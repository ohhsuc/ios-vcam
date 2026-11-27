#import "MediaManager.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

@interface MediaManager ()
@property (atomic, readwrite) BOOL isRunning;
@property (atomic, readwrite) BOOL hasVideo;
@property (atomic, copy, readwrite, nullable) NSString *lastError;
@end

@implementation MediaManager {
    dispatch_queue_t _decodeQueue;
    dispatch_source_t _timer;
    NSURL *_fileURL;
    AVAsset *_asset;
    AVAssetReader *_reader;
    AVAssetReaderOutput *_output;
    CMSampleBufferRef _pending;
    CVPixelBufferRef _latest;
    CMTime _lastPTS;
    CMTime _originPTS;
    double _clockStart;
    BOOL _clockActive;
}

+ (instancetype)sharedManager {
    static MediaManager *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _decodeQueue = dispatch_queue_create("com.vcam.decode", DISPATCH_QUEUE_SERIAL);
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _decodeQueue);
        dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 60, NSEC_PER_MSEC * 2);
        __weak MediaManager *weakSelf = self;
        dispatch_source_set_event_handler(_timer, ^{ [weakSelf tick]; });
        dispatch_resume(_timer);
    }
    return self;
}

- (NSError *)errorWithMessage:(NSString *)message {
    return [NSError errorWithDomain:@"com.vcam.media" code:1
                            userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (void)clearLatest {
    @synchronized (self) {
        if (_latest) CVPixelBufferRelease(_latest);
        _latest = NULL;
    }
}

- (void)closeReader {
    if (_pending) CFRelease(_pending);
    _pending = NULL;
    [_reader cancelReading];
    _reader = nil;
    _output = nil;
    _clockActive = NO;
}

- (void)discardVideo {
    self.isRunning = NO;
    self.hasVideo = NO;
    [self closeReader];
    [self clearLatest];
    _asset = nil;
    if (_fileURL) [[NSFileManager defaultManager] removeItemAtURL:_fileURL error:NULL];
    _fileURL = nil;
}

- (BOOL)openReader:(NSError **)error {
    [self closeReader];
    NSArray<AVAssetTrack *> *tracks = [_asset tracksWithMediaType:AVMediaTypeVideo];
    if (!tracks.count) {
        if (error) *error = [self errorWithMessage:@"视频没有可读取的视频轨道"];
        return NO;
    }
    AVAssetTrack *track = tracks.firstObject;
    _reader = [[AVAssetReader alloc] initWithAsset:_asset error:error];
    if (!_reader) return NO;
    NSDictionary *settings = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    // Apply the source's display transform for portrait/rotated clips.
    if (!CGAffineTransformIsIdentity(track.preferredTransform)) {
        AVAssetReaderVideoCompositionOutput *output = [[AVAssetReaderVideoCompositionOutput alloc] initWithVideoTracks:@[track] videoSettings:settings];
        output.videoComposition = [AVMutableVideoComposition videoCompositionWithPropertiesOfAsset:_asset];
        _output = output;
    } else {
        _output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    }
    _output.alwaysCopiesSampleData = NO;
    if (![_reader canAddOutput:_output]) {
        if (error) *error = [self errorWithMessage:@"无法创建视频解码输出"];
        [self closeReader];
        return NO;
    }
    [_reader addOutput:_output];
    if (![_reader startReading]) {
        if (error) *error = _reader.error ?: [self errorWithMessage:@"视频解码启动失败"];
        [self closeReader];
        return NO;
    }
    return YES;
}

- (BOOL)publish:(CMSampleBufferRef)sample {
    CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(sample);
    if (!pixel) return NO;
    CVPixelBufferRetain(pixel);
    @synchronized (self) {
        if (_latest) CVPixelBufferRelease(_latest);
        _latest = pixel;
    }
    _lastPTS = CMSampleBufferGetPresentationTimeStamp(sample);
    return YES;
}

- (BOOL)primeReader:(NSError **)error {
    if (![self openReader:error]) return NO;
    CMSampleBufferRef first = [_output copyNextSampleBuffer];
    BOOL ok = first && [self publish:first];
    if (first) CFRelease(first);
    if (!ok) {
        if (error) *error = _reader.error ?: [self errorWithMessage:@"视频没有可解码的帧"];
        [self closeReader];
        return NO;
    }
    _clockActive = NO;
    return YES;
}

- (void)loadVideoAtURL:(NSURL *)url completion:(void (^)(NSError *))completion {
    dispatch_async(_decodeQueue, ^{
        [self discardVideo];
        self.lastError = nil;
        self->_fileURL = url;
        self->_asset = [AVURLAsset URLAssetWithURL:url options:nil];
        NSError *error = nil;
        if ([self primeReader:&error]) {
            self.hasVideo = YES;
        } else {
            error = error ?: [self errorWithMessage:@"无法读取视频"];
            self.lastError = error.localizedDescription;
            [self discardVideo];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

- (void)tick {
    if (!self.isRunning || !self.hasVideo) {
        _clockActive = NO;
        return;
    }
    double now = CACurrentMediaTime();
    if (!_clockActive) {
        _clockStart = now;
        _originPTS = _lastPTS;
        _clockActive = YES;
    }
    // Bound work per tick. Decode on the serial queue, never the UI/camera queue.
    for (NSUInteger i = 0; i < 8 && self.isRunning; i++) {
        if (!_pending) _pending = [_output copyNextSampleBuffer];
        if (!_pending) {
            if (_reader.status == AVAssetReaderStatusCompleted) {
                // Single playback: never silently restart a completed clip.
                self.lastError = @"视频已播放完毕，已关闭虚拟相机；如需再次播放，请重新选择视频。";
            } else if (_reader.status == AVAssetReaderStatusFailed ||
                       _reader.status == AVAssetReaderStatusCancelled) {
                self.lastError = _reader.error.localizedDescription ?: @"视频解码中断";
            } else {
                return;
            }
            [self discardVideo];
            return;
        }
        double offset = CMTimeGetSeconds(CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(_pending), _originPTS));
        if (isfinite(offset) && offset > now - _clockStart) return;
        [self publish:_pending];
        CFRelease(_pending);
        _pending = NULL;
    }
}

- (void)start {
    if (self.hasVideo) self.isRunning = YES;
}

- (void)stop {
    self.isRunning = NO;
    dispatch_async(_decodeQueue, ^{ self->_clockActive = NO; });
}

- (CVPixelBufferRef)copyLatestPixelBuffer {
    if (!self.isRunning) return NULL;
    @synchronized (self) {
        if (!self.isRunning || !_latest) return NULL;
        return CVPixelBufferRetain(_latest);
    }
}

- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
    [self closeReader];
    [self clearLatest];
}
@end

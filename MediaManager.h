#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN
@interface MediaManager : NSObject
@property (atomic, readonly) BOOL isRunning;
@property (atomic, readonly) BOOL hasVideo;
@property (atomic, copy, readonly, nullable) NSString *lastError;
+ (instancetype)sharedManager;
// Ownership of the imported temporary file passes to the manager.
- (void)loadVideoAtURL:(NSURL *)url completion:(void (^)(NSError * _Nullable error))completion;
- (void)start;
- (void)stop;
- (nullable CVPixelBufferRef)copyLatestPixelBuffer CF_RETURNS_RETAINED;
@end
NS_ASSUME_NONNULL_END

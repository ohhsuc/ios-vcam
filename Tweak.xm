#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTPixelTransferSession.h>
#import <VideoToolbox/VTPixelTransferProperties.h>
#import <objc/runtime.h>
#import "MediaManager.h"
#include <atomic>

// Diagnostic counters only: do not change frame processing or retain camera images.
enum VCamDiagnosticReason { VCamNoAttempt, VCamInvalidOriginal, VCamNoImage, VCamNoSource, VCamTransferFailed, VCamFormatMismatch, VCamSampleCreationFailed, VCamAttachmentMismatch, VCamInvalidReplacement, VCamReplacementReady };
static std::atomic<unsigned long long> g_callbackCount{0}, g_activeCount{0}, g_replacedCount{0}, g_fallbackCount{0};
static std::atomic<int> g_lastReason{VCamNoAttempt};
static CMSampleBufferRef diagnosticFailure(VCamDiagnosticReason reason) {
    g_lastReason.store(reason, std::memory_order_relaxed);
    return NULL;
}
static NSString *diagnosticSummary(void) {
    NSString *reason;
    switch (g_lastReason.load(std::memory_order_relaxed)) {
        case VCamInvalidOriginal: reason = @"原始帧无效"; break;
        case VCamNoImage: reason = @"原始图像或格式缺失"; break;
        case VCamNoSource: reason = @"解码帧尚未就绪"; break;
        case VCamTransferFailed: reason = @"像素转换失败"; break;
        case VCamFormatMismatch: reason = @"格式描述不匹配"; break;
        case VCamSampleCreationFailed: reason = @"SampleBuffer 创建失败"; break;
        case VCamAttachmentMismatch: reason = @"附加信息数量不匹配"; break;
        case VCamInvalidReplacement: reason = @"替换帧无效"; break;
        case VCamReplacementReady: reason = @"替换帧已生成"; break;
        default: reason = @"尚无替换尝试"; break;
    }
    return [NSString stringWithFormat:@"回调 %llu · 启用时 %llu\n替换 %llu · 回退 %llu\n%@", g_callbackCount.load(std::memory_order_relaxed), g_activeCount.load(std::memory_order_relaxed), g_replacedCount.load(std::memory_order_relaxed), g_fallbackCount.load(std::memory_order_relaxed), reason];
}

#pragma mark - Isolated user interface
@interface VCamOverlayWindow : UIWindow
@property (nonatomic, weak) UIButton *floatingButton;
@property (nonatomic, assign) BOOL modalInteraction;
@end

@implementation VCamOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.modalInteraction) return [super hitTest:point withEvent:event];
    UIButton *button = self.floatingButton;
    if (!button || button.hidden || !button.userInteractionEnabled) return nil;
    CGPoint local = [button convertPoint:point fromView:self];
    if (![button pointInside:local withEvent:event]) return nil;
    return [button hitTest:local withEvent:event];
}
@end

@interface VCamController : UIViewController <PHPickerViewControllerDelegate>
@property (nonatomic, weak) VCamOverlayWindow *overlay;
@property (nonatomic, weak) UIWindow *previousKeyWindow;
@property (nonatomic, strong) UIButton *floatingButton;
@property (nonatomic, strong) UIView *menu;
@property (nonatomic, strong) NSProgress *importProgress;
@property (nonatomic, assign) NSUInteger importGeneration;
@property (nonatomic, assign) BOOL importing;
@property (nonatomic, copy) NSString *status;
- (void)refreshButton;
@end

static NSArray<UIWindow *> *windowsForOverlay(UIWindow *overlay) {
    if (overlay.windowScene) return overlay.windowScene.windows;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIApplication.sharedApplication.windows;
#pragma clang diagnostic pop
}

@implementation VCamController

- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:CGRectZero];
    self.view.backgroundColor = UIColor.clearColor;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 100, 50, 50);
    button.layer.cornerRadius = 25;
    button.titleLabel.font = [UIFont systemFontOfSize:24];
    [button setTitle:@"📷" forState:UIControlStateNormal];
    [button addTarget:self action:@selector(showMenu:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    [button addGestureRecognizer:pan];
    self.floatingButton = button;
    [self.view addSubview:button];
    [self refreshButton];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (CGRectIsEmpty(self.view.bounds)) return;
    if (CGRectGetMinX(self.floatingButton.frame) == 0) {
        self.floatingButton.center = CGPointMake(CGRectGetWidth(self.view.bounds)-40, 125);
    }
    [self clampButton];
}

- (void)clampButton {
    CGRect bounds = self.view.bounds;
    if (CGRectIsEmpty(bounds)) return;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat minX = safe.left + 26, maxX = CGRectGetWidth(bounds) - safe.right - 26;
    CGFloat minY = safe.top + 26, maxY = CGRectGetHeight(bounds) - safe.bottom - 26;
    CGPoint p = self.floatingButton.center;
    p.x = MIN(MAX(p.x,minX),MAX(minX,maxX));
    p.y = MIN(MAX(p.y,minY),MAX(minY,maxY));
    self.floatingButton.center = p;
}

- (void)drag:(UIPanGestureRecognizer *)gesture {
    CGPoint delta = [gesture translationInView:self.view];
    CGPoint p = self.floatingButton.center;
    self.floatingButton.center = CGPointMake(p.x+delta.x,p.y+delta.y);
    [gesture setTranslation:CGPointZero inView:self.view];
    [self clampButton];
    if (gesture.state == UIGestureRecognizerStateEnded) {
        p = self.floatingButton.center;
        p.x = p.x < CGRectGetMidX(self.view.bounds) ? 35 : CGRectGetWidth(self.view.bounds)-35;
        [UIView animateWithDuration:0.2 animations:^{
            self.floatingButton.center = p;
            [self clampButton];
        }];
    }
}

- (void)refreshButton {
    MediaManager *manager = [MediaManager sharedManager];
    self.floatingButton.backgroundColor = self.importing ? UIColor.systemOrangeColor :
        (manager.isRunning ? UIColor.systemGreenColor : UIColor.systemGrayColor);
}

- (void)restoreInteraction {
    [self.menu removeFromSuperview];
    self.menu = nil;
    self.overlay.modalInteraction = NO;
    self.overlay.windowLevel = UIWindowLevelStatusBar - 1;
    self.floatingButton.hidden = NO;
    if (self.overlay.isKeyWindow) {
        UIWindow *previous = self.previousKeyWindow;
        if (!previous || previous.hidden) {
            for (UIWindow *window in windowsForOverlay(self.overlay)) {
                if (window != self.overlay && !window.hidden && window.rootViewController &&
                    window.windowLevel == UIWindowLevelNormal) {
                    previous = window;
                    break;
                }
            }
        }
        if (previous && previous != self.overlay) [previous makeKeyWindow];
        else [self.overlay resignKeyWindow];
    }
    self.previousKeyWindow = nil;
    [self refreshButton];
}

- (void)showMenu:(UIButton *)sender {
    if (self.menu || self.presentedViewController) return;
    [self refreshButton];
    self.overlay.modalInteraction = YES;
    self.overlay.windowLevel = UIWindowLevelAlert + 1;
    self.floatingButton.hidden = YES;

    UIView *backdrop = [[UIView alloc] initWithFrame:self.view.bounds];
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    self.menu = backdrop;
    [self.view addSubview:backdrop];

    UIStackView *panel = [[UIStackView alloc] init];
    panel.axis = UILayoutConstraintAxisVertical;
    panel.spacing = 8;
    panel.layoutMargins = UIEdgeInsetsMake(16,16,16,16);
    panel.layoutMarginsRelativeArrangement = YES;
    panel.backgroundColor = UIColor.secondarySystemBackgroundColor;
    panel.layer.cornerRadius = 16;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    [backdrop addSubview:panel];
    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:backdrop.centerXAnchor],
        [panel.centerYAnchor constraintEqualToAnchor:backdrop.centerYAnchor],
        [panel.widthAnchor constraintEqualToConstant:260]
    ]];

    MediaManager *manager = [MediaManager sharedManager];
    UILabel *label = [[UILabel alloc] init];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.labelColor;
    NSString *state = self.importing ? @"正在导入视频" :
        (manager.isRunning ? @"虚拟视频已启用" : (manager.hasVideo ? @"视频已就绪" : @"未选择视频"));
    NSString *detail = manager.lastError ?: self.status;
    label.text = detail.length ? [NSString stringWithFormat:@"VCam · %@\n%@",state,detail] :
        [NSString stringWithFormat:@"VCam · %@",state];
    [panel addArrangedSubview:label];
    UILabel *diagnostic = [[UILabel alloc] init];
    diagnostic.numberOfLines = 0;
    diagnostic.textAlignment = NSTextAlignmentCenter;
    diagnostic.textColor = UIColor.secondaryLabelColor;
    diagnostic.font = [UIFont systemFontOfSize:12];
    diagnostic.text = diagnosticSummary();
    [panel addArrangedSubview:diagnostic];

    [self addButton:self.importing ? @"取消导入" : @"选择视频" selector:self.importing ? @selector(cancelImport:) : @selector(selectVideo:) to:panel enabled:YES];
    [self addButton:manager.isRunning ? @"关闭虚拟相机" : @"开启虚拟相机" selector:@selector(toggleVideo:) to:panel enabled:!self.importing && manager.hasVideo];
    [self addButton:@"关闭菜单" selector:@selector(closeMenu:) to:panel enabled:YES];
}

- (void)addButton:(NSString *)title selector:(SEL)selector to:(UIStackView *)panel enabled:(BOOL)enabled {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:selector forControlEvents:UIControlEventTouchUpInside];
    button.enabled = enabled;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [panel addArrangedSubview:button];
}

- (void)closeMenu:(UIButton *)sender { [self restoreInteraction]; }

- (void)toggleVideo:(UIButton *)sender {
    MediaManager *manager = [MediaManager sharedManager];
    if (manager.isRunning) [manager stop];
    else [manager start];
    [self restoreInteraction];
}

- (void)cancelImport:(UIButton *)sender {
    self.importGeneration++;
    [self.importProgress cancel];
    self.importProgress = nil;
    self.importing = NO;
    self.status = @"已取消导入";
    [[MediaManager sharedManager] stop];
    [self restoreInteraction];
}

- (void)selectVideo:(UIButton *)sender {
    if (self.importing || self.presentedViewController) return;
    [self.menu removeFromSuperview];
    self.menu = nil;
    for (UIWindow *window in windowsForOverlay(self.overlay)) {
        if (window != self.overlay && window.isKeyWindow) {
            self.previousKeyWindow = window;
            break;
        }
    }
    if (!self.previousKeyWindow && !self.overlay.isKeyWindow) {
        for (UIWindow *window in windowsForOverlay(self.overlay)) {
            if (window != self.overlay && !window.hidden && window.rootViewController && window.windowLevel == UIWindowLevelNormal) {
                self.previousKeyWindow = window;
                break;
            }
        }
    }
    [self.overlay makeKeyAndVisible];
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.filter = PHPickerFilter.videosFilter;
    config.selectionLimit = 1;
    config.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    NSItemProvider *provider = results.firstObject.itemProvider;
    [picker dismissViewControllerAnimated:YES completion:^{ [self restoreInteraction]; }];
    if (!provider) return;
    if (![provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        self.status = @"所选内容不是视频";
        return;
    }
    self.importing = YES;
    self.status = nil;
    NSUInteger generation = ++self.importGeneration;
    [[MediaManager sharedManager] stop];
    [self refreshButton];
    self.importProgress = [provider loadFileRepresentationForTypeIdentifier:@"public.movie" completionHandler:^(NSURL *url, NSError *error) {
        // The provider's URL is temporary: copy before this callback returns.
        NSURL *local = nil;
        NSError *copyError = error;
        if (url && !copyError) {
            NSString *ext = url.pathExtension.length ? url.pathExtension : @"mov";
            NSString *name = [NSString stringWithFormat:@"vcam-%@.%@",NSUUID.UUID.UUIDString,ext];
            local = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
            if (![[NSFileManager defaultManager] copyItemAtURL:url toURL:local error:&copyError]) local = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.importGeneration) {
                if (local) [[NSFileManager defaultManager] removeItemAtURL:local error:NULL];
                return;
            }
            self.importProgress = nil;
            if (!local) {
                self.importing = NO;
                self.status = copyError.localizedDescription ?: @"视频导入失败";
                [self refreshButton];
                if (self.menu) { [self restoreInteraction]; [self showMenu:self.floatingButton]; }
                return;
            }
            [[MediaManager sharedManager] loadVideoAtURL:local completion:^(NSError *loadError) {
                if (generation != self.importGeneration) return;
                self.importing = NO;
                self.status = loadError.localizedDescription;
                if (!loadError) [[MediaManager sharedManager] start];
                [self refreshButton];
                if (self.menu) { [self restoreInteraction]; [self showMenu:self.floatingButton]; }
            }];
        });
    }];
}
@end

static VCamOverlayWindow *g_overlayWindow;
static VCamController *g_controller;

static void setupOverlay(void) {
    if (g_overlayWindow) { [g_controller refreshButton]; return; }
    UIWindowScene *activeScene = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
            activeScene = (UIWindowScene *)scene;
            break;
        }
    }
    if (!activeScene && UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    // LiveContainer can host legacy applications without a foreground UIWindowScene.
    VCamOverlayWindow *window = activeScene ? [[VCamOverlayWindow alloc] initWithWindowScene:activeScene] : [[VCamOverlayWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    window.frame = activeScene ? activeScene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
    window.backgroundColor = UIColor.clearColor;
    window.windowLevel = UIWindowLevelStatusBar - 1;
    VCamController *controller = [[VCamController alloc] init];
    controller.overlay = window;
    window.rootViewController = controller;
    [controller loadViewIfNeeded];
    window.floatingButton = controller.floatingButton;
    g_controller = controller;
    g_overlayWindow = window;
    window.hidden = NO;
}

#pragma mark - Video data output (one delegate proxy per output)
@interface VCamVideoDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> target;
@end

@implementation VCamVideoDelegate {
    VTPixelTransferSessionRef _transfer;
}

- (void)dealloc {
    if (_transfer) {
        if (@available(iOS 16.0, *)) VTPixelTransferSessionInvalidate(_transfer);
        CFRelease(_transfer);
    }
}

- (CMSampleBufferRef)copyReplacementFor:(CMSampleBufferRef)original CF_RETURNS_RETAINED {
    if (!original || !CMSampleBufferIsValid(original) ||
        !CMSampleBufferDataIsReady(original) || CMSampleBufferGetNumSamples(original) != 1) return diagnosticFailure(VCamInvalidOriginal);
    CVPixelBufferRef incoming = CMSampleBufferGetImageBuffer(original);
    CMVideoFormatDescriptionRef desc = CMSampleBufferGetFormatDescription(original);
    if (!incoming || !desc || CMFormatDescriptionGetMediaType(desc) != kCMMediaType_Video) return diagnosticFailure(VCamNoImage);
    CVPixelBufferRef source = [[MediaManager sharedManager] copyLatestPixelBuffer];
    if (!source) return diagnosticFailure(VCamNoSource);

    CVPixelBufferRef output = NULL;
    size_t width = CVPixelBufferGetWidth(incoming), height = CVPixelBufferGetHeight(incoming);
    OSType format = CVPixelBufferGetPixelFormatType(incoming);
    if (!_transfer) {
        OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &_transfer);
        if (status == noErr && _transfer) {
            VTSessionSetProperty(_transfer, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_CropSourceToCleanAperture);
        }
    }
    NSDictionary *attrs = @{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    if (_transfer && CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                         (__bridge CFDictionaryRef)attrs, &output) == kCVReturnSuccess && output) {
        // Preserve buffer-level format/colour attachments on a fresh destination.
        const CVAttachmentMode cvModes[] = {kCVAttachmentMode_ShouldPropagate, kCVAttachmentMode_ShouldNotPropagate};
        for (CVAttachmentMode mode : cvModes) {
            CFDictionaryRef values = CVBufferCopyAttachments(incoming, mode);
            if (values) { CVBufferSetAttachments(output, values, mode); CFRelease(values); }
        }
        if (VTPixelTransferSessionTransferImage(_transfer, source, output) != noErr) {
            CVPixelBufferRelease(output);
            output = NULL;
        }
    }
    CVPixelBufferRelease(source);
    if (!output) return diagnosticFailure(VCamTransferFailed);

    // Never pass a sample whose image buffer disagrees with its format description.
    if (!CMVideoFormatDescriptionMatchesImageBuffer(desc, output)) {
        CVPixelBufferRelease(output);
        return diagnosticFailure(VCamFormatMismatch);
    }
    CMSampleTimingInfo timing;
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMSampleBufferGetSampleTimingInfo(original, 0, &timing);
    if (status == noErr) {
        status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, output, desc, &timing, &sample);
    }
    CVPixelBufferRelease(output);
    if (status != noErr || !sample) {
        if (sample) CFRelease(sample);
        return diagnosticFailure(VCamSampleCreationFailed);
    }

    // Keep both attachment modes, not just the propagating dictionary.
    const CMAttachmentMode cmModes[] = {kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate};
    for (CMAttachmentMode mode : cmModes) {
        CFDictionaryRef values = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, original, mode);
        if (values) { CMSetAttachments(sample, values, mode); CFRelease(values); }
    }
    CFArrayRef originalAttachments = CMSampleBufferGetSampleAttachmentsArray(original, false);
    if (originalAttachments && CFArrayGetCount(originalAttachments) > 0) {
        CFArrayRef newAttachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
        if (!newAttachments || CFArrayGetCount(newAttachments) != CFArrayGetCount(originalAttachments)) {
            CFRelease(sample);
            return diagnosticFailure(VCamAttachmentMismatch);
        }
        for (CFIndex i = 0; i < CFArrayGetCount(originalAttachments); i++) {
            NSDictionary *from = (__bridge NSDictionary *)CFArrayGetValueAtIndex(originalAttachments, i);
            NSMutableDictionary *to = (__bridge NSMutableDictionary *)CFArrayGetValueAtIndex(newAttachments, i);
            if (from && to) [to addEntriesFromDictionary:from];
        }
    }
    CMTime outputPTS = CMSampleBufferGetOutputPresentationTimeStamp(original);
    if (CMTIME_IS_VALID(outputPTS) && CMTIME_IS_NUMERIC(outputPTS)) {
        CMSampleBufferSetOutputPresentationTimeStamp(sample, outputPTS);
    }
    if (!CMSampleBufferIsValid(sample) || !CMSampleBufferDataIsReady(sample)) {
        CFRelease(sample);
        return diagnosticFailure(VCamInvalidReplacement);
    }
    g_lastReason.store(VCamReplacementReady, std::memory_order_relaxed);
    return sample;
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> target = self.target;
    if (![target respondsToSelector:_cmd]) return;
    g_callbackCount.fetch_add(1, std::memory_order_relaxed);
    CMSampleBufferRef replacement = NULL;
    if ([MediaManager sharedManager].isRunning) {
        g_activeCount.fetch_add(1, std::memory_order_relaxed);
        replacement = [self copyReplacementFor:sampleBuffer];
        if (replacement) g_replacedCount.fetch_add(1, std::memory_order_relaxed);
        else g_fallbackCount.fetch_add(1, std::memory_order_relaxed);
    }
    @try {
        [target captureOutput:output didOutputSampleBuffer:replacement ?: sampleBuffer fromConnection:connection];
    } @finally {
        if (replacement) CFRelease(replacement);
    }
}

- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> target = self.target;
    if ([target respondsToSelector:_cmd]) [target captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
}
@end

static char kVCamDelegateKey;

%group VCamHooks
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if ([delegate isKindOfClass:VCamVideoDelegate.class]) {
        %orig(delegate, queue);
        return;
    }
    VCamVideoDelegate *proxy = nil;
    if (delegate && queue && [delegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        proxy = [[VCamVideoDelegate alloc] init];
        proxy.target = delegate;
    }
    // Keep the previous proxy alive until the framework has switched delegates.
    VCamVideoDelegate * __attribute__((objc_precise_lifetime)) previous = objc_getAssociatedObject(self,&kVCamDelegateKey);
    (void)previous;
    %orig(proxy ? (id)proxy : delegate, queue);
    objc_setAssociatedObject(self,&kVCamDelegateKey,proxy,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%end
%end

%ctor {
    @autoreleasepool {
        if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        %init(VCamHooks);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { setupOverlay(); }];
            [center addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { setupOverlay(); }];
            setupOverlay();
        });
    }
}

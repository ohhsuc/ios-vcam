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
    CVPixelBufferRef incoming = CMSampleBufferGetImageBuffer(original);
    if (!incoming) return NULL;
    CVPixelBufferRef source = [[MediaManager sharedManager] copyLatestPixelBuffer];
    if (!source) return NULL;
    CVPixelBufferRef output = NULL;
    size_t width = CVPixelBufferGetWidth(incoming), height = CVPixelBufferGetHeight(incoming);
    OSType format = CVPixelBufferGetPixelFormatType(incoming);
    if (CVPixelBufferGetWidth(source)==width && CVPixelBufferGetHeight(source)==height &&
        CVPixelBufferGetPixelFormatType(source)==format) {
        output = CVPixelBufferRetain(source);
    } else if (@available(iOS 16.0, *)) {
        if (!_transfer && VTPixelTransferSessionCreate(kCFAllocatorDefault,&_transfer)==noErr) {
            VTSessionSetProperty(_transfer,kVTPixelTransferPropertyKey_ScalingMode,kVTScalingMode_CropSourceToCleanAperture);
        }
        NSDictionary *attrs = @{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}};
        if (_transfer && CVPixelBufferCreate(kCFAllocatorDefault,width,height,format,(__bridge CFDictionaryRef)attrs,&output)==kCVReturnSuccess) {
            if (VTPixelTransferSessionTransferImage(_transfer,source,output)!=noErr) {
                CVPixelBufferRelease(output);
                output = NULL;
            }
        }
    }
    CVPixelBufferRelease(source);
    if (!output) return NULL;
    CMVideoFormatDescriptionRef desc = NULL;
    CMSampleBufferRef sample = NULL;
    CMSampleTimingInfo timing;
    if (CMSampleBufferGetSampleTimingInfo(original,0,&timing)==noErr &&
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,output,&desc)==noErr) {
        CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,output,desc,&timing,&sample);
    }
    if (desc) CFRelease(desc);
    CVPixelBufferRelease(output);
    return sample;
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> target = self.target;
    if (![target respondsToSelector:_cmd]) return;
    CMSampleBufferRef replacement = [self copyReplacementFor:sampleBuffer];
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

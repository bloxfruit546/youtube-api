//
//  Tweak.x
//  PhotographicStyles16
//
//  Glue: find the viewfinder, mount PS16ControlPanelView above it, run a live
//  filtered preview from the camera's own capture session, and bake the same
//  style into finished stills before CameraUI hands them to the Photo Library.
//
//  Every private class is resolved with objc_getClass("...") and every private
//  property is read/written through KVC inside @try/@catch, so a 12.x build that
//  disagrees with the header cannot crash the Camera app.
//

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>

#import "CameraUIHeaders.h"
#import "PS16ColorEngine.h"
#import "PS16ControlPanelView.h"

#pragma mark - Constants

static const CGFloat kPS16PanelHeight = 284.0;
static const CGFloat kPS16TriggerSize = 40.0;

// Associated-object keys; the addresses are never dereferenced.
static char kPS16PanelKey;
static char kPS16TriggerKey;
static char kPS16TriggerControllerKey;
#define PS16PanelAssocKey ((const void *)&kPS16PanelKey)
#define PS16TriggerAssocKey ((const void *)&kPS16TriggerKey)
#define PS16TriggerControllerAssocKey ((const void *)&kPS16TriggerControllerKey)

// Forward declarations: the panel's callbacks are assigned before these are
// defined, and C blocks need the symbols visible at the point of use.
static void PS16UpdateLivePreview(UIViewController *controller);
static PS16ControlPanelView *PS16PanelFor(UIViewController *controller);

#pragma mark - Safe KVC

static id PS16Value(id object, NSString *key)
{
    if (object == nil || key == nil) {
        return nil;
    }

    @try {
        return [object valueForKey:key];
    } @catch (NSException *exception) {
        return nil;
    }
}

static void PS16SetValue(id object, NSString *key, id value)
{
    if (object == nil || key == nil || value == nil) {
        return;
    }

    @try {
        [object setValue:value forKey:key];
    } @catch (NSException *exception) {
        // Some 12.x builds keep these readonly. Leaving the original in place is
        // always safe, so there is nothing to recover from.
    }
}

#pragma mark - Live preview

/// Receives frames from a video-data output attached to the Camera app's own
/// session, renders the style on the A7 GPU and blits the result into its own
/// layer. Frames are downscaled to the view size before the filter chain runs:
/// the chain is per-pixel, so the result is identical and a 1080p render 30
/// times a second is not something a PowerVR G6430 will do.
@interface PS16LivePreviewView : UIView <AVCaptureVideoDataOutputSampleBufferDelegate> {
    BOOL _inFlight;
    BOOL _outputAttached;
    BOOL _active;
    CGSize _targetSize;
    // AVCaptureOutput exposes no -session (it is private), so remember which one
    // we hooked. Weak: the session is owned by the Camera app.
    __weak AVCaptureSession *_attachedSession;
}

@property (nonatomic, strong) CIContext *context;
@property (nonatomic, strong, nullable) AVCaptureVideoDataOutput *output;
@property (nonatomic, weak, nullable) id<AVCaptureVideoDataOutputSampleBufferDelegate> chainedDelegate;
@property (nonatomic, strong, nullable) dispatch_queue_t chainedQueue;
@property (nonatomic, strong, nullable) dispatch_queue_t framesQueue;

+ (instancetype)sharedView;

- (void)attachToPreviewLayer:(nullable CALayer *)previewLayer;
- (void)setActive:(BOOL)active;
- (void)clearFrame;

- (void)ps16_attachOutputToSession:(AVCaptureSession *)session;
- (void)ps16_renderPixelBuffer:(CVPixelBufferRef)pixelBuffer
                   orientation:(AVCaptureVideoOrientation)orientation;

@end

@implementation PS16LivePreviewView

+ (instancetype)sharedView
{
    static PS16LivePreviewView *view = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        view = [[PS16LivePreviewView alloc] initWithFrame:CGRectZero];
    });

    return view;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];

    if (self) {
        // The engine owns the only CIContext in the process, so the preview and
        // the stills share one GPU pipeline and one set of compiled kernels.
        _context = [PS16ColorEngine sharedEngine].renderingContext;
        _framesQueue = dispatch_queue_create("com.ps16.preview.frames", DISPATCH_QUEUE_SERIAL);
        _targetSize = CGSizeMake(640.0, 1136.0);

        self.backgroundColor = [UIColor blackColor];
        self.userInteractionEnabled = NO;
        // Hidden until the first filtered frame lands, so a failed attach can
        // never black out the stock viewfinder.
        self.hidden = YES;
        self.layer.contentsGravity = kCAGravityResize;
        self.layer.masksToBounds = YES;
        self.layer.opaque = YES;
    }

    return self;
}

#pragma mark Session wiring

/// Depth-first hunt for the AVFoundation preview layer; CAMPreviewView may expose
/// a plain container layer instead.
static AVCaptureVideoPreviewLayer *PS16FindPreviewLayer(CALayer *root, NSInteger depth)
{
    if (root == nil || depth > 4) {
        return nil;
    }

    if ([root isKindOfClass:[AVCaptureVideoPreviewLayer class]]) {
        return (AVCaptureVideoPreviewLayer *)root;
    }

    for (CALayer *child in root.sublayers) {
        AVCaptureVideoPreviewLayer *found = PS16FindPreviewLayer(child, depth + 1);

        if (found != nil) {
            return found;
        }
    }

    return nil;
}

- (void)attachToPreviewLayer:(CALayer *)previewLayer
{
    if (previewLayer == nil) {
        return;
    }

    AVCaptureVideoPreviewLayer *videoLayer = PS16FindPreviewLayer(previewLayer, 0);
    AVCaptureSession *session = nil;

    if (videoLayer != nil) {
        @try {
            session = videoLayer.session;
        } @catch (NSException *exception) {
            session = nil;
        }
    }

    if (session == nil) {
        return;
    }

    // A new session (camera switch, mode change) means the old output went with
    // it; re-attach against the new one.
    if (_outputAttached && _attachedSession == session) {
        return;
    }

    _outputAttached = NO;
    _attachedSession = session;
    [self ps16_attachOutputToSession:session];
}

- (void)ps16_attachOutputToSession:(AVCaptureSession *)session
{
    // The Camera app usually already owns a video-data output (scene detection,
    // QR codes). A session allows only one, so reuse it rather than fight it.
    AVCaptureVideoDataOutput *output = nil;

    @try {
        for (AVCaptureOutput *existing in session.outputs) {
            if ([existing isKindOfClass:[AVCaptureVideoDataOutput class]]) {
                output = (AVCaptureVideoDataOutput *)existing;
                break;
            }
        }
    } @catch (NSException *exception) {
        output = nil;
    }

    BOOL owned = (output == nil);

    if (owned) {
        output = [[AVCaptureVideoDataOutput alloc] init];
        output.alwaysDiscardsLateVideoFrames = YES;
        output.videoSettings = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        };
    } else {
        // Chain, do not steal: the Camera app keeps receiving its own frames.
        self.chainedDelegate = output.sampleBufferDelegate;
        self.chainedQueue = output.sampleBufferCallbackQueue;
    }

    @try {
        [output setSampleBufferDelegate:self queue:self.framesQueue];
    } @catch (NSException *exception) {
        NSLog(@"[PS16] sample buffer delegate refused: %@", exception.reason);
        return;
    }

    self.output = output;

    if (!owned) {
        _outputAttached = YES;
        return;
    }

    @try {
        [session beginConfiguration];

        if ([session canAddOutput:output]) {
            [session addOutput:output];
        } else {
            NSLog(@"[PS16] session refused the video data output");
            self.output = nil;
            return;
        }

        [session commitConfiguration];
    } @catch (NSException *exception) {
        NSLog(@"[PS16] session config failed: %@", exception.reason);
        return;
    }

    _outputAttached = YES;
}

#pragma mark Frame path

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    id<AVCaptureVideoDataOutputSampleBufferDelegate> chained = self.chainedDelegate;

    if (chained != nil) {
        dispatch_queue_t queue = self.chainedQueue ?: dispatch_get_main_queue();

        dispatch_async(queue, ^{
            [chained captureOutput:captureOutput
               didOutputSampleBuffer:sampleBuffer
                      fromConnection:connection];
        });
    }

    if (!_active || _inFlight) {
        return;
    }

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);

    if (pixelBuffer == NULL) {
        return;
    }

    AVCaptureVideoOrientation orientation = AVCaptureVideoOrientationPortrait;

    @try {
        orientation = connection.videoOrientation;
    } @catch (NSException *exception) {
        orientation = AVCaptureVideoOrientationPortrait;
    }

    // Already on the serial frames queue and createCGImage: blocks, so a plain
    // flag is enough to drop frames while the GPU is still busy.
    _inFlight = YES;
    [self ps16_renderPixelBuffer:pixelBuffer orientation:orientation];
    _inFlight = NO;
}

/// EXIF orientation that turns a sensor buffer upright for a given preview
/// connection orientation.
static CGImagePropertyOrientation PS16ExifForVideoOrientation(AVCaptureVideoOrientation orientation)
{
    switch (orientation) {
        case AVCaptureVideoOrientationPortraitUpsideDown: return kCGImagePropertyOrientationLeft;
        case AVCaptureVideoOrientationLandscapeRight:     return kCGImagePropertyOrientationDown;
        case AVCaptureVideoOrientationLandscapeLeft:      return kCGImagePropertyOrientationUp;
        case AVCaptureVideoOrientationPortrait:
        default:                                          return kCGImagePropertyOrientationRight;
    }
}

- (void)ps16_renderPixelBuffer:(CVPixelBufferRef)pixelBuffer
                   orientation:(AVCaptureVideoOrientation)orientation
{
    // Read through the ivar: the capture queue must not touch UIKit state.
    CGSize target = _targetSize;

    if (target.width < 1.0 || target.height < 1.0) {
        target = CGSizeMake(640.0, 1136.0);
    }

    @autoreleasepool {
        CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];

        if (image == nil) {
            return;
        }

        image = [image imageByApplyingOrientation:PS16ExifForVideoOrientation(orientation)];

        CGRect extent = image.extent;

        if (extent.size.width < 1.0 || extent.size.height < 1.0) {
            return;
        }

        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-extent.origin.x,
                                                                                -extent.origin.y)];
        extent = image.extent;

        CGFloat cover = MAX(target.width / extent.size.width, target.height / extent.size.height);

        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(cover, cover)];
        extent = image.extent;

        image = [image imageByApplyingTransform:
                 CGAffineTransformMakeTranslation(-(extent.size.width - target.width) * 0.5,
                                                  -(extent.size.height - target.height) * 0.5)];
        image = [image imageByCroppingToRect:CGRectMake(0.0, 0.0, target.width, target.height)];

        image = [[PS16ColorEngine sharedEngine] filteredImage:image];

        if (image == nil) {
            return;
        }

        CGImageRef rendered = nil;

        @try {
            rendered = [self.context createCGImage:image fromRect:image.extent];
        } @catch (NSException *exception) {
            NSLog(@"[PS16] preview render failed: %@", exception.reason);
            rendered = nil;
        }

        if (rendered == NULL) {
            return;
        }

        // The CGImage keeps its pixel storage alive while the layer holds it.
        dispatch_async(dispatch_get_main_queue(), ^{
            self.layer.contents = (__bridge id)rendered;
            self.hidden = NO;
            CGImageRelease(rendered);
        });
    }
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    // Cached on the main thread so the capture queue never reads -bounds.
    CGFloat scale = [UIScreen mainScreen].scale;

    if (scale > 2.0) {
        scale = 2.0;
    }

    _targetSize = CGSizeMake(self.bounds.size.width * scale, self.bounds.size.height * scale);
}

- (void)setActive:(BOOL)active
{
    _active = active;

    if (!active) {
        [self clearFrame];
    }
}

- (void)clearFrame
{
    _inFlight = NO;
    self.layer.contents = nil;
    // Uncovered again: dropping only the contents would leave an opaque black
    // view sitting on top of the stock viewfinder.
    self.hidden = YES;
}

@end

#pragma mark - Trigger button target

/// The reopen button lives directly on the viewfinder, so it has no owning view
/// controller to message. One shared target, with the controller carried on the
/// button itself.
@interface PS16TriggerTarget : NSObject
+ (instancetype)sharedTarget;
- (void)triggerTapped:(UIButton *)sender;
@end

@implementation PS16TriggerTarget

+ (instancetype)sharedTarget
{
    static PS16TriggerTarget *target = nil;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        target = [[PS16TriggerTarget alloc] init];
    });

    return target;
}

- (void)triggerTapped:(UIButton *)sender
{
    id controller = objc_getAssociatedObject(sender, PS16TriggerControllerAssocKey);

    if (![controller isKindOfClass:[UIViewController class]]) {
        return;
    }

    PS16ControlPanelView *panel = PS16PanelFor((UIViewController *)controller);

    if (panel == nil) {
        return;
    }

    sender.hidden = YES;
    [panel showAnimated:YES];
}

@end

#pragma mark - Viewfinder helpers

static CAMPreviewView *PS16PreviewViewOf(UIViewController *controller)
{
    id preview = PS16Value(controller, @"previewView");

    if (![preview isKindOfClass:[UIView class]]) {
        preview = PS16Value(controller, @"_previewView");
    }

    return [preview isKindOfClass:[UIView class]] ? (CAMPreviewView *)preview : nil;
}

static CALayer *PS16VideoLayerOf(CAMPreviewView *preview)
{
    if (preview == nil) {
        return nil;
    }

    id layer = PS16Value(preview, @"previewLayer");

    if (![layer isKindOfClass:[CALayer class]]) {
        layer = PS16Value(preview, @"videoPreviewLayer");
    }

    if (![layer isKindOfClass:[CALayer class]]) {
        layer = preview.layer;
    }

    return [layer isKindOfClass:[CALayer class]] ? (CALayer *)layer : nil;
}

/// Capture mode is private. The iOS 12 Camera binary orders the modes Photo 0,
/// Square 1, Video 2, Slo-mo 3, Timelapse 4, Pano 5; styles apply to the first
/// two only.
///
/// ponytail: hard-coded ordering, no runtime discovery. Ceiling: a build that
/// reorders the enum leaves the panel visible in the wrong mode instead of
/// crashing. Upgrade path is reading the shutter bar's selected button.
static BOOL PS16ModeSupportsStyles(UIViewController *controller)
{
    id mode = PS16Value(controller, @"captureMode");

    if (mode == nil) {
        mode = PS16Value(controller, @"_captureMode");
    }

    if ([mode isKindOfClass:[NSNumber class]]) {
        NSInteger value = [(NSNumber *)mode integerValue];
        return (value >= 0 && value <= 1);
    }

    // Unreadable: fail open. A visible panel is always better than a missing one.
    return YES;
}

#pragma mark - Panel mounting

static PS16ControlPanelView *PS16PanelFor(UIViewController *controller)
{
    if (controller == nil) {
        return nil;
    }

    id panel = objc_getAssociatedObject(controller, PS16PanelAssocKey);

    return [panel isKindOfClass:[PS16ControlPanelView class]] ? (PS16ControlPanelView *)panel : nil;
}

static UIButton *PS16TriggerFor(UIViewController *controller)
{
    if (controller == nil) {
        return nil;
    }

    id trigger = objc_getAssociatedObject(controller, PS16TriggerAssocKey);

    return [trigger isKindOfClass:[UIButton class]] ? (UIButton *)trigger : nil;
}

static void PS16LayoutPanel(PS16ControlPanelView *panel, UIView *host)
{
    CGRect bounds = host.bounds;

    if (bounds.size.width < 1.0 || bounds.size.height < kPS16PanelHeight) {
        return;
    }

    panel.frame = CGRectMake(0.0, bounds.size.height - kPS16PanelHeight, bounds.size.width, kPS16PanelHeight);
}

static void PS16LayoutTrigger(UIButton *trigger, UIView *host)
{
    CGRect bounds = host.bounds;

    if (bounds.size.width < 1.0 || bounds.size.height < kPS16PanelHeight) {
        return;
    }

    // Level with the shutter, inside the right edge.
    trigger.frame = CGRectMake(bounds.size.width - kPS16TriggerSize - 10.0,
                               bounds.size.height - 130.0,
                               kPS16TriggerSize,
                               kPS16TriggerSize);
}

/// Hides or shows the panel *and* the reopen button. The caller drives it from
/// the collapse button and from the mode check.
static void PS16SetPanelVisible(UIViewController *controller, BOOL visible)
{
    PS16ControlPanelView *panel = PS16PanelFor(controller);
    UIButton *trigger = PS16TriggerFor(controller);

    if (panel == nil) {
        return;
    }

    trigger.hidden = visible;

    if (visible) {
        panel.hidden = NO;
        [panel showAnimated:YES];
    } else {
        [panel hideAnimated:YES];
    }
}

static void PS16Mount(UIViewController *controller, BOOL sync)
{
    UIView *hostView = controller.view;

    if (hostView == nil) {
        return;
    }

    CAMPreviewView *preview = PS16PreviewViewOf(controller);
    PS16ControlPanelView *panel = PS16PanelFor(controller);

    if (panel == nil) {
        @try {
            panel = [[PS16ControlPanelView alloc] initWithFrame:CGRectZero];
        } @catch (NSException *exception) {
            panel = nil;
        }

        if (panel == nil) {
            return;
        }

        __weak UIViewController *weakController = controller;

        panel.onParametersChanged = ^{
            UIViewController *strongController = weakController;

            if (strongController != nil) {
                PS16UpdateLivePreview(strongController);
            }
        };

        panel.onCollapseRequested = ^{
            UIViewController *strongController = weakController;

            if (strongController != nil) {
                PS16SetPanelVisible(strongController, NO);
            }
        };

        objc_setAssociatedObject(controller, PS16PanelAssocKey, panel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [hostView addSubview:panel];

        // Reopen button: lives on the viewfinder so it survives the panel being
        // hidden. Hidden until the user collapses the panel once.
        UIButton *trigger = [UIButton buttonWithType:UIButtonTypeCustom];

        trigger.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.6];
        trigger.layer.cornerRadius = kPS16TriggerSize * 0.5;
        trigger.layer.borderWidth = 1.5;
        trigger.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.85].CGColor;
        trigger.titleLabel.font = [UIFont systemFontOfSize:9.0 weight:UIFontWeightBold];
        [trigger setTitle:@"Styles" forState:UIControlStateNormal];
        [trigger setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [trigger addTarget:[PS16TriggerTarget sharedTarget]
                    action:@selector(triggerTapped:)
          forControlEvents:UIControlEventTouchUpInside];

        objc_setAssociatedObject(trigger, PS16TriggerControllerAssocKey, controller, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(controller, PS16TriggerAssocKey, trigger, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [hostView addSubview:trigger];

        trigger.hidden = YES;
        sync = YES;
    }

    if (panel.superview != hostView) {
        @try {
            if (preview != nil && preview.superview == hostView) {
                [hostView insertSubview:panel aboveSubview:preview];
            } else {
                [hostView addSubview:panel];
            }
        } @catch (NSException *exception) {
            // UIKit refused the insert; the camera keeps working with the panel
            // unmounted.
        }
    }

    UIButton *trigger = PS16TriggerFor(controller);

    if (trigger != nil && trigger.superview != hostView) {
        [hostView addSubview:trigger];
    }

    if (!PS16ModeSupportsStyles(controller)) {
        panel.hidden = YES;
        trigger.hidden = YES;
        // Deactivate, not just hide: the frame loop sets hidden = NO on every
        // rendered frame, so hiding only would pop the overlay back on.
        [[PS16LivePreviewView sharedView] setActive:NO];
        return;
    }

    PS16LayoutPanel(panel, hostView);
    PS16LayoutTrigger(trigger, hostView);

    if (sync) {
        [panel refreshFromEngine];

        // A fresh mount always starts expanded; the trigger only appears once
        // the user has collapsed the panel.
        if (trigger.hidden && panel.hidden) {
            panel.hidden = NO;
        }
    }

    PS16UpdateLivePreview(controller);
}

#pragma mark - Live preview mounting

static void PS16UpdateLivePreview(UIViewController *controller)
{
    UIView *hostView = controller.view;
    CAMPreviewView *preview = PS16PreviewViewOf(controller);

    if (preview == nil || hostView == nil) {
        return;
    }

    PS16LivePreviewView *live = [PS16LivePreviewView sharedView];
    PS16ControlPanelView *panel = PS16PanelFor(controller);
    UIButton *trigger = PS16TriggerFor(controller);

    // Host the filtered frame *inside* the viewfinder, not beside it: the stock
    // preview view is nested and often transformed, so a sibling with
    // preview.frame in host coordinates lands in the wrong place. As a child it
    // inherits the crop, the 3:4 aspect and every rotation for free.
    if (live.superview != preview) {
        @try {
            live.frame = preview.bounds;
            live.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [preview addSubview:live];
        } @catch (NSException *exception) {
            return;
        }
    } else if (!CGRectEqualToRect(live.frame, preview.bounds)) {
        live.frame = preview.bounds;
    }

    // CameraUI re-adds its own preview layer on every mode/layout change, which
    // would bury the overlay; keep it on top of the viewfinder's own layer.
    [preview bringSubviewToFront:live];

    // Keep the UI above the opaque preview frame after every re-mount.
    if (panel != nil && panel.superview == hostView) {
        [hostView bringSubviewToFront:panel];
    }

    if (trigger != nil && trigger.superview == hostView) {
        [hostView bringSubviewToFront:trigger];
    }

    [live attachToPreviewLayer:PS16VideoLayerOf(preview)];

    // Stays on while a style is actually doing something, not only while the
    // panel is open: the user expects to keep seeing the graded frame after
    // collapsing the panel. Bypass / Style 0 hand the viewfinder back untouched
    // instead of burning A7 GPU on a pass-through render.
    PS16ColorEngine *engine = [PS16ColorEngine sharedEngine];

    [live setActive:(engine.style > 0.0 && !engine.isBypassed)];
}

#pragma mark - Capture baking

static void PS16BakeCaptureResponse(CAMStillImageCaptureResponse *response)
{
    if (response == nil) {
        return;
    }

    PS16ColorEngine *engine = [PS16ColorEngine sharedEngine];

    if (engine.isBypassed || engine.style <= 0.0) {
        return;
    }

    // Deferred responses are unfinished stand-ins; the real still arrives later
    // through the same callback and gets processed then.
    id deferred = PS16Value(response, @"deferredProcessingRequired");

    if ([deferred isKindOfClass:[NSNumber class]] && [deferred boolValue]) {
        return;
    }

    @autoreleasepool {
        UIImage *source = nil;
        id imageValue = PS16Value(response, @"image");

        if ([imageValue isKindOfClass:[UIImage class]]) {
            source = (UIImage *)imageValue;
        }

        if (source == nil) {
            id dataValue = PS16Value(response, @"imageData");

            if ([dataValue isKindOfClass:[NSData class]] && [(NSData *)dataValue length] > 0) {
                @try {
                    source = [UIImage imageWithData:(NSData *)dataValue];
                } @catch (NSException *exception) {
                    source = nil;
                }
            }
        }

        if (source == nil) {
            return;
        }

        UIImage *processed = [engine processCapturedImage:source];

        if (processed == nil) {
            return;
        }

        PS16SetValue(response, @"image", processed);
        // The engine bakes the orientation into the pixels, so the result is
        // upright and EXIF orientation 1 is the matching value.
        PS16SetValue(response, @"imageOrientation", @(1));

        // Shutter thumbnail: leaving it unfiltered would flash the old look
        // right after the shot.
        id previewValue = PS16Value(response, @"previewImage");

        if ([previewValue isKindOfClass:[UIImage class]]) {
            UIImage *previewProcessed = [engine processCapturedImage:(UIImage *)previewValue];

            if (previewProcessed != nil) {
                PS16SetValue(response, @"previewImage", previewProcessed);
            }
        }

        // The saved file comes from imageData where it was already encoded, so
        // -image alone would not change what lands in the Photo Library.
        id dataValue = PS16Value(response, @"imageData");

        if ([dataValue isKindOfClass:[NSData class]] && [(NSData *)dataValue length] > 0) {
            NSData *encoded = UIImageJPEGRepresentation(processed, 0.95);

            if (encoded != nil) {
                PS16SetValue(response, @"imageData", encoded);
            }
        }
    }
}

#pragma mark - Hooks

%group PS16ViewfinderGroup

%hook CAMViewfinderViewController

- (void)viewDidLoad
{
    %orig;
    PS16Mount(self, YES);
}

- (void)viewDidLayoutSubviews
{
    %orig;
    // Rotations and mode switches change the host bounds; the style itself is
    // untouched by layout.
    PS16Mount(self, NO);
}

- (void)viewDidAppear:(BOOL)animated
{
    %orig;
    // The preview layer is recreated when the session restarts (camera switch,
    // photo -> video), so the live view has to be re-pointed at it.
    PS16Mount(self, YES);
}

%end

%end

// The capture delegate exists in two spellings across 12.x builds. Each one
// lives in its own group and is only %init'd when the running class actually
// implements it: hooking a missing selector leaves Logos with a NULL original
// IMP, and %orig would jump to address 0 the first time it fired.

%group PS16CaptureGeneratedGroup

%hook CAMViewfinderViewController

- (void)captureController:(id)captureController
    didGenerateStillImageCaptureResponse:(CAMStillImageCaptureResponse *)response
{
    // Before %orig: CameraUI's own handler is what persists the still.
    PS16BakeCaptureResponse(response);
    %orig;
}

%end

%end

%group PS16CaptureOutputGroup

%hook CAMViewfinderViewController

- (void)captureController:(id)captureController
    didOutputStillImageCaptureResponse:(CAMStillImageCaptureResponse *)response
{
    PS16BakeCaptureResponse(response);
    %orig;
}

%end

%end

%ctor
{
    // CameraUI is a hard dependency of the Camera binary, so its classes are
    // registered before this constructor runs. Probing first keeps a nil class
    // out of MSHookMessageEx, which would otherwise be a load-time crash.
    Class cameraClass = objc_getClass("CAMViewfinderViewController");

    if (cameraClass == Nil) {
        return;
    }

    %init(PS16ViewfinderGroup);

    if (class_getInstanceMethod(cameraClass, @selector(captureController:didGenerateStillImageCaptureResponse:)) != NULL) {
        %init(PS16CaptureGeneratedGroup);
    }

    if (class_getInstanceMethod(cameraClass, @selector(captureController:didOutputStillImageCaptureResponse:)) != NULL) {
        %init(PS16CaptureOutputGroup);
    }
}

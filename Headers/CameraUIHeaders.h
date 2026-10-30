//
//  CameraUIHeaders.h
//  PhotographicStyles16
//
//  Private CameraUI.framework surface used by the tweak, declared by hand so the
//  project builds against the public iOS 12.0 SDK while still talking to classes
//  that only exist inside the stock Camera app.
//
//  Every class here is resolved at runtime with objc_getClass("..."): writing
//  [CAMPreviewView class] would emit an OBJC_CLASS_$_CAMPreviewView reference
//  the Camera binary never exports, which is an undefined symbol at link time.
//
//  Everything below is used defensively: callers must check
//  -respondsToSelector: / -isKindOfClass: and wrap KVC in @try/@catch.
//

#ifndef PS16_CAMERAUI_HEADERS_H
#define PS16_CAMERAUI_HEADERS_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - CameraUI: CAMPreviewView

/// The live viewfinder host view. The actual video surface is a sublayer owned by
/// AVFoundation, which is why the shorthand preview-view itself cannot be
/// filtered in place.
@interface CAMPreviewView : UIView

/// The layer that owns the video surface; equal to -videoPreviewLayer in most
/// iOS 12 configurations and to a plain container layer while the session warms
/// up.
@property (nullable, nonatomic, strong) CALayer *previewLayer;

/// AVFoundation preview layer when the session is running, nil for stills-only.
@property (nullable, nonatomic, strong) AVCaptureVideoPreviewLayer *videoPreviewLayer;

/// Bounds of the letterboxed video area inside the view, in view coordinates.
- (CGRect)previewBounds;

@end

#pragma mark - CameraUI: CAMCaptureResponse / CAMStillImageCaptureResponse

@interface CAMCaptureResponse : NSObject

@property (nonatomic, assign) long long uniqueIdentifier;
@property (nullable, nonatomic, strong) NSDate *captureDate;

@end

/// Wraps one finished still capture. The Camera app hands this to
/// CAMViewfinderViewController before it reaches the Photos library, so mutating
/// -image / -previewImage / -imageData here is what bakes the style into the
/// saved photo.
///
/// Declared read-write: some 12.x builds expose these as readonly properties
/// backed by a private ivar, so the capture path always probes with
/// -respondsToSelector: and falls back to setValue:forKey: inside @try/@catch.
@interface CAMStillImageCaptureResponse : CAMCaptureResponse

/// Full resolution still, already oriented.
@property (nullable, nonatomic, copy) UIImage *image;

/// Downscaled still used for the shutter thumbnail animation.
@property (nullable, nonatomic, copy) UIImage *previewImage;

/// Encoded JPEG that will be written to disk.
@property (nullable, nonatomic, copy) NSData *imageData;

/// EXIF orientation of -image.
@property (nonatomic, assign) NSInteger imageOrientation;

/// The CAMStillImageCaptureRequest that produced this response.
@property (nullable, nonatomic, strong) id captureRequest;

/// YES when the response is a stub awaiting deferred processing.
@property (nonatomic, assign, getter=isDeferredProcessingRequired) BOOL deferredProcessingRequired;

@end

#pragma mark - CameraUI: CAMViewfinderViewController

/// Full screen Camera UI controller: owns the preview view and the shutter.
@interface CAMViewfinderViewController : UIViewController

/// The viewfinder, available once -viewDidLoad has run.
@property (nullable, nonatomic, readonly) CAMPreviewView *previewView;

/// Shutter entry points. iOS 12 funnels the hardware and on-screen buttons
/// through the "released" variant; both are declared so a hook can pick
/// whichever exists on the running build.
- (void)captureStillImage;
- (void)_captureStillImage;
- (void)_handleShutterButtonPressed:(nullable id)sender;
- (void)_handleShutterButtonReleased:(nullable id)sender;

/// Capture controller delegate callback that delivers the finished still.
- (void)captureController:(nullable id)captureController
    didGenerateStillImageCaptureResponse:(nullable CAMStillImageCaptureResponse *)response;

/// Older 12.x builds route the same event through this selector.
- (void)captureController:(nullable id)captureController
    didOutputStillImageCaptureResponse:(nullable CAMStillImageCaptureResponse *)response;

@end

NS_ASSUME_NONNULL_END

#endif /* PS16_CAMERAUI_HEADERS_H */

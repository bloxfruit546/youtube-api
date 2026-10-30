//
//  PS16ColorEngine.h
//  PhotographicStyles16
//
//  One Metal-backed CIContext, one reusable CIFilter chain, five presets.
//  Parameters are read behind os_unfair_lock so the UI can write them from the
//  main thread while the capture queue renders.
//

#ifndef PS16_COLOR_ENGINE_H
#define PS16_COLOR_ENGINE_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSInteger const PS16PresetCount;   // 5

/// "Standard", "Pearl", "Rose Gold", "Contrast", "Amber". Never nil.
FOUNDATION_EXPORT NSString *PS16PresetName(NSInteger preset);

/// Two-stop gradient that identifies a preset in the rail / pad / slider.
/// Always two colours, dark stop first.
FOUNDATION_EXPORT NSArray<UIColor *> *PS16PresetGradient(NSInteger preset);

@class PS16ControlPanelView;

@interface PS16ColorEngine : NSObject

+ (instancetype)sharedEngine;

/// 0..100, default 50. Y axis of the pad.
@property (nonatomic, assign) CGFloat bright;

/// 0..100, default 50. X axis of the pad.
@property (nonatomic, assign) CGFloat color;

/// 0..100, default 100. Intensity slider.
@property (nonatomic, assign) CGFloat style;

/// 0..4, default 0.
@property (nonatomic, assign) NSInteger preset;

/// YES while "Reconc" is engaged: the pipeline returns the source untouched.
@property (nonatomic, assign, getter=isBypassed) BOOL bypassed;

/// Applies the whole chain. Returns the source unchanged when bypassed or when
/// style == 0, so the caller never pays for an identity render.
- (CIImage *)filteredImage:(nullable CIImage *)source;

/// Bakes the style into a captured still. Honours the UIImage's own orientation
/// and returns nil only if Core Image fails outright.
- (nullable UIImage *)processCapturedImage:(nullable UIImage *)image;

/// Restores Bright 50 / Color 50 / Style 100.
- (void)resetParameters;

/// The one context the process owns, so the live preview renders through the
/// same GPU pipeline as the stills instead of allocating a second one.
@property (nonatomic, strong, readonly) CIContext *renderingContext;

@end

NS_ASSUME_NONNULL_END

#endif /* PS16_COLOR_ENGINE_H */

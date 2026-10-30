//
//  PS16IntensitySlider.h
//  PhotographicStyles16
//
//  150 x 20 capsule: white -> preset-colour track with a black thumb.
//  Maps X to Style (0..100).
//

#ifndef PS16_INTENSITY_SLIDER_H
#define PS16_INTENSITY_SLIDER_H

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class PS16IntensitySlider;

@protocol PS16IntensitySliderDelegate <NSObject>
@optional
- (void)intensitySlider:(PS16IntensitySlider *)slider didChangeStyle:(CGFloat)style;
- (void)intensitySlider:(PS16IntensitySlider *)slider didChangeInteracting:(BOOL)interacting;
@end

@interface PS16IntensitySlider : UIView

@property (nullable, nonatomic, weak) id<PS16IntensitySliderDelegate> delegate;

/// 0..100. Default 100.
@property (nonatomic, assign) CGFloat style;

- (void)setStyle:(CGFloat)style animated:(BOOL)animated;

/// Recolours the right-hand end of the track (the preset's accent colour).
- (void)setAccentColor:(UIColor *)color;

@end

NS_ASSUME_NONNULL_END

#endif /* PS16_INTENSITY_SLIDER_H */

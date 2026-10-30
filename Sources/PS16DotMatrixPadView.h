//
//  PS16DotMatrixPadView.h
//  PhotographicStyles16
//
//  11x11 dot matrix with a magnetic cluster that swells around the puck.
//  X axis -> Colour (0..100), Y axis (up) -> Bright (0..100).
//

#ifndef PS16_DOT_MATRIX_PAD_VIEW_H
#define PS16_DOT_MATRIX_PAD_VIEW_H

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class PS16DotMatrixPadView;

@protocol PS16DotMatrixPadViewDelegate <NSObject>
@optional
/// Fires on every touch move; both values are already in 0..100.
- (void)dotMatrixPadView:(PS16DotMatrixPadView *)padView
          didChangeBright:(CGFloat)bright
                   color:(CGFloat)color;
/// Fires on touch down and on touch up, so the owner can show / schedule-hide
/// the HUD strip.
- (void)dotMatrixPadView:(PS16DotMatrixPadView *)padView didChangeInteracting:(BOOL)interacting;
@end

@interface PS16DotMatrixPadView : UIView

@property (nullable, nonatomic, weak) id<PS16DotMatrixPadViewDelegate> delegate;

/// 0..100, plotted bottom-to-top.
@property (nonatomic, assign) CGFloat bright;

/// 0..100, plotted left-to-right.
@property (nonatomic, assign) CGFloat color;

/// Moves the puck to the given coordinates. Animated when `animated` is YES.
- (void)setBright:(CGFloat)bright color:(CGFloat)color animated:(BOOL)animated;

/// Recolours the background gradient (two stops, dark first).
- (void)setGradientColors:(NSArray<UIColor *> *)colors;

@end

NS_ASSUME_NONNULL_END

#endif /* PS16_DOT_MATRIX_PAD_VIEW_H */

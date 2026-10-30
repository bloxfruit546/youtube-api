//
//  PS16ControlPanelView.h
//  PhotographicStyles16
//
//  The whole Photographic Styles panel: HUD strip, floating preset pill, preset
//  rail, dot pad, Reconc toggle, intensity slider, collapse and reset buttons.
//  Owns no engine state of its own beyond the layout — it reads and writes
//  PS16ColorEngine directly.
//

#ifndef PS16_CONTROL_PANEL_VIEW_H
#define PS16_CONTROL_PANEL_VIEW_H

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PS16ControlPanelView : UIView

/// Fired whenever Bright / Color / Style / preset / bypass changed, so the
/// caller can push a fresh frame to the live preview.
@property (nullable, nonatomic, copy) void (^onParametersChanged)(void);

/// Fired when the user taps the collapse chevron.
@property (nullable, nonatomic, copy) void (^onCollapseRequested)(void);

/// YES once the panel has been collapsed by the user.
@property (nonatomic, assign, readonly, getter=isCollapsed) BOOL collapsed;

/// Re-reads the engine and repaints every control. Call after an external
/// change (preset picked from elsewhere, engine reset).
- (void)refreshFromEngine;

/// Animates the panel onto the screen (slide up + fade).
- (void)showAnimated:(BOOL)animated;

/// Animates the panel off the screen (slide down + fade).
- (void)hideAnimated:(BOOL)animated;

/// YES while any control is being touched, so the camera can suppress its own
/// focus reticle if it wants to.
@property (nonatomic, assign, readonly, getter=isInteracting) BOOL interacting;

@end

NS_ASSUME_NONNULL_END

#endif /* PS16_CONTROL_PANEL_VIEW_H */

//
//  PS16ControlPanelView.m
//  PhotographicStyles16
//
//  Everything is laid out from self.bounds in -layoutSubviews, so the same code
//  produces the spec's 320 pt geometry on the iPhone 5s and stays centred on the
//  4.7" / 5.5" iOS 12 devices.
//
//  Panel height budget (320 x 568 pt):
//      HUD strip 28 | gap 8 | content 172 | gap 8 | slider 20 | gap 8 | buttons 30
//      + 10 bottom padding = 284 pt.
//

#import "PS16ControlPanelView.h"

#import "PS16ColorEngine.h"
#import "PS16DotMatrixPadView.h"
#import "PS16IntensitySlider.h"

#import <QuartzCore/QuartzCore.h>
#import <math.h>

// Height lives in Tweak.x (the panel is framed from the host view there);
// repeating it here would be a second copy with no reader.
static const CGFloat kPS16HUDRowHeight = 28.0;
static const CGFloat kPS16RailCellSize = 28.0;
static const CGFloat kPS16RailSpacing = 8.0;
static const CGFloat kPS16PadSize = 150.0;
static const CGFloat kPS16ReconcSize = 44.0;
static const CGFloat kPS16GroupGap = 12.0;
static const CGFloat kPS16SliderWidth = 150.0;
static const CGFloat kPS16SliderHeight = 20.0;
static const CGFloat kPS16SmallButtonSize = 30.0;
static const CGFloat kPS16SideMargin = 12.0;
static const CGFloat kPS16HUDHideDelay = 1.0;
static const CGFloat kPS16PillHideDelay = 1.2;

#pragma mark - Glyph button

typedef NS_ENUM(NSInteger, PS16Glyph) {
    PS16GlyphChevronDown = 0,
    PS16GlyphReset = 1,
};

/// Vector glyphs only: SF Symbols are iOS 13+, and bundling PNGs for two icons
/// is more moving parts than two UIBezierPath calls.
@interface PS16GlyphButton : UIButton

@property (nonatomic, assign) PS16Glyph glyph;

@end

@implementation PS16GlyphButton

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.2];
        self.opaque = NO;
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    self.layer.cornerRadius = MIN(self.bounds.size.width, self.bounds.size.height) * 0.5;
}

- (void)setGlyph:(PS16Glyph)glyph
{
    _glyph = glyph;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect
{
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    if (ctx == NULL) {
        return;
    }

    CGRect bounds = self.bounds;
    CGPoint center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    CGFloat unit = MIN(bounds.size.width, bounds.size.height);

    CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextSetLineWidth(ctx, MAX(1.5, unit * 0.07));
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);

    if (self.glyph == PS16GlyphChevronDown) {
        CGFloat half = unit * 0.20;
        CGFloat rise = unit * 0.13;

        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(center.x - half, center.y - rise)];
        [path addLineToPoint:CGPointMake(center.x, center.y + rise)];
        [path addLineToPoint:CGPointMake(center.x + half, center.y - rise)];
        [path stroke];
    } else {
        CGFloat radius = unit * 0.26;
        CGFloat startAngle = (CGFloat)(-M_PI * 0.35);
        CGFloat endAngle = (CGFloat)(M_PI * 1.45);

        UIBezierPath *arc = [UIBezierPath bezierPathWithArcCenter:center
                                                          radius:radius
                                                      startAngle:startAngle
                                                        endAngle:endAngle
                                                       clockwise:YES];
        [arc stroke];

        // Arrow head at the arc's end, pointing along the tangent.
        CGPoint tip = CGPointMake(center.x + radius * cos(endAngle),
                                  center.y + radius * sin(endAngle));
        CGFloat head = unit * 0.13;

        UIBezierPath *arrow = [UIBezierPath bezierPath];
        [arrow moveToPoint:CGPointMake(tip.x - head, tip.y - head * 0.4)];
        [arrow addLineToPoint:tip];
        [arrow addLineToPoint:CGPointMake(tip.x + head * 0.5, tip.y - head * 1.2)];
        [arrow stroke];
    }
}

- (void)setHighlighted:(BOOL)highlighted
{
    [super setHighlighted:highlighted];
    self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:(highlighted ? 0.34 : 0.2)];
}

@end

#pragma mark - Preset rail

@protocol PS16PresetRailDelegate <NSObject>
- (void)presetRail:(id)rail didSelectPreset:(NSInteger)preset;
@end

/// Vertical column of five gradient swatches. Lives here rather than in its own
/// file because nothing else needs it.
@interface PS16PresetRailView : UIView

@property (nonatomic, assign) NSInteger selectedPreset;
@property (nullable, nonatomic, weak) id<PS16PresetRailDelegate> delegate;

- (void)setSelectedPreset:(NSInteger)preset animated:(BOOL)animated;

@end

@implementation PS16PresetRailView {
    NSMutableArray<UIView *> *_cells;
    NSMutableArray<CAGradientLayer *> *_gradients;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _selectedPreset = 0;
        _cells = [NSMutableArray arrayWithCapacity:PS16PresetCount];
        _gradients = [NSMutableArray arrayWithCapacity:PS16PresetCount];
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;

        for (NSInteger index = 0; index < PS16PresetCount; index++) {
            UIView *cell = [[UIView alloc] initWithFrame:CGRectZero];
            cell.layer.cornerRadius = 6.0;
            cell.layer.masksToBounds = YES;
            cell.layer.borderWidth = 0.0;
            cell.layer.borderColor = [UIColor whiteColor].CGColor;

            CAGradientLayer *gradient = [CAGradientLayer layer];
            gradient.startPoint = CGPointMake(0.0, 0.0);
            gradient.endPoint = CGPointMake(1.0, 1.0);
            NSArray<UIColor *> *stops = PS16PresetGradient(index);
            gradient.colors = @[ (id)stops[0].CGColor, (id)stops[1].CGColor ];
            [cell.layer addSublayer:gradient];

            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                                 action:@selector(ps16_cellTapped:)];
            [cell addGestureRecognizer:tap];

            // Index travels on the cell's tag so one target-action serves all
            // five cells.
            cell.tag = index;

            [self addSubview:cell];
            [_cells addObject:cell];
            [_gradients addObject:gradient];
        }

        [self ps16_updateSelectionBorders];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    CGSize cellSize = CGSizeMake(MIN(kPS16RailCellSize, self.bounds.size.width),
                                 MIN(kPS16RailCellSize, self.bounds.size.width));

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    for (NSInteger index = 0; index < (NSInteger)_cells.count; index++) {
        UIView *cell = _cells[index];
        cell.frame = CGRectMake((self.bounds.size.width - cellSize.width) * 0.5,
                                index * (cellSize.height + kPS16RailSpacing),
                                cellSize.width,
                                cellSize.height);
        _gradients[index].frame = cell.bounds;
    }

    [CATransaction commit];
    [self ps16_updateSelectionBorders];
}

- (void)ps16_updateSelectionBorders
{
    for (NSInteger index = 0; index < (NSInteger)_cells.count; index++) {
        UIView *cell = _cells[index];
        BOOL selected = (index == self.selectedPreset);

        cell.layer.borderWidth = selected ? 2.5 : 0.0;
        cell.layer.borderColor = [UIColor whiteColor].CGColor;
    }
}

- (void)ps16_cellTapped:(UITapGestureRecognizer *)tap
{
    NSInteger index = tap.view.tag;

    if (index == self.selectedPreset) {
        return;
    }

    [self setSelectedPreset:index animated:YES];

    id<PS16PresetRailDelegate> delegate = self.delegate;

    if ([delegate respondsToSelector:@selector(presetRail:didSelectPreset:)]) {
        [delegate presetRail:self didSelectPreset:index];
    }
}

- (void)setSelectedPreset:(NSInteger)preset
{
    [self setSelectedPreset:preset animated:NO];
}

- (void)setSelectedPreset:(NSInteger)preset animated:(BOOL)animated
{
    _selectedPreset = MAX(0, MIN(PS16PresetCount - 1, preset));

    if (!animated) {
        [self ps16_updateSelectionBorders];
        return;
    }

    [UIView animateWithDuration:0.18
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                     animations:^{
        [self ps16_updateSelectionBorders];
    } completion:nil];
}

@end

#pragma mark - Control panel

@interface PS16ControlPanelView () <PS16DotMatrixPadViewDelegate, PS16IntensitySliderDelegate, PS16PresetRailDelegate> {
    NSUInteger _hudGeneration;
    NSUInteger _pillGeneration;
    BOOL _interacting;
    BOOL _collapsed;
}

@property (nonatomic, strong) UIView *hudStrip;
@property (nonatomic, strong) UILabel *brightValueLabel;
@property (nonatomic, strong) UILabel *colorValueLabel;
@property (nonatomic, strong) UILabel *styleValueLabel;

@property (nonatomic, strong) UIView *pillBadge;
@property (nonatomic, strong) UILabel *pillLabel;

@property (nonatomic, strong) UIView *railContainer;
@property (nonatomic, strong) PS16PresetRailView *railView;
@property (nonatomic, strong) PS16DotMatrixPadView *padView;
@property (nonatomic, strong) PS16IntensitySlider *sliderView;
@property (nonatomic, strong) UIButton *reconcButton;
@property (nonatomic, strong) PS16GlyphButton *collapseButton;
@property (nonatomic, strong) PS16GlyphButton *resetButton;

- (void)ps16_commonInit;
- (void)ps16_buildHUD;
- (void)ps16_buildPill;
- (void)ps16_buildRail;
- (void)ps16_buildPad;
- (void)ps16_buildSlider;
- (void)ps16_buildReconcButton;
- (void)ps16_buildActionButtons;

- (UILabel *)ps16_makeLabel:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight;
- (CGSize)pillSizeForText:(NSString *)text;
- (void)ps16_showHUDBriefly;
- (void)ps16_hideHUD;
- (void)ps16_showPillWithText:(NSString *)text;
- (void)ps16_applyPreset:(NSInteger)preset announce:(BOOL)announce;
- (void)ps16_pushParameters;
- (void)ps16_syncHUDFromEngine;
- (void)ps16_syncControlsFromEngine;
- (void)ps16_reconcTapped;
- (void)ps16_collapseTapped;
- (void)ps16_resetTapped;

@end

@implementation PS16ControlPanelView

#pragma mark - Lifetime

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        [self ps16_commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        [self ps16_commonInit];
    }
    return self;
}

- (void)ps16_commonInit
{
    _interacting = NO;
    _collapsed = NO;

    self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.92];
    self.opaque = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    self.layer.cornerRadius = 18.0;
    self.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    self.layer.masksToBounds = NO;

    [self ps16_buildHUD];
    [self ps16_buildPill];
    [self ps16_buildRail];
    [self ps16_buildPad];
    [self ps16_buildSlider];
    [self ps16_buildReconcButton];
    [self ps16_buildActionButtons];

    [self refreshFromEngine];
}

#pragma mark - Builders

- (UILabel *)ps16_makeLabel:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight
{
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];

    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.backgroundColor = [UIColor clearColor];

    return label;
}

- (void)ps16_buildHUD
{
    UIView *strip = [[UIView alloc] initWithFrame:CGRectZero];
    strip.backgroundColor = [UIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.65];
    strip.alpha = 0.0;
    strip.userInteractionEnabled = NO;

    UILabel *bright = [self ps16_makeLabel:@"Bright: 50" size:12.0 weight:UIFontWeightBold];
    UILabel *color = [self ps16_makeLabel:@"Color: 50" size:12.0 weight:UIFontWeightBold];
    UILabel *style = [self ps16_makeLabel:@"Style: 100" size:12.0 weight:UIFontWeightBold];

    bright.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    color.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    style.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    [strip addSubview:bright];
    [strip addSubview:color];
    [strip addSubview:style];

    [self addSubview:strip];

    self.hudStrip = strip;
    self.brightValueLabel = bright;
    self.colorValueLabel = color;
    self.styleValueLabel = style;
}

- (void)ps16_buildPill
{
    UIView *badge = [[UIView alloc] initWithFrame:CGRectZero];
    badge.backgroundColor = [UIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.7];
    badge.layer.cornerRadius = 6.0;
    badge.alpha = 0.0;
    badge.userInteractionEnabled = NO;

    UILabel *label = [self ps16_makeLabel:@"Standard" size:13.0 weight:UIFontWeightMedium];

    [badge addSubview:label];
    [self addSubview:badge];

    self.pillBadge = badge;
    self.pillLabel = label;
}

- (void)ps16_buildRail
{
    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.backgroundColor = [UIColor clearColor];

    PS16PresetRailView *rail = [[PS16PresetRailView alloc] initWithFrame:CGRectZero];
    rail.delegate = self;

    [container addSubview:rail];
    [self addSubview:container];

    self.railContainer = container;
    self.railView = rail;
}

- (void)ps16_buildPad
{
    PS16DotMatrixPadView *pad = [[PS16DotMatrixPadView alloc] initWithFrame:CGRectZero];

    pad.delegate = self;
    [self addSubview:pad];

    self.padView = pad;
}

- (void)ps16_buildSlider
{
    PS16IntensitySlider *slider = [[PS16IntensitySlider alloc] initWithFrame:CGRectZero];

    slider.delegate = self;
    [self addSubview:slider];

    self.sliderView = slider;
}

- (void)ps16_buildReconcButton
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];

    button.frame = CGRectZero;
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    button.layer.cornerRadius = kPS16ReconcSize * 0.5;
    button.titleLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.8;
    [button setTitle:@"Reconc" forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [button addTarget:self
               action:@selector(ps16_reconcTapped)
     forControlEvents:UIControlEventTouchUpInside];

    [self addSubview:button];
    self.reconcButton = button;
}

- (void)ps16_buildActionButtons
{
    PS16GlyphButton *collapse = [[PS16GlyphButton alloc] initWithFrame:CGRectZero];
    collapse.glyph = PS16GlyphChevronDown;
    [collapse addTarget:self
                 action:@selector(ps16_collapseTapped)
       forControlEvents:UIControlEventTouchUpInside];

    PS16GlyphButton *reset = [[PS16GlyphButton alloc] initWithFrame:CGRectZero];
    reset.glyph = PS16GlyphReset;
    [reset addTarget:self
              action:@selector(ps16_resetTapped)
    forControlEvents:UIControlEventTouchUpInside];

    [self addSubview:collapse];
    [self addSubview:reset];

    self.collapseButton = collapse;
    self.resetButton = reset;
}

#pragma mark - Layout

- (void)layoutSubviews
{
    [super layoutSubviews];

    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;

    if (width < 1.0 || height < 1.0) {
        return;
    }

    // The three-column band is centred as a group, so the rail's left margin
    // equals the Reconc button's right margin on every screen width.
    CGFloat groupWidth = kPS16RailCellSize + kPS16GroupGap + kPS16PadSize + kPS16GroupGap + kPS16ReconcSize;
    CGFloat left = floorf((width - groupWidth) * 0.5);

    CGFloat contentTop = kPS16HUDRowHeight + 8.0;
    CGFloat contentHeight = MAX(kPS16PadSize, PS16PresetCount * kPS16RailCellSize + (PS16PresetCount - 1) * kPS16RailSpacing);

    self.hudStrip.frame = CGRectMake(0.0, 0.0, width, kPS16HUDRowHeight);

    CGFloat third = width / 3.0;
    self.brightValueLabel.frame = CGRectMake(0.0, 0.0, third, kPS16HUDRowHeight);
    self.colorValueLabel.frame = CGRectMake(third, 0.0, third, kPS16HUDRowHeight);
    self.styleValueLabel.frame = CGRectMake(third * 2.0, 0.0, third, kPS16HUDRowHeight);

    self.railContainer.frame = CGRectMake(left, contentTop, kPS16RailCellSize, contentHeight);
    self.railView.frame = self.railContainer.bounds;

    self.padView.frame = CGRectMake(left + kPS16RailCellSize + kPS16GroupGap,
                                    contentTop + (contentHeight - kPS16PadSize) * 0.5,
                                    kPS16PadSize,
                                    kPS16PadSize);

    self.reconcButton.frame = CGRectMake(left + kPS16RailCellSize + kPS16GroupGap + kPS16PadSize + kPS16GroupGap,
                                         contentTop + (contentHeight - kPS16ReconcSize) * 0.5,
                                         kPS16ReconcSize,
                                         kPS16ReconcSize);

    CGFloat sliderTop = contentTop + contentHeight + 8.0;
    self.sliderView.frame = CGRectMake(self.padView.frame.origin.x,
                                       sliderTop,
                                       kPS16SliderWidth,
                                       kPS16SliderHeight);

    CGFloat buttonTop = sliderTop + kPS16SliderHeight + 8.0;
    self.collapseButton.frame = CGRectMake(kPS16SideMargin, buttonTop,
                                           kPS16SmallButtonSize, kPS16SmallButtonSize);
    self.resetButton.frame = CGRectMake(width - kPS16SideMargin - kPS16SmallButtonSize, buttonTop,
                                        kPS16SmallButtonSize, kPS16SmallButtonSize);

    // Pill badge floats just above the panel's top edge, centred on the pad.
    CGSize pillSize = [self pillSizeForText:self.pillLabel.text ?: @""];
    self.pillBadge.frame = CGRectMake((width - pillSize.width) * 0.5,
                                      -pillSize.height - 6.0,
                                      pillSize.width,
                                      pillSize.height);
    self.pillLabel.frame = CGRectMake(10.0, 0.0, pillSize.width - 20.0, pillSize.height);
}

- (CGSize)pillSizeForText:(NSString *)text
{
    UIFont *font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    CGSize measured = [text sizeWithAttributes:@{ NSFontAttributeName: font }];

    return CGSizeMake(ceil(measured.width) + 20.0, 24.0);
}

#pragma mark - Public

- (BOOL)isCollapsed
{
    return _collapsed;
}

- (BOOL)isInteracting
{
    return _interacting;
}

- (void)refreshFromEngine
{
    [self ps16_syncControlsFromEngine];
    [self ps16_syncHUDFromEngine];
}

- (void)showAnimated:(BOOL)animated
{
    _collapsed = NO;

    if (!animated) {
        self.alpha = 1.0;
        return;
    }

    [self.layer removeAllAnimations];
    self.alpha = 0.0;
    [UIView animateWithDuration:0.24
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.alpha = 1.0;
    } completion:nil];
}

- (void)hideAnimated:(BOOL)animated
{
    _collapsed = YES;

    if (!animated) {
        self.alpha = 0.0;
        return;
    }

    [UIView animateWithDuration:0.24
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.alpha = 0.0;
    } completion:nil];
}

#pragma mark - HUD

- (void)ps16_syncHUDFromEngine
{
    PS16ColorEngine *engine = [PS16ColorEngine sharedEngine];

    self.brightValueLabel.text = [NSString stringWithFormat:@"Bright: %d", (int)lround(engine.bright)];
    self.colorValueLabel.text = [NSString stringWithFormat:@"Color: %d", (int)lround(engine.color)];
    self.styleValueLabel.text = [NSString stringWithFormat:@"Style: %d", (int)lround(engine.style)];
}

- (void)ps16_showHUDBriefly
{
    _hudGeneration += 1;

    if (self.hudStrip.alpha < 1.0) {
        [UIView animateWithDuration:0.12
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.hudStrip.alpha = 1.0;
        } completion:nil];
    }
}

- (void)ps16_hideHUD
{
    // Generation counter: a re-touch during the delay bumps it, so a stale block
    // cannot hide a HUD the user is currently dragging.
    NSUInteger generation = _hudGeneration;

    __weak PS16ControlPanelView *weakSelf = self;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPS16HUDHideDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PS16ControlPanelView *strongSelf = weakSelf;

        if (strongSelf == nil || strongSelf->_hudGeneration != generation || strongSelf->_interacting) {
            return;
        }

        [UIView animateWithDuration:0.2
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                         animations:^{
            strongSelf.hudStrip.alpha = 0.0;
        } completion:nil];
    });
}

- (void)ps16_showPillWithText:(NSString *)text
{
    _pillGeneration += 1;
    NSUInteger generation = _pillGeneration;

    self.pillLabel.text = text;
    [self setNeedsLayout];
    [self layoutIfNeeded];

    [UIView animateWithDuration:0.14
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.pillBadge.alpha = 1.0;
    } completion:nil];

    __weak PS16ControlPanelView *weakSelf = self;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPS16PillHideDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PS16ControlPanelView *strongSelf = weakSelf;

        if (strongSelf == nil || strongSelf->_pillGeneration != generation) {
            return;
        }

        [UIView animateWithDuration:0.2
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                         animations:^{
            strongSelf.pillBadge.alpha = 0.0;
        } completion:nil];
    });
}

#pragma mark - Engine sync

- (void)ps16_pushParameters
{
    [self ps16_syncHUDFromEngine];

    void (^handler)(void) = self.onParametersChanged;

    if (handler != nil) {
        handler();
    }
}

- (void)ps16_syncControlsFromEngine
{
    PS16ColorEngine *engine = [PS16ColorEngine sharedEngine];
    NSInteger preset = engine.preset;

    self.railView.selectedPreset = preset;
    [self.padView setBright:engine.bright color:engine.color animated:NO];
    [self.sliderView setStyle:engine.style animated:NO];

    NSArray<UIColor *> *stops = PS16PresetGradient(preset);

    [self.padView setGradientColors:stops];
    [self.sliderView setAccentColor:stops[1]];

    self.reconcButton.backgroundColor = engine.isBypassed
        ? [UIColor colorWithWhite:1.0 alpha:0.42]
        : [UIColor colorWithWhite:1.0 alpha:0.2];

    self.pillLabel.text = PS16PresetName(preset);
    [self setNeedsLayout];
}

- (void)ps16_applyPreset:(NSInteger)preset announce:(BOOL)announce
{
    PS16ColorEngine *engine = [PS16ColorEngine sharedEngine];

    engine.preset = preset;

    NSArray<UIColor *> *stops = PS16PresetGradient(engine.preset);

    [self.railView setSelectedPreset:engine.preset animated:announce];
    [self.padView setGradientColors:stops];
    [self.sliderView setAccentColor:stops[1]];

    if (announce) {
        [self ps16_showPillWithText:PS16PresetName(engine.preset)];
    }

    [self ps16_pushParameters];
}

#pragma mark - Actions

- (void)ps16_reconcTapped
{
    PS16ColorEngine *engine = [PS16ColorEngine sharedEngine];

    engine.bypassed = !engine.isBypassed;

    [UIView animateWithDuration:0.16 animations:^{
        self.reconcButton.backgroundColor = engine.isBypassed
            ? [UIColor colorWithWhite:1.0 alpha:0.42]
            : [UIColor colorWithWhite:1.0 alpha:0.2];
    }];

    [self ps16_showPillWithText:engine.isBypassed ? @"Original" : PS16PresetName(engine.preset)];
    [self ps16_pushParameters];
}

- (void)ps16_collapseTapped
{
    void (^handler)(void) = self.onCollapseRequested;

    if (handler != nil) {
        handler();
    }
}

- (void)ps16_resetTapped
{
    PS16ColorEngine *engine = [PS16ColorEngine sharedEngine];

    [engine resetParameters];

    [self.padView setBright:engine.bright color:engine.color animated:YES];
    [self.sliderView setStyle:engine.style animated:YES];
    [self ps16_showPillWithText:PS16PresetName(engine.preset)];
    [self ps16_pushParameters];
}

#pragma mark - PS16DotMatrixPadViewDelegate

- (void)dotMatrixPadView:(PS16DotMatrixPadView *)padView
         didChangeBright:(CGFloat)bright
                  color:(CGFloat)color
{
    PS16ColorEngine *engine = [PS16ColorEngine sharedEngine];

    engine.bright = bright;
    engine.color = color;

    [self ps16_pushParameters];
}

- (void)dotMatrixPadView:(PS16DotMatrixPadView *)padView didChangeInteracting:(BOOL)interacting
{
    _interacting = interacting;

    if (interacting) {
        [self ps16_showHUDBriefly];
    } else {
        [self ps16_hideHUD];
    }
}

#pragma mark - PS16IntensitySliderDelegate

- (void)intensitySlider:(PS16IntensitySlider *)slider didChangeStyle:(CGFloat)style
{
    [PS16ColorEngine sharedEngine].style = style;
    [self ps16_pushParameters];
}

- (void)intensitySlider:(PS16IntensitySlider *)slider didChangeInteracting:(BOOL)interacting
{
    _interacting = interacting;

    if (interacting) {
        [self ps16_showHUDBriefly];
    } else {
        [self ps16_hideHUD];
    }
}

#pragma mark - PS16PresetRailDelegate

- (void)presetRail:(id)rail didSelectPreset:(NSInteger)preset
{
    [self ps16_applyPreset:preset announce:YES];
}

@end

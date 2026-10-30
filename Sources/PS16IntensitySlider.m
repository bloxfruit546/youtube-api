//
//  PS16IntensitySlider.m
//  PhotographicStyles16
//
//  The spec's "white -> preset colour" track plus a black thumb with a white
//  rim. Touch tracking is raw -touchesBegan/Moved/Ended rather than a control
//  subclass: one view, no target-action plumbing.
//

#import "PS16IntensitySlider.h"

#import <QuartzCore/QuartzCore.h>

static const CGFloat kPS16SliderCornerRadius = 10.0;
static const CGFloat kPS16ThumbSize = 16.0;

@interface PS16IntensitySlider () {
    UIColor *_accentColor;
}

@property (nonatomic, strong) CAGradientLayer *trackLayer;
@property (nonatomic, strong) UIView *thumb;
@property (nonatomic, assign) BOOL dragging;

- (void)ps16_commonInit;
- (CGFloat)ps16_thumbCenterX;
- (void)ps16_layoutThumbAnimated:(BOOL)animated;
- (void)ps16_applyPoint:(CGPoint)point notify:(BOOL)notify;
- (void)ps16_notifyInteracting:(BOOL)interacting;

@end

@implementation PS16IntensitySlider

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
    _style = 100.0;
    _accentColor = [UIColor colorWithWhite:0.92 alpha:1.0];

    self.backgroundColor = [UIColor clearColor];
    self.layer.cornerRadius = kPS16SliderCornerRadius;
    self.layer.borderWidth = 1.5;
    self.layer.borderColor = [UIColor whiteColor].CGColor;
    self.layer.masksToBounds = NO;

    _trackLayer = [CAGradientLayer layer];
    _trackLayer.startPoint = CGPointMake(0.0, 0.5);
    _trackLayer.endPoint = CGPointMake(1.0, 0.5);
    _trackLayer.cornerRadius = kPS16SliderCornerRadius;
    _trackLayer.masksToBounds = YES;
    _trackLayer.colors = @[
        (id)[UIColor whiteColor].CGColor,
        (id)[UIColor colorWithWhite:0.92 alpha:1.0].CGColor,
    ];
    [self.layer addSublayer:_trackLayer];

    _thumb = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, kPS16ThumbSize, kPS16ThumbSize)];
    _thumb.backgroundColor = [UIColor blackColor];
    _thumb.layer.cornerRadius = kPS16ThumbSize * 0.5;
    _thumb.layer.borderWidth = 1.5;
    _thumb.layer.borderColor = [UIColor whiteColor].CGColor;
    _thumb.userInteractionEnabled = NO;
    [self addSubview:_thumb];
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.trackLayer.frame = self.bounds;
    [CATransaction commit];

    [self ps16_layoutThumbAnimated:NO];
}

#pragma mark - Geometry

- (CGFloat)ps16_thumbCenterX
{
    CGFloat travel = self.bounds.size.width - kPS16ThumbSize;

    if (travel <= 0.0) {
        return self.bounds.size.width * 0.5;
    }

    return kPS16ThumbSize * 0.5 + (MAX(0.0, MIN(100.0, self.style)) / 100.0) * travel;
}

- (void)ps16_layoutThumbAnimated:(BOOL)animated
{
    CGFloat x = [self ps16_thumbCenterX];

    CGRect frame = CGRectMake(x - kPS16ThumbSize * 0.5,
                              (self.bounds.size.height - kPS16ThumbSize) * 0.5,
                              kPS16ThumbSize,
                              kPS16ThumbSize);

    if (animated) {
        [UIView animateWithDuration:0.22
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.thumb.frame = frame;
        } completion:nil];
    } else {
        self.thumb.frame = frame;
    }
}

- (void)ps16_applyPoint:(CGPoint)point notify:(BOOL)notify
{
    CGFloat travel = self.bounds.size.width - kPS16ThumbSize;
    CGFloat value = 100.0;

    if (travel > 0.0) {
        value = ((point.x - kPS16ThumbSize * 0.5) / travel) * 100.0;
    }

    _style = MAX(0.0, MIN(100.0, value));
    [self ps16_layoutThumbAnimated:NO];

    if (!notify) {
        return;
    }

    id<PS16IntensitySliderDelegate> delegate = self.delegate;

    if ([delegate respondsToSelector:@selector(intensitySlider:didChangeStyle:)]) {
        [delegate intensitySlider:self didChangeStyle:_style];
    }
}

#pragma mark - Setters

- (void)setStyle:(CGFloat)style
{
    _style = MAX(0.0, MIN(100.0, style));

    if (!self.dragging) {
        [self ps16_layoutThumbAnimated:NO];
    }
}

- (void)setStyle:(CGFloat)style animated:(BOOL)animated
{
    self.style = style;
    [self ps16_layoutThumbAnimated:animated];
}

- (void)setAccentColor:(UIColor *)color
{
    _accentColor = color ?: [UIColor colorWithWhite:0.92 alpha:1.0];

    [CATransaction begin];
    [CATransaction setAnimationDuration:0.22];
    self.trackLayer.colors = @[
        (id)[UIColor whiteColor].CGColor,
        (id)_accentColor.CGColor,
    ];
    [CATransaction commit];
}

#pragma mark - Touches

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    // Generous hit area: the capsule is only 20 pt tall on a 4 inch screen.
    return CGRectContainsPoint(CGRectInset(self.bounds, -8.0, -8.0), point);
}

- (void)ps16_notifyInteracting:(BOOL)interacting
{
    id<PS16IntensitySliderDelegate> delegate = self.delegate;

    if ([delegate respondsToSelector:@selector(intensitySlider:didChangeInteracting:)]) {
        [delegate intensitySlider:self didChangeInteracting:interacting];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    self.dragging = YES;
    [self ps16_notifyInteracting:YES];
    [self ps16_applyPoint:[[touches anyObject] locationInView:self] notify:YES];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self ps16_applyPoint:[[touches anyObject] locationInView:self] notify:YES];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self ps16_applyPoint:[[touches anyObject] locationInView:self] notify:YES];
    self.dragging = NO;
    [self ps16_notifyInteracting:NO];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    self.dragging = NO;
    [self ps16_notifyInteracting:NO];
}

@end

//
//  PS16DotMatrixPadView.m
//  PhotographicStyles16
//
//  The dot field is painted in -drawRect: with CoreGraphics, because 121 tiny
//  CALayers would cost more on an A7 than one small bitmap. The background is a
//  CAGradientLayer so a preset change recolours it without a redraw.
//

#import "PS16DotMatrixPadView.h"

#import <QuartzCore/QuartzCore.h>
#import <math.h>

static const NSInteger kPS16GridCount = 11;
static const CGFloat kPS16DotBaseRadius = 1.25;    // 2.5 pt dot
static const CGFloat kPS16DotGrowRadius = 1.75;    // -> 3.0 pt radius, 6 pt dot
static const CGFloat kPS16DotBaseAlpha = 0.45;
static const CGFloat kPS16DotGrowAlpha = 0.50;     // -> 0.95 peak
static const CGFloat kPS16ClusterSigma = 18.0;     // pt, magnetic falloff
static const CGFloat kPS16PuckSize = 10.0;
static const CGFloat kPS16PadCornerRadius = 22.0;

@interface PS16DotMatrixPadView ()

@property (nonatomic, strong) CAGradientLayer *gradientLayer;
@property (nonatomic, assign) CGPoint puckCenter;
@property (nonatomic, assign) BOOL dragging;
@property (nonatomic, assign) BOOL animating;
@property (nonatomic, strong, nullable) CADisplayLink *displayLink;
@property (nonatomic, assign) CFTimeInterval animationStart;
@property (nonatomic, assign) CGPoint animationFrom;
@property (nonatomic, assign) CGPoint animationTo;

@end

@implementation PS16DotMatrixPadView

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
    _bright = 50.0;
    _color = 50.0;
    _puckCenter = CGPointZero;

    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    self.layer.cornerRadius = kPS16PadCornerRadius;
    self.layer.masksToBounds = YES;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;

    _gradientLayer = [CAGradientLayer layer];
    _gradientLayer.startPoint = CGPointMake(0.0, 0.0);
    _gradientLayer.endPoint = CGPointMake(1.0, 1.0);
    _gradientLayer.colors = @[
        (id)[UIColor colorWithWhite:0.16 alpha:0.85].CGColor,
        (id)[UIColor colorWithWhite:0.34 alpha:0.85].CGColor,
    ];
    [self.layer addSublayer:_gradientLayer];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(ps16_handlePan:)];
    [self addGestureRecognizer:pan];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(ps16_handleTap:)];
    [self addGestureRecognizer:tap];
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    // The gradient layer sits below the painted dots, so it never needs to fight
    // -drawRect: for z-order.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.gradientLayer.frame = self.bounds;
    [CATransaction commit];

    if (!self.dragging && !self.animating) {
        self.puckCenter = [self ps16_pointForBright:self.bright color:self.color];
    }
    [self setNeedsDisplay];
}

- (void)willMoveToWindow:(UIWindow *)newWindow
{
    [super willMoveToWindow:newWindow];

    // CADisplayLink retains its target; dropping the window must tear it down or
    // the pad never deallocates.
    [self.displayLink invalidate];
    self.displayLink = nil;
    self.animating = NO;
}

#pragma mark - Geometry

/// Inset keeps the puck fully inside the rounded corners at the extremes.
- (CGFloat)ps16_travelX
{
    return MAX(1.0, self.bounds.size.width * 0.5 - (kPS16PuckSize * 0.5 + 6.0));
}

- (CGFloat)ps16_travelY
{
    return MAX(1.0, self.bounds.size.height * 0.5 - (kPS16PuckSize * 0.5 + 6.0));
}

- (CGPoint)ps16_pointForBright:(CGFloat)bright color:(CGFloat)color
{
    CGFloat nx = (MAX(0.0, MIN(100.0, color)) - 50.0) / 50.0;
    CGFloat ny = (MAX(0.0, MIN(100.0, bright)) - 50.0) / 50.0;

    return CGPointMake(self.bounds.size.width * 0.5 + nx * [self ps16_travelX],
                       self.bounds.size.height * 0.5 - ny * [self ps16_travelY]);
}

- (void)ps16_applyPoint:(CGPoint)point notify:(BOOL)notify
{
    CGFloat travelX = [self ps16_travelX];
    CGFloat travelY = [self ps16_travelY];

    CGFloat nx = (point.x - self.bounds.size.width * 0.5) / travelX;
    CGFloat ny = (self.bounds.size.height * 0.5 - point.y) / travelY;

    nx = MAX(-1.0, MIN(1.0, nx));
    ny = MAX(-1.0, MIN(1.0, ny));

    _color = (nx + 1.0) * 50.0;
    _bright = (ny + 1.0) * 50.0;
    self.puckCenter = [self ps16_pointForBright:_bright color:_color];

    [self setNeedsDisplay];

    if (!notify) {
        return;
    }

    id<PS16DotMatrixPadViewDelegate> delegate = self.delegate;

    if ([delegate respondsToSelector:@selector(dotMatrixPadView:didChangeBright:color:)]) {
        [delegate dotMatrixPadView:self didChangeBright:_bright color:_color];
    }
}

#pragma mark - Gestures

- (void)ps16_handlePan:(UIPanGestureRecognizer *)pan
{
    CGPoint point = [pan locationInView:self];

    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            [self ps16_cancelAnimation];
            self.dragging = YES;
            [self ps16_notifyInteracting:YES];
            [self ps16_applyPoint:point notify:YES];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            [self ps16_applyPoint:point notify:YES];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            [self ps16_applyPoint:point notify:YES];
            self.dragging = NO;
            [self ps16_notifyInteracting:NO];
            break;
        }
        default:
            break;
    }
}

- (void)ps16_handleTap:(UITapGestureRecognizer *)tap
{
    if (tap.state != UIGestureRecognizerStateEnded) {
        return;
    }

    [self ps16_cancelAnimation];
    [self ps16_notifyInteracting:YES];
    [self ps16_applyPoint:[tap locationInView:self] notify:YES];
    [self ps16_notifyInteracting:NO];
}

- (void)ps16_notifyInteracting:(BOOL)interacting
{
    id<PS16DotMatrixPadViewDelegate> delegate = self.delegate;

    if ([delegate respondsToSelector:@selector(dotMatrixPadView:didChangeInteracting:)]) {
        [delegate dotMatrixPadView:self didChangeInteracting:interacting];
    }
}

#pragma mark - Puck animation

- (void)ps16_cancelAnimation
{
    [self.displayLink invalidate];
    self.displayLink = nil;
    self.animating = NO;
}

- (void)setBright:(CGFloat)bright
{
    _bright = MAX(0.0, MIN(100.0, bright));

    if (!self.dragging && !self.animating) {
        self.puckCenter = [self ps16_pointForBright:_bright color:_color];
        [self setNeedsDisplay];
    }
}

- (void)setColor:(CGFloat)color
{
    _color = MAX(0.0, MIN(100.0, color));

    if (!self.dragging && !self.animating) {
        self.puckCenter = [self ps16_pointForBright:_bright color:_color];
        [self setNeedsDisplay];
    }
}

- (void)setBright:(CGFloat)bright color:(CGFloat)color animated:(BOOL)animated
{
    CGPoint from = self.puckCenter;

    [self ps16_cancelAnimation];
    _bright = MAX(0.0, MIN(100.0, bright));
    _color = MAX(0.0, MIN(100.0, color));

    CGPoint target = [self ps16_pointForBright:_bright color:_color];

    if (!animated) {
        self.puckCenter = target;
        [self setNeedsDisplay];
        return;
    }

    self.animationFrom = from;
    self.animationTo = target;
    self.animationStart = CACurrentMediaTime();
    self.animating = YES;

    // ponytail: ease-out cubic, not a spring. The puck is painted in
    // -drawRect:, so the redraw has to be stepped explicitly; upgrade path is a
    // damped-oscillator integrator if the motion ever needs overshoot.
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(ps16_stepAnimation:)];
    self.displayLink = link;
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)ps16_stepAnimation:(CADisplayLink *)link
{
    CFTimeInterval elapsed = CACurrentMediaTime() - self.animationStart;
    CGFloat t = (CGFloat)(elapsed / 0.30);

    if (t >= 1.0) {
        self.puckCenter = self.animationTo;
        [self setNeedsDisplay];
        [self ps16_cancelAnimation];
        return;
    }

    CGFloat eased = 1.0 - pow(1.0 - t, 3.0);

    self.puckCenter = CGPointMake(self.animationFrom.x + (self.animationTo.x - self.animationFrom.x) * eased,
                                  self.animationFrom.y + (self.animationTo.y - self.animationFrom.y) * eased);
    [self setNeedsDisplay];
}

#pragma mark - Gradient

- (void)setGradientColors:(NSArray<UIColor *> *)colors
{
    if (colors.count < 2) {
        return;
    }

    NSArray *cgColors = @[ (id)colors[0].CGColor, (id)colors[1].CGColor ];

    // Colour-only change: keeping it off the implicit-animation path avoids a
    // second fade fighting the caller's own transition.
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.22];
    self.gradientLayer.colors = cgColors;
    [CATransaction commit];
}

#pragma mark - Drawing

- (void)drawRect:(CGRect)rect
{
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    if (ctx == NULL) {
        return;
    }

    CGRect bounds = self.bounds;
    CGFloat stepX = bounds.size.width / (CGFloat)(kPS16GridCount + 1);
    CGFloat stepY = bounds.size.height / (CGFloat)(kPS16GridCount + 1);
    const CGFloat twoSigmaSq = 2.0 * kPS16ClusterSigma * kPS16ClusterSigma;

    CGPoint puck = self.puckCenter;

    for (NSInteger row = 1; row <= kPS16GridCount; row++) {
        for (NSInteger col = 1; col <= kPS16GridCount; col++) {
            CGFloat dx = stepX * (CGFloat)col - puck.x;
            CGFloat dy = stepY * (CGFloat)row - puck.y;
            CGFloat inf = expf(-(dx * dx + dy * dy) / twoSigmaSq);

            CGFloat radius = kPS16DotBaseRadius + kPS16DotGrowRadius * inf;
            CGFloat alpha = kPS16DotBaseAlpha + kPS16DotGrowAlpha * inf;

            CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, alpha);
            CGContextFillEllipseInRect(ctx,
                                       CGRectMake(stepX * (CGFloat)col - radius,
                                                  stepY * (CGFloat)row - radius,
                                                  radius * 2.0,
                                                  radius * 2.0));
        }
    }

    // Puck: white core, thin dark rim so it stays visible over bright dots.
    CGRect puckRect = CGRectMake(puck.x - kPS16PuckSize * 0.5,
                                 puck.y - kPS16PuckSize * 0.5,
                                 kPS16PuckSize,
                                 kPS16PuckSize);

    CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);
    CGContextFillEllipseInRect(ctx, puckRect);

    CGContextSetRGBStrokeColor(ctx, 0.0, 0.0, 0.0, 0.35);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextStrokeEllipseInRect(ctx, CGRectInset(puckRect, 0.5, 0.5));
}

@end

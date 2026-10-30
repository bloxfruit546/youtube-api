//
//  PS16ColorEngine.m
//  PhotographicStyles16
//
//  One CIContext on the system Metal device, one filter chain allocated at init
//  and reused for every frame. Nothing here allocates inside a render pass.
//

#import "PS16ColorEngine.h"

#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <os/lock.h>

NSInteger const PS16PresetCount = 5;

#pragma mark - Preset table

typedef struct {
    const char *name;
    CGFloat     baseSaturation;   // added to the Colour axis
    CGFloat     contrast;         // multiplies the Contrast control
    CGFloat     biasR;            // colour-matrix bias, 0..1 scale
    CGFloat     biasG;
    CGFloat     biasB;
    CGFloat     shadowLift;       // tone-curve point 1 offset
    CGFloat     highlightLift;    // tone-curve point 3 offset
} PS16PresetSpec;

// Order is the rail order: Standard, Pearl, Rose Gold, Contrast, Amber.
static const PS16PresetSpec kPS16Presets[5] = {
    { "Standard",  0.00, 1.00,  0.00,  0.00,  0.00,  0.00,  0.00 },
    { "Pearl",     0.06, 0.94,  0.04, -0.02,  0.06,  0.02,  0.03 },
    { "Rose Gold", 0.04, 1.02,  0.07,  0.01, -0.03,  0.00,  0.02 },
    { "Contrast",  0.10, 1.08, -0.03,  0.01,  0.05, -0.07,  0.07 },
    { "Amber",     0.08, 1.06,  0.09,  0.03, -0.08, -0.03, -0.01 },
};

NSString *PS16PresetName(NSInteger preset)
{
    if (preset < 0 || preset >= PS16PresetCount) {
        preset = 0;
    }
    return [NSString stringWithUTF8String:kPS16Presets[preset].name];
}

/// Rail swatch gradients, top stop = shadow end. Spec hex values.
static UIColor *PS16Hex(uint32_t rgb)
{
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

NSArray<UIColor *> *PS16PresetGradient(NSInteger preset)
{
    static NSArray<NSArray<UIColor *> *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            @[ PS16Hex(0xE89B6C), PS16Hex(0x7A8B99) ],   // Standard
            @[ PS16Hex(0x9B6B9E), PS16Hex(0xF2C6DE) ],   // Pearl
            @[ PS16Hex(0xD48A78), PS16Hex(0xF5D6CE) ],   // Rose Gold
            @[ PS16Hex(0x3A7CA5), PS16Hex(0x81C3D7) ],   // Contrast
            @[ PS16Hex(0xB85D19), PS16Hex(0xE6A15C) ],   // Amber
        ];
    });
    if (preset < 0 || preset >= PS16PresetCount) {
        preset = 0;
    }
    return table[preset];
}

#pragma mark - Engine

@interface PS16ColorEngine () {
    os_unfair_lock _lock;
    CGFloat _bright;
    CGFloat _color;
    CGFloat _style;
    NSInteger _preset;
    BOOL _bypassed;
}

@property (nonatomic, strong) CIContext *context;
@property (nonatomic, strong) CIFilter *controlsFilter;
@property (nonatomic, strong) CIFilter *curveFilter;
@property (nonatomic, strong) CIFilter *matrixFilter;

@end

@implementation PS16ColorEngine

+ (instancetype)sharedEngine
{
    static PS16ColorEngine *engine = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        engine = [[PS16ColorEngine alloc] init];
    });
    return engine;
}

- (instancetype)init
{
    self = [super init];
    if (!self) {
        return nil;
    }

    _lock = OS_UNFAIR_LOCK_INIT;
    _bright = 50.0;
    _color = 50.0;
    _style = 100.0;
    _preset = 0;
    _bypassed = NO;

    // Metal-backed context, allocated once for the whole process. Options are
    // the anti-Jetsam set from the spec: no colour-space conversion, no
    // intermediate cache retention, high priority so the A7 GPU schedules the
    // viewfinder first.
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSDictionary *options = @{
        kCIContextWorkingColorSpace: [NSNull null],
        kCIContextOutputColorSpace: [NSNull null],
        kCIContextCacheIntermediates: @NO,
        kCIContextPriorityRequestLow: @NO,
        kCIContextUseSoftwareRenderer: @(device == nil),
    };
    if (device != nil) {
        _context = [CIContext contextWithMTLDevice:device options:options];
    }
    if (_context == nil) {
        // No Metal device (or the MTL context refused): GL/CPU still works and
        // is far better than a nil context.
        _context = [CIContext contextWithOptions:options];
    }

    _controlsFilter = [CIFilter filterWithName:@"CIColorControls"];
    _curveFilter = [CIFilter filterWithName:@"CIToneCurve"];
    _matrixFilter = [CIFilter filterWithName:@"CIColorMatrix"];

    for (CIFilter *filter in @[ _controlsFilter, _curveFilter, _matrixFilter ]) {
        [filter setDefaults];
    }

    return self;
}

#pragma mark - Parameters

- (CIContext *)renderingContext
{
    return self.context;
}

- (CGFloat)bright
{
    os_unfair_lock_lock(&_lock);
    CGFloat value = _bright;
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (void)setBright:(CGFloat)bright
{
    CGFloat clamped = MAX(0.0, MIN(100.0, bright));
    os_unfair_lock_lock(&_lock);
    _bright = clamped;
    os_unfair_lock_unlock(&_lock);
}

- (CGFloat)color
{
    os_unfair_lock_lock(&_lock);
    CGFloat value = _color;
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (void)setColor:(CGFloat)color
{
    CGFloat clamped = MAX(0.0, MIN(100.0, color));
    os_unfair_lock_lock(&_lock);
    _color = clamped;
    os_unfair_lock_unlock(&_lock);
}

- (CGFloat)style
{
    os_unfair_lock_lock(&_lock);
    CGFloat value = _style;
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (void)setStyle:(CGFloat)style
{
    CGFloat clamped = MAX(0.0, MIN(100.0, style));
    os_unfair_lock_lock(&_lock);
    _style = clamped;
    os_unfair_lock_unlock(&_lock);
}

- (NSInteger)preset
{
    os_unfair_lock_lock(&_lock);
    NSInteger value = _preset;
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (void)setPreset:(NSInteger)preset
{
    NSInteger clamped = MAX(0, MIN(PS16PresetCount - 1, preset));
    os_unfair_lock_lock(&_lock);
    _preset = clamped;
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)isBypassed
{
    os_unfair_lock_lock(&_lock);
    BOOL value = _bypassed;
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (void)setBypassed:(BOOL)bypassed
{
    os_unfair_lock_lock(&_lock);
    _bypassed = bypassed;
    os_unfair_lock_unlock(&_lock);
}

- (void)resetParameters
{
    os_unfair_lock_lock(&_lock);
    _bright = 50.0;
    _color = 50.0;
    _style = 100.0;
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - Colour grading

- (CIImage *)filteredImage:(CIImage *)source
{
    if (source == nil) {
        return nil;
    }

    // One snapshot of the parameters so a mid-render UI write cannot produce a
    // chain built from two different states.
    os_unfair_lock_lock(&_lock);
    CGFloat bright = _bright;
    CGFloat color = _color;
    CGFloat style = _style;
    NSInteger presetIndex = _preset;
    BOOL bypassed = _bypassed;
    os_unfair_lock_unlock(&_lock);

    if (bypassed || style <= 0.0) {
        return source;
    }

    if (presetIndex < 0 || presetIndex >= PS16PresetCount) {
        presetIndex = 0;
    }
    const PS16PresetSpec spec = kPS16Presets[presetIndex];

    // b, c in [-1, 1]; s in [0, 1].
    const CGFloat b = (bright - 50.0) / 50.0;
    const CGFloat c = (color - 50.0) / 50.0;
    const CGFloat s = style / 100.0;

    @autoreleasepool {
        CIImage *image = source;

        // 1. Exposure / saturation / contrast.
        CGFloat saturation = 1.0 + (c * 0.65 + spec.baseSaturation) * s;
        saturation = MAX(0.0, saturation);

        [_controlsFilter setValue:image forKey:kCIInputImageKey];
        [_controlsFilter setValue:@(b * 0.18 * s) forKey:kCIInputBrightnessKey];
        [_controlsFilter setValue:@(saturation) forKey:kCIInputSaturationKey];
        [_controlsFilter setValue:@(1.0 + (spec.contrast - 1.0) * s) forKey:kCIInputContrastKey];
        image = _controlsFilter.outputImage;

        // 2. Tone curve: preset shadow/highlight lift plus the spec's midtone
        // bend so Bright never clips the highlights.
        [_curveFilter setValue:image forKey:kCIInputImageKey];
        [_curveFilter setValue:[CIVector vectorWithX:0.0 Y:0.0] forKey:@"inputPoint0"];
        [_curveFilter setValue:[CIVector vectorWithX:0.25
                                                   Y:0.25 + spec.shadowLift * s]
                        forKey:@"inputPoint1"];
        [_curveFilter setValue:[CIVector vectorWithX:0.50
                                                   Y:0.50 + b * 0.15 * s]
                        forKey:@"inputPoint2"];
        [_curveFilter setValue:[CIVector vectorWithX:0.75
                                                   Y:0.75 + spec.highlightLift * s]
                        forKey:@"inputPoint3"];
        [_curveFilter setValue:[CIVector vectorWithX:1.0 Y:1.0] forKey:@"inputPoint4"];
        image = _curveFilter.outputImage;

        // 3. Preset identity, lerped from the identity matrix by style and the
        // Colour axis, exactly as specified.
        const CGFloat k = s * (0.5 + 0.5 * (c + 1.0));

        // The Colour axis also shifts the cast itself, left = cool / right =
        // warm, so dragging the pad recolours the frame on every preset instead
        // of only moving saturation. Without this, Standard (all-zero bias)
        // looked identical across the whole pad.
        // ponytail: one linear warm/cool pair, not a full HSV wheel. Ceiling: the
        // pad cannot reach green/magenta. Upgrade path is a hue-rotation filter.
        const CGFloat warmth = c * 0.10 * s;

        [_matrixFilter setValue:image forKey:kCIInputImageKey];
        [_matrixFilter setValue:[CIVector vectorWithX:1.0 Y:0.0 Z:0.0 W:0.0] forKey:@"inputRVector"];
        [_matrixFilter setValue:[CIVector vectorWithX:0.0 Y:1.0 Z:0.0 W:0.0] forKey:@"inputGVector"];
        [_matrixFilter setValue:[CIVector vectorWithX:0.0 Y:0.0 Z:1.0 W:0.0] forKey:@"inputBVector"];
        [_matrixFilter setValue:[CIVector vectorWithX:0.0 Y:0.0 Z:0.0 W:1.0] forKey:@"inputAVector"];
        [_matrixFilter setValue:[CIVector vectorWithX:spec.biasR * k + warmth
                                                    Y:spec.biasG * k
                                                    Z:spec.biasB * k - warmth
                                                    W:0.0]
                         forKey:@"inputBiasVector"];
        image = _matrixFilter.outputImage;

        return image ?: source;
    }
}

#pragma mark - Still capture

/// EXIF orientation matching a UIImageOrientation, so CI sees upright pixels.
static CGImagePropertyOrientation PS16ExifFromImageOrientation(UIImageOrientation orientation)
{
    switch (orientation) {
        case UIImageOrientationDown:              return kCGImagePropertyOrientationDown;
        case UIImageOrientationLeft:              return kCGImagePropertyOrientationLeft;
        case UIImageOrientationRight:             return kCGImagePropertyOrientationRight;
        case UIImageOrientationDownMirrored:      return kCGImagePropertyOrientationDownMirrored;
        case UIImageOrientationUpMirrored:        return kCGImagePropertyOrientationUpMirrored;
        case UIImageOrientationLeftMirrored:      return kCGImagePropertyOrientationLeftMirrored;
        case UIImageOrientationRightMirrored:     return kCGImagePropertyOrientationRightMirrored;
        case UIImageOrientationUp:
        default:                                  return kCGImagePropertyOrientationUp;
    }
}

- (UIImage *)processCapturedImage:(UIImage *)image
{
    if (image == nil) {
        return nil;
    }

    if (self.isBypassed || self.style <= 0.0) {
        return image;
    }

    @autoreleasepool {
        CGImageRef sourceRef = image.CGImage;

        if (sourceRef == NULL) {
            // CIImage-only or backed by a non-CGImage format; nothing to bake.
            return image;
        }

        CIImage *source = [CIImage imageWithCGImage:sourceRef];
        source = [source imageByApplyingOrientation:PS16ExifFromImageOrientation(image.imageOrientation)];

        CIImage *output = [self filteredImage:source];

        if (output == nil) {
            return image;
        }

        CGRect extent = output.extent;

        if (extent.size.width < 1.0 || extent.size.height < 1.0) {
            return image;
        }

        CGImageRef rendered = [self.context createCGImage:output fromRect:extent];

        if (rendered == NULL) {
            return image;
        }

        // Pixels are already upright, so the result is .Up with the original
        // scale preserved.
        UIImage *result = [UIImage imageWithCGImage:rendered
                                              scale:image.scale
                                        orientation:UIImageOrientationUp];

        CGImageRelease(rendered);

        return result ?: image;
    }
}

@end

// One frame of the visualiser, drawn with Core Graphics into whatever context it is handed: the live
// view's (VisualizerView.m) and the lock screen clip's (VisualizerClip.m), so both look the same. The
// context is UIKit's way up, the origin top left; images go through UIKit so they land the right way up.
//
// What the song's cover gives it is worked out once per cover: the background, a blurred background, and
// two colours, the cover's most vivid one and the most vivid one of another hue.
//
// Glow is a shadow drawn once for the whole of a style's shapes, through a transparency layer, rather than
// one per shape. Particles live here, a fixed pool moved each frame; they come out of the middle for the
// round styles and rise from the bottom for the others.
#import <CoreImage/CoreImage.h>
#import "Visualizer.h"

enum { kMostParticles = 600 };

typedef struct {
    CGFloat x, y, vx, vy, life, maxLife, size, hue, spin;
} SGParticle;

@implementation SGVizRenderer {
    UIImage *_blurred;
    CGFloat _album1[3], _album2[3];
    SGParticle _particles[kMostParticles];
    NSInteger _particleCount;
    double _time, _angle, _flash, _emitCarry;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _album1[0] = _album1[1] = _album1[2] = 1;
    _album2[0] = _album2[1] = _album2[2] = 0.7;
    return self;
}

#pragma mark - the cover

- (void)setArtwork:(UIImage *)artwork {
    if (artwork == _artwork) return;
    _artwork = artwork;
    _blurred = nil;
    if (!artwork.CGImage) return;
    [self readPalette:artwork];
    // Blurred from a small copy: the blur hides the size, and it is quick.
    CIImage *small = [[CIImage imageWithCGImage:artwork.CGImage] imageByApplyingTransform:CGAffineTransformMakeScale(
        200 / MAX(1.0, artwork.size.width * artwork.scale), 200 / MAX(1.0, artwork.size.width * artwork.scale))];
    CIImage *blurred = [[small imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:14];
    static CIContext *context;
    if (!context) context = [CIContext contextWithOptions:nil];
    CGImageRef image = [context createCGImage:blurred fromRect:small.extent];
    if (image) {
        _blurred = [UIImage imageWithCGImage:image];
        CGImageRelease(image);
    }
}

static void toHSB(const CGFloat rgb[3], CGFloat *h, CGFloat *s, CGFloat *b) {
    [[UIColor colorWithRed:rgb[0] green:rgb[1] blue:rgb[2] alpha:1] getHue:h saturation:s brightness:b alpha:NULL];
}

// The most vivid colour of the cover, and the most vivid of a clearly different hue; a grey cover
// gives white and a light grey.
- (void)readPalette:(UIImage *)image {
    enum { side = 12 };
    uint8_t pixels[side * side * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, side, side, 8, side * 4, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return;
    CGContextDrawImage(context, CGRectMake(0, 0, side, side), image.CGImage);
    CGContextRelease(context);
    CGFloat best[3] = {1, 1, 1}, second[3] = {0.7, 0.7, 0.7};
    CGFloat bestScore = 0, bestHue = 0, secondScore = 0;
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < side * side; i++) {
            CGFloat rgb[3] = {pixels[i * 4] / 255.0, pixels[i * 4 + 1] / 255.0, pixels[i * 4 + 2] / 255.0};
            CGFloat h, s, b;
            toHSB(rgb, &h, &s, &b);
            CGFloat score = s * (0.3 + b);
            if (pass == 0 && score > bestScore) {
                bestScore = score;
                bestHue = h;
                memcpy(best, rgb, sizeof best);
            } else if (pass == 1) {
                CGFloat distance = fabs(h - bestHue);
                distance = MIN(distance, 1 - distance);
                if (distance > 0.1 && score > secondScore) {
                    secondScore = score;
                    memcpy(second, rgb, sizeof second);
                }
            }
        }
    }
    if (bestScore < 0.12) {
        best[0] = best[1] = best[2] = 1;
        second[0] = second[1] = second[2] = 0.75;
    } else if (secondScore < 0.08) {
        // One hue only: its lighter self.
        for (int c = 0; c < 3; c++) second[c] = MIN(1, best[c] * 0.6 + 0.4);
    }
    // Colours drawn over a dark background want to be bright.
    for (int k = 0; k < 2; k++) {
        CGFloat *rgb = k ? second : best, h, s, b;
        toHSB(rgb, &h, &s, &b);
        UIColor *lifted = [UIColor colorWithHue:h saturation:MIN(s, 0.9) brightness:MAX(b, 0.85) alpha:1];
        [lifted getRed:&rgb[0] green:&rgb[1] blue:&rgb[2] alpha:NULL];
    }
    memcpy(_album1, best, sizeof best);
    memcpy(_album2, second, sizeof second);
}

#pragma mark - colours

// The colour at `t` (0...1) along the palette.
- (UIColor *)colorAt:(CGFloat)t settings:(const SGVizSettings *)settings alpha:(CGFloat)alpha {
    t = MAX(0, MIN(1, t));
    switch (settings->colors) {
        case SGVizColorsRainbow: {
            CGFloat hue = fmod(t * 0.85 + _time * 0.04, 1);
            return [UIColor colorWithHue:hue saturation:0.75 brightness:1 alpha:alpha];
        }
        case SGVizColorsWhite:
            return [UIColor colorWithWhite:1 alpha:alpha];
        default: {
            const CGFloat *a = settings->colors == SGVizColorsCustom ? settings->color1 : _album1;
            const CGFloat *b = settings->colors == SGVizColorsCustom ? settings->color2 : _album2;
            return [UIColor colorWithRed:a[0] + (b[0] - a[0]) * t green:a[1] + (b[1] - a[1]) * t blue:a[2] + (b[2] - a[2]) * t alpha:alpha];
        }
    }
}

#pragma mark - drawing

static void fillAspect(UIImage *image, CGSize size) {
    if (!image || image.size.width < 1 || image.size.height < 1) return;
    CGFloat scale = MAX(size.width / image.size.width, size.height / image.size.height);
    CGSize drawn = CGSizeMake(image.size.width * scale, image.size.height * scale);
    [image drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2, drawn.width, drawn.height)];
}

- (void)drawBackground:(const SGVizSettings *)settings size:(CGSize)size context:(CGContextRef)context {
    CGRect all = CGRectMake(0, 0, size.width, size.height);
    switch (settings->background) {
        case SGVizBackgroundSong:
        case SGVizBackgroundBlurred: {
            [[UIColor blackColor] setFill];
            UIRectFill(all);
            BOOL blurred = settings->background == SGVizBackgroundBlurred && _blurred;
            fillAspect(blurred ? _blurred : _artwork, size);
            // Darkened, so what is drawn over it stands out.
            [[UIColor colorWithWhite:0 alpha:blurred ? 0.3 : 0.5] setFill];
            UIRectFillUsingBlendMode(all, kCGBlendModeNormal);
            break;
        }
        case SGVizBackgroundColor:
            [[UIColor colorWithRed:settings->backgroundColor[0] green:settings->backgroundColor[1] blue:settings->backgroundColor[2] alpha:1] setFill];
            UIRectFill(all);
            break;
        default:
            [[UIColor blackColor] setFill];
            UIRectFill(all);
    }
    if (_flash > 0.01) {
        [[UIColor colorWithWhite:1 alpha:_flash * 0.12] setFill];
        UIRectFillUsingBlendMode(all, kCGBlendModeNormal);
    }
}

- (void)drawBars:(const SGVizFrame *)frame settings:(const SGVizSettings *)settings size:(CGSize)size context:(CGContextRef)context mirror:(BOOL)mirror {
    NSInteger n = frame->bandCount;
    CGFloat margin = size.width * 0.06, slot = (size.width - 2 * margin) / n, width = MAX(1, slot * 0.68);
    CGFloat floor = mirror ? size.height / 2 : size.height - margin, most = mirror ? size.height * 0.38 : size.height * 0.78;
    for (NSInteger i = 0; i < n; i++) {
        CGFloat value = frame->bands[i], height = MAX(width * 0.5, value * most);
        CGFloat x = margin + i * slot + (slot - width) / 2;
        CGRect bar = mirror ? CGRectMake(x, floor - height, width, height * 2) : CGRectMake(x, floor - height, width, height);
        [[self colorAt:(CGFloat)i / MAX(1, n - 1) settings:settings alpha:0.95] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:bar cornerRadius:width / 2] fill];
    }
}

- (void)drawRadial:(const SGVizFrame *)frame settings:(const SGVizSettings *)settings size:(CGSize)size context:(CGContextRef)context {
    NSInteger n = frame->bandCount;
    CGPoint centre = CGPointMake(size.width / 2, size.height / 2);
    CGFloat side = MIN(size.width, size.height), inner = side * (0.24 + 0.03 * frame->bass), most = side * 0.2;
    CGFloat width = MAX(1.5, 2 * M_PI * inner / (n * 2) * 0.62);
    CGContextSetLineCap(context, kCGLineCapRound);
    CGContextSetLineWidth(context, width);
    // Round the whole circle: the bands go out and back, so the ends meet.
    NSInteger spokes = n * 2;
    for (NSInteger i = 0; i < spokes; i++) {
        NSInteger band = i < n ? i : spokes - 1 - i;
        CGFloat value = frame->bands[band], angle = _angle + 2 * M_PI * i / spokes - M_PI_2;
        CGFloat length = MAX(width, value * most);
        CGFloat c = cos(angle), s = sin(angle);
        CGContextMoveToPoint(context, centre.x + c * inner, centre.y + s * inner);
        CGContextAddLineToPoint(context, centre.x + c * (inner + length), centre.y + s * (inner + length));
        CGContextSetStrokeColorWithColor(context, [self colorAt:(CGFloat)band / MAX(1, n - 1) settings:settings alpha:0.95].CGColor);
        CGContextStrokePath(context);
    }
}

- (void)drawCoverInMiddle:(const SGVizFrame *)frame size:(CGSize)size context:(CGContextRef)context {
    if (!_artwork) return;
    CGFloat side = MIN(size.width, size.height), radius = side * (0.2 + 0.025 * frame->bass);
    CGRect circle = CGRectMake(size.width / 2 - radius, size.height / 2 - radius, radius * 2, radius * 2);
    CGContextSaveGState(context);
    [[UIBezierPath bezierPathWithOvalInRect:circle] addClip];
    [_artwork drawInRect:circle];
    CGContextRestoreGState(context);
}

- (void)drawWave:(const SGVizFrame *)frame settings:(const SGVizSettings *)settings size:(CGSize)size context:(CGContextRef)context {
    CGFloat middle = size.height / 2, amplitude = size.height * 0.34;
    for (int pass = 0; pass < 2; pass++) {
        UIBezierPath *line = [UIBezierPath bezierPath];
        for (NSInteger i = 0; i < SGVizWaveformPoints; i++) {
            CGFloat x = size.width * i / (SGVizWaveformPoints - 1);
            CGFloat y = middle + (pass ? -1 : 1) * frame->waveform[i] * amplitude * (pass ? 0.6 : 1);
            if (i == 0) [line moveToPoint:CGPointMake(x, y)];
            else [line addLineToPoint:CGPointMake(x, y)];
        }
        line.lineWidth = MAX(1.5, size.width * (pass ? 0.004 : 0.008));
        line.lineJoinStyle = kCGLineJoinRound;
        [[self colorAt:pass ? 1 : 0 settings:settings alpha:pass ? 0.45 : 1] setStroke];
        [line stroke];
    }
}

- (void)drawSpectrum:(const SGVizFrame *)frame settings:(const SGVizSettings *)settings size:(CGSize)size context:(CGContextRef)context {
    NSInteger n = frame->bandCount;
    CGFloat bottom = size.height, most = size.height * 0.75;
    UIBezierPath *curve = [UIBezierPath bezierPath];
    [curve moveToPoint:CGPointMake(0, bottom)];
    CGPoint previous = CGPointMake(0, bottom - frame->bands[0] * most);
    [curve addLineToPoint:previous];
    for (NSInteger i = 1; i < n; i++) {
        CGPoint point = CGPointMake(size.width * i / (n - 1), bottom - frame->bands[i] * most);
        CGPoint mid = CGPointMake((previous.x + point.x) / 2, (previous.y + point.y) / 2);
        [curve addQuadCurveToPoint:mid controlPoint:previous];
        previous = point;
    }
    [curve addLineToPoint:previous];
    [curve addLineToPoint:CGPointMake(size.width, bottom)];
    [curve closePath];
    CGContextSaveGState(context);
    [curve addClip];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = @[(__bridge id)[self colorAt:1 settings:settings alpha:0.9].CGColor, (__bridge id)[self colorAt:0 settings:settings alpha:0.35].CGColor];
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
    CGContextDrawLinearGradient(context, gradient, CGPointMake(0, bottom - most), CGPointMake(0, bottom), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
    CGContextRestoreGState(context);
    curve.lineWidth = MAX(1.5, size.width * 0.006);
    [[self colorAt:1 settings:settings alpha:1] setStroke];
    [curve stroke];
}

- (void)drawRings:(const SGVizFrame *)frame settings:(const SGVizSettings *)settings size:(CGSize)size context:(CGContextRef)context {
    CGFloat side = MIN(size.width, size.height);
    CGPoint centre = CGPointMake(size.width / 2, size.height / 2);
    const float values[4] = {frame->bass, frame->mids, frame->highs, frame->level};
    for (int i = 0; i < 4; i++) {
        CGFloat radius = side * (0.23 + 0.07 * i) + side * 0.06 * values[i];
        UIBezierPath *ring = [UIBezierPath bezierPathWithArcCenter:centre radius:radius startAngle:0 endAngle:2 * M_PI clockwise:YES];
        ring.lineWidth = MAX(1, side * (0.006 + 0.02 * values[i]));
        [[self colorAt:i / 3.0 settings:settings alpha:0.35 + 0.6 * MIN(1, values[i])] setStroke];
        [ring stroke];
    }
}

#pragma mark - particles

static CGFloat triggerValue(const SGVizFrame *frame, SGVizTrigger trigger) {
    switch (trigger) {
        case SGVizTriggerBass: return frame->bass;
        case SGVizTriggerLevel: return frame->level;
        case SGVizTriggerHighs: return frame->highs;
        default: return frame->bass * 0.35;
    }
}

- (void)moveParticles:(const SGVizFrame *)frame settings:(const SGVizSettings *)settings size:(CGSize)size dt:(double)dt {
    CGFloat side = MIN(size.width, size.height), scale = side / 350;
    BOOL fromMiddle = settings->style == SGVizStyleRadial || settings->style == SGVizStyleRings || settings->style == SGVizStyleParticlesOnly;
    CGFloat energy = triggerValue(frame, settings->trigger);
    double rate = settings->particleAmount * 140 * energy;
    if (frame->beat && (settings->trigger == SGVizTriggerBeat || settings->trigger == SGVizTriggerBass)) _emitCarry += 6 + 30 * settings->particleAmount;
    _emitCarry += rate * dt;
    while (_emitCarry >= 1 && _particleCount < kMostParticles) {
        _emitCarry -= 1;
        SGParticle *p = &_particles[_particleCount++];
        CGFloat speed = (50 + arc4random_uniform(170)) * scale * (0.6 + energy);
        if (fromMiddle) {
            CGFloat angle = arc4random_uniform(3600) / 3600.0 * 2 * M_PI, start = side * 0.22;
            p->x = size.width / 2 + cos(angle) * start;
            p->y = size.height / 2 + sin(angle) * start;
            p->vx = cos(angle) * speed;
            p->vy = sin(angle) * speed;
        } else {
            p->x = arc4random_uniform(1000) / 1000.0 * size.width;
            p->y = size.height + 4;
            p->vx = ((CGFloat)arc4random_uniform(200) - 100) / 100 * 20 * scale;
            p->vy = -speed;
        }
        p->maxLife = p->life = 0.8 + arc4random_uniform(1400) / 1000.0;
        p->size = (1.5 + arc4random_uniform(35) / 10.0) * scale;
        p->hue = arc4random_uniform(1000) / 1000.0;
        p->spin = arc4random_uniform(628) / 100.0;
    }
    if (_emitCarry > 1) _emitCarry = 1;
    CGFloat push = 1 + frame->level * 1.5;
    for (NSInteger i = 0; i < _particleCount;) {
        SGParticle *p = &_particles[i];
        p->life -= dt;
        p->x += p->vx * dt * push;
        p->y += p->vy * dt * push;
        p->spin += dt * 3;
        if (p->life <= 0 || p->x < -20 || p->y < -20 || p->x > size.width + 20 || p->y > size.height + 20) {
            _particles[i] = _particles[--_particleCount];
            continue;
        }
        i++;
    }
}

- (void)drawParticles:(const SGVizSettings *)settings context:(CGContextRef)context {
    for (NSInteger i = 0; i < _particleCount; i++) {
        SGParticle *p = &_particles[i];
        CGFloat alpha = MAX(0, MIN(1, p->life / p->maxLife)) * 0.9, r = p->size;
        UIColor *color = [self colorAt:p->hue settings:settings alpha:alpha];
        switch (settings->particleShape) {
            case SGVizParticleSparks: {
                CGContextSetStrokeColorWithColor(context, color.CGColor);
                CGContextSetLineWidth(context, MAX(1, r * 0.5));
                CGFloat length = r * 4, speed = MAX(1, hypot(p->vx, p->vy));
                CGContextMoveToPoint(context, p->x, p->y);
                CGContextAddLineToPoint(context, p->x - p->vx / speed * length, p->y - p->vy / speed * length);
                CGContextStrokePath(context);
                break;
            }
            case SGVizParticleSquares: {
                CGContextSaveGState(context);
                CGContextTranslateCTM(context, p->x, p->y);
                CGContextRotateCTM(context, p->spin);
                CGContextSetFillColorWithColor(context, color.CGColor);
                CGContextFillRect(context, CGRectMake(-r, -r, 2 * r, 2 * r));
                CGContextRestoreGState(context);
                break;
            }
            case SGVizParticleRings:
                CGContextSetStrokeColorWithColor(context, color.CGColor);
                CGContextSetLineWidth(context, MAX(0.8, r * 0.35));
                CGContextStrokeEllipseInRect(context, CGRectMake(p->x - r * 1.5, p->y - r * 1.5, r * 3, r * 3));
                break;
            default:
                CGContextSetFillColorWithColor(context, color.CGColor);
                CGContextFillEllipseInRect(context, CGRectMake(p->x - r, p->y - r, 2 * r, 2 * r));
        }
    }
}

#pragma mark - the frame

- (void)drawFrame:(const SGVizFrame *)frame settings:(const SGVizSettings *)settings inContext:(CGContextRef)context
             size:(CGSize)size dt:(double)dt {
    if (size.width < 1 || size.height < 1) return;
    dt = MAX(0, MIN(dt, 0.1));
    _time += dt;
    _angle += dt * settings->spin * 1.2 * (1 + frame->bass);
    _flash = frame->beat ? 1 : _flash * pow(0.8, dt * 60);

    UIGraphicsPushContext(context);
    [self drawBackground:settings size:size context:context];
    if (settings->particles) [self moveParticles:frame settings:settings size:size dt:dt];

    CGContextSaveGState(context);
    if (settings->glow) {
        CGContextSetShadowWithColor(context, CGSizeZero, MIN(size.width, size.height) * 0.035,
                                    [self colorAt:0.3 settings:settings alpha:0.9].CGColor);
    }
    CGContextBeginTransparencyLayer(context, NULL);
    if (settings->particles) [self drawParticles:settings context:context];
    switch (settings->style) {
        case SGVizStyleBars: [self drawBars:frame settings:settings size:size context:context mirror:NO]; break;
        case SGVizStyleMirror: [self drawBars:frame settings:settings size:size context:context mirror:YES]; break;
        case SGVizStyleRadial: [self drawRadial:frame settings:settings size:size context:context]; break;
        case SGVizStyleWave: [self drawWave:frame settings:settings size:size context:context]; break;
        case SGVizStyleSpectrum: [self drawSpectrum:frame settings:settings size:size context:context]; break;
        case SGVizStyleRings: [self drawRings:frame settings:settings size:size context:context]; break;
        default: break;
    }
    CGContextEndTransparencyLayer(context);
    CGContextRestoreGState(context);

    BOOL round = settings->style == SGVizStyleRadial || settings->style == SGVizStyleRings || settings->style == SGVizStyleParticlesOnly;
    if (settings->cover && round) [self drawCoverInMiddle:frame size:size context:context];
    UIGraphicsPopContext();
}

@end

// SGVisualizerView.h says what it is. One shape layer holds every bar, its path made again each frame from
// the bars SGVisualizerReadBars hands back, under a conic gradient for the Spectrum colour, or for the Cover
// gradient: the playing cover's main colours (SGCoverPalette.h) round the ring, mirrored when the ring is. The display link runs
// the way the lyrics' does (Redesigned/Lyrics/SGRKaraokeView.m): it asks for 60 to 120 frames a second, is
// put down while the player opens or closes (Shared/Player/PlayerEvents.h) and whenever the view is not in a
// window or the app is not in front, so a locked phone is not woken to draw what nobody sees.
#import "Core/SGCore.h"
#import "Shared/Player/PlayerEvents.h"
#import "SGCoverPalette.h"
#import "SGSpectrum.h"
#import "Visualizer.h"
#import "SGVisualizerView.h"

static const CGFloat kOuterInset = 2, kGap = 4;
static NSInteger sg_showing;

static void showing(NSInteger change) {
    sg_showing = MAX(0, sg_showing + change);
    SGVisualizerSetListening(sg_showing > 0);
}

@implementation SGVisualizerView {
    CAShapeLayer *_shape;
    CAGradientLayer *_spectrum;
    CADisplayLink *_link;
    CFTimeInterval _last;
    float _bars[SGSpectrumMaxBands];
    NSInteger _count;
    SGVisualizerStyle _style;
    SGVisualizerColor _color;
    BOOL _mirror, _counted, _covered;
    NSUInteger _frames;
    CGFloat _widthFactor;
    // The bars' directions, made again when their number changes.
    float _cos[SGSpectrumMaxBands], _sin[SGSpectrumMaxBands];
    NSInteger _angles;
}

// Shown as far as its ancestors go: none hidden or faded out (a queue cell's ring, a closed player's).
static BOOL onScreen(UIView *view) {
    for (UIView *at = view; at; at = at.superview) if (at.hidden || at.alpha < 0.01) return NO;
    return view.window != nil;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    self.backgroundColor = UIColor.clearColor;
    _shape = [CAShapeLayer layer];
    _shape.fillColor = nil;
    _shape.lineCap = kCALineCapRound;
    _shape.lineJoin = kCALineJoinRound;
    _spectrum = [CAGradientLayer layer];
    _spectrum.type = kCAGradientLayerConic;
    _spectrum.startPoint = CGPointMake(0.5, 0.5);
    _spectrum.endPoint = CGPointMake(0.5, 0);
    [self.layer addSublayer:_shape];
    [self readSettings];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(readSettings) name:SGVisualizerSettingsDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(paletteChanged) name:SGCoverPaletteDidChangeNotification object:nil];
    for (NSNotificationName name in @[SGPlayerTransitionNotification, SGPlayerTransitionEndedNotification,
                                      UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification]) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(scheduleLink) name:name object:nil];
    }
    return self;
}

- (void)dealloc {
    [_link invalidate];
    if (_counted) showing(-1);
}

- (void)readSettings {
    _count = SGVisualizerBarCount();
    _style = (SGVisualizerStyle)SGInt(SGKeyVisualizerStyle, SGVisualizerStyleBars);
    _color = (SGVisualizerColor)SGInt(SGKeyVisualizerColor, SGVisualizerColorAccent);
    _mirror = SGEnabled(SGKeyVisualizerMirror);
    _widthFactor = SGVisualizerWidthFactor();
    memset(_bars, 0, sizeof _bars);
    [self applyColor:NO];
}

// A new track's colours fade in rather than cut.
- (void)paletteChanged {
    if (_color == SGVisualizerColorCover) [self applyColor:YES];
}

- (void)setAccent:(UIColor *)accent {
    if (accent == _accent || [accent isEqual:_accent]) return;
    _accent = accent;
    [self applyColor:NO];
}

- (void)applyColor:(BOOL)animated {
    UIColor *color = _color == SGVisualizerColorWhite ? UIColor.whiteColor : (_accent ?: UIColor.whiteColor);
    BOOL cover = _color == SGVisualizerColorCover;
    BOOL spectrum = _color == SGVisualizerColorSpectrum || cover;
    [CATransaction begin];
    if (animated) [CATransaction setAnimationDuration:0.8];
    else [CATransaction setDisableActions:YES];
    if (cover) {
        // Until the cover's colours are read, the accent all the way round.
        NSArray<UIColor *> *palette = SGCoverPaletteForPlayingTrack() ?: @[color];
        NSMutableArray *stops = [NSMutableArray array];
        for (UIColor *stop in SGCoverGradientStops(palette, _mirror)) [stops addObject:(id)stop.CGColor];
        if (stops.count == 1) [stops addObject:stops[0]];
        _spectrum.colors = stops;
    } else if (spectrum) {
        _spectrum.colors = [SGVisualizerView hues];
    }
    if (spectrum) {
        _shape.strokeColor = UIColor.whiteColor.CGColor;
        _shape.fillColor = _style == SGVisualizerStyleDots ? UIColor.whiteColor.CGColor : nil;
        if (_spectrum.superlayer != self.layer) {
            [_shape removeFromSuperlayer];
            [self.layer addSublayer:_spectrum];
            _spectrum.mask = _shape;
        }
    } else {
        if (_spectrum.superlayer) {
            _spectrum.mask = nil;
            [_spectrum removeFromSuperlayer];
            [self.layer addSublayer:_shape];
        }
        _shape.strokeColor = color.CGColor;
        _shape.fillColor = _style == SGVisualizerStyleDots ? color.CGColor : nil;
    }
    [CATransaction commit];
}

+ (NSArray *)hues {
    static NSArray *hues;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *list = [NSMutableArray array];
        for (int i = 0; i <= 12; i++) [list addObject:(id)[UIColor colorWithHue:i / 12.0 saturation:0.75 brightness:1 alpha:1].CGColor];
        hues = list;
    });
    return hues;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _shape.frame = self.bounds;
    _spectrum.frame = self.bounds;
    [CATransaction commit];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self scheduleLink];
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    [self scheduleLink];
}

// Runs while it can be seen; whether it is counted as a ring on screen follows the link.
- (void)scheduleLink {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(scheduleLink) object:nil];
    BOOL visible = self.window && !self.hidden && UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
    NSTimeInterval wait = SGPlayerTransitionEnds() - CACurrentMediaTime();
    BOOL run = visible && wait <= 0;
    if (visible && wait > 0) [self performSelector:@selector(scheduleLink) withObject:nil afterDelay:wait + 0.05 inModes:@[NSRunLoopCommonModes]];
    if (visible != _counted) {
        _counted = visible;
        showing(visible ? 1 : -1);
    }
    if (run && !_link) {
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        _link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        _last = 0;
    } else if (!run && _link) {
        [_link invalidate];
        _link = nil;
    }
}

- (void)tick:(CADisplayLink *)link {
    // Faded out with the cover (a clip over the field, the lyrics in the player), or inside something hidden
    // or faded (asked twice a second, a walk up the views being too dear for every frame): nothing to draw.
    if (_frames++ % 30 == 0) {
        _covered = !onScreen(self);
        // A new track's cover is noticed here: the read is kicked off and the notification brings it in.
        if (_color == SGVisualizerColorCover) SGCoverPaletteForPlayingTrack();
    }
    if (self.alpha < 0.01 || _covered) {
        _last = 0;
        return;
    }
    float elapsed = _last > 0 ? (float)(link.targetTimestamp - _last) : 1 / 60.0f;
    _last = link.targetTimestamp;
    // A mirrored ring shows each band twice, so it reads half as many.
    NSInteger bands = _mirror ? MAX(8, _count / 2) : _count;
    SGVisualizerReadBars(_bars, bands, elapsed);
    [self drawBands:bands];
}

- (void)drawBands:(NSInteger)bands {
    CGRect bounds = self.bounds;
    CGPoint centre = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    CGFloat outer = MIN(bounds.size.width, bounds.size.height) / 2 - kOuterInset;
    CGFloat inner = MAX(4, MIN(self.innerRadius + kGap, outer - 8));
    CGFloat reach = outer - inner;
    NSInteger count = _mirror ? bands * 2 : bands;
    if (count <= 0 || reach <= 0) return;
    CGFloat step = 2 * M_PI / count;
    // A bar is a share of the room it has, never wider than that room, and at a thousand bars never thinner
    // than a hairline; the width choice is a bigger or smaller share.
    CGFloat room = inner * step;
    CGFloat width = MIN(8 * _widthFactor, room * 0.55 * _widthFactor);
    width = MIN(width, MAX(0.75, room * 0.95));
    width = MAX(width, MIN(1.5, room * 1.1));
    if (count != _angles) {
        for (NSInteger i = 0; i < count; i++) {
            CGFloat angle = -M_PI_2 + (i + 0.5) * step;
            _cos[i] = (float)cos(angle);
            _sin[i] = (float)sin(angle);
        }
        _angles = count;
    }
    UIBezierPath *path = [UIBezierPath bezierPath];
    for (NSInteger i = 0; i < count; i++) {
        // Mirrored, the lowest band is at the top and the highest meets itself at the bottom.
        NSInteger band = _mirror ? (i < bands ? i : count - 1 - i) : i;
        CGFloat value = _bars[band];
        CGFloat dx = _cos[i], dy = _sin[i];
        CGFloat out = inner + MAX(width * 0.5, value * reach);
        switch (_style) {
            case SGVisualizerStyleBars:
                [path moveToPoint:CGPointMake(centre.x + dx * inner, centre.y + dy * inner)];
                [path addLineToPoint:CGPointMake(centre.x + dx * out, centre.y + dy * out)];
                break;
            case SGVisualizerStyleWave:
                if (i == 0) [path moveToPoint:CGPointMake(centre.x + dx * out, centre.y + dy * out)];
                else [path addLineToPoint:CGPointMake(centre.x + dx * out, centre.y + dy * out)];
                break;
            case SGVisualizerStyleDots: {
                CGFloat r = width * 0.6;
                CGPoint at = CGPointMake(centre.x + dx * out, centre.y + dy * out);
                [path moveToPoint:CGPointMake(at.x + r, at.y)];
                [path addArcWithCenter:at radius:r startAngle:0 endAngle:2 * M_PI clockwise:YES];
                break;
            }
        }
    }
    if (_style == SGVisualizerStyleWave) [path closePath];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _shape.lineWidth = _style == SGVisualizerStyleWave ? MAX(1.5, 2.5 * _widthFactor) : _style == SGVisualizerStyleDots ? 0 : width;
    _shape.path = path.CGPath;
    [CATransaction commit];
}

@end

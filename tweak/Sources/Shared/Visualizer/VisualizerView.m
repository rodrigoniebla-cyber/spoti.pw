// The visualiser live: a frame per screen refresh while the view is on screen and showing. Each frame
// reads the samples being heard right then (VisualizerTap.x), analyses them and draws them.
//
// The display link asks for up to 120 Hz: one capped at 60 would drag the player's own transitions down
// with it. It only runs while the view is in a window, not transparent and on the screen, so the
// neighbouring covers in the player's list, and a player that is closed, cost nothing. Drawing is at
// twice the points rather than the screen's three times, which the eye does not miss on moving shapes.
#import <mach/mach_time.h>
#import <QuartzCore/QuartzCore.h>
#import "Core/SGCore.h"
#import "Visualizer.h"

@interface SGVisualizerView ()
- (void)tick:(CADisplayLink *)link;
@end

// The display link holds its target strongly; this holds the view weakly.
@interface SGVizLinkTarget : NSObject
@property (nonatomic, weak) SGVisualizerView *view;
@end

@implementation SGVizLinkTarget
- (void)tick:(CADisplayLink *)link {
    SGVisualizerView *view = self.view;
    if (view) [view tick:link];
    else [link invalidate];
}
@end

@implementation SGVisualizerView {
    CADisplayLink *_link;
    SGVizAnalyzer *_analyzer;
    SGVizRenderer *_renderer;
    SGVizFrame _frame;
    SGVizSettings _settings;
    NSUInteger _generation;
    CFTimeInterval _last, _drawnAt;
    float _samples[SGVizWindow];
    BOOL _listening;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.opaque = YES;
    self.backgroundColor = UIColor.blackColor;
    self.contentScaleFactor = MIN(2, UIScreen.mainScreen.scale);
    self.userInteractionEnabled = NO;
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Music visualiser";
    _analyzer = [SGVizAnalyzer new];
    _renderer = [SGVizRenderer new];
    _frame.bandCount = 48;
    return self;
}

- (void)dealloc {
    [_link invalidate];
    if (_listening) SGVisualizerTapRelease();
}

- (void)setArtwork:(UIImage *)artwork {
    if (artwork == _artwork) return;
    _artwork = artwork;
    _renderer.artwork = artwork;
    [self setNeedsDisplay];
}

// Shown, in a window, and at least partly on its screen.
- (BOOL)showing {
    UIWindow *window = self.window;
    if (!window || self.hidden || self.alpha < 0.01) return NO;
    for (UIView *view = self.superview; view; view = view.superview) {
        if (view.hidden || view.alpha < 0.01) return NO;
    }
    return CGRectIntersectsRect([self convertRect:self.bounds toView:window], window.bounds);
}

- (void)update {
    BOOL want = self.window && !self.hidden && self.alpha > 0.01;
    if (want && !_link) {
        SGVizLinkTarget *target = [SGVizLinkTarget new];
        target.view = self;
        _link = [CADisplayLink displayLinkWithTarget:target selector:@selector(tick:)];
        if (@available(iOS 15.0, *)) _link.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 120);
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        _last = 0;
    } else if (!want && _link) {
        [_link invalidate];
        _link = nil;
    }
    if (want != _listening) {
        _listening = want;
        if (want) SGVisualizerTapRetain();
        else SGVisualizerTapRelease();
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self update];
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    [self update];
}

- (void)setAlpha:(CGFloat)alpha {
    [super setAlpha:alpha];
    [self update];
}

- (void)tick:(CADisplayLink *)link {
    if (![self showing]) return;
    CFTimeInterval now = link.timestamp;
    double dt = _last ? now - _last : 1.0 / 60;
    _last = now;
    NSUInteger generation = SGVisualizerSettingsGeneration();
    if (generation != _generation) {
        _generation = generation;
        _settings = SGVisualizerSettings();
    }
    // The samples heard as this frame reaches the screen.
    double rate = SGVisualizerTapRead(_samples, SGVizWindow, mach_absolute_time());
    if (rate > 0) [_analyzer analyze:_samples count:SGVizWindow rate:rate settings:&_settings frame:&_frame dt:dt];
    else [_analyzer decay:&_frame dt:dt];
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    if (!_generation) {
        _generation = SGVisualizerSettingsGeneration();
        _settings = SGVisualizerSettings();
    }
    CFTimeInterval now = CACurrentMediaTime();
    double dt = _drawnAt ? now - _drawnAt : 1.0 / 60;
    _drawnAt = now;
    [_renderer drawFrame:&_frame settings:&_settings inContext:UIGraphicsGetCurrentContext() size:self.bounds.size dt:dt];
}

@end

// The music visualiser: Spotify's own sound, taken off its output as it plays, drawn in real time in
// place of the player's cover (a tap on the cover switches between the two, under either look), and made
// into a looping clip for the lock screen's animated artwork, where it stands in when a track has no
// Canvas or Apple Music cover.
//
//     VisualizerTap.x        a render notify on Spotify's RemoteIO unit: the sound, mono, into a ring
//     VisualizerAnalysis.m   the ring's latest window as bands, bass, mids, highs, beats and a waveform
//     VisualizerRenderer.m   one frame drawn: styles, colours, backgrounds, particles, glow
//     VisualizerView.m       the view over the cover, a frame per screen refresh
//     VisualizerCover.m      the cover's tap and layout, handed over by either look's PlayerGestures.x
//     VisualizerClip.m       the lock screen's clip, rendered from a stretch of the track's own analysis
//     VisualizerSettings.m   its page, and the settings every frame reads
//
// Every setting applies at once: the renderer reads them again whenever the defaults change.
#import <UIKit/UIKit.h>

@class SGModSection;

#define SGKeyVisualizer @"spotifyglass.visualizer"                    // the tap on the cover shows it
#define SGKeyVisualizerShown @"spotifyglass.visualizer.shown"         // showing now, rather than the cover
#define SGKeyVisualizerStyle @"spotifyglass.visualizer.style"
#define SGKeyVisualizerColors @"spotifyglass.visualizer.colors"
#define SGKeyVisualizerColor1 @"spotifyglass.visualizer.color1"       // #rrggbb
#define SGKeyVisualizerColor2 @"spotifyglass.visualizer.color2"
#define SGKeyVisualizerBackground @"spotifyglass.visualizer.background"
#define SGKeyVisualizerBackgroundColor @"spotifyglass.visualizer.backgroundColor"
#define SGKeyVisualizerCover @"spotifyglass.visualizer.cover"         // the cover in the middle of the round styles
#define SGKeyVisualizerGlow @"spotifyglass.visualizer.glow"
#define SGKeyVisualizerFollows @"spotifyglass.visualizer.follows"
#define SGKeyVisualizerBars @"spotifyglass.visualizer.bars"
#define SGKeyVisualizerSensitivity @"spotifyglass.visualizer.sensitivity"
#define SGKeyVisualizerSmoothing @"spotifyglass.visualizer.smoothing"
#define SGKeyVisualizerSpin @"spotifyglass.visualizer.spin"
#define SGKeyVisualizerParticles @"spotifyglass.visualizer.particles"
#define SGKeyVisualizerParticleAmount @"spotifyglass.visualizer.particleAmount"
#define SGKeyVisualizerParticleTrigger @"spotifyglass.visualizer.particleTrigger"
#define SGKeyVisualizerParticleShape @"spotifyglass.visualizer.particleShape"

typedef NS_ENUM(NSInteger, SGVizStyle) {
    SGVizStyleBars, SGVizStyleMirror, SGVizStyleRadial, SGVizStyleWave, SGVizStyleSpectrum, SGVizStyleRings, SGVizStyleParticlesOnly,
};
typedef NS_ENUM(NSInteger, SGVizColors) { SGVizColorsAlbum, SGVizColorsRainbow, SGVizColorsWhite, SGVizColorsCustom };
typedef NS_ENUM(NSInteger, SGVizBackground) { SGVizBackgroundSong, SGVizBackgroundBlurred, SGVizBackgroundBlack, SGVizBackgroundColor };
typedef NS_ENUM(NSInteger, SGVizFollows) { SGVizFollowsAll, SGVizFollowsBass, SGVizFollowsMids, SGVizFollowsHighs, SGVizFollowsVocals };
typedef NS_ENUM(NSInteger, SGVizTrigger) { SGVizTriggerBeat, SGVizTriggerBass, SGVizTriggerLevel, SGVizTriggerHighs };
typedef NS_ENUM(NSInteger, SGVizParticleShape) { SGVizParticleDots, SGVizParticleSparks, SGVizParticleSquares, SGVizParticleRings };

// Every setting at once, read from the defaults.
typedef struct {
    SGVizStyle style;
    SGVizColors colors;
    SGVizBackground background;
    SGVizFollows follows;
    SGVizTrigger trigger;
    SGVizParticleShape particleShape;
    BOOL cover, glow, particles;
    NSInteger bars;
    float sensitivity, smoothing, spin, particleAmount;   // sensitivity 0.5...2.5, the others 0...1
    CGFloat color1[3], color2[3], backgroundColor[3];     // sRGB
} SGVizSettings;

SGVizSettings SGVisualizerSettings(void);
// Bumped whenever the defaults change, so a renderer knows to read them again.
NSUInteger SGVisualizerSettingsGeneration(void);

#pragma mark - the sound

enum { SGVizMostBands = 128, SGVizWaveformPoints = 256 };

// One moment of the sound, as the renderer draws it. Values run 0...1, a little over on a loud hit.
typedef struct {
    float bands[SGVizMostBands];
    NSInteger bandCount;
    float bass, mids, highs, level;
    BOOL beat;                                  // a kick just now
    float waveform[SGVizWaveformPoints];        // -1...1
    BOOL silent;                                // nothing playing: the renderer lets everything fall
} SGVizFrame;

// VisualizerTap.x. Someone wants the sound: the notify reads the buffers only while at least one asks.
void SGVisualizerTapRetain(void);
void SGVisualizerTapRelease(void);
// The `count` latest samples heard at host time `atHostTime` (mach_absolute_time), the output's latency
// taken off; the sample rate, or 0 when nothing has played for a moment. Any thread.
double SGVisualizerTapRead(float *samples, NSInteger count, uint64_t atHostTime);

// VisualizerAnalysis.m. One analyser per reader (the view, the clip), since each smooths on its own.
@interface SGVizAnalyzer : NSObject
// Fills `frame` from the samples, the settings saying which bands and how much smoothing.
- (void)analyze:(const float *)samples count:(NSInteger)count rate:(double)rate settings:(const SGVizSettings *)settings
          frame:(SGVizFrame *)frame dt:(double)dt;
// Nothing playing: everything falls to rest.
- (void)decay:(SGVizFrame *)frame dt:(double)dt;
@end
enum { SGVizWindow = 2048 };

#pragma mark - drawing

@interface SGVizRenderer : NSObject
@property (nonatomic, strong) UIImage *artwork;   // the song's cover: background, palette, the middle
- (void)drawFrame:(const SGVizFrame *)frame settings:(const SGVizSettings *)settings inContext:(CGContextRef)context
             size:(CGSize)size dt:(double)dt;
@end

// VisualizerView.m: the visualiser live, drawing while it is on screen.
@interface SGVisualizerView : UIView
@property (nonatomic, strong) UIImage *artwork;
@end

#pragma mark - the player's cover

// Called by either look's PlayerGestures.x from CoverArtTiltView. A tap: YES when it switched between the
// cover and the visualiser, and Spotify's own tilt mode is to be left out. Layout: the visualiser put on
// the player's cover (not the bar's small one), shown or not as the last tap left it.
BOOL SGVisualizerCoverTapped(UIView *tiltView);
void SGVisualizerCoverLaidOut(UIView *tiltView);

#pragma mark - the lock screen

// VisualizerClip.m: a looping clip of the visualiser for the track `uri`, `aspect` wide over tall, made
// from its sound once enough of it has played; `done` on the main queue with the file, or nil and why.
// A request for another track drops the one before it.
void SGVisualizerClipFor(NSString *uri, UIImage *artwork, CGFloat aspect, void (^done)(NSURL *file, NSString *note));

// VisualizerSettings.m: the Visualiser page.
UIViewController *SGVisualizerSettingsPage(void);

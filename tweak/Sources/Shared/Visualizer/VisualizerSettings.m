// The visualiser's settings, read for the renderer whenever the defaults change, and its page.
// Everything on it applies at once: the view reads them again on the next frame.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/LockScreenArtwork/LockScreenArtwork.h"
#import "Visualizer.h"

static NSUInteger sg_generation = 1;

NSUInteger SGVisualizerSettingsGeneration(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) { sg_generation++; }];
    });
    return sg_generation;
}

static double number(NSString *key, double fallback) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

static void readColor(NSString *key, CGFloat rgb[3], uint32_t fallback) {
    NSString *text = [NSUserDefaults.standardUserDefaults stringForKey:key];
    unsigned value = fallback;
    if (text.length == 7 && [text hasPrefix:@"#"]) [[NSScanner scannerWithString:[text substringFromIndex:1]] scanHexInt:&value];
    rgb[0] = ((value >> 16) & 0xff) / 255.0;
    rgb[1] = ((value >> 8) & 0xff) / 255.0;
    rgb[2] = (value & 0xff) / 255.0;
}

SGVizSettings SGVisualizerSettings(void) {
    SGVizSettings settings = {0};
    settings.style = (SGVizStyle)SGInt(SGKeyVisualizerStyle, SGVizStyleRadial);
    settings.colors = (SGVizColors)SGInt(SGKeyVisualizerColors, SGVizColorsAlbum);
    settings.background = (SGVizBackground)SGInt(SGKeyVisualizerBackground, SGVizBackgroundSong);
    settings.follows = (SGVizFollows)SGInt(SGKeyVisualizerFollows, SGVizFollowsAll);
    settings.trigger = (SGVizTrigger)SGInt(SGKeyVisualizerParticleTrigger, SGVizTriggerBeat);
    settings.particleShape = (SGVizParticleShape)SGInt(SGKeyVisualizerParticleShape, SGVizParticleDots);
    settings.cover = SGFlag(SGKeyVisualizerCover, YES);
    settings.glow = SGFlag(SGKeyVisualizerGlow, YES);
    settings.particles = SGFlag(SGKeyVisualizerParticles, YES);
    settings.bars = (NSInteger)number(SGKeyVisualizerBars, 48);
    settings.sensitivity = (float)number(SGKeyVisualizerSensitivity, 1.0);
    settings.smoothing = (float)number(SGKeyVisualizerSmoothing, 0.6);
    settings.spin = (float)number(SGKeyVisualizerSpin, 0.2);
    settings.particleAmount = (float)number(SGKeyVisualizerParticleAmount, 0.5);
    readColor(SGKeyVisualizerColor1, settings.color1, 0x1ED760);
    readColor(SGKeyVisualizerColor2, settings.color2, 0x8A2BE2);
    readColor(SGKeyVisualizerBackgroundColor, settings.backgroundColor, 0x101018);
    return settings;
}

#pragma mark - colour rows

@interface SGVizColorPicker : NSObject <UIColorPickerViewControllerDelegate>
@property (nonatomic, copy) NSString *key;
@end

@implementation SGVizColorPicker
- (void)colorPickerViewController:(UIColorPickerViewController *)picker didSelectColor:(UIColor *)color continuously:(BOOL)continuously {
    CGFloat r = 0, g = 0, b = 0;
    [color getRed:&r green:&g blue:&b alpha:NULL];
    NSString *text = [NSString stringWithFormat:@"#%02X%02X%02X", (int)lround(MAX(0, MIN(1, r)) * 255), (int)lround(MAX(0, MIN(1, g)) * 255),
                      (int)lround(MAX(0, MIN(1, b)) * 255)];
    [NSUserDefaults.standardUserDefaults setObject:text forKey:self.key];
}
@end

static SGVizColorPicker *sg_picker;

static void pickColor(NSString *key, NSString *title) {
    CGFloat rgb[3];
    readColor(key, rgb, [key isEqualToString:SGKeyVisualizerColor1] ? 0x1ED760 : [key isEqualToString:SGKeyVisualizerColor2] ? 0x8A2BE2 : 0x101018);
    UIColorPickerViewController *picker = [UIColorPickerViewController new];
    picker.title = title;
    picker.supportsAlpha = NO;
    picker.selectedColor = [UIColor colorWithRed:rgb[0] green:rgb[1] blue:rgb[2] alpha:1];
    sg_picker = [SGVizColorPicker new];
    sg_picker.key = key;
    picker.delegate = sg_picker;
    [SGTopController() presentViewController:picker animated:YES completion:nil];
}

static SGModRow *colorRow(NSString *title, NSString *key, BOOL (^visible)(void)) {
    SGModRow *row = SGStatActionRow(title, nil, ^NSString *{
        return [NSUserDefaults.standardUserDefaults stringForKey:key] ?: @"Default";
    }, ^{ pickColor(key, title); });
    row.visible = visible;
    return row;
}

static SGModRow *percentRow(NSString *title, NSString *key, double fallback, double minimum, double maximum) {
    return SGSliderRow(title, nil, minimum, maximum, 0.05, ^double { return number(key, fallback); },
                       ^(double value) { [NSUserDefaults.standardUserDefaults setDouble:value forKey:key]; },
                       ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f%%", value * 100]; });
}

#pragma mark - the page

// Where the visualiser stands among the lock screen's artwork sources.
static SGModRow *lockRow(void) {
    return SGStatRow(@"On the lock screen", ^NSString *{
        if (!SGAnimatedArtworkAvailable()) return @"Needs iOS 26";
        if (!SGFlag(SGKeyLockScreenArtwork, YES)) return @"Animated lock screen off";
        NSArray<NSString *> *order = SGArtworkOrderFor(SGKeyLockScreenArtworkSources);
        NSUInteger at = [order indexOfObject:SGArtworkSourceVisualizer];
        if (at == NSNotFound) return @"Off";
        return at == 0 ? @"Every song" : @"When there is no clip";
    });
}

UIViewController *SGVisualizerSettingsPage(void) {
    BOOL (^on)(void) = ^BOOL { return SGFlag(SGKeyVisualizer, NO); };
    BOOL (^round)(void) = ^BOOL {
        NSInteger style = SGInt(SGKeyVisualizerStyle, SGVizStyleRadial);
        return on() && (style == SGVizStyleRadial || style == SGVizStyleRings || style == SGVizStyleParticlesOnly);
    };
    BOOL (^custom)(void) = ^BOOL { return on() && SGInt(SGKeyVisualizerColors, SGVizColorsAlbum) == SGVizColorsCustom; };
    BOOL (^particles)(void) = ^BOOL { return on() && SGFlag(SGKeyVisualizerParticles, YES); };

    SGModRow *style = SGChoiceRow(@"Style", nil, SGKeyVisualizerStyle,
                                  @[@"Bars", @"Mirrored bars", @"Radial", @"Wave", @"Spectrum", @"Rings", @"Particles only"], SGVizStyleRadial);
    SGModRow *colors = SGChoiceRow(@"Colours", nil, SGKeyVisualizerColors, @[@"From the album art", @"Rainbow", @"White", @"Custom"], SGVizColorsAlbum);
    SGModRow *background = SGChoiceRow(@"Background", nil, SGKeyVisualizerBackground,
                                       @[@"Song image", @"Blurred song image", @"Black", @"Colour"], SGVizBackgroundSong);
    SGModRow *cover = SGSwitchRow(@"Cover in the middle", @"For the round styles", SGKeyVisualizerCover);
    cover.visible = round;
    SGModRow *spin = percentRow(@"Spin", SGKeyVisualizerSpin, 0.2, 0, 1);
    spin.visible = round;
    SGModRow *backgroundColor = colorRow(@"Background colour", SGKeyVisualizerBackgroundColor, ^BOOL {
        return on() && SGInt(SGKeyVisualizerBackground, SGVizBackgroundSong) == SGVizBackgroundColor;
    });
    SGModRow *follows = SGChoiceRow(@"Follows", nil, SGKeyVisualizerFollows, @[@"Whole spectrum", @"Bass", @"Mids", @"Highs", @"Vocals"], SGVizFollowsAll);
    SGModRow *bars = SGSliderRow(@"Bars", nil, 16, 128, 8, ^double { return number(SGKeyVisualizerBars, 48); },
                                 ^(double value) { [NSUserDefaults.standardUserDefaults setDouble:value forKey:SGKeyVisualizerBars]; },
                                 ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f", value]; });
    SGModRow *particlesOn = SGSwitchRow(@"Particles", nil, SGKeyVisualizerParticles);
    SGModRow *amount = percentRow(@"Amount", SGKeyVisualizerParticleAmount, 0.5, 0.05, 1);
    SGModRow *trigger = SGChoiceRow(@"React to", nil, SGKeyVisualizerParticleTrigger, @[@"The beat", @"Bass", @"Loudness", @"Highs"], SGVizTriggerBeat);
    SGModRow *shape = SGChoiceRow(@"Shape", nil, SGKeyVisualizerParticleShape, @[@"Dots", @"Sparks", @"Squares", @"Rings"], SGVizParticleDots);

    NSArray<SGModRow *> *lookRows = @[style, colors, colorRow(@"Colour 1", SGKeyVisualizerColor1, custom), colorRow(@"Colour 2", SGKeyVisualizerColor2, custom),
                                      background, backgroundColor, cover, spin, SGSwitchRow(@"Glow", nil, SGKeyVisualizerGlow)];
    NSArray<SGModRow *> *soundRows = @[follows, bars, percentRow(@"Sensitivity", SGKeyVisualizerSensitivity, 1, 0.5, 2.5),
                                       percentRow(@"Smoothing", SGKeyVisualizerSmoothing, 0.6, 0, 0.95)];
    for (SGModRow *row in [lookRows arrayByAddingObjectsFromArray:soundRows]) {
        if (!row.visible) row.visible = on;
    }
    particlesOn.visible = on;
    for (SGModRow *row in @[amount, trigger, shape]) row.visible = particles;

    SGModRow *main = SGOptionRow(@"Visualiser", @"Tap the player's cover to switch between it and the visualiser", SGKeyVisualizer);
    main.changed = ^(BOOL value) {};
    return [[SGModPage alloc] initWithTitle:@"Visualiser" intro:nil sections:@[
        SGSection(nil, @[main]),
        SGSection(@"Look", lookRows),
        SGSection(@"Sound", soundRows),
        SGSection(@"Particles", @[particlesOn, amount, trigger, shape]),
        SGNotedSection(@"Lock screen", @[lockRow()], @"From iOS 26 the lock screen can show the visualiser too: a looping clip made from the song as it plays, "
                       "since iOS takes only a video there. It is one of the sources under Player › Lock screen widget › Sources, "
                       "after Canvas and Apple Music, so it shows when a track has neither; move it up to see it on every song."),
    ] footer:nil];
}

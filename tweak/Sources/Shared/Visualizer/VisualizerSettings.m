// The visualizer's rows (Visualizer.h): the same strength and choice of what to follow as Music Haptics, or
// Music Haptics' own with a switch, then how many bars, their style and colour, and the mirror. Each row
// applies at once and tells every ring.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/Haptics/Haptics.h"
#import "Visualizer.h"

NSNotificationName const SGVisualizerSettingsDidChangeNotification = @"spotifyglass.visualizerChanged";

static NSArray<NSNumber *> *counts(void) { return @[@48, @64, @96, @128]; }

NSInteger SGVisualizerBarCount(void) {
    NSArray<NSNumber *> *list = counts();
    NSInteger index = SGInt(SGKeyVisualizerBars, 1);
    return list[(NSUInteger)MAX(0, MIN((NSInteger)list.count - 1, index))].integerValue;
}

static void changed(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:SGVisualizerSettingsDidChangeNotification object:nil];
}

NSArray<SGModRow *> *SGVisualizerRows(NSString *waitsOnKey) {
    BOOL (^own)(void) = ^BOOL { return !SGFlag(SGKeyVisualizerLikeHaptics, NO); };
    SGModRow *likeHaptics = SGOptionRow(@"Same as Music Haptics", @"Its strength and what it follows", SGKeyVisualizerLikeHaptics);
    likeHaptics.changed = ^(BOOL on) { changed(); };
    SGModRow *strength = SGSliderRow(@"Strength", nil, SGMusicStrengthMin, SGMusicStrengthMax, SGStrengthStep,
        ^double { return SGInt(SGKeyVisualizerStrength, 100); },
        ^(double value) { SGSetInt(SGKeyVisualizerStrength, (NSInteger)lround(value)); changed(); },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%ld %%", lround(value)]; });
    strength.visible = own;
    SGModRow *follows = SGChoiceRow(@"Follows", nil, SGKeyVisualizerFollows, @[@"Everything", @"Beat", @"Bass"], SGMusicFollowsEverything);
    follows.choiceNotes = @[@"Every band at its level", @"The drums jump out of the rest", @"The low end, all the way round"];
    follows.chosen = ^(NSInteger index) { changed(); };
    follows.visible = own;
    SGModRow *bars = SGChoiceRow(@"Bars", nil, SGKeyVisualizerBars, @[@"48", @"64", @"96", @"128"], 1);
    bars.chosen = ^(NSInteger index) { changed(); };
    SGModRow *style = SGChoiceRow(@"Style", nil, SGKeyVisualizerStyle, @[@"Bars", @"Wave", @"Dots"], SGVisualizerStyleBars);
    style.chosen = ^(NSInteger index) { changed(); };
    SGModRow *color = SGChoiceRow(@"Colour", nil, SGKeyVisualizerColor, @[@"Accent", @"White", @"Spectrum"], SGVisualizerColorAccent);
    color.chosen = ^(NSInteger index) { changed(); };
    SGModRow *mirror = SGSwitchRow(@"Mirror", @"Each side the other's reflection", SGKeyVisualizerMirror);
    mirror.changed = ^(BOOL on) { changed(); };
    NSArray<SGModRow *> *rows = @[likeHaptics, strength, follows, bars, style, color, mirror];
    if (waitsOnKey) for (SGModRow *row in rows) SGWaitsOn(row, waitsOnKey, NO);
    return rows;
}

static NSArray<NSNumber *> *rates(void) { return @[@6, @10, @15]; }

NSInteger SGLockScreenVisualizerFramesPerSecond(void) {
    NSArray<NSNumber *> *list = rates();
    NSInteger index = SGInt(SGKeyLockScreenVisualizerRate, 1);
    return list[(NSUInteger)MAX(0, MIN((NSInteger)list.count - 1, index))].integerValue;
}

NSArray<SGModRow *> *SGLockScreenVisualizerRows(void) {
    SGModRow *on = SGOptionRow(@"Lock screen visualizer", @"The cover in a ring of bars, as the artwork", SGKeyLockScreenVisualizer);
    SGModRow *rate = SGChoiceRow(@"Lock screen frames", nil, SGKeyLockScreenVisualizerRate, @[@"6 a second", @"10 a second", @"15 a second"], 1);
    rate.choiceNotes = @[@"Lightest on the battery", @"Smooth enough to follow the beat", @"Smoothest, and the most battery"];
    rate.choiceFooter = @"The lock screen draws a new picture each time, so it never moves as smoothly as the ring in the player.";
    SGWaitsOn(rate, SGKeyLockScreenVisualizer, NO);
    return @[on, rate];
}

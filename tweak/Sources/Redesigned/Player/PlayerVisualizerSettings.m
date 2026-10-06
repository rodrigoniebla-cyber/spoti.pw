// The Player page's Visualizer card (Player.h): the switch that rings the cover with bars, the spin, and
// under them the ring's own settings (Shared/Visualizer), all applying at once.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/Visualizer/Visualizer.h"
#import "Player.h"

NSArray<SGModSection *> *SGRPlayerVisualizerSections(void) {
    void (^tell)(BOOL) = ^(BOOL on) {
        [NSNotificationCenter.defaultCenter postNotificationName:SGVisualizerSettingsDidChangeNotification object:nil];
    };
    SGModRow *on = SGWithSymbol(SGOptionRow(@"Visualizer", @"Bars round the cover, moving with the music", SGRKeyPlayerVisualizer),
                                @"circle.dotted.circle");
    on.changed = tell;
    SGModRow *spin = SGWaitsOn(SGSwitchRow(@"Spin the cover", @"Slowly, while the song plays", SGRKeyPlayerVisualizerSpin),
                               SGRKeyPlayerVisualizer, NO);
    spin.changed = tell;
    NSMutableArray<SGModRow *> *rows = [NSMutableArray arrayWithObjects:on, spin, nil];
    [rows addObjectsFromArray:SGVisualizerRows(SGRKeyPlayerVisualizer)];
    NSArray<SGModRow *> *lockScreen = SGLockScreenVisualizerRows();
    return @[SGNotedSection(@"Visualizer", rows,
        @"The cover becomes a circle with the bars round it, like an NCS video. It listens to what you hear, after speed, "
         "pitch and audio effects, only while the player is on screen. Strength and Follows work as Music Haptics' do."),
             SGNotedSection(@"Lock screen", lockScreen, @"The lock screen's artwork becomes the cover in the ring, drawn again several "
                            "times a second while the song plays, in the style and colour above. With lock screen lyrics showing the "
                            "line as the artwork, the line sits under the ring. An animated cover (Canvas) shows over it. Applies after you restart Spotify.")];
}

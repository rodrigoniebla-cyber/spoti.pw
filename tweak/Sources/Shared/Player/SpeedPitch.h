// Speed and pitch: two sliders in the more button's menu, done to Spotify's sound, under either look.
// Nothing here draws on a Spotify screen of its own: the block goes into Spotify's own context menu
// sheet, and the rest is audio.
//
//     SpeedPitchMenu.x   the expandable row and its two sliders, put into Spotify's context menu
//     SpeedPitch.x       speed and pitch done to Spotify's audio, between its mixer and its speaker unit
//     SGTimePitch.m      Apple's time and pitch unit, pulling the mixer or working in place
//     SpeedPitchPresets.m      the named presets, stored
//     SpeedPitchIntents.swift  a preset set by Siri or Shortcuts
//
// Speed and pitch last until Spotify quits; neither is stored. The presets are.
// Threading: main thread only, except what SGTimePitch.h says runs on the render thread.
#import <UIKit/UIKit.h>

// Marks a menu opened soon after a tap on `button`, the player's more button, as the player's, so it gets
// Speed and pitch (watching it twice does nothing). The redesign's PlayerHeader.x hands its button over;
// a menu presented from a now playing controller is taken for the player's without it, which is how the
// native look's player gets the block.
void SGPlayerMenuWatchMoreButton(UIView *button);
// The speed Spotify's sound plays at, 1 when normal.
double SGPlayerSpeed(void);
// Whether speed can apply: Spotify's output was taken over when it wired it.
BOOL SGPlayerSpeedAllowed(void);
void SGSetPlayerSpeed(double speed);
// Semitones Spotify's output is moved by, 0 when it is not.
float SGPlayerPitch(void);
void SGSetPlayerPitch(float semitones);
// Whether the output could be reached to change its pitch.
BOOL SGPlayerPitchAvailable(void);

// Presets (SpeedPitchPresets.m): speed and pitch under a name, set from the menu or by Siri and
// Shortcuts (SpeedPitchIntents.swift). The list is the user's to add to and take from, stored as
// [{name, speed, pitch}] and filled with a few to start with the first time it is read.
#define SGKeySpeedPitchPresets @"spotifyglass.speedPitchPresets"
// Posted on the main thread whenever speed or pitch was set from outside the menu (a preset from Siri),
// so an open menu shows it.
extern NSString *const SGSpeedPitchChangedNotification;

@interface SGSpeedPitchPreset : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) float speed, pitch;
@end

NSArray<SGSpeedPitchPreset *> *SGSpeedPitchPresets(void);
// The preset speed and pitch are at, nil when they are at none.
SGSpeedPitchPreset *SGSpeedPitchPresetAt(float speed, float pitch);
// Saves under `name`, replacing a preset of the same name (whatever its case) in its place.
void SGSpeedPitchSavePreset(NSString *name, float speed, float pitch);
void SGSpeedPitchDeletePreset(NSString *name);
// Sets speed and pitch to the preset named, as far as each can go here; NO when there is no such
// preset or neither could be set. Main thread.
BOOL SGSpeedPitchApplyPreset(NSString *name);
// Has Siri learn the presets' names again; the list's own changes call it, and the menu once at launch.
void SGSpeedPitchPresetsChanged(void);

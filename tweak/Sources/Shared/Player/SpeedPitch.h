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
// Speed and pitch last until Spotify quits; neither is stored. Whether pitch follows speed is, and so are the presets.
// Threading: main thread only, except what SGTimePitch.h says runs on the render thread.
#import <UIKit/UIKit.h>

// Marks a menu opened soon after a tap on `button`, the player's more button, as the player's, so it gets
// Speed and pitch (watching it twice does nothing). The redesign's PlayerHeader.x hands its button over;
// a menu presented from a now playing controller is taken for the player's without it, which is how the
// native look's player gets the block.
void SGPlayerMenuWatchMoreButton(UIView *button);
// The two sliders alone, for a menu of a look's own that draws its own row for them (the redesign's
// player menu, Redesigned/Player/PlayerMenu.x): SGSpeedPitchPanelHeight() tall at whatever width it is
// given, showing the player's values as it is made.
UIView *SGSpeedPitchPanelMake(void);
CGFloat SGSpeedPitchPanelHeight(void);
// What the row says beside its name, the speed and the pitch where either is changed ("1.25×  +2 st"),
// nil while both are normal.
NSString *SGSpeedPitchSummary(void);
// Posted, object nil, whenever the block or the panel shows new values; userInfo's "summary" is
// SGSpeedPitchSummary's text for them, missing while both are normal.
extern NSNotificationName const SGSpeedPitchChangedNotification;
// The speed Spotify's sound plays at, 1 when normal.
double SGPlayerSpeed(void);
// Whether speed can apply: Spotify's output was taken over when it wired it.
BOOL SGPlayerSpeedAllowed(void);
void SGSetPlayerSpeed(double speed);
// Semitones the Pitch slider moves Spotify's output by, 0 when it does not (always while pitch follows speed).
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
extern NSString *const SGSpeedPitchSetElsewhereNotification;

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
// Before a preset is set: one with a pitch of its own turns Pitch follows speed off, which would drop it.
void SGSpeedPitchPrepareFor(SGSpeedPitchPreset *preset);
// Has Siri learn the presets' names again; the list's own changes call it, and the menu once at launch.
void SGSpeedPitchPresetsChanged(void);
// Pitch follows speed, as a record played faster: the pitch slider goes and speed is played by resampling
// (SpeedPitch.x). The switch is on until turned off, and stored, but it only applies where speed does, so
// this is NO while SGPlayerSpeedAllowed() is NO. Turning it on puts the pitch back to normal; while it is
// on, SGSetPlayerPitch does nothing.
#define SGKeyPitchFollowsSpeed @"spotifyglass.speedPitch.follows"
BOOL SGPlayerPitchFollowsSpeed(void);
void SGSetPlayerPitchFollowsSpeed(BOOL follows);

// Current downstream processing delay, in seconds. Atomic unit ownership; safe off-render.
double SGPlayerAudioLatency(void);

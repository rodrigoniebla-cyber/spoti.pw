// The named presets of Speed and pitch, stored in the mod's settings so the menu, Siri and Shortcuts
// read the same list. SpeedPitchIntents.swift reads the stored list directly and hands a preset back
// here by name, through SGSpeedPitchApplyPresetNamed below, looked up with dlsym.
#import "Core/SGCore.h"
#import <objc/message.h>
#import "SpeedPitch.h"

NSString *const SGSpeedPitchChangedNotification = @"SGSpeedPitchChanged";

@implementation SGSpeedPitchPreset
@end

// What a fresh install starts with. The slowed and sped up ones move the pitch with the speed the way
// a record played at another speed does (12 × log2 of the speed, to the semitone); the last two leave
// the speed alone.
static NSArray<NSDictionary *> *starters(void) {
    return @[
        @{@"name": @"Normal", @"speed": @1.0, @"pitch": @0},
        @{@"name": @"Slowed", @"speed": @0.8, @"pitch": @-4},
        @{@"name": @"Slightly slowed", @"speed": @0.9, @"pitch": @-2},
        @{@"name": @"Sped up", @"speed": @1.15, @"pitch": @2},
        @{@"name": @"Nightcore", @"speed": @1.3, @"pitch": @5},
        @{@"name": @"Deep", @"speed": @1.0, @"pitch": @-4},
        @{@"name": @"High", @"speed": @1.0, @"pitch": @5},
    ];
}

static NSArray<NSDictionary *> *stored(void) {
    NSArray *list = [NSUserDefaults.standardUserDefaults arrayForKey:SGKeySpeedPitchPresets];
    if (!list) {
        // Written out, so Siri reads the same list before the menu was ever opened.
        list = starters();
        [NSUserDefaults.standardUserDefaults setObject:list forKey:SGKeySpeedPitchPresets];
    }
    return list;
}

static void store(NSArray<NSDictionary *> *list) {
    [NSUserDefaults.standardUserDefaults setObject:list forKey:SGKeySpeedPitchPresets];
}

NSArray<SGSpeedPitchPreset *> *SGSpeedPitchPresets(void) {
    NSMutableArray<SGSpeedPitchPreset *> *presets = [NSMutableArray array];
    for (NSDictionary *entry in stored()) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *name = entry[@"name"];
        if (![name isKindOfClass:NSString.class] || !name.length) continue;
        SGSpeedPitchPreset *preset = [SGSpeedPitchPreset new];
        preset.name = name;
        preset.speed = [entry[@"speed"] respondsToSelector:@selector(floatValue)] ? [entry[@"speed"] floatValue] : 1;
        preset.pitch = [entry[@"pitch"] respondsToSelector:@selector(floatValue)] ? [entry[@"pitch"] floatValue] : 0;
        [presets addObject:preset];
    }
    return presets;
}

SGSpeedPitchPreset *SGSpeedPitchPresetAt(float speed, float pitch) {
    for (SGSpeedPitchPreset *preset in SGSpeedPitchPresets()) {
        if (fabsf(preset.speed - speed) < 0.001f && fabsf(preset.pitch - pitch) < 0.001f) return preset;
    }
    return nil;
}

static NSUInteger indexNamed(NSArray<NSDictionary *> *list, NSString *name) {
    return [list indexOfObjectPassingTest:^BOOL(NSDictionary *entry, NSUInteger i, BOOL *stop) {
        return [entry isKindOfClass:NSDictionary.class] && [entry[@"name"] isKindOfClass:NSString.class] &&
               [entry[@"name"] caseInsensitiveCompare:name] == NSOrderedSame;
    }];
}

void SGSpeedPitchSavePreset(NSString *name, float speed, float pitch) {
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length) return;
    NSMutableArray<NSDictionary *> *list = [stored() mutableCopy];
    NSDictionary *entry = @{@"name": name, @"speed": @(roundf(speed * 100) / 100), @"pitch": @(roundf(pitch))};
    NSUInteger index = indexNamed(list, name);
    if (index == NSNotFound) [list addObject:entry];
    else list[index] = entry;
    store(list);
    SGSpeedPitchPresetsChanged();
    SGLog(@"speed and pitch: preset %@ saved, %.2f× %+.0f st", name, speed, pitch);
}

void SGSpeedPitchDeletePreset(NSString *name) {
    NSMutableArray<NSDictionary *> *list = [stored() mutableCopy];
    NSUInteger index = indexNamed(list, name);
    if (index == NSNotFound) return;
    [list removeObjectAtIndex:index];
    store(list);
    SGSpeedPitchPresetsChanged();
    SGLog(@"speed and pitch: preset %@ deleted", name);
}

BOOL SGSpeedPitchApplyPreset(NSString *name) {
    SGSpeedPitchPreset *found = nil;
    for (SGSpeedPitchPreset *preset in SGSpeedPitchPresets()) {
        if ([preset.name caseInsensitiveCompare:name] == NSOrderedSame) {
            found = preset;
            break;
        }
    }
    if (!found) return NO;
    BOOL speed = SGPlayerSpeedAllowed(), pitch = SGPlayerPitchAvailable();
    if (speed) SGSetPlayerSpeed(found.speed);
    if (pitch) SGSetPlayerPitch(found.pitch);
    SGLog(@"speed and pitch: preset %@ set from outside the menu (speed %@, pitch %@)", found.name,
          speed ? @"set" : @"unavailable", pitch ? @"set" : @"unavailable");
    [NSNotificationCenter.defaultCenter postNotificationName:SGSpeedPitchChangedNotification object:nil];
    return speed || pitch;
}

// For SpeedPitchIntents.swift, which finds it with dlsym: the Swift side is compiled on its own for the
// App Intents metadata and cannot see this file's declarations. Called on the main thread.
__attribute__((visibility("default"))) BOOL SGSpeedPitchApplyPresetNamed(const char *name);
BOOL SGSpeedPitchApplyPresetNamed(const char *name) {
    if (!name) return NO;
    return SGSpeedPitchApplyPreset([NSString stringWithUTF8String:name]);
}

__attribute__((visibility("default"))) BOOL SGSpeedPitchResetFromIntent(void);
BOOL SGSpeedPitchResetFromIntent(void) {
    BOOL speed = SGPlayerSpeedAllowed(), pitch = SGPlayerPitchAvailable();
    if (speed) SGSetPlayerSpeed(1);
    if (pitch) SGSetPlayerPitch(0);
    SGLog(@"speed and pitch: reset from outside the menu");
    [NSNotificationCenter.defaultCenter postNotificationName:SGSpeedPitchChangedNotification object:nil];
    return speed || pitch;
}

// Siri learns the presets' names again (SpeedPitchIntents.swift), from iOS 17, where the phrases are.
void SGSpeedPitchPresetsChanged(void) {
    Class bridge = NSClassFromString(@"SGSpeedPitchShortcutsBridge");
    SEL changed = NSSelectorFromString(@"presetsChanged");
    if (![bridge respondsToSelector:changed]) return;
    ((void (*)(Class, SEL))objc_msgSend)(bridge, changed);
}

// What the hook, the harness and the settings share: the order of the sources, which key this iOS
// takes a clip under, and putting one there.
#import <MediaPlayer/MediaPlayer.h>
#import "LockScreenArtwork.h"

NSString *const SGArtworkSourceSpotify = @"spotify";
NSString *const SGArtworkSourceApple = @"applemusic";
NSString *const SGArtworkSourceVisualizer = @"visualizer";

// Set once the visualiser has been added to an order stored before it existed, so taking it out holds.
static NSString *const kVisualizerOffered = @"spotifyglass.lockscreen.visualizerOffered";

NSArray<NSString *> *SGArtworkOrder(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id stored = [defaults arrayForKey:SGKeyLockScreenArtworkSources];
    NSArray *keys = [stored isKindOfClass:NSArray.class] ? stored : @[SGArtworkSourceSpotify, SGArtworkSourceApple, SGArtworkSourceVisualizer];
    if ([stored isKindOfClass:NSArray.class] && ![stored containsObject:SGArtworkSourceVisualizer] && ![defaults boolForKey:kVisualizerOffered]) {
        keys = [stored arrayByAddingObject:SGArtworkSourceVisualizer];
        [defaults setObject:keys forKey:SGKeyLockScreenArtworkSources];
    }
    if (![defaults boolForKey:kVisualizerOffered]) [defaults setBool:YES forKey:kVisualizerOffered];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (id key in keys) {
        BOOL known = [key isEqual:SGArtworkSourceSpotify] || [key isEqual:SGArtworkSourceApple] || [key isEqual:SGArtworkSourceVisualizer];
        if (known && ![order containsObject:key]) [order addObject:key];
    }
    return order;
}

void SGArtworkSetOrder(NSArray<NSString *> *order) {
    [NSUserDefaults.standardUserDefaults setObject:order ?: @[] forKey:SGKeyLockScreenArtworkSources];
}

BOOL SGAnimatedArtworkAvailable(void) {
    if (@available(iOS 26.0, *)) return MPMediaItemAnimatedArtwork.class != nil;
    return NO;
}

NSArray<NSString *> *SGAnimatedArtworkKeys(void) {
    if (@available(iOS 26.0, *)) return MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys;
    return nil;
}

NSString *SGAnimatedArtworkKey(CGFloat *aspect) {
    if (@available(iOS 26.0, *)) {
        NSArray<NSString *> *supported = SGAnimatedArtworkKeys();
        // A Canvas is taller than either shape, so the tall key loses the least of it.
        if ([supported containsObject:MPNowPlayingInfoProperty3x4AnimatedArtwork]) {
            if (aspect) *aspect = 3.0 / 4.0;
            return MPNowPlayingInfoProperty3x4AnimatedArtwork;
        }
        if ([supported containsObject:MPNowPlayingInfoProperty1x1AnimatedArtwork]) {
            if (aspect) *aspect = 1;
            return MPNowPlayingInfoProperty1x1AnimatedArtwork;
        }
    }
    return nil;
}

NSDictionary *SGArtworkInInfo(NSDictionary *info, id artwork, NSString *key) {
    if (!info.count || !artwork || !key.length) return info;
    if (info[key] == artwork) return info;
    NSMutableDictionary *shown = [info mutableCopy];
    shown[key] = artwork;
    return shown;
}

// What SiriIntents.swift's actions do inside Spotify: play the DJ, like or unlike the song playing,
// download the playlist or album playing or remove its download. Swift reaches SGSiriRun by dlsym.
//
// Spotify's own services do the work, found by the selectors its binary names (scripts/inspect-
// extensions.sh with a pattern, 9.1.86):
//
//     like, unlike   -addURL:showUIConfirmation:completion: / -removeURL:showUIConfirmation:completion:,
//                    the collection platform's; else the CarPlay side's
//                    -addContentToCollectionWithURI:fromContext:completionHandler: /
//                    -removeContentFromCollectionWithURI:completionHandler:
//     download       -makeEntityAvailableOfflineWithURL:, the offline manager's
//     undownload     -removeOfflineURL:completion:, else -removeOfflinePlaylistURL:completion:
//     DJ             +[SPTPlayerContext contextForURI:] played with the player's -playContext:options:
//
// None of these objects is ever handed to the mod, so each is found the first time it is needed: the
// class among Spotify's that implements the selector, then a live instance of it on the heap (SGHeap.h).
// Every call is checked against the method's type encoding first, so a Spotify that changed a
// signature gets "couldn't" from Siri rather than a crash.
//
// Threading: main thread.
#import <objc/message.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Lyrics/Lyrics.h"
#import "SGHeap.h"

// SiriIntents.swift's SGSiriOutcome.
typedef NS_ENUM(int32_t, SGSiriOutcome) {
    SGSiriDone = 0,
    SGSiriNothingPlaying = 1,
    SGSiriNotACollection = 2,
    SGSiriUnavailable = 3,
    SGSiriAlready = 4,
    SGSiriNotLoaded = 5,
};

// The DJ's playlist, the same for everyone (a string in the binary, next to defaultDJPlaylistURI).
static NSString *const kDJURI = @"spotify:playlist:37i9dQZF1EYkqdzj48dyYq";

#pragma mark - finding Spotify's objects

// The argument types of `sel` on `target`, after self and _cmd, as their first type character each
// (@ object, B bool, c char, q long long); nil when the target does not implement it.
static NSString *argumentTypes(id target, SEL sel) {
    Method method = object_isClass(target) ? class_getClassMethod(target, sel) : class_getInstanceMethod(object_getClass(target), sel);
    if (!method) return nil;
    NSMutableString *types = [NSMutableString string];
    unsigned count = method_getNumberOfArguments(method);
    for (unsigned i = 2; i < count; i++) {
        char *type = method_copyArgumentType(method, i);
        // A block reads @?, an object @: both are objects to the call.
        [types appendFormat:@"%c", type ? type[0] : '?'];
        free(type);
    }
    return types;
}

static BOOL takes(id target, SEL sel, NSString *types) {
    NSString *actual = argumentTypes(target, sel);
    // BOOL is B on arm64; c where a header typed it as char.
    NSString *loose = [actual stringByReplacingOccurrencesOfString:@"c" withString:@"B"];
    BOOL ok = [loose isEqualToString:types];
    if (!ok) SGLog(@"siri: %@ on %@ takes %@, not %@", NSStringFromSelector(sel), NSStringFromClass(object_getClass(target)), actual ?: @"nothing", types);
    return ok;
}

// The live object implementing every selector in `selectors`, found once and kept (weakly, so a
// logout's new services are found again).
static id serviceFor(NSArray<NSString *> *selectors, NSMapTable<NSString *, id> *cache) {
    NSString *key = [selectors componentsJoinedByString:@","];
    id kept = [cache objectForKey:key];
    if (kept) return kept;
    CFTimeInterval started = CACurrentMediaTime();
    NSArray<Class> *classes = SGSpotifyClassesResponding(selectors);
    id found = classes.count ? SGHeapFindInstance(classes) : nil;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (Class cls in classes) {
        if (names.count == 6) break;
        [names addObject:NSStringFromClass(cls)];
    }
    SGLog(@"siri: %@ -> classes %@, instance %@ (%.0f ms)", key, [names componentsJoinedByString:@", "],
          found ? NSStringFromClass(object_getClass(found)) : @"none", (CACurrentMediaTime() - started) * 1000);
    if (found) [cache setObject:found forKey:key];
    return found;
}

static NSMapTable<NSString *, id> *services(void) {
    static NSMapTable *table;
    if (!table) table = [NSMapTable strongToWeakObjectsMapTable];
    return table;
}

#pragma mark - what is playing

static id<SPTPlayer> player(void) {
    id caught = SGKaraokePlayer();
    if (caught) return caught;
    // The lyrics engine only catches the player when something of its own is on; otherwise it is found.
    static __weak id found;
    id kept = found;
    if (kept) return kept;
    Class esperanto = objc_getClass("SPTEsperantoPlayer");
    kept = esperanto ? SGHeapFindInstance(@[esperanto]) : nil;
    found = kept;
    SGLog(@"siri: the player %@", kept ? @"found on the heap" : @"not found");
    return kept;
}

static NSURL *asURL(id uri) {
    if ([uri isKindOfClass:NSURL.class]) return uri;
    if ([uri isKindOfClass:NSString.class] && [uri length]) return [NSURL URLWithString:uri];
    return nil;
}

static NSURL *playingTrack(void) {
    NSURL *uri = asURL(player().state.track.URI);
    return [uri.absoluteString hasPrefix:@"spotify:track:"] ? uri : nil;
}

// The playlist or album the song plays from; Liked Songs (spotify:user:…:collection) downloads too.
static NSURL *playingCollection(BOOL *somethingPlays) {
    SPTPlayerState *state = player().state;
    if (somethingPlays) *somethingPlays = state.track != nil;
    NSURL *uri = asURL(state.contextURI);
    NSString *text = uri.absoluteString;
    BOOL collection = [text hasPrefix:@"spotify:playlist:"] || [text hasPrefix:@"spotify:album:"] ||
                      [text hasSuffix:@":collection"] || [text hasPrefix:@"spotify:show:"] ||
                      ([text hasPrefix:@"spotify:user:"] && [text containsString:@":playlist:"]);
    return collection ? uri : nil;
}

#pragma mark - the actions

static void (^const ignoreTwo)(id, id) = ^(id a, id b) {};

static SGSiriOutcome setLiked(BOOL liked) {
    NSURL *track = playingTrack();
    if (!track) return SGSiriNothingPlaying;
    NSString *primary = liked ? @"addURL:showUIConfirmation:completion:" : @"removeURL:showUIConfirmation:completion:";
    SEL sel = NSSelectorFromString(primary);
    id collection = serviceFor(@[@"addURL:showUIConfirmation:completion:", @"removeURL:showUIConfirmation:completion:"], services());
    if (collection && takes(collection, sel, @"@B@")) {
        ((void (*)(id, SEL, NSURL *, BOOL, id))objc_msgSend)(collection, sel, track, YES, ignoreTwo);
        SGLog(@"siri: %@ %@ through %@", liked ? @"liked" : @"unliked", track, NSStringFromClass(object_getClass(collection)));
        return SGSiriDone;
    }
    // CarPlay's route to the same collection.
    id external = serviceFor(@[@"addContentToCollectionWithURI:fromContext:completionHandler:",
                               @"removeContentFromCollectionWithURI:completionHandler:"], services());
    if (liked) {
        SEL add = NSSelectorFromString(@"addContentToCollectionWithURI:fromContext:completionHandler:");
        if (external && takes(external, add, @"@@@")) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(external, add, track.absoluteString, nil, ignoreTwo);
            SGLog(@"siri: liked %@ through %@", track, NSStringFromClass(object_getClass(external)));
            return SGSiriDone;
        }
    } else {
        SEL remove = NSSelectorFromString(@"removeContentFromCollectionWithURI:completionHandler:");
        if (external && takes(external, remove, @"@@")) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(external, remove, track.absoluteString, ignoreTwo);
            SGLog(@"siri: unliked %@ through %@", track, NSStringFromClass(object_getClass(external)));
            return SGSiriDone;
        }
    }
    return SGSiriUnavailable;
}

static SGSiriOutcome setDownloaded(BOOL downloaded) {
    BOOL plays = NO;
    NSURL *uri = playingCollection(&plays);
    if (!uri) return plays ? SGSiriNotACollection : SGSiriNothingPlaying;
    if (downloaded) {
        SEL make = NSSelectorFromString(@"makeEntityAvailableOfflineWithURL:");
        id offline = serviceFor(@[@"makeEntityAvailableOfflineWithURL:"], services());
        if (!offline || !takes(offline, make, @"@")) return SGSiriUnavailable;
        ((void (*)(id, SEL, NSURL *))objc_msgSend)(offline, make, uri);
        SGLog(@"siri: downloading %@ through %@", uri, NSStringFromClass(object_getClass(offline)));
        return SGSiriDone;
    }
    for (NSString *name in @[@"removeOfflineURL:completion:", @"removeOfflinePlaylistURL:completion:"]) {
        SEL remove = NSSelectorFromString(name);
        id offline = serviceFor(@[name], services());
        if (!offline || !takes(offline, remove, @"@@")) continue;
        ((void (*)(id, SEL, NSURL *, id))objc_msgSend)(offline, remove, uri, ignoreTwo);
        SGLog(@"siri: removed the download of %@ through %@ %@", uri, NSStringFromClass(object_getClass(offline)), name);
        return SGSiriDone;
    }
    return SGSiriUnavailable;
}

static SGSiriOutcome playDJ(void) {
    id<SPTPlayer> target = player();
    Class contextClass = objc_getClass("SPTPlayerContext");
    SEL contextFor = NSSelectorFromString(@"contextForURI:");
    SEL play = NSSelectorFromString(@"playContext:options:");
    if (!target) return SGSiriNotLoaded;
    if (!contextClass || ![contextClass respondsToSelector:contextFor] || ![target respondsToSelector:play]) {
        SGLog(@"siri: cannot play the DJ (context class %@, player %@)", contextClass, NSStringFromClass(object_getClass(target)));
        return SGSiriUnavailable;
    }
    id context = ((id (*)(id, SEL, NSURL *))objc_msgSend)(contextClass, contextFor, [NSURL URLWithString:kDJURI]);
    if (!context || !takes(target, play, @"@@")) return SGSiriUnavailable;
    id task = ((id (*)(id, SEL, id, id))objc_msgSend)(target, play, context, nil);
    SGLog(@"siri: DJ -> %@", task);
    return SGSiriDone;
}

// For SiriIntents.swift, which finds it with dlsym. Main thread.
__attribute__((visibility("default"))) int32_t SGSiriRun(const char *action);
int32_t SGSiriRun(const char *action) {
    NSString *name = action ? @(action) : @"";
    SGSiriOutcome outcome = SGSiriUnavailable;
    @try {
        if ([name isEqualToString:@"dj"]) outcome = playDJ();
        else if ([name isEqualToString:@"like"]) outcome = setLiked(YES);
        else if ([name isEqualToString:@"unlike"]) outcome = setLiked(NO);
        else if ([name isEqualToString:@"download"]) outcome = setDownloaded(YES);
        else if ([name isEqualToString:@"undownload"]) outcome = setDownloaded(NO);
    } @catch (NSException *e) {
        SGLog(@"siri: %@ threw %@", name, e.reason);
        outcome = SGSiriUnavailable;
    }
    SGLog(@"siri: %@ -> %d", name, (int)outcome);
    return outcome;
}

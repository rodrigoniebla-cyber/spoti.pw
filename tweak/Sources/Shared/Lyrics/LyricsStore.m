// Lyrics kept on the phone, so a song plays with its lyrics without a connection, as Spotify's own do for
// the songs it has downloaded. Every track's lines, once they came (from Spotify or a source of the
// mod's), are written to a file of their own and read back when the lyrics view, the lock screen or the
// Live Activity asks for a track whose lines are not in memory: after a restart, offline, or long after.
// Newer lines for the track replace the file.
//
// The files are property lists of the lines as KaraokeSource.x holds them, under Application Support
// (which iOS does not purge, unlike Caches) and out of the backup; the oldest go past kMostTracks. Which
// tracks are kept is read from the folder once, in the background, so asking about a track costs a set
// lookup and no disk read.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"

static const NSUInteger kMostTracks = 5000;
static const NSTimeInterval kWriteDelay = 1;   // for the source's name, which is noted just after the lines

static dispatch_queue_t sg_queue;
static NSMutableSet<NSString *> *sg_index;   // under @synchronized (sg_index)
static NSURL *sg_folder;

#pragma mark - lines as property lists

static NSDictionary *plistOfLine(SGKaraokeLine *line) {
    if (!line) return nil;
    NSMutableArray *words = [NSMutableArray arrayWithCapacity:line.words.count];
    for (SGKaraokeWord *word in line.words) {
        [words addObject:@[word.text ?: @"", @(word.start), @(word.end), @(word.joined)]];
    }
    NSMutableDictionary *out = [@{@"w": words, @"s": @(line.start), @"e": @(line.end), @"a": @(line.align), @"t": @(line.timing)} mutableCopy];
    if (line.voice) out[@"v"] = line.voice;
    if (line.translation) out[@"tr"] = line.translation;
    NSDictionary *backing = plistOfLine(line.backing), *pronunciation = plistOfLine(line.pronunciation);
    if (backing) out[@"b"] = backing;
    if (pronunciation) out[@"p"] = pronunciation;
    return out;
}

static NSInteger integer(id value) {
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
}

static SGKaraokeLine *lineOfPlist(NSDictionary *plist) {
    if (![plist isKindOfClass:NSDictionary.class]) return nil;
    SGKaraokeLine *line = [SGKaraokeLine new];
    NSMutableArray<SGKaraokeWord *> *words = [NSMutableArray array];
    for (NSArray *entry in plist[@"w"]) {
        if (![entry isKindOfClass:NSArray.class] || entry.count < 4 || ![entry[0] isKindOfClass:NSString.class]) continue;
        SGKaraokeWord *word = [SGKaraokeWord new];
        word.text = entry[0];
        word.start = integer(entry[1]);
        word.end = integer(entry[2]);
        word.joined = [entry[3] respondsToSelector:@selector(boolValue)] && [entry[3] boolValue];
        [words addObject:word];
    }
    line.words = words;
    line.start = integer(plist[@"s"]);
    line.end = integer(plist[@"e"]);
    line.align = (SGKaraokeAlign)integer(plist[@"a"]);
    line.timing = (SGKaraokeTiming)MIN(integer(plist[@"t"]), (NSInteger)SGKaraokeTimingNone);
    if ([plist[@"v"] isKindOfClass:NSString.class]) line.voice = plist[@"v"];
    if ([plist[@"tr"] isKindOfClass:NSString.class]) line.translation = plist[@"tr"];
    line.backing = lineOfPlist(plist[@"b"]);
    line.pronunciation = lineOfPlist(plist[@"p"]);
    return line;
}

#pragma mark - the folder

// A track id is base62, but nothing that reaches a file name is taken on trust.
static NSURL *fileFor(NSString *trackID) {
    NSCharacterSet *allowed = NSCharacterSet.alphanumericCharacterSet;
    if (!trackID.length || trackID.length > 64 || [trackID rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    return [sg_folder URLByAppendingPathComponent:[trackID stringByAppendingPathExtension:@"plist"]];
}

// Past the most, the tracks written longest ago go.
static void prune(NSMutableArray<NSURL *> *files) {
    if (files.count <= kMostTracks) return;
    [files sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *first = nil, *second = nil;
        [a getResourceValue:&first forKey:NSURLContentModificationDateKey error:NULL];
        [b getResourceValue:&second forKey:NSURLContentModificationDateKey error:NULL];
        return [first ?: NSDate.distantPast compare:second ?: NSDate.distantPast];
    }];
    NSUInteger over = files.count - kMostTracks;
    for (NSUInteger i = 0; i < over; i++) {
        [NSFileManager.defaultManager removeItemAtURL:files[i] error:NULL];
        @synchronized (sg_index) { [sg_index removeObject:files[i].URLByDeletingPathExtension.lastPathComponent]; }
    }
    SGLog(@"lyrics store: %lu oldest tracks let go", (unsigned long)over);
}

void SGLyricsStoreStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_queue = dispatch_queue_create("spotifyglass.lyricsstore", DISPATCH_QUEUE_SERIAL);
        sg_index = [NSMutableSet set];
        NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        sg_folder = [support URLByAppendingPathComponent:@"spotifyglass/lyrics" isDirectory:YES];
        dispatch_async(sg_queue, ^{
            NSFileManager *fm = NSFileManager.defaultManager;
            [fm createDirectoryAtURL:sg_folder withIntermediateDirectories:YES attributes:nil error:NULL];
            NSURL *parent = sg_folder.URLByDeletingLastPathComponent;
            [parent setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:NULL];
            NSMutableArray<NSURL *> *files = [[fm contentsOfDirectoryAtURL:sg_folder includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                                     options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL] mutableCopy] ?: [NSMutableArray array];
            @synchronized (sg_index) {
                for (NSURL *file in files) [sg_index addObject:file.URLByDeletingPathExtension.lastPathComponent];
            }
            SGLog(@"lyrics store: %lu tracks kept offline", (unsigned long)files.count);
            prune(files);
        });
    });
}

BOOL SGLyricsStoreHas(NSString *trackID) {
    if (!sg_index || !trackID) return NO;
    @synchronized (sg_index) { return [sg_index containsObject:trackID]; }
}

NSArray<SGKaraokeLine *> *SGLyricsStoreRead(NSString *trackID, NSString **credit) {
    if (!SGLyricsStoreHas(trackID)) return nil;
    NSURL *file = fileFor(trackID);
    NSData *data = file ? [NSData dataWithContentsOfURL:file] : nil;
    NSDictionary *root = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
    if (![root isKindOfClass:NSDictionary.class] || ![root[@"lines"] isKindOfClass:NSArray.class]) {
        @synchronized (sg_index) { [sg_index removeObject:trackID]; }
        return nil;
    }
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    for (NSDictionary *plist in root[@"lines"]) {
        SGKaraokeLine *line = lineOfPlist(plist);
        if (line) [lines addObject:line];
    }
    if (credit) *credit = [root[@"credit"] isKindOfClass:NSString.class] ? root[@"credit"] : nil;
    return lines.count ? lines : nil;
}

void SGLyricsStoreWrite(NSString *trackID, NSArray<SGKaraokeLine *> *lines) {
    if (!sg_queue || !lines.count || !fileFor(trackID)) return;
    NSArray<SGKaraokeLine *> *kept = [lines copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWriteDelay * NSEC_PER_SEC)), sg_queue, ^{
        NSMutableArray *plists = [NSMutableArray arrayWithCapacity:kept.count];
        for (SGKaraokeLine *line in kept) [plists addObject:plistOfLine(line)];
        NSMutableDictionary *root = [@{@"lines": plists, @"saved": [NSDate date]} mutableCopy];
        NSString *credit = SGLyricsCreditFor(trackID);
        if (credit) root[@"credit"] = credit;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:root format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        if (![data writeToURL:fileFor(trackID) options:NSDataWritingAtomic error:NULL]) return;
        BOOL added;
        NSUInteger count;
        @synchronized (sg_index) {
            added = ![sg_index containsObject:trackID];
            [sg_index addObject:trackID];
            count = sg_index.count;
        }
        if (added && count > kMostTracks + 100) {
            NSMutableArray<NSURL *> *files = [[NSFileManager.defaultManager contentsOfDirectoryAtURL:sg_folder
                includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL] mutableCopy];
            if (files) prune(files);
        }
    });
}

NSUInteger SGLyricsStoreCount(void) {
    if (!sg_index) return 0;
    @synchronized (sg_index) { return sg_index.count; }
}

void SGLyricsStoreClear(void) {
    if (!sg_queue) return;
    @synchronized (sg_index) { [sg_index removeAllObjects]; }
    dispatch_async(sg_queue, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSURL *file in [fm contentsOfDirectoryAtURL:sg_folder includingPropertiesForKeys:nil options:0 error:NULL]) {
            [fm removeItemAtURL:file error:NULL];
        }
        SGLog(@"lyrics store: cleared");
    });
}

#pragma mark - the Lyrics page's rows

SGModSection *SGLyricsOfflineSection(void) {
    SGModRow *clear = SGStatActionRow(@"Delete saved lyrics", nil, ^NSString *{
        NSUInteger count = SGLyricsStoreCount();
        return count == 1 ? @"1 song" : [NSString stringWithFormat:@"%lu songs", (unsigned long)count];
    }, ^{
        SGLyricsStoreClear();
    });
    return SGNotedSection(@"Offline", @[SGSwitchRow(@"Save lyrics offline", nil, SGKeyLyricsOffline), clear],
                          @"Keeps the lyrics of every song they load for, so downloaded songs show them without a connection.");
}

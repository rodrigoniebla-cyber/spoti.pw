// SGCoverPalette.h says what this does. The vote is SGPalette.m's; this reads the picture into pixels for it.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "Shared/Lyrics/Lyrics.h"
#import "SGPalette.h"
#import "SGCoverPalette.h"
#import "Visualizer.h"

const NSInteger SGCoverPaletteColors = 4;
NSNotificationName const SGCoverPaletteDidChangeNotification = @"spotifyglass.coverPaletteChanged";

// Enough pixels for a cover's colours; more would only cost.
enum { kSide = 32 };

NSArray<UIColor *> *SGCoverPaletteOfImage(UIImage *image) {
    if (!image.CGImage) return nil;
    uint8_t pixels[kSide * kSide * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, kSide, kSide, 8, kSide * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, kSide, kSide), image.CGImage);
    CGContextRelease(context);
    float rgb[SGPaletteMaxColors * 3];
    int count = SGPaletteExtract(pixels, kSide, kSide, kSide * 4, (int)SGCoverPaletteColors, rgb);
    if (count < 1) return nil;
    NSMutableArray<UIColor *> *colors = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (int i = 0; i < count; i++) [colors addObject:[UIColor colorWithRed:rgb[i * 3] green:rgb[i * 3 + 1] blue:rgb[i * 3 + 2] alpha:1]];
    return colors;
}

#pragma mark - the playing track's

static NSString *sg_paletteTrack;
// The track the cover on screen was last read for: the now playing artwork's read gives way to it.
static NSString *sg_offeredTrack;
static BOOL sg_reading;
static NSArray<UIColor *> *sg_palette;
static CFTimeInterval sg_retryAt;

NSArray<UIColor *> *SGCoverPaletteForPlayingTrack(void) {
    NSString *track = SGKaraokePlayingTrack();
    if (!track || sg_reading || [track isEqualToString:sg_paletteTrack] || CACurrentMediaTime() < sg_retryAt) return sg_palette;
    id artwork = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[MPMediaItemPropertyArtwork];
    if (![artwork isKindOfClass:MPMediaItemArtwork.class]) return sg_palette;
    sg_reading = YES;
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("spotifyglass.cover-palette", DISPATCH_QUEUE_SERIAL); });
    MPMediaItemArtwork *cover = artwork;
    NSString *wanted = [track copy];
    dispatch_async(queue, ^{
        NSArray<UIColor *> *colors = SGCoverPaletteOfImage([cover imageWithSize:CGSizeMake(64, 64)]);
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_reading = NO;
            if ([wanted isEqualToString:sg_offeredTrack]) {
                sg_paletteTrack = wanted;
                return;
            }
            // An image that could not be read is tried again the next time it is asked for.
            if (!colors) {
                sg_retryAt = CACurrentMediaTime() + 3;
                return;
            }
            sg_paletteTrack = wanted;
            sg_palette = colors;
            [NSNotificationCenter.defaultCenter postNotificationName:SGCoverPaletteDidChangeNotification object:nil];
        });
    });
    return sg_palette;
}

static dispatch_queue_t paletteQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("spotifyglass.cover-palette.shown", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

void SGCoverPaletteOfferImage(UIImage *image) {
    static const void *offered;
    if (!image.CGImage || (__bridge const void *)image == offered) return;
    offered = (__bridge const void *)image;
    NSString *track = SGKaraokePlayingTrack();
    dispatch_async(paletteQueue(), ^{
        NSArray<UIColor *> *colors = SGCoverPaletteOfImage(image);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!colors || offered != (__bridge const void *)image) return;
            sg_offeredTrack = track;
            sg_paletteTrack = track;
            sg_palette = colors;
            [NSNotificationCenter.defaultCenter postNotificationName:SGCoverPaletteDidChangeNotification object:nil];
        });
    });
}

#pragma mark - round the ring

NSArray<UIColor *> *SGCoverGradientStops(NSArray<UIColor *> *palette, BOOL mirror) {
    if (palette.count == 0) return nil;
    NSMutableArray<UIColor *> *stops = [palette mutableCopy];
    if (mirror) {
        for (NSInteger i = (NSInteger)palette.count - 2; i >= 0; i--) [stops addObject:palette[(NSUInteger)i]];
        if (palette.count == 1) [stops addObject:palette[0]];
    } else {
        [stops addObject:palette[0]];
    }
    return stops;
}

UIColor *SGCoverGradientColor(NSArray<UIColor *> *stops, CGFloat t) {
    if (stops.count == 0) return UIColor.whiteColor;
    if (stops.count == 1) return stops[0];
    t = MAX(0, MIN(1, t)) * (CGFloat)(stops.count - 1);
    NSUInteger from = MIN((NSUInteger)floor(t), stops.count - 2);
    CGFloat share = t - (CGFloat)from;
    CGFloat r0, g0, b0, r1, g1, b1;
    [stops[from] getRed:&r0 green:&g0 blue:&b0 alpha:NULL];
    [stops[from + 1] getRed:&r1 green:&g1 blue:&b1 alpha:NULL];
    return [UIColor colorWithRed:r0 + (r1 - r0) * share green:g0 + (g1 - g0) * share blue:b0 + (b1 - b0) * share alpha:1];
}

#pragma mark - the gradient colours

const NSInteger SGVisualizerRepeats = 4;

NSArray<UIColor *> *SGVisualizerSpectrumColours(void) {
    static NSArray<UIColor *> *hues;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *list = [NSMutableArray array];
        for (int i = 0; i < 6; i++) [list addObject:[UIColor colorWithHue:i / 6.0 saturation:0.75 brightness:1 alpha:1]];
        hues = list;
    });
    return hues;
}

NSArray<UIColor *> *SGVisualizerGradientColours(NSInteger colour, UIColor *accent) {
    if (colour == SGVisualizerColorSpectrum) return SGVisualizerSpectrumColours();
    if (colour != SGVisualizerColorCover) return nil;
    return SGCoverPaletteForPlayingTrack() ?: @[accent ?: UIColor.whiteColor];
}

static CGFloat luminance(UIColor *color) {
    CGFloat r = 1, g = 1, b = 1;
    [color getRed:&r green:&g blue:&b alpha:NULL];
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

NSArray<UIColor *> *SGVisualizerGradientStops(NSArray<UIColor *> *colours, NSInteger gradient, BOOL mirror, BOOL spectrum) {
    if (!colours.count) return nil;
    if (colours.count == 1) return @[colours[0], colours[0]];
    switch (gradient) {
        case SGVisualizerGradientAround:
            if (spectrum && !mirror) return [colours arrayByAddingObject:colours[0]];
            return SGCoverGradientStops(colours, mirror);
        case SGVisualizerGradientRepeating: {
            // There and back, SGVisualizerRepeats times, ending where it began.
            NSMutableArray<UIColor *> *stops = [NSMutableArray array];
            for (NSInteger turn = 0; turn < SGVisualizerRepeats; turn++) {
                [stops addObjectsFromArray:colours];
                for (NSInteger i = (NSInteger)colours.count - 2; i >= 1; i--) [stops addObject:colours[(NSUInteger)i]];
            }
            [stops addObject:colours[0]];
            return stops;
        }
        case SGVisualizerGradientAlternating:
            return colours;
        default:
            // Along a bar: darkest inside, lightest at the tip, so every bar glows outward.
            if (spectrum) return colours;
            return [colours sortedArrayUsingComparator:^NSComparisonResult(UIColor *a, UIColor *b) {
                CGFloat x = luminance(a), y = luminance(b);
                return x < y ? NSOrderedAscending : x > y ? NSOrderedDescending : NSOrderedSame;
            }];
    }
}

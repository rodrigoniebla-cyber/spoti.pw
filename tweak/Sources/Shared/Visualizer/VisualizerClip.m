// The lock screen's visualiser. From iOS 26 the lock screen plays a looping clip behind its controls
// (Shared/LockScreenArtwork), and a clip is all it takes: nothing can draw there live. So the clip is
// made from the track itself: once a track is asked for, the sound heard is analysed 30 times a second
// while that track plays (paused stretches left out), and after kSeconds of it the frames are drawn by
// the same renderer as the player's visualiser into an H.264 file at the lock screen's shape.
//
// The file is named by the track, the shape and the settings, and kept in the lock screen's clip cache,
// under its size cap; a track played again with the same settings is ready at once.
//
// Threading: the capture runs on the main queue (the analysis of a window is a fraction of a
// millisecond); the drawing and the encoding on a queue of their own.
#import <AVFoundation/AVFoundation.h>
#import <mach/mach_time.h>
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import "Visualizer.h"

static const double kSeconds = 10, kFramesPerSecond = 30;
static const CGFloat kWidth = 720;

static NSString *sg_uri;
static UIImage *sg_artwork;
static CGFloat sg_aspect;
static void (^sg_done)(NSURL *, NSString *);
static dispatch_source_t sg_timer;
static SGVizAnalyzer *sg_analyzer;
static NSMutableData *sg_frames;       // SGVizFrame after SGVizFrame
static SGVizSettings sg_settings;
static BOOL sg_listening;

static NSURL *clipFile(NSString *uri, CGFloat aspect, const SGVizSettings *settings) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *folder = [caches stringByAppendingPathComponent:@"spoti.pw/LockArtwork"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *bytes = [NSData dataWithBytes:settings length:sizeof *settings];
    NSUInteger settingsHash = bytes.hash ^ (NSUInteger)(aspect * 1000);
    NSString *track = [[uri componentsSeparatedByString:@":"].lastObject stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:
        [NSString stringWithFormat:@"visualizer-%@-%lx.mp4", track, (unsigned long)settingsHash]]];
}

static void stopCapture(void) {
    if (sg_timer) {
        dispatch_source_cancel(sg_timer);
        sg_timer = nil;
    }
    if (sg_listening) {
        sg_listening = NO;
        SGVisualizerTapRelease();
    }
}

static void finish(NSURL *file, NSString *note) {
    void (^done)(NSURL *, NSString *) = sg_done;
    sg_done = nil;
    if (done) done(file, note);
}

#pragma mark - drawing the clip

static CVPixelBufferRef drawnFrame(CVPixelBufferPoolRef pool, SGVizRenderer *renderer, const SGVizFrame *frame,
                                   const SGVizSettings *settings, CGSize size) {
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &buffer) != kCVReturnSuccess || !buffer) return NULL;
    CVPixelBufferLockBaseAddress(buffer, 0);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), (size_t)size.width, (size_t)size.height, 8,
                                                 CVPixelBufferGetBytesPerRow(buffer), space,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    if (context) {
        // The renderer draws the way UIKit does, from the top.
        CGContextTranslateCTM(context, 0, size.height);
        CGContextScaleCTM(context, 1, -1);
        [renderer drawFrame:frame settings:settings inContext:context size:size dt:1 / kFramesPerSecond];
        CGContextRelease(context);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

static void render(NSString *uri, NSData *frames, SGVizSettings settings, UIImage *artwork, CGFloat aspect, NSURL *file) {
    static dispatch_queue_t queue;
    if (!queue) queue = dispatch_queue_create("spotifyglass.visualizer.clip", DISPATCH_QUEUE_SERIAL);
    dispatch_async(queue, ^{
        CFTimeInterval started = CACurrentMediaTime();
        CGSize size = CGSizeMake(kWidth, round(kWidth / MAX(0.3, aspect) / 2) * 2);
        NSURL *partial = [file URLByAppendingPathExtension:@"part.mp4"];
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        NSError *error = nil;
        AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:&error];
        AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
            AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @(size.width), AVVideoHeightKey: @(size.height),
            AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(3000000), AVVideoMaxKeyFrameIntervalKey: @(30)},
        }];
        input.expectsMediaDataInRealTime = NO;
        AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
            sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                                          (id)kCVPixelBufferWidthKey: @(size.width), (id)kCVPixelBufferHeightKey: @(size.height)}];
        if (!writer || ![writer canAddInput:input]) {
            dispatch_async(dispatch_get_main_queue(), ^{ if ([sg_uri isEqualToString:uri]) finish(nil, [NSString stringWithFormat:@"no writer: %@", error]); });
            return;
        }
        [writer addInput:input];
        [writer startWriting];
        [writer startSessionAtSourceTime:kCMTimeZero];
        SGVizRenderer *renderer = [SGVizRenderer new];
        renderer.artwork = artwork;
        NSUInteger count = frames.length / sizeof(SGVizFrame);
        const SGVizFrame *all = frames.bytes;
        // Particles take a moment to fill the view: a second is drawn first and thrown away, so the
        // clip starts full, the way it ends.
        NSUInteger warmup = MIN(count, (NSUInteger)kFramesPerSecond);
        for (NSUInteger i = 0; i < warmup; i++) {
            CVPixelBufferRef scratch = drawnFrame(adaptor.pixelBufferPool, renderer, &all[count - warmup + i], &settings, size);
            if (scratch) CVPixelBufferRelease(scratch);
        }
        BOOL failed = NO;
        for (NSUInteger i = 0; i < count && !failed; i++) {
            while (!input.readyForMoreMediaData) [NSThread sleepForTimeInterval:0.005];
            CVPixelBufferRef buffer = drawnFrame(adaptor.pixelBufferPool, renderer, &all[i], &settings, size);
            if (!buffer) { failed = YES; break; }
            failed = ![adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake((int64_t)i, (int32_t)kFramesPerSecond)];
            CVPixelBufferRelease(buffer);
        }
        [input markAsFinished];
        dispatch_semaphore_t written = dispatch_semaphore_create(0);
        [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
        dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
        BOOL ok = !failed && writer.status == AVAssetWriterStatusCompleted;
        if (ok) {
            [NSFileManager.defaultManager removeItemAtURL:file error:nil];
            ok = [NSFileManager.defaultManager moveItemAtURL:partial toURL:file error:nil];
        }
        NSString *note = [NSString stringWithFormat:@"%lu frames at %.0fx%.0f %@ in %.1f s", (unsigned long)count, size.width, size.height,
                          ok ? @"drawn" : [NSString stringWithFormat:@"failed (%@)", writer.error], CACurrentMediaTime() - started];
        dispatch_async(dispatch_get_main_queue(), ^{
            SGLog(@"visualizer: lock screen clip for %@: %@", uri, note);
            if ([sg_uri isEqualToString:uri]) finish(ok ? file : nil, note);
        });
    });
}

#pragma mark - capturing the track

static void capture(void) {
    SPTPlayerState *state = SGPlayerState();
    if (![SGURIString(state.track.URI) isEqualToString:sg_uri]) {
        // The track moved on before enough of it was heard.
        stopCapture();
        finish(nil, @"the track changed before the clip was made");
        return;
    }
    if (state.isPaused) return;
    float samples[SGVizWindow];
    double rate = SGVisualizerTapRead(samples, SGVizWindow, mach_absolute_time());
    if (rate <= 0) return;
    SGVizFrame frame = {0};
    [sg_analyzer analyze:samples count:SGVizWindow rate:rate settings:&sg_settings frame:&frame dt:1 / kFramesPerSecond];
    if (frame.silent) return;
    [sg_frames appendBytes:&frame length:sizeof frame];
    if (sg_frames.length / sizeof(SGVizFrame) < kSeconds * kFramesPerSecond) return;
    stopCapture();
    render(sg_uri, sg_frames, sg_settings, sg_artwork, sg_aspect, clipFile(sg_uri, sg_aspect, &sg_settings));
    sg_frames = nil;
}

void SGVisualizerClipFor(NSString *uri, UIImage *artwork, CGFloat aspect, void (^done)(NSURL *file, NSString *note)) {
    stopCapture();
    finish(nil, @"another track asked for");
    if (!uri.length) {
        if (done) done(nil, @"no track");
        return;
    }
    sg_uri = [uri copy];
    sg_artwork = artwork;
    sg_aspect = aspect > 0 ? aspect : 1;
    sg_done = [done copy];
    sg_settings = SGVisualizerSettings();
    NSURL *file = clipFile(uri, sg_aspect, &sg_settings);
    if ([NSFileManager.defaultManager fileExistsAtPath:file.path]) {
        [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: NSDate.date} ofItemAtPath:file.path error:nil];
        finish(file, @"made before");
        return;
    }
    sg_analyzer = [SGVizAnalyzer new];
    sg_frames = [NSMutableData dataWithCapacity:(NSUInteger)(kSeconds * kFramesPerSecond) * sizeof(SGVizFrame)];
    SGVisualizerTapRetain();
    sg_listening = YES;
    sg_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(sg_timer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(NSEC_PER_SEC / kFramesPerSecond), NSEC_PER_MSEC * 5);
    dispatch_source_set_event_handler(sg_timer, ^{ capture(); });
    dispatch_resume(sg_timer);
    SGLog(@"visualizer: listening to %@ for the lock screen's clip", uri);
}

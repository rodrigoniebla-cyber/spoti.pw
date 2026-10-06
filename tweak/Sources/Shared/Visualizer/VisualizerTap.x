// The visualiser's ear: the last stage of Shared/Audio/SGAudioPipeline's render notify on Spotify's RemoteIO
// unit, after speed and pitch, the effects and Music Haptics, so it hears what the speaker plays (MusicHaptics.x
// has the whole story of the unit and its format). After each render the buffer goes into a ring, mixed to mono, with the host time its last
// sample will be heard: the render's timestamp plus AVAudioSession's output latency, large over
// Bluetooth. A reader asks for the samples heard at a given moment, so what is drawn is what is heard.
//
// Threading: the notify runs on the render thread and touches only atomics and the ring; the ring is read
// from any thread, a torn read costing a sample or two of one frame.
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import "Core/SGCore.h"
#import "Shared/Audio/SGAudioPipeline.h"
#import "Visualizer.h"

enum { kRingSize = 1 << 16, kMonoFrames = 4096 };   // about 1.4 s at 48 kHz

static float sg_ring[kRingSize];
static atomic_uint_fast64_t sg_written;          // samples written, ever
static atomic_uint_fast64_t sg_heardAtBits;      // host time the last written sample is heard, as a double's bits
static atomic_uint_fast64_t sg_rateBits;
static atomic_uint_fast64_t sg_layout;           // flags | channels << 32 | bytes << 48, 0 for a format not read
static atomic_uint_fast64_t sg_latencyBits;      // seconds
static atomic_int sg_readers;
static double sg_secondsPerTick;

static void storeDouble(atomic_uint_fast64_t *slot, double value) {
    uint64_t bits;
    memcpy(&bits, &value, sizeof bits);
    atomic_store_explicit(slot, bits, memory_order_relaxed);
}

static double loadDouble(atomic_uint_fast64_t *slot) {
    uint64_t bits = atomic_load_explicit(slot, memory_order_relaxed);
    double value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

#pragma mark - the render thread

static inline float sampleAt(const void *data, UInt32 index, UInt32 bytes, BOOL isFloat) {
    if (bytes == 4) return isFloat ? ((const float *)data)[index] : ((const int32_t *)data)[index] / 2147483648.0f;
    return ((const int16_t *)data)[index] / 32768.0f;
}

static OSStatus rendered(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus,
                         UInt32 frames, AudioBufferList *data) {
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || !data || !data->mNumberBuffers || !frames) return noErr;
    if (atomic_load_explicit(&sg_readers, memory_order_relaxed) <= 0) return noErr;
    uint64_t layout = atomic_load_explicit(&sg_layout, memory_order_relaxed);
    UInt32 formatFlags = (UInt32)layout, channels = (UInt32)(layout >> 32) & 0xffff, bytes = (UInt32)(layout >> 48);
    if ((bytes != 2 && bytes != 4) || channels < 1) return noErr;
    BOOL isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL split = (formatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    BOOL fits = split ? data->mNumberBuffers == channels : data->mNumberBuffers == 1 && data->mBuffers[0].mNumberChannels == channels;
    for (UInt32 b = 0; fits && b < data->mNumberBuffers; b++) {
        fits = data->mBuffers[b].mData && data->mBuffers[b].mDataByteSize >= frames * bytes * (split ? 1 : channels);
    }
    if (!fits) return noErr;
    double rate = loadDouble(&sg_rateBits);
    if (rate <= 0) return noErr;

    BOOL silence = (*flags & kAudioUnitRenderAction_OutputIsSilence) != 0;
    const void *left = data->mBuffers[0].mData, *right = split && channels > 1 ? data->mBuffers[1].mData : left;
    UInt32 stride = split ? 1 : channels, rightOffset = !split && channels > 1 ? 1 : 0;
    uint64_t written = atomic_load_explicit(&sg_written, memory_order_relaxed);
    for (UInt32 i = 0; i < frames; i++) {
        UInt32 at = i * stride;
        float value = silence ? 0 : 0.5f * (sampleAt(left, at, bytes, isFloat) + sampleAt(right, at + rightOffset, bytes, isFloat));
        sg_ring[(written + i) & (kRingSize - 1)] = value;
    }
    uint64_t hostTime = (timestamp->mFlags & kAudioTimeStampHostTimeValid) ? timestamp->mHostTime : mach_absolute_time();
    double heardAt = hostTime + (frames / rate + loadDouble(&sg_latencyBits)) / sg_secondsPerTick;
    storeDouble(&sg_heardAtBits, heardAt);
    atomic_store_explicit(&sg_written, written + frames, memory_order_release);
    return noErr;
}

#pragma mark - reading

double SGVisualizerTapRead(float *samples, NSInteger count, uint64_t atHostTime) {
    if (count <= 0 || count > kRingSize / 2) return 0;
    uint64_t written = atomic_load_explicit(&sg_written, memory_order_acquire);
    double rate = loadDouble(&sg_rateBits), heardAt = loadDouble(&sg_heardAtBits);
    if (rate <= 0 || written < (uint64_t)count) return 0;
    // How far behind the last written sample the moment asked for is; a stream that stopped a while ago
    // is silence.
    double behind = (heardAt - (double)atHostTime) * sg_secondsPerTick;
    if (behind < -0.25) return 0;
    uint64_t lag = behind > 0 ? (uint64_t)(behind * rate) : 0;
    if (lag + count > kRingSize - 8192) lag = kRingSize - 8192 - count;
    uint64_t end = written - lag;
    for (NSInteger i = 0; i < count; i++) samples[i] = sg_ring[(end - count + i) & (kRingSize - 1)];
    return rate;
}

void SGVisualizerTapRetain(void) {
    atomic_fetch_add(&sg_readers, 1);
}

void SGVisualizerTapRelease(void) {
    atomic_fetch_sub(&sg_readers, 1);
}

#pragma mark - the output unit

static void readFormat(AudioUnit unit) {
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof format;
    OSStatus status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size);
    UInt32 bytes = format.mBitsPerChannel / 8;
    BOOL takes = status == noErr && format.mFormatID == kAudioFormatLinearPCM && format.mSampleRate > 0 && format.mChannelsPerFrame >= 1
                 && (bytes == 2 || bytes == 4) && ((format.mFormatFlags & kAudioFormatFlagIsFloat) || (format.mFormatFlags & kAudioFormatFlagIsSignedInteger));
    static uint64_t logged;
    uint64_t layout = takes ? (uint64_t)format.mFormatFlags | (uint64_t)(format.mChannelsPerFrame & 0xffff) << 32 | (uint64_t)bytes << 48 : 0;
    if (layout != logged) {
        logged = layout;
        SGLog(@"visualizer: listening at %.0f Hz, %u channels, %u-bit%@", format.mSampleRate, (unsigned)format.mChannelsPerFrame,
              (unsigned)format.mBitsPerChannel, takes ? @"" : @", a format it does not read");
    }
    if (takes) storeDouble(&sg_rateBits, format.mSampleRate);
    atomic_store(&sg_layout, layout);
}

static void readLatency(void) {
    storeDouble(&sg_latencyBits, AVAudioSession.sharedInstance.outputLatency);
}

%ctor {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    sg_secondsPerTick = (double)timebase.numer / timebase.denom / 1e9;
    // readFormat is the pipeline's prepare, called as the output starts and when its format changes.
    static const SGAudioProcessor processor = {readFormat, rendered};
    if (!SGAudioPipelineRegister(SGAudioStageVisualizer, &processor)) {
        SGLog(@"visualizer: the audio pipeline took no stage, the visualiser hears nothing");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ readLatency(); });
    [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) { readLatency(); }];
}

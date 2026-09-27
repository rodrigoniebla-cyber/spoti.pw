// A window of the sound as the renderer wants it: a Hann-windowed 2048-point FFT (vDSP), its bins
// gathered into bands spaced evenly in pitch over whatever part of the spectrum the settings follow,
// scaled by a level that follows the loudest band down slowly (so a quiet song fills the view as a
// loud one does), and smoothed the way a meter falls: at once up, then down at the smoothing's pace.
// Bass, mids and highs are measured over fixed ranges whatever is followed, for the particles and the
// pulses; a beat is the bass jumping well over its recent average, at most one every 180 ms.
#import <Accelerate/Accelerate.h>
#import "Visualizer.h"

static const float kLowest = 30, kHighest = 16000;
static const double kBeatGap = 0.18;

@implementation SGVizAnalyzer {
    FFTSetup _fft;
    float _window[SGVizWindow];
    float _windowed[SGVizWindow];
    float _real[SGVizWindow / 2], _imag[SGVizWindow / 2];
    float _power[SGVizWindow / 2];
    float _smoothed[SGVizMostBands];
    float _peak;                    // the level the bands are scaled against
    float _bass, _mids, _highs, _level;
    float _bassAverage;
    double _sinceBeat;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _fft = vDSP_create_fftsetup(11, kFFTRadix2);   // 2^11 = 2048
    vDSP_hann_window(_window, SGVizWindow, vDSP_HANN_NORM);
    _peak = 1e-4f;
    _sinceBeat = 1;
    return self;
}

- (void)dealloc {
    if (_fft) vDSP_destroy_fftsetup(_fft);
}

// The mean power of the bins between two frequencies.
- (float)powerFrom:(float)low to:(float)high rate:(double)rate {
    float binWidth = rate / SGVizWindow;
    NSInteger first = MAX(1, (NSInteger)floorf(low / binWidth)), last = MIN(SGVizWindow / 2 - 1, (NSInteger)ceilf(high / binWidth));
    if (last < first) last = first;
    float sum = 0;
    for (NSInteger i = first; i <= last; i++) sum += _power[i];
    return sum / (float)(last - first + 1);
}

static float follow(float current, float target, float fall, double dt) {
    if (target >= current) return current + (target - current) * 0.75f;
    // `fall` is the share left after a 60th of a second.
    return target + (current - target) * powf(fall, (float)(dt * 60));
}

- (void)analyze:(const float *)samples count:(NSInteger)count rate:(double)rate settings:(const SGVizSettings *)settings
          frame:(SGVizFrame *)frame dt:(double)dt {
    if (count < SGVizWindow || rate <= 0 || !_fft) {
        [self decay:frame dt:dt];
        return;
    }
    const float *window = samples + (count - SGVizWindow);
    vDSP_vmul(window, 1, _window, 1, _windowed, 1, SGVizWindow);
    DSPSplitComplex split = {_real, _imag};
    vDSP_ctoz((const DSPComplex *)_windowed, 2, &split, 1, SGVizWindow / 2);
    vDSP_fft_zrip(_fft, &split, 1, 11, kFFTDirection_Forward);
    _imag[0] = 0;   // the packed Nyquist bin
    vDSP_zvmags(&split, 1, _power, 1, SGVizWindow / 2);

    // What part of the spectrum the bars spread over.
    float low = kLowest, high = kHighest;
    switch (settings->follows) {
        case SGVizFollowsBass: low = 25; high = 250; break;
        case SGVizFollowsMids: low = 250; high = 4000; break;
        case SGVizFollowsHighs: low = 4000; high = 16000; break;
        case SGVizFollowsVocals: low = 200; high = 3500; break;
        default: break;
    }
    high = MIN(high, (float)rate / 2 - 1);
    NSInteger bands = MAX(4, MIN(SGVizMostBands, settings->bars));
    float fall = 0.55f + 0.42f * settings->smoothing;
    float loudest = 0;
    float raw[SGVizMostBands];
    for (NSInteger b = 0; b < bands; b++) {
        float from = low * powf(high / low, (float)b / bands), to = low * powf(high / low, (float)(b + 1) / bands);
        // Highs carry less energy than bass for the same loudness; a gentle tilt evens the bars out.
        float tilt = 1 + 1.6f * (float)b / bands;
        raw[b] = sqrtf([self powerFrom:from to:to rate:rate]) * tilt;
        loudest = MAX(loudest, raw[b]);
    }
    _peak = MAX(loudest, _peak * powf(0.996f, (float)(dt * 60)));
    _peak = MAX(_peak, 1e-4f);
    for (NSInteger b = 0; b < bands; b++) {
        float value = powf(raw[b] / _peak, 0.8f) * settings->sensitivity;
        _smoothed[b] = follow(_smoothed[b], MIN(value, 1.3f), fall, dt);
        frame->bands[b] = _smoothed[b];
    }
    frame->bandCount = bands;

    float bass = sqrtf([self powerFrom:30 to:150 rate:rate]), mids = sqrtf([self powerFrom:400 to:2500 rate:rate]);
    float highs = sqrtf([self powerFrom:5000 to:MIN(14000, (float)rate / 2 - 1) rate:rate]) * 2.5f;
    float level = 0;
    vDSP_rmsqv(window, 1, &level, SGVizWindow);
    float scale = settings->sensitivity / _peak;
    _bass = follow(_bass, MIN(1.3f, bass * scale), fall, dt);
    _mids = follow(_mids, MIN(1.3f, mids * scale * 1.5f), fall, dt);
    _highs = follow(_highs, MIN(1.3f, highs * scale), fall, dt);
    _level = follow(_level, MIN(1.3f, level * 4 * settings->sensitivity), fall, dt);
    frame->bass = _bass;
    frame->mids = _mids;
    frame->highs = _highs;
    frame->level = _level;

    // A kick: the bass well over where it has been lately.
    float bassNow = bass * scale;
    _sinceBeat += dt;
    frame->beat = bassNow > 0.25f && bassNow > _bassAverage * 1.45f && _sinceBeat > kBeatGap;
    if (frame->beat) _sinceBeat = 0;
    _bassAverage += (bassNow - _bassAverage) * MIN(1.0f, (float)dt * 4);

    for (NSInteger i = 0; i < SGVizWaveformPoints; i++) {
        frame->waveform[i] = MAX(-1.0f, MIN(1.0f, window[i * SGVizWindow / SGVizWaveformPoints] * 2.5f * settings->sensitivity));
    }
    frame->silent = level < 1e-5f;
}

- (void)decay:(SGVizFrame *)frame dt:(double)dt {
    float fall = powf(0.85f, (float)(dt * 60));
    NSInteger bands = MAX(4, MIN(SGVizMostBands, frame->bandCount ?: 48));
    for (NSInteger b = 0; b < bands; b++) {
        _smoothed[b] *= fall;
        frame->bands[b] = _smoothed[b];
    }
    frame->bandCount = bands;
    frame->bass = (_bass *= fall);
    frame->mids = (_mids *= fall);
    frame->highs = (_highs *= fall);
    frame->level = (_level *= fall);
    frame->beat = NO;
    for (NSInteger i = 0; i < SGVizWaveformPoints; i++) frame->waveform[i] *= fall;
    frame->silent = YES;
}

@end

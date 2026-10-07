// SGPalette.h says what this does and why it is plain C.
#include "SGPalette.h"
#include <math.h>
#include <stdlib.h>

enum { kMostPixels = 64 * 64 };
// Where the picture is read, as shares of its width and height: the centre, the quarters going round, the
// edges.
static const float kPoints[SGPaletteMaxColors][2] = {
    {0.5f, 0.5f},
    {0.25f, 0.25f}, {0.75f, 0.25f}, {0.75f, 0.75f}, {0.25f, 0.75f},
    {0.5f, 0.1f}, {0.9f, 0.5f}, {0.5f, 0.9f},
};
// How far the blur reaches, a share of the picture's side: the spread of its Gaussian.
static const float kBlur = 0.16f;
// Lifted to show on black: at least this light. A colour with more hue than a grey has is made this much
// more vivid, and more again for what lightness it gained, up to kMostVivid times.
static const float kLightFloor = 0.64f, kGreyChroma = 0.025f, kVivid = 1.3f, kMostVivid = 2.2f;

typedef struct { float L, a, b; } Lab;

static float toLinear(float c) { return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f); }
static float toGamma(float c) {
    c = c < 0 ? 0 : c > 1 ? 1 : c;
    return c <= 0.0031308f ? 12.92f * c : 1.055f * powf(c, 1 / 2.4f) - 0.055f;
}

static Lab toLab(float r, float g, float b) {
    float l = cbrtf(0.4122214708f * r + 0.5363325363f * g + 0.0514459929f * b);
    float m = cbrtf(0.2119034982f * r + 0.6806995451f * g + 0.1073969566f * b);
    float s = cbrtf(0.0883024619f * r + 0.2817188376f * g + 0.6299787005f * b);
    return (Lab){0.2104542553f * l + 0.7936177850f * m - 0.0040720468f * s,
                 1.9779984951f * l - 2.4285922050f * m + 0.4505937099f * s,
                 0.0259040371f * l + 0.7827717662f * m - 0.8086757660f * s};
}

// Linear RGB of `c`; NO when it is outside what a screen shows.
static int toLinearRGB(Lab c, float *out) {
    float l = c.L + 0.3963377774f * c.a + 0.2158037573f * c.b;
    float m = c.L - 0.1055613458f * c.a - 0.0638541728f * c.b;
    float s = c.L - 0.0894841775f * c.a - 1.2914855480f * c.b;
    l = l * l * l; m = m * m * m; s = s * s * s;
    out[0] = 4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s;
    out[1] = -1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s;
    out[2] = -0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s;
    for (int i = 0; i < 3; i++) if (out[i] < -0.002f || out[i] > 1.002f) return 0;
    return 1;
}

// Brought up to show as a bar on black, its hue kept, then drawn back in to what a screen shows by taking
// vividness away, never lightness or hue.
static void lift(Lab c, float *rgb) {
    float C = sqrtf(c.a * c.a + c.b * c.b), gain = 1;
    if (C > kGreyChroma) {
        gain = kVivid;
        if (c.L < kLightFloor && c.L > 0.05f) gain *= sqrtf(kLightFloor / c.L);
        if (gain > kMostVivid) gain = kMostVivid;
    }
    if (c.L < kLightFloor) c.L = kLightFloor;
    c.a *= gain;
    c.b *= gain;
    float linear[3];
    for (int tries = 0; tries < 40 && !toLinearRGB(c, linear); tries++) {
        c.a *= 0.92f;
        c.b *= 0.92f;
    }
    for (int i = 0; i < 3; i++) rgb[i] = toGamma(linear[i]);
}

int SGPaletteExtract(const uint8_t *rgba, int width, int height, int stride, int count, float *rgb) {
    if (!rgba || !rgb || width < 1 || height < 1 || stride < width * 4 || count < 1) return 0;
    if (count > SGPaletteMaxColors) count = SGPaletteMaxColors;

    // The picture in linear light, where a blur mixes colours as light does; a pixel every `step` either
    // way so no more than kMostPixels are read. On the heap, not static: the playing cover's palette and the
    // lock screen's frames are read on queues of their own, and may be at once.
    int step = 1;
    while ((width / step) * (height / step) > kMostPixels) step++;
    float *pixels = malloc(sizeof(float) * 5 * kMostPixels);
    if (!pixels) return 0;
    int n = 0;
    for (int y = 0; y < height; y += step) {
        const uint8_t *row = rgba + (long)y * stride;
        for (int x = 0; x < width && n < kMostPixels; x += step) {
            const uint8_t *px = row + x * 4;
            float alpha = px[3] / 255.0f;
            if (alpha < 0.5f) continue;
            float *p = pixels + n * 5;
            for (int i = 0; i < 3; i++) {
                float c = px[i] / 255.0f / alpha;
                p[i] = toLinear(c > 1 ? 1 : c);
            }
            p[3] = (x + 0.5f) / width;
            p[4] = (y + 0.5f) / height;
            n++;
        }
    }
    if (!n) {
        free(pixels);
        return 0;
    }

    float spread = 2 * kBlur * kBlur;
    for (int c = 0; c < count; c++) {
        double sum[3] = {0}, mass = 0;
        for (int i = 0; i < n; i++) {
            const float *p = pixels + i * 5;
            float dx = p[3] - kPoints[c][0], dy = p[4] - kPoints[c][1];
            float weight = expf(-(dx * dx + dy * dy) / spread);
            mass += weight;
            for (int k = 0; k < 3; k++) sum[k] += weight * p[k];
        }
        lift(toLab((float)(sum[0] / mass), (float)(sum[1] / mass), (float)(sum[2] / mass)), &rgb[c * 3]);
    }
    free(pixels);
    return count;
}

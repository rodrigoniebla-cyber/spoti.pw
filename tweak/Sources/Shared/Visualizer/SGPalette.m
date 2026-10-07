// SGPalette.h says what this does and why it is plain C.
#include "SGPalette.h"
#include <math.h>
#include <string.h>

enum { kBins = 36 };
// A pixel needs this much saturation and brightness to vote at all.
static const float kVoteSaturation = 0.12f, kVoteBrightness = 0.10f;
// A colour taken is lifted to at least this much, to show on black.
static const float kSaturationFloor = 0.5f, kBrightnessFloor = 0.78f;
// The hues within this many bins either side of a colour taken are struck off, and a hue under this share of
// the votes is not a colour of its own.
static const int kStrikeBins = 3;
static const double kLeastShare = 0.04;
// The analogous shades filling out a cover with few hues: how far each steps, in degrees.
static const float kShadeStep = 28;

static void toHSV(float r, float g, float b, float *h, float *s, float *v) {
    float most = fmaxf(r, fmaxf(g, b)), least = fminf(r, fminf(g, b)), span = most - least;
    *v = most;
    *s = most > 0 ? span / most : 0;
    float hue = 0;
    if (span > 1e-6f) {
        if (most == r) hue = fmodf((g - b) / span, 6);
        else if (most == g) hue = (b - r) / span + 2;
        else hue = (r - g) / span + 4;
        hue *= 60;
        if (hue < 0) hue += 360;
    }
    *h = hue;
}

static void toRGB(float h, float s, float v, float *r, float *g, float *b) {
    h = fmodf(h, 360);
    if (h < 0) h += 360;
    float chroma = v * s, x = chroma * (1 - fabsf(fmodf(h / 60, 2) - 1)), m = v - chroma;
    float red, green, blue;
    switch ((int)(h / 60)) {
        case 0: red = chroma; green = x; blue = 0; break;
        case 1: red = x; green = chroma; blue = 0; break;
        case 2: red = 0; green = chroma; blue = x; break;
        case 3: red = 0; green = x; blue = chroma; break;
        case 4: red = x; green = 0; blue = chroma; break;
        default: red = chroma; green = 0; blue = x; break;
    }
    *r = red + m;
    *g = green + m;
    *b = blue + m;
}

static float clamp01(float x) { return x < 0 ? 0 : x > 1 ? 1 : x; }

int SGPaletteExtract(const uint8_t *rgba, int width, int height, int stride, int count, float *rgb) {
    if (!rgba || !rgb || width < 1 || height < 1 || stride < width * 4 || count < 1) return 0;
    if (count > SGPaletteMaxColors) count = SGPaletteMaxColors;

    double weight[kBins] = {0}, sumR[kBins] = {0}, sumG[kBins] = {0}, sumB[kBins] = {0};
    double total = 0, brightness = 0;
    long seen = 0;
    for (int y = 0; y < height; y++) {
        const uint8_t *row = rgba + (long)y * stride;
        for (int x = 0; x < width; x++) {
            const uint8_t *px = row + x * 4;
            float alpha = px[3] / 255.0f;
            if (alpha < 0.5f) continue;
            float r = clamp01(px[0] / 255.0f / alpha), g = clamp01(px[1] / 255.0f / alpha), b = clamp01(px[2] / 255.0f / alpha);
            float h, s, v;
            toHSV(r, g, b, &h, &s, &v);
            brightness += v;
            seen++;
            if (s < kVoteSaturation || v < kVoteBrightness) continue;
            double w = s * (0.3 + 0.7 * v);
            int bin = (int)(h / 10) % kBins;
            weight[bin] += w;
            sumR[bin] += w * r;
            sumG[bin] += w * g;
            sumB[bin] += w * b;
            total += w;
        }
    }
    if (!seen) return 0;

    // Each hue's votes with half of its neighbours', so a hue split across a bin edge still counts whole.
    double smooth[kBins];
    for (int i = 0; i < kBins; i++) {
        smooth[i] = weight[i] + 0.5 * (weight[(i + kBins - 1) % kBins] + weight[(i + 1) % kBins]);
    }

    float hsv[SGPaletteMaxColors][3];
    int taken = 0;
    while (taken < count && total > 0) {
        int best = 0;
        for (int i = 1; i < kBins; i++) if (smooth[i] > smooth[best]) best = i;
        if (smooth[best] < kLeastShare * total) break;
        double w = 0, r = 0, g = 0, b = 0;
        for (int d = -1; d <= 1; d++) {
            int bin = (best + d + kBins) % kBins;
            w += weight[bin];
            r += sumR[bin];
            g += sumG[bin];
            b += sumB[bin];
        }
        if (w <= 0) { smooth[best] = 0; continue; }
        toHSV((float)(r / w), (float)(g / w), (float)(b / w), &hsv[taken][0], &hsv[taken][1], &hsv[taken][2]);
        taken++;
        for (int d = -kStrikeBins; d <= kStrikeBins; d++) smooth[(best + d + kBins) % kBins] = 0;
    }

    if (taken == 0) {
        // Nothing vivid: greys around how bright the picture is.
        float base = (float)(brightness / seen);
        base = base < 0.6f ? 0.6f : base > 1 ? 1 : base;
        for (int i = 0; i < count; i++) {
            hsv[i][0] = 0;
            hsv[i][1] = 0;
            hsv[i][2] = clamp01(base + ((float)i - (count - 1) / 2.0f) * 0.12f);
        }
        taken = count;
    } else {
        for (int i = 0; i < taken; i++) {
            if (hsv[i][1] < kSaturationFloor) hsv[i][1] = kSaturationFloor;
            if (hsv[i][2] < kBrightnessFloor) hsv[i][2] = kBrightnessFloor;
        }
        // Shades of the first, alternately either side of it.
        for (int k = taken; k < count; k++) {
            int step = (k - taken) / 2 + 1;
            float shift = kShadeStep * step * ((k - taken) % 2 ? -1 : 1);
            hsv[k][0] = fmodf(hsv[0][0] + shift + 360, 360);
            hsv[k][1] = hsv[0][1];
            float shade = hsv[0][2] * (step % 2 ? 0.94f : 1);
            hsv[k][2] = shade < kBrightnessFloor ? kBrightnessFloor : shade;
        }
        taken = count;
    }

    // Ring order: by hue from the dominant colour round. Greys keep the order they were made in.
    float away[SGPaletteMaxColors];
    int order[SGPaletteMaxColors];
    for (int i = 0; i < count; i++) {
        away[i] = hsv[0][1] > 0 ? fmodf(hsv[i][0] - hsv[0][0] + 360, 360) : (float)i;
        order[i] = i;
    }
    for (int i = 1; i < count; i++) {
        int item = order[i], j = i - 1;
        while (j >= 0 && away[order[j]] > away[item]) { order[j + 1] = order[j]; j--; }
        order[j + 1] = item;
    }
    for (int i = 0; i < count; i++) {
        const float *c = hsv[order[i]];
        toRGB(c[0], c[1], c[2], &rgb[i * 3], &rgb[i * 3 + 1], &rgb[i * 3 + 2]);
    }
    return count;
}

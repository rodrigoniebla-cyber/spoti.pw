// SGPalette.h says what this does and why it is plain C.
#include "SGPalette.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

enum { kMostPixels = 64 * 64, kClusters = 8, kRounds = 10 };
// What a cluster has to be to be a colour of the cover's: lighter than this (a black border or shadow is no
// colour for a bar on black), and further than this from one already taken, in OKLab.
static const float kDarkest = 0.22f, kApart = 0.09f;
// A cluster's worth: its share of the picture, lifted by how vivid it is (a grey sky counts for less than the
// red coat in front of it), up to this much.
static const float kVividLift = 6, kVividMost = 1.6f;
// Lifted to show on black: at least this light, and a colour with any hue at least this vivid.
static const float kLightFloor = 0.66f, kChromaFloor = 0.1f, kGreyChroma = 0.035f;
// The shades filling out a cover with fewer colours than asked for: lightness steps from the main one.
static const float kShadeStep = 0.1f;

typedef struct { float L, a, b; } Lab;

static float toLinear(float c) { return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f); }
static float toGamma(float c) {
    c = c < 0 ? 0 : c > 1 ? 1 : c;
    return c <= 0.0031308f ? 12.92f * c : 1.055f * powf(c, 1 / 2.4f) - 0.055f;
}

static Lab toLab(float r, float g, float b) {
    r = toLinear(r); g = toLinear(g); b = toLinear(b);
    float l = cbrtf(0.4122214708f * r + 0.5363325363f * g + 0.0514459929f * b);
    float m = cbrtf(0.2119034982f * r + 0.6806995451f * g + 0.1073969566f * b);
    float s = cbrtf(0.0883024619f * r + 0.2817188376f * g + 0.6299787005f * b);
    return (Lab){0.2104542553f * l + 0.7936177850f * m - 0.0040720468f * s,
                 1.9779984951f * l - 2.4285922050f * m + 0.4505937099f * s,
                 0.0259040371f * l + 0.7827717662f * m - 0.8086757660f * s};
}

static void toRGB(Lab c, float *out) {
    float l = c.L + 0.3963377774f * c.a + 0.2158037573f * c.b;
    float m = c.L - 0.1055613458f * c.a - 0.0638541728f * c.b;
    float s = c.L - 0.0894841775f * c.a - 1.2914855480f * c.b;
    l = l * l * l; m = m * m * m; s = s * s * s;
    out[0] = toGamma(4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s);
    out[1] = toGamma(-1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s);
    out[2] = toGamma(-0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s);
}

static float chroma(Lab c) { return sqrtf(c.a * c.a + c.b * c.b); }
static float hue(Lab c) {
    float h = atan2f(c.b, c.a) * 180 / 3.14159265f;
    return h < 0 ? h + 360 : h;
}
static float distance(Lab x, Lab y) {
    float dL = x.L - y.L, da = x.a - y.a, db = x.b - y.b;
    return sqrtf(dL * dL + da * da + db * db);
}

// Brought up to show as a bar on black, keeping its hue.
static Lab lift(Lab c) {
    if (c.L < kLightFloor) c.L = kLightFloor;
    float C = chroma(c);
    if (C > kGreyChroma && C < kChromaFloor) {
        c.a *= kChromaFloor / C;
        c.b *= kChromaFloor / C;
    }
    return c;
}

int SGPaletteExtract(const uint8_t *rgba, int width, int height, int stride, int count, float *rgb) {
    if (!rgba || !rgb || width < 1 || height < 1 || stride < width * 4 || count < 1) return 0;
    if (count > SGPaletteMaxColors) count = SGPaletteMaxColors;

    // The picture as OKLab, a pixel every `step` either way so no more than kMostPixels are read.
    // On the heap, not static: the playing cover's palette and the lock screen's frames are read on queues of
    // their own, and may be at once.
    Lab *pixels = malloc(sizeof(Lab) * kMostPixels);
    float *weights = malloc(sizeof(float) * kMostPixels), *nearest = malloc(sizeof(float) * kMostPixels);
    if (!pixels || !weights || !nearest) {
        free(pixels); free(weights); free(nearest);
        return 0;
    }
    int step = 1;
    while ((width / step) * (height / step) > kMostPixels) step++;
    int n = 0;
    double lightness = 0;
    for (int y = 0; y < height; y += step) {
        const uint8_t *row = rgba + (long)y * stride;
        for (int x = 0; x < width && n < kMostPixels; x += step) {
            const uint8_t *px = row + x * 4;
            float alpha = px[3] / 255.0f;
            if (alpha < 0.5f) continue;
            float r = px[0] / 255.0f / alpha, g = px[1] / 255.0f / alpha, b = px[2] / 255.0f / alpha;
            pixels[n] = toLab(r > 1 ? 1 : r, g > 1 ? 1 : g, b > 1 ? 1 : b);
            float lift = 1 + kVividLift * chroma(pixels[n]);
            weights[n] = lift > kVividMost ? kVividMost : lift;
            lightness += pixels[n].L;
            n++;
        }
    }
    if (!n) {
        free(pixels); free(weights); free(nearest);
        return 0;
    }

    // k-means, seeded with the heaviest pixel and then, each time, the pixel furthest from every seed so far,
    // so the seeds start spread over what the picture has and the same picture always gives the same colours.
    int k = n < kClusters ? n : kClusters;
    Lab centres[kClusters];
    int best = 0;
    for (int i = 1; i < n; i++) if (weights[i] > weights[best]) best = i;
    centres[0] = pixels[best];
    for (int i = 0; i < n; i++) nearest[i] = distance(pixels[i], centres[0]);
    for (int c = 1; c < k; c++) {
        int far = 0;
        for (int i = 1; i < n; i++) if (nearest[i] * weights[i] > nearest[far] * weights[far]) far = i;
        centres[c] = pixels[far];
        for (int i = 0; i < n; i++) {
            float d = distance(pixels[i], centres[c]);
            if (d < nearest[i]) nearest[i] = d;
        }
    }
    double mass[kClusters];
    for (int round = 0; round < kRounds; round++) {
        double sumL[kClusters] = {0}, sumA[kClusters] = {0}, sumB[kClusters] = {0};
        memset(mass, 0, sizeof mass);
        for (int i = 0; i < n; i++) {
            int owner = 0;
            float closest = distance(pixels[i], centres[0]);
            for (int c = 1; c < k; c++) {
                float d = distance(pixels[i], centres[c]);
                if (d < closest) { closest = d; owner = c; }
            }
            mass[owner] += weights[i];
            sumL[owner] += weights[i] * pixels[i].L;
            sumA[owner] += weights[i] * pixels[i].a;
            sumB[owner] += weights[i] * pixels[i].b;
        }
        for (int c = 0; c < k; c++) {
            if (mass[c] <= 0) continue;
            centres[c] = (Lab){(float)(sumL[c] / mass[c]), (float)(sumA[c] / mass[c]), (float)(sumB[c] / mass[c])};
        }
    }

    free(pixels); free(weights); free(nearest);

    // The heaviest clusters that are not too dark, each far enough from those taken before it.
    Lab taken[SGPaletteMaxColors];
    int got = 0;
    int used[kClusters] = {0};
    while (got < count) {
        int pick = -1;
        for (int c = 0; c < k; c++) {
            if (used[c] || mass[c] <= 0 || centres[c].L < kDarkest) continue;
            if (pick < 0 || mass[c] > mass[pick]) pick = c;
        }
        if (pick < 0) break;
        used[pick] = 1;
        Lab colour = lift(centres[pick]);
        int close = 0;
        for (int t = 0; t < got; t++) if (distance(taken[t], colour) < kApart) close = 1;
        if (!close) taken[got++] = colour;
    }
    if (!got) {
        // Nothing but dark: a grey as light as the picture is, lifted.
        float L = (float)(lightness / n);
        taken[got++] = lift((Lab){L, 0, 0});
    }
    // Shades of the first, lighter and darker by turns, for a cover with fewer colours than asked for.
    for (int s = got; s < count; s++) {
        int stepIndex = (s - got) / 2 + 1;
        Lab shade = taken[0];
        shade.L += kShadeStep * stepIndex * ((s - got) % 2 ? -1 : 1);
        if (shade.L > 0.97f) shade.L -= 2 * kShadeStep * stepIndex;
        if (shade.L < kLightFloor - 0.1f) shade.L = kLightFloor - 0.1f;
        taken[s] = shade;
    }

    // Ring order: by hue from the main colour round; greys after it in the order they came.
    float away[SGPaletteMaxColors];
    int order[SGPaletteMaxColors];
    int coloured = chroma(taken[0]) > kGreyChroma;
    for (int i = 0; i < count; i++) {
        away[i] = coloured && chroma(taken[i]) > kGreyChroma ? fmodf(hue(taken[i]) - hue(taken[0]) + 360, 360) : 360 + (float)i;
        order[i] = i;
    }
    away[0] = 0;
    for (int i = 1; i < count; i++) {
        int item = order[i], j = i - 1;
        while (j >= 0 && away[order[j]] > away[item]) { order[j + 1] = order[j]; j--; }
        order[j + 1] = item;
    }
    for (int i = 0; i < count; i++) toRGB(taken[order[i]], &rgb[i * 3]);
    return count;
}

// The cover palette (tweak/Sources/Shared/Visualizer/SGPalette.h) on made-up covers: two big colours come
// back as those two, a black border is no colour of its own, one colour is filled out with lighter and darker
// shades of it, a grey cover gets greys, the colours taken are light enough for a bar on black, and the main
// colour is first.
//   cc -std=c11 -I tweak/Sources -x c harness/visualizer/palette_test.c -x c tweak/Sources/Shared/Visualizer/SGPalette.m -lm
#include "Shared/Visualizer/SGPalette.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

enum { W = 32, H = 32 };
static uint8_t pixels[W * H * 4];

static void fill(int x0, int y0, int x1, int y1, int r, int g, int b) {
    for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) {
        uint8_t *p = pixels + (y * W + x) * 4;
        p[0] = (uint8_t)r; p[1] = (uint8_t)g; p[2] = (uint8_t)b; p[3] = 255;
    }
}

static float hueOf(const float *c) {
    float r = c[0], g = c[1], b = c[2];
    float most = fmaxf(r, fmaxf(g, b)), least = fminf(r, fminf(g, b)), d = most - least;
    if (d < 1e-6f) return -1;
    float h = most == r ? fmodf((g - b) / d, 6) : most == g ? (b - r) / d + 2 : (r - g) / d + 4;
    h *= 60;
    return h < 0 ? h + 360 : h;
}

static int byte(float c) { int v = (int)(c * 255 + 40); return v > 255 ? 255 : v; }

static float valueOf(const float *c) { return fmaxf(c[0], fmaxf(c[1], c[2])); }

static float away(float a, float b) {
    float d = fabsf(a - b);
    return d > 180 ? 360 - d : d;
}

static int hasHue(const float *rgb, int n, float hue, float within) {
    for (int i = 0; i < n; i++) if (away(hueOf(&rgb[i * 3]), hue) <= within) return 1;
    return 0;
}

int main(void) {
    float rgb[SGPaletteMaxColors * 3];

    // Two colours, a black border round them: red takes the most of the picture, blue less.
    memset(pixels, 0, sizeof pixels);
    for (int i = 0; i < W * H; i++) pixels[i * 4 + 3] = 255;
    fill(4, 4, 20, 28, 200, 30, 30);
    fill(20, 4, 28, 28, 30, 60, 220);
    assert(SGPaletteExtract(pixels, W, H, W * 4, 4, rgb) == 4);
    for (int i = 0; i < 12; i++) assert(rgb[i] >= 0 && rgb[i] <= 1);
    assert(away(hueOf(rgb), 0) < 12);                 // the dominant colour first, and red
    assert(hasHue(rgb, 4, 230, 14));                   // blue is in
    for (int i = 0; i < 4; i++) assert(valueOf(&rgb[i * 3]) >= 0.5f);
    // Nothing black came out as a colour.
    for (int i = 0; i < 4; i++) assert(hueOf(&rgb[i * 3]) >= 0);
    // The two taken from the picture are light enough to show on black.
    assert(valueOf(rgb) >= 0.75f);

    // The same cover with the colours the other way round: blue first.
    memset(pixels, 0, sizeof pixels);
    for (int i = 0; i < W * H; i++) pixels[i * 4 + 3] = 255;
    fill(4, 4, 12, 28, 200, 30, 30);
    fill(12, 4, 28, 28, 30, 60, 220);
    assert(SGPaletteExtract(pixels, W, H, W * 4, 3, rgb) == 3);
    assert(away(hueOf(rgb), 230) < 14);
    assert(hasHue(rgb, 3, 0, 12));

    // One colour: shades of it, of its hue, the colours not all the same.
    memset(pixels, 0, sizeof pixels);
    for (int i = 0; i < W * H; i++) pixels[i * 4 + 3] = 255;
    fill(0, 0, W, H, 30, 160, 60);
    assert(SGPaletteExtract(pixels, W, H, W * 4, 4, rgb) == 4);
    assert(away(hueOf(rgb), 135) < 12);
    for (int i = 1; i < 4; i++) {
        assert(away(hueOf(&rgb[i * 3]), hueOf(rgb)) < 15);
        float d = fabsf(rgb[i * 3] - rgb[0]) + fabsf(rgb[i * 3 + 1] - rgb[1]) + fabsf(rgb[i * 3 + 2] - rgb[2]);
        assert(d > 0.08f);
    }

    // A grey cover: greys, no hue anywhere.
    fill(0, 0, W, H, 120, 120, 120);
    assert(SGPaletteExtract(pixels, W, H, W * 4, 4, rgb) == 4);
    for (int i = 0; i < 4; i++) {
        assert(hueOf(&rgb[i * 3]) < 0);
        assert(rgb[i * 3] >= 0.4f && rgb[i * 3] <= 1);
    }

    // A rainbow: four far apart hues.
    for (int x = 0; x < W; x++) {
        float h = x * 360.0f / W, c = 0.85f, xx = c * (1 - fabsf(fmodf(h / 60, 2) - 1));
        float r, g, b;
        switch ((int)(h / 60)) { case 0: r = c; g = xx; b = 0; break; case 1: r = xx; g = c; b = 0; break;
            case 2: r = 0; g = c; b = xx; break; case 3: r = 0; g = xx; b = c; break;
            case 4: r = xx; g = 0; b = c; break; default: r = c; g = 0; b = xx; }
        fill(x, 0, x + 1, H, byte(r), byte(g), byte(b));
    }
    assert(SGPaletteExtract(pixels, W, H, W * 4, 4, rgb) == 4);
    for (int i = 0; i < 4; i++) for (int j = i + 1; j < 4; j++) assert(away(hueOf(&rgb[i * 3]), hueOf(&rgb[j * 3])) >= 40);
    // In ring order: hue grows from the first, round.
    float last = 0;
    for (int i = 1; i < 4; i++) {
        float from = fmodf(hueOf(&rgb[i * 3]) - hueOf(rgb) + 360, 360);
        assert(from > last);
        last = from;
    }

    // Premultiplied pixels read the same as straight ones; transparent ones vote for nothing.
    memset(pixels, 0, sizeof pixels);
    fill(0, 0, W, H, 200, 30, 30);
    for (int i = 0; i < W * H; i++) { pixels[i * 4] = (uint8_t)(pixels[i * 4] / 2); pixels[i * 4 + 1] /= 2; pixels[i * 4 + 2] /= 2; pixels[i * 4 + 3] = 128; }
    assert(SGPaletteExtract(pixels, W, H, W * 4, 2, rgb) == 2);
    assert(away(hueOf(rgb), 0) < 10);
    for (int i = 0; i < W * H; i++) pixels[i * 4 + 3] = 0;
    assert(SGPaletteExtract(pixels, W, H, W * 4, 2, rgb) == 0);

    // Bad arguments.
    assert(SGPaletteExtract(NULL, W, H, W * 4, 4, rgb) == 0);
    assert(SGPaletteExtract(pixels, 0, H, W * 4, 4, rgb) == 0);
    assert(SGPaletteExtract(pixels, W, H, W * 4, 0, rgb) == 0);
    assert(SGPaletteExtract(pixels, W, H, 4, 4, rgb) == 0);
    puts("palette: two colours, one hue, grey, a rainbow, premultiplied pixels and bad input passed");
    return 0;
}

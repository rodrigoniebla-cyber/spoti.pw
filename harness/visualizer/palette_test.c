// The cover palette (tweak/Sources/Shared/Visualizer/SGPalette.h) on made-up covers: the colours are where
// they are on the cover, centre first and then the quarters; a small vivid detail on a dark cover does not
// become a colour; a purple and blue cover gives purples and blues; a grey cover greys; everything light
// enough for a bar on black.
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
    if (d < 0.04f) return -1;
    float h = most == r ? fmodf((g - b) / d, 6) : most == g ? (b - r) / d + 2 : (r - g) / d + 4;
    h *= 60;
    return h < 0 ? h + 360 : h;
}

static float saturationOf(const float *c) {
    float most = fmaxf(c[0], fmaxf(c[1], c[2])), least = fminf(c[0], fminf(c[1], c[2]));
    return most > 0 ? (most - least) / most : 0;
}

static float valueOf(const float *c) { return fmaxf(c[0], fmaxf(c[1], c[2])); }

static float away(float a, float b) {
    float d = fabsf(a - b);
    return d > 180 ? 360 - d : d;
}

int main(void) {
    float rgb[SGPaletteMaxColors * 3];

    // Four quarters, four colours, a fifth in the middle: each comes back where it is. The first row is the
    // top, so red is top left, green top right, blue bottom right, yellow bottom left.
    fill(0, 0, 16, 16, 200, 30, 30);
    fill(16, 0, 32, 16, 30, 180, 60);
    fill(16, 16, 32, 32, 30, 60, 220);
    fill(0, 16, 16, 32, 220, 200, 30);
    fill(12, 12, 20, 20, 160, 40, 200);
    assert(SGPaletteExtract(pixels, W, H, W * 4, 5, rgb) == 5);
    for (int i = 0; i < 15; i++) assert(rgb[i] >= 0 && rgb[i] <= 1);
    assert(away(hueOf(&rgb[3]), 0) < 20);
    assert(away(hueOf(&rgb[6]), 135) < 25);
    assert(away(hueOf(&rgb[9]), 228) < 20);
    assert(away(hueOf(&rgb[12]), 55) < 20);
    for (int i = 0; i < 5; i++) assert(valueOf(&rgb[i * 3]) >= 0.55f);

    // A dark cover with white lettering across the middle and a few small cyan dots: greys and light greys,
    // the dots no colour of their own, and nothing red or orange.
    fill(0, 0, W, H, 12, 12, 14);
    fill(4, 12, 28, 20, 240, 240, 240);
    for (int x = 4; x < 28; x += 4) fill(x, 9, x + 1, 10, 40, 200, 220);
    assert(SGPaletteExtract(pixels, W, H, W * 4, 5, rgb) == 5);
    for (int i = 0; i < 5; i++) {
        float h = hueOf(&rgb[i * 3]);
        assert(h < 0 || (h > 150 && h < 260));             // grey, or a touch of the cyan
        assert(saturationOf(&rgb[i * 3]) < 0.35f);
        assert(valueOf(&rgb[i * 3]) >= 0.5f);
    }
    assert(valueOf(rgb) >= valueOf(&rgb[3]));             // the lettering makes the middle the lightest

    // Purple on top, blue below, a small hot yellow spot in a corner: purples and blues.
    fill(0, 0, W, 16, 90, 30, 140);
    fill(0, 16, W, H, 30, 40, 150);
    fill(29, 0, 32, 3, 255, 230, 0);
    assert(SGPaletteExtract(pixels, W, H, W * 4, 5, rgb) == 5);
    for (int i = 0; i < 5; i++) {
        float h = hueOf(&rgb[i * 3]);
        assert(h > 215 && h < 300);
        assert(saturationOf(&rgb[i * 3]) > 0.3f);
    }

    // A grey cover: greys, no hue anywhere.
    fill(0, 0, W, H, 120, 120, 120);
    assert(SGPaletteExtract(pixels, W, H, W * 4, 4, rgb) == 4);
    for (int i = 0; i < 4; i++) {
        assert(hueOf(&rgb[i * 3]) < 0);
        assert(rgb[i * 3] >= 0.5f && rgb[i * 3] <= 1);
    }

    // As many as asked for, up to eight.
    assert(SGPaletteExtract(pixels, W, H, W * 4, 12, rgb) == SGPaletteMaxColors);

    // Premultiplied pixels read the same as straight ones; transparent ones are not read.
    memset(pixels, 0, sizeof pixels);
    fill(0, 0, W, H, 200, 30, 30);
    for (int i = 0; i < W * H; i++) { pixels[i * 4] = (uint8_t)(pixels[i * 4] / 2); pixels[i * 4 + 1] /= 2; pixels[i * 4 + 2] /= 2; pixels[i * 4 + 3] = 128; }
    assert(SGPaletteExtract(pixels, W, H, W * 4, 2, rgb) == 2);
    assert(away(hueOf(rgb), 0) < 12);
    for (int i = 0; i < W * H; i++) pixels[i * 4 + 3] = 0;
    assert(SGPaletteExtract(pixels, W, H, W * 4, 2, rgb) == 0);

    // Bad arguments.
    assert(SGPaletteExtract(NULL, W, H, W * 4, 4, rgb) == 0);
    assert(SGPaletteExtract(pixels, 0, H, W * 4, 4, rgb) == 0);
    assert(SGPaletteExtract(pixels, W, H, W * 4, 0, rgb) == 0);
    assert(SGPaletteExtract(pixels, W, H, 4, 4, rgb) == 0);
    puts("palette: quarters in place, dark cover with a detail, purple and blue, grey, premultiplied and bad input passed");
    return 0;
}

// The main colours of a picture, for the visualizer's Cover gradient (Visualizer.h). Plain C so it is
// tested on the Mac or Linux against harness/visualizer/palette_test.c, like SGSpectrum.
//
// The picture is blurred and read at a few points: its centre, then the middle of each quarter going round
// (top left, top right, bottom right, bottom left), then the middle of each edge. Each point is the
// average of the picture round it, weighted by distance, so a small vivid detail or thin text barely moves
// it and the colours are the ones the cover is mostly made of where it is. Nothing is voted on or
// clustered, so no colour comes back that the cover does not have over a good part of it.
//
// Each colour is lifted to be light enough to show as a bar on black, and a colour with any hue is made a
// little more vivid, as a blur washes colours out. Its hue is kept.
#pragma once
#include <stdint.h>

enum { SGPaletteMaxColors = 8 };

// `rgba` is width x height pixels of 8 bit channels, premultiplied or not, rows `stride` bytes apart, the
// first row the top. Writes `count` (1...SGPaletteMaxColors) colours as three floats each, 0...1, into
// `rgb`, in the order of the points above, and returns how many it wrote: `count`, or 0 for an empty
// picture or bad arguments.
int SGPaletteExtract(const uint8_t *rgba, int width, int height, int stride, int count, float *rgb);

// The main colours of a picture, for the visualizer's Cover gradient (Visualizer.h). Plain C so it is
// tested on the Mac or Linux against harness/visualizer/palette_test.c, like SGSpectrum.
//
// The picture's pixels vote for a hue (36 bins of 10 degrees), each by how saturated and bright it is, so a
// cover's black border or grey sky says nothing and its vivid parts decide. The strongest hue is taken as a
// colour (the mean of its bin and the two beside it), the hues within 30 degrees of it are struck off, and
// the next strongest is taken, until there are `count` colours or what is left is under 4 % of the votes.
// Each is lifted to be bright and saturated enough to show as a bar on black. A cover with fewer hues than
// that fills the rest with analogous shades of its first colour, and a grey one with greys.
//
// The colours come back in a ring order: the dominant colour first, then the others by how far their hue is
// round from it, so a gradient through them in that order has no jump anywhere but at its own end.
#pragma once
#include <stdint.h>

enum { SGPaletteMaxColors = 8 };

// `rgba` is width x height pixels of 8 bit channels, premultiplied or not, rows `stride` bytes apart. Writes
// `count` (1...SGPaletteMaxColors) colours as three floats each, 0...1, into `rgb` and returns how many it
// wrote: `count`, or 0 for an empty picture or bad arguments.
int SGPaletteExtract(const uint8_t *rgba, int width, int height, int stride, int count, float *rgb);

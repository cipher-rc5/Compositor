#ifndef WandPixels_h
#define WandPixels_h
#include <stdint.h>
#include <stddef.h>
// Magic Wand match over premultiplied RGBA (4 bytes per pixel, `stride` bytes per row, rows
// top-down). The reference color is the average over a (2 * radius + 1)² square around the
// seed, clipped to the image. A pixel matches when every channel, alpha included, is within
// `tolerance` of it. Contiguous fills 4-connected from the seed (nothing when the seed itself
// doesn't match); otherwise every matching pixel. Writes 255 for selected, 0 elsewhere, into
// `mask` (width * height bytes). Returns the number selected, or -1 when memory runs out.
long wand_mask(const uint8_t *rgba, size_t width, size_t height, size_t stride,
               size_t seedX, size_t seedY, size_t radius, int tolerance, int contiguous, uint8_t *mask);
// Outline of the nonzero pixels of `mask`, along pixel edges, as closed loops of corner points
// (x, y pairs in pixel-edge coordinates). Outer boundaries run clockwise and holes
// counterclockwise in top-left coordinates, so the winding rule fills exactly those pixels.
// `points` receives 2 * pointCount values and `loops` each loop's corner count; both are
// malloc'd and must be freed. Returns 0 on success, -1 when memory runs out, and -2 when the
// outline is too detailed to be worth drawing.
int wand_trace(const uint8_t *mask, size_t width, size_t height,
               int32_t **points, size_t *pointCount, int32_t **loops, size_t *loopCount);
// Marks where one channel of an image is at least `threshold` (or, with `below`, less than it): 255 in `mask`
// (width * height bytes), 0 elsewhere. The channel is one byte every `step` bytes along rows `stride` bytes
// apart, starting at `bytes`. Returns how many pixels are marked.
long wand_threshold(const uint8_t *bytes, size_t width, size_t height, size_t stride, size_t step,
                    uint8_t threshold, int below, uint8_t *mask);
// Object Selection's edge offset: erodes (`erode`) or dilates `mask` (width * height bytes, 0 or nonzero) one pixel
// per step, `steps` times, over the 3 × 3 square around each pixel, clipped to the image. Eroding clears a set
// pixel with any clear neighbour and sets the rest to 255; dilating sets to 255 a clear pixel with any set
// neighbour. In place. Returns 0, or -1 when memory runs out.
int wand_morph(uint8_t *mask, size_t width, size_t height, int steps, int erode);
#endif

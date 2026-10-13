#include <stdint.h>
#include <stddef.h>
// Per-channel lookup on premultiplied RGBA (4 bytes per pixel, `stride` bytes per row): each color is divided
// by its alpha, mapped through `tables` (256 floats 0…1 each for red, green, then blue, interpolated between
// entries), and multiplied back. Alpha and fully transparent pixels are kept.
void levels_apply(uint8_t *pixels, size_t width, size_t height, size_t stride, const float *tables);
// Adds alpha-weighted counts to `bins` (1024 doubles: RGB as the mean of the channels, then red, green, blue),
// each weighted by `coverage` (1 byte per pixel, `coverageStride` bytes per row) when given.
void levels_histogram(const uint8_t *pixels, size_t width, size_t height, size_t stride,
                      const uint8_t *coverage, size_t coverageStride, double *bins);
// Adds a `side` × `side` hue/saturation vectorscope of every `step`th pixel on every `step`th row to `bins`
// (index y * side + x), each sample weighted by its alpha times step², so the counts stay those of the whole image.
void levels_vectorscope(const uint8_t *pixels, size_t width, size_t height, size_t stride, size_t step,
                        int side, double *bins);

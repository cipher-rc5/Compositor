#include <stddef.h>
#include <stdint.h>
// Fills the pixels `mask` selects (1 byte per pixel, `maskStride` bytes per row) with patches copied from the
// unselected opaque ones of `rgba` (4 bytes per pixel, `stride` bytes per row), in place. Works in memory for
// `width` × `height` pixels only, so a caller can pass a region of a larger image: its corner and the image's stride.
// Returns 1 on success, 0 when no source patch exists (pixels untouched), -1 on allocation failure.
int content_fill(uint8_t *rgba, size_t stride, const uint8_t *mask, size_t maskStride, int width, int height);

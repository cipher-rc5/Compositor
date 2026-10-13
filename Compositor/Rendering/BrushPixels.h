#ifndef BrushPixels_h
#define BrushPixels_h
#include <stdint.h>
#include <stddef.h>
// Half-open bounds of nonzero alpha in premultiplied RGBA. Empty returns all zero.
void brush_alpha_bounds(const uint8_t *bytes, size_t width, size_t height, size_t stride, size_t bounds[4]);
void layer_extract_alpha(const uint8_t *rgba, size_t rgbaStride, uint8_t *gray, size_t grayStride, size_t width, size_t height);
void layer_unpremultiply_opaque(uint8_t *rgba, size_t stride, size_t width, size_t height);
void layer_restore_alpha(uint8_t *rgba, size_t stride, const uint8_t *alpha, size_t alphaStride, size_t width, size_t height);

// Smudge and Liquify dabs, in place, over premultiplied RGBA (4 bytes per pixel, `stride` bytes per row, rows
// top-down). A dab at (cx, cy) covers the (2 * r + 1)² square around it, clipped to the image. `radius` is half
// the brush's diameter; within `hardness` of it (0–0.98, as a fraction) pixels move fully, fading smoothly to
// nothing at the rim.
// Smudge: `carried` is the color the brush carries, a (2 * r + 1)² square of RGBA floats. Picking up fills it
// from the image (zero past its edges); each dab lays it down, then picks up what it left, keeping `strength`
// of what it had.
void warp_pick_up(const uint8_t *rgba, size_t width, size_t height, size_t stride, long cx, long cy, long r, float *carried);
void warp_smudge(uint8_t *rgba, size_t width, size_t height, size_t stride, long cx, long cy, long r,
                 float radius, float hardness, float strength, float *carried);
// Liquify: pixels under the brush move by (moveX, moveY), most at its center, sampled bilinearly from a copy of
// the area as it was before the dab. `scratch` holds that copy between dabs (*scratch may start NULL; free it
// when done) and `scratchSize` its size in bytes. Returns 0, or -1 when memory runs out.
int warp_push(uint8_t *rgba, size_t width, size_t height, size_t stride, long cx, long cy, long r,
              float radius, float hardness, float moveX, float moveY, uint8_t **scratch, size_t *scratchSize);
#endif

#ifndef MattePixels_h
#define MattePixels_h
#include <stddef.h>
// Guided filtering (He, Sun & Tang) of `mask` by `guide`, both width * height floats (0–1, rows packed), over
// (2 * radius + 1)² squares with edges repeated; `epsilon` decides how much of an edge in the guide counts. Writes
// width * height floats, clamped to 0–1, into `out`, which may be `mask`. Returns 0, or -1 when memory runs out.
int matte_guided_filter(const float *mask, const float *guide, size_t width, size_t height, size_t radius,
                        float epsilon, float *out);
#endif

#include "BrushPixels.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

void brush_alpha_bounds(const uint8_t *bytes, size_t width, size_t height, size_t stride, size_t bounds[4]) {
    size_t left = width, right = 0, top = height, bottom = 0;
    for (size_t y = 0; y < height; ++y) {
        const uint8_t *row = bytes + y * stride;
        size_t first = 0;
        while (first < width && row[first * 4 + 3] == 0) ++first;
        if (first == width) continue;
        size_t last = width;
        while (last > first && row[(last - 1) * 4 + 3] == 0) --last;
        if (first < left) left = first;
        if (last > right) right = last;
        if (y < top) top = y;
        bottom = y + 1;
    }
    bounds[0] = right ? left : 0;
    bounds[1] = right ? top : 0;
    bounds[2] = right;
    bounds[3] = bottom;
}

void layer_unpremultiply_opaque(uint8_t *rgba, size_t stride, size_t width, size_t height) {
    for (size_t y = 0; y < height; ++y) {
        uint8_t *p = rgba + y * stride;
        for (size_t x = 0; x < width; ++x, p += 4) {
            unsigned a = p[3];
            for (int c = 0; c < 3; ++c) {
                unsigned v = a ? (p[c] * 255u + a / 2) / a : 0;
                p[c] = v > 255 ? 255 : v;
            }
            p[3] = 255;
        }
    }
}
void layer_restore_alpha(uint8_t *rgba, size_t stride, const uint8_t *alpha, size_t alphaStride, size_t width, size_t height) {
    for (size_t y = 0; y < height; ++y) {
        uint8_t *p = rgba + y * stride;
        for (size_t x = 0; x < width; ++x, p += 4) {
            unsigned a = alpha[y * alphaStride + x];
            for (int c = 0; c < 3; ++c) p[c] = (p[c] * a + 127) / 255;
            p[3] = a;
        }
    }
}
void layer_extract_alpha(const uint8_t *rgba, size_t rgbaStride, uint8_t *gray, size_t grayStride, size_t width, size_t height) {
    for (size_t y = 0; y < height; ++y)
        for (size_t x = 0; x < width; ++x)
            gray[y * grayStride + x] = rgba[y * rgbaStride + x * 4 + 3];
}

// Smudge and Liquify: the same arithmetic, in the same order, as the Swift these dabs replaced, so strokes come
// out identical. Fusing multiply-adds would round differently, so it stays off.
#pragma STDC FP_CONTRACT OFF

// How much a dab moves pixels at a distance `u` (0 center, 1 rim) from its center.
static inline float warp_weight(float u, float hardness) {
    if (!(u < 1)) return 0;
    if (!(u > hardness)) return 1;
    float t = (1 - u) / (1 - hardness);
    return t * t * (3 - 2 * t);
}

static inline uint8_t warp_byte(float value) {
    float v = roundf(value);
    return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
}

void warp_pick_up(const uint8_t *rgba, size_t width, size_t height, size_t stride, long cx, long cy, long r, float *carried) {
    long side = 2 * r + 1, W = (long)width, H = (long)height;
    memset(carried, 0, (size_t)(side * side) * 4 * sizeof(float));
    for (long dy = -r; dy <= r; ++dy) {
        long y = cy + dy;
        if (y < 0 || y >= H) continue;
        for (long dx = -r; dx <= r; ++dx) {
            long x = cx + dx;
            if (x < 0 || x >= W) continue;
            const uint8_t *p = rgba + (size_t)y * stride + (size_t)x * 4;
            float *c = carried + ((dy + r) * side + dx + r) * 4;
            for (int k = 0; k < 4; ++k) c[k] = (float)p[k];
        }
    }
}

void warp_smudge(uint8_t *rgba, size_t width, size_t height, size_t stride, long cx, long cy, long r,
                 float radius, float hardness, float strength, float *carried) {
    long side = 2 * r + 1, W = (long)width, H = (long)height;
    float invR = 1 / radius;
    for (long dy = -r; dy <= r; ++dy) {
        long y = cy + dy;
        if (y < 0 || y >= H) continue;
        for (long dx = -r; dx <= r; ++dx) {
            long x = cx + dx;
            if (x < 0 || x >= W) continue;
            float w = warp_weight(sqrtf((float)(dx * dx + dy * dy)) * invR, hardness);
            if (!(w > 0)) continue;
            uint8_t *p = rgba + (size_t)y * stride + (size_t)x * 4;
            float *c = carried + ((dy + r) * side + dx + r) * 4;
            for (int k = 0; k < 4; ++k) {
                float under = (float)p[k];
                float painted = under + (c[k] - under) * w;
                p[k] = warp_byte(painted);
                // The brush picks up some of what it just left, more the weaker the smudge.
                c[k] = painted + (c[k] - painted) * strength;
            }
        }
    }
}

int warp_push(uint8_t *rgba, size_t width, size_t height, size_t stride, long cx, long cy, long r,
              float radius, float hardness, float moveX, float moveY, uint8_t **scratch, size_t *scratchSize) {
    long W = (long)width, H = (long)height;
    long margin = (long)ceilf(fmaxf(fabsf(moveX), fabsf(moveY))) + 2;
    long x0 = cx - r - margin < 0 ? 0 : cx - r - margin, x1 = cx + r + margin > W - 1 ? W - 1 : cx + r + margin;
    long y0 = cy - r - margin < 0 ? 0 : cy - r - margin, y1 = cy + r + margin > H - 1 ? H - 1 : cy + r + margin;
    if (x0 > x1 || y0 > y1) return 0;
    long cw = x1 - x0 + 1, ch = y1 - y0 + 1;
    size_t needed = (size_t)(cw * ch) * 4;
    if (*scratchSize < needed) {
        uint8_t *grown = realloc(*scratch, needed);
        if (!grown) return -1;
        *scratch = grown;
        *scratchSize = needed;
    }
    // A copy of the area as it was before this dab, which the dab samples from.
    uint8_t *copy = *scratch;
    for (long y = 0; y < ch; ++y)
        memcpy(copy + y * cw * 4, rgba + (size_t)(y + y0) * stride + (size_t)x0 * 4, (size_t)cw * 4);
    float invR = 1 / radius;
    for (long dy = -r; dy <= r; ++dy) {
        long y = cy + dy;
        if (y < y0 || y > y1) continue;
        for (long dx = -r; dx <= r; ++dx) {
            long x = cx + dx;
            if (x < x0 || x > x1) continue;
            float w = warp_weight(sqrtf((float)(dx * dx + dy * dy)) * invR, hardness);
            if (!(w > 0)) continue;
            // Bilinear sample of the old pixels, from behind the brush's travel.
            float sx = (float)(x - x0) - moveX * w, sy = (float)(y - y0) - moveY * w;
            sx = sx > 0 ? sx : 0;
            sy = sy > 0 ? sy : 0;
            sx = sx < (float)(cw - 1) ? sx : (float)(cw - 1);
            sy = sy < (float)(ch - 1) ? sy : (float)(ch - 1);
            long ix = (long)sx < cw - 2 ? (long)sx : cw - 2, iy = (long)sy < ch - 2 ? (long)sy : ch - 2;
            // A one-pixel-wide area has nothing to blend between.
            if (ix < 0 || iy < 0) continue;
            float fx = sx - (float)ix, fy = sy - (float)iy;
            const uint8_t *s00 = copy + (iy * cw + ix) * 4, *s10 = s00 + 4, *s01 = s00 + cw * 4, *s11 = s01 + 4;
            uint8_t *p = rgba + (size_t)y * stride + (size_t)x * 4;
            for (int k = 0; k < 4; ++k) {
                float top = (float)s00[k] + ((float)s10[k] - (float)s00[k]) * fx;
                float bottom = (float)s01[k] + ((float)s11[k] - (float)s01[k]) * fx;
                p[k] = warp_byte(top + (bottom - top) * fy);
            }
        }
    }
    return 0;
}

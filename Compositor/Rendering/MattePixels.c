#include "MattePixels.h"
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>

// The same arithmetic, in the same order, as the Swift this replaced (GuidedMatte.filter), so mattes come out
// identical. Fusing multiply-adds would round differently, so it stays off.
#pragma STDC FP_CONTRACT OFF

static inline long matte_clamp(long value, long upper) { return value < 0 ? 0 : value > upper ? upper : value; }

// Mean over a (2r+1)² square as two running-sum passes, so the cost doesn't grow with the radius. `pass` (w * h)
// and `sums` (w) are scratch; `out` may be `src`. The column pass keeps one running sum per column and walks rows
// in order: each column sees exactly the additions it would walking down on its own, in the same order.
static void matte_box(const float *src, float *pass, float *sums, float *out, long w, long h, long r) {
    float span = (float)(r * 2 + 1);
    for (long y = 0; y < h; ++y) {
        const float *row = src + y * w;
        float *into = pass + y * w;
        float sum = 0;
        for (long x = -r; x <= r; ++x) sum += row[matte_clamp(x, w - 1)];
        for (long x = 0; x < w; ++x) {
            into[x] = sum / span;
            sum -= row[matte_clamp(x - r, w - 1)];
            sum += row[matte_clamp(x + r + 1, w - 1)];
        }
    }
    for (long x = 0; x < w; ++x) sums[x] = 0;
    for (long y = -r; y <= r; ++y) {
        const float *row = pass + matte_clamp(y, h - 1) * w;
        for (long x = 0; x < w; ++x) sums[x] += row[x];
    }
    for (long y = 0; y < h; ++y) {
        const float *leaving = pass + matte_clamp(y - r, h - 1) * w, *entering = pass + matte_clamp(y + r + 1, h - 1) * w;
        float *into = out + y * w;
        for (long x = 0; x < w; ++x) {
            into[x] = sums[x] / span;
            sums[x] -= leaving[x];
            sums[x] += entering[x];
        }
    }
}

int matte_guided_filter(const float *mask, const float *guide, size_t width, size_t height, size_t radius,
                        float epsilon, float *out) {
    if (!width || !height) return 0;
    if (width > (size_t)LONG_MAX / height || radius > (size_t)LONG_MAX / 4) return -1;
    size_t count = width * height;
    if (count > SIZE_MAX / sizeof(float) / 5) return -1;
    long w = (long)width, h = (long)height, r = (long)radius;
    // Five planes where the Swift kept thirteen: each mean is boxed in place once what it was made from is used up.
    float *planes = malloc(count * 5 * sizeof(float)), *sums = malloc(width * sizeof(float));
    if (!planes || !sums) { free(planes); free(sums); return -1; }
    float *pass = planes, *meanGuide = planes + count, *meanMask = meanGuide + count;
    float *meanSquares = meanMask + count, *meanProducts = meanSquares + count;
    matte_box(guide, pass, sums, meanGuide, w, h, r);
    matte_box(mask, pass, sums, meanMask, w, h, r);
    for (size_t i = 0; i < count; ++i) {
        meanSquares[i] = guide[i] * guide[i];
        meanProducts[i] = guide[i] * mask[i];
    }
    matte_box(meanSquares, pass, sums, meanSquares, w, h, r);
    matte_box(meanProducts, pass, sums, meanProducts, w, h, r);
    // Slope and offset take the places of the means of squares and products they are made from.
    float *slope = meanSquares, *offset = meanProducts;
    for (size_t i = 0; i < count; ++i) {
        float variance = meanSquares[i] - meanGuide[i] * meanGuide[i];
        float covariance = meanProducts[i] - meanGuide[i] * meanMask[i];
        float a = covariance / (variance + epsilon);
        float b = meanMask[i] - a * meanGuide[i];
        slope[i] = a;
        offset[i] = b;
    }
    float *meanSlope = meanGuide, *meanOffset = meanMask;
    matte_box(slope, pass, sums, meanSlope, w, h, r);
    matte_box(offset, pass, sums, meanOffset, w, h, r);
    for (size_t i = 0; i < count; ++i) {
        float value = meanSlope[i] * guide[i] + meanOffset[i];
        // Swift's min(1, max(0, value)), comparison for comparison.
        float floored = value >= 0 ? value : 0;
        out[i] = floored < 1 ? floored : 1;
    }
    free(planes);
    free(sums);
    return 0;
}

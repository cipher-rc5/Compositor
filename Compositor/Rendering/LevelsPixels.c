#include "LevelsPixels.h"
#include <math.h>
void levels_apply(uint8_t *pixels, size_t width, size_t height, size_t stride, const float *tables) {
    for (size_t y=0; y<height; ++y) for (size_t x=0; x<width; ++x) {
        uint8_t *p = pixels + y*stride + x*4;
        float alpha = p[3];
        if (!alpha) continue;
        for (int channel=0; channel<3; ++channel) {
            float v = fminf(255, p[channel]*255.0f/alpha);
            int lo = (int)v, hi = lo < 255 ? lo+1 : 255;
            const float *table = tables + channel*256;
            float result = table[lo] + (table[hi]-table[lo])*(v-lo);
            p[channel] = (uint8_t)fminf(alpha, fmaxf(0, roundf(result*alpha)));
        }
    }
}
void levels_histogram(const uint8_t *pixels, size_t width, size_t height, size_t stride,
                      const uint8_t *coverage, size_t coverageStride, double *bins) {
    for (size_t y=0; y<height; ++y) for (size_t x=0; x<width; ++x) {
        const uint8_t *p = pixels + y*stride + x*4;
        if (!p[3]) continue;
        double weight = p[3]/255.0 * (coverage ? coverage[y*coverageStride + x]/255.0 : 1);
        for (int channel=0; channel<3; ++channel) {
            int value = (int)fmin(255, round(p[channel]*255.0/p[3]));
            bins[(channel+1)*256+value] += weight;
            bins[value] += weight/3.0;
        }
    }
}
// Hue is found on the color hexagon and its angle's cosine and sine read from a table, interpolated between its
// 1024 steps, so no pixel calls trigonometry and each lands where the exact angle puts it.
#define SCOPE_TURNS 1024
void levels_vectorscope(const uint8_t *pixels, size_t width, size_t height, size_t stride, size_t step,
                        int side, double *bins) {
    if (side <= 0) return;
    if (step < 1) step = 1;
    double cosines[SCOPE_TURNS + 1], sines[SCOPE_TURNS + 1];
    for (int i=0; i<=SCOPE_TURNS; ++i) {
        double angle = i * (2 * M_PI / SCOPE_TURNS);
        cosines[i] = cos(angle) * 0.48; sines[i] = sin(angle) * 0.48;
    }
    double area = (double)step * step;
    for (size_t y=0; y<height; y+=step) for (size_t x=0; x<width; x+=step) {
        const uint8_t *p = pixels + y*stride + x*4;
        double alpha = p[3];
        if (!alpha) continue;
        double r = fmin(1, p[0]/alpha), g = fmin(1, p[1]/alpha), b = fmin(1, p[2]/alpha);
        double high = fmax(r, fmax(g, b)), low = fmin(r, fmin(g, b)), chroma = high - low;
        if (chroma <= 1e-4 || high <= 1e-4) continue;
        double hue = high == r ? (g - b) / chroma : high == g ? 2 + (b - r) / chroma : 4 + (r - g) / chroma;
        hue /= 6;
        if (hue < 0) hue += 1;
        double turn = hue * SCOPE_TURNS;
        int index = (int)turn;
        if (index >= SCOPE_TURNS) index = SCOPE_TURNS - 1;
        double fraction = turn - index, saturation = chroma / high;
        double c = cosines[index] + (cosines[index + 1] - cosines[index]) * fraction;
        double s = sines[index] + (sines[index + 1] - sines[index]) * fraction;
        int column = (int)((0.5 + c * saturation) * side);
        int row = (int)((0.5 + s * saturation) * side);
        column = column < 0 ? 0 : column >= side ? side - 1 : column;
        row = row < 0 ? 0 : row >= side ? side - 1 : row;
        bins[row * side + column] += alpha / 255 * area;
    }
}

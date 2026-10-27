// Primitives.h — Headroom Android DSP core: shared building blocks.
// Port of the primitives in NamRig/NamRig/Blocks.swift (Smoother, Biquad, ADAA1, Oversampler,
// Hermite reads) plus an FFT (vDSP replacement) used by the convolution reverb.
//
// RT discipline (same as the Swift engine): everything is allocated in prepare(), process()
// never allocates or locks.
#pragma once

#include <algorithm>
#include <atomic>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstring>
#include <vector>

namespace hr {

constexpr float kPi = 3.14159265358979323846f;

inline float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
inline float dbToGain(float db) { return std::pow(10.0f, db / 20.0f); }
inline float flushDenorm(float x) { return std::fabs(x) < 1e-18f ? 0.0f : x; }
inline float finiteOr0(float x) { return std::isfinite(x) ? x : 0.0f; }

/// One-pole parameter smoother (~ms to reach 1-1/e).
struct Smoother {
    float value = 0, target = 0, coef = 0.999f;
    explicit Smoother(float v = 0) : value(v), target(v) {}
    void prepare(double sr, float ms = 5) { coef = std::exp(-1.0f / (ms / 1000.0f * float(sr))); }
    void snap() { value = target; }
    inline float next() { value += (target - value) * (1 - coef); return value; }
    bool settled() const { return std::fabs(target - value) < 1e-6f; }
};

/// RBJ cookbook biquad.
struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    float x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    void reset() { x1 = x2 = y1 = y2 = 0; }
    void identity() { b0 = 1; b1 = b2 = a1 = a2 = 0; }
    inline float process(float x) {
        float y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1; x1 = x; y2 = y1; y1 = y;
        return y;
    }
    void setLowShelf(float freq, float gainDb, float sr) {
        float A = std::pow(10.0f, gainDb / 40), w0 = 2 * kPi * freq / sr, cw = std::cos(w0), sw = std::sin(w0);
        float sa = 2 * std::sqrt(A) * (sw / 2 * 1.4142135f);
        float a0 = (A + 1) + (A - 1) * cw + sa;
        b0 = A * ((A + 1) - (A - 1) * cw + sa) / a0;
        b1 = 2 * A * ((A - 1) - (A + 1) * cw) / a0;
        b2 = A * ((A + 1) - (A - 1) * cw - sa) / a0;
        a1 = -2 * ((A - 1) + (A + 1) * cw) / a0;
        a2 = ((A + 1) + (A - 1) * cw - sa) / a0;
    }
    void setHighShelf(float freq, float gainDb, float sr) {
        float A = std::pow(10.0f, gainDb / 40), w0 = 2 * kPi * freq / sr, cw = std::cos(w0), sw = std::sin(w0);
        float sa = 2 * std::sqrt(A) * (sw / 2 * 1.4142135f);
        float a0 = (A + 1) - (A - 1) * cw + sa;
        b0 = A * ((A + 1) + (A - 1) * cw + sa) / a0;
        b1 = -2 * A * ((A - 1) + (A + 1) * cw) / a0;
        b2 = A * ((A + 1) + (A - 1) * cw - sa) / a0;
        a1 = 2 * ((A - 1) - (A + 1) * cw) / a0;
        a2 = ((A + 1) - (A - 1) * cw - sa) / a0;
    }
    void setPeaking(float freq, float gainDb, float q, float sr) {
        float A = std::pow(10.0f, gainDb / 40), w0 = 2 * kPi * freq / sr, cw = std::cos(w0), sw = std::sin(w0);
        float alpha = sw / (2 * q), a0 = 1 + alpha / A;
        b0 = (1 + alpha * A) / a0; b1 = -2 * cw / a0; b2 = (1 - alpha * A) / a0;
        a1 = -2 * cw / a0; a2 = (1 - alpha / A) / a0;
    }
    void setLowpass(float freq, float q, float sr) {
        float w0 = 2 * kPi * freq / sr, cw = std::cos(w0), sw = std::sin(w0);
        float alpha = sw / (2 * q), a0 = 1 + alpha;
        b0 = (1 - cw) / 2 / a0; b1 = (1 - cw) / a0; b2 = (1 - cw) / 2 / a0;
        a1 = -2 * cw / a0; a2 = (1 - alpha) / a0;
    }
    void setHighpass(float freq, float q, float sr) {
        float w0 = 2 * kPi * freq / sr, cw = std::cos(w0), sw = std::sin(w0);
        float alpha = sw / (2 * q), a0 = 1 + alpha;
        b0 = (1 + cw) / 2 / a0; b1 = -(1 + cw) / a0; b2 = (1 + cw) / 2 / a0;
        a1 = -2 * cw / a0; a2 = (1 - alpha) / a0;
    }
};

/// First-order antiderivative anti-aliasing for memoryless shapers.
struct ADAA1 {
    float prevX = 0;
    static constexpr float eps = 1e-5f;
    void reset() { prevX = 0; }
    static inline float lnCosh(float x) { float a = std::fabs(x); return a + std::log1p(std::exp(-2 * a)) - 0.6931472f; }
    static inline float hardClip(float x) { return x < -1 ? -1 : (x > 1 ? 1 : x); }
    static inline float clipF1(float x) { float a = std::fabs(x); return a <= 1 ? x * x * 0.5f : a - 0.5f; }
    static inline float fuzz(float x) { return x >= 0 ? std::tanh(x) : 0.8f * std::tanh(0.7f * x); }
    static inline float fuzzF1(float x) { return x >= 0 ? lnCosh(x) : (0.8f / 0.7f) * lnCosh(0.7f * x); }
    inline float processTanh(float x) {
        float dx = x - prevX;
        float y = std::fabs(dx) < eps ? std::tanh((x + prevX) * 0.5f) : (lnCosh(x) - lnCosh(prevX)) / dx;
        prevX = x; return y;
    }
    inline float processClip(float x) {
        float dx = x - prevX;
        float y = std::fabs(dx) < eps ? hardClip((x + prevX) * 0.5f) : (clipF1(x) - clipF1(prevX)) / dx;
        prevX = x; return y;
    }
    inline float processFuzz(float x) {
        float dx = x - prevX;
        float y = std::fabs(dx) < eps ? fuzz((x + prevX) * 0.5f) : (fuzzF1(x) - fuzzF1(prevX)) / dx;
        prevX = x; return y;
    }
};

/// Correlation y[i] = sum_k a[i+k]*f[k] (vDSP_conv semantics, f already reversed by caller).
/// Written with independent accumulators so clang vectorizes it without -ffast-math.
inline void convCorr(const float* a, const float* f, float* y, int yStride, int n, int taps) {
    for (int i = 0; i < n; ++i) {
        const float* ap = a + i;
        float s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0, s5 = 0, s6 = 0, s7 = 0;
        int k = 0;
        for (; k + 8 <= taps; k += 8) {
            s0 += ap[k] * f[k];         s1 += ap[k + 1] * f[k + 1];
            s2 += ap[k + 2] * f[k + 2]; s3 += ap[k + 3] * f[k + 3];
            s4 += ap[k + 4] * f[k + 4]; s5 += ap[k + 5] * f[k + 5];
            s6 += ap[k + 6] * f[k + 6]; s7 += ap[k + 7] * f[k + 7];
        }
        float s = ((s0 + s1) + (s2 + s3)) + ((s4 + s5) + (s6 + s7));
        for (; k < taps; ++k) s += ap[k] * f[k];
        y[i * yStride] = s;
    }
}

/// Polyphase windowed-sinc oversampler (2/4/8×). Identical design to the Swift `Oversampler`.
class Oversampler {
public:
    int factor = 1;
    int latencySamples() const { return factor > 0 ? (N - 1 + factor / 2) / factor : 0; }

    void prepare(int f, int maxBlock) {
        f = std::max(1, f); int mb = std::max(1, maxBlock);
        if (!upRev.empty() && factor == f && maxBlk == mb) { reset(); return; }
        factor = f; maxBlk = mb; N = P * f;
        std::vector<float> proto(N);
        float fc = 0.5f / f, center = float(N - 1) / 2, sum = 0;
        for (int k = 0; k < N; ++k) {
            float m = k - center;
            float s = std::fabs(m) < 1e-6f ? 2 * fc : std::sin(2 * kPi * fc * m) / (kPi * m);
            float w = 0.42f - 0.5f * std::cos(2 * kPi * k / (N - 1)) + 0.08f * std::cos(4 * kPi * k / (N - 1));
            proto[k] = s * w; sum += proto[k];
        }
        for (auto& v : proto) v /= sum;
        upRev.assign(P * f, 0);
        for (int p = 0; p < f; ++p) for (int q = 0; q < P; ++q) upRev[p * P + q] = proto[(P - 1 - q) * f + p] * f;
        downRev.assign(N, 0);
        for (int j = 0; j < N; ++j) downRev[j] = proto[N - 1 - j];
        upHist.assign(P - 1, 0); upScratch.assign(P - 1 + mb, 0);
        high.assign(mb * f, 0);
        downHist.assign(N - 1, 0); downScratch.assign(N - 1 + mb * f, 0);
        filtered.assign(mb * f, 0);
    }
    void reset() {
        std::fill(upHist.begin(), upHist.end(), 0.0f);
        std::fill(downHist.begin(), downHist.end(), 0.0f);
    }
    template <typename Shape>
    void process(float* s, int n, Shape&& shape) {
        if (n <= 0) return;
        if (upRev.empty() || n > maxBlk) { for (int i = 0; i < n; ++i) s[i] = shape(s[i]); return; }
        const int f = factor, nHigh = n * f, histLen = P - 1, dHist = N - 1;
        float* us = upScratch.data(); float* hi = high.data();
        std::memcpy(us, upHist.data(), histLen * sizeof(float));
        std::memcpy(us + histLen, s, n * sizeof(float));
        for (int p = 0; p < f; ++p) convCorr(us, upRev.data() + p * P, hi + p, f, n, P);
        std::memcpy(upHist.data(), us + n, histLen * sizeof(float));
        for (int k = 0; k < nHigh; ++k) hi[k] = shape(hi[k]);
        float* ds = downScratch.data();
        std::memcpy(ds, downHist.data(), dHist * sizeof(float));
        std::memcpy(ds + dHist, hi, nHigh * sizeof(float));
        // Only every f-th decimator output is kept, so only compute those.
        for (int m = 0; m < n; ++m) convCorr(ds + m * f, downRev.data(), s + m, 1, 1, N);
        std::memcpy(downHist.data(), ds + nHigh, dHist * sizeof(float));
    }

private:
    static constexpr int P = 16;
    int N = 16, maxBlk = 0;
    std::vector<float> upRev, downRev, upHist, upScratch, high, downHist, downScratch, filtered;
};

/// 4-point Hermite interpolation.
inline float hermite(float xm1, float x0, float x1, float x2, float t) {
    float c = (x1 - xm1) * 0.5f, v = x0 - x1, w = c + v;
    float a = w + v + (x2 - x0) * 0.5f, b = w + a;
    return ((a * t - b) * t + c) * t + x0;
}
/// Hermite read at fractional delay d behind write index wi in a ring of cap.
inline float ringReadHermite(const float* base, int cap, int wi, float d) {
    float rd = float(wi) - d;
    int r0 = int(std::floor(rd)); float t = rd - float(r0);
    r0 = ((r0 % cap) + cap) % cap;
    int rm1 = r0 == 0 ? cap - 1 : r0 - 1;
    int r1 = r0 + 1 == cap ? 0 : r0 + 1;
    int r2 = r1 + 1 == cap ? 0 : r1 + 1;
    return hermite(base[rm1], base[r0], base[r1], base[r2], t);
}

/// Equal-power pan law; pan in [-1,1].
inline void equalPowerPan(float pan, float& l, float& r) {
    float p = clampf(pan, -1, 1), th = (p + 1) * (kPi / 4);
    l = std::cos(th); r = std::sin(th);
}

/// In-place iterative radix-2 complex FFT (size fixed at construction). Precomputed twiddles.
class FFT {
public:
    explicit FFT(int n = 1024) { init(n); }
    void init(int n) {
        size = n; int lg = 0; while ((1 << lg) < n) ++lg; log2n = lg;
        rev.resize(n);
        for (int i = 0; i < n; ++i) { int r = 0; for (int b = 0; b < lg; ++b) if (i & (1 << b)) r |= 1 << (lg - 1 - b); rev[i] = r; }
        tw.resize(n / 2);
        for (int k = 0; k < n / 2; ++k) tw[k] = std::polar(1.0f, -2 * kPi * k / n);
    }
    int n() const { return size; }
    /// inverse=true computes the unscaled inverse (caller divides by N).
    void transform(std::complex<float>* x, bool inverse) const {
        for (int i = 0; i < size; ++i) if (i < rev[i]) std::swap(x[i], x[rev[i]]);
        for (int len = 2; len <= size; len <<= 1) {
            int half = len >> 1, step = size / len;
            for (int i = 0; i < size; i += len) {
                for (int j = 0; j < half; ++j) {
                    std::complex<float> w = tw[j * step];
                    if (inverse) w = std::conj(w);
                    std::complex<float> u = x[i + j], v = x[i + j + half] * w;
                    x[i + j] = u + v; x[i + j + half] = u - v;
                }
            }
        }
    }
private:
    int size = 0, log2n = 0;
    std::vector<int> rev;
    std::vector<std::complex<float>> tw;
};

}  // namespace hr

// Reverbs.h — port of ReverbAlgorithms.swift (Dattorro plate, dispersive spring, FDN room/hall),
// the ReverbBlock dispatcher, and the IR convolution reverb.
//
// The IR reverb on iOS was a single 64k-point overlap-save FFT per 512 samples (vDSP). On Android
// it is a uniformly-partitioned overlap-save convolver (block 512, FFT 1024, ≤127 partitions):
// identical output/latency, ~20× fewer flops — no vendor FFT needed.
#pragma once

#include <array>
#include "Block.h"
#include "Reaper.h"

namespace hr {

Reaper& reaper();

/// Circular delay line with integer + linear-fractional taps.
struct DL {
    std::vector<float> buf; int cap = 4, w = 0;
    void alloc(int maxLen) { cap = std::max(4, maxLen); buf.assign(cap, 0); w = 0; }
    void clear() { std::fill(buf.begin(), buf.end(), 0.0f); w = 0; }
    inline void push(float x) { buf[w] = x; if (++w >= cap) w = 0; }
    inline float tapInt(int d) const { int r = w - d; if (r < 0) r += cap; return buf[r]; }
    inline float tapFrac(float d) const {
        int di = int(d); float f = d - di;
        int r0 = w - di; if (r0 < 0) r0 += cap;
        int r1 = r0 - 1; if (r1 < 0) r1 += cap;
        return buf[r0] * (1 - f) + buf[r1] * f;
    }
};
inline int clampOff(float v, int maxv) { int i = int(v); return i < 1 ? 1 : (i > maxv ? maxv : i); }

// ============================================================================================
class DattorroPlate {
public:
    float predelayMs = 0, decay = 0.5f, damp = 0.0005f, size = 1, mod = 1, mix = 0.3f;
    void prepare(double sampleRate) {
        fs = float(sampleRate);
        float sc = fs / baseFs;
        auto cap = [&](int len, bool m = false) { return int(len * sc * maxSize) + (m ? int(maxExc) : 0) + 8; };
        pd.alloc(int(0.2f * fs) + 8);
        for (int i = 0; i < 4; ++i) dif[i].alloc(cap(lDif[i]));
        apL1.alloc(cap(672, true)); dlL1.alloc(cap(4453)); apL2.alloc(cap(1801)); dlL2.alloc(cap(3720));
        apR1.alloc(cap(908, true)); dlR1.alloc(cap(4217)); apR2.alloc(cap(2656)); dlR2.alloc(cap(3163));
        prepared = true; reset();
    }
    void reset() {
        if (!prepared) return;
        pd.clear(); for (auto& d : dif) d.clear();
        apL1.clear(); dlL1.clear(); apL2.clear(); dlL2.clear(); apR1.clear(); dlR1.clear(); apR2.clear(); dlR2.clear();
        bw = dampL = dampR = tailL = tailR = lfo = 0;
    }
    void process(float* s, int n) {
        if (!prepared || n <= 0) return;
        float sc = (fs / baseFs) * clampf(size, 0.5f, maxSize);
        float dec = clampf(decay, 0, 0.97f), dmp = clampf(damp, 0, 0.95f);
        float bwc = clampf(1 - dmp, 0.2f, 0.9995f), dd2 = clampf(dec + 0.15f, 0.25f, 0.5f);
        int pdS = clampOff(std::max(0.0f, predelayMs) / 1000 * fs, pd.cap - 2);
        float exc = clampf(mod, 0, 1) * maxExc * (fs / baseFs);
        float lfoInc = 2 * kPi * 0.7f / fs;
        int nDif[4]; for (int i = 0; i < 4; ++i) nDif[i] = clampOff(lDif[i] * sc, dif[i].cap - 2);
        float nApL1 = 672 * sc, nApR1 = 908 * sc;
        int nDlL1 = clampOff(4453 * sc, dlL1.cap - 2), nApL2 = clampOff(1801 * sc, apL2.cap - 2), nDlL2 = clampOff(3720 * sc, dlL2.cap - 2);
        int nDlR1 = clampOff(4217 * sc, dlR1.cap - 2), nApR2 = clampOff(2656 * sc, apR2.cap - 2), nDlR2 = clampOff(3163 * sc, dlR2.cap - 2);
        auto off = [&](int v, const DL& dl) { return clampOff(v * sc, dl.cap - 2); };
        DL &a = dlL1, &b = apL2, &c = dlL2, &d = dlR1, &e = apR2, &f = dlR2;
        int yld0 = off(266, d), yld1 = off(2974, d), yle = off(1913, e), ylf = off(1996, f), yla = off(1990, a), ylb = off(187, b), ylc = off(1066, c);
        int yra0 = off(353, a), yra1 = off(3627, a), yrb = off(1228, b), yrc = off(2673, c), yrd = off(2111, d), yre = off(335, e), yrf = off(121, f);
        for (int i = 0; i < n; ++i) {
            float dry = s[i];
            pd.push(dry);
            float x = pd.tapInt(pdS);
            bw = flushDenorm(bwc * x + (1 - bwc) * bw); x = bw;
            x = apI(dif[0], x, nDif[0], 0.75f); x = apI(dif[1], x, nDif[1], 0.75f);
            x = apI(dif[2], x, nDif[2], 0.625f); x = apI(dif[3], x, nDif[3], 0.625f);
            float s1 = std::sin(lfo), s2 = std::sin(lfo + 1.5f);
            lfo += lfoInc; if (lfo > 2 * kPi) lfo -= 2 * kPi;
            float lenL1 = std::max(2.0f, nApL1 + exc * s1), lenR1 = std::max(2.0f, nApR1 + exc * s2);
            float nL = flushDenorm(x + dec * tailR);
            nL = ap(apL1, nL, lenL1, -0.70f);
            dlL1.push(flushDenorm(nL)); nL = dlL1.tapInt(nDlL1);
            dampL = flushDenorm((1 - dmp) * nL + dmp * dampL); nL = dampL;
            nL = apI(apL2, nL, nApL2, dd2);
            dlL2.push(flushDenorm(nL)); nL = dlL2.tapInt(nDlL2);
            float nR = flushDenorm(x + dec * tailL);
            nR = ap(apR1, nR, lenR1, -0.70f);
            dlR1.push(flushDenorm(nR)); nR = dlR1.tapInt(nDlR1);
            dampR = flushDenorm((1 - dmp) * nR + dmp * dampR); nR = dampR;
            nR = apI(apR2, nR, nApR2, dd2);
            dlR2.push(flushDenorm(nR)); nR = dlR2.tapInt(nDlR2);
            tailL = nL; tailR = nR;
            float left = 0.6f * (d.tapInt(yld0) + d.tapInt(yld1) - e.tapInt(yle) + f.tapInt(ylf) - a.tapInt(yla) - b.tapInt(ylb) - c.tapInt(ylc));
            float right = 0.6f * (a.tapInt(yra0) + a.tapInt(yra1) - b.tapInt(yrb) + c.tapInt(yrc) - d.tapInt(yrd) - e.tapInt(yre) - f.tapInt(yrf));
            s[i] = dry * (1 - mix) + 0.5f * (left + right) * mix;
        }
    }
private:
    static constexpr float baseFs = 29761, maxSize = 2.0f, maxExc = 24;
    static constexpr int lDif[4] = {142, 107, 379, 277};
    float fs = 48000; bool prepared = false;
    DL pd, dif[4], apL1, dlL1, apL2, dlL2, apR1, dlR1, apR2, dlR2;
    float bw = 0, dampL = 0, dampR = 0, tailL = 0, tailR = 0, lfo = 0;
    static inline float ap(DL& dl, float x, float len, float g) {
        float delayed = dl.tapFrac(len), wn = flushDenorm(x - g * delayed); dl.push(wn); return g * wn + delayed;
    }
    static inline float apI(DL& dl, float x, int len, float g) {
        float delayed = dl.tapInt(len), wn = flushDenorm(x - g * delayed); dl.push(wn); return g * wn + delayed;
    }
};

// ============================================================================================
class SpringReverb {
public:
    float decay = 0.72f, tension = 0.6f, tone = 0.5f, mix = 0.3f; int springs = 3;
    void prepare(double sampleRate) {
        fs = float(sampleRate);
        for (int s = 0; s < kMaxSprings; ++s) { loop[s].alloc(int(loopMs[s] / 1000 * fs * 1.5f) + 8); }
        prepared = true; reset();
    }
    void reset() {
        if (!prepared) return;
        for (int s = 0; s < kMaxSprings; ++s) { apX[s].fill(0); apY[s].fill(0); loop[s].clear(); lp[s] = 0; fb[s] = 0; }
        hpX = hpY = 0;
    }
    void process(float* s, int n) {
        if (!prepared || n <= 0) return;
        int nS = std::min(std::max(springs, 1), kMaxSprings);
        float dec = clampf(decay, 0, 0.9f), baseA = -clampf(tension, 0.05f, 0.88f);
        float fc = 1200 + clampf(tone, 0, 1) * 5000, lpC = 1 - std::exp(-2 * kPi * std::min(fc, fs * 0.45f) / fs);
        float hpR = 1 - 2 * kPi * 80 / fs;
        int loopN[kMaxSprings]; float aS[kMaxSprings];
        for (int k = 0; k < kMaxSprings; ++k) { loopN[k] = clampOff(loopMs[k] / 1000 * fs, loop[k].cap - 2); aS[k] = std::max(-0.88f, std::min(-0.05f, baseA * detune[k])); }
        float outScale = 0.7f / nS;
        for (int i = 0; i < n; ++i) {
            float dry = s[i];
            float hp = flushDenorm(dry - hpX + hpR * hpY); hpX = dry; hpY = hp;
            float wet = 0;
            for (int sp = 0; sp < nS; ++sp) {
                float a = aS[sp], v = flushDenorm(hp + dec * fb[sp]);
                float* ax = apX[sp].data(); float* ay = apY[sp].data();
                for (int k = 0; k < kAP; ++k) { float xn = v, yn = a * xn + ax[k] - a * ay[k]; ax[k] = xn; ay[k] = flushDenorm(yn); v = yn; }
                lp[sp] = flushDenorm(lp[sp] + lpC * (v - lp[sp])); v = lp[sp];
                loop[sp].push(v);
                float dlt = loop[sp].tapInt(loopN[sp]);
                dlt = 0.85f * std::tanh(dlt * 1.3f) + 0.15f * dlt;
                fb[sp] = flushDenorm(dlt); wet += dlt;
            }
            s[i] = dry * (1 - mix) + wet * outScale * mix;
        }
    }
private:
    static constexpr int kAP = 90, kMaxSprings = 3;
    static constexpr float loopMs[3] = {37.0f, 43.7f, 52.1f}, detune[3] = {1.0f, 0.97f, 1.04f};
    float fs = 48000; bool prepared = false;
    std::array<float, kAP> apX[kMaxSprings]{}, apY[kMaxSprings]{};
    DL loop[kMaxSprings]; float lp[kMaxSprings]{}, fb[kMaxSprings]{}; float hpX = 0, hpY = 0;
};

// ============================================================================================
class FDNReverb {
public:
    bool hall = false; float size = 1, decay = 1.5f, hfDamp = 0.3f, mix = 0.3f, predelayMs = 0, mod = 1;
    void prepare(double sampleRate) {
        fs = float(sampleRate);
        float sc = fs / 48000 * maxSize;
        for (int i = 0; i < N; ++i) lines[i].alloc(int(std::max(roomLen[i], hallLen[i]) * sc) + int(maxMod) + 8);
        pd.alloc(int(0.2f * fs) + 8); er.alloc(int(0.07f * fs) + 8);
        prepared = true; reset();
    }
    void reset() {
        if (!prepared) return;
        for (int i = 0; i < N; ++i) { lines[i].clear(); damp[i] = 0; lfoPh[i] = i * 0.7f; }
        pd.clear(); er.clear();
    }
    void process(float* s, int n) {
        if (!prepared || n <= 0) return;
        const int* base = hall ? hallLen : roomLen;
        float sc = fs / 48000 * clampf(size, 0.5f, maxSize), t60 = std::max(0.05f, decay);
        int M[N]; float g[N];
        for (int i = 0; i < N; ++i) { M[i] = clampOff(base[i] * sc, lines[i].cap - int(maxMod) - 2); g[i] = std::pow(10.0f, -3.0f * M[i] / (t60 * fs)); }
        float dCoef = clampf(hfDamp, 0, 0.95f) * (hall ? 0.80f : 0.30f);
        float modDepth = clampf(mod, 0, 1) * maxMod * (hall ? 1.0f : 0.35f), lfoInc = 2 * kPi * 0.9f / fs;
        int pdS = clampOff(std::max(0.0f, predelayMs) / 1000 * fs, pd.cap - 2);
        int erTap[8]; for (int t = 0; t < 8; ++t) erTap[t] = clampOff(erMs[t] / 1000 * fs, er.cap - 2);
        float y[N], dlt[N];
        for (int i = 0; i < n; ++i) {
            float dry = s[i];
            pd.push(dry); float inp = pd.tapInt(pdS);
            for (int k = 0; k < N; ++k) {
                float m = M[k] - modDepth * 0.5f * (1 + std::sin(lfoPh[k]));
                lfoPh[k] += lfoInc; if (lfoPh[k] > 2 * kPi) lfoPh[k] -= 2 * kPi;
                y[k] = lines[k].tapFrac(std::max(1.0f, m));
            }
            float wet = 0;
            for (int k = 0; k < N; ++k) wet += outSign[k] * y[k];
            if (!hall) { er.push(inp); for (int t = 0; t < 8; ++t) wet += (t % 2 ? -1.0f : 1.0f) * er.tapInt(erTap[t]) * 0.35f; }
            float sum = 0;
            for (int k = 0; k < N; ++k) { damp[k] = flushDenorm((1 - dCoef) * y[k] + dCoef * damp[k]); dlt[k] = flushDenorm(damp[k] * g[k]); sum += dlt[k]; }
            float sH = (2.0f / N) * sum;
            for (int k = 0; k < N; ++k) lines[k].push(flushDenorm(inp * (k % 2 ? -1.0f : 1.0f) + (dlt[k] - sH)));
            s[i] = dry * (1 - mix) + wet * 0.30f * mix;
        }
    }
private:
    static constexpr int N = 8;
    static constexpr int roomLen[N] = {1153, 1303, 1531, 1733, 1951, 2161, 2371, 2591};
    static constexpr int hallLen[N] = {2399, 2767, 3187, 3571, 3947, 4391, 4799, 5279};
    static constexpr float outSign[N] = {1, 1, -1, -1, 1, 1, -1, -1};
    static constexpr float erMs[8] = {7, 11, 17, 23, 29, 37, 43, 53};
    static constexpr float maxSize = 2.0f, maxMod = 18;
    float fs = 48000; bool prepared = false;
    DL lines[N], pd, er; float damp[N]{}, lfoPh[N]{};
};

// ============================================================================================
/// Reverb block: 0 room (FDN) · 1 plate · 2 spring · 3 hall (FDN). Knobs 0…100.
class ReverbBlock : public Block {
public:
    ReverbBlock() : Block(Kind::Reverb) { configure(); }
    void setParam(int id, float v) override {
        switch (id) { case P::RvbType: type = int(v); break; case P::RvbDecay: decayPct = v; break; case P::RvbDamp: dampPct = v; break; case P::RvbMix: mixPct = v; break; }
        configure();
    }
    void prepare(double sr, int) override { plate.prepare(sr); spring.prepare(sr); fdn.prepare(sr); }
    void reset() override { plate.reset(); spring.reset(); fdn.reset(); }
    void process(float* s, int n) override {
        switch (algo.load(std::memory_order_relaxed)) {
            case 1: plate.process(s, n); break;
            case 2: spring.process(s, n); break;
            default: fdn.process(s, n); break;
        }
    }
private:
    DattorroPlate plate; SpringReverb spring; FDNReverb fdn;
    std::atomic<int> algo{3}; int type = 3; float decayPct = 70, dampPct = 30, mixPct = 25;
    void configure() {
        float dec = decayPct / 100, dmp = dampPct / 100, mx = mixPct / 100;
        plate.mix = mx; spring.mix = mx; fdn.mix = mx;
        switch (type) {
            case 1: plate.decay = 0.4f + dec * 0.55f; plate.damp = dmp * 0.5f; break;
            case 2: spring.decay = 0.5f + dec * 0.38f; spring.tone = 1 - dmp; break;
            case 3: fdn.hall = true; fdn.decay = 1.5f + dec * 4.5f; fdn.hfDamp = dmp; break;
            default: fdn.hall = false; fdn.decay = 0.3f + dec * 1.2f; fdn.hfDamp = dmp; break;
        }
        algo.store(type, std::memory_order_relaxed);
    }
};

// ============================================================================================
/// Convolution reverb — uniformly-partitioned overlap-save. B=512 hop (wet latency B, like iOS),
/// FFT 2B, up to 127 partitions (65024 taps ≈ 1.35 s @48k). Predelay 0…250 ms on the wet path.
class ReverbIRBlock : public Block {
public:
    static constexpr int B = 512, NF = 2 * B, NB = B + 1, maxParts = 127;
    static constexpr int maxIR = B * maxParts;
    using cf = std::complex<float>;

    ReverbIRBlock() : Block(Kind::IRReverb), fft(NF) {}
    ~ReverbIRBlock() override { delete ir.load(); }

    void setParam(int id, float v) override {
        if (id == P::IrvMix) mix = v / 100;
        else if (id == P::IrvPredelay) { predelayMs = v; updatePredelay(); }
    }
    void prepare(double sampleRate, int) override {
        sr = float(sampleRate);
        hist.assign(size_t(maxParts) * NB, cf(0, 0));
        window.assign(NF, 0); work.assign(NF, cf(0, 0)); acc.assign(NB, cf(0, 0));
        inBuf.assign(B, 0); outBuf.assign(B, 0);
        int needPd = int(sampleRate * 0.30) + 2;
        pdRing.assign(needPd, 0);
        updatePredelay();
        clearRunning();
    }
    void reset() override { clearRunning(); }

    /// Control thread: taps already mono, at engine SR, energy-normalized by the caller.
    void setIR(const float* taps, int count) {
        int n = std::min(count, maxIR);
        Spectra* sp = nullptr;
        if (n >= 1) {
            sp = new Spectra();
            sp->parts = (n + B - 1) / B;
            sp->h.assign(size_t(sp->parts) * NB, cf(0, 0));
            std::vector<cf> tmp(NF);
            for (int p = 0; p < sp->parts; ++p) {
                std::fill(tmp.begin(), tmp.end(), cf(0, 0));
                for (int j = 0; j < B; ++j) { int k = p * B + j; if (k < n) tmp[j] = cf(taps[k], 0); }
                fft.transform(tmp.data(), false);
                for (int k = 0; k < NB; ++k) sp->h[size_t(p) * NB + k] = tmp[k];
            }
        }
        Spectra* old = ir.exchange(sp, std::memory_order_acq_rel);
        if (old) reaper().retire([old] { delete old; });
        clearPending.store(true, std::memory_order_release);
    }
    void clearIR() { setIR(nullptr, 0); }

    void process(float* s, int n) override {
        Spectra* sp = ir.load(std::memory_order_acquire);
        if (!sp || pdRing.empty()) return;
        if (clearPending.exchange(false, std::memory_order_acq_rel)) clearRunning();
        const float mx = mix; const int cap = int(pdRing.size()), dly = pdDelay;
        for (int i = 0; i < n; ++i) {
            float dry = s[i];
            inBuf[fillPos++] = dry;
            float wet = outBuf[readPos++];
            if (fillPos >= B) { convStep(*sp); fillPos = 0; readPos = 0; }
            pdRing[pdWrite] = wet;
            int ri = pdWrite - dly;
            float wd = pdRing[ri >= 0 ? ri : ri + cap];
            if (++pdWrite >= cap) pdWrite = 0;
            s[i] = dry * (1 - mx) + wd * mx;
        }
    }

private:
    struct Spectra { int parts = 0; std::vector<cf> h; };
    std::atomic<Spectra*> ir{nullptr};
    std::atomic<bool> clearPending{false};
    FFT fft;
    std::vector<cf> hist, work, acc;   // hist: ring of input spectra [maxParts][NB]
    std::vector<float> window, inBuf, outBuf, pdRing;
    int histHead = 0, fillPos = 0, readPos = 0, pdWrite = 0, pdDelay = 0;
    float sr = 48000, mix = 0.35f, predelayMs = 0;

    void updatePredelay() { int cap = std::max(1, int(pdRing.size())); pdDelay = std::min(std::max(0, int(predelayMs / 1000 * sr)), cap - 1); }
    void clearRunning() {
        std::fill(hist.begin(), hist.end(), cf(0, 0));
        std::fill(window.begin(), window.end(), 0.0f);
        std::fill(inBuf.begin(), inBuf.end(), 0.0f); std::fill(outBuf.begin(), outBuf.end(), 0.0f);
        std::fill(pdRing.begin(), pdRing.end(), 0.0f);
        histHead = fillPos = readPos = pdWrite = 0;
    }
    void convStep(const Spectra& sp) {
        // window = [previous B | new B]; X = FFT(window) → newest slot of the spectrum ring.
        std::memmove(window.data(), window.data() + B, B * sizeof(float));
        std::memcpy(window.data() + B, inBuf.data(), B * sizeof(float));
        for (int k = 0; k < NF; ++k) work[k] = cf(window[k], 0);
        fft.transform(work.data(), false);
        histHead = (histHead + maxParts - 1) % maxParts;
        cf* slot = hist.data() + size_t(histHead) * NB;
        for (int k = 0; k < NB; ++k) slot[k] = work[k];
        // Y = Σ_p X[t-p] · H[p]
        std::fill(acc.begin(), acc.end(), cf(0, 0));
        for (int p = 0; p < sp.parts; ++p) {
            const cf* x = hist.data() + size_t((histHead + p) % maxParts) * NB;
            const cf* h = sp.h.data() + size_t(p) * NB;
            for (int k = 0; k < NB; ++k) acc[k] += x[k] * h[k];
        }
        // Hermitian-extend and inverse; keep the last B samples (overlap-save).
        for (int k = 0; k < NB; ++k) work[k] = acc[k];
        for (int k = NB; k < NF; ++k) work[k] = std::conj(acc[NF - k]);
        fft.transform(work.data(), true);
        const float sc = 1.0f / NF;
        for (int j = 0; j < B; ++j) outBuf[j] = work[B + j].real() * sc;
    }
};

}  // namespace hr

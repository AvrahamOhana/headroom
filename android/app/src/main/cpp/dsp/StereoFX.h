// StereoFX.h — port of StereoFX.swift (wet-only ping-pong + decorrelated stereo Freeverb),
// LooperEngine.swift and Tuner.swift (YIN).
#pragma once

#include <atomic>
#include <functional>
#include <string>
#include "Primitives.h"

namespace hr {

class PingPongDelay {
public:
    float timeMs = 350, feedbackPct = 35, mixPct = 30, spreadPct = 100;
    void prepare(double sampleRate) {
        sr = float(sampleRate); int need = int(sampleRate * 2) + 2;
        if (int(L.size()) != need) { L.assign(need, 0); R.assign(need, 0); }
        w = 0;
    }
    void reset() { std::fill(L.begin(), L.end(), 0.0f); std::fill(R.begin(), R.end(), 0.0f); w = 0; }
    void processStereo(const float* in, float* outL, float* outR, int n) {
        int cap = int(L.size());
        if (cap <= 1) { for (int i = 0; i < n; ++i) outL[i] = outR[i] = 0; return; }
        int d = std::min(std::max(1, int(timeMs / 1000 * sr)), cap - 1);
        float fb = clampf(feedbackPct * 0.01f, 0, 0.99f), mix = std::max(mixPct * 0.01f, 0.0f), s = clampf(spreadPct * 0.01f, 0, 1);
        float selfFb = fb * (1 - s), crossFb = fb * s;
        int wi = w;
        for (int i = 0; i < n; ++i) {
            int ri = wi - d, r = ri >= 0 ? ri : ri + cap;
            float eL = L[r], eR = R[r], x = in[i];
            L[wi] = flushDenorm(x + eL * selfFb + eR * crossFb);
            R[wi] = flushDenorm(x * (1 - s) + eR * selfFb + eL * crossFb);
            outL[i] = eL * mix; outR[i] = eR * mix;
            if (++wi >= cap) wi = 0;
        }
        w = wi;
    }
private:
    float sr = 48000; std::vector<float> L, R; int w = 0;
};

class StereoReverb {
public:
    float decayPct = 60, dampPct = 35, mixPct = 25, widthPct = 100;
    void prepare(double sampleRate) {
        float scale = float(sampleRate) / 44100;
        for (int c = 0; c < 8; ++c) { cl[c].assign(std::max(1, int(combBase[c] * scale)), 0); cr[c].assign(std::max(1, int((combBase[c] + 23) * scale)), 0); }
        for (int a = 0; a < 4; ++a) { al[a].assign(std::max(1, int(apBase[a] * scale)), 0); ar[a].assign(std::max(1, int((apBase[a] + 23) * scale)), 0); }
        reset();
    }
    void reset() {
        for (int c = 0; c < 8; ++c) { std::fill(cl[c].begin(), cl[c].end(), 0.0f); std::fill(cr[c].begin(), cr[c].end(), 0.0f); icl[c] = icr[c] = 0; stl[c] = str[c] = 0; }
        for (int a = 0; a < 4; ++a) { std::fill(al[a].begin(), al[a].end(), 0.0f); std::fill(ar[a].begin(), ar[a].end(), 0.0f); ial[a] = iar[a] = 0; }
    }
    void processStereo(const float* in, float* outL, float* outR, int n) {
        if (cl[0].empty()) { for (int i = 0; i < n; ++i) outL[i] = outR[i] = 0; return; }
        float fb = 0.7f + clampf(decayPct * 0.01f, 0, 1) * 0.28f, d1 = clampf(dampPct * 0.01f, 0, 1) * 0.4f, d2 = 1 - d1;
        float mix = std::max(mixPct * 0.01f, 0.0f), width = clampf(widthPct * 0.01f, 0, 1);
        float wet1 = width * 0.5f + 0.5f, wet2 = (1 - width) * 0.5f;
        for (int i = 0; i < n; ++i) {
            float input = in[i] * 0.015f, oL = 0, oR = 0;
            for (int c = 0; c < 8; ++c) {
                oL += comb(cl[c], icl[c], stl[c], input, fb, d1, d2);
                oR += comb(cr[c], icr[c], str[c], input, fb, d1, d2);
            }
            for (int a = 0; a < 4; ++a) { oL = allpass(al[a], ial[a], oL); oR = allpass(ar[a], iar[a], oR); }
            outL[i] = (oL * wet1 + oR * wet2) * mix;
            outR[i] = (oR * wet1 + oL * wet2) * mix;
        }
    }
private:
    static constexpr int combBase[8] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
    static constexpr int apBase[4] = {556, 441, 341, 225};
    std::vector<float> cl[8], cr[8], al[4], ar[4];
    int icl[8]{}, icr[8]{}, ial[4]{}, iar[4]{}; float stl[8]{}, str[8]{};
    static inline float comb(std::vector<float>& b, int& idx, float& store, float in, float fb, float d1, float d2) {
        float y = b[idx]; store = flushDenorm(y * d2 + store * d1);
        b[idx] = in + store * fb; if (++idx >= int(b.size())) idx = 0; return y;
    }
    static inline float allpass(std::vector<float>& b, int& idx, float x) {
        float bo = b[idx], y = -x + bo; b[idx] = flushDenorm(x + bo * 0.5f); if (++idx >= int(b.size())) idx = 0; return y;
    }
};

/// End-of-chain phrase looper (≤120 s). State transitions on the control thread; audio reads.
class Looper {
public:
    enum State { Idle = 0, Recording, Playing, Overdubbing, Stopped };
    float loopLevel = 1;
    void prepare(double sampleRate) {
        int need = int(sampleRate * 120) + 16;
        if (int(buf.size()) != need) buf.assign(need, 0);
        resetState();
    }
    void resetState() { state.store(Idle); recPos = loopLen = playPos = 0; }
    void clear() { state.store(Idle); std::fill(buf.begin(), buf.end(), 0.0f); recPos = loopLen = playPos = 0; }
    void toggle() {
        switch (state.load()) {
            case Idle: recPos = playPos = loopLen = 0; state.store(Recording); break;
            case Recording: {
                // Stop recording first so the seam edit can't race the audio thread.
                state.store(Stopped);
                waitCallback();
                loopLen = std::max(recPos.load(), 1);
                if (loopLen > xfade * 2) for (int i = 0; i < xfade; ++i) {
                    float a = float(i) / xfade; float& v = buf[loopLen - xfade + i]; v = v * (1 - a) + buf[i] * a;
                }
                playPos = 0; state.store(Playing); break;
            }
            case Playing: state.store(Overdubbing); break;
            case Overdubbing: state.store(Playing); break;
            case Stopped: playPos = 0; state.store(Playing); break;
        }
    }
    void stopPlayback() { int s = state.load(); if (s == Playing || s == Overdubbing) state.store(Stopped); }
    int current() const { return state.load(); }
    bool hasLoop() const { return loopLen > 0; }
    std::function<void()> waitCallback = [] {};

    void process(float* s, int n) {
        int cap = int(buf.size()); if (cap <= 1) return;
        int st = state.load(std::memory_order_acquire);
        if (st == Recording) {
            int w = recPos.load(std::memory_order_relaxed);
            for (int i = 0; i < n && w < cap; ++i) buf[w++] = s[i];
            recPos.store(w, std::memory_order_relaxed);
        } else if (st == Playing || st == Overdubbing) {
            int len = loopLen; if (len <= 1) return;
            bool od = st == Overdubbing; float lvl = loopLevel; int p = playPos;
            for (int i = 0; i < n; ++i) {
                float ls = buf[p];
                if (od) buf[p] = clampf(buf[p] + s[i], -0.99f, 0.99f);
                s[i] += ls * lvl;
                if (++p >= len) p = 0;
            }
            playPos = p;
        }
    }
private:
    std::vector<float> buf;
    std::atomic<int> state{Idle}, recPos{0};
    int loopLen = 0, playPos = 0;
    static constexpr int xfade = 256;
};

/// YIN monophonic pitch detection (Tuner.swift). x holds framesNeeded samples oldest→newest.
struct Tuner {
    static constexpr int minLag = 48, maxLag = 768, window = 2048, framesNeeded = window + maxLag;
    /// Returns false when no confident pitch. freq/clarity out.
    static bool detect(const float* x, float sampleRate, float& freq, float& clarity) {
        float rms = 0; for (int i = 0; i < window; ++i) rms += x[i] * x[i];
        if (std::sqrt(rms / window) < 0.003f) return false;
        static thread_local float d[maxLag], cm[maxLag];
        for (int tau = 0; tau < maxLag; ++tau) d[tau] = 0;
        for (int tau = minLag; tau < maxLag; ++tau) {
            float sum = 0; for (int i = 0; i < window; ++i) { float df = x[i] - x[i + tau]; sum += df * df; } d[tau] = sum;
        }
        cm[0] = 1; float running = 0;
        for (int tau = 1; tau < maxLag; ++tau) { running += d[tau]; cm[tau] = running > 0 ? d[tau] * tau / running : 1; }
        int best = -1;
        for (int tau = minLag; tau < maxLag - 1; ++tau) {
            if (cm[tau] < 0.15f) { while (tau + 1 < maxLag && cm[tau + 1] < cm[tau]) ++tau; best = tau; break; }
        }
        if (best < 0) {
            float lo = 1; int loTau = -1;
            for (int t = minLag; t < maxLag; ++t) if (cm[t] < lo) { lo = cm[t]; loTau = t; }
            if (lo >= 0.3f) return false;
            best = loTau;
        }
        float t = float(best);
        if (best > minLag && best < maxLag - 1) {
            float a = cm[best - 1], b = cm[best], c = cm[best + 1], den = a + c - 2 * b;
            if (std::fabs(den) > 1e-9f) t += (a - c) / (2 * den);
        }
        freq = sampleRate / t;
        if (!(freq > 40 && freq < 1200)) return false;
        clarity = 1 - cm[best];
        return true;
    }
};

}  // namespace hr

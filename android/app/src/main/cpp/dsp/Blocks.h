// Blocks.h — mono chain blocks. Line-for-line port of NamRig/NamRig/Blocks.swift + Wah.swift.
#pragma once

#include <memory>
#include <vector>
#include "Block.h"
#include "NamModel.h"
#include "Reaper.h"

namespace hr {

Reaper& reaper();   // engine-wide deferred deleter (Engine.cpp)

// ---------------------------------------------------------------------------------------------
class GateBlock : public Block {
public:
    GateBlock() : Block(Kind::Gate) {}
    float thresholdDb = -60, releaseMs = 80, rangeDb = -80, holdMs = 40;
    void prepare(double sampleRate, int) override { sr = float(sampleRate); update(); }
    void reset() override { env = g = hpX1 = hpY1 = 0; holdCount = 0; open = false; }
    void setParam(int id, float v) override {
        switch (id) { case P::GateThr: thresholdDb = v; break; case P::GateRel: releaseMs = v; break; case P::GateRange: rangeDb = v; break; }
        update();
    }
    void process(float* s, int n) override {
        float e = env, gg = g, x1 = hpX1, y1 = hpY1; int hc = holdCount; bool isOpen = open;
        for (int i = 0; i < n; ++i) {
            float x = s[i];
            float y = x - x1 + detHP * y1; x1 = x; y1 = y;
            float a = std::fabs(y);
            e = a > e ? detAtk * e + (1 - detAtk) * a : detRel * e + (1 - detRel) * a;
            if (e > openThr) { isOpen = true; hc = holdSamples; }
            else if (isOpen && e < closeThr) { if (hc > 0) --hc; else isOpen = false; }
            float target = isOpen ? 1.0f : floorGain;
            gg = target > gg ? gAtk * gg + (1 - gAtk) * target : gRel * gg + (1 - gRel) * target;
            s[i] = x * gg;
        }
        env = flushDenorm(e); g = flushDenorm(gg); hpX1 = x1; hpY1 = flushDenorm(y1); holdCount = hc; open = isOpen;
    }
private:
    float sr = 48000, openThr = 0.01f, closeThr = 0.005f, floorGain = 0;
    float detAtk = 0.9f, detRel = 0.999f, gAtk = 0.9f, gRel = 0.999f, detHP = 0.99f;
    float env = 0, g = 0, hpX1 = 0, hpY1 = 0; int holdSamples = 2000, holdCount = 0; bool open = false;
    void update() {
        openThr = dbToGain(thresholdDb); closeThr = dbToGain(thresholdDb - 6);
        floorGain = dbToGain(std::min(rangeDb, 0.0f));
        detAtk = std::exp(-1 / (0.0005f * sr)); detRel = std::exp(-1 / (0.020f * sr));
        gAtk = std::exp(-1 / (0.0015f * sr)); gRel = std::exp(-1 / (std::max(5.0f, releaseMs) / 1000 * sr));
        holdSamples = int(std::max(0.0f, holdMs) / 1000 * sr);
        detHP = std::exp(-2 * kPi * 120 / sr);
    }
};

// ---------------------------------------------------------------------------------------------
/// Amp / Pedal capture: 30 Hz rumble HPF → smoothed input gain → NAM → DC blocker → smoothed makeup.
class AmpBlock : public Block {
public:
    explicit AmpBlock(Kind k = Kind::Amp) : Block(k) {}
    ~AmpBlock() override { delete model.load(); }

    /// Control thread. Takes ownership; the previous model is freed once the audio thread is past it.
    void setModel(NamModel* m) {
        NamModel* old = model.exchange(m, std::memory_order_acq_rel);
        if (old) reaper().retire([old] { delete old; });
    }
    bool hasModel() const { return model.load(std::memory_order_relaxed) != nullptr; }
    NamModel* currentModel() const { return model.load(std::memory_order_acquire); }

    void setParam(int id, float v) override {
        if (id == P::AmpDrive) inSm.target = dbToGain(v);
        else if (id == P::AmpMakeup) mkSm.target = dbToGain(v);
    }
    void prepare(double sampleRate, int maxBlock) override {
        sr = sampleRate;
        inSm.prepare(sampleRate, 8); mkSm.prepare(sampleRate, 20); inSm.snap(); mkSm.snap();
        preHP.setHighpass(30, 0.707f, float(sampleRate));
        if (auto* m = model.load()) m->prepare(sampleRate, maxBlock);
    }
    void reset() override { dcX1 = dcY1 = 0; preHP.reset(); inSm.snap(); mkSm.snap(); }
    void process(float* s, int n) override {
        for (int i = 0; i < n; ++i) s[i] = preHP.process(s[i]) * inSm.next();
        if (NamModel* m = model.load(std::memory_order_acquire)) m->process(s, s, n);
        float x1 = dcX1, y1 = dcY1;
        for (int i = 0; i < n; ++i) {
            float x = finiteOr0(s[i]);
            float y = x - x1 + 0.9975f * y1; x1 = x; y1 = y;
            s[i] = y * mkSm.next();
        }
        dcX1 = x1; dcY1 = flushDenorm(y1);
    }
    double sr = 48000;
private:
    std::atomic<NamModel*> model{nullptr};
    Smoother inSm{1}, mkSm{1};
    Biquad preHP;
    float dcX1 = 0, dcY1 = 0;
};

// ---------------------------------------------------------------------------------------------
/// Cab IR: zero-latency direct convolution, up to 2048 taps. IR swap = atomic pointer + reaper.
class CabBlock : public Block {
public:
    CabBlock() : Block(Kind::Cab) {}
    ~CabBlock() override { delete ir.load(); }
    static constexpr int maxIR = 2048;
    void prepare(double, int maxBlock) override {
        maxBlk = std::max(1, maxBlock);
        hist.assign(maxIR, 0); scratch.assign(maxIR + maxBlk, 0);
    }
    void reset() override { std::fill(hist.begin(), hist.end(), 0.0f); }
    void setIR(const float* taps, int count) {
        int n = std::min(count, maxIR);
        Taps* t = nullptr;
        if (n > 1) { t = new Taps(); t->rev.resize(n); for (int i = 0; i < n; ++i) t->rev[i] = taps[n - 1 - i]; }
        Taps* old = ir.exchange(t, std::memory_order_acq_rel);
        if (old) reaper().retire([old] { delete old; });
    }
    void clearIR() { setIR(nullptr, 0); }
    void process(float* s, int n) override {
        Taps* t = ir.load(std::memory_order_acquire);
        if (!t || n > maxBlk || hist.empty()) return;
        int len = int(t->rev.size()), need = len - 1;
        float* scr = scratch.data();
        std::memcpy(scr, hist.data() + (maxIR - need), need * sizeof(float));
        std::memcpy(scr + need, s, n * sizeof(float));
        convCorr(scr, t->rev.data(), s, 1, n, len);
        // hist = newest maxIR INPUT samples (right-aligned). The input now lives in scr+need.
        if (n >= maxIR) std::memcpy(hist.data(), scr + need + n - maxIR, maxIR * sizeof(float));
        else {
            std::memmove(hist.data(), hist.data() + n, (maxIR - n) * sizeof(float));
            std::memcpy(hist.data() + maxIR - n, scr + need, n * sizeof(float));
        }
    }
private:
    struct Taps { std::vector<float> rev; };
    std::atomic<Taps*> ir{nullptr};
    std::vector<float> hist, scratch;
    int maxBlk = 4096;
};

// ---------------------------------------------------------------------------------------------
class EQBlock : public Block {
public:
    EQBlock() : Block(Kind::EQ) {}
    void prepare(double sampleRate, int) override { sr = float(sampleRate); recompute(); }
    void reset() override { lo.reset(); md.reset(); hi.reset(); }
    void setParam(int id, float v) override {
        if (id == P::EqBass) bass = v; else if (id == P::EqMid) mid = v; else if (id == P::EqTreble) treble = v;
        recompute();
    }
    void process(float* s, int n) override { for (int i = 0; i < n; ++i) s[i] = hi.process(md.process(lo.process(s[i]))); }
private:
    Biquad lo, md, hi; float sr = 48000, bass = 0, mid = 0, treble = 0;
    void recompute() { lo.setLowShelf(120, bass, sr); md.setPeaking(750, mid, 0.7f, sr); hi.setHighShelf(3000, treble, sr); }
};

// ---------------------------------------------------------------------------------------------
/// Tape-style delay: gliding time, LP+HP+tanh conditioned feedback, Hermite read.
class DelayBlock : public Block {
public:
    DelayBlock() : Block(Kind::Delay) {}
    void setParam(int id, float v) override {
        switch (id) {
            case P::DlyTime: timeMs = v; timeSm.target = std::max(2.0f, timeMs / 1000 * sr); break;
            case P::DlyFb: feedback = v / 100; break;
            case P::DlyMix: mixSm.target = v / 100; break;
            case P::DlyTone: tone = v / 100; updateTone(); break;
            case P::DlySnap: timeSm.snap(); break;
        }
    }
    void prepare(double sampleRate, int) override {
        sr = float(sampleRate);
        int need = int(sampleRate * 2) + 8;
        if (int(buf.size()) != need) buf.assign(need, 0);
        w = 0;
        timeSm.prepare(sampleRate, 60); timeSm.target = std::max(2.0f, timeMs / 1000 * sr); timeSm.snap();
        mixSm.prepare(sampleRate, 10); mixSm.snap();
        hpCoef = std::exp(-2 * kPi * 110 / sr);
        updateTone();
    }
    void reset() override { std::fill(buf.begin(), buf.end(), 0.0f); w = 0; lp = hpX1 = hpY1 = 0; timeSm.snap(); mixSm.snap(); }
    void process(float* s, int n) override {
        int cap = int(buf.size()); if (cap <= 8) return;
        float* base = buf.data();
        float fb = std::min(feedback, 1.1f), maxD = float(cap - 4);
        int wi = w; float ls = lp, x1 = hpX1, y1 = hpY1;
        for (int i = 0; i < n; ++i) {
            float d = clampf(timeSm.next(), 2, maxD);
            float echo = ringReadHermite(base, cap, wi, d);
            ls += lpCoef * (echo - ls);
            float hpv = ls - x1 + hpCoef * y1; x1 = ls; y1 = hpv;
            float fbv = std::tanh(hpv * fb);
            float dry = s[i];
            base[wi] = flushDenorm(dry + fbv);
            s[i] = dry + echo * mixSm.next();
            if (++wi >= cap) wi = 0;
        }
        w = wi; lp = flushDenorm(ls); hpX1 = x1; hpY1 = flushDenorm(y1);
    }
private:
    std::vector<float> buf; int w = 0;
    float sr = 48000, timeMs = 350, feedback = 0.35f, tone = 0.6f;
    Smoother timeSm{16800}, mixSm{0.3f};
    float lpCoef = 0.5f, hpCoef = 0.99f, lp = 0, hpX1 = 0, hpY1 = 0;
    void updateTone() { float fc = 1200 * std::pow(10.0f, clampf(tone, 0, 1)); lpCoef = 1 - std::exp(-2 * kPi * fc / sr); }
};

// ---------------------------------------------------------------------------------------------
class CompressorBlock : public Block {
public:
    CompressorBlock() : Block(Kind::Comp) {}
    void prepare(double sampleRate, int) override { sr = float(sampleRate); updateTimes(); mkSm.prepare(sampleRate, 10); mkSm.snap(); }
    void reset() override { env = 0; grDb = 0; gr.store(0); mkSm.snap(); }
    void setParam(int id, float v) override {
        switch (id) {
            case P::CompThr: thresholdDb = v; break;
            case P::CompRatio: ratio = v; break;
            case P::CompAtk: atkMs = v; updateTimes(); break;
            case P::CompRel: relMs = v; updateTimes(); break;
            case P::CompMakeup: mkSm.target = dbToGain(v); break;
        }
    }
    float meter() const override { return gr.load(std::memory_order_relaxed); }
    void process(float* s, int n) override {
        const float thr = thresholdDb, r = std::max(1.0f, ratio), k = kneeDb, halfK = kneeDb * 0.5f;
        float g = grDb, e = env;
        for (int i = 0; i < n; ++i) {
            float x = std::fabs(s[i]);
            e = x > e ? x : e * detRel;
            float xDb = 20 * std::log10(e > 1e-7f ? e : 1e-7f);
            float over = xDb - thr, want;
            if (over <= -halfK) want = 0;
            else if (over >= halfK) want = -over * (1 - 1 / r);
            else { float t = over + halfK; want = -(1 - 1 / r) * t * t / (2 * k); }
            g = want < g ? attackCoef * g + (1 - attackCoef) * want : releaseCoef * g + (1 - releaseCoef) * want;
            s[i] *= dbToGain(g) * mkSm.next();
        }
        grDb = g; env = flushDenorm(e); gr.store(g, std::memory_order_relaxed);
    }
private:
    float thresholdDb = -18, ratio = 4, kneeDb = 6, atkMs = 10, relMs = 120, sr = 48000;
    float attackCoef = 0.998f, releaseCoef = 0.9998f, detRel = 0.9995f, env = 0, grDb = 0;
    std::atomic<float> gr{0};
    Smoother mkSm{1};
    void updateTimes() {
        attackCoef = std::exp(-1 / std::max(1.0f, atkMs / 1000 * sr));
        releaseCoef = std::exp(-1 / std::max(1.0f, relMs / 1000 * sr));
        detRel = std::exp(-1 / (0.008f * sr));
    }
};

// ---------------------------------------------------------------------------------------------
class DriveBlock : public Block {
public:
    DriveBlock() : Block(Kind::Drive) {}
    void setParam(int id, float v) override {
        switch (id) {
            case P::DriveAmt: drive = v; break;
            case P::DriveTone: toneHz = v; updateTone(); break;
            case P::DriveLevel: level = dbToGain(v); break;
            case P::DriveMode: mode = int(v); break;
        }
    }
    void prepare(double sampleRate, int maxBlock) override {
        sr = float(sampleRate); updateTone();
        os2.prepare(2, maxBlock); os8.prepare(8, maxBlock);
        aT.reset(); aC.reset(); aF.reset();
    }
    void reset() override { toneState = 0; os2.reset(); os8.reset(); aT.reset(); aC.reset(); aF.reset(); }
    void process(float* s, int n) override {
        const float d = drive;
        switch (mode) {
            case 1: os8.process(s, n, [&](float x) { return aC.processClip(x * d); }); break;
            case 2: os8.process(s, n, [&](float x) { return aF.processFuzz(x * d); }); break;
            default: os2.process(s, n, [&](float x) { return aT.processTanh(x * d); }); break;
        }
        float ts = toneState;
        for (int i = 0; i < n; ++i) { ts += toneCoef * (s[i] - ts); s[i] = ts * level; }
        toneState = flushDenorm(ts);
    }
private:
    float drive = 4, level = 1, toneHz = 4000, toneCoef = 0.3f, toneState = 0, sr = 48000; int mode = 0;
    Oversampler os2, os8; ADAA1 aT, aC, aF;
    void updateTone() { float fc = clampf(toneHz, 100, sr / 2 - 100); toneCoef = 1 - std::exp(-2 * kPi * fc / sr); }
};

// ---------------------------------------------------------------------------------------------
class BoostBlock : public Block {
public:
    BoostBlock() : Block(Kind::Boost) {}
    void setParam(int id, float v) override { if (id == P::BoostDb) sm.target = dbToGain(v); }
    void prepare(double sampleRate, int) override { sm.prepare(sampleRate, 8); sm.snap(); }
    void reset() override { sm.snap(); }
    void process(float* s, int n) override {
        if (sm.settled()) { float g = sm.value; if (g != 1) for (int i = 0; i < n; ++i) s[i] *= g; }
        else for (int i = 0; i < n; ++i) s[i] *= sm.next();
    }
private:
    Smoother sm{dbToGain(6)};
};

// ---------------------------------------------------------------------------------------------
class TremoloBlock : public Block {
public:
    TremoloBlock() : Block(Kind::Tremolo) {}
    void setParam(int id, float v) override { if (id == P::TrmRate) rateHz = v; else if (id == P::TrmDepth) depth = v / 100; }
    void prepare(double sampleRate, int) override { sr = float(sampleRate); }
    void reset() override { phase = 0; }
    void process(float* s, int n) override {
        float inc = 2 * kPi * rateHz / sr, ph = phase;
        for (int i = 0; i < n; ++i) {
            s[i] *= 1 - depth * 0.5f * (1 - std::cos(ph));
            ph += inc; if (ph > 2 * kPi) ph -= 2 * kPi;
        }
        phase = ph;
    }
private:
    float rateHz = 5, depth = 0.5f, sr = 48000, phase = 0;
};

// ---------------------------------------------------------------------------------------------
class ChorusBlock : public Block {
public:
    ChorusBlock() : Block(Kind::Chorus) {}
    void setParam(int id, float v) override {
        if (id == P::ChoRate) rateHz = v; else if (id == P::ChoDepth) depthMs = v; else if (id == P::ChoMix) mixSm.target = v / 100;
    }
    void prepare(double sampleRate, int) override {
        sr = float(sampleRate);
        int need = int(sampleRate * 0.06) + 8; if (int(buf.size()) != need) buf.assign(need, 0);
        w = 0; hpCoef = std::exp(-2 * kPi * 150 / sr);
        mixSm.prepare(sampleRate, 10); mixSm.snap();
    }
    void reset() override { std::fill(buf.begin(), buf.end(), 0.0f); w = 0; phase = 0; hpX1 = hpY1 = 0; mixSm.snap(); }
    void process(float* s, int n) override {
        int cap = int(buf.size()); if (cap <= 8) return;
        float* base = buf.data();
        float inc = 2 * kPi * rateHz / sr, baseS = baseMs / 1000 * sr, depthS = depthMs / 1000 * sr;
        float ph = phase, x1 = hpX1, y1 = hpY1; int wi = w;
        for (int i = 0; i < n; ++i) {
            float dry = s[i]; base[wi] = dry;
            float c = std::cos(ph), l1 = 0.5f * (1 - c), l2 = 0.5f * (1 + c);
            float v1 = ringReadHermite(base, cap, wi, baseS + depthS * l1);
            float v2 = ringReadHermite(base, cap, wi, baseS * 0.8f + depthS * 0.7f * l2);
            float wetRaw = (v1 + v2) * 0.5f;
            float wet = wetRaw - x1 + hpCoef * y1; x1 = wetRaw; y1 = wet;
            float mx = mixSm.next();
            s[i] = dry * (1 - mx * 0.5f) + wet * mx;
            if (++wi >= cap) wi = 0;
            ph += inc; if (ph > 2 * kPi) ph -= 2 * kPi;
        }
        phase = ph; w = wi; hpX1 = x1; hpY1 = flushDenorm(y1);
    }
private:
    float rateHz = 0.8f, depthMs = 6, sr = 48000, phase = 0, hpCoef = 0.98f, hpX1 = 0, hpY1 = 0;
    static constexpr float baseMs = 14;
    Smoother mixSm{0.4f}; std::vector<float> buf; int w = 0;
};

// ---------------------------------------------------------------------------------------------
class FlangerBlock : public Block {
public:
    FlangerBlock() : Block(Kind::Flanger) {}
    void setParam(int id, float v) override {
        switch (id) {
            case P::FlgRate: rateHz = v; break; case P::FlgDepth: depthMs = v; break;
            case P::FlgFb: feedback = v / 100; break; case P::FlgMix: mixSm.target = v / 100; break;
        }
    }
    void prepare(double sampleRate, int) override {
        sr = float(sampleRate);
        int need = int(sampleRate * 0.03) + 8; if (int(buf.size()) != need) buf.assign(need, 0);
        w = 0; hpCoef = std::exp(-2 * kPi * 90 / sr);
        mixSm.prepare(sampleRate, 10); mixSm.snap();
    }
    void reset() override { std::fill(buf.begin(), buf.end(), 0.0f); w = 0; phase = 0; hpX1 = hpY1 = 0; mixSm.snap(); }
    void process(float* s, int n) override {
        int cap = int(buf.size()); if (cap <= 8) return;
        float* base = buf.data();
        float inc = 2 * kPi * rateHz / sr, fb = std::min(feedback, 0.98f);
        float baseS = baseMs / 1000 * sr, depthS = depthMs / 1000 * sr;
        float ph = phase, x1 = hpX1, y1 = hpY1; int wi = w;
        for (int i = 0; i < n; ++i) {
            float dry = s[i];
            float tri = std::fabs(ph / kPi - 1);
            float lfo = 0.5f * (1 - std::cos(kPi * tri));
            float wet = ringReadHermite(base, cap, wi, baseS + depthS * lfo);
            float fbHP = wet - x1 + hpCoef * y1; x1 = wet; y1 = fbHP;
            base[wi] = flushDenorm(dry + std::tanh(fbHP * fb));
            float mx = mixSm.next();
            s[i] = dry * (1 - mx) + wet * mx;
            if (++wi >= cap) wi = 0;
            ph += inc; if (ph > 2 * kPi) ph -= 2 * kPi;
        }
        phase = ph; w = wi; hpX1 = x1; hpY1 = flushDenorm(y1);
    }
private:
    float rateHz = 0.4f, depthMs = 2, feedback = 0.5f, sr = 48000, phase = 0, hpCoef = 0.98f, hpX1 = 0, hpY1 = 0;
    static constexpr float baseMs = 0.6f;
    Smoother mixSm{0.5f}; std::vector<float> buf; int w = 0;
};

// ---------------------------------------------------------------------------------------------
/// Wah: TPT state-variable band-pass swept 400 Hz … 2.2 kHz by pedal or envelope.
class WahBlock : public Block {
public:
    WahBlock() : Block(Kind::Wah) {}
    void setParam(int id, float v) override {
        switch (id) {
            case P::WahPos: position = v; break; case P::WahAuto: autoMode = v > 0.5f; break;
            case P::WahSense: sensitivity = v / 100; break; case P::WahMix: mix = v / 100; break;
        }
    }
    void prepare(double sampleRate, int) override {
        fs = float(sampleRate);
        atk = std::exp(-1.0f / (0.005f * fs)); rel = std::exp(-1.0f / (0.080f * fs));
        posCoef = 1 - std::exp(-1.0f / (0.004f * fs));
        reset();
    }
    void reset() override { ic1 = ic2 = env = 0; posSm = clampf(position, 0, 1); }
    void process(float* s, int n) override {
        const float k = 1 / q, mx = clampf(mix, 0, 1), nyq = fs * 0.45f;
        if (autoMode) {
            float sens = 1 + clampf(sensitivity, 0, 1) * 9;
            for (int i = 0; i < n; ++i) {
                float x = s[i], a = std::fabs(x);
                env = a > env ? atk * env + (1 - atk) * a : rel * env + (1 - rel) * a;
                float pos = clampf(env * sens, 0, 1);
                float fc = std::min(loHz * std::pow(hiHz / loHz, pos), nyq);
                float y = bandpass(x, std::tan(kPi * fc / fs), k) * wetBoost;
                s[i] = x * (1 - mx) + y * mx;
            }
            env = flushDenorm(env);
        } else {
            float target = clampf(position, 0, 1);
            for (int i = 0; i < n; ++i) {
                posSm += (target - posSm) * posCoef;
                float fc = std::min(loHz * std::pow(hiHz / loHz, posSm), nyq);
                float y = bandpass(s[i], std::tan(kPi * fc / fs), k) * wetBoost;
                s[i] = s[i] * (1 - mx) + y * mx;
            }
        }
    }
private:
    float position = 0.5f, sensitivity = 0.5f, mix = 0.92f; bool autoMode = false;
    float fs = 48000, ic1 = 0, ic2 = 0, env = 0, atk = 0.99f, rel = 0.9995f, posSm = 0.5f, posCoef = 0.002f;
    static constexpr float loHz = 400, hiHz = 2200, q = 4.0f, wetBoost = 1.6f;
    inline float bandpass(float x, float g, float k) {
        float a1 = 1 / (1 + g * (g + k)), a2 = g * a1, a3 = g * a2;
        float v3 = x - ic2, v1 = a1 * ic1 + a2 * v3, v2 = ic2 + a2 * ic1 + a3 * v3;
        ic1 = flushDenorm(2 * v1 - ic1); ic2 = flushDenorm(2 * v2 - ic2);
        return v1;
    }
};

}  // namespace hr

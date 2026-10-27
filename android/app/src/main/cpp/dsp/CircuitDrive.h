// CircuitDrive.h — circuit-derived OD / distortion / fuzz library. Port of CircuitDrive.swift.
// Model names are original/allusive; see the disclaimer in the Kotlin UI.
#pragma once

#include "Block.h"

namespace hr {

enum class ClipMode { SoftFeedback, SoftBounded, HardShunt, Asym };
enum class ToneType { LowpassTilt, RatFilter, ScoopTilt, KlonTilt, MuffScoop };

struct PedalModel {
    const char* name; float inputHz, gainLo, gainHi; ClipMode clip; float diodeVf, asymVf, feedbackCapHz;
    ToneType tone; float toneLoHz, toneHiHz, scoopHz, scoopDb, makeup; int oversample, stages; bool needsDC;
};

inline const PedalModel kPedals[] = {
    {"Green Screamer", 600, 1.5f, 45, ClipMode::SoftFeedback, 0.6f, 0.6f, 0, ToneType::LowpassTilt, 700, 2200, 0, 0, 0.65f, 2, 1, false},
    {"Rodent", 32, 2.5f, 75, ClipMode::HardShunt, 0.6f, 0.6f, 2400, ToneType::RatFilter, 700, 4500, 0, 0, 0.42f, 8, 1, false},
    {"Modern Distortion", 50, 3, 90, ClipMode::HardShunt, 0.6f, 0.6f, 5000, ToneType::ScoopTilt, 1500, 4500, 600, -7, 0.42f, 8, 1, false},
    {"Centaur Gold", 40, 1, 30, ClipMode::Asym, 0.30f, 0.38f, 0, ToneType::KlonTilt, 0, 3000, 0, 0, 0.50f, 4, 1, true},
    {"Muffin Fuzz", 80, 4, 120, ClipMode::SoftBounded, 0.6f, 0.6f, 0, ToneType::MuffScoop, 800, 4500, 1000, -13.5f, 0.50f, 8, 2, false},
};
constexpr int kPedalCount = int(sizeof(kPedals) / sizeof(kPedals[0]));

class CircuitDriveBlock : public Block {
public:
    CircuitDriveBlock() : Block(Kind::Stomp) {}

    void setParam(int id, float v) override {
        switch (id) {
            case P::StompModel: { int m = int(v); if (m != model) { model = m; recompute(true); } return; }
            case P::StompDrive: drive = v; break;
            case P::StompTone: tone = v; break;
            case P::StompLevel: level = v; break;
        }
        recompute(false);
    }
    void prepare(double sampleRate, int maxBlock) override {
        sr = float(sampleRate); maxBlk = std::max(1, maxBlock);
        os2.prepare(2, maxBlk); os4.prepare(4, maxBlk); os8.prepare(8, maxBlk);
        recompute(true); reset();
    }
    void reset() override {
        inputHP.reset(); preLP.reset(); bq0.reset(); bq1.reset(); bq2.reset(); smoothLP.reset();
        dcX1 = dcY1 = 0; adaaA.reset(); adaaB.reset(); os2.reset(); os4.reset(); os8.reset();
    }

    void process(float* s, int n) override {
        if (n <= 0 || n > maxBlk) return;
        for (int i = 0; i < n; ++i) s[i] = inputHP.process(s[i]);
        if (hasPreLP) for (int i = 0; i < n; ++i) s[i] = preLP.process(s[i]);

        switch (clipMode) {
            case ClipMode::SoftFeedback:
                if (stages == 2) applyClip(s, n, [&](float x) { return step(adaaB, x, g2, 1, false, stepRaw(adaaA, x, g, 1, false)); });
                else applyClip(s, n, [&](float x) { return stepRaw(adaaA, x, g, 1, false); });
                break;
            case ClipMode::SoftBounded:
                if (stages == 2) applyClip(s, n, [&](float x) { return step(adaaB, x, g2, 0, false, stepRaw(adaaA, x, g, 0, false)); });
                else applyClip(s, n, [&](float x) { return stepRaw(adaaA, x, g, 0, false); });
                break;
            case ClipMode::HardShunt:
                applyClip(s, n, [&](float x) { return hardStep(x); });
                break;
            case ClipMode::Asym:
                applyClip(s, n, [&](float x) { return stepRaw(adaaA, x, g, 1, true); });
                break;
        }
        if (needsDC) {
            float x1 = dcX1, y1 = dcY1;
            for (int i = 0; i < n; ++i) { float x = finiteOr0(s[i]); float y = x - x1 + 0.9975f * y1; x1 = x; y1 = y; s[i] = y; }
            dcX1 = x1; dcY1 = flushDenorm(y1);
        }
        const float lg = outGain;
        for (int i = 0; i < n; ++i) {
            float v = bq2.process(bq1.process(bq0.process(s[i])));
            v = smoothLP.process(v) * lg;
            s[i] = finiteOr0(v);
        }
    }

private:
    int model = 0; float drive = 0.5f, tone = 0.5f, level = 0.8f;
    float sr = 48000, g = 1, g2 = 1, vf = 0.6f, vfNeg = 0.6f, outGain = 1;
    ClipMode clipMode = ClipMode::SoftFeedback; int osFactor = 2, stages = 1, maxBlk = 4096;
    bool needsDC = false, hasPreLP = false;
    Biquad inputHP, preLP, bq0, bq1, bq2, smoothLP;
    float dcX1 = 0, dcY1 = 0;
    ADAA1 adaaA, adaaB;
    Oversampler os2, os4, os8;

    const PedalModel& current() const { return kPedals[std::min(std::max(0, model), kPedalCount - 1)]; }
    static float lerp(float a, float b, float x) { return a + (b - a) * x; }

    void recompute(bool resetFilters) {
        const PedalModel& m = current();
        float d = clampf(drive, 0, 1), t = clampf(tone, 0, 1);
        float gg = m.gainLo * std::pow(m.gainHi / m.gainLo, d);
        g = gg; g2 = m.stages == 2 ? std::max(2.0f, gg * 0.6f) : gg;
        vf = m.diodeVf; vfNeg = m.asymVf;
        clipMode = m.clip; osFactor = m.oversample; stages = m.stages; needsDC = m.needsDC;
        hasPreLP = m.feedbackCapHz > 0;
        outGain = m.makeup * clampf(level, 0, 1);
        inputHP.setHighpass(std::min(m.inputHz, sr * 0.45f), 0.707f, sr);
        if (hasPreLP) preLP.setLowpass(std::min(m.feedbackCapHz, sr * 0.45f), 0.707f, sr); else preLP.identity();
        switch (m.tone) {
            case ToneType::LowpassTilt:
                bq0.setLowpass(lerp(m.toneLoHz, m.toneHiHz, t), 0.707f, sr);
                bq1.setHighShelf(3000, -2.5f, sr); bq2.setPeaking(720, 3, 0.7f, sr); break;
            case ToneType::RatFilter:
                bq0.setLowpass(lerp(m.toneHiHz, m.toneLoHz, t), 0.707f, sr); bq1.identity(); bq2.identity(); break;
            case ToneType::ScoopTilt:
                bq0.setLowpass(lerp(m.toneLoHz, m.toneHiHz, t), 0.707f, sr);
                bq1.setHighShelf(3000, lerp(-5, 4, t), sr); bq2.setPeaking(m.scoopHz, m.scoopDb, 1.0f, sr); break;
            case ToneType::KlonTilt:
                bq0.setHighShelf(m.toneHiHz, lerp(-3, 4, t), sr); bq1.setLowpass(std::min(8500.0f, sr * 0.45f), 0.707f, sr); bq2.identity(); break;
            case ToneType::MuffScoop:
                bq0.setPeaking(m.scoopHz, m.scoopDb, 0.9f, sr); bq1.setLowpass(lerp(m.toneLoHz, m.toneHiHz, t), 0.707f, sr); bq2.identity(); break;
        }
        smoothLP.setLowpass(std::min(10000.0f, sr * 0.45f), 0.707f, sr);
        if (resetFilters) { inputHP.reset(); preLP.reset(); bq0.reset(); bq1.reset(); bq2.reset(); smoothLP.reset(); }
    }

    template <typename F> void applyClip(float* s, int n, F&& f) {
        if (osFactor == 8) os8.process(s, n, f); else if (osFactor == 4) os4.process(s, n, f); else os2.process(s, n, f);
    }
    // Shapes. `ramp`=1 → soft-feedback (x + Vf·tanh(gx/Vf)); 0 → bounded (Vf·tanh(gx/Vf)).
    inline float shape(float x, float gain, float ramp, bool asym) const {
        float v = (asym && x < 0) ? vfNeg : vf;
        return ramp * x + v * std::tanh(gain * x / v);
    }
    inline float F1(float x, float gain, float ramp, bool asym) const {
        float v = (asym && x < 0) ? vfNeg : vf;
        return ramp * 0.5f * x * x + (v * v / gain) * ADAA1::lnCosh(gain * x / v);
    }
    inline float stepRaw(ADAA1& a, float x, float gain, float ramp, bool asym) {
        float p = a.prevX, dx = x - p;
        float y = std::fabs(dx) < ADAA1::eps ? shape((x + p) * 0.5f, gain, ramp, asym) : (F1(x, gain, ramp, asym) - F1(p, gain, ramp, asym)) / dx;
        a.prevX = x; return y;
    }
    // Second cascaded stage takes the first stage's output as its input.
    inline float step(ADAA1& a, float, float gain, float ramp, bool asym, float in) { return stepRaw(a, in, gain, ramp, asym); }
    inline float hardStep(float x) {
        float p = adaaA.prevX, dx = x - p;
        auto hs = [&](float u) { return vf * ADAA1::hardClip(g * u / vf); };
        auto hf = [&](float u) { return (vf * vf / g) * ADAA1::clipF1(g * u / vf); };
        float y = std::fabs(dx) < ADAA1::eps ? hs((x + p) * 0.5f) : (hf(x) - hf(p)) / dx;
        adaaA.prevX = x; return y;
    }
};

}  // namespace hr

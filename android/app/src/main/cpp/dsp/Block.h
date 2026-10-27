// Block.h — base class + kind/param ids shared with Kotlin (keep in sync with BlockKind.kt).
#pragma once

#include <atomic>
#include "Primitives.h"

namespace hr {

/// Same order as Swift `BlockKind.allCases` and Kotlin `BlockKind` — the ordinal crosses JNI.
enum class Kind : int {
    Gate = 0, Comp, Boost, Drive, Stomp, Wah, Pedal, Amp, Cab, EQ,
    Chorus, Flanger, Tremolo, Delay, Reverb, IRReverb, Count
};

/// Per-kind parameter ids, in UI units (dB, ms, %, Hz…). Conversion happens in the block.
namespace P {
enum Gate { GateThr = 0, GateRel, GateRange };
enum Comp { CompThr = 0, CompRatio, CompAtk, CompRel, CompMakeup };
enum Boost { BoostDb = 0 };
enum Drive { DriveAmt = 0, DriveTone, DriveLevel, DriveMode };
enum Stomp { StompModel = 0, StompDrive, StompTone, StompLevel };
enum Wah { WahPos = 0, WahAuto, WahSense, WahMix };
enum Amp { AmpDrive = 0, AmpMakeup };   // pedal + amp: input drive dB, output makeup dB
enum EQ { EqBass = 0, EqMid, EqTreble };
enum Chorus { ChoRate = 0, ChoDepth, ChoMix };
enum Flanger { FlgRate = 0, FlgDepth, FlgFb, FlgMix };
enum Tremolo { TrmRate = 0, TrmDepth };
enum Delay { DlyTime = 0, DlyFb, DlyMix, DlyTone, DlySnap };
enum Reverb { RvbType = 0, RvbDecay, RvbDamp, RvbMix };
enum IRReverb { IrvMix = 0, IrvPredelay };
}  // namespace P

class Block {
public:
    explicit Block(Kind k) : kind(k) {}
    virtual ~Block() = default;
    const Kind kind;
    std::atomic<bool> bypass{false};

    virtual void prepare(double sampleRate, int maxBlock) {}
    virtual void process(float* s, int n) = 0;   // in place, mono, n <= maxBlock
    virtual void reset() {}
    virtual void setParam(int id, float v) {}
    /// Optional read-back for meters (comp gain reduction).
    virtual float meter() const { return 0; }

    inline void render(float* s, int n) { if (!bypass.load(std::memory_order_relaxed)) process(s, n); }
};

}  // namespace hr

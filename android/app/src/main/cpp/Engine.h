// Engine.h — Headroom Android render engine (platform-independent; Oboe glue is in AudioIO.cpp).
// Mirrors AudioEngine.swift's RenderContext + render callback.
#pragma once

#include <array>
#include <atomic>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include "dsp/Block.h"
#include "dsp/Reaper.h"
#include "dsp/StereoFX.h"

namespace hr {

/// Ordered, lock-free-for-the-audio-thread chain (double-buffered slot tables + atomic flip).
class SignalChain {
public:
    static constexpr int cap = 64;
    void set(const std::vector<Block*>& blocks, Reaper& rp);
    void render(float* s, int n) {
        // Hazard protocol: announce the table we read, then confirm it is still active.
        int a = active.load();
        for (;;) { reading.store(a); int a2 = active.load(); if (a2 == a) break; a = a2; }
        int c = count[a].load(std::memory_order_acquire);
        Block* const* t = slots[a];
        for (int i = 0; i < c; ++i) if (t[i]) t[i]->render(s, n);
        reading.store(-1, std::memory_order_release);
    }
private:
    Block* slots[2][cap]{};
    std::atomic<int> count[2]{{0}, {0}};
    std::atomic<int> active{0};
    std::atomic<int> reading{-1};   // table the audio thread is iterating, -1 = none
};

enum Global : int {
    GOutputDb = 0, GMuted, GDualOn, GLevelA, GLevelB, GPanA, GPanB,
    GStereoOn, GPingMix, GPingTime, GPingFb, GSpace, GWidth, GLoopLevel
};

class Engine {
public:
    static constexpr int kMaxBlock = 1024;
    static Engine& get();

    // ---- block registry (control thread) ----
    Block* createBlock(int kind);
    void destroyBlock(Block* b);
    bool isLive(Block* b);
    void setChain(int path, const std::vector<Block*>& blocks);

    /// Load a capture into an Amp/Pedal block. Returns {makeupDb, loudness(NaN if absent)}.
    /// Throws std::exception with the NAM error on failure.
    std::array<double, 2> loadModel(Block* b, const std::string& path);
    void clearModel(Block* b);
    void setIR(Block* b, const float* taps, int n);

    void setGlobal(int id, float v);
    void looperCommand(int cmd);   // 0 toggle, 1 stop, 2 clear
    int looperState() const { return looper.current(); }
    bool looperHasLoop() const { return looper.hasLoop(); }

    // ---- audio lifecycle ----
    /// Prepare everything for a sample rate (audio must be stopped).
    void prepare(double sampleRate);
    void setRunning(bool r) { reaper().audioRunning.store(r); if (!r) reaper().collect(); }
    double sampleRate() const { return sr; }

    /// Audio thread: mono input → stereo output. Any n (chunked internally).
    void render(const float* in, float* outL, float* outR, int n);

    // ---- metering / tuner (any thread) ----
    float inPeak() const { return inPk.load(std::memory_order_relaxed); }
    float outPeak() const { return outPk.load(std::memory_order_relaxed); }
    float cpuLoad() const { return cpu.load(std::memory_order_relaxed); }
    bool tuner(float& freq, float& clarity);
    uint64_t xruns = 0;

private:
    Engine();
    void renderChunk(const float* in, float* outL, float* outR, int n);

    std::mutex ctl;
    std::set<Block*> live;
    SignalChain chainA, chainB;
    double sr = 48000;

    // RT state
    std::vector<float> s, bufB, R, mid, midPre, ppL, ppR, rvL, rvR;
    Smoother outSm{dbToGain(-6)}, gAL{0.7f}, gAR{0.7f}, gBL{0.7f}, gBR{0.7f};
    float outputDb = -6; bool muted = false;
    std::atomic<bool> dualOn{false}, stereoOn{false};
    float levelA = 0, levelB = 0, panA = -0.7f, panB = 0.7f;
    PingPongDelay ping; StereoReverb rev; Looper looper;
    std::atomic<float> inPk{0}, outPk{0}, cpu{0};
    static constexpr int kAnalysis = 4096;
    float analysis[kAnalysis]{};
    std::atomic<int> analysisW{0};

    void updateDualMix();
    void updateOutput();
};

}  // namespace hr

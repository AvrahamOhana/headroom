#include "Engine.h"

#include <chrono>
#include <stdexcept>
#include <thread>

#include "dsp/Blocks.h"
#include "dsp/CircuitDrive.h"
#include "dsp/Reverbs.h"

namespace hr {

Reaper& reaper() { static Reaper r; return r; }

// ------------------------------------------------------------------------------------ chain
void SignalChain::set(const std::vector<Block*>& blocks, Reaper&) {
    // The inactive table may still be iterated by a callback that picked it before the last flip:
    // wait only while that is actually happening (microseconds — one render pass).
    int next = 1 - active.load();
    while (reading.load() == next) std::this_thread::yield();
    int n = std::min(int(blocks.size()), cap);
    for (int i = 0; i < n; ++i) slots[next][i] = blocks[size_t(i)];
    count[next].store(n, std::memory_order_release);
    active.store(next);
}

// ------------------------------------------------------------------------------------ engine
Engine& Engine::get() { static Engine e; return e; }

Engine::Engine() {
    for (auto* v : {&s, &bufB, &R, &mid, &midPre, &ppL, &ppR, &rvL, &rvR}) v->assign(kMaxBlock, 0.0f);
    looper.waitCallback = [] { reaper().waitForCallbackBoundary(); };
    prepare(48000);
}

Block* Engine::createBlock(int kind) {
    Block* b = nullptr;
    switch (Kind(kind)) {
        case Kind::Gate: b = new GateBlock(); break;
        case Kind::Comp: b = new CompressorBlock(); break;
        case Kind::Boost: b = new BoostBlock(); break;
        case Kind::Drive: b = new DriveBlock(); break;
        case Kind::Stomp: b = new CircuitDriveBlock(); break;
        case Kind::Wah: b = new WahBlock(); break;
        case Kind::Pedal: b = new AmpBlock(Kind::Pedal); break;
        case Kind::Amp: b = new AmpBlock(Kind::Amp); break;
        case Kind::Cab: b = new CabBlock(); break;
        case Kind::EQ: b = new EQBlock(); break;
        case Kind::Chorus: b = new ChorusBlock(); break;
        case Kind::Flanger: b = new FlangerBlock(); break;
        case Kind::Tremolo: b = new TremoloBlock(); break;
        case Kind::Delay: b = new DelayBlock(); break;
        case Kind::Reverb: b = new ReverbBlock(); break;
        case Kind::IRReverb: b = new ReverbIRBlock(); break;
        default: return nullptr;
    }
    b->prepare(sr, kMaxBlock);
    b->reset();
    std::lock_guard<std::mutex> g(ctl);
    live.insert(b);
    return b;
}

bool Engine::isLive(Block* b) { std::lock_guard<std::mutex> g(ctl); return live.count(b) > 0; }

void Engine::destroyBlock(Block* b) {
    {
        std::lock_guard<std::mutex> g(ctl);
        if (!live.erase(b)) return;
    }
    reaper().retire([b] { delete b; });
}

void Engine::setChain(int path, const std::vector<Block*>& blocks) {
    std::lock_guard<std::mutex> g(ctl);
    std::vector<Block*> ok;
    for (Block* b : blocks) if (live.count(b)) ok.push_back(b);
    (path == 0 ? chainA : chainB).set(ok, reaper());
    reaper().collect();
}

std::array<double, 2> Engine::loadModel(Block* b, const std::string& path) {
    if (!isLive(b) || (b->kind != Kind::Amp && b->kind != Kind::Pedal)) throw std::runtime_error("not a capture block");
    auto* m = new NamModel();
    try { m->load(path); } catch (...) { delete m; throw; }
    double rate = sr;
    m->prepare(rate, kMaxBlock);
    double loud = m->loudness(), makeup;
    if (std::isfinite(loud)) makeup = -18 - loud;
    else {
        // Sine probe (same as iOS): 440 Hz at 0.1 → aim for a 0.4 peak.
        std::vector<float> in(1024), out(1024);
        for (int i = 0; i < 1024; ++i) in[size_t(i)] = 0.1f * std::sin(2 * kPi * 440 * i / float(rate));
        m->process(in.data(), out.data(), 1024);
        float peak = 0; bool nan = false;
        for (float v : out) { if (!std::isfinite(v)) nan = true; else peak = std::max(peak, std::fabs(v)); }
        makeup = nan ? 0 : 20 * std::log10(0.4 / std::max(peak, 1e-4f));
        m->prepare(rate, kMaxBlock);
    }
    makeup = std::max(-24.0, std::min(12.0, makeup));
    std::lock_guard<std::mutex> g(ctl);
    if (!live.count(b)) { delete m; throw std::runtime_error("block was removed"); }
    static_cast<AmpBlock*>(b)->setModel(m);
    return {makeup, loud};
}

void Engine::clearModel(Block* b) {
    std::lock_guard<std::mutex> g(ctl);
    if (live.count(b) && (b->kind == Kind::Amp || b->kind == Kind::Pedal)) static_cast<AmpBlock*>(b)->setModel(nullptr);
}

void Engine::setIR(Block* b, const float* taps, int n) {
    std::lock_guard<std::mutex> g(ctl);
    if (!live.count(b)) return;
    if (b->kind == Kind::Cab) static_cast<CabBlock*>(b)->setIR(taps, n);
    else if (b->kind == Kind::IRReverb) static_cast<ReverbIRBlock*>(b)->setIR(taps, n);
}

void Engine::updateDualMix() {
    float gA = dbToGain(levelA), gB = dbToGain(levelB), l, r;
    equalPowerPan(panA, l, r); gAL.target = gA * l; gAR.target = gA * r;
    equalPowerPan(panB, l, r); gBL.target = gB * l; gBR.target = gB * r;
}
void Engine::updateOutput() { outSm.target = muted ? 0.0f : dbToGain(outputDb); }

void Engine::setGlobal(int id, float v) {
    switch (id) {
        case GOutputDb: outputDb = v; updateOutput(); break;
        case GMuted: muted = v > 0.5f; updateOutput(); break;
        case GDualOn: dualOn.store(v > 0.5f); break;
        case GLevelA: levelA = v; updateDualMix(); break;
        case GLevelB: levelB = v; updateDualMix(); break;
        case GPanA: panA = v; updateDualMix(); break;
        case GPanB: panB = v; updateDualMix(); break;
        case GStereoOn: stereoOn.store(v > 0.5f); break;
        case GPingMix: ping.mixPct = v; break;
        case GPingTime: ping.timeMs = v; break;
        case GPingFb: ping.feedbackPct = v; break;
        case GSpace: rev.mixPct = v; break;
        case GWidth: ping.spreadPct = v; rev.widthPct = v; break;
        case GLoopLevel: looper.loopLevel = v / 100; break;
    }
}

void Engine::looperCommand(int cmd) {
    std::lock_guard<std::mutex> g(ctl);
    if (cmd == 0) looper.toggle(); else if (cmd == 1) looper.stopPlayback();
    else { looper.resetState(); reaper().waitForCallbackBoundary(); looper.clear(); }
}

void Engine::prepare(double rate) {
    std::lock_guard<std::mutex> g(ctl);
    sr = rate;
    for (Block* b : live) { b->prepare(rate, kMaxBlock); b->reset(); }
    for (auto* sm : {&gAL, &gAR, &gBL, &gBR}) { sm->prepare(rate, 10); sm->snap(); }
    outSm.prepare(rate, 10); updateOutput(); outSm.snap(); updateDualMix();
    gAL.snap(); gAR.snap(); gBL.snap(); gBR.snap();
    looper.prepare(rate);
    ping.prepare(rate); rev.prepare(rate); ping.reset(); rev.reset();
    rev.decayPct = 60; rev.dampPct = 35;
    cpu.store(0);
}

void Engine::render(const float* in, float* outL, float* outR, int n) {
    auto t0 = std::chrono::steady_clock::now();
    for (int off = 0; off < n; off += kMaxBlock) {
        int m = std::min(kMaxBlock, n - off);
        renderChunk(in + off, outL + off, outR + off, m);
    }
    double bufNs = n / sr * 1e9;
    if (bufNs > 0) {
        double used = std::chrono::duration<double, std::nano>(std::chrono::steady_clock::now() - t0).count() / bufNs;
        cpu.store(cpu.load(std::memory_order_relaxed) * 0.9f + float(used) * 0.1f, std::memory_order_relaxed);
    }
    reaper().epoch.fetch_add(1, std::memory_order_acq_rel);
}

static inline float clip1(float v) { return !std::isfinite(v) ? 0.0f : (v > 1 ? 1.0f : (v < -1 ? -1.0f : v)); }

void Engine::renderChunk(const float* in, float* outL, float* outR, int n) {
    float* x = s.data();
    float inP = 0; int aw = analysisW.load(std::memory_order_relaxed);
    for (int i = 0; i < n; ++i) {
        float v = finiteOr0(in[i]); x[i] = v;
        analysis[aw] = v; aw = (aw + 1) & (kAnalysis - 1);
        inP = std::max(inP, std::fabs(v));
    }
    analysisW.store(aw, std::memory_order_release);
    inPk.store(inP, std::memory_order_relaxed);

    float* Rb = R.data();
    if (dualOn.load(std::memory_order_relaxed)) {
        float* b = bufB.data(); float* md = mid.data(); float* mp = midPre.data();
        std::memcpy(b, x, n * sizeof(float));
        chainA.render(x, n); chainB.render(b, n);
        for (int i = 0; i < n; ++i) {
            float a = x[i], bb = b[i];
            float l = a * gAL.next() + bb * gBL.next();
            Rb[i] = a * gAR.next() + bb * gBR.next();
            x[i] = l;
        }
        for (int i = 0; i < n; ++i) md[i] = 0.5f * (x[i] + Rb[i]);
        std::memcpy(mp, md, n * sizeof(float));
        looper.process(md, n);
        for (int i = 0; i < n; ++i) { float d = md[i] - mp[i]; x[i] += d; Rb[i] += d; md[i] = 0.5f * (x[i] + Rb[i]); }
        if (stereoOn.load(std::memory_order_relaxed)) {
            ping.processStereo(md, ppL.data(), ppR.data(), n);
            rev.processStereo(md, rvL.data(), rvR.data(), n);
        } else {
            std::fill(ppL.begin(), ppL.begin() + n, 0.0f); std::fill(ppR.begin(), ppR.begin() + n, 0.0f);
            std::fill(rvL.begin(), rvL.begin() + n, 0.0f); std::fill(rvR.begin(), rvR.begin() + n, 0.0f);
        }
    } else {
        chainA.render(x, n);
        looper.process(x, n);
        std::memcpy(Rb, x, n * sizeof(float));
        if (stereoOn.load(std::memory_order_relaxed)) {
            ping.processStereo(x, ppL.data(), ppR.data(), n);
            rev.processStereo(x, rvL.data(), rvR.data(), n);
        } else {
            std::fill(ppL.begin(), ppL.begin() + n, 0.0f); std::fill(ppR.begin(), ppR.begin() + n, 0.0f);
            std::fill(rvL.begin(), rvL.begin() + n, 0.0f); std::fill(rvR.begin(), rvR.begin() + n, 0.0f);
        }
    }
    float outP = 0;
    for (int i = 0; i < n; ++i) {
        float a = std::max(std::fabs(x[i]), std::fabs(Rb[i]));
        if (std::isfinite(a) && a > outP) outP = a;
        float og = outSm.next();
        outL[i] = clip1((x[i] + ppL[size_t(i)] + rvL[size_t(i)]) * og);
        outR[i] = clip1((Rb[i] + ppR[size_t(i)] + rvR[size_t(i)]) * og);
    }
    outPk.store(outP, std::memory_order_relaxed);
}

bool Engine::tuner(float& freq, float& clarity) {
    constexpr int need = Tuner::framesNeeded;
    static thread_local float buf[need];
    int w = analysisW.load(std::memory_order_acquire);
    for (int i = 0; i < need; ++i) buf[i] = analysis[((w - need + i) % kAnalysis + kAnalysis) % kAnalysis];
    if (Tuner::detect(buf, float(sr), freq, clarity) && clarity > 0.5f) return true;
    return false;
}

}  // namespace hr

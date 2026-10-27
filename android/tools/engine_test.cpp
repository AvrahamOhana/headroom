// engine_test.cpp — headless test of the Android C++ engine on the host (macOS/Linux).
// Build + run: android/tools/engine_test.sh
// Checks: every block finite/bounded under stress, cab + IR-reverb match brute-force convolution,
// NAM capture loads + level-matches, full chain (dual + stereo + looper) real-time factor.
#include <chrono>
#include <cstdio>
#include <random>
#include <string>
#include <vector>

#include "../app/src/main/cpp/Engine.h"
#include "../app/src/main/cpp/dsp/Block.h"

using namespace hr;

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { ++failures; std::printf("FAIL: " __VA_ARGS__); std::printf("\n"); } } while (0)

static std::vector<float> guitarish(int n, float sr, unsigned seed = 1) {
    std::mt19937 rng(seed); std::normal_distribution<float> nd(0, 1);
    std::vector<float> x(n);
    float env = 0;
    for (int i = 0; i < n; ++i) {
        if (i % int(sr * 0.5f) == 0) env = 0.5f;          // pluck every 0.5 s
        env *= 0.99995f;
        float t = i / sr;
        x[i] = env * (0.6f * std::sin(2 * kPi * 82.4f * t) + 0.3f * std::sin(2 * kPi * 164.8f * t) + 0.1f * std::sin(2 * kPi * 247.f * t)) + 0.0005f * nd(rng);
    }
    return x;
}

struct Stats { float peak = 0; bool finite = true; };
static Stats stats(const float* x, int n) { Stats s; for (int i = 0; i < n; ++i) { if (!std::isfinite(x[i])) s.finite = false; else s.peak = std::max(s.peak, std::fabs(x[i])); } return s; }

int main(int argc, char** argv) {
    std::string model = argc > 1 ? argv[1] : "";
    const float sr = 48000;
    Engine& E = Engine::get();
    E.prepare(sr);
    E.setRunning(false);

    // ---- 1) each block alone, default + extreme params, odd block sizes ----
    const char* names[] = {"gate","comp","boost","drive","stomp","wah","pedal","amp","cab","eq","chorus","flanger","tremolo","delay","reverb","irReverb"};
    auto in = guitarish(int(sr * 3), sr);
    for (int k = 0; k < int(Kind::Count); ++k) {
        for (int variant = 0; variant < 3; ++variant) {
            Block* b = E.createBlock(k);
            // UI maxima per kind (same ranges as the knobs); kinds not listed take 100 (= 100 %).
            static const std::vector<std::vector<float>> maxes = {
                {-10, 500, -10}, {0, 20, 100, 500, 24}, {18}, {50, 8000, 6, 2}, {4, 1, 1, 1}, {1, 1, 100, 100},
                {24, 12}, {24, 12}, {}, {12, 12, 12}, {8, 15, 100}, {5, 8, 95, 100}, {14, 100},
                {1000, 90, 100, 100}, {3, 100, 100, 100}, {100, 200}};
            if (variant == 1) for (size_t p = 0; p < maxes[size_t(k)].size(); ++p) b->setParam(int(p), maxes[size_t(k)][p]);
            if (variant == 2) for (int p = 0; p < 6; ++p) b->setParam(p, p == 0 ? 3 : 1); // types/modes
            if (k == int(Kind::Cab) || k == int(Kind::IRReverb)) {
                std::vector<float> ir(k == int(Kind::Cab) ? 1500 : 30000);
                std::mt19937 r(3); std::normal_distribution<float> nd(0, 1);
                for (size_t i = 0; i < ir.size(); ++i) ir[i] = nd(r) * std::exp(-float(i) / (ir.size() / 5.0f));
                float e = 0; for (float v : ir) e += v * v; for (float& v : ir) v /= std::sqrt(e);
                E.setIR(b, ir.data(), int(ir.size()));
            }
            std::vector<float> buf = in;
            int pos = 0, sizes[] = {1, 37, 128, 192, 480, 1024, 7};
            for (int it = 0; pos < int(buf.size()); ++it) { int m = std::min(sizes[it % 7], int(buf.size()) - pos); b->render(buf.data() + pos, m); pos += m; }
            Stats st = stats(buf.data(), int(buf.size()));
            CHECK(st.finite, "%s v%d produced NaN/Inf", names[k], variant);
            CHECK(st.peak < 50, "%s v%d peak %.2f", names[k], variant, st.peak);
            std::printf("  %-9s v%d peak %6.3f\n", names[k], variant, st.peak);
            E.destroyBlock(b);
        }
    }

    // ---- 2) cab = brute force convolution ----
    {
        Block* b = E.createBlock(int(Kind::Cab));
        std::vector<float> ir(2048); std::mt19937 r(5); std::uniform_real_distribution<float> u(-1, 1);
        for (auto& v : ir) v = u(r) * 0.05f;
        E.setIR(b, ir.data(), 2048);
        std::vector<float> x(6000); for (auto& v : x) v = u(r);
        std::vector<float> y = x; int pos = 0, sz[] = {100, 1024, 3, 900};
        for (int it = 0; pos < 6000; ++it) { int m = std::min(sz[it % 4], 6000 - pos); b->render(y.data() + pos, m); pos += m; }
        double err = 0;
        for (int i = 0; i < 6000; ++i) { double ref = 0; for (int k = 0; k < 2048 && k <= i; ++k) ref += double(ir[k]) * x[i - k]; err = std::max(err, std::fabs(ref - y[i])); }
        CHECK(err < 1e-4, "cab conv error %g", err);
        std::printf("cab conv max error %.2e\n", err);
        E.destroyBlock(b);
    }
    // ---- 3) IR reverb wet = brute force convolution delayed by B ----
    {
        Block* b = E.createBlock(int(Kind::IRReverb));
        b->setParam(P::IrvMix, 100); b->setParam(P::IrvPredelay, 0);
        int L = 5000; std::vector<float> ir(L); std::mt19937 r(7); std::uniform_real_distribution<float> u(-1, 1);
        for (auto& v : ir) v = u(r) * 0.02f;
        E.setIR(b, ir.data(), L);
        int N = 12000; std::vector<float> x(N); for (auto& v : x) v = u(r);
        std::vector<float> y = x; int pos = 0, sz[] = {256, 77, 1024, 513};
        for (int it = 0; pos < N; ++it) { int m = std::min(sz[it % 4], N - pos); b->render(y.data() + pos, m); pos += m; }
        double err = 0; const int B = 512;
        for (int i = B; i < N; ++i) { double ref = 0; int j = i - B; for (int k = 0; k < L && k <= j; ++k) ref += double(ir[k]) * x[j - k]; err = std::max(err, std::fabs(ref - y[i])); }
        CHECK(err < 1e-3, "ir reverb conv error %g", err);
        std::printf("ir reverb conv max error %.2e\n", err);
        E.destroyBlock(b);
    }

    // ---- 4) NAM capture + full rig, real-time factor ----
    if (!model.empty()) {
        Block* gate = E.createBlock(int(Kind::Gate));
        Block* amp = E.createBlock(int(Kind::Amp));
        Block* cab = E.createBlock(int(Kind::Cab));
        Block* dly = E.createBlock(int(Kind::Delay));
        Block* rvb = E.createBlock(int(Kind::Reverb));
        Block* ampB = E.createBlock(int(Kind::Amp));
        std::array<double, 2> r{};
        try { r = E.loadModel(amp, model); E.loadModel(ampB, model); }
        catch (std::exception& e) { CHECK(false, "model load: %s", e.what()); }
        amp->setParam(P::AmpMakeup, float(r[0])); ampB->setParam(P::AmpMakeup, float(r[0]));
        std::printf("model makeup %+.1f dB, loudness %.1f\n", r[0], r[1]);
        std::vector<float> ir(2048, 0); ir[0] = 1; E.setIR(cab, ir.data(), 2048);
        E.setChain(0, {gate, amp, cab, dly, rvb});
        E.setChain(1, {ampB});
        E.setGlobal(GOutputDb, 0);

        auto x = guitarish(int(sr * 10), sr, 9);
        std::vector<float> L(x.size()), R(x.size());
        for (int pass = 0; pass < 2; ++pass) {
            bool dual = pass == 1;
            E.setGlobal(GDualOn, dual); E.setGlobal(GStereoOn, dual);
            auto t0 = std::chrono::steady_clock::now();
            for (size_t off = 0; off < x.size(); off += 192) {
                int m = int(std::min<size_t>(192, x.size() - off));
                E.render(x.data() + off, L.data() + off, R.data() + off, m);
            }
            double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
            Stats sl = stats(L.data(), int(L.size())), srr = stats(R.data(), int(R.size()));
            CHECK(sl.finite && srr.finite, "full rig NaN");
            CHECK(sl.peak > 0.01f, "full rig silent (peak %.4f)", sl.peak);
            std::printf("full rig %s: peak L %.3f R %.3f, %.1fx real time (host)\n", dual ? "dual+stereo" : "mono", sl.peak, srr.peak, 10.0 / secs);
        }
        // looper: record 1 s, play 1 s → output must contain the loop on top of silence
        E.setGlobal(GDualOn, 0); E.setGlobal(GStereoOn, 0);
        E.setChain(0, {});
        std::vector<float> one(48000), sil(48000, 0.0f), lo(48000), ro(48000);
        for (int i = 0; i < 48000; ++i) one[i] = 0.3f * std::sin(2 * kPi * 220 * i / sr);
        E.looperCommand(0);
        E.render(one.data(), lo.data(), ro.data(), 48000);
        E.looperCommand(0);
        CHECK(E.looperState() == 2, "looper not playing (%d)", E.looperState());
        E.render(sil.data(), lo.data(), ro.data(), 48000);
        Stats ls = stats(lo.data(), 48000);
        CHECK(ls.peak > 0.25f, "looper playback peak %.3f", ls.peak);
        std::printf("looper playback peak %.3f\n", ls.peak);
        // tuner on a clean 110 Hz
        std::vector<float> a2(8192); for (int i = 0; i < 8192; ++i) a2[i] = 0.3f * std::sin(2 * kPi * 110 * i / sr);
        E.render(a2.data(), lo.data(), ro.data(), 8192);
        float f = 0, c = 0; bool ok = E.tuner(f, c);
        CHECK(ok && std::fabs(f - 110) < 0.5f, "tuner %d %.2f", ok, f);
        std::printf("tuner: %.2f Hz clarity %.2f\n", f, c);
    }

    std::printf(failures ? "\n%d FAILURE(S)\n" : "\nALL PASS\n", failures);
    return failures ? 1 : 0;
}

// Headless NAM engine test harness — runs on the Mac (no device, no simulator).
//
// Loads a .nam model, processes 1 s of audio in 512-frame blocks, and reports:
//   - output level (peak / DC / NaN) for a -20 dB sine,
//   - whether it RESPONDS to input (sine vs silence — catches "constant garbage" models),
//   - performance: real-time factor + ms per 512-block.
//
// Build (see tools/run_tests.sh): clang++ -std=gnu++20 -O2 -DNAM_SAMPLE_FLOAT=1 ...

#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <vector>

#include "get_dsp.h"
#include "dsp.h"

static void stats(const std::vector<NAM_SAMPLE>& x, int n, double& peak, double& dc, bool& nan) {
  peak = 0; double sum = 0; nan = false;
  for (int i = 0; i < n; i++) {
    double v = x[i];
    if (!std::isfinite(v)) { nan = true; continue; }
    double a = std::fabs(v); if (a > peak) peak = a;
    sum += v;
  }
  dc = sum / (n > 0 ? n : 1);
}

static double processAll(nam::DSP* m, std::vector<NAM_SAMPLE>& in, std::vector<NAM_SAMPLE>& out,
                         int total, int block) {
  auto t0 = std::chrono::high_resolution_clock::now();
  for (int off = 0; off + block <= total; off += block) {
    NAM_SAMPLE* ic[1] = { &in[off] };
    NAM_SAMPLE* oc[1] = { &out[off] };
    m->process(ic, oc, block);
  }
  auto t1 = std::chrono::high_resolution_clock::now();
  return std::chrono::duration<double>(t1 - t0).count();
}

int main(int argc, char** argv) {
  if (argc < 2) { printf("usage: %s model.nam\n", argv[0]); return 2; }
  const double sr = 48000;
  const int maxBlock = 4096, block = 512, total = 48000; // 1 second
  const int nproc = (total / block) * block;

  std::unique_ptr<nam::DSP> model;
  try { model = nam::get_dsp(std::filesystem::path(argv[1])); }
  catch (const std::exception& e) { printf("LOAD FAILED: %s\n", e.what()); return 1; }
  if (!model) { printf("LOAD FAILED (null)\n"); return 1; }
  model->Reset(sr, maxBlock);

  // 1) -20 dB 440 Hz sine.
  std::vector<NAM_SAMPLE> sine(total), sout(total, 0);
  for (int i = 0; i < total; i++) sine[i] = (NAM_SAMPLE)(0.1 * std::sin(2 * M_PI * 440 * i / sr));
  double elapsed = processAll(model.get(), sine, sout, total, block);
  double speak, sdc; bool snan; stats(sout, nproc, speak, sdc, snan);

  // 2) silence (does the output actually depend on input?).
  std::vector<NAM_SAMPLE> zero(total, 0), zout(total, 0);
  model->Reset(sr, maxBlock);
  processAll(model.get(), zero, zout, total, block);
  double zpeak, zdc; bool znan; stats(zout, nproc, zpeak, zdc, znan);

  double rtf = elapsed / ((double)nproc / sr);
  bool responds = speak > zpeak * 2 + 1e-3;

  printf("%s\n", argv[1]);
  printf("  sine  -20dB : peak %.4f  DC %.4f  NaN %s\n", speak, sdc, snan ? "YES" : "no");
  printf("  silence     : peak %.4f  DC %.4f  -> responds-to-input: %s\n",
         zpeak, zdc, responds ? "YES" : "NO (constant/broken)");
  printf("  perf        : RTF %.4f  (%.1fx real-time)  %.3f ms / 512-block\n",
         rtf, rtf > 0 ? 1.0 / rtf : 0.0, elapsed / (nproc / block) * 1000.0);
  return 0;
}

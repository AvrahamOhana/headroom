// NamModel.h — thin C++ wrapper over NeuralAmpModelerCore (Android counterpart of Engine/NAMModel.mm).
#pragma once

#include <cmath>
#include <memory>
#include <string>
#include <vector>

namespace nam { class DSP; }

namespace hr {

class NamModel {
public:
    NamModel();
    ~NamModel();
    /// Throws std::exception on failure (message is the NAM core's error).
    void load(const std::string& path);
    /// Off the audio thread: sets SR + buffer size and prewarms (expensive).
    void prepare(double sampleRate, int maxBlock);
    /// Audio thread. Passes the input through if not ready or n > maxBlock.
    void process(const float* in, float* out, int n);
    bool loaded() const { return dsp != nullptr; }
    double loudness() const;          // NAN when absent
    double expectedSampleRate() const;
private:
    std::unique_ptr<nam::DSP> dsp;
    std::vector<float> inScratch, outScratch;
    int maxBlock = 0;
};

}  // namespace hr

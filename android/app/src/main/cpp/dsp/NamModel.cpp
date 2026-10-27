#include "NamModel.h"

#include <filesystem>
#include "dsp.h"
#include "get_dsp.h"

namespace hr {

NamModel::NamModel() = default;
NamModel::~NamModel() = default;

void NamModel::load(const std::string& path) {
    dsp = nam::get_dsp(std::filesystem::path(path));
}

void NamModel::prepare(double sampleRate, int mb) {
    if (!dsp) return;
    maxBlock = mb;
    inScratch.assign(size_t(mb), 0.0f);
    outScratch.assign(size_t(mb), 0.0f);
    dsp->Reset(sampleRate, mb);
}

void NamModel::process(const float* in, float* out, int n) {
    if (!dsp || n > maxBlock) {
        if (out != in) for (int i = 0; i < n; ++i) out[i] = in[i];
        return;
    }
    for (int i = 0; i < n; ++i) inScratch[size_t(i)] = in[i];
    NAM_SAMPLE* ic[1] = {inScratch.data()};
    NAM_SAMPLE* oc[1] = {outScratch.data()};
    dsp->process(ic, oc, n);
    for (int i = 0; i < n; ++i) out[i] = outScratch[size_t(i)];
}

double NamModel::loudness() const {
    if (!dsp || !dsp->HasLoudness()) return NAN;
    try { return dsp->GetLoudness(); } catch (...) { return NAN; }
}

double NamModel::expectedSampleRate() const { return dsp ? dsp->GetExpectedSampleRate() : -1.0; }

}  // namespace hr

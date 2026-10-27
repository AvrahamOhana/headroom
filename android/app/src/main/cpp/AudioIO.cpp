#include "AudioIO.h"

#include <android/log.h>
#include "Engine.h"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "HeadroomAudio", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "HeadroomAudio", __VA_ARGS__)

namespace hr {

AudioIO& AudioIO::get() { static AudioIO a; return a; }

std::string AudioIO::start(const AudioConfig& cfg) {
    std::lock_guard<std::mutex> g(m);
    closeLocked();

    oboe::AudioStreamBuilder ob;
    ob.setDirection(oboe::Direction::Output)
      ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
      ->setSharingMode(oboe::SharingMode::Exclusive)
      ->setFormat(oboe::AudioFormat::Float)
      ->setChannelCount(oboe::ChannelCount::Stereo)
      ->setSampleRate(cfg.sampleRate)
      ->setUsage(oboe::Usage::Media)
      ->setContentType(oboe::ContentType::Music)
      ->setSampleRateConversionQuality(oboe::SampleRateConversionQuality::Medium)
      ->setDataCallback(this)
      ->setErrorCallback(this);
    if (cfg.outputDeviceId > 0) ob.setDeviceId(cfg.outputDeviceId);
    oboe::Result r = ob.openStream(out);
    if (r != oboe::Result::OK) return std::string("Could not open audio output: ") + oboe::convertToText(r);

    const int rate = out->getSampleRate();
    auto openInput = [&](oboe::InputPreset preset, int channels) {
        oboe::AudioStreamBuilder ib;
        ib.setDirection(oboe::Direction::Input)
          ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
          ->setSharingMode(oboe::SharingMode::Exclusive)
          ->setFormat(oboe::AudioFormat::Float)
          ->setChannelCount(channels)
          ->setSampleRate(rate)
          ->setInputPreset(preset)
          ->setSampleRateConversionQuality(oboe::SampleRateConversionQuality::Medium)
          ->setBufferCapacityInFrames(out->getBufferCapacityInFrames() * 2);
        if (cfg.inputDeviceId > 0) ib.setDeviceId(cfg.inputDeviceId);
        return ib.openStream(in);
    };
    // Unprocessed = no AGC / noise suppression / echo cancel (what a guitar needs). Some devices
    // reject it → VoiceRecognition (also unprocessed on most). Mono first; some USB interfaces
    // only open stereo → take channel 0 (input 1).
    r = openInput(oboe::InputPreset::Unprocessed, 1);
    if (r != oboe::Result::OK) r = openInput(oboe::InputPreset::VoiceRecognition, 1);
    if (r != oboe::Result::OK) r = openInput(oboe::InputPreset::Unprocessed, 2);
    if (r != oboe::Result::OK) { closeLocked(); return std::string("Could not open audio input: ") + oboe::convertToText(r); }
    inChannels = in->getChannelCount();

    // Ask the OS (ADPF) to boost the CPU for our callback — NAM is heavy and Android otherwise
    // likes to run audio on a little core.
    out->setPerformanceHintEnabled(true);
    const int burst = out->getFramesPerBurst();
    out->setBufferSizeInFrames(std::max(burst, burst * std::max(1, cfg.burstsPerBuffer)));
    const int cap = std::max(out->getBufferCapacityInFrames(), 4096) + burst * 4;
    inBuf.assign(size_t(cap) * size_t(inChannels), 0.0f);
    monoIn.assign(size_t(cap), 0.0f); outL.assign(size_t(cap), 0.0f); outR.assign(size_t(cap), 0.0f);

    Engine& E = Engine::get();
    if (std::abs(E.sampleRate() - rate) > 0.5) E.prepare(rate);
    drainCallbacks = 4;
    inputShort.store(0);

    E.setRunning(true);
    isRunning.store(true);
    r = in->requestStart();
    if (r == oboe::Result::OK) r = out->requestStart();
    if (r != oboe::Result::OK) { closeLocked(); return std::string("Could not start audio: ") + oboe::convertToText(r); }
    LOGI("started: %d Hz, burst %d, buffer %d, in ch %d, out %s/%s", rate, burst, out->getBufferSizeInFrames(), inChannels,
         out->getSharingMode() == oboe::SharingMode::Exclusive ? "excl" : "shared",
         out->getPerformanceMode() == oboe::PerformanceMode::LowLatency ? "lowlat" : "normal");
    return "";
}

void AudioIO::closeLocked() {
    isRunning.store(false);
    if (out) { out->requestStop(); out->close(); out.reset(); }
    if (in) { in->requestStop(); in->close(); in.reset(); }
    Engine::get().setRunning(false);
}

void AudioIO::stop() { std::lock_guard<std::mutex> g(m); closeLocked(); }

AudioStatus AudioIO::status() {
    std::lock_guard<std::mutex> g(m);
    AudioStatus s;
    if (!out || !in) return s;
    s.sampleRate = out->getSampleRate();
    s.framesPerBurst = out->getFramesPerBurst();
    s.bufferFrames = out->getBufferSizeInFrames();
    s.inputChannels = inChannels;
    s.exclusive = out->getSharingMode() == oboe::SharingMode::Exclusive && in->getSharingMode() == oboe::SharingMode::Exclusive;
    s.lowLatency = out->getPerformanceMode() == oboe::PerformanceMode::LowLatency && in->getPerformanceMode() == oboe::PerformanceMode::LowLatency;
    s.mmap = oboe::OboeExtensions::isMMapUsed(out.get());
    auto xr = out->getXRunCount();
    s.underruns = (xr ? xr.value() : 0) + inputShort.load();
    auto lo = out->calculateLatencyMillis(), li = in->calculateLatencyMillis();
    if (lo && li) s.latencyMs = lo.value() + li.value();
    return s;
}

oboe::DataCallbackResult AudioIO::onAudioReady(oboe::AudioStream* stream, void* audioData, int32_t numFrames) {
    float* dst = static_cast<float*>(audioData);
    auto* inS = in.get();
    if (!inS || numFrames <= 0 || size_t(numFrames) > monoIn.size()) {
        std::memset(dst, 0, size_t(numFrames) * 2 * sizeof(float));
        return oboe::DataCallbackResult::Continue;
    }
    if (drainCallbacks > 0) {
        // Flush whatever the input has queued so input and output start aligned (low latency).
        int got;
        do { auto rr = inS->read(inBuf.data(), numFrames, 0); got = rr ? rr.value() : 0; } while (got > 0);
        --drainCallbacks;
        std::memset(dst, 0, size_t(numFrames) * 2 * sizeof(float));
        Engine::get().render(monoIn.data(), outL.data(), outR.data(), 0);   // keep epoch moving
        return oboe::DataCallbackResult::Continue;
    }
    auto rr = inS->read(inBuf.data(), numFrames, 0);
    int got = rr ? rr.value() : 0;
    if (got < numFrames) inputShort.fetch_add(1, std::memory_order_relaxed);
    const int ch = inChannels;
    for (int i = 0; i < got; ++i) monoIn[size_t(i)] = inBuf[size_t(i) * size_t(ch)];
    for (int i = got; i < numFrames; ++i) monoIn[size_t(i)] = 0;
    Engine::get().render(monoIn.data(), outL.data(), outR.data(), numFrames);
    for (int i = 0; i < numFrames; ++i) { dst[2 * i] = outL[size_t(i)]; dst[2 * i + 1] = outR[size_t(i)]; }
    return oboe::DataCallbackResult::Continue;
}

void AudioIO::onErrorAfterClose(oboe::AudioStream*, oboe::Result error) {
    LOGE("stream closed: %s", oboe::convertToText(error));
    isRunning.store(false);
    Engine::get().setRunning(false);
    disconnected.store(true);
}

}  // namespace hr

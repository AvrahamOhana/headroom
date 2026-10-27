// AudioIO.h — Oboe full-duplex I/O: mono float input → Engine::render → stereo float output.
#pragma once

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include <oboe/Oboe.h>

namespace hr {

struct AudioConfig {
    int inputDeviceId = 0;    // 0 = default
    int outputDeviceId = 0;
    int burstsPerBuffer = 2;  // 1 lowest · 2 balanced · 4 safe
    int sampleRate = 48000;
};

struct AudioStatus {
    int sampleRate = 0, framesPerBurst = 0, bufferFrames = 0, inputChannels = 0;
    bool exclusive = false, lowLatency = false, mmap = false;
    int64_t underruns = 0;
    double latencyMs = -1;    // output + input pipeline estimate, when the device reports it
};

class AudioIO : public oboe::AudioStreamDataCallback, public oboe::AudioStreamErrorCallback {
public:
    static AudioIO& get();
    /// Returns "" on success or an error message.
    std::string start(const AudioConfig& cfg);
    void stop();
    bool running() const { return isRunning.load(); }
    /// Set when the device went away (USB unplugged…) — the app should restart the engine.
    bool takeDisconnected() { return disconnected.exchange(false); }
    AudioStatus status();

    oboe::DataCallbackResult onAudioReady(oboe::AudioStream* s, void* audioData, int32_t numFrames) override;
    void onErrorAfterClose(oboe::AudioStream* s, oboe::Result error) override;

private:
    std::mutex m;
    std::shared_ptr<oboe::AudioStream> in, out;
    std::vector<float> inBuf, monoIn, outL, outR;
    std::atomic<bool> isRunning{false}, disconnected{false};
    int drainCallbacks = 0, inChannels = 1;
    std::atomic<int64_t> inputShort{0};
    void closeLocked();
};

}  // namespace hr

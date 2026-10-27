// Reaper.h — deferred deletion for objects the audio thread may still be touching.
// The audio callback bumps `epoch` once per callback. Anything retired at epoch E is freed only
// once the audio thread has completed two more callbacks (or immediately when audio is stopped).
// Control-thread only, except `epoch` (written by the audio thread).
#pragma once

#include <atomic>
#include <functional>
#include <mutex>
#include <thread>
#include <chrono>
#include <vector>

namespace hr {

class Reaper {
public:
    std::atomic<uint64_t> epoch{0};
    std::atomic<bool> audioRunning{false};

    void retire(std::function<void()> deleter) {
        std::lock_guard<std::mutex> g(m);
        pending.push_back({epoch.load(std::memory_order_acquire), std::move(deleter)});
        collectLocked();
    }
    void collect() { std::lock_guard<std::mutex> g(m); collectLocked(); }

    /// Block until the audio thread has finished any callback that started before this call.
    void waitForCallbackBoundary() {
        if (!audioRunning.load()) return;
        // Time-bounded: never stall the caller more than ~60 ms even if callbacks stop flowing.
        uint64_t e0 = epoch.load(std::memory_order_acquire);
        auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(60);
        while (audioRunning.load() && epoch.load(std::memory_order_acquire) < e0 + 2 && std::chrono::steady_clock::now() < until)
            std::this_thread::sleep_for(std::chrono::microseconds(500));
    }

private:
    struct Item { uint64_t at; std::function<void()> del; };
    std::mutex m;
    std::vector<Item> pending;

    void collectLocked() {
        uint64_t now = epoch.load(std::memory_order_acquire);
        bool running = audioRunning.load();
        std::vector<Item> keep;
        for (auto& it : pending) {
            if (!running || now >= it.at + 2) it.del();
            else keep.push_back(std::move(it));
        }
        pending.swap(keep);
    }
};

/// Engine-wide instance (defined in Engine.cpp).
Reaper& reaper();

}  // namespace hr

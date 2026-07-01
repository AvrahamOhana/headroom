//
//  LooperEngine.swift
//  NamRig — a real-time phrase looper that sits at the END of the chain (records / plays the
//  final processed tone). One-button cycle like a Ditto: idle → record → play → overdub → play…
//
//  RT-safety (same discipline as Blocks.swift): the loop buffer is pre-allocated in `prepare`;
//  `process` does zero allocation / locks. The state is an `Atomic<Int>`; `loopLevel` is a plain
//  var (benign race). All state TRANSITIONS happen on the main thread (toggle/stop/clear); the
//  audio thread only reads the state and the buffer. `nonisolated` so it compiles under the
//  project's `-default-isolation=MainActor`.
//

import Foundation
import Synchronization

nonisolated final class LooperEngine: @unchecked Sendable {
    enum State: Int { case idle, recording, playing, overdubbing, stopped }

    private let state = Atomic<Int>(0)        // State.rawValue (audio thread reads, main writes)
    var loopLevel: Float = 1.0                // playback level (benign race)

    private var buf: UnsafeMutableBufferPointer<Float>?
    private var cap = 0
    private var sr: Float = 48000
    private var recPos = 0                     // write head while recording
    private var loopLen = 0                    // fixed once recording stops
    private var playPos = 0                    // playback head
    private let xfade = 256                    // seam crossfade (samples) to kill the wrap click

    func prepare(sampleRate: Double, maxBlock: Int) {
        sr = Float(sampleRate)
        let need = Int(sampleRate * 120) + 16  // up to 120 s
        if buf == nil || cap != need {
            buf?.deallocate()
            let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: need); b.initialize(repeating: 0)
            buf = b; cap = need
        }
        reset()
    }

    func reset() {
        state.store(State.idle.rawValue, ordering: .releasing)
        recPos = 0; loopLen = 0; playPos = 0
    }

    func clear() {
        if let p = buf?.baseAddress { for i in 0..<cap { p[i] = 0 } }
        reset()
    }

    /// The classic single-button cycle (main thread).
    func toggle() {
        switch State(rawValue: state.load(ordering: .relaxed)) ?? .idle {
        case .idle:
            recPos = 0; playPos = 0; loopLen = 0
            state.store(State.recording.rawValue, ordering: .releasing)
        case .recording:
            loopLen = max(recPos, 1)
            // Crossfade the seam so the loop wrap doesn't click. Recording has stopped (we flip the
            // state below), so this one-shot main-thread edit can't race the audio thread.
            if loopLen > xfade * 2, let b = buf?.baseAddress {
                for i in 0..<xfade {
                    let a = Float(i) / Float(xfade)
                    b[loopLen - xfade + i] = b[loopLen - xfade + i] * (1 - a) + b[i] * a
                }
            }
            playPos = 0
            state.store(State.playing.rawValue, ordering: .releasing)
        case .playing:
            state.store(State.overdubbing.rawValue, ordering: .releasing)
        case .overdubbing:
            state.store(State.playing.rawValue, ordering: .releasing)
        case .stopped:
            playPos = 0
            state.store(State.playing.rawValue, ordering: .releasing)
        }
    }

    /// Stop playback (keeps the loop so it can be resumed).
    func stopPlayback() {
        let s = State(rawValue: state.load(ordering: .relaxed)) ?? .idle
        if s == .playing || s == .overdubbing { state.store(State.stopped.rawValue, ordering: .releasing) }
    }

    var current: State { State(rawValue: state.load(ordering: .relaxed)) ?? .idle }
    var hasLoop: Bool { loopLen > 0 }
    var stateName: String {
        switch current {
        case .idle: return "Idle"; case .recording: return "REC"; case .playing: return "Play"
        case .overdubbing: return "Overdub"; case .stopped: return "Stopped"
        }
    }

    func process(_ s: UnsafeMutablePointer<Float>, _ n: Int) {
        guard let b = buf?.baseAddress, cap > 1 else { return }
        switch State(rawValue: state.load(ordering: .acquiring)) ?? .idle {
        case .idle, .stopped:
            return                                  // pass dry
        case .recording:
            var w = recPos
            for i in 0..<n { if w >= cap { break }; b[w] = s[i]; w += 1 }
            recPos = w                              // dry passes through (monitor while recording)
        case .playing, .overdubbing:
            guard loopLen > 1 else { return }
            let lvl = loopLevel, od = (state.load(ordering: .relaxed) == State.overdubbing.rawValue)
            var p = playPos
            for i in 0..<n {
                let loopSample = b[p]
                if od {
                    var v = b[p] + s[i]             // sum new input into the loop
                    if v > 0.99 { v = 0.99 } else if v < -0.99 { v = -0.99 }
                    b[p] = v
                }
                s[i] += loopSample * lvl            // mix playback over the live signal
                p += 1; if p >= loopLen { p = 0 }
            }
            playPos = p
        }
    }

    deinit { buf?.deallocate() }
}

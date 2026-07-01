//
//  Tempo.swift
//  NamRig — tap-tempo clock + musical note divisions for tempo-synced delay / modulation.
//
//  `TempoClock` is a pure VALUE TYPE. It holds a BPM and a short ring of recent tap
//  timestamps; from those it derives a delay time (ms) or a modulation rate (Hz) for any
//  musical division. It owns NO timing source of its own: the caller (the MAIN thread)
//  passes `CACurrentMediaTime()` into `tap(at:)`. The file deliberately never references
//  Date() / CACurrentMediaTime() so the math stays testable headlessly and the type stays a
//  plain, copyable value.
//
//  Threading: TempoClock lives on the @MainActor AudioEngine and is mutated only on the main
//  thread (tap / bpm / division edits). The audio thread NEVER sees this type — the main
//  thread pushes the derived scalars (delaySamples, rateHz, …) into the RT blocks, exactly
//  like every other parameter. Hence it is `nonisolated` (so it compiles under the project's
//  `-default-isolation=MainActor`) but needs no atomics.
//

import Foundation

/// A tap-tempo clock. Value type — copy it freely; mutate via `tap` / `bpm`.
nonisolated struct TempoClock: Sendable {

    // MARK: BPM (clamped)

    static let minBPM: Double = 40
    static let maxBPM: Double = 300

    private var _bpm: Double = 120

    /// Beats-per-minute, always clamped to `minBPM…maxBPM`. Default 120.
    var bpm: Double {
        get { _bpm }
        set { _bpm = min(max(newValue, Self.minBPM), Self.maxBPM) }
    }

    /// Length of one quarter-note beat, in milliseconds.
    var beatMs: Double { 60_000.0 / _bpm }

    /// BPM rounded for display.
    var bpmRounded: Int { Int(_bpm.rounded()) }

    init(bpm: Double = 120) { self.bpm = bpm }   // routes through the clamping setter

    // MARK: Note divisions

    /// Musical subdivisions of a quarter-note beat (the usual delay-pedal set).
    /// `beatMultiplier` is expressed in quarter-note beats (quarter = 1).
    nonisolated enum NoteDivision: CaseIterable, Identifiable, Codable, Hashable, Sendable {
        case quarter            // 1/4
        case dottedEighth       // 1/8 dotted  (the "the edge" U2 slap)
        case eighth             // 1/8
        case eighthTriplet      // 1/8 triplet
        case sixteenth          // 1/16

        var id: Self { self }

        /// Short label for a Picker / readout.
        var displayName: String {
            switch self {
            case .quarter:       return "1/4"
            case .dottedEighth:  return "1/8."
            case .eighth:        return "1/8"
            case .eighthTriplet: return "1/8T"
            case .sixteenth:     return "1/16"
            }
        }

        /// Multiplier on the quarter-note beat. Delay time = beatMs × beatMultiplier.
        var beatMultiplier: Double {
            switch self {
            case .quarter:       return 1.0
            case .dottedEighth:  return 0.75        // dotted = 1.5 × an eighth = 0.75 of a beat
            case .eighth:        return 0.5
            case .eighthTriplet: return 1.0 / 3.0
            case .sixteenth:     return 0.25
            }
        }
    }

    /// Delay time for a division, in milliseconds (feeds `delayTimeMs` / `delay.delaySamples`).
    func ms(_ d: NoteDivision) -> Double {
        beatMs * d.beatMultiplier
    }

    /// Modulation rate for a division, in Hz — one LFO cycle per division
    /// (feeds `chorus/flanger/tremolo.rateHz`). Reciprocal of the period.
    func hz(_ d: NoteDivision) -> Float {
        let periodMs = ms(d)
        guard periodMs > 0 else { return 0 }
        return Float(1000.0 / periodMs)
    }

    // MARK: Tap tempo

    /// How many recent tap timestamps to keep (≈4 → up to 3 intervals to average).
    private static let maxTaps = 4
    /// A gap longer than this (s) means the user started a NEW count — drop the history.
    /// 2.0 s ≈ 30 BPM, below the 40 BPM floor, so it can never be a real beat.
    private static let resetGap: Double = 2.0

    /// Monotonic timestamps of the most recent taps (seconds, from the caller's clock).
    private var taps: [Double] = []

    /// Register a tap at monotonic time `t` (the caller passes `CACurrentMediaTime()`).
    /// Keeps the last few taps, takes their intervals, rejects any interval longer than
    /// 2× the median (a stray/long tap), averages the rest, and updates `bpm`.
    /// A single tap (or one after a long gap) only seeds the count; bpm is unchanged.
    mutating func tap(at t: Double) {
        // Long silence ⇒ a fresh count.
        if let last = taps.last, t - last > Self.resetGap {
            taps.removeAll(keepingCapacity: true)
        }
        // Ignore a non-increasing timestamp (double event / clock hiccup).
        if let last = taps.last, t <= last { return }

        taps.append(t)
        if taps.count > Self.maxTaps { taps.removeFirst(taps.count - Self.maxTaps) }
        guard taps.count >= 2 else { return }        // need at least one interval

        // Consecutive intervals.
        var intervals: [Double] = []
        intervals.reserveCapacity(taps.count - 1)
        for i in 1..<taps.count { intervals.append(taps[i] - taps[i - 1]) }

        // Reject outliers: anything longer than 2× the median interval.
        let med = Self.median(of: intervals)
        var kept = intervals.filter { $0 <= 2 * med }
        if kept.isEmpty { kept = intervals }         // never average nothing

        let avg = kept.reduce(0, +) / Double(kept.count)
        guard avg > 0 else { return }
        bpm = 60.0 / avg                             // setter clamps to 40…300
    }

    /// Forget the tap history (e.g. when the user releases a held tap pad). Keeps `bpm`.
    mutating func clearTaps() { taps.removeAll(keepingCapacity: true) }

    /// Median of a non-empty list (even count → mean of the two middle values).
    private static func median(of xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        return n.isMultiple(of: 2) ? (s[n / 2 - 1] + s[n / 2]) / 2 : s[n / 2]
    }
}

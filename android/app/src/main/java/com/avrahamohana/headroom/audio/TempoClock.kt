package com.avrahamohana.headroom.audio

import com.avrahamohana.headroom.model.NoteDivision

/** Tap-tempo clock (port of Tempo.swift). Timestamps in seconds from a monotonic clock. */
class TempoClock(bpm: Double = 120.0) {
    var bpm: Double = bpm.coerceIn(MIN, MAX)
        set(v) { field = v.coerceIn(MIN, MAX) }
    private val taps = ArrayDeque<Double>()

    fun ms(d: NoteDivision) = 60_000.0 / bpm * d.beats

    fun tap(t: Double) {
        taps.lastOrNull()?.let { if (t - it > 2.0) taps.clear(); if (t <= it && taps.isNotEmpty()) return }
        taps.addLast(t)
        while (taps.size > 4) taps.removeFirst()
        if (taps.size < 2) return
        val intervals = (1 until taps.size).map { taps[it] - taps[it - 1] }
        val s = intervals.sorted()
        val med = if (s.size % 2 == 0) (s[s.size / 2 - 1] + s[s.size / 2]) / 2 else s[s.size / 2]
        val kept = intervals.filter { it <= 2 * med }.ifEmpty { intervals }
        val avg = kept.average()
        if (avg > 0) bpm = 60.0 / avg
    }

    companion object { const val MIN = 40.0; const val MAX = 300.0 }
}

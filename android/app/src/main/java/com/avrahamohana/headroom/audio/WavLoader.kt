package com.avrahamohana.headroom.audio

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.sqrt

/** Minimal RIFF/WAVE reader for impulse responses: PCM 8/16/24/32-bit and IEEE float 32/64, any channel count. */
object WavLoader {
    class Wav(val samples: FloatArray, val sampleRate: Int)

    fun read(file: File): Wav? = runCatching { parse(file.readBytes()) }.getOrNull()

    fun parse(bytes: ByteArray): Wav? {
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        if (bytes.size < 12 || String(bytes, 0, 4) != "RIFF" || String(bytes, 8, 4) != "WAVE") return null
        var pos = 12
        var fmt = 0; var ch = 0; var sr = 0; var bits = 0
        var dataOff = -1; var dataLen = 0
        while (pos + 8 <= bytes.size) {
            val id = String(bytes, pos, 4); val len = bb.getInt(pos + 4)
            val body = pos + 8
            if (id == "fmt ") {
                fmt = bb.getShort(body).toInt() and 0xFFFF
                ch = bb.getShort(body + 2).toInt()
                sr = bb.getInt(body + 4)
                bits = bb.getShort(body + 14).toInt()
                if (fmt == 0xFFFE && len >= 26) fmt = bb.getShort(body + 24).toInt() and 0xFFFF   // extensible → subformat
            } else if (id == "data") {
                dataOff = body; dataLen = minOf(len.toLong() and 0xFFFFFFFFL, (bytes.size - body).toLong()).toInt(); break
            }
            pos = body + len + (len and 1)
        }
        if (dataOff < 0 || ch <= 0 || sr <= 0) return null
        val bpsm = bits / 8
        val frames = dataLen / (bpsm * ch)
        val out = FloatArray(frames)
        for (i in 0 until frames) {
            val o = dataOff + i * bpsm * ch   // channel 0
            out[i] = when {
                fmt == 3 && bits == 32 -> bb.getFloat(o)
                fmt == 3 && bits == 64 -> bb.getDouble(o).toFloat()
                bits == 16 -> bb.getShort(o) / 32768f
                bits == 24 -> ((bytes[o].toInt() and 0xFF) or ((bytes[o + 1].toInt() and 0xFF) shl 8) or (bytes[o + 2].toInt() shl 16)) / 8388608f
                bits == 32 -> bb.getInt(o) / 2147483648f
                bits == 8 -> ((bytes[o].toInt() and 0xFF) - 128) / 128f
                else -> 0f
            }
        }
        return Wav(out, sr)
    }

    /** Linear resample to the engine rate (as on iOS). */
    fun resample(x: FloatArray, srcSR: Int, dstSR: Int): FloatArray {
        if (abs(srcSR - dstSR) <= 1 || x.isEmpty()) return x
        val ratio = dstSR.toDouble() / srcSR
        val n = maxOf(1, (x.size * ratio).toInt())
        return FloatArray(n) { i ->
            val p = i / ratio; val i0 = p.toInt(); val fr = (p - i0).toFloat()
            val a = x[minOf(i0, x.size - 1)]; val b = x[minOf(i0 + 1, x.size - 1)]
            a + (b - a) * fr
        }
    }

    /** Cab IR: ≤2048 taps, L1-normalized. */
    fun cabIR(file: File, sr: Int): FloatArray? {
        val w = read(file) ?: return null
        var x = resample(w.samples, w.sampleRate, sr)
        if (x.size > 2048) x = x.copyOf(2048)
        val l1 = x.sumOf { abs(it).toDouble() }.toFloat()
        if (l1 > 1e-6f) for (i in x.indices) x[i] /= l1
        return x.takeIf { it.isNotEmpty() }
    }

    /** Reverb IR: ≤64000 taps, energy-normalized. */
    fun reverbIR(file: File, sr: Int): FloatArray? {
        val w = read(file) ?: return null
        var x = resample(w.samples, w.sampleRate, sr)
        if (x.size > 64000) x = x.copyOf(64000)
        val e = sqrt(x.sumOf { (it * it).toDouble() }).toFloat()
        if (e > 1e-9f) for (i in x.indices) x[i] /= e
        return x.takeIf { it.isNotEmpty() }
    }
}

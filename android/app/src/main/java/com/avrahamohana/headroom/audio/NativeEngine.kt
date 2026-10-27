package com.avrahamohana.headroom.audio

import java.io.IOException

/** JNI surface of libheadroom (cpp/jni.cpp). All block handles are opaque native pointers. */
object NativeEngine {
    init { System.loadLibrary("headroom") }

    // Global ids — keep in sync with cpp/Engine.h `Global`.
    const val G_OUTPUT_DB = 0; const val G_MUTED = 1; const val G_DUAL_ON = 2
    const val G_LEVEL_A = 3; const val G_LEVEL_B = 4; const val G_PAN_A = 5; const val G_PAN_B = 6
    const val G_STEREO_ON = 7; const val G_PING_MIX = 8; const val G_PING_TIME = 9; const val G_PING_FB = 10
    const val G_SPACE = 11; const val G_WIDTH = 12; const val G_LOOP_LEVEL = 13

    /** Native param ids shared by Amp + Pedal (cpp/dsp/Block.h). */
    const val P_AMP_DRIVE = 0; const val P_AMP_MAKEUP = 1; const val P_DLY_SNAP = 4

    /** Returns null on success, else an error message. */
    external fun nativeStart(inputDeviceId: Int, outputDeviceId: Int, burstsPerBuffer: Int, sampleRate: Int): String?
    external fun nativeStop()
    external fun nativeIsRunning(): Boolean
    external fun nativeTakeDisconnected(): Boolean

    external fun nativeCreateBlock(kind: Int): Long
    external fun nativeDestroyBlock(handle: Long)
    external fun nativeSetChain(path: Int, handles: LongArray)
    external fun nativeSetBypass(handle: Long, bypass: Boolean)
    external fun nativeSetParam(handle: Long, id: Int, value: Float)
    external fun nativeGetMeter(handle: Long): Float
    /** [makeupDb, loudness (NaN if absent)] */
    @Throws(IOException::class) external fun nativeLoadModel(handle: Long, path: String): DoubleArray
    external fun nativeClearModel(handle: Long)
    external fun nativeSetIR(handle: Long, taps: FloatArray?)
    external fun nativeSetGlobal(id: Int, value: Float)
    external fun nativeLooper(cmd: Int)          // 0 toggle · 1 stop · 2 clear
    external fun nativeLooperState(): Int        // 0 idle · 1 rec · 2 play · 3 dub · 4 stopped
    external fun nativeLooperHasLoop(): Boolean
    /** inPeak, outPeak, cpu, sr, burst, bufferFrames, underruns, latencyMs, exclusive, lowLatency, mmap, inChannels */
    external fun nativeStats(out: FloatArray)
    external fun nativeTuner(out: FloatArray): Boolean
}

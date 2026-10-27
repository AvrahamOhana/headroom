// jni.cpp — JNI surface for com.avrahamohana.headroom.audio.NativeEngine.
#include <jni.h>
#include <string>
#include <vector>

#include "AudioIO.h"
#include "Engine.h"

using namespace hr;

static Block* B(jlong h) { return reinterpret_cast<Block*>(h); }

#define FN(name) Java_com_avrahamohana_headroom_audio_NativeEngine_##name

extern "C" {

JNIEXPORT jstring JNICALL FN(nativeStart)(JNIEnv* env, jobject, jint inDev, jint outDev, jint bursts, jint rate) {
    AudioConfig c; c.inputDeviceId = inDev; c.outputDeviceId = outDev; c.burstsPerBuffer = bursts; c.sampleRate = rate;
    std::string err = AudioIO::get().start(c);
    return err.empty() ? nullptr : env->NewStringUTF(err.c_str());
}
JNIEXPORT void JNICALL FN(nativeStop)(JNIEnv*, jobject) { AudioIO::get().stop(); }
JNIEXPORT jboolean JNICALL FN(nativeIsRunning)(JNIEnv*, jobject) { return AudioIO::get().running(); }
JNIEXPORT jboolean JNICALL FN(nativeTakeDisconnected)(JNIEnv*, jobject) { return AudioIO::get().takeDisconnected(); }

JNIEXPORT jlong JNICALL FN(nativeCreateBlock)(JNIEnv*, jobject, jint kind) { return reinterpret_cast<jlong>(Engine::get().createBlock(kind)); }
JNIEXPORT void JNICALL FN(nativeDestroyBlock)(JNIEnv*, jobject, jlong h) { Engine::get().destroyBlock(B(h)); }
JNIEXPORT void JNICALL FN(nativeSetChain)(JNIEnv* env, jobject, jint path, jlongArray arr) {
    jsize n = env->GetArrayLength(arr);
    std::vector<jlong> tmp(static_cast<size_t>(n));
    if (n) env->GetLongArrayRegion(arr, 0, n, tmp.data());
    std::vector<Block*> blocks; for (jlong h : tmp) blocks.push_back(B(h));
    Engine::get().setChain(path, blocks);
}
JNIEXPORT void JNICALL FN(nativeSetBypass)(JNIEnv*, jobject, jlong h, jboolean bypass) {
    if (Engine::get().isLive(B(h))) B(h)->bypass.store(bypass);
}
JNIEXPORT void JNICALL FN(nativeSetParam)(JNIEnv*, jobject, jlong h, jint id, jfloat v) {
    if (Engine::get().isLive(B(h))) B(h)->setParam(id, v);
}
JNIEXPORT jfloat JNICALL FN(nativeGetMeter)(JNIEnv*, jobject, jlong h) {
    return Engine::get().isLive(B(h)) ? B(h)->meter() : 0.0f;
}
/// Returns [makeupDb, loudness]; throws java.io.IOException on failure.
JNIEXPORT jdoubleArray JNICALL FN(nativeLoadModel)(JNIEnv* env, jobject, jlong h, jstring jpath) {
    const char* p = env->GetStringUTFChars(jpath, nullptr);
    std::string path(p); env->ReleaseStringUTFChars(jpath, p);
    try {
        auto r = Engine::get().loadModel(B(h), path);
        jdoubleArray out = env->NewDoubleArray(2);
        env->SetDoubleArrayRegion(out, 0, 2, r.data());
        return out;
    } catch (const std::exception& e) {
        env->ThrowNew(env->FindClass("java/io/IOException"), e.what());
    } catch (...) {
        env->ThrowNew(env->FindClass("java/io/IOException"), "unknown NAM load error");
    }
    return nullptr;
}
JNIEXPORT void JNICALL FN(nativeClearModel)(JNIEnv*, jobject, jlong h) { Engine::get().clearModel(B(h)); }
JNIEXPORT void JNICALL FN(nativeSetIR)(JNIEnv* env, jobject, jlong h, jfloatArray taps) {
    if (!taps) { Engine::get().setIR(B(h), nullptr, 0); return; }
    jsize n = env->GetArrayLength(taps);
    std::vector<float> v(static_cast<size_t>(n));
    if (n) env->GetFloatArrayRegion(taps, 0, n, v.data());
    Engine::get().setIR(B(h), v.data(), n);
}
JNIEXPORT void JNICALL FN(nativeSetGlobal)(JNIEnv*, jobject, jint id, jfloat v) { Engine::get().setGlobal(id, v); }
JNIEXPORT void JNICALL FN(nativeLooper)(JNIEnv*, jobject, jint cmd) { Engine::get().looperCommand(cmd); }
JNIEXPORT jint JNICALL FN(nativeLooperState)(JNIEnv*, jobject) { return Engine::get().looperState(); }
JNIEXPORT jboolean JNICALL FN(nativeLooperHasLoop)(JNIEnv*, jobject) { return Engine::get().looperHasLoop(); }

/// out[0..] = inPeak, outPeak, cpu, sampleRate, burst, bufferFrames, underruns, latencyMs, exclusive, lowLatency, mmap, inChannels
JNIEXPORT void JNICALL FN(nativeStats)(JNIEnv* env, jobject, jfloatArray out) {
    Engine& E = Engine::get();
    AudioStatus s = AudioIO::get().status();
    float v[12] = {E.inPeak(), E.outPeak(), E.cpuLoad(), float(s.sampleRate), float(s.framesPerBurst), float(s.bufferFrames),
                   float(s.underruns), float(s.latencyMs), s.exclusive ? 1.f : 0.f, s.lowLatency ? 1.f : 0.f, s.mmap ? 1.f : 0.f, float(s.inputChannels)};
    env->SetFloatArrayRegion(out, 0, std::min<jsize>(12, env->GetArrayLength(out)), v);
}
/// Returns true + [freq, clarity] when a confident pitch is present.
JNIEXPORT jboolean JNICALL FN(nativeTuner)(JNIEnv* env, jobject, jfloatArray out) {
    float f = 0, c = 0;
    bool ok = Engine::get().tuner(f, c);
    float v[2] = {f, c};
    env->SetFloatArrayRegion(out, 0, 2, v);
    return ok;
}

}  // extern "C"

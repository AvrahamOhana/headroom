# Headroom for Android

Native Android port of Headroom: the same DSP, rig model and presets as the iOS/macOS app.

## Architecture

| Layer | Where | Notes |
|---|---|---|
| DSP engine (C++20) | `app/src/main/cpp/dsp/`, `Engine.*` | Line-for-line port of the Swift blocks: gate, comp, boost, drive (2×/8× OS + ADAA), circuit stompboxes, wah, NAM amp/pedal, cab IR, EQ, chorus, flanger, tremolo, tape delay, plate/spring/FDN reverbs, IR reverb, ping-pong + stereo reverb, looper, YIN tuner. Dual A ∥ B paths. |
| NAM core | `../ThirdParty/NeuralAmpModelerCore` | Compiled straight from the submodule, always `-O3`. |
| Audio I/O | `AudioIO.cpp` | Oboe 1.9.3 full duplex: mono float input (Unprocessed preset, no AGC) → engine → stereo float output, exclusive + low-latency, ADPF performance hint. |
| JNI | `jni.cpp` ↔ `audio/NativeEngine.kt` | Blocks are opaque handles; params are pushed in UI units. |
| App (Kotlin, Compose) | `java/com/avrahamohana/headroom/` | `engine/RigEngine` (rig state, presets, models, device routing), `ui/` (chain strip with drag & drop, knob editors, OUT/LOOP panels, sheets, Live view), `midi/` (android.media.midi: USB + BLE), `t3k/` (TONE3000 OAuth PKCE + browser). |

RT safety: chains are double-buffered slot tables with a hazard-pointer handshake; removed blocks,
replaced NAM models and IRs are freed by an epoch reaper only after the audio thread has moved on.

Presets use the same JSON keys as iOS (`presets.json`), so files move between platforms.

## Build

Requires JDK 17, Android SDK 35, NDK 28.2.13676358, CMake 3.22.1 (Android Studio installs these).

```
git submodule update --init --recursive
cd android
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Tests

- `tools/engine_test.sh` — builds the C++ engine + real NAM core on the host and checks every block
  (finite/bounded at UI extremes), cab and IR reverb against brute-force convolution, model
  level-matching, dual/stereo render, looper and tuner. Prints `ALL PASS`.
- The same test cross-compiles for a phone (arm64) with the NDK clang and runs over `adb shell`
  for an on-device real-time factor (Pixel 8: full mono rig ≈14× real time, dual+stereo ≈7.7×).

## Using it

Plug a class-compliant USB-C audio interface (iRig, Focusrite, …) — it is picked automatically, and
hot-plugging restarts audio on it. Without one the phone mic is used: wear headphones. Settings
shows the actual sample rate, buffer, latency path (low-latency / exclusive / MMAP) and glitch count.

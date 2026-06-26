# iOS Setup & Integration Recipe

_How we get from an empty Mac to "guitar playing through a NAM capture on the iPhone."
Milestones M0–M2. Written 2026-06-25 against NeuralAmpModelerCore (vendored in `ThirdParty/`)._

---

## Prerequisites
- **Full Xcode** (Mac App Store). Command Line Tools alone can't build iOS apps.
- After install:
  ```
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept
  xcodebuild -version
  ```
- A **free Apple ID** is enough to run on your own device (no $99 needed until we ship).

## Hardware: connect & prove it (do this while Xcode downloads)
- **iPhone 15 = USB-C.** Plug the **iRig USB** straight in (USB-A end → any USB-A→USB-C adapter).
  Guitar → iRig instrument input. It's **class-compliant** → no drivers, iOS just sees it.
- **Free proof the whole signal path works:** install **GarageBand**, make a guitar/amp track,
  and watch the input meter move as you play. If GarageBand hears the guitar, M1 is de-risked
  before we write any audio code.
- If iOS ever says *"accessory requires too much power,"* use a powered USB-C hub (rare for an iRig).

---

## M0 — Create the app & run it on your iPhone
1. **Xcode → File → New → Project → iOS → App.** Product Name e.g. `NamRig`, Interface **SwiftUI**,
   Language **Swift**. Save it **inside this repo** so it's in git.
2. **Signing:** select the project → the app target → **Signing & Capabilities** →
   check **Automatically manage signing** → **Team:** *Add an Account…* (your free Apple ID) →
   pick the resulting **(Personal Team)**. Set a unique **Bundle Identifier** (e.g. `com.yourname.namrig`).
3. **Run on device:** plug in the iPhone (USB-C), **Trust** the computer, pick it as the run
   destination, press **⌘R**. First launch: on the phone, **Settings → General → VPN & Device
   Management → Trust** your developer cert. (Free certs expire after **7 days** — just re-run to renew.)

**Done when:** a blank SwiftUI app launches on your phone.

---

## M1 — Audio passthrough (we'll write this live)
- **Info.plist:** add **`NSMicrophoneUsageDescription`** (guitar input arrives as "microphone" input) —
  e.g. "NamRig uses your audio interface to process your guitar."
- **AVAudioSession:** category **`.playAndRecord`**, mode **`.measurement`** (strips system input
  processing), `setPreferredSampleRate(48000)`, `setPreferredIOBufferDuration(...)` — start ~256 frames
  (≈5.3 ms) then push to 128 / 64 once stable.
- **AVAudioEngine:** route `inputNode → mainMixerNode → output` for a raw passthrough first, then
  measure and record round-trip latency on the iRig. (We'll likely move to a manual render block /
  `AUAudioUnit` for the DSP chain in M2.)

**Done when:** clean guitar passes through at a small buffer; latency noted.

---

## M2 — Wire in the NAM engine (the "first tone" milestone)
The bridge is already written: **`Sources/DSP/NAMModel.h` + `.mm`** (a tiny Obj-C wrapper over
`nam::DSP`). Steps to make it build and play:

### 1. Add source files to the app target
In Xcode, **Add Files to "NamRig"…** (use *Create groups*, **reference in place — don't copy**):
- Everything in `ThirdParty/NeuralAmpModelerCore/NAM/` **and** `…/NAM/wavenet/` (the `.cpp`/`.h`).
- `Sources/DSP/NAMModel.h` and `Sources/DSP/NAMModel.mm`.

> The model engine is ~13 `.cpp` files (incl. `wavenet/a2_fast.cpp` for the A2 fast path). It needs
> only **Eigen** (header-only) and **nlohmann/json** (single header) — both already vendored. No CMake.

### 2. Build Settings (app target)
- **C++ Language Dialect** → `GNU++20` (C++20).
- **Header Search Paths** (non-recursive), add all four:
  - `$(SRCROOT)/ThirdParty/NeuralAmpModelerCore`
  - `$(SRCROOT)/ThirdParty/NeuralAmpModelerCore/NAM`
  - `$(SRCROOT)/ThirdParty/NeuralAmpModelerCore/Dependencies/eigen`
  - `$(SRCROOT)/ThirdParty/NeuralAmpModelerCore/Dependencies/nlohmann`
- **Preprocessor Macros** (Debug + Release):
  - `NAM_ENABLE_A2_FAST=1`  (matches the engine's default; enables the A2 fast-path)
  - `NAM_SAMPLE_FLOAT=1`    (run inference in float to match Core Audio + save CPU; the bridge
    works either way, but float is the right call on mobile)
- If you hit Eigen alignment/vectorization build errors on arm64, add `EIGEN_MAX_ALIGN_BYTES=0`.
  Only as a last resort add `EIGEN_DONT_VECTORIZE` (kills SIMD perf — avoid).

### 3. Bridging header (so Swift sees `NAMModel`)
When you add the first `.mm` file, Xcode offers **"Create Bridging Header?" → Yes.** In
`NamRig-Bridging-Header.h` add:
```objc
#import "NAMModel.h"
```
Now from Swift:
```swift
let nam = NAMModel()
try nam.loadModel(fromPath: path)         // off audio thread
nam.prepare(withSampleRate: 48000, maxBlockSize: 4096)  // off audio thread; prewarms
// on the audio thread, per block:
nam.processInput(inPtr, output: outPtr, frames: n)
```

### 4. Bundle a test capture
Grab a free **A1** and an **A2** `.nam` from TONE3000, drag them in, confirm they're in
**Build Phases → Copy Bundle Resources**. Load with `Bundle.main.path(forResource:ofType:"nam")`.

**Done when:** guitar → `NAMModel.process` → out **sounds like the amp**, no dropouts at 128 frames.
Then we A/B A1 vs A2 and watch CPU/battery — that's our efficiency story, measured.

---

## Notes that save hours
- **Match sample rates.** NAM models are sample-rate-specific (usually 48 kHz). Run the session at the
  model's `expectedSampleRate` or the tone shifts. For M2, force **48 kHz**.
- **Real-time safety.** On the audio thread: no `malloc`, locks, logging, or Obj-C that allocates.
  `NAMModel.process` only casts + calls `nam::DSP::process` (allocation-free after `prepare`).
- **Prewarm cost.** `Reset()` prewarms; it's slow — always off the audio thread (we do it in `prepare`).
- **Don't hot-swap mid-audio yet.** Load/prepare before starting the engine. Lock-free model swap
  for instant preset changes comes at M5.

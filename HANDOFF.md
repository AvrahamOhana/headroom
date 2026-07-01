# NamRig — Handoff / Continuation Guide

> Written 2026-07-01 to move development to a new MacBook and let a fresh Claude Code
> session pick up seamlessly. This file is the portable version of the local `~/.claude`
> memory (gotchas, roadmap, context) — it travels with the repo.

---

## 1. What NamRig is

A **native iOS guitar amp-sim / multi-FX** app aimed at competing with Line 6 Helix,
Fractal Axe-FX and Neural Quad Cortex — but **one-time purchase, no subscription**.

**Stack**
- **SwiftUI** UI, `@MainActor @Observable` `AudioEngine` (Swift 6, `-default-isolation=MainActor`).
- **AVAudioEngine** real-time audio: `AVAudioSinkNode` (input) → lock-free SPSC `FloatRingBuffer`
  → `AVAudioSourceNode` (output, now **stereo**). RT render callback: read ring → mono block
  chain → end-of-chain **looper** → Tier-1 **stereo output stage** → L/R.
- **NeuralAmpModelerCore** (NAM, C++20, MIT) via an Obj-C++ bridge (`Engine/NAMModel.h/.mm`).
  This is the amp core and it is **industry-leading** (same capture tech as QC/Tonex, often more
  accurate, free). Amp tone is a STRENGTH, not a weak spot.
- **TONE3000** API (OAuth PKCE) to browse/download `.nam` captures (amp / pedal) and `.wav` cab IRs.
- All DSP blocks are `nonisolated class AudioBlock` subclasses in `Blocks.swift`
  (`prepare/process(mono, n)/reset/bypass:Atomic`), RT-safe (preallocated, no locks/alloc in `process`).

**Competitive wedge:** scenes/MIDI, no subscription, TONE3000 integration, and the NAM-only
**pedal-capture → amp-capture stacking**.

---

## 2. Resume on the new MacBook

1. **Get the code:** it's a git repo. `git clone <your remote>` or copy the folder. (There is no
   remote configured yet — add one with `git remote add origin …` and push if you want cloud backup.)
2. **Xcode:** open `NamRig/NamRig.xcodeproj`. Built with the iOS 26.5 SDK / Xcode 26.
3. **Pair the iPhone:** plug in, trust the Mac. Find its id with `xcrun devicectl list devices`
   and update `DEV=` in `tools/deploy.sh` (current device id: `2B76597E-2150-5B8F-AC97-39A954AFB44A`,
   an iPhone 15). Signing team is already in the project; `-allowProvisioningUpdates` handles the rest.
4. **TONE3000 token:** `keys.md` (gitignored, holds a bearer token) does NOT travel. On the new
   machine just re-auth in-app: **Amp block → Browse TONE3000 → log in** (OAuth PKCE), which writes a
   fresh token to `UserDefaults("t3k_token")`. That's all TONE3000 browsing (amp/pedal/cab) needs.
5. **Build settings are already in the pbxproj** (the two critical Debug optimizations below).

---

## 3. Build & deploy

- **Compile-check** (fast, no device, no signing):
  ```
  xcodebuild build -project NamRig/NamRig.xcodeproj -scheme NamRig \
    -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet
  ```
- **Deploy** (build + install + launch): `tools/deploy.sh` (optionally pass
  `EXCLUDED_SOURCE_FILE_NAMES` as arg 1 to skip an in-progress file).
- Files auto-bundle via Xcode **synced folders** (anything under `NamRig/NamRig/` is compiled) —
  no need to edit the pbxproj to add a new `.swift`.

---

## 4. CRITICAL gotchas (do not relearn these)

- **Debug MUST optimize the engine.** Debug sets `GCC_OPTIMIZATION_LEVEL = 2` (C++ NAM: ~38× faster,
  else "a couple crackles then silence") AND `SWIFT_OPTIMIZATION_LEVEL = -O` (Swift DSP; at `-Onone`
  the Freeverb reverb alone hit 15–18% CPU). Both are in the pbxproj — keep them.
- **`-default-isolation=MainActor`:** every class/struct/enum touched on the audio thread must be
  `nonisolated` (e.g. `nonisolated final class X: @unchecked Sendable`, `nonisolated enum …`), or you
  get "main actor-isolated conformance … cannot be used in nonisolated context". Standalone `swift`
  test files DON'T set this flag, so DSP that passes a headless test can still fail to compile in-app.
  `AudioBlock` subclasses also need `override init(kind:)` and (warning-only) restated `@unchecked Sendable`.
- **`Array.move(fromOffsets:toOffset:)` is a SwiftUI extension** — NOT available in `AudioEngine.swift`/
  `Blocks.swift` (no SwiftUI import). Do the move manually in the engine (see `movePreset`).
- **Deploy: skip the decoy `NamRig.app`s.** There are two: `Index.noindex/…` (no valid
  CFBundleIdentifier) and a transient `.XCInstall/Wrapper/…` (has an executable but can be STALE).
  A naive `find … -print -quit` grabs one and then `devicectl install` fails while `launch` SILENTLY
  relaunches the OLD build. `tools/deploy.sh` already excludes both and picks the bundle that actually
  contains the `NamRig` executable. A real install prints `installationURL: file:///…/Bundle/Application/…`.
- **Launch with `--terminate-existing`** or a running app → "Launch prevented due to 'prevent launch'
  assertion" (RBSRequestErrorDomain 7).
- **A compile-check (`CODE_SIGNING_ALLOWED=NO`) leaves an UNSIGNED product** in the same
  `Build/Products/…` path → a later `devicectl install` fails "No code signature found". Always run a
  real signed build (`deploy.sh`) before installing.
- **Device drops** show as CoreDeviceError 1011 / `devicectl list devices` → `unavailable`. Build still
  succeeds; just re-run deploy when it's back.
- **A2 NAM fast-path removed** (garbage output); the bundled `wavenet_a2_max.nam` is a broken fixture —
  judge A2 by real TONE3000 captures. The iOS Simulator can't do real-time guitar audio — device only.
- **Multi-agent `Workflow` tool STALLED** on a 5-agent parallel build (infra hang, ~0 output). Prefer
  building features **directly** (single background Agents for verified self-contained DSP have worked
  well: reverb algos, OD library, StereoFX, Tempo).

---

## 5. Current state

### Shipped & tested on device (earlier this session, committed)
Block chain (free-order add/remove, tap-to-edit), NAM amp + 2nd **pedal-capture** slot, TONE3000
browse (amp→amp-cab / pedal→pedal, pagination, artwork), tuner, presets (**tolerant decoder** — schema
changes never wipe saved presets), MIDI in (PC→preset, CC→param/bypass/nav, learn), app icon, latency
picker. **Real reverb algorithms** (`ReverbAlgorithms.swift`: Dattorro plate / dispersive spring / FDN
room+hall — genuinely different engines by reverb type). **Anti-aliased drive** (Oversampler + ADAA1).
**Stompbox OD library** (`CircuitDrive.swift`: Green Screamer/Rodent/Modern Distortion/Centaur Gold/
Muffin Fuzz — circuit-modeled, retuned for pick dynamics + a global post-clip anti-fizz LPF; addable
`.stomp` block). **Stereo Tier-1** (per-preset: PingPong + decorrelated StereoReverb → wide output;
bit-identical mono when off). Setlist manager (reorder/rename/duplicate/delete), Live-mode neighbor
preview + panic-mute + tuner-auto-mute + haptics, Light/Dark/System theme, OUTPUT/MIXER as the "OUT"
chain block.

### Built + compiles green, **PENDING DEPLOY** (device went offline before deploy)
These are in the working tree / this commit but NOT yet run on the phone — **deploy `tools/deploy.sh`
first thing and smoke-test them**:
- **Header cleanup** — "Live" labeled capsule button; Tuner + MIDI moved into the gear-icon dropdown.
- **CAB is its own chain block** — `.cab` BlockKind + `CabBlock` (the 2048-tap IR convolution extracted
  from `AmpBlock`); in `defaultOrder` after `.amp`; `loadCabIR/clearCabIR/applyCabIR` now target
  `cab.setIR`; `apply()` **migrates** old presets (inserts `.cab` after `.amp` if their saved order lacks
  it — so existing presets keep their cab). CAB editor has **Browse**(TONE3000 cab, `format=""`/`arch=""`
  → `.wav` IR) / **File**. NOTE: `AmpBlock`'s own IR code is left intact-but-unused (safe to delete later).
- **Tap tempo** (`Tempo.swift` `TempoClock` value type) — Delay editor: Tempo-Sync toggle → TAP button +
  BPM readout + note-division Picker (1/4, 1/8., 1/8, 1/8T, 1/16). `delayTimeMs = tempo.ms(div)` when synced.
- **Looper** (`LooperEngine.swift`, end-of-chain) — one-button REC→Play→Overdub cycle, seam crossfade,
  RT-safe Atomic state; `context.looper.process(s,n)` runs right after `chain.render`; transport
  (REC/STOP/CLEAR + Loop Level) lives in the OUTPUT block editor.

### Written, NOT wired (safe — compiles unused)
- **Wah** (`Wah.swift`) — a real swept resonant filter (TPT-SVF bandpass, 400→2200 Hz, manual `position`
  + auto-envelope). This is the **expression-pedal** target. Made self-contained (its `init(kind:)` has no
  `.wah` default) so it can't break the build. DSP verified: `swift tools/wah_test.swift` PASSES — the
  resonant peak sweeps 400 → 900 → 2200 Hz as `position` goes heel→toe.

---

## 6. Pending work — pick up here (in priority order)

### A. Finish the Wah (≈ mirror the `.stomp`/`.cab` block wiring)
1. `Blocks.swift`: add `case wah = "Wah"` to `BlockKind`.
2. `Wah.swift`: restore `override init(kind: BlockKind = .wah)`.
3. `AudioEngine.swift`: `private let wah = WahBlock(kind: .wah)`; add to `chainBlocks` (installed, but
   **addable** — do NOT put in `defaultOrder`); @Observable params `wahEnabled/wahPosition/wahAuto/
   wahSense/wahMix` with `didSet → wah.…`; add `.wah` to `setBlockEnabled`/`isBlockEnabled`.
4. `MIDIManager.swift`: add `MIDIParam.wah` (range 0…1); `AudioEngine.setParam` case `.wah: wahPosition = v`
   — **this is what makes an expression pedal work** (map the pedal's CC → `.wah` via MIDI-learn).
5. `ContentView.swift`: `ChainBlock.wah` (the 7 switches: case list / kind / init? / short "WAH" / full
   "Wah" / icon e.g. "dial.min.fill" / color) + a `controls(.wah)` editor (Auto toggle, Position slider,
   Sensitivity, Mix) + `isOn`/`enabled`.
6. `Preset.swift`: add `wahOn/wahPos/wahAuto/wahSense/wahMix` + the tolerant `g(.…)` decoder lines +
   `capture()`/`apply()` in `AudioEngine`.
7. `swift tools/wah_test.swift` should show the resonant peak sweeping heel→toe. Then `tools/deploy.sh`.

### B. Recorder (verify ON DEVICE — can't headless-test AVAudioEngine)
New `Recorder.swift` `@MainActor @Observable`: `engine.mainMixerNode.installTap(onBus:0,bufferSize:4096,
format: mixer.outputFormat)` → write buffers to an `AVAudioFile` (.caf/.m4a) in Documents/Recordings/;
`start(engine:name:)` / `stop()->URL?` / `isRecording`. AudioEngine (owns `engine`) exposes
`startRecording/stopRecording`; UI = a record button in the header + a Recordings list (share/delete) in
Settings. Do NOT touch the RT source callback.

### C. Dual amps / Stereo Tier-2 (the big architectural one — go slow)
Two parallel amp paths A∥B → end mixer (per-path level + equal-power pan via `StereoFX.equalPowerPan`) →
the existing stereo output. Likely a 2nd `SignalChain` instance for B + a split after the common pre-amp
blocks; RenderContext + callback changes must keep **bit-identical mono when dual is OFF**; per-preset
path-B + mixer fields in `Preset`. Costs ~2× NAM CPU — call out the headroom + the latency picker.

### Longer roadmap
FX "feel" upgrades to SOTA (shared-LFO stereo chorus, through-zero flanger, RMS soft-knee compressor +
sidechain, parametric/graphic EQ, tape/BBD delay); **Snapshots** (Helix-style param scenes within one
preset — refactor `apply()` into `applyStructural` + `applyParams`, snapshot = `applyParams` only, zero
reload gap); dual-cab + mic-position; power-amp sag + global EQ; lower the deployment target (currently
`IPHONEOS_DEPLOYMENT_TARGET = 26.5`, very high) to reach iPhone 11 / older devices.

**Sound-competitive framing:** the amp core (NAM) already competes/wins. The real levers are **cabs**
(dual-cab + mic + curated IRs), **finishing the FX to SOTA**, and **output/power-amp polish**.

---

## 7. Key files

```
NamRig/NamRig/
  AudioEngine.swift    @Observable engine + RenderContext (RT box) + render callback + presets/MIDI/tempo/looper/stereo
  Blocks.swift         AudioBlock base, BlockKind enum, all mono blocks (gate/comp/drive/amp/CabBlock/eq/mod/delay/reverb…),
                       Biquad, ADAA1, Oversampler, SignalChain (atomic-reorder)
  ReverbAlgorithms.swift  DattorroPlate / SpringReverb / FDNReverb (ReverbBlock delegates by type)
  CircuitDrive.swift   CircuitDriveBlock + PedalModel table (the OD library)
  StereoFX.swift       PingPongDelay + StereoReverb (wet-only) + equalPowerPan  (Tier-1 stereo output)
  LooperEngine.swift   end-of-chain phrase looper                 (NEW, wired)
  Tempo.swift          TempoClock value type (tap tempo)          (NEW, wired)
  Wah.swift            WahBlock resonant wah                       (NEW, NOT wired)
  ContentView.swift    main UI: header, presetBar, chain strip + tile/editor, OUTPUT block, all sheets
  LiveView.swift       full-screen stage view
  MIDIManager.swift    CoreMIDI in, CC/PC mapping + learn
  Preset.swift         Preset struct + tolerant Codable decoder + PresetStore (Documents/presets.json)
  T3K.swift            TONE3000 client (OAuth PKCE) + browser (Target .amp/.pedal/.cab)
  Engine/NAMModel.*    Obj-C++ bridge to NeuralAmpModelerCore
tools/
  deploy.sh            build + install + launch (device-aware, dodges the decoy .apps)
  *_test.swift         headless DSP verifiers (reverb_algo, od, aa, stereo, ir_reverb, wah, tempo…)
docs/fx-roadmap.md     the FX research (OD recipes, reverb algorithms, legal/naming)
keys.md                GITIGNORED — TONE3000 token; re-auth in-app on a new machine
```

**Security note:** model real pedal/amp circuit *behavior* (legal); never ship trademarked names/logos —
the OD models use allusive names + `CircuitDriveBlock.disclaimer` ("not affiliated…"). Keep `keys.md` ignored.

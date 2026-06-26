# nam-rig — Research Brief (v0)

_Compiled 2026-06-25 from two web-research passes (competitive + technical). Items marked **⚠** are
vendor/forum claims or unverified and should be re-checked before relying on them publicly._

---

## 1. Market & competitors

The NAM ecosystem is **large and accelerating** — TONE3000 (formerly ToneHunt) hosts ~350k+ free
`.nam` captures with a public API — but the **iOS player field is shallow and unwon**.

### Dedicated NAM (.nam) players on iOS

| App | Dev | Price | AUv3+Standalone | Notes / weaknesses |
|---|---|---|---|---|
| **NAM Live** | Luke Chard Maple | $14.99 once | claims live | **The competitor that triggered this project.** Brand new, **0 ratings**. Pitch = ours: "play A2 NAM captures live, add effects, browse thousands of tones." Depth unverified. `id6778012976` |
| **Nam XT** | Reinarc / Artera DSP | $14.99 once | yes | 3.5★ (11). Complaints: "muted" tone; **no AUv3 state-saving**; AUv3 import freezes; preset reload bugs in AUM. `id6739214860` |
| **Ampz** | LNH Enterprises | $9.99 once, no IAP | yes | 4.0★ (2). Strong spec sheet: custom C++ engine, ⚠claimed <2.5ms latency, 10-slot FX, looper, drums, tuner, MIDI. ampz.app |
| **NAM Loader Pedal** | Rafael G. Bertholdo | $4.99 once | yes | 4.0★ (1). Loads .nam + IR, MIDI CC, TONE3000 browser. Bugs: gate broken in Logic; browsing only in standalone. `id6775461616` |
| **GigFast Lite** | Reinarc | Free + **sub** ($9.99/mo) | yes | 3.8★ (37). Top complaint = **subscription resentment**. ⚠20–30% CPU on M2 iPad w/ complex profiles. `id6503917233` |

**Incumbent — AmpliTube TONEX (IK):** AUv3+standalone, but **cannot import `.nam`** (proprietary
format) and can't capture on iOS. **2.5★ / 83 ratings** — frequent startup crashes, sample-rate
crackle, broken AUv3 recall. **No effects chains, no scenes, single fixed rig.** Tone quality praised
when it works. Monetizes via $9.99/mo subscription + one-time tiers.

**Legacy (none load NAM):** AmpliTube (no AUv3, IAP sprawl, non-transferable purchases); BIAS FX 2
(no AUv3, one-time tiers, crash reports); Line 6 Mobile POD (**abandoned**, last update 2018);
Deplike (dark-pattern countdown pricing); Tonebridge (free, preset-player, stale AUv3).

**Does NOT exist on iOS:** "NAM Player" (no such app), AIDA-X (desktop only, uses a *different*
RTNeural format), GuitarML Proteus, Tonocracy.

### Monetization reality
- **Subscriptions are the #1 grievance** category-wide. **IAP fragmentation** is #2.
- Successful indie NAM players are **one-time purchases** ($4.99–$14.99).
- Wedge: **one-time price, explicitly "no subscription, own it forever,"** ~$10–20.

---

## 2. The wedge — gaps to exploit with great UI/UX

1. **Scenes / snapshots** — the clearest gap. No iOS app reliably offers Helix-style snapshots
   (instant, gapless switching of multiple param/bypass states inside one preset).
2. **Gapless / fast preset switching** — everyone (even hardware) has audible gaps; iOS hosts worse.
3. **Rock-solid MIDI foot control + MIDI-Learn** — in-app footswitch mapping is rare; Bluetooth-MIDI
   stability is the real pain to solve.
4. **Both standalone AND AUv3, done right** — esp. **AUv3 state-saving that actually works**.
5. **"Stage Mode"** — one-tap live hardening: Do-Not-Disturb, Guided Access lock, CPU headroom,
   clip/signal meters, always-on tuner.
6. **CPU/battery efficiency** — NAM-on-iOS is heavy (⚠~7–9%/instance vs ToneX 1–2%); lean into **A2**.
7. **Live-stage UI** — big tappable scene/preset buttons, dark-stage contrast, instant A/B.

> ⚠ Caution from research: gigging iOS guitarists prioritize **simplicity, speed, tuner, reliability**
> over deep complexity — make scenes powerful but keep the fast path uncluttered.

---

## 3. Technical foundation

### 3.1 Engine & licensing
- **`sdatkinson/NeuralAmpModelerCore`** — the C++ engine. **MIT licensed** (confirmed) → fine in a
  paid, closed-source app. **C++20**, deps **Eigen** (MPL-2.0) + **nlohmann/json**. Clean API:
  `nam::get_dsp(path/json)` → `Reset(sampleRate, maxBlock)` → `prewarm()` → `process(in, out, n)`.
  Models are **mono in / mono out**. Has an `NAM_ENABLE_A2_FAST` build option (A2 support).
- **Perf upgrade path:** `mikeoliphant/NeuralAudio` (MIT) — "same output, faster, less memory,"
  supports **A1 + A2** + RTNeural; used in ARM hardware (Darkglass Anagram → ARM-portable). ⚠iOS
  build undocumented but pure C++.
- **Avoid:** `Tr3m/nam-juce` (GPL-3.0) and JUCE-license friction for closed source.
- ⚠ iOS gotcha: Eigen alignment may need `EIGEN_MAX_ALIGN_BYTES 0` workarounds on some toolchains.

### 3.2 NAM architectures & A2
- **WaveNet** (default, dilated conv, high quality, compute-hungry) vs **LSTM** (recurrent, cheaper).
- A1 size tiers (channels/head): **Standard** 16/8 (heaviest) → **Lite** 12/6 → **Feather** 8/4 →
  **Nano** 4/2 (~2.5× faster than Standard). Standard is heavy on mobile = wide channels × many
  dilated layers per sample @48kHz.
- **A2 = NAM Architecture 2**, launched **2026-06-02** by TONE3000 + Steven Atkinson, fully
  open-source/commercial-OK. Feed-forward WaveNet w/ LeakyReLU; **A2-Full ≈ 30–40% less CPU than
  A1-Standard**; A2-Lite for embedded. **Now the default for new TONE3000 captures.** → Support both
  A1 and A2. ⚠Exact A2 topology reported inconsistently across sources.

### 3.3 `.nam` file format
JSON: `version`, `architecture` (e.g. "WaveNet"/"LSTM"), `config` (arch dict), **`weights`** (flat
float array), optional `sample_rate` (defaults **48000**), `metadata` (name, gear make/model/type,
tone_type, in/out levels). Format gating in Core: earliest 0.5.0, latest fully-supported 0.7.0.

### 3.4 iOS real-time audio
- **Ship BOTH** a standalone app (AVAudioEngine / AURemoteIO) **and** an AUv3 extension, sharing one
  **real-time-safe C++ DSP kernel**. Standalone = the dedicated live rig; AUv3 = host in AUM/GarageBand.
- Low-latency path: `AVAudioSession` category **playAndRecord**, mode **Measurement**, set
  `setPreferredIOBufferDuration` (**seconds**, not frames). @48kHz: 64 frames ≈ 1.33ms, 128 ≈ 2.67ms,
  256 ≈ 5.33ms; RTL ≈ 2× buffer + hardware in/out.
- ⚠Measured RTL (older hw): Scarlett 2i2 ≈ 8.9ms, iRig HD ≈ 14.6ms @64/48k. <3ms ≈ imperceptible.
  Some iPhone 15/16 units reportedly glitch below ~20ms buffers — **validate on target device**.

### 3.5 Guitar input hardware (HARD requirement)
- Guitar → 3.5mm/headphone jack **does not work** (TRRS mic-level, impedance mismatch); built-in mic
  unusable. **Need a digital interface** doing Hi-Z + A/D over Lightning/USB-C.
- What guitarists use: **IK iRig HD 2 / HD X** (class-compliant), **Apogee Jam 96k / Jam+**,
  class-compliant USB interfaces (Focusrite Scarlett, MOTU M2/M4). Match connector: iPhone 15/16 +
  modern iPad = USB-C; older = Lightning (+ Camera Adapter for USB gear).

### 3.6 MIDI (CoreMIDI)
- Use **`MIDIEventList` / `MIDIReceiveBlock`** (iOS 14+); old `MIDIPacketList` path deprecated.
  Receive **Program Change** → preset/scene, **Control Change** → params. Wrappers: MIDIKit, MIKMIDI.
- **BLE MIDI** (iRig BlueBoard, AirStep, WIDI): ~3–10ms, convenient, slightly jittery; ⚠occasional
  disconnects — stability is a real feature to nail. **USB MIDI** (Morningstar MC6/MC8): tighter,
  needs Camera Adapter on Lightning. Background MIDI works because the audio session is always live.

### 3.7 Open-source starting points
- ✅ `sdatkinson/NeuralAmpModelerCore` (MIT) — the engine we vendor.
- ✅ `sdatkinson/NeuralAmpModelerPlugin` (MIT, **iPlug2**) — canonical usage reference; iPlug2 ships an
  "iOS-APP with AUv3" Xcode scheme (⚠no shipping iOS target in the plugin yet).
- ✅ `mikeoliphant/NeuralAudio` (MIT) — faster engine, A1+A2; swap target later.
- ❌ `Tr3m/nam-juce` (GPL-3.0), `AidaDSP/AIDA-X` (GPL, different format) — reference only.
- All shipping iOS NAM apps are closed-source (no reusable code, but they prove feasibility).

---

## 4. Open questions / unverified (⚠ re-verify before relying)
- Per-instance CPU % and "<2.5ms" roundtrip — forum/vendor claims, no independent iPhone benchmark.
- How many A1-Standard models run concurrently on an **iPhone** (vendor figures are for Macs).
- Exact A2 layer topology and the literal `architecture` string stored in A2 `.nam` files.
- `NeuralAudio` / Core **iOS build** is inferred from pure-C++/ARM use, not documented.
- NAM Live's actual feature depth (too new, 0 ratings) — worth buying to assess directly.
- Latency tables are older-hardware; re-measure on the actual test device + interface.

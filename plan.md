# nam-rig — Plan (living doc)

_Last updated 2026-06-25. This is the spine; `docs/research.md` holds the supporting brief._

## Vision
A native iOS app that loads NAM (A1 + A2) captures and is the **best-feeling** way to play and gig
with them: instant tones, real effects, **scenes**, and reliable **MIDI foot control** — wrapped in
UI that doesn't make you tap through five menus on a dark stage. Sold once, owned forever.

## What makes it win
- **Scenes / snapshots** with **gapless switching** — the clearest gap in every competitor.
- **Rock-solid MIDI** (foot-controller PC/CC + MIDI-Learn), BLE *and* USB, that doesn't drop mid-set.
- **One-tap "Stage Mode"** — DND, Guided-Access lock, CPU headroom, clip meter, always-on tuner.
- **Efficiency** — lean into the new **A2** architecture for battery/CPU on iPhone.
- **Excellent UI/UX** — big tappable controls, instant A/B, fast preset/scene navigation.
- **One-time price, no subscription** — the #1 complaint across the whole category.
- **Standalone + AUv3, both done right** (esp. AUv3 state-saving that actually works).

## Tech stack (decided)
- **UI:** SwiftUI
- **DSP engine:** `NeuralAmpModelerCore` (C++20, MIT) → vendored at `ThirdParty/NeuralAmpModelerCore`,
  wrapped behind an Objective-C++ bridge. Perf upgrade path: swap to `mikeoliphant/NeuralAudio`.
- **Audio (standalone):** AVAudioEngine + AVAudioSession (`playAndRecord`, `.measurement`), small buffers.
- **AUv3:** app extension sharing one real-time-safe C++ DSP kernel (fast-follow, M8).
- **MIDI:** CoreMIDI (`MIDIEventList`, iOS 14+).

## Target architecture (signal flow)
```
Guitar → [audio interface, Hi-Z + A/D, USB-C/Lightning]
       → AVAudioSession(playAndRecord, .measurement)
       → AVAudioEngine render callback  ── real-time thread, NO allocations/locks ──
            └─ DSP kernel (shared C++):
                 input gain → noise gate → NAM model (A1/A2) → IR/cab → EQ → FX(delay/reverb) → output gain
       → speaker / interface out
SwiftUI  ←→  param store (lock-free)  ←→  DSP kernel        CoreMIDI → param store / preset+scene switch
```
The **same C++ kernel** is wrapped twice: by the standalone AVAudioEngine graph and by the AUv3
`internalRenderBlock`. Build it engine-agnostic so `NeuralAudio` can replace Core later.

## Milestone roadmap
> **MVP = M0–M2** (proves the entire stack end-to-end on real hardware).
> **v1.0 sellable ≈ through M7.** **AUv3 (M8)** is a fast-follow.

| # | Milestone | Definition of done |
|---|---|---|
| **M0** | Toolchain & device build | Full Xcode installed; SwiftUI "hello" runs on the **physical device** via free provisioning. |
| **M1** | Audio passthrough | Guitar in → out, clean, at 128-frame buffer (then try 64); measured round-trip latency recorded. |
| **M2** | **First NAM tone** (the proof) | Bundled **A1 + A2** `.nam` loads, processed in a real-time-safe callback; sounds like the amp; no dropouts @128. |
| **M3** | Tone loading + IR + meters | Load any `.nam` from Files; optional IR/cab; in/out gain; signal/clip meter; tuner. |
| **M4** | Effects chain | Noise gate, EQ, drive, delay, reverb as **reorderable** nodes. |
| **M5** | **Presets + Scenes** | Save/recall full rig presets; **scenes** snapshot param/bypass states with **gapless** switching. |
| **M6** | MIDI | Program Change → preset/scene; CC → param; **MIDI-Learn**; BLE + USB foot controllers. |
| **M7** | Stage Mode + polish | Big-button live UI; DND/Guided-Access guidance; always-on tuner; instant A/B; dark-stage contrast. |
| **M8** | AUv3 extension | Shared kernel hosts in AUM/GarageBand with **working state recall**. |
| **M9** | Ship | Apple Developer account; App Store assets; one-time pricing; TestFlight beta; launch. |

## Committed backlog (slot in as we build)
- **TONE3000 cloud library** — browse/search the [TONE3000 API](https://www.tone3000.com/api) in-app, one-tap download `.nam` + IRs into a local library, favorites/recent. Real differentiator: competitors make you sideload files. Slot in after Presets (**M5**). To spec when we build: auth/API-key, search/filter params, download URLs, model licensing. _(Requested 2026-06-26.)_
- **Effects chain (M4) layout** — pre-amp: noise gate, compressor, wah, drive/boost; post-amp: EQ, chorus, flanger, tremolo, delay, reverb. Each bypassable + reorderable.
- **Amp "controls" reality** — a `.nam` is a fixed snapshot, so the amp page exposes **Input Drive** (pre-gain → breakup), **Output**, and a **post 3-band EQ**. No native gain/bass/mid/treble knobs (those would need multi-capture gain sweeps).

## Key decisions
**Decided:** SwiftUI + NeuralAmpModelerCore (MIT) + AVAudioEngine; standalone first, AUv3 fast-follow;
one-time pricing, no subscription; support A1 **and** A2.

**Open (decide as we go):**
- App **name** (NAM Live is taken) + bundle id.
- Min iOS version (likely **16 or 17** floor; 14+ needed for `MIDIEventList`).
- iPhone-only vs **Universal** (iPad is great for a rig — lean Universal).
- Effects DSP: hand-write vs small library.
- Engine for v1: stay on Core, or move to NeuralAudio if M2 CPU is tight.
- Exact price (~$10–20).

## Risks & mitigations
- **CPU/battery on iPhone** (NAM is heavy) → measure at **M2**, prefer A2/efficient models, profile early.
- **Real-time safety** → zero allocations/locks/logging on the audio thread; lock-free param passing.
- **BLE MIDI drops** → design reconnect handling; support USB as the rock-solid path.
- **Latency glitches on some devices below ~20ms buffers** → make buffer size a setting; test on target device.
- **Competitor moving** (NAM Live) → ship the scenes/MIDI/Stage-Mode wedge they don't have; iterate fast.

## Next actions
1. **(You)** Install **full Xcode** from the Mac App Store — the long pole (~7GB+). Ping me when it's ready.
2. ✅ Hardware locked: **iRig USB + iPhone 15** (USB-C, A16 Bionic).
3. **(You, while it downloads)** Plug the iRig into the iPhone's USB-C, guitar in, confirm signal in **GarageBand** (free) — proves the hardware path before we write code. See `docs/setup-ios.md`.
4. **(Prepped — no action)** M0 setup + the **M2 engine-integration recipe** are in `docs/setup-ios.md`; the Obj-C++ bridge draft is in `Sources/DSP/`. When Xcode's in, we run **M0 → M1 → M2**.

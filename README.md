# nam-rig

A native iOS amp-modeling app that loads **Neural Amp Modeler (NAM)** captures (A1 + A2) and
gives guitarists excellent UI/UX for **practice and live rigs**: effects, presets, **scenes**,
and MIDI foot-controller support.

> **Status: bootstrapping (2026-06-25).** No Xcode project yet — see [`plan.md`](plan.md) for the
> roadmap and [`docs/research.md`](docs/research.md) for the market + technical brief.

## Why
The NAM ecosystem is open and growing fast, but the existing iOS players are shallow (and the
incumbent, ToneX, can't even load `.nam`). The gap: a polished, reliable, live-ready player with
real **scenes**, **gapless switching**, solid **MIDI**, and **one-time pricing** (no subscription).

## Stack (planned)
- **UI:** SwiftUI
- **DSP engine:** [`NeuralAmpModelerCore`](https://github.com/sdatkinson/NeuralAmpModelerCore) (C++, MIT) behind an Objective-C++ bridge
- **Audio:** AVAudioEngine (standalone) + an AUv3 app extension (fast-follow), sharing one real-time DSP kernel
- **MIDI:** CoreMIDI (`MIDIEventList`, iOS 14+)

## Layout
- `plan.md` — strategy, milestones, decisions (living doc)
- `docs/research.md` — competitive + technical research brief
- `ThirdParty/` — vendored MIT engine(s) as git submodules

## Requirements to develop
- A Mac with **full Xcode** (Apple Silicon)
- An **iPhone/iPad** + a **guitar audio interface** — the built-in headphone jack will **not** work
  for guitar input (impedance mismatch)

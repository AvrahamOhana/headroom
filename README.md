# Headroom

**Headroom** (formerly NamRig) is a native **iOS + macOS guitar rig**: Neural Amp Modeler captures as the amp core, a free-form
dual-path signal chain you build by dragging blocks, real reverb/delay/modulation algorithms,
MIDI in/out, and a built-in TONE3000 browser for captures and cab IRs. Free on the App Store, no
subscription, no ads — and open source under the GPLv3.

<!-- screenshot -->

## Features

- **Amp core: NAM.** Loads any `.nam` capture (WaveNet A1/A2, LSTM, custom). Level-matches with the
  capture's loudness metadata, rumble-filters the input, and caps makeup gain so quiet captures don't
  become hiss.
- **Two complete signal paths (A ∥ B)** with per-path level and pan into a stereo output. Any block
  can appear any number of times — two delays, EQ before *and* after the amp, two amps. Drag tiles to
  reorder or move them between paths; settings travel with the block.
- **Blocks:** noise gate (hysteresis / hold / range), compressor (soft knee), clean boost, drive
  (anti-aliased, oversampled), stompbox overdrives (circuit-modeled), wah (expression-pedal or auto),
  second NAM slot for pedal captures, cab IR, 3-band EQ, chorus, flanger, tremolo, tape-style delay
  (tempo sync, tap), algorithmic reverbs (room / plate / spring / hall), convolution reverb, a
  stereo widen stage, and a phrase looper.
- **MIDI:** Program Change → preset, CC/note mappings with learn, expression pedal, momentary or
  latching switches, Bank Select, MIDI clock in → tempo; MIDI **out** (PC on preset load, per-preset
  send list, CC feedback, clock); Bluetooth MIDI pairing on iOS.
- **TONE3000:** OAuth login, search / trending / favorites / mine / downloaded, sort and filters,
  one-tap download of captures and cab IRs.
- **Live view** for stage use; setlist management; presets migrate across schema changes.

## Building

Requirements: Xcode 26, iOS 18+ or macOS 15+ (the `Atomic` type sets the floor).

```
git clone --recurse-submodules https://github.com/AvrahamOhana/nam-rig.git
open NamRig/NamRig.xcodeproj
```

The NAM core is a git submodule (`ThirdParty/NeuralAmpModelerCore`, which nests Eigen and
nlohmann/json) — clone with `--recurse-submodules` or run `git submodule update --init --recursive`.

Set your own team in Signing & Capabilities, pick the `NamRig` scheme, and run on **My Mac** or an
iPhone (the iOS Simulator cannot do real-time guitar audio). Command-line builds:

```
# macOS
xcodebuild build -project NamRig/NamRig.xcodeproj -scheme NamRig -destination 'platform=macOS' -quiet
# iOS (compile check, no signing)
xcodebuild build -project NamRig/NamRig.xcodeproj -scheme NamRig -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet
# iOS deploy to a paired device
DEV=<device-id from `xcrun devicectl list devices`> tools/deploy.sh
```

Debug builds keep the C++ and Swift optimizers on (`GCC_OPTIMIZATION_LEVEL=2`, `-O`): the neural
network is ~40× slower unoptimized and the audio thread starves.

## Testing without a device

- `tools/blocks_test.swift` — compiles the real DSP blocks and checks them numerically (gate, compressor,
  delay, chorus, flanger, amp block, wah, lock-free chain). Run command in the file header.
- `tools/preset_test.swift` — preset schema round-trip and migration of old presets.
- `tools/render.sh <model.nam> <in.wav> <out.wav>` — renders audio through the real NAM core + blocks
  offline and prints peak / noise floor / click metrics.

The Xcode project, source folder and Swift module keep the working title `NamRig`. `HANDOFF.md` is the developer guide: architecture, gotchas, and the roadmap.

## Captures

Headroom ships one capture, the author's own amp (CC BY 4.0). Bring your own `.nam` files, or log in to
TONE3000 inside the app. Never redistribute captures you downloaded — they belong to their creators.

## License

GPL-3.0-or-later — see `LICENSE`. Third-party notices and the capture license are in `NOTICE.md`.
Headroom is not affiliated with Neural Amp Modeler, TONE3000, or any amplifier or pedal manufacturer.

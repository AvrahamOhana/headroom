# NamRig FX Roadmap — competing with Helix / Axe-FX / Quad Cortex

Source: 5-agent deep-research workflow (2026-06). Verdict: **amps already compete (NAM neural + IR cabs);
the whole gap is the hand-written FX in Blocks.swift, and the dominant flaw is NO oversampling / anti-aliasing.**

## Priority order
1. **Oversampling + ADAA infra** (foundation; kills "digital fizz" — the #1 cheap-vs-pro tell).
2. **CircuitDriveBlock + pedal library** (real, voiced OD/dist/fuzz — circuit-derived, not generic tanh).
3. **Reverb refactor** — 3 real algorithms (FDN room/hall, Dattorro plate, dispersive spring). The current
   room/plate/spring/hall are the SAME Freeverb with different decay/damp values (user-noticed, must fix).
4. Stereo (post-amp: mono-in/stereo-out on time/mod/reverb).
5. Modulation + dynamics + EQ feel pass.

## Architecture (new infra in Blocks.swift, all RT-safe — prealloc in prepare, atomic swap like AmpBlock.setIR)
- **Oversampler** (struct, factor 2/4/8, polyphase/halfband FIR). Wrap ONLY nonlinear blocks. 2–4x soft, 8x hard-clip/fuzz.
- **ADAA1** (struct, stores prevX): `y=(F1(x)-F1(prevX))/(x-prevX)`; fallback `f((x+prevX)/2)` when `|x-prevX|<1e-5` (NON-NEGOTIABLE). F1: tanh→`ln cosh` (stable `|x|+ln(1+e^-2|x|)-ln2`); hardclip→`x²/2` for |x|<1 else `|x|-1/2`. ADAA1+2xOS ≈ alias-free soft; 8x for hard.
- **Biquad LP/HP/BP** (RBJ) — only shelves/peaks exist today; needed for pedal pre/tone filters + spring band-limit.
- **Reverb primitives**: AllpassLine, DelayLine(fractional read), OnePoleLP, LFO.
- **Denormal flush** on every recursive reverb/feedback line (FTZ or ±1e-20) — 6s tails stall the audio thread otherwise.
- **DC blocker** after every asymmetric nonlinearity (fuzz, Ge Klon, Big Muff).

## Overdrive library (data-driven: PedalModel{inputHz, gain, clipMode, diodeVf, asym, feedbackCapHz, tone, level, OS})
Clip topology genuinely BRANCHES in code (soft-in-feedback vs hard-to-ground), so these are real different algorithms.
- **Green Screamer** (TS808): input HPF ~720Hz (mid-hump, lows clean) → gain → SOFT clip Si 0.6V in feedback → LPF~723Hz+tilt → level.
- **Rodent** (RAT): light HPF → very-high gain + feedback-cap treble roll → HARD clip Si to ground → "Filter" LPF (darker as turned up) → level. 8x OS.
- **Modern Distortion** (DS-1): transistor+opamp gain → HARD clip Si to ground → tilt+mid-scoop tone → DC block → level. 8x OS.
- **Centaur Gold** (Klon): parallel CLEAN + clipped(Ge 0.3V soft asym) branches, blend knob, treble tilt. Delay-match the clean branch to the ADAA wet.
- **Muffin Fuzz** (Big Muff): two cascaded soft-clip stages + mid-SCOOP peaking biquad (~-13.5dB @1kHz) + makeup.
- **Face Fuzz** (Fuzz Face): transistor cutoff, pickup-loading — NOT a static shaper → ship as a **NAM capture** (existing pedal .nam slot) or WDF later.

## Reverb algorithms (replace the fake "types"; keep ReverbIRBlock as the 4th "convolution" option)
- **Plate** = Dattorro 1997 figure-8 allpass tank (input diffusers 142/107/379/277 → modulated tank, read 7 fixed taps, scale ×1.613@48k). First tank AP MUST modulate.
- **Spring** = HP80 → cascade of ~100 stretched allpasses (M~256, a~0.6 = dispersive chirp) in modulated feedback loop (LP~4.3kHz, delay 30-55ms, decay .6-.8) → light tanh "clank".
- **Room** = ER tap-delay (7/11/17/23/29/37/43/53ms, alternating-sign) → small 8-line FDN (Householder, Jot gains, HF damp).
- **Hall** = same FDN, longer lines + T60 1.5-6s + frequency-dependent damping (highs decay 2-3x faster) + every line modulated.

## Neural vs modeled (offer BOTH, labeled)
- **Circuit** (CircuitDriveBlock): tweakable, light, continuous knobs, one engine + data table = whole library. The breadth/workflow win.
- **Capture** (.nam pedal slot): exact unit, fixed knobs, heavier; for "this exact pedal" + circuits that resist modeling (Ge fuzz).
  A capture is ONE knob setting — ship multiple captures across the sweep. Always wrap neural blocks in the oversampler (they alias too).

## Legal / naming
Modeling circuit BEHAVIOR is legal (topology not copyrightable, patents expired). NOT allowed: trademarked NAMES, logos,
trade dress, implied endorsement. Ship ALLUSIVE names (Green Screamer, Rodent, Modern Distortion, Centaur Gold, Muffin Fuzz,
Face Fuzz) — same as Helix (Minotaur=Klon, Vermin=RAT). In-app Models disclaimer: "All model names are original. Third-party
product names are referenced only to identify the inspiring circuits. NamRig is not affiliated with/endorsed by any manufacturer."
Reference real pedals only in docs (nominative fair use), never as the in-app product name. Verify license of any bundled captures.

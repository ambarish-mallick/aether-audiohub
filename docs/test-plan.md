# Test plan and recorded results

Machine: Apple Silicon Mac, macOS 27.2 (26B5101f), Apple Swift 6.4 / clang 21 (Command Line Tools), CMake (Homebrew). Date: 27 Oct 2026.

## 1. DSP core — `./scripts/test-core`

156 checks pass in release **and** under AddressSanitizer + UndefinedBehaviorSanitizer. The sanitizer run caught one real out-of-bounds read in response-curve interpolation; it is fixed and covered.

| Spec requirement | Test | Result |
|---|---|---|
| §6.1 DSP bypass exact after declared latency | All 6 rates, random 1–1500-frame buffers | max error 0 (≤ 1e−7 required) |
| §7.1 Output independent of chunking | Random 1–3000 vs fixed 512 frames, custom + room + IEM | bit-identical |
| §7.1 Convolution vs high-precision reference | Engine vs float64 direct convolution, 3 modes | 133.6–135.3 dB SNR |
| §3.1 Deterministic output | Two engines, same input | bit-identical |
| §6.1 No non-finite output | NaN/±Inf injected | finite; 3/3 counted |
| §6.1 Non-finite internal → bypass/fade | ±3e38 input overflows the FFT | safety bypass latched, finite output, recovers on next config |
| §6.1 Stereo integrity, centre | Centre-mono, 3 modes | L−R residual < −80 dB |
| §6.1 Hard pan not swapped | Left-only and right-only | Crossfeed: ILD 12.2 dB, 31.2 dB > 3 kHz, ITD 0.40 ms. Reference: ILD 2.0 dB broadband, 12.4 dB > 3 kHz, ITD 0.27 ms |
| §6.1 No audible transition defects | 997 Hz sine; 5 live mode switches including bypass | max second difference within the sinusoid bound (no click) |
| §3.7 / §7.2 Level matching | K-weighted, mono + uncorrelated pink | crossfeed +0.02, reference −0.03, custom +0.01 dB vs bypass; L60°/R20° −0.01, rear 150° −0.12, swapped 270°/90° −0.10, left off +0.03, right off + fold −0.05 dB |
| Clarity restores bypass timbre | ⅓-octave power response of the designed matrix, clarity 0 vs 1 | tilt 1.87 → 0.05 dB; Reference bands 100 Hz–16 kHz within ±1.5 dB (worst −1.47 dB at 6.4 kHz); ILD change ≤ 0.002 dB |
| Free speaker placement | Wrap, asymmetric, side-swapped and rear layouts | 390° ≡ 30°, −30° ≡ 330° (bit-identical); L60°/R20° ILD at 4 kHz 14.1 vs 7.5 dB; left at 270° favours the right ear and flips the ITD sign; rear 150° is 4.6 dB darker above 8 kHz than 30° |
| Speaker switched off | Left off, with and without fold; both off | left channel output exactly 0 without fold; right speaker still plays; 23 of 46 reflections rendered, all from the right speaker; fold feeds both channels to the right speaker identically (ILD 6.4 dB toward the right); both off rejected |
| §6.1 True peak ≤ −1 dBTP at default gain | Corpus below at −1 dBFS sample peak | all ≤ −1 dBTP (worst: mono sweep in Reference, −3.28 dBTP) |
| §3.7 True-peak meter | fs/4 sine at 45° (−3.01 dBFS samples) | reads ≈ 0 dBTP |
| §3.2 Fixed alignment, all modes | Impulse, 6 rates × 3 modes | bypass/crossfeed: arrival at declared latency ±1 sample; HRTF: direct-sound centroid within 0.1 ms |
| §3.8 All supported rates | 44.1–192 kHz × 4 modes, large room + IEM, random buffers | finite, non-silent |
| §5.2 Invalid config keeps previous | NaN width, bad mode, bad struct size, bad rate | rejected; generation unchanged |
| §3.4 Width | w = 1.25 on mono / anti-phase | mono unchanged (< 1e−5); side +1.94 dB |
| §3.5 Room | Reference room | 46 reflections, 6.2–40.1 ms, all lateral-capable, DRR +12.8 dB; dry = 0 reflections |
| §3.6 Correction bounds | +8 dB bass, +10 dB at 6 kHz, −25 dB narrow notch | within [−12, +6]; notch → +0.8 dB (not inverted); hostile input rejected |

Headroom corpus (true peak at the default −6 dB):

| Signal (−1 dBFS sample peak) | Crossfeed | Reference |
|---|---|---|
| Pink, uncorrelated stereo | −7.40 | −5.36 |
| Pink, mono | −6.76 | −4.71 |
| Pink, hard-left | −8.43 | −8.22 |
| Pink, anti-phase | −10.14 | −10.43 |
| Sine sweep 20 Hz–20 kHz, mono | −6.16 | −3.28 |

The −3.28 dBTP sweep is the narrowest margin. Real masters at 0 dBFS with inter-sample overs can exceed −1 dBTP in Reference/Custom; the Out meter flags this, and lowering Headroom fixes it. A broad licensed music corpus has not been run (spec §6.1 asks for one).

## 2. CPU — `./scripts/run-benchmarks` (512-frame host buffers)

| Mode | 44.1 kHz | 48 kHz | 96 kHz | 192 kHz |
|---|---|---|---|---|
| Crossfeed | 0.35% | 0.20% | 0.31% | 0.58% |
| Reference | 0.15% | 0.17% | 0.37% | 0.76% |
| Custom, large room + IEM | 0.18% | 0.20% | 0.42% | 0.88% |

Percent of one core. The spec gate is ≤ 15% for Reference.

## 3. Route — `Aether --selftest`

On the real device (MUSE HiFi M3Ultra over USB at 192 kHz, with system audio playing): 1279 callbacks, 0 overloads, 0 callbacks without tap input, live switches rendered bypass/crossfeed/reference, peak DSP load 11.4% of a buffer period, tap 48 kHz → route 192 kHz converted by Core Audio, estimated added latency ≈ 10 ms. Re-run after the clarity and free-placement update (ABI 2): pass, 1277 callbacks, 0 overloads, 0 tap-missing, peak DSP load 6.8%. See `docs/routing-macos.md`.

## 4. UI

Rendered offscreen for review with a debug build: `Aether --snapshot out.png --mode 0…3 [--unlinked] [--size WxH] [--room-size 0…2] [--width W] [--off left|right [--fold]] [--view onboarding|profiles]`. Reviewed for each room size, for width 80%, 100% and 122%, and with one speaker off (with and without fold). Checked at the minimum window size (1040 × 820) with unlinked speakers and one speaker behind the listener: nothing clips. Keyboard: ⌘1–⌘4 modes, ⌘B bypass, ⌘E engine; sliders focus with Tab and move with ←/→ (Shift ×5); VoiceOver labels and values on every control; increased-contrast palette.

## 5. Not yet run (required by the spec before release)

- 8-hour continuous playback; 99th-percentile callback timing; memory ceiling (§6.2).
- Electrical or loopback **measured** added latency (the UI shows an estimate only).
- DAC unplug/replug and sleep/wake recovery timing on hardware. The code paths exist; they are not measured.
- Source-app matrix (§4.3) with Apple Music, Spotify, browsers, exclusive mode and Atmos, each documented with screenshots.
- ±100 ppm clock-drift validation (drift is handled by Core Audio's aggregate here, not by Aether's own ASRC).
- Parser fuzzing beyond the hostile-input unit checks.
- Controlled listening tests (§7.3: ≥ 24 listeners, preregistered, level-matched).

# DSP mathematics

All design runs in float64 on the control thread. The result is a 2×2 FIR matrix `G[e][s]` (ear e, source channel s):

```
G = g_headroom · norm · E_e · ( H[e][L]·W[L][s] + H[e][R]·W[R][s] )
```

## Width (spec §3.4)

`M = (xL + xR)/2`, `S = (xL − xR)/2`, `x'L = M + wS`, `x'R = M − wS` ⇔ `W = [[a, b], [b, a]]`, with `a = (1+w)/2`, `b = (1−w)/2`. The default is `w = 1`; Custom allows 0.75–1.25. Tests confirm that mono input is unaffected and that side gain equals w.

## Virtual speakers (spec §3.2)

`yL = h(L,L)*xL + h(L,R)*xR`, `yR = h(R,L)*xL + h(R,R)*xR`, with the speakers at elevation 0°. Each speaker angle is set on its own side, 0–360°, measured from straight ahead toward that side: the left speaker sits at azimuth −θL, the right at +θR (clockwise from the front, right positive). θ = 0 is front centre, 90° is beside that ear, 180° is directly behind, and 270° is beside the opposite ear. Angles wrap modulo 360°. The Reference preset is θL = θR = 30°.

Per-ear HRTF model (Brown & Duda 1998, structural model), with head radius a = 8.75 cm, c = 343 m/s, and ears at ±100°:

- Head shadow: `H_hs(ω) = (1 + jαω/2ω0) / (1 + jω/2ω0)`, with `ω0 = c/a`, `α(θ) = (1+αmin/2) + (1−αmin/2)·cos(θ/θmin·π)`, `αmin = 0.1`, `θmin = 150°`. θ is the angle between the source and ear axis.
- ITD relative to head centre: `−(a/c)cos θ` for θ < 90°, and `(a/c)(θ − π/2)` otherwise. Rendered as an exact band-limited fractional delay in the frequency domain.
- Pinna: `1 + 0.35·Σ ρk e^{−jωτk}`, with B&D's ρ, A, B, D tables at elevation φ. The 0.35 depth tempers comb colouration. It is a tuned starting value, **not a validated optimum**.
- Rear shelf (front/back cue): `R(f) = (1 + jg·f/fr) / (1 + jf/fr)`, with `fr = 2.5 kHz` and HF gain `g = 10^(−6·r/20)`, where `r = max(0, −cos az · cos el)` is how far behind the source is. This models pinna shadowing of sources behind the head. The pinna-echo delays above are front/back symmetric, so without this cue a source at 150° would sound identical to one at 30°.
- Diffuse-field equalisation: the cos(el)-weighted power average over 72 azimuths × 4 elevations, ⅓-octave smoothed, ±10 dB, applied as a minimum-phase filter to every direction. It removes the model's average colouration while preserving direction-dependent cues.

## Switching a speaker off

Custom can switch either virtual speaker off (`speaker_enabled`); at least one stays on. A switched-off speaker contributes neither direct sound nor early reflections. Then:

- **Without fold**, its channel is not heard, exactly like unplugging a real loudspeaker. With width w ≠ 1, the mid/side stage still mixes a share of the muted channel into the other one, as it would before a real speaker pair.
- **With fold** (`fold_disabled`), both channels feed the remaining speaker at −3 dB each (ITU-style mono fold-down, `(L+R)/√2`), so nothing in the mix is lost.

Clarity and the loudness convention are computed on the resulting layout, so single-speaker playback is loudness-matched to bypass like every other mode: measured +0.03 dB (left off) and −0.05 dB (right off, folded). Because of that matching, the remaining speaker plays about 3 dB louder than it did as one of a pair.

## Clarity (timbre compensation)

The rendered power response follows the loudness convention below: `P(f) = ¼ Σ_e ( |H_eL + H_eR|² + |H_eL|² + |H_eR|² )`. It equals 1 for bypass. Before compensation, the Reference layout shows about +2.2 dB below 400 Hz (the two paths sum coherently at low frequencies), a −3.3 dB band at 6.3 kHz (pinna notch), and less treble above 10 kHz (far-ear head shadow). Through IEMs, which are already tuned to a target, this reads as muffled.

The correction is `C(f) = clarity · clamp( 10·log10( T(f) / P̄(f) ), −12, +10 ) dB`:

- `P̄` is P smoothed over ⅙ octave in the power domain.
- `T(f) = ½ Σ_s |R_s(f)|²` keeps the rear shelf of the two speakers, so rear placements stay audibly behind.
- C is held below 20 Hz and above min(20 kHz, 0.45·fs).
- It is realised as minimum phase and applied identically to all four paths.

Interaural level and time differences are therefore unchanged (max ILD change 0.002 dB in test). Measured with clarity 1: bass-to-treble tilt drops from 1.87 dB to 0.05 dB, and every ⅓-octave band from 100 Hz to 16 kHz is within ±1.5 dB (worst −1.47 dB at 6.4 kHz). Speakers at 150° stay 4.6 dB darker in the 8–16 kHz band than speakers at 30°. Reference uses clarity 1. Custom exposes 0–100%.
- A raised-cosine taper from 0.45·fs to Nyquist bounds fractional-delay sinc tails.

## Early room (spec §3.5)

The image-source method uses shoebox rooms:

| Room | W × D × H (m) | Speaker distance |
|---|---|---|
| Small | 4.0 × 5.0 × 2.6 | 1.4 m |
| Medium | 5.5 × 7.0 × 3.0 | 2.0 m |
| Large | 8.0 × 10.0 × 3.6 | 2.8 m |

The listener sits at 40% of the depth. Orders 1–2 are rendered.

- Wall pressure reflection factors: sides/back 0.75, front 0.70, floor 0.55, ceiling 0.65. Each bounce adds HF damping as a one-pole magnitude with a corner at 6 kHz (walls), 3 kHz (floor) or 5 kHz (ceiling).
- Gain = Π r · (d_direct/d_image) · room_level. Each reflection is rendered through the HRTF of **its own direction**, so the room carries interaural differences instead of one shared stereo reverb.
- Reflections arriving < 5 ms after the direct sound are omitted, treated as a reflection-free zone like a treated control room. Those arriving > 45 ms are omitted too. No late reverb is offered (the spec requires validation first).
- Measurable parameters: count, first and last delay, and direct-to-reflected energy. Reference: 46 reflections, 6.2–40.1 ms, direct +12.8 dB.

## Crossfeed (spec §3.3)

`D(f) = (1+g) − g·LP(f)`, `C(f) = g·LP(f)·e^{−jω d}`, with `LP = 1/(1 + jf/fc)`. Defaults: g = −9 dB, fc = 700 Hz, d = 0.3 ms. Ranges: −15…−3 dB, 0.5–2 kHz, 0.1–0.6 ms. The centre-mono sum `D + C ≈ 1 + g` is flat, so there is no bass build-up for mono content. Measured hard-left: ILD 12.2 dB broadband, 31 dB above 3 kHz, ITD 0.40 ms.

## IEM correction (spec §3.6)

- **User-tuned:** RBJ low shelf at 120 Hz, peak at 3 kHz (Q = 1), and high shelf at 8 kHz, each ±6 dB.
- **Imported (model estimate or measured personal):**
  1. Interpolate onto 480 log points.
  2. Smooth the measurement in the power domain: ⅙ octave below 2 kHz, widening to ⅓ octave above 6 kHz. The target gets ⅙ octave.
  3. Align levels over 300 Hz–3 kHz.
  4. Compute `Q = T·|P| / (|P|² + λ)`, with `λ = 0.01 · mean|P|²` (300 Hz–3 kHz).
  5. Fade to 0 dB over half an octave outside the reliable range (measurement span ∩ [20 Hz, user limit, default 10 kHz]).
  6. Clamp to **+6 / −12 dB**.

  A −25 dB narrow notch at 8.5 kHz yields +0.8 dB rather than an inversion (tested).
- The 64-point curve (20 Hz–20 kHz) becomes a minimum-phase filter via the folded real cepstrum and is folded into G.

## Loudness reference convention

For a pink-spectrum input, the K-weighted (ITU-R BS.1770 pre-filter + RLB) output power over 20 Hz–20 kHz is averaged over both ears and over two equally weighted conditions: fully correlated (`|H_eL + H_eR|²`) and uncorrelated stereo (`|H_eL|² + |H_eR|²`). It is normalised to the bypass power. Measured: crossfeed +0.02, reference −0.03, custom +0.01 dB versus bypass. Custom layouts: L60°/R20° −0.01, both at 150° −0.12, swapped 270°/90° −0.10, left off +0.03, right off with fold −0.05 dB.

## Headroom (spec §3.7)

Processing modes apply −6 dB by default (adjustable −18…0 dB). There is no limiter, no compression, and no automatic loudness gain. Corpus results at the default are in `docs/test-plan.md`.

## Convolution

Uniformly partitioned overlap-save. N = 2B; both channels go through one complex FFT (`z = xL + j·xR`) and are separated by Hermitian symmetry. The frequency-domain delay line is shared by the active and previous banks. Output for both ears comes from one inverse FFT of `Y_L + j·Y_R`. Agreement with float64 direct convolution: 134.6–135.5 dB SNR.

## True peak

The 4× polyphase interpolator is a 64-tap Kaiser-windowed sinc (β = 8, pass band 0.45·fs), with each phase normalised to unity DC gain. A sine at fs/4 with 45° phase (sample peak −3.01 dBFS) reads ≈ 0 dBTP. This is an estimate in the spirit of BS.1770 Annex 2, not a certified meter.

# Release notes

## Aether 1.1.0 — 27 Oct 2026

Developed by Ambarish Mallick.

**Sound**
- **Clarity** (new, on by default): removes the dullness that virtual speakers add on IEMs. The overall tonal balance returns to that of bypass within ±1.5 dB per ⅓ octave, with interaural cues untouched.
- Speakers can be placed **anywhere on the full circle** (0–360° per side), including behind you. Rear placements keep a subtle darker tone as a front/back cue.
- **Independent left and right angles.** The speakers start linked; the chain button unlinks them.
- **Switch either speaker off**, optionally playing its channel through the remaining speaker (−3 dB mono fold-down).
- Every layout stays loudness-matched to bypass (within 0.13 dB in tests).

**Interface**
- Drag a speaker in the sound field to place it. Right-click to switch a speaker on or off.
- Small, medium and large rooms are drawn as distinct floor plans with a 1 m grid and their dimensions.
- The stereo image band shows the width setting live. Anything pushed beyond the speakers is drawn in amber.

**Packaging**
- A single installer: `Aether-1.1.0.dmg`, a universal app (Apple silicon + Intel) with hardened runtime.
- When opened from the disk image, Aether offers to move itself to Applications.
- Settings from 1.0 carry over automatically.

**Known**
- Not yet Developer ID signed or notarized, so first launch needs **Open Anyway** in Privacy & Security once.
- The Intel slice is built but has not been run on an Intel Mac or under Rosetta.
- See `docs/known-limitations.md` for the rest.

# Definition of Done — status (spec §10)

Legend: ✅ done with evidence · 🟡 partly done · ⬜ not started

| # | Criterion | Status | Evidence / what remains |
|---|---|---|---|
| 1 | Shared-mode audio from Apple Music, Spotify, browser and local player reaches the DAC on macOS **and Windows** | 🟡 | macOS: live system audio processed on a USB DAC (`--selftest`). Per-app matrix not documented. Windows not started. |
| 2 | Accurate Processing / DSP bypass / Not processing / Error; no false lossless or bit-perfect claim | ✅ | `EngineStatus` driven by route state, callback liveness, hog mode and the active filter bank; UI copy says "not bit-identical". |
| 3 | Reference HRTF, crossfeed, room-off and bypass presets; gain-matched, click-free; correct channels | ✅ | Tests: level match within 0.13 dB (incl. asymmetric/rear layouts), clarity restores bypass timbre with ILD unchanged, click-free switching, channel mapping, centre and hard-pan integrity. |
| 4 | HRTF assets with redistribution rights and provenance; IEM tiers distinguished and deletable | 🟡 | No dataset bundled; analytic model documented in `assets/hrtf-manifest.json`. Tiers labelled; raw data kept apart; delete works. Licensed measured HRTF and SOFA importer remain. |
| 5 | Objective, stability, latency, CPU, memory, drift, recovery and perceptual gates pass and are archived | 🟡 | DSP objective and CPU gates pass (`docs/test-plan.md`). 8-hour run, measured latency, memory, drift and perceptual study not run. |
| 6 | No allocation, lock, I/O, exception or unbounded work on the audio thread | ✅ | Reviewed: `aether_engine_process` and `AetherIOProc` use preallocated buffers, atomics and bounded loops; banks are freed on the control thread. Not yet checked by instrumentation. |
| 7 | Protected, exclusive, remote and Atmos handled honestly; no DRM circumvention | ✅ | No circumvention; onboarding explains bypass cases; hog mode detected and reported. |
| 8 | Install, upgrade, crash recovery, default-device restoration and uninstall on clean machines | 🟡 | No driver, so nothing to restore: tap and aggregate are process-private and vanish on crash. Unclean-exit marker keeps the engine off. Clean-machine runs not done. |
| 9 | macOS Developer ID signed and notarized; Windows production signed | 🟡 | `scripts/package-macos` builds the universal hardened-runtime DMG and signs, notarizes and staples it when given a Developer ID and notary profile. Current build: ad-hoc only, because no Developer ID certificate is installed. |
| 10 | Security review, fuzzing, SBOM, privacy review, accessibility audit, runbook, rollback, limitations page | 🟡 | Privacy design and limitations documented; sanitizer runs; accessibility implemented but not audited. No fuzzing or SBOM yet (no third-party dependencies). |
| 11 | Source, reproducible builds, pinned dependencies, manifests, fixtures, benchmark, listening report, release notes | 🟡 | Scripts, manifest and benchmark exist. Toolchain not pinned; no listening report. |

## macOS release steps (when a Developer ID is available)

1. Set up notary credentials once: `xcrun notarytool store-credentials aether-notary --apple-id … --team-id …`
2. `AETHER_SIGN_IDENTITY="Developer ID Application: …" AETHER_NOTARY_PROFILE=aether-notary ./scripts/package-macos`
3. Check: `spctl -a -t open --context context:primary-signature -v dist/Aether-<version>.dmg` and `xcrun stapler validate dist/Aether-<version>.dmg`
4. On a clean machine with standard Gatekeeper settings: download, install, launch, run `--selftest`.

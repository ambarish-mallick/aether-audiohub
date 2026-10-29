# Architecture

## Components

| Component | Path | Responsibility | Never does |
|---|---|---|---|
| `dsp-core` | `core/` | Filter design (float64, control thread); partitioned convolution, crossfades, metering (float32, audio thread) | OS calls, file/network I/O, locks or allocation in `process` |
| `route-macos` | `platform/macos/` | Process tap, private aggregate device, IOProc, device/format listeners, route telemetry | UI work or logging in the IOProc |
| `controller` | `apps/macos/Aether/` | SwiftUI UI, presets, settings, IEM profile store, status, recovery | Touch audio buffers |
| `profile design` | `core/src/design.cpp` (`aether_design_*`) | User-tuned EQ curves; regularised correction from imported responses | Run on the audio thread |
| `diagnostics` | `--selftest`, `aether-render`, `aether-bench` | Route smoke test, offline rendering, CPU cost | Record or upload audio |

## Core ABI

`core/include/aether/aether_core.h`: create → submit_config → prepare(rate) → process(…) → read_meters → destroy.

- `process` accepts any frame count and strided channels. Input runs through a B-sample FIFO into the internal block processor, so output is **independent of host buffer chunking** (tested bit-exact).
- `submit_config` validates the configuration (non-finite values or an unknown mode are rejected and the previous snapshot stays active). It designs the 2×2 FIR matrix in float64, transforms it into partition spectra, and publishes it with one atomic exchange. A newer submission replaces an unconsumed one (latest wins).
- The audio thread adopts a pending bank only between crossfades and only when the retire ring has space. Retired banks return over a lock-free SPSC ring and are freed on the control thread. The audio thread never frees memory.
- `prepare` reallocates and rebuilds for a new rate. The route always calls it with the IOProc stopped.

## Fixed latency and exact bypass

All filters include a common alignment delay D0 = 2 ms. Convolution adds one partition B. Bypass is not a filter: it copies the input delayed by exactly B + D0 samples, so bypass is bit-exact and time-aligned with the processed modes. A crossfade between bypass and processing therefore blends two signals on the same timeline, with no comb filtering and no click.

| Rate | B | Latency |
|---|---|---|
| 44.1 / 48 kHz | 256 | 7.8 / 7.3 ms |
| 88.2 / 96 kHz | 512 | 7.8 / 7.3 ms |
| 176.4 / 192 kHz | 1024 | 7.8 / 7.3 ms |

## Safety behaviour

- Non-finite input samples become 0 and are counted.
- A non-finite internal result (for example, overflow from absurd input) clears the convolution state, switches to an engine-owned unity bank, fades in from silence, and raises `safety_bypass` until the next configuration arrives.
- No limiter and no compression. Sample peak and 4× oversampled true peak are metered, and the UI warns above −1 dBTP and at 0 dBFS.

## Route state and recovery (macOS)

- The tap and the aggregate are **private to the Aether process**. If Aether crashes or is force-quit, macOS removes both, and because the tap's mute behaviour is *muted when tapped*, system audio returns to its normal path immediately. There is no virtual device to leave behind as the system default.
- A marker file exists only while the route runs. Finding it at launch means the last session ended uncleanly, so the engine starts **off** and a banner explains why.
- Device removal, sample-rate changes, tap format changes, default-output changes (when following the default), sleep/wake, and IOProc stalls (> 3 s without callbacks) all trigger an orderly stop and a bounded restart. The badge reads **Not processing** with the reason in the meantime.

## Settings

`~/Library/Application Support/Aether/settings.json` (versioned) holds mode, parameters, output UID, onboarding and consent state. IEM profiles live in `iem-profiles.json`: the raw imported response and target are stored apart from the generated correction, and every profile can be deleted. No audio, track titles or account data are ever stored.

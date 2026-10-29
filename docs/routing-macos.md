# macOS routing

## What ships now: process-tap route (macOS 14.4+)

The spec (§4.1) names Core Audio process taps as the *prototype / optional* route. Aether implements this route fully. It needs no driver installation and cannot leave the system in a broken state.

1. `CATapDescription(stereoGlobalTapButExcludeProcesses: [Aether])`, private, `muteBehavior = .mutedWhenTapped`. It captures the stereo mixdown of every process except Aether, so Aether's own output can never feed back. The original destination is muted only while Aether reads the tap.
2. A private aggregate device: the chosen DAC is the main (clock) sub-device and the tap is a sub-tap with drift compensation. The IOProc therefore receives tap input and DAC output buffers in one callback, on one clock. Core Audio handles drift and any tap/DAC rate difference, and the UI shows that conversion.
3. In the IOProc (C++, no allocation, no Objective-C messaging, no locks), the engine processes the tap buffer and the result goes to the DAC's preferred stereo channels. Every other channel is zeroed.

Checks and disclosures:

- The output must be ≥ 2 channels with float32 virtual streams. Hog mode held by another process blocks start, with an explanation.
- Wireless transports (Bluetooth, AirPlay) get a warning.
- If the system default output differs from Aether's output, the UI says the default device is muted while Aether renders elsewhere.
- Reported in the UI and in `--selftest`: tap format and rate, route rate, conversion, the DAC's physical format, stereo channel map, buffer size, device latency, DSP latency, estimated added latency, callback count, overloads, callbacks without tap input, and DSP load.

Listeners: device list and default output (system); device alive and nominal rate (DAC); tap format; processor overload (aggregate). Plus NSWorkspace sleep/wake.

### Verified on

macOS 27.2 (26B5101f), Apple Silicon, MUSE HiFi M3Ultra USB DAC (24-bit integer physical format) at 192 kHz, with system audio playing (`--selftest`):

| Field | Value |
|---|---|
| Callbacks | 1279 in 3.4 s |
| Overloads | 0 |
| Callbacks without tap input | 0 |
| Modes rendered live | bypass, crossfeed, reference |
| DSP load (peak, per buffer) | 11.4% |
| Tap → route rate | 48 kHz → 192 kHz (converted by Core Audio) |
| Estimated added latency | ≈ 10 ms |

## Not yet built: HAL virtual output device (spec production route)

The spec's production default is an Audio Server Driver Plug-in exposing a virtual output, plus a user-space bridge. It is **not** implemented here. That work requires:

- A signed HAL plug-in bundle installed into `/Library/Audio/Plug-Ins/HAL` (administrator consent, then a `coreaudiod` restart).
- A shared-memory SPSC transport with format generations, sequence numbers and timestamps (spec §5.1).
- An installer and uninstaller that restore the prior default output.
- Developer ID signing and notarization.

The `dsp-core` ABI is already route-agnostic, so the bridge would call the same `aether_engine_process`.

Why the tap route is a sound v1 on current macOS: it captures the same shared mix a virtual device would receive. It cannot become a stuck or silent default device. It disappears with the process. And it needs no kernel or privileged installation. Its limits (exclusive-mode apps, protected content) are the same class of limits the spec already lists for the virtual-device route.

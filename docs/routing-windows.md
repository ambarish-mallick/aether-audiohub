# Windows routing — not started

Nothing Windows-specific exists yet. This session ran on macOS, with no Windows machine, WDK, HLK or Microsoft Hardware Developer Program account, so nothing could be built or tested. Per spec §11 ("do not report a SysVAD sample tone as processed application audio"), nothing is claimed.

## Plan (spec §4.2)

1. **Virtual render endpoint** derived from current WDK/SysVAD guidance, implementing a *real* PCM handoff (the SysVAD sample only simulates loopback). Keep only bounded transport code in the kernel.
2. **Bridge service:** shared-mode, event-driven WASAPI on the physical DAC; `IAudioClient3` for period negotiation; MMCSS registration; bounded SPSC ring with format generations; ASRC when the clocks differ (the spec gives the acceptance figures). It calls the same `aether_engine_process`; `core/` builds with any C++20 compiler and has no OS dependencies.
3. **Controller:** WinUI 3 or a native UI mirroring the macOS app's states (Processing / DSP bypass / Not processing / Error), with explicit consent to change the default endpoint and to restore it on uninstall.
4. **Signing:** test-signing for development, then HLK runs and dashboard signing for production. Start early, because it gates distribution.
5. **APO branch:** evaluate only as an endpoint-specific option, never as the system-wide v1 promise.

The DSP core is ready for this: its tests, determinism and ABI are platform-neutral.

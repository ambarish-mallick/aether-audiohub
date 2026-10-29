# Known limitations

- **Stereo in, two virtual speakers out.** Aether places the two channel feeds as loudspeakers. It cannot recover individual instruments or the original multitrack scene.
- **Generic analytic HRTF.** A spherical-head model with tempered pinna cues, not a measured head. Expect some front/back ambiguity and individual differences. Speakers placed behind rely on a modelled rear shelf (a darker tone) plus correct ITD/ILD. Without head tracking, many listeners will still hear rear placements as front or inside the head; the Crossfeed mode exists for listeners who prefer no HRTF colouration. Parameters are tuned starting values, not listening-test-validated optima.
- **No head tracking.** Shown as *Planned*.
- **Bypass routes.** Apps with exclusive (hog-mode) device access, protected streams, remote playback (Spotify Connect, AirPlay to another device) and app-selected outputs may bypass the tap or block rendering. Aether reports *Not processing* where it can detect this.
- **Double spatialisation.** Apple Music Dolby Atmos or other spatial output reaching the system mix will be processed again. Set Atmos to Off, or use Bypass.
- **Rate conversion.** When the tapped mix and the DAC run at different rates, Core Audio's aggregate converts (shown in the Input node). Aether does not run its own ASRC on macOS.
- **Latency.** About 7.3 ms of DSP plus one device buffer; the UI figure is an estimate, not a loopback measurement. Fine for music; noticeable for lip-sync or games.
- **Headroom.** −6 dB is a starting policy. Loud masters with inter-sample overs can exceed −1 dBTP in Reference/Custom; watch the Out meter and lower Headroom. There is deliberately no limiter.
- **Wireless outputs.** Supported but not recommended: the codec re-encodes after processing.
- **Windows.** Not implemented.
- **Signing.** The installer is ad-hoc signed (hardened runtime), not Developer ID signed or notarized. On another Mac, the first launch needs **Open Anyway** in System Settings › Privacy & Security. macOS may also ask again for system-audio permission after an update. Both go away with a Developer ID build (`AETHER_SIGN_IDENTITY` + `AETHER_NOTARY_PROFILE` in `scripts/package-macos`).
- **Intel Macs.** The app is universal, but the x86_64 slice has not been run (no Intel Mac or Rosetta on the build machine).

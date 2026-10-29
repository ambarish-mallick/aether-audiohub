// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
import AetherCore
@preconcurrency import AetherRoute
import AppKit
import Foundation

/// Route smoke test (spec §7.2): `Aether --selftest report.json [--output-uid UID]`.
/// Starts the real route, plays a generated −40 dBFS 1 kHz tone from a separate process
/// (afplay), switches modes live, records what the route saw, stops, writes JSON, exits.
/// No audio is saved; the report holds counters, formats and levels only.
@MainActor
enum SelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("--selftest") }

    static func run() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { exit(2) }
        let reportURL = URL(fileURLWithPath: args[i + 1])
        let uid = args.firstIndex(of: "--output-uid").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            ?? AERoute.systemDefaultOutputUID()
        var report: [String: Any] = ["tool": "Aether route self-test", "version": AppInfo.version,
                                     "date": ISO8601DateFormatter().string(from: Date())]
        func finish(_ ok: Bool) -> Never {
            report["pass"] = ok
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: reportURL)
            }
            exit(ok ? 0 : 1)
        }
        guard let uid else { report["error"] = "no output device"; finish(false) }

        let route = AERoute()
        var cfg = aether_config()
        aether_config_default(&cfg)
        _ = route.submitConfig(&cfg)
        do { try route.start(withOutputUID: uid) } catch {
            report["error"] = error.localizedDescription
            finish(false)
        }

        // Quiet test tone, written to a temporary file and played by a separate process.
        let toneURL = FileManager.default.temporaryDirectory.appendingPathComponent("aether-selftest-tone.wav")
        writeTone(to: toneURL, seconds: 2.5, hz: 1000, dbfs: -40)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [toneURL.path]

        var maxIn: Float = 0, maxOutTP: Float = 0, maxLoad = 0.0
        var generations = Set<UInt32>()
        var modesSeen = Set<Int32>()
        var ticks = 0
        let start = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { try? player.run() }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            MainActor.assumeIsolated {
                ticks += 1
                let t = Date().timeIntervalSince(start)
                let m = route.readMetersReset(true)
                if t > 0.9 {
                    maxIn = max(maxIn, max(m.in_peak.0, m.in_peak.1))
                    maxOutTP = max(maxOutTP, max(m.out_true_peak.0, m.out_true_peak.1))
                }
                generations.insert(m.active_generation)
                modesSeen.insert(m.active_mode)
                let snap = route.snapshot()
                maxLoad = max(maxLoad, snap.loadPeak)
                // Live switches: crossfeed at 1.4 s, bypass at 2.0 s, back to reference at 2.6 s.
                for (at, mode) in [(1.4, AETHER_MODE_CROSSFEED), (2.0, AETHER_MODE_BYPASS), (2.6, AETHER_MODE_REFERENCE)]
                    where t >= at && t < at + 0.05 {
                    var c = cfg
                    c.mode = Int32(mode.rawValue)
                    _ = route.submitConfig(&c)
                }
                guard t >= 3.4 else { return }
                timer.invalidate()
                let info = route.engineInfo()
                report["output_device"] = snap.deviceName
                report["output_transport"] = snap.deviceTransport
                report["output_physical_format"] = snap.physicalFormat
                report["route_sample_rate"] = snap.routeSampleRate
                report["tap_sample_rate"] = snap.tapSampleRate
                report["tap_channels"] = snap.tapChannels
                report["tap_rate_converted"] = snap.tapRateConverted
                report["stereo_channels"] = [snap.leftChannel, snap.rightChannel]
                report["buffer_frames"] = snap.bufferFrames
                report["dsp_latency_frames"] = info.latency_frames
                report["estimated_added_latency_ms"] = snap.estimatedAddedLatencyMs
                report["callbacks"] = snap.callbacks
                report["callbacks_without_tap_input"] = snap.tapMissing
                report["processor_overloads"] = snap.overloads
                report["dsp_load_peak_percent"] = maxLoad * 100
                report["tap_in_peak_dbfs"] = linearToDb(maxIn)
                report["out_true_peak_dbtp"] = linearToDb(maxOutTP)
                report["modes_rendered"] = modesSeen.sorted()
                report["filter_generations_seen"] = generations.count
                route.stop()
                player.terminate()
                try? FileManager.default.removeItem(at: toneURL)
                // Signal at the tap proves capture works; the level only matches the tone
                // when nothing else is playing, so that comparison is informational.
                let signal = linearToDb(maxIn) > -60
                report["tap_signal_present"] = signal
                report["tap_level_matches_tone_only"] = abs(linearToDb(maxIn) + 40) < 4
                if !signal {
                    report["hint"] = "The tap delivered silence. Allow Aether under Privacy & Security → Screen & System Audio Recording and run again."
                }
                finish(snap.callbacks > 0 && snap.overloads == 0 && snap.tapMissing == 0 && signal && modesSeen.count >= 3)
            }
        }
    }

    private static func writeTone(to url: URL, seconds: Double, hz: Double, dbfs: Double) {
        let rate = 48000, frames = Int(seconds * Double(rate))
        let amp = pow(10, dbfs / 20)
        var pcm = Data(capacity: frames * 4)
        for n in 0..<frames {
            let fade = min(1, Double(min(n, frames - n)) / 2400) // 50 ms ramps, no clicks
            let v = Int16((amp * fade * sin(2 * .pi * hz * Double(n) / Double(rate)) * 32767).rounded())
            for _ in 0..<2 { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }
        }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(UInt32(rate)); u32(UInt32(rate * 4)); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); d.append(pcm)
        try? d.write(to: url)
    }
}

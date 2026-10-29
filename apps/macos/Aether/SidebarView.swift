// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
import AetherRoute
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var app: AetherController
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                signalPath
                divider
                levels
                divider
                enhancements
                divider
                safety
                divider
                integrity
                privacyNote
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
        }
        .background(Theme.sidebar.opacity(0.92))
    }

    private var divider: some View { Rectangle().fill(Theme.stroke(contrast)).frame(height: 1) }

    // MARK: Signal path

    private var running: Bool { app.snapshot?.state == .running }

    private var signalPath: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "Signal path")
                Spacer()
                Text(running ? "LIVE" : "IDLE")
                    .font(.system(size: 10, weight: .semibold)).kerning(1.4)
                    .foregroundStyle(running ? Theme.accent : Theme.textSecondary(contrast))
            }
            .padding(.bottom, 12)

            PathNode(icon: "music.note", title: "Input source", value: "System audio",
                     detail: inputDetail, highlighted: false, indicator: app.meters.signalPresent ? Theme.accent : nil)
            connector
            PathNode(icon: "cpu", title: "DSP processing", value: dspValue, detail: dspDetail,
                     highlighted: app.status == .processing, indicator: nil)
            connector
            outputNode
        }
    }

    private var connector: some View {
        HStack {
            Spacer().frame(width: 26)
            VStack(spacing: 0) {
                Rectangle().fill(Theme.accent.opacity(0.35))
                    .frame(width: 1, height: 14)
                    .mask(VStack(spacing: 2) { ForEach(0..<4, id: \.self) { _ in Rectangle().frame(height: 2) } })
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.accent.opacity(0.5))
            }
            Spacer()
        }
        .frame(height: 22)
        .accessibilityHidden(true)
    }

    private var inputDetail: String {
        guard let s = app.snapshot, s.state == .running else { return "Process tap · starts with the engine" }
        var d = String(format: "Process tap · %@ · %u ch float", khz(s.tapSampleRate), s.tapChannels)
        if s.tapRateConverted { d += String(format: " → %@ (Core Audio SRC)", khz(s.routeSampleRate)) }
        if !app.meters.signalPresent { d += "\nNo signal. Playing music? Check Privacy & Security → Screen & System Audio Recording." }
        return d
    }

    private var dspValue: String {
        if app.meters.safetyBypass { return "Safety bypass" }
        return app.settings.mode.longName
    }

    private var dspDetail: String {
        let info = app.engineInfo
        guard info.sample_rate > 0 else { return "32-bit float · fixed latency in every mode" }
        let latMs = 1000 * Double(info.latency_frames) / info.sample_rate
        var parts = [String(format: "%.1f ms", latMs)]
        if app.settings.mode != .bypass && info.filter_taps > 1 {
            parts.insert("\(info.filter_taps.formatted())-tap FIR", at: 0)
        }
        if let s = app.snapshot, s.state == .running {
            parts.append(String(format: "load %.1f%%", s.loadAverage * 100))
        }
        return parts.joined(separator: " · ")
    }

    private var outputNode: some View {
        let dev = app.selectedDevice
        let snap = app.snapshot
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                NodeIcon(icon: "headphones")
                VStack(alignment: .leading, spacing: 4) {
                    Text("OUTPUT DEVICE").font(.system(size: 9.5, weight: .semibold)).kerning(1.4)
                        .foregroundStyle(Theme.textSecondary(contrast))
                    Menu {
                        Button {
                            app.selectOutput(uid: nil)
                        } label: {
                            Text("Follow system default" + (app.settings.outputUID == nil ? "  ✓" : ""))
                        }
                        Divider()
                        ForEach(app.devices, id: \.uid) { d in
                            Button {
                                app.selectOutput(uid: d.uid)
                            } label: {
                                Text("\(d.name) — \(d.transport)" + (app.settings.outputUID == d.uid ? "  ✓" : ""))
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(dev?.name ?? "Not connected").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary(contrast))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Output device: \(dev?.name ?? "not connected")")
                    Text(outputDetail(dev, snap)).font(.system(size: 11)).foregroundStyle(Theme.textSecondary(contrast))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if dev?.isWireless == true {
                WarningLine(text: "Wireless output: a Bluetooth/AirPlay codec re-encodes after Aether. Wired DAC recommended.")
            }
            if let snap, snap.state == .running, !snap.systemDefaultOutputName.isEmpty,
               snap.systemDefaultOutputName != snap.deviceName {
                WarningLine(text: "System output is “\(snap.systemDefaultOutputName)”. Its sound is muted while Aether renders to “\(snap.deviceName)”.",
                            tint: Theme.textSecondary(contrast))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke(contrast)))
    }

    private func outputDetail(_ dev: AEOutputDevice?, _ snap: AERouteSnapshot?) -> String {
        guard let dev else { return "Connect a DAC or choose another output" }
        if let snap, snap.state == .running, snap.deviceUID == dev.uid {
            return String(format: "%@ · %@ · %@ · ch %u/%u · buffer %u", dev.transport, snap.physicalFormat,
                          khz(snap.routeSampleRate), snap.leftChannel, snap.rightChannel, snap.bufferFrames)
        }
        return "\(dev.transport) · \(khz(dev.nominalSampleRate))" + (app.settings.outputUID == nil ? " · system default" : "")
    }

    // MARK: Levels

    private var levels: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Levels")
                Spacer()
                if app.meters.clipped {
                    Tag(text: "CLIP", color: Theme.danger)
                } else if app.meters.overTruePeak {
                    Tag(text: "TP > −1 dBTP", color: Theme.amber)
                }
            }
            MeterRow(label: "In", values: app.meters.inPeak, unit: "dBFS")
            MeterRow(label: "Out", values: app.meters.outTruePeak, unit: "dBTP")
            HStack {
                Text(app.meters.sessionTruePeakMax > -119
                     ? String(format: "Session max %.1f dBTP", app.meters.sessionTruePeakMax) : "Session max —")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(app.meters.sessionTruePeakMax > -1 ? Theme.amber : Theme.textSecondary(contrast))
                Spacer()
                Button("Reset") { app.resetTruePeakHold() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary(contrast))
            }
            if app.meters.nonFiniteInput > 0 {
                WarningLine(text: "\(app.meters.nonFiniteInput) invalid input samples were replaced with silence.")
            }
        }
    }

    // MARK: Enhancements

    private var enhancements: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "Enhancements")
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(get: { app.settings.iemEnabled && app.activeProfile != nil },
                                     set: { on in
                                         if on && app.activeProfile == nil { app.showProfiles = true }
                                         else { app.settings.iemEnabled = on }
                                     })) {
                    RowLabel(title: "IEM compensation", subtitle: profileSubtitle)
                }
                .toggleStyle(AetherSwitchStyle())
                Button(app.profiles.isEmpty ? "Create a profile…" : "Manage profiles…") { app.showProfiles = true }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.accent)
            }
            HStack {
                RowLabel(title: "Head tracking", subtitle: "Future module")
                Spacer()
                Tag(text: "PLANNED", color: Theme.textSecondary(contrast))
            }
            Toggle(isOn: $app.settings.levelMatchBypass) {
                RowLabel(title: "Level-matched bypass",
                         subtitle: app.settings.levelMatchBypass ? String(format: "Bypass trimmed %.1f dB for fair A/B", app.settings.headroom)
                                                                : "Bypass is true unity")
            }
            .toggleStyle(AetherSwitchStyle())
        }
    }

    private var profileSubtitle: String {
        guard let p = app.activeProfile else { return "Per-ear correction · off" }
        return "\(p.name) · \(p.tier.title)"
    }

    // MARK: Safety

    private var safety: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Listening safety")
            AetherSlider(label: "Headroom", value: $app.settings.headroom, range: -18...0, step: 0.5,
                         valueText: String(format: "%.1f dB", app.settings.headroom), captions: ("−18 dB", "", "0 dB"))
            if app.settings.headroom > -3 {
                WarningLine(text: "Little headroom: spatial filtering can create inter-sample overs. Watch the Out meter.")
            } else {
                Text("Fixed pre-gain in processing modes. No limiter, no compression, no loudness boost.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Integrity

    private var integrity: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionLabel(text: "Signal integrity")
            IntegrityLine(text: "32-bit floating-point processing")
            IntegrityLine(text: "No forced loudness boost — modes are K-weighted level-matched")
            IntegrityLine(text: "DSP bypass: unity, delay-compensated")
            IntegrityLine(text: "Processed output is not bit-identical to the source", caution: true)
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield").font(.system(size: 13)).foregroundStyle(Theme.textSecondary(contrast))
            Text("System audio is read only to process it in real time. Nothing is recorded, stored, identified or sent anywhere.")
                .font(.system(size: 11)).foregroundStyle(Theme.textSecondary(contrast))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke(contrast)))
    }
}

func khz(_ hz: Double) -> String {
    guard hz > 0 else { return "—" }
    let k = hz / 1000
    return k == k.rounded() ? String(format: "%.0f kHz", k) : String(format: "%.1f kHz", k)
}

// MARK: - Small components

struct NodeIcon: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let icon: String
    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14))
            .foregroundStyle(Theme.textPrimary.opacity(0.85))
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke(contrast)))
            .accessibilityHidden(true)
    }
}

struct PathNode: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let icon: String
    let title: String
    let value: String
    let detail: String
    let highlighted: Bool
    let indicator: Color?
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NodeIcon(icon: icon)
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).kerning(1.4)
                    .foregroundStyle(Theme.textSecondary(contrast))
                HStack(spacing: 6) {
                    Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    if let indicator {
                        Circle().fill(indicator).frame(width: 6, height: 6).shadow(color: indicator, radius: 3)
                            .accessibilityLabel("Signal present")
                    }
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textSecondary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(highlighted ? Theme.accentDeep.opacity(0.20) : Theme.panel.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(highlighted ? Theme.accent.opacity(0.5) : Theme.stroke(contrast)))
        .accessibilityElement(children: .combine)
    }
}

struct MeterRow: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let label: String
    let values: [Double]
    let unit: String
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary(contrast))
                .frame(width: 26, alignment: .leading)
            VStack(spacing: 4) {
                ForEach(0..<2, id: \.self) { c in bar(values[c]) }
            }
            Text(values.max().map { $0 > -119 ? String(format: "%.1f", $0) : "—" } ?? "—")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 38, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level")
        .accessibilityValue(String(format: "Left %.0f, right %.0f %@", values[0], values[1], unit))
    }

    private func bar(_ db: Double) -> some View {
        GeometryReader { geo in
            let frac = ((db + 60) / 60).clamped(0, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule()
                    .fill(LinearGradient(stops: [.init(color: Theme.accentDeep, location: 0),
                                                 .init(color: Theme.accent, location: 0.8),
                                                 .init(color: Theme.amber, location: 0.95),
                                                 .init(color: Theme.danger, location: 1)],
                                         startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * frac) }
                Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1).offset(x: geo.size.width * (59.0 / 60.0))
            }
        }
        .frame(height: 5)
    }
}

struct RowLabel: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
            Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary(contrast)).lineLimit(2)
        }
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold)).kerning(1.2)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(0.6)))
    }
}

struct WarningLine: View {
    let text: String
    var tint: Color = Theme.amber
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
    }
}

struct IntegrityLine: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let text: String
    var caution = false
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "diamond").font(.system(size: 8, weight: .semibold))
                .foregroundStyle(caution ? Theme.amber.opacity(0.8) : Theme.accent.opacity(0.8))
                .padding(.top, 3)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.textPrimary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

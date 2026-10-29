// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
import AetherCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// IEM profile manager. Three tiers, labelled honestly; raw measurements are stored apart
/// from the generated correction; everything is local and deletable.
struct ProfilesView: View {
    @EnvironmentObject var app: AetherController
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dismiss) private var dismiss

    enum Pane: Equatable { case empty, existing(UUID), userTuned, importing }

    /// Editor state lives in a reference type (`@State` needs the SwiftUI macro plugin,
    /// which Command Line Tools builds do not ship).
    final class Draft: ObservableObject {
        @Published var pane: Pane = .empty
        @Published var name = "My IEM"
        @Published var bass = 0.0
        @Published var presence = 0.0
        @Published var treble = 0.0
        @Published var tier: IEMProfile.Tier = .modelEstimate
        @Published var iemModel = ""
        @Published var eartips = ""
        @Published var notes = ""
        @Published var measurement: (URL, ResponseCSV.Curve)?
        @Published var target: (URL, ResponseCSV.Curve)?
        @Published var reliableHigh = 10000.0
        @Published var importError: String?
    }
    @StateObject private var d = Draft()

    private var pane: Pane { get { d.pane } nonmutating set { d.pane = newValue } }
    private var name: String { d.name }
    private var bass: Double { d.bass }
    private var presence: Double { d.presence }
    private var treble: Double { d.treble }
    private var tier: IEMProfile.Tier { d.tier }
    private var iemModel: String { d.iemModel }
    private var eartips: String { d.eartips }
    private var notes: String { d.notes }
    private var measurement: (URL, ResponseCSV.Curve)? { get { d.measurement } nonmutating set { d.measurement = newValue } }
    private var target: (URL, ResponseCSV.Curve)? { get { d.target } nonmutating set { d.target = newValue } }
    private var reliableHigh: Double { d.reliableHigh }
    private var importError: String? { get { d.importError } nonmutating set { d.importError = newValue } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionLabel(text: "IEM compensation profiles")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Rectangle().fill(Theme.stroke(contrast)).frame(height: 1)
            HStack(spacing: 0) {
                list.frame(width: 230)
                Rectangle().fill(Theme.stroke(contrast)).frame(width: 1)
                ScrollView { detail.padding(20) }.frame(maxWidth: .infinity)
            }
        }
        .frame(width: 780, height: 560)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .onAppear { if let id = app.settings.activeProfileID { pane = .existing(id) } }
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if app.profiles.isEmpty {
                        Text("No profiles yet. Generic (no correction) is used.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary(contrast)).padding(8)
                    }
                    ForEach(app.profiles) { p in
                        Button { pane = .existing(p.id) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(p.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                                    if app.settings.activeProfileID == p.id && app.settings.iemEnabled {
                                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                                    }
                                }
                                Text(p.tier.title).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary(contrast))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 9).fill(pane == .existing(p.id) ? Theme.accentDeep.opacity(0.25) : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }
            VStack(alignment: .leading, spacing: 8) {
                Button { pane = .userTuned } label: { Label("New user-tuned", systemImage: "slider.horizontal.3") }
                Button { pane = .importing } label: { Label("Import response…", systemImage: "square.and.arrow.down") }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(14)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch pane {
        case .empty:
            VStack(alignment: .leading, spacing: 10) {
                Text("Optional per-ear correction").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                ForEach(IEMProfile.Tier.allCases) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(t.explanation).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary(contrast))
                    }
                }
                Text("Corrections are smoothed, limited to +6 / −12 dB, never invert narrow notches, and are realised as minimum-phase filters.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary(contrast)).padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .existing(let id):
            if let p = app.profiles.first(where: { $0.id == id }) { existing(p) }
        case .userTuned: userTunedEditor
        case .importing: importEditor
        }
    }

    private func existing(_ p: IEMProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(p.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Tag(text: p.tier.title.uppercased(), color: p.tier == .userTuned ? Theme.textSecondary(contrast) : Theme.accent)
            }
            Text(p.tier.explanation).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary(contrast))
            CurvePreview(left: p.curveLeft, right: p.curveRight).frame(height: 160)
            VStack(alignment: .leading, spacing: 3) {
                if p.tier == .userTuned {
                    meta("Bass / presence / treble", String(format: "%+.1f / %+.1f / %+.1f dB", p.bass, p.presence, p.treble))
                }
                if let m = p.iemModel, !m.isEmpty { meta("IEM", m) }
                if let t = p.eartips, !t.isEmpty { meta("Ear tips", t) }
                if let f = p.measurementFile { meta("Response file", f) }
                if let f = p.targetFile { meta("Target file", f) }
                if let b = p.maxBoostDb, let c = p.maxCutDb { meta("Range", String(format: "%+.1f … %+.1f dB", c, b)) }
                if let r = p.reliableHighHz { meta("Corrected up to", String(format: "%.1f kHz", r / 1000)) }
                meta("Created", p.created.formatted(date: .abbreviated, time: .shortened))
                if let n = p.notes, !n.isEmpty { meta("Notes", n) }
            }
            HStack {
                Button("Use this profile") { app.activateProfile(p) }
                    .disabled(app.settings.activeProfileID == p.id && app.settings.iemEnabled)
                Spacer()
                Button("Delete", role: .destructive) {
                    app.deleteProfile(p)
                    pane = .empty
                }
            }
            .padding(.top, 6)
        }
    }

    private func meta(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).frame(width: 140, alignment: .leading).foregroundStyle(Theme.textSecondary(contrast))
            Text(v).foregroundStyle(Theme.textPrimary.opacity(0.9))
        }
        .font(.system(size: 11.5))
    }

    // MARK: User-tuned

    private var userCurve: [Float] {
        var out = [Float](repeating: 0, count: Int(AETHER_EQ_POINTS))
        _ = aether_design_user_eq(Float(bass), Float(presence), Float(treble), &out)
        return out
    }

    private var userTunedEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("User-tuned profile").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text(IEMProfile.Tier.userTuned.explanation).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary(contrast))
            TextField("Profile name", text: $d.name).textFieldStyle(.roundedBorder)
            AetherSlider(label: "Bass shelf · 120 Hz", value: $d.bass, range: -6...6, step: 0.5,
                         valueText: String(format: "%+.1f dB", bass))
            AetherSlider(label: "Presence · 3 kHz", value: $d.presence, range: -6...6, step: 0.5,
                         valueText: String(format: "%+.1f dB", presence))
            AetherSlider(label: "Treble shelf · 8 kHz", value: $d.treble, range: -6...6, step: 0.5,
                         valueText: String(format: "%+.1f dB", treble))
            CurvePreview(left: userCurve, right: userCurve).frame(height: 130)
            if bass > 3 || presence > 3 || treble > 3 {
                WarningLine(text: "Boosts above +3 dB reduce headroom. Watch the Out meter.")
            }
            HStack {
                Spacer()
                Button("Save & use") {
                    let curve = userCurve
                    let p = IEMProfile(name: name.isEmpty ? "User-tuned" : name, tier: .userTuned, bass: bass,
                                       presence: presence, treble: treble, curveLeft: curve, curveRight: curve)
                    app.saveProfile(p, activate: true)
                    pane = .existing(p.id)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Import

    private var importEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import a frequency response").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            Text("Text/CSV with frequency (Hz) and level (dB) columns; a third column is read as the right ear. You also need a target curve in the same format — Aether does not choose a target for you.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary(contrast))
            Picker("Tier", selection: $d.tier) {
                Text(IEMProfile.Tier.modelEstimate.title).tag(IEMProfile.Tier.modelEstimate)
                Text(IEMProfile.Tier.measuredPersonal.title).tag(IEMProfile.Tier.measuredPersonal)
            }
            .pickerStyle(.segmented)
            Text(tier.explanation).font(.system(size: 11)).foregroundStyle(Theme.textSecondary(contrast))
            HStack {
                TextField("IEM model", text: $d.iemModel)
                TextField("Ear tips / insertion", text: $d.eartips)
            }
            .textFieldStyle(.roundedBorder)
            TextField("Notes (coupler, date, uncertainty…)", text: $d.notes).textFieldStyle(.roundedBorder)
            HStack {
                Button(measurement == nil ? "Choose response…" : "Response: \(measurement!.0.lastPathComponent)") { pick { measurement = $0 } }
                Button(target == nil ? "Choose target…" : "Target: \(target!.0.lastPathComponent)") { pick { target = $0 } }
            }
            AetherSlider(label: "Correct up to", value: $d.reliableHigh, range: 4000...16000, step: 500,
                         valueText: String(format: "%.1f kHz", reliableHigh / 1000), captions: ("4 kHz", "Treble is fit-sensitive", "16 kHz"))
            if let err = importError { WarningLine(text: err, tint: Theme.danger) }
            if let design = designed {
                CurvePreview(left: design.left, right: design.right).frame(height: 130)
                Text(String(format: "Range %+.1f … %+.1f dB · %.0f%% of points hit the limits · level offset %.1f dB",
                            design.report.max_cut_db, design.report.max_boost_db,
                            design.report.clamped_fraction * 100, design.report.level_offset_db))
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary(contrast))
            }
            HStack {
                Spacer()
                Button("Save & use") { saveImported() }
                    .disabled(designed == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private struct Designed { var left: [Float]; var right: [Float]; var report: aether_correction_report }

    private var designed: Designed? {
        guard let (_, m) = measurement, let (_, t) = target else { return nil }
        func design(_ db: [Float]) -> ([Float], aether_correction_report)? {
            var out = [Float](repeating: 0, count: Int(AETHER_EQ_POINTS))
            var rep = aether_correction_report()
            let rc = aether_design_correction(m.hz, db, Int32(m.hz.count), t.hz, t.left, Int32(t.hz.count),
                                              Float(reliableHigh), &out, &rep)
            return rc == AETHER_OK ? (out, rep) : nil
        }
        guard let (l, rep) = design(m.left) else { return nil }
        let r = m.right.flatMap { design($0)?.0 } ?? l
        return Designed(left: l, right: r, report: rep)
    }

    private func pick(_ done: @escaping ((URL, ResponseCSV.Curve)) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .tabSeparatedText, .text]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            done((url, try ResponseCSV.parse(url)))
            importError = nil
        } catch {
            importError = "\(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func saveImported() {
        guard let d = designed, let (mu, m) = measurement, let (tu, t) = target else { return }
        var p = IEMProfile(name: iemModel.isEmpty ? mu.deletingPathExtension().lastPathComponent : iemModel,
                           tier: tier, curveLeft: d.left, curveRight: d.right)
        p.iemModel = iemModel
        p.eartips = eartips
        p.notes = notes
        p.measurementFile = mu.lastPathComponent
        p.targetFile = tu.lastPathComponent
        p.rawMeasurementHz = m.hz
        p.rawMeasurementLeftDb = m.left
        p.rawMeasurementRightDb = m.right
        p.rawTargetHz = t.hz
        p.rawTargetDb = t.left
        p.maxBoostDb = d.report.max_boost_db
        p.maxCutDb = d.report.max_cut_db
        p.clampedFraction = d.report.clamped_fraction
        p.reliableHighHz = d.report.reliable_high_hz
        app.saveProfile(p, activate: true)
        pane = .existing(p.id)
    }
}

/// Correction curve over 20 Hz – 20 kHz, ±12 dB.
struct CurvePreview: View {
    let left: [Float]
    let right: [Float]
    var body: some View {
        Canvas { ctx, size in
            let range = 12.0
            func y(_ db: Double) -> CGFloat { size.height / 2 - CGFloat(db / range) * size.height / 2 }
            for db in stride(from: -12.0, through: 12.0, by: 6.0) {
                var p = Path(); p.move(to: CGPoint(x: 0, y: y(db))); p.addLine(to: CGPoint(x: size.width, y: y(db)))
                ctx.stroke(p, with: .color(.white.opacity(db == 0 ? 0.18 : 0.06)), lineWidth: 1)
            }
            for f in [100.0, 1000.0, 10000.0] {
                let x = size.width * log(f / 20) / log(1000)
                var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(.white.opacity(0.06)), lineWidth: 1)
                ctx.draw(Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))").font(.system(size: 9)).foregroundColor(.gray),
                         at: CGPoint(x: x + 10, y: size.height - 8))
            }
            for (curve, color) in [(left, Theme.accent), (right, Color(red: 0.62, green: 0.74, blue: 0.98))] where !curve.isEmpty {
                var p = Path()
                for (i, v) in curve.enumerated() {
                    let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(curve.count - 1), y: y(Double(v)))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
                ctx.stroke(p, with: .color(color.opacity(0.9)), lineWidth: 1.6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
        .accessibilityLabel("Correction curve preview, left ear teal, right ear blue")
    }
}

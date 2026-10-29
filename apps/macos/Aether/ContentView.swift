// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AetherController
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                mainPanel
                Rectangle().fill(Theme.stroke(contrast)).frame(width: 1)
                SidebarView().frame(width: 330)
            }
            Rectangle().fill(Theme.stroke(contrast)).frame(height: 1)
            footer
        }
        .background(background)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $app.showOnboarding) { OnboardingView().environmentObject(app) }
        .sheet(isPresented: $app.showProfiles) { ProfilesView().environmentObject(app) }
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Theme.backgroundTop, Theme.background], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.accent.opacity(app.status == .processing ? 0.10 : 0.05), .clear],
                           center: UnitPoint(x: 0.36, y: 0.36), startRadius: 10, endRadius: 420)
        }
        .ignoresSafeArea()
    }

    // MARK: Main panel

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            banners
            VStack(spacing: 6) {
                Text("Give the music room.")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Open the stereo field without exaggerating the space.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textSecondary(contrast))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)

            SoundFieldView(mode: app.settings.mode, leftDegrees: app.settings.azimuthLeft,
                           rightDegrees: app.settings.azimuthRight,
                           speakersOn: app.settings.mode == .custom ? (app.settings.leftEnabled, app.settings.rightEnabled) : (true, true),
                           fold: app.settings.mode == .custom && app.settings.foldMuted,
                           width: app.settings.mode == .custom ? app.settings.width : 1,
                           roomSize: app.settings.mode == .custom ? app.settings.roomSize : .medium,
                           roomLevel: app.settings.roomLevel,
                           room: app.room, crossfeedDelay: app.settings.crossfeedDelay,
                           active: app.status == .processing || app.status == .dspBypass,
                           level: outputActivity,
                           onMoveSpeaker: { side, deg in app.setSpeakerAngle(side: side, degrees: deg) },
                           onToggleSpeaker: { side, on in app.setSpeakerEnabled(side: side, on) })
                .frame(minHeight: 230, maxHeight: .infinity)
                .padding(.vertical, 6)

            HStack(spacing: 12) {
                ForEach(Array(ProcessingMode.allCases.enumerated()), id: \.element.id) { i, mode in
                    ModeCard(mode: mode, selected: app.settings.mode == mode,
                             shortcut: Character(String(i + 1))) { app.select(mode) }
                }
            }
            .padding(.bottom, 14)

            ParametersCard()
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .frame(minWidth: 640)
    }

    private var outputActivity: Double {
        let db = app.meters.outPeak.max() ?? -120
        return ((db + 50) / 44).clamped(0, 1)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("AETHER")
                        .font(.system(size: 17, weight: .semibold))
                        .kerning(5)
                        .foregroundStyle(Theme.textPrimary)
                    Text("SPATIAL ENGINE")
                        .font(.system(size: 10, weight: .semibold)).kerning(1.9)
                        .foregroundStyle(Theme.textSecondary(contrast))
                }
                Text("a project by Ambarish Mallick")
                    .font(.system(size: 10.5, weight: .medium))
                    .italic()
                    .foregroundStyle(Theme.accent.opacity(0.75))
                    .accessibilityLabel("A project by Ambarish Mallick")
            }
            Spacer()
            PillButton(title: "Bypass", isOn: app.settings.mode == .bypass,
                       tint: Color(red: 0.62, green: 0.74, blue: 0.98), systemImage: "slash.circle") {
                app.toggleBypass()
            }
            .keyboardShortcut("b", modifiers: .command)
            .help("Toggle DSP bypass (⌘B)")
            .accessibilityLabel(app.settings.mode == .bypass ? "Bypass on. Activate to resume processing" : "Bypass")
            PillButton(title: app.settings.engineOn ? "Engine On" : "Engine Off", isOn: app.settings.engineOn) {
                app.setEngine(!app.settings.engineOn)
            }
            .keyboardShortcut("e", modifiers: .command)
            .help("Start or stop the system-audio route (⌘E)")
        }
    }

    @ViewBuilder private var banners: some View {
        VStack(spacing: 8) {
            if app.crashedLastSession {
                Banner(icon: "exclamationmark.shield", tint: Theme.amber,
                       text: "Aether did not shut down cleanly last time. The engine was left off and system audio is playing normally.",
                       action: ("Dismiss", { app.crashedLastSession = false }))
            }
            if case .error(let msg) = app.status {
                Banner(icon: "xmark.octagon", tint: Theme.danger, text: msg, action: ("Retry", { app.setEngine(true) }))
            } else if case .notProcessing(let msg) = app.status {
                Banner(icon: "pause.circle", tint: Theme.amber, text: "Not processing — \(msg)", action: nil)
            }
            if app.meters.safetyBypass {
                Banner(icon: "shield.lefthalf.filled", tint: Theme.amber,
                       text: "An invalid internal result triggered the safety bypass. Change any setting to resume processing.", action: nil)
            }
        }
        .padding(.top, 12)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(app.status.color).frame(width: 6, height: 6)
                Text("AETHER \(AppInfo.version)").font(.system(size: 10.5, weight: .semibold)).kerning(1.6)
                    .foregroundStyle(Theme.textSecondary(contrast))
                Text("·").foregroundStyle(Theme.textSecondary(contrast))
                Text("a project by Ambarish Mallick")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.78))
            }
            Spacer()
            Text(app.summary).font(.system(size: 11)).foregroundStyle(Theme.textSecondary(contrast)).lineLimit(1)
            Spacer()
            if let s = app.snapshot, s.state == .running {
                Text(String(format: "≈ %.1f ms added", s.estimatedAddedLatencyMs))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary(contrast))
                    .help("Estimate: DSP latency plus one route buffer. Not a loopback measurement.")
            }
            StatusBadge(status: app.status)
        }
        .padding(.horizontal, 22)
        .frame(height: 42)
        .background(Theme.sidebar.opacity(0.95))
    }
}

struct Banner: View {
    let icon: String
    let tint: Color
    let text: String
    let action: (String, () -> Void)?
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.textPrimary.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.35)))
    }
}

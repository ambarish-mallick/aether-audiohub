// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var app: AetherController
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AETHER").font(.system(size: 22, weight: .semibold)).kerning(7).foregroundStyle(Theme.textPrimary)
                Text("a project by Ambarish Mallick").font(.system(size: 11.5, weight: .medium)).italic()
                    .foregroundStyle(Theme.accent.opacity(0.8))
                Text("Stereo through your IEMs, presented like two speakers in front of you.")
                    .font(.system(size: 14)).foregroundStyle(Theme.textSecondary(contrast)).padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 16) {
                point("waveform.path", "How it works",
                      "When the engine is on, Aether reads the mixed system audio through a private macOS process tap, processes it in 32-bit float, and plays it to the output you choose. The original path is muted only while Aether is reading it — turn the engine off (or quit) and audio returns to normal instantly.")
                point("lock.shield", "Permission",
                      "macOS will ask to allow System Audio Recording for Aether. Audio is processed in real time only — never recorded, stored, identified or sent.")
                point("exclamationmark.triangle", "What can bypass Aether",
                      "Apps with exclusive (hog-mode) device access, protected streams, Spotify Connect / AirPlay playback on another device, and Apple Music Dolby Atmos or other spatial output. For Apple Music, set Dolby Atmos to Off so Aether receives plain stereo and nothing is spatialised twice.")
                point("cable.connector", "Wired is recommended",
                      "Aether targets wired IEMs on a DAC. Bluetooth codecs re-encode the signal after processing.")
            }
            HStack {
                Text("You can switch to DSP bypass any time with ⌘B.").font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary(contrast))
                Spacer()
                Button {
                    app.finishOnboarding()
                } label: {
                    Text("Continue").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 20).padding(.vertical, 9)
                        .background(Capsule().fill(Theme.accent.opacity(0.2)))
                        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.7)))
                        .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 560)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    private func point(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary(contrast))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

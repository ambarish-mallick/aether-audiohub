// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
import SwiftUI

/// Aether's visual language: deep blue-black glass, one mint-teal accent, quiet type.
enum Theme {
    static let background = Color(red: 0.035, green: 0.051, blue: 0.067)
    static let backgroundTop = Color(red: 0.055, green: 0.078, blue: 0.098)
    static let panel = Color(red: 0.067, green: 0.090, blue: 0.110)
    static let panelRaised = Color(red: 0.082, green: 0.110, blue: 0.133)
    static let sidebar = Color(red: 0.047, green: 0.066, blue: 0.082)
    static let accent = Color(red: 0.55, green: 0.89, blue: 0.80)
    static let accentDeep = Color(red: 0.20, green: 0.52, blue: 0.47)
    static let amber = Color(red: 0.98, green: 0.76, blue: 0.38)
    static let danger = Color(red: 1.00, green: 0.45, blue: 0.43)
    static let textPrimary = Color(red: 0.91, green: 0.94, blue: 0.95)

    static func textSecondary(_ contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? Color(white: 0.80) : Color(red: 0.52, green: 0.60, blue: 0.65)
    }
    static func stroke(_ contrast: ColorSchemeContrast) -> Color {
        Color.white.opacity(contrast == .increased ? 0.28 : 0.075)
    }
}

/// Small uppercase tracked label used for section headers.
struct SectionLabel: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(1.9)
            .foregroundStyle(Theme.textSecondary(contrast))
            .accessibilityAddTraits(.isHeader)
    }
}

/// Rounded glass panel.
struct Panel<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var highlighted = false
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(highlighted ? Theme.accentDeep.opacity(0.22) : Theme.panel.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(highlighted ? Theme.accent.opacity(0.55) : Theme.stroke(contrast), lineWidth: 1)
            )
    }
}

/// Capsule toggle used for Engine and Bypass in the header.
struct PillButton: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let title: String
    let isOn: Bool
    var tint: Color = Theme.accent
    var systemImage: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                } else {
                    Circle()
                        .fill(isOn ? tint : Theme.textSecondary(contrast).opacity(0.6))
                        .frame(width: 7, height: 7)
                        .shadow(color: isOn ? tint.opacity(0.9) : .clear, radius: 4)
                }
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(isOn ? Theme.textPrimary : Theme.textSecondary(contrast))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(isOn ? tint.opacity(0.16) : Color.white.opacity(0.03)))
            .overlay(Capsule().strokeBorder(isOn ? tint.opacity(0.6) : Theme.stroke(contrast), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Status badge: PROCESSING / DSP BYPASS / NOT PROCESSING / ERROR / OFF.
struct StatusBadge: View {
    let status: EngineStatus
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.color).frame(width: 6, height: 6)
                .shadow(color: status.color.opacity(0.8), radius: 3)
            Text(status.badge)
                .font(.system(size: 10.5, weight: .bold))
                .kerning(1.4)
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(status.color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(status.color.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(status.spoken)")
    }
}

/// Toggle styled as a compact switch with an accent track.
struct AetherSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                Spacer(minLength: 8)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? Theme.accent.opacity(0.35) : Color.white.opacity(0.08))
                        .overlay(Capsule().strokeBorder(configuration.isOn ? Theme.accent.opacity(0.6) : Color.white.opacity(0.12)))
                        .frame(width: 34, height: 20)
                    Circle()
                        .fill(configuration.isOn ? Theme.accent : Color(white: 0.55))
                        .frame(width: 14, height: 14)
                        .padding(3)
                        .shadow(color: configuration.isOn ? Theme.accent.opacity(0.8) : .clear, radius: 4)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(hi, Swift.max(lo, self)) }
}

func linearToDb(_ v: Float) -> Double { 20 * log10(Swift.max(Double(v), 1e-9)) }

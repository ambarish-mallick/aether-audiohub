// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
import SwiftUI

/// Slider with a filled track and captions. Keyboard: focus with Tab, adjust with ←/→
/// (Shift for 5× steps). VoiceOver: adjustable element with a spoken value.
struct AetherSlider: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String
    var captions: (String, String, String) = ("", "", "")
    var dimmed = false
    var onEdit: ((Double) -> Void)? = nil

    @FocusState private var focused: Bool

    private func set(_ v: Double) {
        let snapped = ((v - range.lowerBound) / step).rounded() * step + range.lowerBound
        let c = snapped.clamped(range.lowerBound, range.upperBound)
        if let onEdit { onEdit(c) } else { value = c }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(valueText).font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(dimmed ? Theme.textSecondary(contrast) : Theme.textPrimary)
            }
            GeometryReader { geo in
                let w = geo.size.width
                let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let x = 9 + CGFloat(frac.clamped(0, 1)) * (w - 18)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.35))
                        .overlay(Capsule().strokeBorder(Theme.stroke(contrast), lineWidth: 1))
                        .frame(height: 8)
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.accentDeep.opacity(0.8), Theme.accent.opacity(dimmed ? 0.35 : 0.85)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(8, x), height: 8)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                        .overlay(Circle().strokeBorder(focused ? Theme.accent : .clear, lineWidth: 2).padding(-3))
                        .offset(x: x - 9)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let f = Double((g.location.x - 9) / max(1, w - 18))
                    set(range.lowerBound + f.clamped(0, 1) * (range.upperBound - range.lowerBound))
                })
            }
            .frame(height: 22)
            if !captions.0.isEmpty || !captions.2.isEmpty {
                HStack {
                    Text(captions.0)
                    Spacer()
                    Text(captions.1)
                    Spacer()
                    Text(captions.2)
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary(contrast).opacity(0.85))
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow, phases: [.down, .repeat]) { press in
            set(value - step * (press.modifiers.contains(.shift) ? 5 : 1)); return .handled
        }
        .onKeyPress(.rightArrow, phases: [.down, .repeat]) { press in
            set(value + step * (press.modifiers.contains(.shift) ? 5 : 1)); return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: set(value + step)
            case .decrement: set(value - step)
            @unknown default: break
            }
        }
    }
}

struct ModeCard: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let mode: ProcessingMode
    let selected: Bool
    let shortcut: Character
    let action: () -> Void
    @StateObject private var hoverBox = HoverBox()
    private var hover: Bool { hoverBox.on }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary(contrast))
                    .frame(height: 22)
                Text(mode.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(mode.subtitle).font(.system(size: 11)).foregroundStyle(Theme.textSecondary(contrast))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(selected ? Theme.accentDeep.opacity(0.28) : Theme.panel.opacity(hover ? 1 : 0.85))
                    .shadow(color: selected ? Theme.accent.opacity(0.18) : .clear, radius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(selected ? Theme.accent.opacity(0.7) : Theme.stroke(contrast), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverBox.on = $0 }
        .keyboardShortcut(KeyEquivalent(shortcut), modifiers: .command)
        .accessibilityLabel("\(mode.longName). \(mode.subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("\(mode.longName) (⌘\(String(shortcut)))")
    }
}

final class HoverBox: ObservableObject { @Published var on = false }

/// Chain toggle joining the two speaker angles. Linked: one symmetric angle.
/// Unlinked: each speaker has its own angle.
struct LinkToggle: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let linked: Bool
    let action: () -> Void
    @StateObject private var hoverBox = HoverBox()

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(linked ? Theme.accent : Theme.textSecondary(contrast))
                if !linked {
                    Capsule()
                        .fill(Theme.textSecondary(contrast))
                        .frame(width: 1.6, height: 19)
                        .rotationEffect(.degrees(-45))
                        .overlay(Capsule().fill(Theme.panel).frame(width: 1.6, height: 19)
                            .rotationEffect(.degrees(-45)).offset(x: 1.4, y: 1.4))
                }
            }
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(linked ? Theme.accentDeep.opacity(0.30) : Color.white.opacity(hoverBox.on ? 0.07 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(linked ? Theme.accent.opacity(0.55) : Theme.stroke(contrast), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverBox.on = $0 }
        .help(linked ? "Linked: both speakers move together. Click to set each speaker’s angle separately."
                     : "Independent angles. Click to link the speakers again (they join at the mean angle).")
        .accessibilityLabel("Link speaker angles")
        .accessibilityValue(linked ? "Linked" : "Independent")
        .accessibilityAddTraits(.isToggle)
    }
}

struct ParametersCard: View {
    @EnvironmentObject var app: AetherController
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    SectionLabel(text: headerTitle)
                    Spacer()
                    headerAccessory
                }
                switch app.settings.mode {
                case .bypass: bypassBody
                case .crossfeed: crossfeedBody
                case .reference, .custom: speakerBody
                }
            }
        }
    }

    private var headerTitle: String {
        switch app.settings.mode {
        case .bypass: "DSP bypass"
        case .crossfeed: "Crossfeed parameters"
        case .reference: "Spatial parameters · reference preset"
        case .custom: "Spatial parameters"
        }
    }

    @ViewBuilder private var headerAccessory: some View {
        if app.settings.mode == .reference || app.settings.mode == .custom {
            HStack(spacing: 8) {
                if app.settings.mode == .custom {
                    Button("Reset") { app.resetCustomToReference() }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary(contrast))
                        .help("Return the custom parameters to the reference values")
                }
                Menu {
                    Button("Both Speakers") { app.setActiveSpeakers(left: true, right: true) }
                    Button("Left Speaker Only") { app.setActiveSpeakers(left: true, right: false) }
                    Button("Right Speaker Only") { app.setActiveSpeakers(left: false, right: true) }
                    Divider()
                    Toggle("Play the Muted Channel Through the Other Speaker", isOn: Binding(
                        get: { app.settings.foldMuted },
                        set: { v in app.editSpeakerParameter { $0.foldMuted = v } }))
                        .disabled(app.settings.mode != .custom || (app.settings.leftEnabled && app.settings.rightEnabled))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: speakersIcon).font(.system(size: 10.5, weight: .semibold))
                        Text(speakersLabel).font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke(contrast)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Active speakers")
                .accessibilityValue(speakersLabel + (speakersState != (true, true) && app.settings.foldMuted ? ", both channels" : ""))
                .help("Play both virtual speakers or switch one off")
                Menu {
                    ForEach(RoomSize.allCases) { size in
                        Button(size.title) { app.editSpeakerParameter { $0.roomSize = size } }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(roomSizeLabel).font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke(contrast)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Room size")
            }
        }
    }

    private var speakersState: (Bool, Bool) {
        app.settings.mode == .custom ? (app.settings.leftEnabled, app.settings.rightEnabled) : (true, true)
    }

    private var speakersLabel: String {
        switch speakersState {
        case (true, false): "Left only"
        case (false, true): "Right only"
        default: "Both speakers"
        }
    }

    private var speakersIcon: String {
        if speakersState == (true, true) { return "hifispeaker.2" }
        return app.settings.foldMuted ? "arrow.triangle.merge" : "hifispeaker"
    }

    private var roomSizeLabel: String {
        let size = app.settings.mode == .reference ? RoomSize.medium : app.settings.roomSize
        let level = app.settings.mode == .reference ? 0.3 : app.settings.roomLevel
        return size.title.replacingOccurrences(of: " room", with: "") + " · " + (level == 0 ? "Dry" : "Early reflections")
    }

    private var speakerBody: some View {
        let isRef = app.settings.mode == .reference
        let left = isRef ? 30 : app.settings.azimuthLeft
        let right = isRef ? 30 : app.settings.azimuthRight
        let linked = isRef || app.settings.speakersLinked
        let room = isRef ? 0.3 : app.settings.roomLevel
        let width = isRef ? 1.0 : app.settings.width
        let clarity = isRef ? 1.0 : app.settings.clarity
        let (leftOn, rightOn) = speakersState
        let angleCaptions = ("0° front", "180° behind", "360°")
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                if linked {
                    AetherSlider(label: "Speaker angle", value: .constant(left), range: 0...360, step: 1,
                                 valueText: String(format: "±%.0f° · %@", left, SpeakerAngle.linkedPosition(left)),
                                 captions: angleCaptions,
                                 onEdit: { v in app.setSpeakerAngle(side: 0, degrees: v) })
                } else {
                    AetherSlider(label: "Left speaker", value: .constant(left), range: 0...360, step: 1,
                                 valueText: String(format: "%.0f° · %@", left,
                                                   SpeakerAngle.position(SpeakerAngle.azimuth(side: 0, degrees: left))),
                                 captions: angleCaptions, dimmed: !leftOn,
                                 onEdit: { v in app.setSpeakerAngle(side: 0, degrees: v) })
                    AetherSlider(label: "Right speaker", value: .constant(right), range: 0...360, step: 1,
                                 valueText: String(format: "%.0f° · %@", right,
                                                   SpeakerAngle.position(SpeakerAngle.azimuth(side: 1, degrees: right))),
                                 captions: angleCaptions, dimmed: !rightOn,
                                 onEdit: { v in app.setSpeakerAngle(side: 1, degrees: v) })
                }
                LinkToggle(linked: linked) {
                    if isRef { app.editSpeakerParameter { $0.speakersLinked = false } }
                    else { app.setSpeakersLinked(!linked) }
                }
            }
            HStack(alignment: .top, spacing: 22) {
                AetherSlider(label: "Room presence", value: .constant(room), range: 0...1, step: 0.01,
                             valueText: room == 0 ? "Dry" : String(format: "%.0f%%", room * 100),
                             captions: ("Anechoic", "Early reflections", "Live"),
                             onEdit: { v in app.editSpeakerParameter { $0.roomLevel = v } })
                AetherSlider(label: "Stereo width", value: .constant(width), range: 0.75...1.25, step: 0.01,
                             valueText: String(format: "%.0f%%", width * 100), captions: ("Narrower", "Unchanged", "Wider"),
                             onEdit: { v in app.editSpeakerParameter { $0.width = v } })
            }
            AetherSlider(label: "Clarity", value: .constant(clarity), range: 0...1, step: 0.01,
                         valueText: String(format: "%.0f%%", clarity * 100),
                         captions: ("Coloured", "Tonal balance", "Crisp · matches bypass"),
                         onEdit: { v in app.editSpeakerParameter { $0.clarity = v } })
            HStack(spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 11))
                Text(footnote).font(.system(size: 11))
            }
            .foregroundStyle(Theme.textSecondary(contrast))
        }
    }

    private var footnote: String {
        if app.settings.mode == .reference { return "Reference is the validated starting point. Moving a control or dragging a speaker switches to Custom." }
        if app.settings.leftEnabled != app.settings.rightEnabled {
            let off = app.settings.leftEnabled ? "right" : "left"
            return app.settings.foldMuted
                ? "The \(off) speaker is off; both channels play through the other speaker (−3 dB each), loudness-matched."
                : "The \(off) speaker is off, so the \(off) channel is not heard. Turn on “Play the muted channel” to keep it."
        }
        if app.settings.width > 1.04 { return "Width above 100% raises side energy and can weaken mono compatibility." }
        if app.settings.clarity < 0.6 { return "Lower clarity keeps more of the HRTF's own colouration, which can sound duller on IEMs." }
        if app.room.count > 0 {
            return String(format: "%d reflections, %.1f–%.1f ms after the direct sound · direct %+.1f dB over reflections",
                          app.room.count, app.room.firstMs, app.room.lastMs, app.room.drrDb)
        }
        return "Dry: direct sound only, no room cues."
    }

    private var crossfeedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            AetherSlider(label: "Cross-feed level", value: $app.settings.crossfeedLevel, range: -15 ... -3, step: 0.5,
                         valueText: String(format: "%.1f dB", app.settings.crossfeedLevel), captions: ("Subtle", "", "Strong"))
            AetherSlider(label: "Cross-path low-pass", value: $app.settings.crossfeedCutoff, range: 500...2000, step: 10,
                         valueText: String(format: "%.0f Hz", app.settings.crossfeedCutoff), captions: ("Darker", "", "Brighter"))
            AetherSlider(label: "Cross-path delay", value: $app.settings.crossfeedDelay, range: 0.1...0.6, step: 0.01,
                         valueText: String(format: "%.2f ms", app.settings.crossfeedDelay), captions: ("0.1 ms", "Head size", "0.6 ms"))
            HStack(spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 11))
                Text("Shelving crossfeed keeps centre-mono flat while easing hard-panned fatigue. No HRTF colouration.")
                    .font(.system(size: 11))
            }
            .foregroundStyle(Theme.textSecondary(contrast))
        }
    }

    private var bypassBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audio passes through the DSP core unchanged: unity gain, channel order preserved, delay-compensated so switching back stays time-aligned.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Text(app.settings.levelMatchBypass
                 ? String(format: "Level-matched compare is on: bypass is trimmed by %.1f dB to match the processing modes. Turn it off in Enhancements for true unity.", app.settings.headroom)
                 : "Unity bypass. macOS may still mix or resample before Aether, so this is “DSP bypass”, not a bit-perfect claim.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary(contrast))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

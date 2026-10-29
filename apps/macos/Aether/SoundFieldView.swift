// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
import SwiftUI

/// Top view of the virtual sound field. Speaker positions, the room outline and every
/// early-reflection image source come from the same model the DSP core renders.
/// In the speaker modes either speaker can be dragged anywhere around the listener.
struct SoundFieldView: View {
    let mode: ProcessingMode
    let leftDegrees: Double   // 0…360 from the front toward the left
    let rightDegrees: Double  // 0…360 from the front toward the right
    let speakersOn: (Bool, Bool)
    let fold: Bool            // a switched-off speaker's channel plays through the other one
    let width: Double         // mid/side width, 1 = unchanged
    let roomSize: RoomSize
    let roomLevel: Double
    let room: RoomInfo
    let crossfeedDelay: Double
    let active: Bool
    let level: Double // 0…1 output activity
    var onMoveSpeaker: ((Int, Double) -> Void)? = nil
    var onToggleSpeaker: ((Int, Bool) -> Void)? = nil

    @StateObject private var anim = FieldAnimator()
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var draggable: Bool { onMoveSpeaker != nil && (mode == .reference || mode == .custom) }
    private var shownDegrees: (Double, Double) { mode == .custom ? (leftDegrees, rightDegrees) : (30, 30) }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 40.0, paused: reduceMotion && !anim.isMoving)) { timeline in
                Canvas { ctx, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    anim.step(to: targets, at: t)
                    draw(&ctx, size: size, time: t)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in drag(to: g.location, start: g.startLocation, size: geo.size) }
                .onEnded { _ in anim.dragging = nil })
            .help(draggable ? "Drag a speaker to place it anywhere around you. Right-click to switch a speaker off." : "")
            .contextMenu {
                if draggable, let toggle = onToggleSpeaker {
                    Button(speakersOn.0 ? "Switch Left Speaker Off" : "Switch Left Speaker On") { toggle(0, !speakersOn.0) }
                        .disabled(speakersOn.0 && !speakersOn.1)
                    Button(speakersOn.1 ? "Switch Right Speaker Off" : "Switch Right Speaker On") { toggle(1, !speakersOn.1) }
                        .disabled(speakersOn.1 && !speakersOn.0)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Virtual sound field, top view")
        .accessibilityValue(accessibilityDescription)
    }

    /// Room walls in units of the speaker-ring radius. Across the room the scale is
    /// metric (1 m = 0.65 ring radii, the floor grid); front to back it is foreshortened,
    /// as in a tilted floor plan, with the walls kept clear of the speaker ring.
    private var roomTargets: (half: Double, front: Double, back: Double) {
        let w = room.widthM > 0 ? room.widthM : 5.5, d = room.depthM > 0 ? room.depthM : 7
        return (w / 2 * FieldAnimator.metre, max(0.6 * d * FieldAnimator.depthMetre, 1.12),
                max(0.4 * d * FieldAnimator.depthMetre, 1.12))
    }

    private var targets: FieldAnimator.Targets {
        let (l, r) = shownDegrees
        let walls = roomTargets
        var t = FieldAnimator.Targets(left: -90, right: 90, radius: 0, room: 0, crossfeed: 0, width: 1,
                                      leftOn: 1, rightOn: 1, roomHalf: walls.half, roomFront: walls.front,
                                      roomBack: walls.back)
        switch mode {
        case .bypass: break
        case .crossfeed: t.crossfeed = 1
        case .reference: t.left = -30; t.right = 30; t.radius = 1; t.room = 1
        case .custom:
            t.left = SpeakerAngle.azimuth(side: 0, degrees: l)
            t.right = SpeakerAngle.azimuth(side: 1, degrees: r)
            t.radius = 1
            t.room = roomLevel > 0 ? 1 : 0
            t.width = width
            t.leftOn = speakersOn.0 ? 1 : 0
            t.rightOn = speakersOn.1 ? 1 : 0
        }
        return t
    }

    private var accessibilityDescription: String {
        switch mode {
        case .bypass: return "Bypass: stereo plays inside the head, unprocessed."
        case .crossfeed: return "Crossfeed: a little low-passed sound from each channel reaches the opposite ear."
        default:
            let (l, r) = shownDegrees
            func describe(_ name: String, _ deg: Double, _ side: Int, _ on: Bool) -> String {
                on ? String(format: "%@ speaker %.0f degrees, %@", name, deg,
                            SpeakerAngle.position(SpeakerAngle.azimuth(side: side, degrees: deg)))
                   : "\(name) speaker off" + (fold ? ", its channel plays through the other speaker" : "")
            }
            return describe("Left", l, 0, speakersOn.0) + ". " + describe("Right", r, 1, speakersOn.1) +
                String(format: ". Stereo width %.0f percent", width * 100) +
                (room.count > 0 ? ", \(roomSize.title.lowercased()) with \(room.count) early reflections." : ", dry room.")
        }
    }

    /// Listener centre and ring radius. The field moves up and shrinks a little as a
    /// speaker goes behind the listener, so the whole circle stays in view.
    private static func layout(_ size: CGSize, rear: Double) -> (CGPoint, CGFloat) {
        let rs = min(size.width * 0.30, size.height * (0.56 - 0.22 * rear))
        return (CGPoint(x: size.width / 2, y: size.height * (0.66 - 0.18 * rear)), rs)
    }

    private func speakerPoints(_ size: CGSize) -> [CGPoint] {
        let (c, rs) = Self.layout(size, rear: anim.rear)
        let ear: CGFloat = 26 + 6 + 16
        return [anim.left, anim.right].enumerated().map { i, az in
            let a = az * .pi / 180
            let onRing = CGPoint(x: c.x + rs * sin(a), y: c.y - rs * cos(a))
            let atEar = CGPoint(x: c.x + (i == 0 ? -ear : ear), y: c.y)
            let k = anim.radius
            return CGPoint(x: atEar.x + (onRing.x - atEar.x) * k, y: atEar.y + (onRing.y - atEar.y) * k)
        }
    }

    private func drag(to p: CGPoint, start: CGPoint, size: CGSize) {
        guard draggable, let move = onMoveSpeaker else { return }
        if anim.dragging == nil {
            let pts = speakerPoints(size)
            let d = pts.map { hypot($0.x - start.x, $0.y - start.y) }
            guard let i = d.indices.min(by: { d[$0] < d[$1] }), d[i] < 30 else { anim.dragging = -1; return }
            anim.dragging = i
        }
        guard let side = anim.dragging, side >= 0 else { return }
        let (c, _) = Self.layout(size, rear: anim.rear)
        let az = atan2(p.x - c.x, c.y - p.y) * 180 / .pi
        move(side, SpeakerAngle.degrees(side: side, azimuth: az))
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, time: Double) {
        let secondary = Theme.textSecondary(contrast)
        let (c, rs) = Self.layout(size, rear: anim.rear)
        let dim = active ? 1.0 : 0.45
        let headR: CGFloat = 26
        let earOffset: CGFloat = headR + 6

        // Guide rings
        for (f, dash) in [(0.42, [2.0, 5.0]), (0.72, [3.0, 6.0]), (1.0, []), (1.3, [1.0, 7.0])] as [(Double, [CGFloat])] {
            let r = rs * f
            let path = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.stroke(path, with: .color(.white.opacity((dash.isEmpty ? 0.07 : 0.06) * (contrast == .increased ? 2.5 : 1))),
                       style: StrokeStyle(lineWidth: 1, dash: dash))
        }

        // Room: floor, 1 m grid and walls. Small, medium and large differ in how far the
        // walls stand from the listener and in how many metres of floor they enclose.
        if anim.room > 0.01 {
            let a = anim.room * dim
            let rect = CGRect(x: c.x - anim.roomHalf * rs, y: c.y - anim.roomFront * rs,
                              width: 2 * anim.roomHalf * rs, height: (anim.roomFront + anim.roomBack) * rs)
            let floor = Path(roundedRect: rect, cornerRadius: 12, style: .continuous)
            ctx.fill(floor, with: .linearGradient(Gradient(colors: [Theme.accent.opacity(0.055 * a), Theme.accent.opacity(0.015 * a)]),
                                                  startPoint: CGPoint(x: c.x, y: rect.minY), endPoint: CGPoint(x: c.x, y: rect.maxY)))
            var grid = ctx
            grid.clip(to: floor)
            let gx = FieldAnimator.metre * rs, gy = FieldAnimator.depthMetre * rs
            var lines = Path()
            var k = 1.0
            while k * gx < anim.roomHalf * rs {
                for x in [c.x - k * gx, c.x + k * gx] {
                    lines.move(to: CGPoint(x: x, y: rect.minY)); lines.addLine(to: CGPoint(x: x, y: rect.maxY))
                }
                k += 1
            }
            lines.move(to: CGPoint(x: c.x, y: rect.minY)); lines.addLine(to: CGPoint(x: c.x, y: rect.maxY))
            var y = c.y - (anim.roomFront * rs / gy).rounded(.down) * gy
            while y < rect.maxY {
                lines.move(to: CGPoint(x: rect.minX, y: y)); lines.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += gy
            }
            grid.stroke(lines, with: .color(Theme.accent.opacity(0.045 * a)), lineWidth: 1)
            ctx.stroke(floor, with: .color(Theme.accent.opacity(0.34 * a)), lineWidth: 1.6)
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: 5, dy: 5), cornerRadius: 8, style: .continuous),
                       with: .color(Theme.accent.opacity(0.12 * a)), lineWidth: 1)

            // Room label
            let name = Text(roomSize.title.uppercased()).font(.system(size: 10, weight: .bold)).kerning(1.6)
                .foregroundColor(Theme.accent.opacity(0.85 * anim.room))
            let dims = Text(String(format: "%.1f × %.1f m · %.1f m ceiling", room.widthM, room.depthM, room.heightM))
                .font(.system(size: 10).monospacedDigit()).foregroundColor(secondary.opacity(anim.room))
            ctx.draw(name, at: CGPoint(x: 6, y: 8), anchor: .topLeading)
            ctx.draw(dims, at: CGPoint(x: 6, y: 23), anchor: .topLeading)
        }

        // Early-reflection image sources
        if anim.room > 0.01 {
            for d in room.dots {
                let a = d.azimuth * .pi / 180
                let r = rs * (1.0 + d.delayMs / 40.0 * 0.95)
                let p = CGPoint(x: c.x + r * sin(a), y: c.y - r * cos(a))
                let s = 2.0 + min(1, d.gain * 5) * 5
                let alpha = (0.12 + min(1, d.gain * 6) * 0.55) * anim.room * dim
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)),
                         with: .color(Theme.accent.opacity(alpha)))
            }
        }

        // Speaker geometry (animated): radius factor 0 → at the ears, 1 → on the ring.
        let spk = speakerPoints(size)
        let ears = [CGPoint(x: c.x - earOffset, y: c.y), CGPoint(x: c.x + earOffset, y: c.y)]

        // Arc joining the virtual speakers, clockwise from the left speaker to the right one.
        if anim.radius > 0.3 {
            var span = (anim.right - anim.left).truncatingRemainder(dividingBy: 360)
            if span < 0 { span += 360 }
            if span > 0.5 {
                var arc = Path()
                let start = (-90 + anim.left) * .pi / 180
                arc.addArc(center: c, radius: rs, startAngle: .radians(start - 0.14),
                           endAngle: .radians(start + span * .pi / 180 + 0.14), clockwise: false)
                ctx.stroke(arc, with: .color(Theme.accent.opacity(0.35 * anim.radius * dim)), lineWidth: 1.5)
            }
        }

        // Stereo image between the speakers: its spread follows the width control.
        // Anything pushed past the speakers (width above 100 %) is drawn in amber.
        let bothOn = min(anim.leftOn, anim.rightOn)
        if anim.radius > 0.3 && bothOn > 0.01 {
            var span = (anim.right - anim.left).truncatingRemainder(dividingBy: 360)
            if span < 0 { span += 360 }
            if span > 2 {
                let mid = anim.left + span / 2, half = span / 2 * anim.width, edge = span / 2
                let r = rs * 0.80
                let a = anim.radius * bothOn * dim
                func arc(_ from: Double, _ to: Double) -> Path {
                    var p = Path()
                    p.addArc(center: c, radius: r, startAngle: .degrees(-90 + from), endAngle: .degrees(-90 + to), clockwise: false)
                    return p
                }
                ctx.stroke(arc(mid - edge, mid + edge), with: .color(.white.opacity(0.14 * a)),
                           style: StrokeStyle(lineWidth: 1, dash: [1, 4]))
                let inner = min(half, edge)
                ctx.stroke(arc(mid - inner, mid + inner), with: .color(Theme.accent.opacity(0.15 * a)),
                           style: StrokeStyle(lineWidth: 10, lineCap: .round))
                ctx.stroke(arc(mid - inner, mid + inner), with: .color(Theme.accent.opacity(0.5 * a)), lineWidth: 1.2)
                if half > edge + 0.3 {
                    for (from, to) in [(mid - half, mid - edge), (mid + edge, mid + half)] {
                        ctx.stroke(arc(from, to), with: .color(Theme.amber.opacity(0.22 * a)),
                                   style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        ctx.stroke(arc(from, to), with: .color(Theme.amber.opacity(0.7 * a)), lineWidth: 1.2)
                    }
                }
                for k in [-1.0, -0.5, 0, 0.5, 1] {
                    let ang = (mid + k * half) * .pi / 180
                    let pt = CGPoint(x: c.x + r * sin(ang), y: c.y - r * cos(ang))
                    let beyond = abs(k * half) > edge + 0.3
                    let s: CGFloat = k == 0 ? 6 : 4
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - s / 2, y: pt.y - s / 2, width: s, height: s)),
                             with: .color((beyond ? Theme.amber : Theme.accent).opacity(0.9 * a)))
                }
                let ang = mid * .pi / 180, lr = r - 17
                let tint = width > 1.005 ? Theme.amber : width < 0.995 ? Theme.accent : secondary
                ctx.draw(Text(String(format: "WIDTH %.0f%%", width * 100)).font(.system(size: 9, weight: .bold).monospacedDigit())
                    .kerning(1.2).foregroundColor(tint.opacity(0.9 * a)),
                         at: CGPoint(x: c.x + lr * sin(ang), y: c.y - lr * cos(ang)))
            }
        }

        // Front marker on the ring
        if anim.radius > 0.3 {
            let tick = Path { p in
                p.move(to: CGPoint(x: c.x, y: c.y - rs - 7))
                p.addLine(to: CGPoint(x: c.x, y: c.y - rs + 7))
            }
            ctx.stroke(tick, with: .color(.white.opacity(0.18 * anim.radius)), lineWidth: 1)
        }

        // Paths speaker → ears (the ear on the speaker's side strong, the far ear faint)
        let azimuths = [anim.left, anim.right]
        let onLevel = [anim.leftOn, anim.rightOn]
        for s in 0..<2 where anim.radius > 0.05 && onLevel[s] > 0.01 {
            for e in 0..<2 {
                var p = Path()
                p.move(to: spk[s])
                p.addLine(to: ears[e])
                let side = anim.radius > 0.5 ? (sin(azimuths[s] * .pi / 180) >= 0 ? 1 : 0) : s
                let ipsi = side == e
                ctx.stroke(p, with: .color(Theme.accent.opacity((ipsi ? 0.55 : 0.16) * anim.radius * onLevel[s] * dim)),
                           style: StrokeStyle(lineWidth: ipsi ? 1.3 : 1, dash: [3, 4]))
            }
        }
        // Crossfeed: low-passed cross-ear paths curving over the head
        if anim.crossfeed > 0.01 {
            for s in 0..<2 {
                var p = Path()
                p.move(to: spk[s])
                p.addQuadCurve(to: ears[1 - s], control: CGPoint(x: c.x, y: c.y - headR * 5.5))
                ctx.stroke(p, with: .color(Theme.accent.opacity(0.7 * anim.crossfeed * dim)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
            }
        }

        // Fold: the switched-off speaker's channel travels to the speaker still playing.
        if fold && anim.radius > 0.5, abs(anim.leftOn - anim.rightOn) > 0.5 {
            let off = anim.leftOn < anim.rightOn ? 0 : 1
            let from = spk[off], to = spk[1 - off]
            let m = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            let ctl = CGPoint(x: m.x + (c.x - m.x) * 0.45, y: m.y + (c.y - m.y) * 0.45)
            var p = Path()
            p.move(to: from)
            p.addQuadCurve(to: to, control: ctl)
            ctx.stroke(p, with: .color(Theme.accent.opacity(0.55 * dim)), style: StrokeStyle(lineWidth: 1.3, dash: [4, 4]))
            let dx = to.x - ctl.x, dy = to.y - ctl.y, len = max(1, hypot(dx, dy))
            let ux = dx / len, uy = dy / len
            let tip = CGPoint(x: to.x - ux * 18, y: to.y - uy * 18)
            var head = Path()
            head.move(to: CGPoint(x: tip.x - ux * 7 - uy * 4, y: tip.y - uy * 7 + ux * 4))
            head.addLine(to: tip)
            head.addLine(to: CGPoint(x: tip.x - ux * 7 + uy * 4, y: tip.y - uy * 7 - ux * 4))
            ctx.stroke(head, with: .color(Theme.accent.opacity(0.7 * dim)), lineWidth: 1.3)
        }

        // Emission rings driven by output activity
        if active && !reduceMotion {
            for s in 0..<2 where onLevel[s] > 0.5 {
                for k in 0..<3 {
                    let phase = (time * 0.55 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                    let r = 14 + phase * (40 + 30 * anim.radius)
                    let alpha = (1 - phase) * 0.32 * level
                    ctx.stroke(Path(ellipseIn: CGRect(x: spk[s].x - r, y: spk[s].y - r, width: 2 * r, height: 2 * r)),
                               with: .color(Theme.accent.opacity(alpha)), lineWidth: 1)
                }
            }
        }

        // Speakers (a switched-off speaker is drawn as a dashed outline)
        for (i, p) in spk.enumerated() {
            let on = onLevel[i]
            let glow = Path(ellipseIn: CGRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44))
            ctx.fill(glow, with: .radialGradient(Gradient(colors: [Theme.accent.opacity(0.35 * dim * on), .clear]),
                                                 center: p, startRadius: 2, endRadius: 24))
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 15, y: p.y - 15, width: 30, height: 30)),
                       with: .color(Theme.accent.opacity((0.45 + 0.3 * on) * dim)),
                       style: StrokeStyle(lineWidth: 1.4, dash: on > 0.5 ? [] : [3, 3]))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                     with: .color(Theme.panelRaised))
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                       with: .color(Theme.accent.opacity(0.5 * dim * on)), lineWidth: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)),
                     with: .color(Theme.accent.opacity(0.95 * dim * on)))
            if on < 0.99 {
                var slash = Path()
                slash.move(to: CGPoint(x: p.x - 7, y: p.y + 7))
                slash.addLine(to: CGPoint(x: p.x + 7, y: p.y - 7))
                ctx.stroke(slash, with: .color(secondary.opacity((1 - on) * dim)), lineWidth: 1.4)
            }
            if anim.radius > 0.5 {
                let deg = i == 0 ? shownDegrees.0 : shownDegrees.1
                let label = on < 0.5 ? String(format: "%@ OFF", i == 0 ? "L" : "R")
                    : String(format: "%@ %.0f°", i == 0 ? "L" : "R", deg)
                let text = Text(label).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(anim.dragging == i ? Theme.accent : secondary)
                let dx = p.x - c.x, dy = p.y - c.y, len = max(1, hypot(dx, dy))
                ctx.draw(text, at: CGPoint(x: p.x + dx / len * 38, y: p.y + dy / len * 30), anchor: .center)
            } else {
                let text = Text(i == 0 ? "L" : "R").font(.system(size: 10, weight: .bold)).foregroundColor(secondary)
                ctx.draw(text, at: CGPoint(x: p.x, y: p.y + 24), anchor: .center)
            }
        }

        // Listener
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - headR - 12, y: c.y - headR - 12, width: 2 * headR + 24, height: 2 * headR + 24)),
                 with: .radialGradient(Gradient(colors: [Theme.accent.opacity(0.10), .clear]), center: c, startRadius: headR, endRadius: headR + 14))
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - headR, y: c.y - headR, width: 2 * headR, height: 2 * headR)),
                   with: .color(.white.opacity(0.22)), lineWidth: 1.2)
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - headR + 6, y: c.y - headR + 6, width: 2 * headR - 12, height: 2 * headR - 12)),
                 with: .color(Theme.panelRaised))
        let person = Image(systemName: "person.fill")
        ctx.draw(Text(person).font(.system(size: 20)).foregroundColor(Theme.accent.opacity(0.85)), at: c)
        for e in ears {
            ctx.fill(Path(ellipseIn: CGRect(x: e.x - 3.5, y: e.y - 3.5, width: 7, height: 7)),
                     with: .color(Theme.accent.opacity(0.9)))
        }
        ctx.draw(Text("LISTENER").font(.system(size: 10, weight: .semibold)).kerning(1.6).foregroundColor(secondary),
                 at: CGPoint(x: c.x, y: c.y + headR + 20))

        // Caption
        let caption: String
        switch mode {
        case .bypass: caption = "IN-HEAD STEREO · NO SPATIAL PROCESSING"
        case .crossfeed: caption = String(format: "EAR-TO-EAR BLEND · %.2f MS CROSS DELAY", crossfeedDelay)
        default:
            caption = room.count > 0
                ? String(format: "VIRTUAL SOUND FIELD · %d EARLY REFLECTIONS · %.0f–%.0f MS", room.count, room.firstMs, room.lastMs)
                : "VIRTUAL SOUND FIELD · DRY ROOM"
        }
        ctx.draw(Text(caption).font(.system(size: 9.5, weight: .semibold)).kerning(1.6).foregroundColor(secondary.opacity(0.85)),
                 at: CGPoint(x: size.width / 2, y: size.height - 10))
    }
}

/// Frame-rate-independent smoothing of the drawn geometry toward the current mode.
/// Speaker azimuths (clockwise from the front) take the shorter way around the circle.
final class FieldAnimator: ObservableObject {
    /// Drawing scale of the room plan, in speaker-ring radii per metre (across / front to back).
    static let metre = 0.65, depthMetre = 0.39

    struct Targets {
        var left, right, radius, room, crossfeed, width, leftOn, rightOn: Double
        var roomHalf, roomFront, roomBack: Double
    }
    private(set) var left = -30.0, right = 30.0, radius = 1.0, room = 1.0, crossfeed = 0.0
    private(set) var width = 1.0, leftOn = 1.0, rightOn = 1.0
    private(set) var roomHalf = 1.79, roomFront = 1.64, roomBack = 1.12
    /// 0 when both speakers are in front, up to 1 when one is directly behind.
    var rear: Double { max(0, -cos(left * .pi / 180), -cos(right * .pi / 180)) * radius }
    /// Speaker being dragged (−1: a drag that did not start on a speaker).
    var dragging: Int?
    private var last: Double?
    private(set) var isMoving = true

    func step(to t: Targets, at time: Double) {
        let dt = min(0.1, max(0, time - (last ?? time)))
        last = time
        let k = dragging != nil ? 1 - exp(-dt * 30) : 1 - exp(-dt * 9)
        func approach(_ v: inout Double, _ target: Double) { v += (target - v) * k }
        func approachAngle(_ v: inout Double, _ target: Double) {
            v = SpeakerAngle.normalized(v + SpeakerAngle.normalized(target - v) * k)
        }
        approachAngle(&left, t.left)
        approachAngle(&right, t.right)
        approach(&radius, t.radius)
        approach(&room, t.room)
        approach(&crossfeed, t.crossfeed)
        approach(&width, t.width)
        approach(&leftOn, t.leftOn)
        approach(&rightOn, t.rightOn)
        approach(&roomHalf, t.roomHalf)
        approach(&roomFront, t.roomFront)
        approach(&roomBack, t.roomBack)
        let scalars = [(radius, t.radius), (room, t.room), (crossfeed, t.crossfeed), (width, t.width), (leftOn, t.leftOn),
                       (rightOn, t.rightOn), (roomHalf, t.roomHalf), (roomFront, t.roomFront), (roomBack, t.roomBack)]
        isMoving = abs(SpeakerAngle.normalized(left - t.left)) > 0.05 || abs(SpeakerAngle.normalized(right - t.right)) > 0.05 ||
            scalars.contains { abs($0.0 - $0.1) > 0.002 }
    }
}

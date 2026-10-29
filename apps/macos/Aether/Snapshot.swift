// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: renders a view offscreen to PNG for design review and docs, then exits.
///   Aether --snapshot out.png [--view main|onboarding|profiles] [--mode 0…3] [--unlinked] [--size WxH] [--defaults] [--version X]
///   custom only: [--room-size 0…2] [--width W] [--off left|right [--fold]]
/// Settings are not written and the audio route is never started.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        Store.readOnly = true
        let path = args[i + 1]
        let which = args.firstIndex(of: "--view").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "main"
        let controller = AetherController(autostart: false)
        controller.showOnboarding = false
        if let vi = args.firstIndex(of: "--version"), vi + 1 < args.count { AppInfo.versionOverride = args[vi + 1] }
        if args.contains("--defaults") {
            controller.settings = UserSettings()
            controller.settings.onboarded = true
        }
        if let mi = args.firstIndex(of: "--mode"), mi + 1 < args.count,
           let raw = Int(args[mi + 1]), let mode = ProcessingMode(rawValue: raw) {
            controller.select(mode)
            if mode == .custom {
                let unlinked = args.contains("--unlinked")
                controller.settings.speakersLinked = !unlinked
                controller.settings.azimuthLeft = unlinked ? 40 : 38
                controller.settings.azimuthRight = unlinked ? 135 : 38
                controller.settings.clarity = 0.9
                controller.settings.roomLevel = 0.55
                controller.settings.width = 1.1
                if let ri = args.firstIndex(of: "--room-size"), ri + 1 < args.count, let raw = Int(args[ri + 1]),
                   let size = RoomSize(rawValue: raw) { controller.settings.roomSize = size }
                if let wi = args.firstIndex(of: "--width"), wi + 1 < args.count, let w = Double(args[wi + 1]) {
                    controller.settings.width = w
                }
                if let oi = args.firstIndex(of: "--off"), oi + 1 < args.count {
                    if args[oi + 1] == "left" { controller.settings.leftEnabled = false }
                    else { controller.settings.rightEnabled = false }
                    controller.settings.foldMuted = args.contains("--fold")
                }
            }
        }
        let size: NSSize
        let root: AnyView
        switch which {
        case "onboarding":
            size = NSSize(width: 560, height: 560)
            root = AnyView(OnboardingView().environmentObject(controller))
        case "profiles":
            size = NSSize(width: 780, height: 560)
            root = AnyView(ProfilesView().environmentObject(controller))
        default:
            size = args.firstIndex(of: "--size").flatMap { i -> NSSize? in
                guard i + 1 < args.count else { return nil }
                let wh = args[i + 1].split(separator: "x").compactMap { Double($0) }
                return wh.count == 2 ? NSSize(width: wh[0], height: wh[1]) : nil
            } ?? NSSize(width: 1200, height: 872)
            root = AnyView(ContentView().environmentObject(controller))
        }
        let host = NSHostingView(rootView: root.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            let ok = (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) != nil
            exit(ok ? 0 : 1)
        }
    }
}
#endif

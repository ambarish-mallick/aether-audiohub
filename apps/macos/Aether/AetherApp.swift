// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
// Aether — IEM soundstage spatializer. A project by Ambarish Mallick.
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if SelfTest.isRequested {
                NSApp.windows.forEach { $0.orderOut(nil) }
                SelfTest.run()
                return
            }
            #if DEBUG
            Snapshot.runIfRequested()
            #endif
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { Installer.offerMoveIfNeeded() }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { onTerminate?() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !AetherApp.isHeadlessRun }
}

@main
struct AetherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AetherController(autostart: !AetherApp.isHeadlessRun)

    /// Self-test and snapshot runs never autostart the route or write user settings.
    static var isHeadlessRun: Bool {
        #if DEBUG
        if CommandLine.arguments.contains("--snapshot") { return true }
        #endif
        return CommandLine.arguments.contains("--selftest")
    }

    init() {
        if AetherApp.isHeadlessRun { Store.readOnly = true }
    }

    var body: some Scene {
        Window("Aether", id: "main") {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 1040, minHeight: 820)
                .onAppear { let controller = app; delegate.onTerminate = { MainActor.assumeIsolated { controller.applicationWillTerminate() } } }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Aether") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Aether",
                        .applicationVersion: AppInfo.version,
                        .credits: NSAttributedString(
                            string: "IEM soundstage spatializer.\nDeveloped by \(AppInfo.developer).\ngithub.com/ambarish-mallick/aether-audiohub",
                            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
                    ])
                }
            }
            CommandGroup(replacing: .help) {
                Button("Aether on GitHub") { NSWorkspace.shared.open(AppInfo.repository) }
                Button("Report an Issue…") {
                    NSWorkspace.shared.open(AppInfo.repository.appendingPathComponent("issues/new"))
                }
            }
            CommandMenu("Engine") {
                Button(app.settings.engineOn ? "Stop Engine" : "Start Engine") { app.setEngine(!app.settings.engineOn) }
                Button(app.settings.mode == .bypass ? "Resume Processing" : "DSP Bypass") { app.toggleBypass() }
                Divider()
                ForEach(ProcessingMode.allCases) { m in
                    Button(m.longName) { app.select(m) }
                }
                Divider()
                Button("IEM Profiles…") { app.showProfiles = true }
                Button("Show Introduction…") { app.showOnboarding = true }
            }
        }
    }
}

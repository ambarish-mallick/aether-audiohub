// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
import AppKit

/// When Aether is opened straight from the downloaded disk image (or from a
/// Gatekeeper-translocated copy), offers to install it into Applications and relaunch
/// from there, so settings, IEM profiles and the system-audio permission belong to
/// one stable copy.
@MainActor
enum Installer {
    static var isRunningFromDiskImage: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    static func offerMoveIfNeeded() {
        guard isRunningFromDiskImage else { return }
        let alert = NSAlert()
        alert.messageText = "Move Aether to Applications?"
        alert.informativeText = "Aether is running from the disk image. Installing it keeps your settings, IEM profiles and the system-audio permission with one copy of the app. You can eject the disk image afterwards."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let installed = try install()
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: installed, configuration: config) { _, error in
                DispatchQueue.main.async {
                    if let error { fail(error) } else { NSApp.terminate(nil) }
                }
            }
        } catch {
            fail(error)
        }
    }

    /// Copies this bundle into /Applications, or ~/Applications when /Applications is not
    /// writable. An existing Aether there is moved to the Trash, not deleted.
    private static func install() throws -> URL {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let user = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let folder = fm.isWritableFile(atPath: system.path) ? system : user
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent("Aether.app", isDirectory: true)
        if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
        try fm.copyItem(at: source, to: dest)
        return dest
    }

    private static func fail(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Aether could not be moved"
        alert.informativeText = "\(error.localizedDescription)\n\nDrag Aether from the disk image onto the Applications folder instead."
        alert.runModal()
    }
}

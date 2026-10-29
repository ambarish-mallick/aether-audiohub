// swift-tools-version:5.9
// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
// Aether — IEM soundstage spatializer for macOS. A project by Ambarish Mallick.
import PackageDescription

let package = Package(
    name: "Aether",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "Aether", targets: ["Aether"]),
    ],
    targets: [
        // Portable C++20 DSP core with a C ABI (also built by CMake for tests and tools).
        .target(
            name: "AetherCore",
            path: "core",
            exclude: ["tests"],
            sources: ["src"],
            publicHeadersPath: "include"
        ),
        // Objective-C++ Core Audio route: process tap + private aggregate device + IOProc.
        .target(
            name: "AetherRoute",
            dependencies: ["AetherCore"],
            path: "platform/macos",
            sources: ["src"],
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        // SwiftUI controller app.
        .executableTarget(
            name: "Aether",
            dependencies: ["AetherCore", "AetherRoute"],
            path: "apps/macos/Aether"
        ),
    ],
    cxxLanguageStandard: .cxx20
)

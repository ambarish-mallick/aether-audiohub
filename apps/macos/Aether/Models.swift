// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
import AetherCore
import Foundation
import SwiftUI

enum ProcessingMode: Int, Codable, CaseIterable, Identifiable {
    case bypass = 0, crossfeed = 1, reference = 2, custom = 3
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .bypass: "Bypass"
        case .crossfeed: "Crossfeed"
        case .reference: "Reference"
        case .custom: "Custom"
        }
    }
    var subtitle: String {
        switch self {
        case .bypass: "DSP bypass · unity"
        case .crossfeed: "Gentle ear blend"
        case .reference: "Speakers at ±30°"
        case .custom: "Your speakers & room"
        }
    }
    var longName: String {
        switch self {
        case .bypass: "DSP bypass"
        case .crossfeed: "Gentle crossfeed"
        case .reference: "Reference speakers"
        case .custom: "Custom speakers"
        }
    }
    var symbol: String {
        switch self {
        case .bypass: "slash.circle"
        case .crossfeed: "arrow.left.arrow.right"
        case .reference: "hifispeaker.2"
        case .custom: "slider.horizontal.3"
        }
    }
}

enum RoomSize: Int, Codable, CaseIterable, Identifiable {
    case small = 0, medium = 1, large = 2
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .small: "Small room"
        case .medium: "Medium room"
        case .large: "Large room"
        }
    }
}

/// Versioned, local-only settings. No audio and no track metadata are ever stored.
struct UserSettings: Codable, Equatable {
    var version = 1
    var engineOn = false
    var mode: ProcessingMode = .reference
    var lastProcessingMode: ProcessingMode = .reference
    /// Each angle is measured from straight ahead toward that speaker's own side, 0…360°.
    var azimuthLeft: Double = 30
    var azimuthRight: Double = 30
    var speakersLinked = true
    var leftEnabled = true
    var rightEnabled = true
    var foldMuted = false           // a switched-off speaker's channel plays through the other
    var clarity: Double = 1.0
    var roomLevel: Double = 0.3
    var roomSize: RoomSize = .medium
    var width: Double = 1.0
    var crossfeedLevel: Double = -9
    var crossfeedCutoff: Double = 700
    var crossfeedDelay: Double = 0.3
    var headroom: Double = -6
    var levelMatchBypass = true
    var iemEnabled = false
    var activeProfileID: UUID?
    var outputUID: String?          // nil = follow the system default output
    var onboarded = false
}

extension UserSettings {
    private enum LegacyKeys: String, CodingKey { case azimuth }

    /// Tolerant decoding: keys missing from older files keep their defaults, and the
    /// single symmetric `azimuth` of earlier builds becomes both speaker angles.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func load<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: key) { value = v }
        }
        load(.version, &version)
        load(.engineOn, &engineOn)
        load(.mode, &mode)
        load(.lastProcessingMode, &lastProcessingMode)
        if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
           let az = try? legacy.decodeIfPresent(Double.self, forKey: .azimuth) {
            azimuthLeft = az
            azimuthRight = az
        }
        load(.azimuthLeft, &azimuthLeft)
        load(.azimuthRight, &azimuthRight)
        load(.speakersLinked, &speakersLinked)
        load(.leftEnabled, &leftEnabled)
        load(.rightEnabled, &rightEnabled)
        load(.foldMuted, &foldMuted)
        if !leftEnabled && !rightEnabled { leftEnabled = true; rightEnabled = true }
        load(.clarity, &clarity)
        load(.roomLevel, &roomLevel)
        load(.roomSize, &roomSize)
        load(.width, &width)
        load(.crossfeedLevel, &crossfeedLevel)
        load(.crossfeedCutoff, &crossfeedCutoff)
        load(.crossfeedDelay, &crossfeedDelay)
        load(.headroom, &headroom)
        load(.levelMatchBypass, &levelMatchBypass)
        load(.iemEnabled, &iemEnabled)
        if let v = try? c.decodeIfPresent(UUID.self, forKey: .activeProfileID) { activeProfileID = v }
        if let v = try? c.decodeIfPresent(String.self, forKey: .outputUID) { outputUID = v }
        load(.onboarded, &onboarded)
    }
}

enum AppInfo {
    static let developer = "Ambarish Mallick"
    static let repository = URL(string: "https://github.com/ambarish-mallick/aether-audiohub")!

    /// Set by debug snapshot rendering, which runs unbundled.
    nonisolated(unsafe) static var versionOverride: String?
    /// Marketing version from the bundle; "dev" for unbundled debug runs.
    static var version: String {
        versionOverride ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// Speaker angles: each is measured from straight ahead toward that speaker's own side.
enum SpeakerAngle {
    /// Azimuth clockwise from the front (right positive), in (−180, 180].
    static func azimuth(side: Int, degrees: Double) -> Double {
        normalized(side == 0 ? -degrees : degrees)
    }

    static func normalized(_ az: Double) -> Double {
        var a = az.truncatingRemainder(dividingBy: 360)
        if a <= -180 { a += 360 }
        if a > 180 { a -= 360 }
        return a
    }

    /// 0…360 angle on that speaker's own side for a drawn azimuth.
    static func degrees(side: Int, azimuth: Double) -> Double {
        var d = (side == 0 ? -azimuth : azimuth).truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    /// Plain-language position for an azimuth.
    static func position(_ az: Double) -> String {
        let a = normalized(az), m = abs(a)
        if m < 7.5 { return "front" }
        if m > 172.5 { return "behind" }
        let side = a < 0 ? "left" : "right"
        if m < 67.5 { return "front " + side }
        if m <= 112.5 { return side }
        return "rear " + side
    }

    /// Short description of a symmetric (linked) angle.
    static func linkedPosition(_ deg: Double) -> String {
        let d = deg.truncatingRemainder(dividingBy: 360)
        let crossed = d > 187.5 && d < 352.5
        let m = crossed ? 360 - d : d
        if m < 7.5 { return "front" }
        if m >= 172.5 { return "behind" }
        let place = m < 67.5 ? "front" : m <= 112.5 ? "beside" : "rear"
        return crossed ? place + " · sides swapped" : place
    }
}

/// IEM profile tiers per the spec: user-tuned sliders are never presented as measurements.
struct IEMProfile: Codable, Identifiable, Equatable {
    enum Tier: String, Codable, CaseIterable, Identifiable {
        case userTuned, modelEstimate, measuredPersonal
        var id: String { rawValue }
        var title: String {
            switch self {
            case .userTuned: "User-tuned"
            case .modelEstimate: "Model estimate"
            case .measuredPersonal: "Measured personal"
            }
        }
        var explanation: String {
            switch self {
            case .userTuned: "Tone sliders you set by ear. Not a measurement of your ear canal."
            case .modelEstimate: "Built from a published response for this IEM model. Approximate: your fit, tips and insertion depth differ."
            case .measuredPersonal: "Built from your own calibrated probe-microphone measurement. Re-measure if tips or fit change."
            }
        }
    }

    var id = UUID()
    var name: String
    var tier: Tier
    var created = Date()
    // User-tuned parameters (dB)
    var bass: Double = 0
    var presence: Double = 0
    var treble: Double = 0
    // Designed correction (dB at aether_eq_frequency(i)), per ear
    var curveLeft: [Float]
    var curveRight: [Float]
    // Provenance for imported responses; raw data kept apart from the generated filter
    var iemModel: String?
    var eartips: String?
    var notes: String?
    var measurementFile: String?
    var targetFile: String?
    var rawMeasurementHz: [Float]?
    var rawMeasurementLeftDb: [Float]?
    var rawMeasurementRightDb: [Float]?
    var rawTargetHz: [Float]?
    var rawTargetDb: [Float]?
    var maxBoostDb: Float?
    var maxCutDb: Float?
    var clampedFraction: Float?
    var reliableHighHz: Float?
}

enum EngineStatus: Equatable {
    case off
    case processing
    case dspBypass
    case notProcessing(String)
    case error(String)

    var badge: String {
        switch self {
        case .off: "OFF"
        case .processing: "PROCESSING"
        case .dspBypass: "DSP BYPASS"
        case .notProcessing: "NOT PROCESSING"
        case .error: "ERROR"
        }
    }
    var spoken: String {
        switch self {
        case .off: "Engine off"
        case .processing: "Processing"
        case .dspBypass: "DSP bypass"
        case .notProcessing(let why): "Not processing. \(why)"
        case .error(let why): "Error. \(why)"
        }
    }
    var color: Color {
        switch self {
        case .off: Color(white: 0.55)
        case .processing: Theme.accent
        case .dspBypass: Color(red: 0.62, green: 0.74, blue: 0.98)
        case .notProcessing: Theme.amber
        case .error: Theme.danger
        }
    }
    var detail: String? {
        switch self {
        case .notProcessing(let s), .error(let s): s
        default: nil
        }
    }
}

/// Local JSON persistence under ~/Library/Application Support/Aether.
enum Store {
    /// Set by debug snapshot rendering so it never touches the user's files.
    nonisolated(unsafe) static var readOnly = false

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Aether", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    static var profilesURL: URL { directory.appendingPathComponent("iem-profiles.json") }
    /// Present while the route is running; found at launch it means the last session did not end cleanly.
    static var runningMarkerURL: URL { directory.appendingPathComponent("engine.running") }

    static func loadSettings() -> UserSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let s = try? JSONDecoder().decode(UserSettings.self, from: data),
              s.version == 1 else { return UserSettings() }
        return s
    }
    static func save(_ s: UserSettings) {
        if readOnly { return }
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: settingsURL, options: .atomic) }
    }
    static func loadProfiles() -> [IEMProfile] {
        guard let data = try? Data(contentsOf: profilesURL) else { return [] }
        return (try? JSONDecoder().decode([IEMProfile].self, from: data)) ?? []
    }
    static func save(_ p: [IEMProfile]) {
        if readOnly { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(p) { try? data.write(to: profilesURL, options: .atomic) }
    }
    static func setRunningMarker(_ on: Bool) {
        if readOnly { return }
        if on { try? Data("1".utf8).write(to: runningMarkerURL, options: .atomic) }
        else { try? FileManager.default.removeItem(at: runningMarkerURL) }
    }
    static var runningMarkerExists: Bool { FileManager.default.fileExists(atPath: runningMarkerURL.path) }
}

/// Parses two- or three-column frequency-response text (Hz, dB[, dB]); separators: comma,
/// semicolon, tab or space. Header and comment lines are skipped. Validates strictly.
enum ResponseCSV {
    struct Curve { var hz: [Float]; var left: [Float]; var right: [Float]? }
    enum ParseError: LocalizedError {
        case unreadable, tooFewPoints(Int), invalidValue(Int)
        var errorDescription: String? {
            switch self {
            case .unreadable: "The file could not be read as text."
            case .tooFewPoints(let n): "Found \(n) usable rows; at least 8 are needed."
            case .invalidValue(let line): "Line \(line) has an out-of-range value."
            }
        }
    }

    static func parse(_ url: URL) throws -> Curve {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.intValue < 8_000_000,
              let text = try? String(contentsOf: url, encoding: .utf8) else { throw ParseError.unreadable }
        var rows: [(Float, Float, Float?)] = []
        for (i, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("*") { continue }
            let parts = line.split(whereSeparator: { ",;\t ".contains($0) }).compactMap { Float($0) }
            guard parts.count >= 2 else { continue }
            let (f, l) = (parts[0], parts[1])
            let r: Float? = parts.count >= 3 ? parts[2] : nil
            guard f.isFinite, l.isFinite, f > 0, f < 200_000, abs(l) < 200, (r.map { $0.isFinite && abs($0) < 200 } ?? true)
            else { throw ParseError.invalidValue(i + 1) }
            rows.append((f, l, r))
        }
        rows.sort { $0.0 < $1.0 }
        var dedup: [(Float, Float, Float?)] = []
        for row in rows where dedup.last.map({ row.0 > $0.0 }) ?? true { dedup.append(row) }
        guard dedup.count >= 8 else { throw ParseError.tooFewPoints(dedup.count) }
        let hasRight = dedup.allSatisfy { $0.2 != nil }
        return Curve(hz: dedup.map(\.0), left: dedup.map(\.1), right: hasRight ? dedup.map { $0.2! } : nil)
    }
}

extension aether_meters {
    static var zero: aether_meters { aether_meters() }
}

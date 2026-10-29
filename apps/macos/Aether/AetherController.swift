// Aether — developed by Ambarish Mallick. Copyright (c) 2026 Ambarish Mallick. SPDX-License-Identifier: MIT
import AetherCore
@preconcurrency import AetherRoute
import AppKit
import Foundation
import SwiftUI

/// Display-ready meter values (dB) with smooth fall-back.
struct MeterState: Equatable {
    var inPeak: [Double] = [-120, -120]
    var outPeak: [Double] = [-120, -120]
    var outTruePeak: [Double] = [-120, -120]
    var sessionTruePeakMax: Double = -120
    var signalPresent = false
    var overTruePeak = false   // > −1 dBTP recently
    var clipped = false        // ≥ 0 dBFS sample recently
    var nonFiniteInput: UInt64 = 0
    var safetyBypass = false
}

struct RoomInfo: Equatable {
    struct Dot: Equatable { var azimuth: Double; var delayMs: Double; var gain: Double; var speaker: Int }
    var dots: [Dot] = []
    var count = 0
    var firstMs = 0.0, lastMs = 0.0, drrDb = 0.0
    var widthM = 0.0, depthM = 0.0, heightM = 0.0, speakerDistanceM = 0.0
}

@MainActor
final class AetherController: ObservableObject {
    @Published var settings: UserSettings { didSet { settingsChanged(from: oldValue) } }
    @Published private(set) var profiles: [IEMProfile]
    @Published private(set) var devices: [AEOutputDevice] = []
    @Published private(set) var status: EngineStatus = .off
    @Published private(set) var snapshot: AERouteSnapshot?
    @Published private(set) var engineInfo = aether_engine_info()
    @Published private(set) var meters = MeterState()
    @Published private(set) var room = RoomInfo()
    @Published private(set) var lastError: String?
    @Published var crashedLastSession = false
    @Published var showOnboarding = false
    @Published var showProfiles = false

    private let route = AERoute()
    private let routeDelegate = RouteDelegateProxy()
    private let controlQueue = DispatchQueue(label: "aether.control", qos: .userInitiated)
    private let pendingConfig = PendingConfig()
    private var timer: Timer?
    private var notProcessingReason: String?
    private var restartWork: DispatchWorkItem?
    private var lastSignalTime = Date.distantPast
    private var lastOverTime = Date.distantPast
    private var lastClipTime = Date.distantPast
    private var stallRestarts = 0
    private var sleeping = false

    init(autostart: Bool = true) {
        settings = Store.loadSettings()
        profiles = Store.loadProfiles()
        crashedLastSession = autostart && Store.runningMarkerExists
        Store.setRunningMarker(false)
        routeDelegate.owner = self
        route.delegate = routeDelegate
        refreshDevices()
        updateRoom()
        submitConfig()
        showOnboarding = !settings.onboarded
        // A crash/forced quit leaves the engine off (safe route); otherwise restore.
        if crashedLastSession { settings.engineOn = false }
        else if autostart && settings.engineOn && settings.onboarded { startRoute() }
        else if !autostart { settings.engineOn = false }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
    }

    // MARK: - User intents

    func setEngine(_ on: Bool) {
        settings.engineOn = on
        if on { crashedLastSession = false; startRoute() } else { stopRoute() }
    }

    func select(_ mode: ProcessingMode) {
        if mode != .bypass { settings.lastProcessingMode = mode }
        settings.mode = mode
    }

    func toggleBypass() {
        select(settings.mode == .bypass ? settings.lastProcessingMode : .bypass)
    }

    /// Parameter edits in Reference move to Custom, starting from the reference values.
    func editSpeakerParameter(_ apply: (inout UserSettings) -> Void) {
        var s = settings
        if s.mode == .reference {
            s.azimuthLeft = 30; s.azimuthRight = 30; s.clarity = 1
            s.leftEnabled = true; s.rightEnabled = true
            s.roomLevel = 0.3; s.roomSize = .medium; s.width = 1
            s.mode = .custom; s.lastProcessingMode = .custom
        }
        apply(&s)
        settings = s
    }

    /// Sets a speaker angle (0…360° toward its own side). While linked, both speakers follow.
    func setSpeakerAngle(side: Int, degrees: Double) {
        let d = degrees.rounded().clamped(0, 360)
        editSpeakerParameter { s in
            if s.speakersLinked { s.azimuthLeft = d; s.azimuthRight = d }
            else if side == 0 { s.azimuthLeft = d }
            else { s.azimuthRight = d }
        }
    }

    /// Switches one speaker on or off. The last speaker playing cannot be switched off.
    func setSpeakerEnabled(side: Int, _ on: Bool) {
        let other = side == 0 ? settings.rightEnabled : settings.leftEnabled
        if !on && !other { return }
        editSpeakerParameter { s in
            if side == 0 { s.leftEnabled = on } else { s.rightEnabled = on }
        }
    }

    /// Plays both speakers, or only one of them.
    func setActiveSpeakers(left: Bool, right: Bool) {
        guard left || right else { return }
        editSpeakerParameter { s in s.leftEnabled = left; s.rightEnabled = right }
    }

    /// Unlinking keeps both angles; relinking joins them at their mean.
    func setSpeakersLinked(_ linked: Bool) {
        var s = settings
        s.speakersLinked = linked
        if linked, s.mode == .custom {
            let mean = ((s.azimuthLeft + s.azimuthRight) / 2).rounded()
            s.azimuthLeft = mean
            s.azimuthRight = mean
        }
        settings = s
    }

    func resetCustomToReference() {
        var s = settings
        s.azimuthLeft = 30; s.azimuthRight = 30; s.speakersLinked = true; s.clarity = 1
        s.leftEnabled = true; s.rightEnabled = true; s.foldMuted = false
        s.roomLevel = 0.3; s.roomSize = .medium; s.width = 1
        settings = s
    }

    var speakersSummary: String {
        let s = settings
        if s.mode != .custom || (s.leftEnabled && s.rightEnabled) { return "" }
        return (s.leftEnabled ? "Left only" : "Right only") + (s.foldMuted ? " (both channels)" : "")
    }

    var speakerAngleSummary: String {
        let s = settings
        if s.mode != .custom { return "±30°" }
        if !s.leftEnabled { return String(format: "R %.0f°", s.azimuthRight) }
        if !s.rightEnabled { return String(format: "L %.0f°", s.azimuthLeft) }
        return s.azimuthLeft == s.azimuthRight ? String(format: "±%.0f°", s.azimuthLeft)
            : String(format: "L %.0f° · R %.0f°", s.azimuthLeft, s.azimuthRight)
    }

    func selectOutput(uid: String?) {
        settings.outputUID = uid
        if settings.engineOn { startRoute() }
    }

    func finishOnboarding() {
        settings.onboarded = true
        showOnboarding = false
    }

    func resetTruePeakHold() { meters.sessionTruePeakMax = -120 }

    // MARK: - Profiles

    var activeProfile: IEMProfile? { profiles.first { $0.id == settings.activeProfileID } }

    func saveProfile(_ p: IEMProfile, activate: Bool) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p } else { profiles.append(p) }
        Store.save(profiles)
        if activate { settings.activeProfileID = p.id; settings.iemEnabled = true }
        submitConfig()
    }

    func deleteProfile(_ p: IEMProfile) {
        profiles.removeAll { $0.id == p.id }
        Store.save(profiles)
        if settings.activeProfileID == p.id { settings.activeProfileID = nil; settings.iemEnabled = false }
    }

    func activateProfile(_ p: IEMProfile) {
        settings.activeProfileID = p.id
        settings.iemEnabled = true
    }

    // MARK: - Derived

    var effectiveOutputUID: String? { settings.outputUID ?? AERoute.systemDefaultOutputUID() }

    var selectedDevice: AEOutputDevice? { devices.first { $0.uid == effectiveOutputUID } }

    var summary: String {
        switch settings.mode {
        case .bypass: return "DSP bypass" + (settings.levelMatchBypass ? String(format: " · %.1f dB level-matched", settings.headroom) : " · unity")
        case .crossfeed: return String(format: "Crossfeed · %.0f dB · %.0f Hz", settings.crossfeedLevel, settings.crossfeedCutoff)
        case .reference: return "Reference · ±30° · Room 30% · Medium"
        case .custom: return String(format: "Custom · %@%@ · Room %.0f%% · %@ · Width %.0f%% · Clarity %.0f%%",
                                    speakerAngleSummary, speakersSummary.isEmpty ? "" : " · " + speakersSummary,
                                    settings.roomLevel * 100,
                                    settings.roomSize.title.replacingOccurrences(of: " room", with: ""),
                                    settings.width * 100, settings.clarity * 100)
        }
    }

    // MARK: - Engine configuration

    private func settingsChanged(from old: UserSettings) {
        if settings != old { Store.save(settings) }
        let dspChanged = settings.mode != old.mode || settings.azimuthLeft != old.azimuthLeft ||
            settings.azimuthRight != old.azimuthRight || settings.clarity != old.clarity ||
            settings.leftEnabled != old.leftEnabled || settings.rightEnabled != old.rightEnabled ||
            settings.foldMuted != old.foldMuted ||
            settings.roomLevel != old.roomLevel || settings.roomSize != old.roomSize || settings.width != old.width ||
            settings.crossfeedLevel != old.crossfeedLevel || settings.crossfeedCutoff != old.crossfeedCutoff ||
            settings.crossfeedDelay != old.crossfeedDelay || settings.headroom != old.headroom ||
            settings.levelMatchBypass != old.levelMatchBypass || settings.iemEnabled != old.iemEnabled ||
            settings.activeProfileID != old.activeProfileID
        if dspChanged {
            submitConfig()
            updateRoom()
        }
    }

    private func makeConfig() -> aether_config {
        var c = aether_config()
        aether_config_default(&c)
        c.mode = Int32(settings.mode.rawValue)
        c.speaker_left_deg = Float(settings.azimuthLeft)
        c.speaker_right_deg = Float(settings.azimuthRight)
        c.clarity = Float(settings.clarity)
        c.speaker_enabled = (settings.leftEnabled ? 1 : 0, settings.rightEnabled ? 1 : 0)
        c.fold_disabled = settings.foldMuted ? 1 : 0
        c.room_level = Float(settings.roomLevel)
        c.room_size = Int32(settings.roomSize.rawValue)
        c.width = Float(settings.width)
        c.crossfeed_level_db = Float(settings.crossfeedLevel)
        c.crossfeed_cutoff_hz = Float(settings.crossfeedCutoff)
        c.crossfeed_delay_ms = Float(settings.crossfeedDelay)
        c.headroom_db = Float(settings.headroom)
        c.level_match_bypass = settings.levelMatchBypass ? 1 : 0
        if settings.iemEnabled, let p = activeProfile {
            c.iem_enabled = 1
            p.curveLeft.withUnsafeBufferPointer { aether_config_set_iem_curve(&c, 0, $0.baseAddress, Int32($0.count)) }
            p.curveRight.withUnsafeBufferPointer { aether_config_set_iem_curve(&c, 1, $0.baseAddress, Int32($0.count)) }
        }
        return c
    }

    /// Filter design runs on a serial background queue; rapid slider moves coalesce to the latest value.
    private func submitConfig() {
        let cfg = makeConfig()
        if pendingConfig.store(cfg) {
            let route = self.route
            let pending = self.pendingConfig
            controlQueue.async {
                while let next = pending.take() {
                    var c = next
                    _ = route.submitConfig(&c)
                }
            }
        }
    }

    private func updateRoom() {
        var cfg = makeConfig()
        var refl = [aether_reflection](repeating: aether_reflection(), count: 128)
        var summary = aether_room_summary()
        let n = Int(aether_describe_room(&cfg, &refl, 128, &summary))
        var info = RoomInfo()
        if n > 0 {
            info.dots = refl.prefix(min(n, 128)).map {
                .init(azimuth: Double($0.azimuth_deg), delayMs: Double($0.delay_ms), gain: Double($0.gain), speaker: Int($0.speaker))
            }
            info.count = n
            info.firstMs = Double(summary.first_delay_ms)
            info.lastMs = Double(summary.last_delay_ms)
            info.drrDb = Double(summary.direct_to_reflected_db)
        }
        info.widthM = Double(summary.room_width_m)
        info.depthM = Double(summary.room_depth_m)
        info.heightM = Double(summary.room_height_m)
        info.speakerDistanceM = Double(summary.speaker_distance_m)
        room = info
    }

    // MARK: - Route lifecycle

    private func startRoute() {
        restartWork?.cancel()
        restartWork = nil
        refreshDevices()
        guard let uid = effectiveOutputUID, devices.contains(where: { $0.uid == uid }) else {
            route.stop()
            Store.setRunningMarker(false)
            notProcessingReason = "Output device not connected — waiting for it"
            return
        }
        do {
            try route.start(withOutputUID: uid)
            Store.setRunningMarker(true)
            notProcessingReason = nil
            lastError = nil
            stallRestarts = 0
            submitConfig()
        } catch {
            Store.setRunningMarker(false)
            lastError = error.localizedDescription
        }
    }

    private func stopRoute() {
        restartWork?.cancel()
        restartWork = nil
        route.stop()
        Store.setRunningMarker(false)
        notProcessingReason = nil
        lastError = nil
    }

    private func scheduleRestart(after seconds: Double) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.restartWork = nil
                guard self.settings.engineOn, !self.sleeping else { return }
                self.startRoute()
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    fileprivate func routeDevicesDidChange() {
        let previousDefault = devices.first { $0.isSystemDefault }?.uid
        refreshDevices()
        guard settings.engineOn, !sleeping else { return }
        let nowDefault = devices.first { $0.isSystemDefault }?.uid
        if route.state != .running {
            if let uid = effectiveOutputUID, devices.contains(where: { $0.uid == uid }), lastError == nil {
                scheduleRestart(after: 0.6) // device came back
            }
        } else if settings.outputUID == nil, previousDefault != nowDefault {
            scheduleRestart(after: 0.3)     // following the system default
        }
    }

    fileprivate func routeDidStop(_ reason: String) {
        Store.setRunningMarker(false)
        notProcessingReason = reason + " — waiting for it to return"
    }

    fileprivate func routeNeedsRestart(_ reason: String) {
        scheduleRestart(after: 0.3)
    }

    private func willSleep() {
        sleeping = true
        if route.state == .running { route.stop(); Store.setRunningMarker(false) }
    }

    private func didWake() {
        sleeping = false
        if settings.engineOn { scheduleRestart(after: 1.5) }
    }

    private func refreshDevices() {
        devices = AERoute.outputDevices()
    }

    // MARK: - Telemetry

    private func tick() {
        let snap = route.snapshot()
        snapshot = snap
        engineInfo = route.engineInfo()
        let m = route.readMetersReset(true)
        let now = Date()
        var s = meters
        let fall = 24.0 / 20.0 // dB per tick
        func smooth(_ old: Double, _ new: Float) -> Double { max(linearToDb(new), old - fall) }
        let running = snap.state == .running
        for c in 0..<2 {
            let inPk = c == 0 ? m.in_peak.0 : m.in_peak.1
            let outPk = c == 0 ? m.out_peak.0 : m.out_peak.1
            let tp = c == 0 ? m.out_true_peak.0 : m.out_true_peak.1
            s.inPeak[c] = running ? smooth(s.inPeak[c], inPk) : -120
            s.outPeak[c] = running ? smooth(s.outPeak[c], outPk) : -120
            s.outTruePeak[c] = running ? smooth(s.outTruePeak[c], tp) : -120
            if running && Double(linearToDb(tp)) > -1.0 { lastOverTime = now }
            if running && outPk >= 1.0 { lastClipTime = now }
            if running && Double(linearToDb(inPk)) > -70 { lastSignalTime = now }
            if running { s.sessionTruePeakMax = max(s.sessionTruePeakMax, linearToDb(tp)) }
        }
        s.signalPresent = now.timeIntervalSince(lastSignalTime) < 1.5
        s.overTruePeak = now.timeIntervalSince(lastOverTime) < 2
        s.clipped = now.timeIntervalSince(lastClipTime) < 3
        s.nonFiniteInput = m.nonfinite_input_samples
        s.safetyBypass = m.safety_bypass != 0
        if s != meters { meters = s }

        // Honest route status.
        let newStatus: EngineStatus
        if !settings.engineOn {
            newStatus = .off
        } else if let err = lastError {
            newStatus = .error(err)
        } else if !running {
            newStatus = .notProcessing(notProcessingReason ?? (sleeping ? "System asleep" : "Route not running"))
        } else if snap.deviceHoggedByOtherProcess {
            newStatus = .notProcessing("Another app has exclusive use of \(snap.deviceName)")
        } else if snap.secondsSinceLastCallback > 1.0 {
            newStatus = .notProcessing("Audio device stopped delivering buffers")
            if snap.secondsSinceLastCallback > 3.0 && stallRestarts < 3 && restartWork == nil {
                stallRestarts += 1
                scheduleRestart(after: 0.1)
            }
        } else if m.safety_bypass != 0 {
            newStatus = .dspBypass
        } else {
            newStatus = m.active_mode == Int32(ProcessingMode.bypass.rawValue) ? .dspBypass : .processing
        }
        if newStatus != status { status = newStatus }
    }

    func applicationWillTerminate() {
        route.stop()
        Store.setRunningMarker(false)
        Store.save(settings)
    }
}

/// Latest-value mailbox between the main thread and the control queue.
private final class PendingConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var value: aether_config?
    private var scheduled = false

    /// Returns true if the caller must schedule a drain.
    func store(_ c: aether_config) -> Bool {
        lock.lock(); defer { lock.unlock() }
        value = c
        if scheduled { return false }
        scheduled = true
        return true
    }

    func take() -> aether_config? {
        lock.lock(); defer { lock.unlock() }
        guard let v = value else { scheduled = false; return nil }
        value = nil
        return v
    }
}

/// AERouteDelegate delivers on the main queue; hop into the main actor explicitly.
private final class RouteDelegateProxy: NSObject, AERouteDelegate {
    weak var owner: AetherController?
    func routeDevicesDidChange() { MainActor.assumeIsolated { owner?.routeDevicesDidChange() } }
    func routeDidStop(withReason reason: String) { MainActor.assumeIsolated { owner?.routeDidStop(reason) } }
    func routeNeedsRestart(_ reason: String) { MainActor.assumeIsolated { owner?.routeNeedsRestart(reason) } }
}

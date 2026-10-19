import AppKit
import ServiceManagement
import SwiftUI

struct Notice: Equatable {
    var text: String
    var isWarning: Bool
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // Display + preset
    @Published var displays: [DisplayInfo] = []
    @Published var selectedDisplayUUID: String?
    @Published var presets: [DisplayPreset] = []
    @Published var activePresetID: String?

    // Brightness lock (preset fixes brightness → True Tone forced off)
    @Published var brightnessLocked = false
    @Published var lockReason: String?
    @Published var lockOverride: Bool?          // per active preset: nil = auto
    @Published var lockBlocksWarmth = UserDefaults.standard.bool(forKey: "lockBlocksWarmth")

    // True Tone / Night Shift
    @Published var trueToneSupported = false
    @Published var trueToneOn = false
    @Published var nightShiftAvailable = false
    @Published var nightShiftOn = false
    @Published var nightShiftStrength: Float = 0.5

    // Custom warmth (Kelvin)
    @Published var tintEnabled = UserDefaults.standard.bool(forKey: "tintEnabled")
    @Published var tintKelvin: Double = {
        let v = UserDefaults.standard.double(forKey: "tintKelvin")
        return v > 0 ? v : 4200
    }()

    // Profiles + misc
    @Published var profiles: [DisplayProfile] = []
    @Published var activeProfileID: UUID?
    @Published var notice: Notice?
    @Published var busy = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let store = ProfileStore()
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var reconfigTask: Task<Void, Never>?

    /// What the user had before a locked preset forced things off; restored when the lock ends.
    private var trueToneBeforeLock: Bool?
    private var nightShiftBeforeLock: Bool?

    private init() {
        profiles = store.load()
        refresh()
        if tintEnabled { applyTint() }
        observe()
    }

    var selectedDisplay: DisplayInfo? {
        displays.first { $0.uuid == selectedDisplayUUID } ?? displays.first
    }

    var activePresetName: String? { presets.first { $0.id == activePresetID }?.name }

    /// Warmth/Night Shift are blocked only if the user opted in.
    var warmthBlocked: Bool { brightnessLocked && lockBlocksWarmth }

    // MARK: Reading state

    func refresh() {
        displays = Displays.active()
        if selectedDisplayUUID == nil || !displays.contains(where: { $0.uuid == selectedDisplayUUID }) {
            selectedDisplayUUID = displays.first { !CoreDisplayPresets.shared.presets(for: $0.id).isEmpty }?.uuid
                ?? displays.first?.uuid
        }
        refreshPresets()
        evaluateLock()
        readBrightnessClients()
    }

    private func refreshPresets() {
        if let d = selectedDisplay {
            presets = CoreDisplayPresets.shared.presets(for: d.id)
            activePresetID = CoreDisplayPresets.shared.activePreset(for: d.id)?.id
        } else {
            presets = []
            activePresetID = nil
        }
    }

    private func readBrightnessClients() {
        let cb = CoreBrightness.shared
        trueToneSupported = cb.trueToneSupported
        trueToneOn = cb.trueToneEnabled ?? false
        nightShiftAvailable = cb.nightShiftAvailable
        nightShiftOn = cb.nightShiftEnabled ?? false
        if let s = cb.nightShiftStrength { nightShiftStrength = s }
    }

    // MARK: Brightness lock

    /// Works out whether the active preset fixes brightness, then enforces True Tone off
    /// (and optionally Night Shift / warmth off). Restores the previous state when the lock ends.
    private func evaluateLock() {
        let cb = CoreBrightness.shared
        let wasLocked = brightnessLocked

        if let d = selectedDisplay, let pid = activePresetID {
            let detection = BrightnessLock.detect(display: d.id, trueTone: cb.trueToneRaw)
            lockOverride = BrightnessLock.override(for: pid)
            brightnessLocked = lockOverride ?? detection.locked
            lockReason = lockOverride != nil ? "set by you for this preset" : detection.reason
        } else {
            lockOverride = nil
            brightnessLocked = false
            lockReason = nil
        }

        if brightnessLocked {
            if !wasLocked {
                trueToneBeforeLock = cb.trueToneEnabled
                nightShiftBeforeLock = cb.nightShiftEnabled
            }
            if cb.trueToneEnabled == true { cb.setTrueTone(false) }
            if lockBlocksWarmth, cb.nightShiftEnabled == true { cb.setNightShift(false) }
        } else if wasLocked {
            if let tt = trueToneBeforeLock, cb.trueToneSupported { cb.setTrueTone(tt) }
            if lockBlocksWarmth, let ns = nightShiftBeforeLock { cb.setNightShift(ns) }
            trueToneBeforeLock = nil
            nightShiftBeforeLock = nil
        }

        if wasLocked != brightnessLocked, lockBlocksWarmth {
            GammaTint.shared.invalidate()
            applyTint()
        }
    }

    /// Per-preset override from the menu: nil = auto-detect, true = locked, false = not locked.
    func setLockOverride(_ value: Bool?) {
        guard let pid = activePresetID else { return }
        BrightnessLock.setOverride(value, for: pid)
        evaluateLock()
        readBrightnessClients()
    }

    func setLockBlocksWarmth(_ on: Bool) {
        // Undo/redo the blocking cleanly around the change.
        let cb = CoreBrightness.shared
        if brightnessLocked {
            if on {
                nightShiftBeforeLock = cb.nightShiftEnabled
                if cb.nightShiftEnabled == true { cb.setNightShift(false) }
            } else if let ns = nightShiftBeforeLock {
                cb.setNightShift(ns)
            }
        }
        lockBlocksWarmth = on
        UserDefaults.standard.set(on, forKey: "lockBlocksWarmth")
        GammaTint.shared.invalidate()
        applyTint()
        readBrightnessClients()
    }

    // MARK: Live controls

    func selectDisplay(uuid: String?) {
        selectedDisplayUUID = uuid
        refreshPresets()
        evaluateLock()
        readBrightnessClients()
    }

    func selectPreset(id: String) async {
        guard let d = selectedDisplay, let p = presets.first(where: { $0.id == id }) else { return }
        busy = true
        defer { busy = false }
        do {
            try await CoreDisplayPresets.shared.setPreset(p, on: d.id)
            notice = nil
        } catch {
            notice = Notice(text: error.localizedDescription, isWarning: true)
        }
        activeProfileID = nil
        try? await Task.sleep(for: .milliseconds(400))
        refresh()
        if tintEnabled { GammaTint.shared.invalidate(); applyTint() }
    }

    func setTrueTone(_ on: Bool) async {
        guard !brightnessLocked else { return }
        CoreBrightness.shared.setTrueTone(on)
        try? await Task.sleep(for: .milliseconds(250))
        if CoreBrightness.shared.trueToneEnabled != on {
            notice = Notice(text: "True Tone didn't change. macOS may be holding it for this preset.", isWarning: true)
        }
        activeProfileID = nil
        readBrightnessClients()
    }

    func setNightShift(_ on: Bool) {
        guard !warmthBlocked else { return }
        CoreBrightness.shared.setNightShift(on)
        activeProfileID = nil
        readBrightnessClients()
    }

    func previewNightShiftStrength(_ value: Float) {
        nightShiftStrength = value
        CoreBrightness.shared.setNightShiftStrength(value, commit: false)
    }

    func commitNightShiftStrength() {
        CoreBrightness.shared.setNightShiftStrength(nightShiftStrength, commit: true)
        activeProfileID = nil
    }

    func setTintEnabled(_ on: Bool) {
        tintEnabled = on
        UserDefaults.standard.set(on, forKey: "tintEnabled")
        activeProfileID = nil
        reportTint(applyTint())
    }

    /// Moving the slider (or a stop button) turns warmth on, like f.lux.
    func setTintKelvin(_ k: Double) {
        tintKelvin = k
        UserDefaults.standard.set(k, forKey: "tintKelvin")
        activeProfileID = nil
        if !tintEnabled {
            tintEnabled = true
            UserDefaults.standard.set(true, forKey: "tintEnabled")
        }
        reportTint(applyTint())
    }

    @discardableResult
    private func applyTint() -> Bool {
        let k = (tintEnabled && !warmthBlocked) ? Int(tintKelvin) : nil
        return GammaTint.shared.apply(kelvin: k, to: displays.map(\.id))
    }

    private func reportTint(_ ok: Bool) {
        if !ok { notice = Notice(text: "The display ignored the warmth change in this preset.", isWarning: true) }
        else if notice?.isWarning == true { notice = nil }
    }

    // MARK: Profiles

    func saveCurrentAsProfile(named raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = presets.first { $0.id == activePresetID }
        var p = DisplayProfile(
            name: name,
            displayUUID: selectedDisplay?.uuid,
            presetName: preset?.name,
            presetID: preset?.uniqueID,
            // In a locked preset True Tone is enforced anyway; store the user's real preference.
            trueTone: trueToneSupported ? (brightnessLocked ? (trueToneBeforeLock ?? trueToneOn) : trueToneOn) : nil,
            nightShift: nightShiftAvailable ? nightShiftOn : nil,
            nightShiftStrength: nightShiftAvailable ? nightShiftStrength : nil,
            tintKelvin: tintEnabled ? Int(tintKelvin) : nil
        )
        if let i = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            p.id = profiles[i].id
            profiles[i] = p
        } else {
            profiles.append(p)
        }
        store.save(profiles)
        activeProfileID = p.id
        notice = Notice(text: "Saved “\(name)”", isWarning: false)
    }

    func overwrite(_ profile: DisplayProfile) {
        saveCurrentAsProfile(named: profile.name)
    }

    func delete(_ profile: DisplayProfile) {
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { activeProfileID = nil }
        store.save(profiles)
    }

    func apply(_ p: DisplayProfile) async {
        busy = true
        defer { busy = false }
        var warnings: [String] = []
        refresh()

        // The profile's own choices win over "restore what you had before the lock".
        if p.trueTone != nil { trueToneBeforeLock = nil }
        if p.nightShift != nil { nightShiftBeforeLock = nil }

        // 1. Reference preset (also sets brightness to the preset's level).
        let target = displays.first { $0.uuid == p.displayUUID } ?? selectedDisplay
        if let d = target {
            selectedDisplayUUID = d.uuid
            if p.presetID != nil || p.presetName != nil {
                let list = CoreDisplayPresets.shared.presets(for: d.id)
                let match = list.first { p.presetID != nil && $0.uniqueID == p.presetID }
                    ?? list.first { $0.name == p.presetName }
                if let match {
                    do { try await CoreDisplayPresets.shared.setPreset(match, on: d.id) }
                    catch { warnings.append(error.localizedDescription) }
                } else {
                    warnings.append("Preset “\(p.presetName ?? "unknown")” isn't available on \(d.name).")
                }
            }
        } else if p.presetName != nil {
            warnings.append("No matching display is connected.")
        }

        // Let CoreBrightness settle, then work out the lock for the new preset.
        try? await Task.sleep(for: .milliseconds(400))
        refreshPresets()
        evaluateLock()

        // 2. True Tone: forced off in a locked preset, otherwise the profile's value.
        let cb = CoreBrightness.shared
        if brightnessLocked {
            if p.trueTone != nil { trueToneBeforeLock = p.trueTone }   // restored when you leave the locked preset
        } else if let tt = p.trueTone, cb.trueToneSupported {
            cb.setTrueTone(tt)
            try? await Task.sleep(for: .milliseconds(250))
            if cb.trueToneEnabled != tt {
                warnings.append("True Tone stayed \(tt ? "off" : "on"). macOS may be holding it for this preset.")
            }
        }

        // 3. Night Shift.
        if cb.nightShiftAvailable {
            if let s = p.nightShiftStrength { cb.setNightShiftStrength(s, commit: true) }
            if let ns = p.nightShift {
                if warmthBlocked { nightShiftBeforeLock = ns } else { cb.setNightShift(ns) }
            }
        }

        // 4. Custom warmth, re-based on the new preset.
        tintEnabled = p.tintKelvin != nil
        if let k = p.tintKelvin { tintKelvin = Double(k) }
        UserDefaults.standard.set(tintEnabled, forKey: "tintEnabled")
        UserDefaults.standard.set(tintKelvin, forKey: "tintKelvin")
        GammaTint.shared.invalidate()
        if !applyTint() { warnings.append("The display ignored the custom warmth in this preset.") }

        activeProfileID = p.id
        readBrightnessClients()
        notice = warnings.isEmpty
            ? Notice(text: "Applied “\(p.name)”" + (brightnessLocked ? ". True Tone is locked off by this preset." : ""), isWarning: false)
            : Notice(text: warnings.joined(separator: "\n"), isWarning: true)
    }

    /// greycard://apply?name=Photography  ·  greycard://warmth?k=3400  ·  greycard://warmth?off
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "greycard" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host?.lowercased() {
        case "apply":
            let name = items.first { $0.name == "name" }?.value ?? url.pathComponents.dropFirst().first
            guard let name,
                  let p = profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                notice = Notice(text: "No profile named “\(url.lastPathComponent)”.", isWarning: true)
                return
            }
            Task { await apply(p) }
        case "warmth":
            if items.contains(where: { $0.name == "off" }) { setTintEnabled(false) }
            else if let k = items.first(where: { $0.name == "k" })?.value.flatMap(Double.init) {
                setTintKelvin(min(max(k, 1900), 10000))
            }
        default:
            break
        }
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            notice = Notice(text: "Launch at login: \(error.localizedDescription)", isWarning: true)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Keeping things applied

    private func observe() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleDisplaysChanged(after: 1.5) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .displaysReconfigured, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleDisplaysChanged(after: 0.8) }
        })
        Displays.registerReconfigurationCallback()

        // Every 2 s: catch preset changes made in Control Centre / System Settings,
        // re-lock True Tone if someone turns it back on, and re-apply warmth if macOS reset it.
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func scheduleDisplaysChanged(after seconds: Double) {
        reconfigTask?.cancel()
        reconfigTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.refresh()
            if self.tintEnabled { GammaTint.shared.invalidate(); self.applyTint() }
        }
    }

    private func tick() {
        guard !busy else { return }
        let previousPreset = activePresetID
        refreshPresets()
        evaluateLock()
        readBrightnessClients()
        if tintEnabled && (previousPreset != activePresetID || GammaTint.shared.needsReapply()) {
            GammaTint.shared.invalidate()
            applyTint()
        }
    }
}

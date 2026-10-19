import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls { AppModel.shared.handle(url: url) }
        }
    }
}

@main
struct GreycardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model: AppModel

    init() {
        if CommandLine.arguments.contains("--doctor") {
            Doctor.run()
            exit(0)
        }
        _model = ObservedObject(wrappedValue: AppModel.shared)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(systemName: "display")
        }
        .menuBarExtraStyle(.window)
    }
}

/// `Greycard --doctor` prints what this Mac exposes, without changing anything.
@MainActor
enum Doctor {
    static func run() {
        _ = NSApplication.shared
        let presets = CoreDisplayPresets.shared
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("CoreDisplay presets: read=\(presets.canRead) set=\(presets.canSet)")

        let cb = CoreBrightness.shared
        let tt = cb.trueToneRaw

        for d in Displays.active() {
            print("\nDisplay: \(d.name)  id=\(d.id)  uuid=\(d.uuid)")
            let activePreset = presets.activePreset(for: d.id)
            let list = presets.presets(for: d.id)
            if list.isEmpty { print("  (no presets)") }
            for p in list {
                print("  \(p.id == activePreset?.id ? "●" : "○") \(p.name)  [\(p.uniqueID ?? "no id")]")
            }
            print("  gamma table capacity: \(CGDisplayGammaTableCapacity(d.id))")

            let canChange = BrightnessLock.osAllowsBrightnessChange(d.id)
            let lock = BrightnessLock.detect(display: d.id, trueTone: tt)
            print("  brightness adjustable (DisplayServices): \(fmt(canChange))")
            print("  brightness-lock auto-detect: \(lock.locked ? "LOCKED – \(lock.reason ?? "")" : "not locked")")

            // Raw keys of the active preset: paste these back if lock detection needs refining.
            if let a = activePreset, let raw = presets.rawPreset(for: d.id, index: a.index) {
                print("  active preset raw keys:")
                for key in raw.keys.sorted() {
                    var value = String(describing: raw[key]!).replacingOccurrences(of: "\n", with: " ")
                    if value.count > 80 { value = String(value.prefix(80)) + "…" }
                    print("    \(key) = \(value)")
                }
            }
        }

        print("\nTrue Tone: supported=\(fmt(tt.supported)) available=\(fmt(tt.available)) enabled=\(fmt(tt.enabled))")
        print("Night Shift: available=\(cb.nightShiftAvailable) enabled=\(fmt(cb.nightShiftEnabled)) strength=\(cb.nightShiftStrength.map { String(format: "%.2f", $0) } ?? "n/a")")
    }

    private static func fmt(_ b: Bool?) -> String { b.map { $0 ? "yes" : "no" } ?? "n/a" }
}

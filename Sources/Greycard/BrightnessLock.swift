import Foundation
import CoreGraphics

/// Decides whether the active preset fixes brightness (e.g. Photography), the same condition
/// under which System Settings greys out the brightness slider.
///
/// Signals, in priority order:
///  1. Your per-preset override (stored in UserDefaults), if set.
///  2. DisplayServicesCanChangeBrightness() == false (private DisplayServices, as used by MonitorControl).
///  3. CoreBrightness reports True Tone supported but not available (macOS already disabled it).
@MainActor
enum BrightnessLock {
    struct Detection {
        var locked: Bool
        var reason: String?
    }

    private typealias CanChangeFn = @convention(c) (UInt32) -> Bool

    private static let canChange: CanChangeFn? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let p = dlsym(h, "DisplayServicesCanChangeBrightness") else { return nil }
        return unsafeBitCast(p, to: CanChangeFn.self)
    }()

    static var canQueryOS: Bool { canChange != nil }

    static func osAllowsBrightnessChange(_ display: CGDirectDisplayID) -> Bool? {
        canChange?(display)
    }

    static func detect(display: CGDirectDisplayID,
                       trueTone: (supported: Bool?, available: Bool?, enabled: Bool?)) -> Detection {
        if osAllowsBrightnessChange(display) == false {
            return Detection(locked: true, reason: "macOS reports brightness is fixed")
        }
        if trueTone.supported == true, trueTone.available == false {
            return Detection(locked: true, reason: "macOS disabled True Tone for this preset")
        }
        return Detection(locked: false, reason: nil)
    }

    // MARK: Per-preset overrides (true = always locked, false = never locked, nil = auto)

    private static let key = "brightnessLockOverrides"

    static func override(for presetID: String) -> Bool? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Bool])?[presetID]
    }

    static func setOverride(_ value: Bool?, for presetID: String) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: Bool]) ?? [:]
        all[presetID] = value
        UserDefaults.standard.set(all, forKey: key)
    }
}

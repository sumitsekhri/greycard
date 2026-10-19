import Foundation
import CoreGraphics

/// One Apple reference preset ("Photography (P3-D65)", "Internet & Web (sRGB)", …).
struct DisplayPreset: Identifiable, Hashable {
    let index: UInt32
    let name: String
    /// Stable ID from CoreDisplay (canonical UUID or hex). Survives reordering.
    let uniqueID: String?
    var id: String { uniqueID ?? "idx:\(index)" }
}

enum PresetError: LocalizedError {
    case apiUnavailable
    case rejected(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .apiUnavailable: return "Preset switching isn't available on this macOS version."
        case .rejected(let n): return "macOS rejected switching to “\(n)”."
        case .verificationFailed(let n): return "Switched to “\(n)” but couldn't confirm it took effect."
        }
    }
}

/// Wraps the undocumented CoreDisplay preset functions (same ones the refmode CLI uses).
/// Loaded with dlopen/dlsym so a missing symbol degrades gracefully instead of crashing.
@MainActor
final class CoreDisplayPresets {
    static let shared = CoreDisplayPresets()

    private typealias GetCountFn = @convention(c) (UInt32) -> UInt32
    private typealias GetActiveFn = @convention(c) (UInt32) -> Int32
    private typealias CopyPresetFn = @convention(c) (UInt32, UInt32) -> Unmanaged<CFDictionary>?
    private typealias SetActiveFn = @convention(c) (UInt32, UInt32) -> Bool

    private let getCount: GetCountFn?
    private let getActive: GetActiveFn?
    private let copyPreset: CopyPresetFn?
    private let setActive: SetActiveFn?

    private init() {
        let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL)
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        getCount = sym("CoreDisplay_Display_GetPresetCount", GetCountFn.self)
        getActive = sym("CoreDisplay_Display_GetActivePresetIndex", GetActiveFn.self)
        copyPreset = sym("CoreDisplay_Display_CopyPreset", CopyPresetFn.self)
        setActive = sym("CoreDisplay_Display_SetActivePresetIndex", SetActiveFn.self)
    }

    var canRead: Bool { getCount != nil && getActive != nil && copyPreset != nil }
    var canSet: Bool { setActive != nil }

    func presets(for display: CGDirectDisplayID) -> [DisplayPreset] {
        guard let getCount, let copyPreset else { return [] }
        let count = getCount(display)
        guard count > 0, count <= 4096 else { return [] }

        var result: [DisplayPreset] = []
        for i in 0..<count {
            guard let dict = copyPreset(display, i)?.takeRetainedValue() as? [String: Any] else { continue }
            guard (dict["PresetValid"] as? Bool) == true,
                  let name = dict["PresetName"] as? String, !name.isEmpty else { continue }
            result.append(DisplayPreset(index: i, name: name, uniqueID: Self.decodeID(dict["PresetUniqueID"])))
        }
        return result
    }

    /// Full raw dictionary for one preset (used by --doctor to discover keys).
    func rawPreset(for display: CGDirectDisplayID, index: UInt32) -> [String: Any]? {
        copyPreset?(display, index)?.takeRetainedValue() as? [String: Any]
    }

    func activePreset(for display: CGDirectDisplayID) -> DisplayPreset? {
        guard let getActive else { return nil }
        let idx = getActive(display)
        guard idx >= 0 else { return nil }
        return presets(for: display).first { $0.index == UInt32(idx) }
    }

    /// Switches preset, then polls until CoreDisplay reports it active (read-back verification).
    func setPreset(_ preset: DisplayPreset, on display: CGDirectDisplayID, timeout: TimeInterval = 3) async throws {
        guard let setActive else { throw PresetError.apiUnavailable }
        if activePreset(for: display)?.id == preset.id { return }
        guard setActive(display, preset.index) else { throw PresetError.rejected(preset.name) }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if activePreset(for: display)?.id == preset.id { return }
        }
        throw PresetError.verificationFailed(preset.name)
    }

    private static func decodeID(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        guard let data = value as? Data, !data.isEmpty else { return nil }
        if data.count == 16 {
            return data.withUnsafeBytes { raw -> String? in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
                return NSUUID(uuidBytes: base).uuidString.lowercased()
            }
        }
        return "hex:" + data.map { String(format: "%02x", $0) }.joined()
    }
}

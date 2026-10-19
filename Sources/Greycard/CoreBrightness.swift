import Foundation
import ObjectiveC

/// True Tone and Night Shift via the private CoreBrightness clients
/// (CBTrueToneClient / CBBlueLightClient — the same ones Shifty uses).
/// Methods are called through typed IMP pointers so BOOL/float arguments pass correctly.
@MainActor
final class CoreBrightness {
    static let shared = CoreBrightness()

    private let trueTone: NSObject?
    private let blueLight: NSObject?

    private init() {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        trueTone = (NSClassFromString("CBTrueToneClient") as? NSObject.Type)?.init()
        blueLight = (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()
    }

    // MARK: True Tone

    var trueToneRaw: (supported: Bool?, available: Bool?, enabled: Bool?) {
        (callBool(trueTone, "supported"), callBool(trueTone, "available"), callBool(trueTone, "enabled"))
    }

    var trueToneSupported: Bool {
        let s = trueToneRaw
        return trueTone != nil && s.enabled != nil && (s.supported ?? true) && (s.available ?? true)
    }

    var trueToneEnabled: Bool? { callBool(trueTone, "enabled") }

    @discardableResult
    func setTrueTone(_ on: Bool) -> Bool { callBool(trueTone, "setEnabled:", on) ?? false }

    // MARK: Night Shift

    var nightShiftAvailable: Bool { blueLightStatus != nil }
    var nightShiftEnabled: Bool? { blueLightStatus?.enabled }

    /// 0 = least warm, 1 = most warm (matches the System Settings slider).
    var nightShiftStrength: Float? {
        guard let obj = blueLight, let imp = imp(obj, "getStrength:") else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Float>) -> Bool
        var value: Float = 0
        let ok = unsafeBitCast(imp, to: Fn.self)(obj, NSSelectorFromString("getStrength:"), &value)
        return ok ? value : nil
    }

    @discardableResult
    func setNightShift(_ on: Bool) -> Bool { callBool(blueLight, "setEnabled:", on) ?? false }

    @discardableResult
    func setNightShiftStrength(_ value: Float, commit: Bool) -> Bool {
        guard let obj = blueLight, let imp = imp(obj, "setStrength:commit:") else { return false }
        typealias Fn = @convention(c) (AnyObject, Selector, Float, Bool) -> Bool
        let clamped = min(max(value, 0), 1)
        return unsafeBitCast(imp, to: Fn.self)(obj, NSSelectorFromString("setStrength:commit:"), clamped, commit)
    }

    /// Reads the first bytes of CoreBrightness's status struct: { BOOL active; BOOL enabled; … }.
    private var blueLightStatus: (active: Bool, enabled: Bool)? {
        guard let obj = blueLight, let imp = imp(obj, "getBlueLightStatus:") else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let size = 256
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        guard unsafeBitCast(imp, to: Fn.self)(obj, NSSelectorFromString("getBlueLightStatus:"), buffer) else { return nil }
        return (buffer.load(fromByteOffset: 0, as: UInt8.self) != 0,
                buffer.load(fromByteOffset: 1, as: UInt8.self) != 0)
    }

    // MARK: Typed message sends

    private func imp(_ obj: NSObject, _ name: String) -> IMP? {
        let sel = NSSelectorFromString(name)
        guard obj.responds(to: sel), let method = class_getInstanceMethod(type(of: obj), sel) else { return nil }
        return method_getImplementation(method)
    }

    private func callBool(_ obj: NSObject?, _ name: String) -> Bool? {
        guard let obj, let imp = imp(obj, name) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(imp, to: Fn.self)(obj, NSSelectorFromString(name))
    }

    private func callBool(_ obj: NSObject?, _ name: String, _ arg: Bool) -> Bool? {
        guard let obj, let imp = imp(obj, name) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Bool
        return unsafeBitCast(imp, to: Fn.self)(obj, NSSelectorFromString(name), arg)
    }
}

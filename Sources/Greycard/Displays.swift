import AppKit
import CoreGraphics

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
}

extension Notification.Name {
    static let displaysReconfigured = Notification.Name("Greycard.displaysReconfigured")
}

enum Displays {
    /// Active, non-mirror-follower displays with a stable UUID.
    static func active() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        return ids.prefix(Int(count)).compactMap { id -> DisplayInfo? in
            if CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay { return nil }
            guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            let uuid = CFUUIDCreateString(nil, cfUUID) as String
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
            return DisplayInfo(id: id, uuid: uuid, name: screen?.localizedName ?? "Display \(id)")
        }
    }

    static func registerReconfigurationCallback() {
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            if flags.contains(.beginConfigurationFlag) { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .displaysReconfigured, object: nil)
            }
        }, nil)
    }
}

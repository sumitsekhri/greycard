import Foundation
import CoreGraphics

/// f.lux/Iris-style colour temperature using the public gamma-table API.
/// Unlike Night Shift it goes both ways: below 6500K = warmer, above = cooler.
/// It multiplies the display's own ColorSync curve, so the active preset stays the base.
@MainActor
final class GammaTint {
    static let shared = GammaTint()

    private struct Table {
        var r: [CGGammaValue]
        var g: [CGGammaValue]
        var b: [CGGammaValue]
    }

    private var bases: [CGDirectDisplayID: Table] = [:]
    private var expected: [CGDirectDisplayID: Table] = [:]
    private(set) var kelvin: Int?

    /// Call after a preset change, wake, or display reconfiguration so the next apply re-reads the base curve.
    func invalidate() { bases.removeAll() }

    /// Returns false if any display refused or ignored the new curve.
    @discardableResult
    func apply(kelvin: Int?, to displays: [CGDirectDisplayID]) -> Bool {
        self.kelvin = kelvin
        guard let kelvin else {
            CGDisplayRestoreColorSyncSettings()
            bases.removeAll()
            expected.removeAll()
            return true
        }

        if displays.contains(where: { bases[$0] == nil }) {
            CGDisplayRestoreColorSyncSettings()   // capture a pristine base, not our previous tint
            bases.removeAll()
            for d in displays { if let t = Self.read(d) { bases[d] = t } }
        }

        let m = Self.multipliers(kelvin: kelvin)
        var allOK = true
        expected.removeAll()
        for d in displays {
            guard let base = bases[d] else { allOK = false; continue }
            let t = Table(r: base.r.map { $0 * m.r }, g: base.g.map { $0 * m.g }, b: base.b.map { $0 * m.b })
            let err = CGSetDisplayTransferByTable(d, UInt32(t.r.count), t.r, t.g, t.b)
            if err == .success, let back = Self.read(d), Self.matches(back, t) {
                expected[d] = t
            } else {
                allOK = false
            }
        }
        return allOK
    }

    /// True when something (macOS, a preset change from Control Centre) reset our curve.
    func needsReapply() -> Bool {
        guard kelvin != nil else { return false }
        for (d, t) in expected {
            guard let now = Self.read(d), Self.matches(now, t) else { return true }
        }
        return false
    }

    // MARK: Helpers

    private static func read(_ d: CGDirectDisplayID) -> Table? {
        let cap = CGDisplayGammaTableCapacity(d)
        guard cap > 0 else { return nil }
        var r = [CGGammaValue](repeating: 0, count: Int(cap))
        var g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(d, cap, &r, &g, &b, &count) == .success, count > 0 else { return nil }
        let n = Int(count)
        return Table(r: Array(r.prefix(n)), g: Array(g.prefix(n)), b: Array(b.prefix(n)))
    }

    /// Compares the midpoint and top of each channel (tables can be resampled, so not every entry).
    private static func matches(_ a: Table, _ b: Table) -> Bool {
        func sample(_ x: [CGGammaValue], _ fraction: Double) -> CGGammaValue? {
            guard !x.isEmpty else { return nil }
            return x[min(x.count - 1, Int(Double(x.count - 1) * fraction))]
        }
        for f in [0.5, 1.0] {
            for (x, y) in [(a.r, b.r), (a.g, b.g), (a.b, b.b)] {
                guard let p = sample(x, f), let q = sample(y, f), abs(p - q) <= 0.02 else { return false }
            }
        }
        return true
    }

    /// Tanner Helland's blackbody approximation, normalised so 6500K = neutral and the brightest channel = 1.
    static func multipliers(kelvin: Int) -> (r: Float, g: Float, b: Float) {
        func raw(_ k: Double) -> (Double, Double, Double) {
            let t = k / 100
            let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
            let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
            let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
            func c(_ v: Double) -> Double { min(max(v, 0), 255) / 255 }
            return (c(r), c(g), c(b))
        }
        let ref = raw(6500)
        let v = raw(Double(min(max(kelvin, 1000), 15000)))
        var r = v.0 / ref.0, g = v.1 / ref.1, b = v.2 / ref.2
        let peak = max(r, g, b)
        r /= peak; g /= peak; b /= peak
        return (Float(r), Float(g), Float(b))
    }
}

import Foundation

/// A saved combination of display settings.
/// `nil` on True Tone / Night Shift means "leave as is". `tintKelvin == nil` means custom warmth OFF.
struct DisplayProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var displayUUID: String?
    var presetName: String?
    var presetID: String?
    var trueTone: Bool?
    var nightShift: Bool?
    var nightShiftStrength: Float?
    var tintKelvin: Int?

    var summary: String {
        var parts: [String] = []
        if let presetName { parts.append(presetName.components(separatedBy: " (").first ?? presetName) }
        if let trueTone { parts.append("True Tone \(trueTone ? "on" : "off")") }
        if let nightShift, nightShift { parts.append("Night Shift") }
        parts.append(tintKelvin.map { "\($0)K" } ?? "no tint")
        return parts.joined(separator: " · ")
    }
}

struct ProfileStore {
    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Greycard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }

    func load() -> [DisplayProfile] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DisplayProfile].self, from: data)) ?? []
    }

    func save(_ profiles: [DisplayProfile]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(profiles).write(to: url, options: .atomic)
    }
}

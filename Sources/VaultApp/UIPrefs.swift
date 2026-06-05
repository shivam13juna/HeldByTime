// UIPrefs.swift — the app's cosmetic, non-secret UI preferences (currently just
// the light/dark appearance choice), persisted as plain JSON in its OWN file
// (ui.json). Kept Foundation-only — no SwiftUI — so AppModel, which loads and
// holds a UIPrefs, compiles and is unit-tested in the offline, headless test
// binary. The single SwiftUI-typed bit (Appearance → ColorScheme) is an
// extension in Theme.swift, the only file here that imports SwiftUI.
//
// Security note (unchanged): the appearance choice is cosmetic and lives in its
// own file so a missing/old install or a decode failure here falls back to the
// default WITHOUT touching schedule.json — the user's time-lock windows are never
// at risk from a UI-prefs problem.

import Foundation

/// The user's light/dark choice. `.system` follows the OS; the other two pin it.
/// (Its SwiftUI `colorScheme` mapping is an extension in Theme.swift.)
enum Appearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

/// Cosmetic, non-secret UI preferences. Persisted as plain JSON in its own file
/// so it is independent of the schedule (a decode failure here can never clobber
/// the user's windows). New fields default AND decode-tolerantly (see the custom
/// `init(from:)`), so an older ui.json still loads without resetting the fields it
/// does contain.
struct UIPrefs: Codable, Equatable {
    var appearance: Appearance = .system

    /// Notify-only update check (no download / no install). When true (default), the
    /// app asks GitHub's PUBLIC releases endpoint on launch whether a newer version
    /// exists and shows a dismissible banner. Cosmetic + non-secret like the
    /// appearance — it never touches a vault, a password, or a schedule.
    var autoCheckUpdates: Bool = true
    /// A release the user chose to skip; the banner stays hidden until a version
    /// strictly newer than this appears. A public version string — non-secret.
    var skippedUpdateVersion: String? = nil
    /// When the last update check ran, so relaunching throttles to ~once per
    /// interval instead of hitting GitHub every launch.
    var lastUpdateCheck: Date? = nil

    static let `default` = UIPrefs()

    static func load(from url: URL) throws -> UIPrefs {
        try JSONDecoder().decode(UIPrefs.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

extension UIPrefs {
    /// Tolerant decode: every field falls back to its default when ABSENT, so an
    /// older ui.json (written before a field existed) still loads WITHOUT resetting
    /// the fields it does contain — e.g. a saved appearance survives an upgrade that
    /// adds the update-check fields. Synthesized Decodable would instead throw on a
    /// missing key, which (via `load`'s caller falling back to `.default`) would
    /// silently wipe the user's appearance. A present-but-wrong-TYPE value still
    /// throws, exactly as before. The memberwise/`init()` initializers stay
    /// synthesized because this lives in an extension, not the struct body.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UIPrefs()
        self.appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? d.appearance
        self.autoCheckUpdates = try c.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? d.autoCheckUpdates
        self.skippedUpdateVersion = try c.decodeIfPresent(String.self, forKey: .skippedUpdateVersion) ?? d.skippedUpdateVersion
        self.lastUpdateCheck = try c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck) ?? d.lastUpdateCheck
    }
}

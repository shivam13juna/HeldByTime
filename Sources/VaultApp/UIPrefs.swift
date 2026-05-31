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
/// the user's windows). New fields should default so older files still decode.
struct UIPrefs: Codable, Equatable {
    var appearance: Appearance = .system

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

// AppConfiguration.swift — Task 9: where the app's files and the bundled helper
// live, plus the user-editable schedule (windows) and its persistence. None of
// this is secret: paths, the helper hash (integrity, not a key), and the daily
// window times. The schedule is stored as plain JSON beside the vault.

import Foundation

/// Filesystem + bundled-helper locations. `.live` is the shipped configuration;
/// the helper hash is compiled in by the Task 11 bundling step.
struct AppConfiguration {
    /// The vault directory (created 0700, excluded from OS backups by VaultStore).
    let vaultDir: URL
    /// Absolute path to the bundled `vaultseal` (Task 11 embeds + signs it here).
    let helperURL: URL
    /// SHA-256 of the bundled helper, compiled into the app at bundling time
    /// (NEVER read from a writable sidecar — app.md §9). Sourced from
    /// `BundledHelper.sha256`, which `build.sh` injects; empty in a non-bundled
    /// build, which makes the launch preflight fail closed by design.
    let compiledHelperSHA256: [UInt8]
    /// Where the (non-secret) schedule preferences are persisted.
    var schedulePrefsURL: URL { vaultDir.appendingPathComponent("schedule.json") }
    /// Where the cosmetic UI preferences (appearance) are persisted. A SEPARATE
    /// file from the schedule so a UI-prefs decode failure never clobbers windows.
    var uiPrefsURL: URL { vaultDir.appendingPathComponent("ui.json") }

    static var live: AppConfiguration {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("EncryptedVault", isDirectory: true)
        // Inside the .app: Contents/Helpers/vaultseal (Task 11 lays this out).
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/vaultseal")
        return AppConfiguration(vaultDir: dir, helperURL: helper,
                                compiledHelperSHA256: BundledHelper.sha256)
    }
}

/// One configured daily window, as plain hour/minute components (TimeOfDay is not
/// Codable and has a failable init, so this DTO is the persisted shape).
struct WindowPrefs: Codable, Equatable, Identifiable {
    var id = UUID()
    var startHour: Int
    var startMinute: Int
    var endHour: Int
    var endMinute: Int

    private enum CodingKeys: String, CodingKey { case startHour, startMinute, endHour, endMinute }

    /// Convert to a VaultCore `DailyWindow`, or nil if any component is invalid.
    var dailyWindow: DailyWindow? {
        guard let s = TimeOfDay(hour: startHour, minute: startMinute),
              let e = TimeOfDay(hour: endHour, minute: endMinute) else { return nil }
        return DailyWindow(start: s, end: e)
    }
}

/// The user's schedule preferences plus the calendar (time zone) used to map
/// windows to rounds. Persisted as JSON; the default is the app.md §5 example.
struct SchedulePrefs: Codable, Equatable {
    var windows: [WindowPrefs]

    static var `default`: SchedulePrefs {
        SchedulePrefs(windows: [WindowPrefs(startHour: 4, startMinute: 0, endHour: 5, endMinute: 0)])
    }

    /// The current-locale calendar carries the local time zone for round mapping.
    var calendar: Calendar { .current }

    /// Build the VaultCore `Schedule`. Invalid window components are dropped here;
    /// an empty result still constructs a `Schedule` whose `nextLock` fails closed
    /// with `.noWindows` (never an accidental always-open vault).
    var schedule: Schedule {
        Schedule(windows: windows.compactMap { $0.dailyWindow }, calendar: calendar)
    }

    static func load(from url: URL) throws -> SchedulePrefs {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SchedulePrefs.self, from: data)
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

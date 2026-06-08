// AppConfiguration.swift — where each VAULT's files and the bundled helper live,
// plus the per-vault schedule (windows) and its persistence, and the app-global
// AppEnvironment that ties together the vaults root and shared (non-vault) files.
// None of this is secret: paths, the helper hash (integrity, not a key), and the
// daily window times. The schedule is stored as plain JSON beside its vault.
//
// Multi-vault layout (one subdirectory per vault under the root):
//   EncryptedVault/                 ← AppEnvironment.vaultsRoot
//     ui.json                       ← app-global appearance (shared by all vaults)
//     app.log                       ← app-scope diagnostics (launch / agent install)
//     <uuid>/                       ← one vault (AppConfiguration.vaultDir)
//       vault.dat, vault.dat.bak
//       schedule.json               ← this vault's windows
//       diagnostics.log             ← this vault's secret-free trail
//       meta.json                   ← this vault's label (VaultRegistry)

import Foundation

/// Per-VAULT filesystem + bundled-helper locations. A vault is self-contained in
/// its `vaultDir`; everything below is resolved relative to it.
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
    /// Where this vault's (non-secret) schedule preferences are persisted.
    var schedulePrefsURL: URL { vaultDir.appendingPathComponent("schedule.json") }
    /// Where this vault's SECRET-FREE diagnostics trail lives (app + agent append;
    /// DiagnosticsView reads it). Non-secret by construction — see DiagnosticLog.
    var diagnosticsLogURL: URL { vaultDir.appendingPathComponent("diagnostics.log") }
    /// This vault's two on-disk copies (primary + `.bak`), mirroring
    /// `VaultStore.primaryURL` / `backupURL`. Used by the list advisory to peek the
    /// plaintext VLT1 window — read-only DISPLAY hints; the authoritative read is
    /// always VaultStore over `vaultDir`.
    var vaultPrimaryURL: URL { vaultDir.appendingPathComponent(VaultRegistry.vaultFileName) }
    var vaultBackupURL: URL { vaultDir.appendingPathComponent(VaultRegistry.vaultFileName + ".bak") }
}

/// APP-GLOBAL locations shared across all vaults: the vaults root (parent of every
/// per-vault subdirectory), the bundled helper + its compiled-in hash, and the
/// non-vault files that live at the root (appearance, app-scope diagnostics).
/// Per-vault `AppConfiguration`s are derived from a vault's directory.
struct AppEnvironment {
    /// …/Application Support/EncryptedVault — the parent of all vault subdirs.
    let vaultsRoot: URL
    let helperURL: URL
    let compiledHelperSHA256: [UInt8]

    /// App-global cosmetic appearance (shared by every vault), at the root — NOT
    /// inside any vault, so deleting a vault never disturbs it.
    var uiPrefsURL: URL { vaultsRoot.appendingPathComponent("ui.json") }
    /// App-scope diagnostics (launch, agent registration) — events not tied to a
    /// single vault. A distinct file from any vault's diagnostics.log, and not
    /// removed by the legacy-purge.
    var appLogURL: URL { vaultsRoot.appendingPathComponent("app.log") }

    /// The registry over the root (enumerate / create / delete / rename vaults).
    var registry: VaultRegistry { VaultRegistry(root: vaultsRoot) }

    /// The per-vault configuration for a given vault directory / entry.
    func configuration(forVaultDir dir: URL) -> AppConfiguration {
        AppConfiguration(vaultDir: dir, helperURL: helperURL,
                         compiledHelperSHA256: compiledHelperSHA256)
    }
    func configuration(for entry: VaultEntry) -> AppConfiguration {
        configuration(forVaultDir: entry.dir)
    }

    /// The shipped environment; the helper hash is compiled in at bundling time
    /// (empty in a non-bundled build ⇒ every vault's preflight fails closed).
    static var live: AppEnvironment {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let root = support.appendingPathComponent("EncryptedVault", isDirectory: true)
        // Inside the .app: Contents/Helpers/vaultseal (Task 11 lays this out).
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/vaultseal")
        return AppEnvironment(vaultsRoot: root, helperURL: helper,
                              compiledHelperSHA256: BundledHelper.sha256)
    }

    /// The environment for the headless re-seal agent (Contents/Helpers/vaultreseal).
    /// The agent is NOT the .app — it runs as a loose executable nested in the
    /// bundle — so `Bundle.main.bundleURL` is the Helpers directory, not the app.
    /// The `vaultseal` helper is therefore the agent's SIBLING, resolved relative
    /// to the agent's own executable; the vaults root is the same user-domain path
    /// the app uses, so the agent enumerates the exact same vaults. Same compiled-in
    /// helper hash ⇒ the agent's HelperRunner preflight is as strict as the app's.
    /// Returns nil if the executable location can't be resolved (agent fails closed).
    static func resealAgent() -> AppEnvironment? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let helper = exe.deletingLastPathComponent().appendingPathComponent("vaultseal")
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let root = support.appendingPathComponent("EncryptedVault", isDirectory: true)
        return AppEnvironment(vaultsRoot: root, helperURL: helper,
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

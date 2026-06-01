// ResealAgentInstaller.swift — the app-side, side-effecting half of the re-seal
// LaunchAgent (the pure spec is LaunchAgentPlist in VaultCore). On launch the app
// (re)writes the per-user plist pointing at the CURRENT bundle's vaultreseal and
// (re)bootstraps it with launchctl, so the periodic re-seal stays live even if
// the app is never opened again — and self-heals if the .app was moved.
//
// User domain only: the plist lives in ~/Library/LaunchAgents and is loaded into
// the user's GUI session (gui/<uid>). NO admin/sudo, consistent with the standard
// account. Best-effort: every failure is swallowed — the app must still run if
// launchctl is unavailable; the agent simply won't be (re)registered this launch.
//
// This installer NEVER touches a secret and NEVER logs (the leak/logging fence
// forbids print/NSLog here); it only writes a non-secret plist and shells out to
// /bin/launchctl, exactly as the app already shells out to the vaultseal helper.

import Foundation

enum ResealAgentInstaller {
    /// The bundled agent executable: Contents/Helpers/vaultreseal, beside vaultseal.
    static var agentExecutableURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/vaultreseal")
    }

    /// Where the user-domain LaunchAgent plist is written.
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(LaunchAgentPlist.resealLabel).plist")
    }

    /// (Re)write the plist for the current bundle path and (re)bootstrap it.
    /// Idempotent: bootout-then-bootstrap refreshes a stale program path (and the
    /// window-end calendar triggers), and — when `kickstart` is true (the default) —
    /// a kickstart makes it run once right now. Pass `kickstart: false` for a pure
    /// trigger RELOAD (e.g. after a schedule edit) that must reload the new triggers
    /// without running the agent now.
    /// Returns true if the plist was written and (re)bootstrap was attempted;
    /// false if there is nothing to install (no bundled agent / can't write).
    ///
    /// The three side effects — whether the agent binary exists, persisting the
    /// plist, and running launchctl — plus the target locations and `uid` are
    /// injected with the LIVE defaults below, so the install ACT is unit-testable
    /// offline (no launchd, no real filesystem) while the production call site
    /// (`AppModel.bootstrap`) keeps using the zero-argument form for identical
    /// behaviour. The seam touches no secret and still never logs.
    @discardableResult
    static func installOrRefresh(
        agentURL: URL = agentExecutableURL,
        plistURL: URL = Self.plistURL,
        uid: uid_t = getuid(),
        calendarTimes: [DailyFireTime] = [],
        kickstart: Bool = true,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        writePlist: (Data, URL) throws -> Void = { data, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        },
        run: ([String]) -> Void = Self.launchctl
    ) -> Bool {
        // Only install once the agent binary is actually present (i.e. a real
        // bundled build, not a bare dev run) — otherwise launchd would spawn a
        // missing path on a timer.
        guard fileExists(agentURL.path) else { return false }

        let plist = LaunchAgentPlist.reseal(programPath: agentURL.path, calendarTimes: calendarTimes)
        guard !plist.isEmpty else { return false }

        do {
            try writePlist(plist, plistURL)
        } catch {
            return false   // can't persist the plist — nothing to bootstrap.
        }

        let domain = "gui/\(uid)"
        // bootout an old definition (ignore "not loaded"), then bootstrap fresh, then
        // — unless this is a pure trigger reload — kickstart so it runs immediately.
        run(["bootout", domain, plistURL.path])
        run(["bootstrap", domain, plistURL.path])
        if kickstart { run(["kickstart", "\(domain)/\(LaunchAgentPlist.resealLabel)"]) }
        return true
    }

    /// Remove the re-seal LaunchAgent — the inverse of `installOrRefresh`. Unloads
    /// the job from the user's GUI session and deletes its plist so launchd will
    /// not reload it at the next login. Touches ONLY the agent (its own label +
    /// plist) — it has no vault parameters and so CANNOT reach a vault. Best-effort
    /// and injectable the same way as install (`fileExists`, `removeFile`, the
    /// launchctl `run`, plus `uid`/`plistURL`), so the act is unit-testable offline
    /// (no launchd, no real filesystem). Never logs; handles no secret.
    ///
    /// Returns true if the agent is gone afterwards (removed now, or already
    /// absent); false ONLY if the plist exists but could not be deleted.
    @discardableResult
    static func uninstall(
        plistURL: URL = Self.plistURL,
        uid: uid_t = getuid(),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        removeFile: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        run: ([String]) -> Void = Self.launchctl
    ) -> Bool {
        let domain = "gui/\(uid)"
        // Unload the loaded job by LABEL (harmless if it isn't loaded). By label,
        // not by plist path, so it still works if the plist is already gone.
        run(["bootout", "\(domain)/\(LaunchAgentPlist.resealLabel)"])
        // Delete the plist so launchd won't reload it at the next login.
        guard fileExists(plistURL.path) else { return true }   // already absent ⇒ done
        do { try removeFile(plistURL) } catch { return false } // couldn't delete ⇒ failed
        return true
    }

    /// Run a launchctl subcommand, discarding output and ignoring failure. This is
    /// the live default for `installOrRefresh(run:)`; tests inject a recording fake.
    static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { /* best-effort */ }
    }
}

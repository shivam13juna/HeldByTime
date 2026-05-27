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
    /// Idempotent: bootout-then-bootstrap refreshes a stale program path, and a
    /// kickstart makes it run once right now (don't wait for the first interval).
    /// Returns true if the plist was written and (re)bootstrap was attempted;
    /// false if there is nothing to install (no bundled agent / can't write).
    @discardableResult
    static func installOrRefresh() -> Bool {
        // Only install once the agent binary is actually present (i.e. a real
        // bundled build, not a bare dev run) — otherwise launchd would spawn a
        // missing path on a timer.
        let agent = agentExecutableURL
        guard FileManager.default.fileExists(atPath: agent.path) else { return false }

        let plist = LaunchAgentPlist.reseal(programPath: agent.path)
        guard !plist.isEmpty else { return false }

        let dir = plistURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try plist.write(to: plistURL, options: .atomic)
        } catch {
            return false   // can't persist the plist — nothing to bootstrap.
        }

        let domain = "gui/\(getuid())"
        // bootout an old definition (ignore "not loaded"), then bootstrap fresh,
        // then kickstart so it runs immediately.
        launchctl(["bootout", domain, plistURL.path])
        launchctl(["bootstrap", domain, plistURL.path])
        launchctl(["kickstart", "\(domain)/\(LaunchAgentPlist.resealLabel)"])
        return true
    }

    /// Run a launchctl subcommand, discarding output and ignoring failure.
    private static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { /* best-effort */ }
    }
}

// LaunchAgentPlist.swift — the (non-secret) specification of the per-user
// LaunchAgent that periodically runs the reveal-incapable re-seal helper
// (Contents/Helpers/vaultreseal). Pure value logic: it builds the launchd
// property-list bytes and names the agent; it touches no files and runs no
// process (that side-effecting work lives in ResealAgentInstaller in the app
// layer). Kept here so it is type-checked by the gate and unit-tested offline.
//
// WHY this agent exists (app.md threat model): once a daily window passes
// UN-opened, the on-disk vault drops to the `expired` state — its drand round
// has published, so the time-lock layer is open and the blob is protected by
// the password ALONE. That is the one moment a weaker future self could pounce
// (e.g. lift vault.dat out of ~/Library and decrypt it out of window). The agent
// runs VaultStore.load() on a schedule; load() re-seals an expired copy FORWARD
// (passwordless, reusing the PW01 bytes verbatim — it can ONLY re-lock, never
// open), shrinking that exposure window from "until I next launch the app" down
// to at most one agent interval. After a re-seal the blob is sealed to a FUTURE
// round again: the key does not exist yet, so nothing — not the password, not a
// terminal, not a file copy — can open it. The agent is adversarial to the
// future self by construction.

import Foundation

/// Names and serialises the re-seal LaunchAgent. Nothing here is secret; the
/// plist is just a path + schedule.
enum LaunchAgentPlist {
    /// The launchd job label (also the plist filename stem and the kickstart
    /// target). Stable so install is idempotent across launches.
    static let resealLabel = "com.shivam.encryptedvault.reseal"

    /// How often launchd fires the agent while the machine is awake. launchd
    /// COALESCES fires missed during sleep/shutdown into a single run on wake,
    /// and re-fires on the next interval if a run failed (e.g. offline) — so this
    /// one knob also gives free sleep-catch-up and retry. 2h ⇒ ~12 attempts/day.
    static let defaultIntervalSeconds = 7200

    /// Build the launchd plist bytes for the re-seal agent. Uses
    /// `PropertyListSerialization` so the output is always well-formed and the
    /// program path is correctly XML-escaped (no hand-rolled XML).
    ///
    /// - `RunAtLoad` runs it once at login (and at install time we kickstart it).
    /// - `StartInterval` drives the periodic + wake-catch-up + retry behaviour.
    /// - `ProcessType=Background` keeps it low-priority; stdio is sent to
    ///   /dev/null so the agent leaves no log surface.
    static func reseal(programPath: String,
                       intervalSeconds: Int = defaultIntervalSeconds) -> Data {
        let job: [String: Any] = [
            "Label": resealLabel,
            "ProgramArguments": [programPath],
            "RunAtLoad": true,
            "StartInterval": intervalSeconds,
            "ProcessType": "Background",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        // These fixed key/value types always serialise; an empty result would be
        // caught by the installer (it refuses to write an empty plist).
        return (try? PropertyListSerialization.data(fromPropertyList: job,
                                                    format: .xml, options: 0)) ?? Data()
    }
}

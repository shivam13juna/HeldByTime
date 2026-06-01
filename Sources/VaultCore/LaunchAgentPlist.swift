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
// to at most one agent interval. `StartCalendarInterval` entries (one per
// window-end, see `fireTimes`) tighten that further: launchd also wakes the agent
// within a minute of each window closing, so the typical exposure is seconds, not
// the full interval — which remains the safety net for sleep, missed fires, and
// schedules edited since the last launch. After a re-seal the blob is sealed to a FUTURE
// round again: the key does not exist yet, so nothing — not the password, not a
// terminal, not a file copy — can open it. The agent is adversarial to the
// future self by construction.

import Foundation

/// A daily wall-clock minute at which launchd should additionally fire the re-seal
/// agent — one `StartCalendarInterval` entry. Minute-granular (launchd's finest
/// calendar granularity), which is exactly the schedule's own granularity.
struct DailyFireTime: Equatable, Hashable {
    let hour: Int     // 0...23
    let minute: Int   // 0...59
}

/// Names and serialises the re-seal LaunchAgent. Nothing here is secret; the
/// plist is just a path + schedule.
enum LaunchAgentPlist {
    /// The launchd job label (also the plist filename stem and the kickstart
    /// target). Stable so install is idempotent across launches.
    static let resealLabel = "app.encryptedvault.reseal"

    /// How often launchd fires the agent while the machine is awake. launchd
    /// COALESCES fires missed during sleep/shutdown into a single run on wake,
    /// and re-fires on the next interval if a run failed (e.g. offline) — so this
    /// one knob also gives free sleep-catch-up and retry. 2h ⇒ ~12 attempts/day.
    /// With `StartCalendarInterval` boundaries now doing the precise window-end
    /// re-seal, this is the coarse SAFETY NET, not the primary trigger.
    static let defaultIntervalSeconds = 7200

    /// The agent fire-times for a set of daily windows: each window's END advanced
    /// by `marginMinutes` (default 1). The margin guarantees the end round has
    /// published and the vault has crossed into `expired` by the time the agent
    /// runs — drand's period is a few seconds, so one minute is ample, and it also
    /// clears the inclusive `R == endRound` boundary (still "open window"). Wraps
    /// past midnight, de-duplicates, and sorts, so identical ends across vaults
    /// collapse to one launchd entry and the generated plist is byte-stable. An
    /// empty input yields no entries (the agent then relies on `StartInterval`
    /// alone, exactly as before these boundaries existed). The window-end's seconds
    /// are intentionally dropped — launchd is minute-granular and the +1min margin
    /// covers any sub-minute remainder.
    static func fireTimes(forWindowEnds windows: [DailyWindow],
                          marginMinutes: Int = 1) -> [DailyFireTime] {
        let minutes = windows.map { window -> Int in
            let end = window.end.hour * 60 + window.end.minute
            return ((end + marginMinutes) % 1440 + 1440) % 1440   // normalise into [0,1440)
        }
        return Set(minutes).sorted().map { DailyFireTime(hour: $0 / 60, minute: $0 % 60) }
    }

    /// Build the launchd plist bytes for the re-seal agent. Uses
    /// `PropertyListSerialization` so the output is always well-formed and the
    /// program path is correctly XML-escaped (no hand-rolled XML).
    ///
    /// - `RunAtLoad` runs it once at login (and at install time we kickstart it).
    /// - `StartInterval` drives the periodic + wake-catch-up + retry behaviour.
    /// - `StartCalendarInterval` (only when `calendarTimes` is non-empty) ALSO
    ///   fires it at each given wall-clock minute — the window-end boundaries, so
    ///   an expired vault re-seals within a minute of its window closing instead of
    ///   waiting up to a full `StartInterval`. Both triggers coexist; the interval
    ///   stays as the safety net.
    /// - `ProcessType=Background` keeps it low-priority; stdio is sent to
    ///   /dev/null so the agent leaves no log surface.
    static func reseal(programPath: String,
                       intervalSeconds: Int = defaultIntervalSeconds,
                       calendarTimes: [DailyFireTime] = []) -> Data {
        var job: [String: Any] = [
            "Label": resealLabel,
            "ProgramArguments": [programPath],
            "RunAtLoad": true,
            "StartInterval": intervalSeconds,
            "ProcessType": "Background",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        // Window-end boundaries, when supplied. Omitted entirely when empty so the
        // plist is byte-identical to the interval-only form (no behavioural change
        // for a vault-less / schedule-less install).
        if !calendarTimes.isEmpty {
            job["StartCalendarInterval"] = calendarTimes.map {
                ["Hour": $0.hour, "Minute": $0.minute]
            }
        }
        // These fixed key/value types always serialise; an empty result would be
        // caught by the installer (it refuses to write an empty plist).
        return (try? PropertyListSerialization.data(fromPropertyList: job,
                                                    format: .xml, options: 0)) ?? Data()
    }
}

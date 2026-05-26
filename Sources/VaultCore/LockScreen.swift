// LockScreen.swift — Task 9: pure presentation logic for the locked/unlock
// screen. Kept in VaultCore (no SwiftUI) so the mapping from a `VaultLoadResult`
// to human-facing text is unit-testable; the SwiftUI `LockedView`/`UnlockView`
// only render the `LockScreenInfo` this produces.
//
// CRITICAL: this is DISPLAY only. The "locked until" time is derived from the
// UNTRUSTED VLT1 display hint (or a committed start round) purely to tell the
// user when to come back — it never authorizes access. Authorization is the
// unseal-as-gate in VaultStore.load(); a result of `.openWindow` is the ONLY
// thing that lets the password prompt appear (`canPrompt`).

import Foundation

struct LockScreenInfo: Equatable {
    let title: String
    let message: String
    /// A formatted local time the vault is expected to open, when known. Shown
    /// as guidance only; nil when there is no meaningful hint (offline) or it is
    /// irrelevant (open / fail-closed).
    let untilLocalTime: String?
    /// True ONLY when the load result authorizes showing the password prompt
    /// (i.e. `.openWindow`). Every other state must keep the prompt hidden.
    let canPrompt: Bool
    /// True when retrying the load could change the outcome (offline) — the view
    /// offers a Retry button. A hard fail-closed state does not.
    let canRetry: Bool
}

enum LockScreen {
    /// Map a load result to what the lock screen should say. `now`/`calendar`
    /// only affect the formatted "until" time (the calendar carries the time
    /// zone); the security decision was already made by `VaultStore.load()`.
    static func describe(_ result: VaultLoadResult,
                         calendar: Calendar = .current) -> LockScreenInfo {
        switch result {
        case .openWindow:
            return LockScreenInfo(
                title: "Window open",
                message: "Your window is open. Enter your vault password to unlock.",
                untilLocalTime: nil, canPrompt: true, canRetry: false)

        case .lockedUntil(let displayStartRound):
            let until = displayStartRound.map { Self.localTime(forRound: $0, calendar: calendar) }
            let when = until.map { " Expected to open around \($0)." } ?? ""
            return LockScreenInfo(
                title: "Locked",
                message: "The vault is sealed until its next window.\(when) "
                    + "It cannot be opened early — not by password, not by changing the clock.",
                untilLocalTime: until, canPrompt: false, canRetry: true)

        case .resealed(let window):
            let until = Self.localTime(forRound: window.startRound, calendar: calendar)
            return LockScreenInfo(
                title: "Re-locked",
                message: "The vault was past its window and has been sealed forward "
                    + "to the next one. Expected to open around \(until).",
                untilLocalTime: until, canPrompt: false, canRetry: true)

        case .offline:
            return LockScreenInfo(
                title: "Offline",
                message: "Can't reach the time-lock network (drand) to verify the time. "
                    + "The vault stays sealed until you're back online. "
                    + "If you use Canopy, make sure api.drand.sh is whitelisted.",
                untilLocalTime: nil, canPrompt: false, canRetry: true)

        case .failClosed(let reason):
            return LockScreenInfo(
                title: "Unavailable",
                message: "The vault could not be opened and access is refused for safety. "
                    + "Details: \(reason)",
                untilLocalTime: nil, canPrompt: false, canRetry: false)
        }
    }

    /// Format the publication instant of `round` in the calendar's time zone.
    private static func localTime(forRound round: UInt64, calendar: Calendar) -> String {
        let date = TrustedTime.date(forRound: round)
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

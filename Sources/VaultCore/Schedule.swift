// Schedule.swift — Task 5: turn the user's daily open-windows into the next
// LOCK target (a start round + end round for the manifest). app.md §5.
//
// The contract this file must satisfy, and why each clause exists:
//
//  * Windows are wall-clock local time (e.g. 04:00–05:00), recurring daily. They
//    are anchored to a `Calendar` (which carries the time zone) so DST and
//    midnight-crossing are handled by the calendar, not by adding fixed seconds —
//    a "04:00" window stays at 04:00 wall-clock on a 23- or 25-hour DST day.
//
//  * The chosen start must be STRICTLY in the future AND clear two independent
//    floors (app.md §5), or we skip forward to the window's next daily occurrence:
//      - freshness:   startRound > verifiedLatest + FRESHNESS_MARGIN_ROUNDS, so
//                     the helper's own seal-freshness rule (§9) will accept the
//                     target. The schedule and the helper must agree or the vault
//                     wedges on a rejected re-seal at a boundary.
//      - minimum lock: startRound − nowRound >= MIN_LOCK_DURATION_ROUNDS, so a
//                     Lock seconds before the window opens does not produce a
//                     near-zero commitment. nowRound is the local-clock round; a
//                     standard account cannot wind it back, and the helper's
//                     stale-round defence catches a clock pushed forward.
//
//  * Among all configured windows we pick the soonest VALID start (smallest start
//    round). This subsumes "adjacent" and "overlapping" windows — there is no
//    special case, just the minimum over candidates.
//
// Fail-closed: anything we cannot turn into a clean future target (no windows, a
// window too short to span a round, or nothing valid within the lookahead
// horizon) returns a `ScheduleError`. We never emit a target the helper would
// reject, and never silently widen a window.

import Foundation

/// A wall-clock time of day in the schedule's calendar/time zone.
struct TimeOfDay: Equatable {
    let hour: Int
    let minute: Int
    let second: Int

    /// Returns nil for out-of-range components (fail closed at construction).
    init?(hour: Int, minute: Int, second: Int = 0) {
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
            return nil
        }
        self.hour = hour; self.minute = minute; self.second = second
    }

    /// Seconds since local midnight — only for the midnight-crossing comparison.
    var secondsOfDay: Int { hour * 3600 + minute * 60 + second }
}

/// One recurring daily open-window. `end < start` (by seconds-of-day) means the
/// window crosses midnight, so its end falls on the following calendar day.
/// `end == start` is NOT a 24-hour window — it has zero wall-clock span and is
/// rejected as degenerate (this is a time-LOCK, an always-open window is meaningless).
struct DailyWindow: Equatable {
    let start: TimeOfDay
    let end: TimeOfDay

    var crossesMidnight: Bool { end.secondsOfDay < start.secondsOfDay }
}

enum ScheduleError: Error, Equatable {
    case noWindows                    // empty configuration
    case degenerateWindow             // a window too short to span even one round
    case noValidStartWithinHorizon    // nothing clears the floors within the lookahead
}

/// The next lock target: the manifest window (rounds) plus the absolute instants
/// they were derived from (kept for display/diagnostics; rounds are authoritative).
struct ScheduleDecision: Equatable {
    let startRound: UInt64
    let endRound: UInt64
    let startDate: Date
    let endDate: Date

    var window: Manifest.Window { Manifest.Window(startRound: startRound, endRound: endRound) }
}

struct Schedule {
    let windows: [DailyWindow]
    /// Carries the time zone; injectable so tests can pin a zone and exercise DST.
    let calendar: Calendar

    /// Defensive lookahead bound. Daily recurrence + a 1-hour minimum lock means a
    /// valid start is normally this-or-next occurrence; this only stops a runaway
    /// search when `verifiedLatest` is implausibly far ahead. Exceeding it fails
    /// closed rather than looping.
    private static let maxOccurrencesPerWindow = 16

    /// Compute the next valid lock target. `now` is the moment of locking;
    /// `verifiedLatest` is the max round verified across drand endpoints (§9).
    ///
    /// `enforceMinLock` gates the 1-hour minimum-lock floor. It is `true` for
    /// every re-seal (window-end, Lock, defensive) so a near window can't be used
    /// to lock-then-reopen with a near-zero commitment. It is `false` only at
    /// FIRST creation, where there is no prior commitment to protect: the user is
    /// freely choosing the first window, so the soonest future occurrence is
    /// honored (still subject to the freshness floor). This does NOT weaken the
    /// crypto lock — it only governs how short a brand-new commitment may be.
    func nextLock(now: Date, verifiedLatest: UInt64,
                  enforceMinLock: Bool = true) -> Result<ScheduleDecision, ScheduleError> {
        guard !windows.isEmpty else { return .failure(.noWindows) }

        let nowRound = TrustedTime.expectedRound(at: now)
        var sawDegenerate = false
        var best: ScheduleDecision? = nil

        for window in windows {
            // Walk this window's daily occurrences forward from `now`, skipping any
            // that are too near, until one is valid or the horizon is exhausted.
            var anchor = now
            for _ in 0..<Schedule.maxOccurrencesPerWindow {
                guard let startDate = nextOccurrence(of: window.start, after: anchor) else { break }
                anchor = startDate   // next iteration looks strictly past this start

                guard let endDate = endInstant(forStartDay: startDate, window: window) else { continue }

                let startRound = TrustedTime.roundForTime(at: startDate)
                let endRound = TrustedTime.roundForTime(at: endDate)
                guard endRound > startRound else { sawDegenerate = true; continue }

                if isValidStart(startRound: startRound, nowRound: nowRound,
                                verifiedLatest: verifiedLatest, enforceMinLock: enforceMinLock) {
                    let candidate = ScheduleDecision(startRound: startRound, endRound: endRound,
                                                     startDate: startDate, endDate: endDate)
                    if best == nil || candidate.startRound < best!.startRound {
                        best = candidate
                    }
                    break   // soonest valid occurrence for THIS window; no need to look further out
                }
                // too near on both/either floor: skip forward to the next day
            }
        }

        if let best { return .success(best) }
        // No window produced a valid future start. Distinguish "every window is
        // unrepresentable" from "valid ones exist but are beyond the horizon".
        return .failure(sawDegenerate && windows.allSatisfy { isDegenerate($0) }
                        ? .degenerateWindow : .noValidStartWithinHorizon)
    }

    // MARK: - Advisory display (NOT authorization)

    /// DISPLAY ONLY — the next wall-clock instant at which some window opens, at or
    /// after `now`, in the schedule's time zone. It ignores rounds, the freshness
    /// margin, and the minimum-lock floor: it answers "when does a window next
    /// open?" for the home-screen hint ("opens at …"), nothing more.
    ///
    /// This NEVER authorizes access. The cryptographic gate is the manifest round
    /// resolved by `VaultStore.load()` (unseal-is-the-gate); a local clock pushed
    /// forward changes only this advisory text, not whether the blob unseals.
    /// Returns nil if there are no windows.
    func nextWindowOpening(after now: Date) -> Date? {
        windows.compactMap { nextOccurrence(of: $0.start, after: now) }.min()
    }

    // MARK: - Validity floors

    private func isValidStart(startRound: UInt64, nowRound: UInt64, verifiedLatest: UInt64,
                              enforceMinLock: Bool) -> Bool {
        // Freshness: the helper rejects target <= latest + margin, so we must clear
        // it. This floor ALWAYS applies (creation and re-seal), or sealing wedges.
        let margin = UInt64(VaultConstants.FRESHNESS_MARGIN_ROUNDS)
        let (freshThreshold, fo) = verifiedLatest.addingReportingOverflow(margin)
        if fo || startRound <= freshThreshold { return false }

        // Minimum lock duration measured from the local-clock round. Applies to
        // re-seals only (see nextLock docs); at first creation the soonest valid
        // window is honored without this floor.
        if enforceMinLock {
            let minLock = UInt64(VaultConstants.MIN_LOCK_DURATION_ROUNDS)
            let (lockThreshold, lo) = nowRound.addingReportingOverflow(minLock)
            if lo || startRound < lockThreshold { return false }
        }

        return true
    }

    /// A window that can never span a round (start and end map to the same round
    /// for every occurrence) — i.e. shorter than one period.
    private func isDegenerate(_ w: DailyWindow) -> Bool {
        let span: Int
        if w.crossesMidnight {
            span = (86400 - w.start.secondsOfDay) + w.end.secondsOfDay
        } else {
            span = w.end.secondsOfDay - w.start.secondsOfDay
        }
        return span < VaultConstants.DRAND_PERIOD_SECONDS
    }

    // MARK: - Wall-clock → instant (DST/timezone via Calendar)

    /// The next instant strictly after `anchor` whose wall-clock time is `tod`,
    /// in the schedule's time zone. `.nextTime` resolves a non-existent wall time
    /// (spring-forward gap) to the next valid instant — fail-forward, never early.
    private func nextOccurrence(of tod: TimeOfDay, after anchor: Date) -> Date? {
        let comps = DateComponents(hour: tod.hour, minute: tod.minute, second: tod.second)
        return calendar.nextDate(after: anchor, matching: comps,
                                 matchingPolicy: .nextTime, repeatedTimePolicy: .first,
                                 direction: .forward)
    }

    /// The window's end instant given its start instant. Built from the start's
    /// calendar day (plus one day if the window crosses midnight) so the duration
    /// follows the wall clock through DST rather than a fixed offset.
    private func endInstant(forStartDay startDate: Date, window: DailyWindow) -> Date? {
        let baseDay = window.crossesMidnight
            ? (calendar.date(byAdding: .day, value: 1, to: startDate) ?? startDate)
            : startDate
        var comps = calendar.dateComponents([.year, .month, .day], from: baseDay)
        comps.hour = window.end.hour
        comps.minute = window.end.minute
        comps.second = window.end.second
        return calendar.date(from: comps)
    }
}

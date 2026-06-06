// schedule_suite.swift — Task 5: daily-window schedule → next lock target.
//
// Covers the §5 gates: basic next-start selection, "inside/after window →
// tomorrow", the two independent skip-forward floors (minimum-lock and
// freshness), soonest-valid across adjacent/overlapping windows, midnight
// crossing, DST (23- and 25-hour days), and the fail-closed buckets
// (no windows / degenerate / nothing within horizon). Also the new
// TrustedTime.roundForTime ceil mapping that underlies all of it.
//
// Calendars are pinned (UTC for the pure-logic cases, America/New_York for DST)
// so results are deterministic regardless of where the harness runs.

import Foundation

private func sck(_ n: String, _ cond: Bool, _ d: String = "") { check("schedule/" + n, cond, d) }

private func cal(_ tz: String) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: tz)!
    return c
}

private func at(_ c: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
    var comps = DateComponents()
    comps.year = y; comps.month = mo; comps.day = d
    comps.hour = h; comps.minute = mi; comps.second = s
    return c.date(from: comps)!
}

private func tod(_ h: Int, _ m: Int, _ s: Int = 0) -> TimeOfDay { TimeOfDay(hour: h, minute: m, second: s)! }
private func win(_ sh: Int, _ sm: Int, _ eh: Int, _ em: Int) -> DailyWindow {
    DailyWindow(start: tod(sh, sm), end: tod(eh, em))
}

/// Unwrap a success decision or fail the named check.
private func decide(_ s: Schedule, now: Date, latest: UInt64) -> ScheduleDecision? {
    if case .success(let d) = s.nextLock(now: now, verifiedLatest: latest) { return d }
    return nil
}

func runScheduleSuite() {
    roundForTimeTests()
    basicSelectionTests()
    skipForwardTests()
    creationFloorTests()
    multiWindowTests()
    midnightCrossingTests()
    dstTests()
    isOpenNowTests()
    failClosedTests()
}

// MARK: - TrustedTime.roundForTime (ceil-based future-boundary mapping)

private func roundForTimeTests() {
    let g = Date(timeIntervalSince1970: Double(VaultConstants.DRAND_GENESIS_UNIX))
    let p = Double(VaultConstants.DRAND_PERIOD_SECONDS)

    sck("round/at-genesis-is-1", TrustedTime.roundForTime(at: g) == 1,
        "\(TrustedTime.roundForTime(at: g))")
    sck("round/before-genesis-clamps", TrustedTime.roundForTime(at: Date(timeIntervalSince1970: 0)) == 1)

    // Exactly on a publication boundary: pub(1001) = genesis + 1000·period.
    let onBoundary = g.addingTimeInterval(1000 * p)
    sck("round/on-boundary-1001", TrustedTime.roundForTime(at: onBoundary) == 1001,
        "\(TrustedTime.roundForTime(at: onBoundary))")

    // One second past the boundary must ceil UP to the next round (1002),
    // whereas expectedRound (floor, the current round) stays at 1001 — this is
    // the whole point of having a separate mapping for future boundaries.
    let pastBoundary = onBoundary.addingTimeInterval(1)
    sck("round/ceils-up-1002", TrustedTime.roundForTime(at: pastBoundary) == 1002,
        "\(TrustedTime.roundForTime(at: pastBoundary))")
    sck("round/expected-floors-1001", TrustedTime.expectedRound(at: pastBoundary) == 1001,
        "\(TrustedTime.expectedRound(at: pastBoundary))")
}

// MARK: - Basic next-start selection

private func basicSelectionTests() {
    let c = cal("UTC")
    let s = Schedule(windows: [win(4, 0, 5, 0)], calendar: c)

    // Now well before today's start → today's start, far enough to clear both floors.
    let now = at(c, 2026, 6, 15, 0, 0)
    let latest = TrustedTime.expectedRound(at: now)
    guard let d = decide(s, now: now, latest: latest) else { return sck("basic/today", false, "no decision") }
    let wantStart = at(c, 2026, 6, 15, 4, 0)
    let wantEnd = at(c, 2026, 6, 15, 5, 0)
    sck("basic/today-start-date", d.startDate == wantStart)
    sck("basic/today-start-round", d.startRound == TrustedTime.roundForTime(at: wantStart),
        "\(d.startRound)")
    sck("basic/today-end-round", d.endRound == TrustedTime.roundForTime(at: wantEnd))
    // 1-hour window is exactly 1200 rounds (3600s / 3s), independent of alignment.
    sck("basic/window-span-1200", d.endRound - d.startRound == 1200, "\(d.endRound - d.startRound)")

    // Now inside the window → tomorrow's start (locking mid-window = done till tomorrow).
    let inside = at(c, 2026, 6, 15, 4, 30)
    if let di = decide(s, now: inside, latest: TrustedTime.expectedRound(at: inside)) {
        sck("basic/inside-window-tomorrow", di.startDate == at(c, 2026, 6, 16, 4, 0),
            "\(di.startDate)")
    } else { sck("basic/inside-window-tomorrow", false, "no decision") }

    // Now after the window → tomorrow's start.
    let after = at(c, 2026, 6, 15, 9, 0)
    if let da = decide(s, now: after, latest: TrustedTime.expectedRound(at: after)) {
        sck("basic/after-window-tomorrow", da.startDate == at(c, 2026, 6, 16, 4, 0))
    } else { sck("basic/after-window-tomorrow", false, "no decision") }
}

// MARK: - Skip-forward floors (each proven independent of the other)

private func skipForwardTests() {
    let c = cal("UTC")
    let s = Schedule(windows: [win(4, 0, 5, 0)], calendar: c)

    // MINIMUM-LOCK floor, freshness slack: 30 min before open = 600 rounds < the
    // 1200-round minimum, so today is skipped. verifiedLatest = nowRound, so the
    // freshness margin (20) is easily cleared — only the min-lock floor bites.
    let near = at(c, 2026, 6, 15, 3, 30)
    if let d = decide(s, now: near, latest: TrustedTime.expectedRound(at: near)) {
        sck("skip/min-lock-skips-to-tomorrow", d.startDate == at(c, 2026, 6, 16, 4, 0),
            "\(d.startDate)")
    } else { sck("skip/min-lock-skips-to-tomorrow", false, "no decision") }

    // Just over the min-lock floor (1.5h ahead = 1800 rounds) → today is kept.
    let okNow = at(c, 2026, 6, 15, 2, 30)
    if let d = decide(s, now: okNow, latest: TrustedTime.expectedRound(at: okNow)) {
        sck("skip/over-min-lock-keeps-today", d.startDate == at(c, 2026, 6, 15, 4, 0))
    } else { sck("skip/over-min-lock-keeps-today", false, "no decision") }

    // FRESHNESS floor, min-lock slack: today's start is hours away (min-lock OK),
    // but a verifiedLatest just below today's start round makes it fail
    // target > latest + margin → skip to tomorrow. Proves freshness independently.
    let now = at(c, 2026, 6, 15, 0, 0)
    let todayStartRound = TrustedTime.roundForTime(at: at(c, 2026, 6, 15, 4, 0))
    let staleLatest = todayStartRound + 5   // today's start <= latest + margin(20)
    if let d = decide(s, now: now, latest: staleLatest) {
        sck("skip/freshness-skips-to-tomorrow", d.startDate == at(c, 2026, 6, 16, 4, 0),
            "\(d.startDate)")
    } else { sck("skip/freshness-skips-to-tomorrow", false, "no decision") }
}

// MARK: - First creation honors the soonest window (no minimum-lock floor)

private func creationFloorTests() {
    let c = cal("UTC")
    let s = Schedule(windows: [win(4, 0, 5, 0)], calendar: c)

    // Same inputs as skip/min-lock-skips-to-tomorrow: 30 min before open. The
    // default (re-seal) path skips to tomorrow; first creation
    // (enforceMinLock: false) honors TODAY's near window — it only clears freshness.
    let near = at(c, 2026, 6, 15, 3, 30)
    let latest = TrustedTime.expectedRound(at: near)
    if case .success(let d) = s.nextLock(now: near, verifiedLatest: latest, enforceMinLock: false) {
        sck("create/honors-near-window-today", d.startDate == at(c, 2026, 6, 15, 4, 0), "\(d.startDate)")
    } else { sck("create/honors-near-window-today", false, "no decision") }

    // The default path on the same inputs still skips to tomorrow (floor intact
    // for re-seals — the within-window lock-then-reopen guard).
    if case .success(let d) = s.nextLock(now: near, verifiedLatest: latest) {
        sck("create/reseal-floor-intact", d.startDate == at(c, 2026, 6, 16, 4, 0), "\(d.startDate)")
    } else { sck("create/reseal-floor-intact", false, "no decision") }

    // Freshness STILL applies at creation: a verifiedLatest just below today's
    // start round is rejected even with the min-lock floor off → skip to tomorrow.
    let now = at(c, 2026, 6, 15, 0, 0)
    let todayStartRound = TrustedTime.roundForTime(at: at(c, 2026, 6, 15, 4, 0))
    let staleLatest = todayStartRound + 5   // today's start <= latest + margin(20)
    if case .success(let d) = s.nextLock(now: now, verifiedLatest: staleLatest, enforceMinLock: false) {
        sck("create/freshness-still-applies", d.startDate == at(c, 2026, 6, 16, 4, 0), "\(d.startDate)")
    } else { sck("create/freshness-still-applies", false, "no decision") }
}

// MARK: - Multiple windows: soonest VALID start wins

private func multiWindowTests() {
    let c = cal("UTC")

    // Adjacent windows 04:00–05:00 and 05:00–06:00; from midnight the soonest
    // start is 04:00. Order of declaration must not matter.
    let adj = Schedule(windows: [win(5, 0, 6, 0), win(4, 0, 5, 0)], calendar: c)
    let now = at(c, 2026, 6, 15, 0, 0)
    if let d = decide(adj, now: now, latest: TrustedTime.expectedRound(at: now)) {
        sck("multi/adjacent-picks-earliest", d.startDate == at(c, 2026, 6, 15, 4, 0))
    } else { sck("multi/adjacent-picks-earliest", false, "no decision") }

    // Overlapping windows 04:00–06:00 and 05:00–07:00; soonest start is 04:00.
    let ovl = Schedule(windows: [win(4, 0, 6, 0), win(5, 0, 7, 0)], calendar: c)
    if let d = decide(ovl, now: now, latest: TrustedTime.expectedRound(at: now)) {
        sck("multi/overlapping-picks-earliest", d.startDate == at(c, 2026, 6, 15, 4, 0))
    } else { sck("multi/overlapping-picks-earliest", false, "no decision") }

    // Cross-window skip-forward: from 03:30 the 04:00 window is too near (skips to
    // tomorrow), but a later SAME-DAY 06:00 window is valid and sooner than
    // tomorrow's 04:00 — the min-over-candidates must pick today's 06:00.
    let mix = Schedule(windows: [win(4, 0, 5, 0), win(6, 0, 7, 0)], calendar: c)
    let near = at(c, 2026, 6, 15, 3, 30)
    if let d = decide(mix, now: near, latest: TrustedTime.expectedRound(at: near)) {
        sck("multi/skip-prefers-later-today-over-tomorrow", d.startDate == at(c, 2026, 6, 15, 6, 0),
            "\(d.startDate)")
    } else { sck("multi/skip-prefers-later-today-over-tomorrow", false, "no decision") }
}

// MARK: - Midnight-crossing windows

private func midnightCrossingTests() {
    let c = cal("UTC")
    let s = Schedule(windows: [win(23, 0, 1, 0)], calendar: c)   // 23:00 → 01:00 next day

    // Noon → today's 23:00 start, end at tomorrow 01:00; span = 2h = 2400 rounds.
    let noon = at(c, 2026, 6, 15, 12, 0)
    if let d = decide(s, now: noon, latest: TrustedTime.expectedRound(at: noon)) {
        sck("midnight/start-today-2300", d.startDate == at(c, 2026, 6, 15, 23, 0))
        sck("midnight/end-next-day-0100", d.endDate == at(c, 2026, 6, 16, 1, 0), "\(d.endDate)")
        sck("midnight/span-2400", d.endRound - d.startRound == 2400, "\(d.endRound - d.startRound)")
    } else { sck("midnight/start-today-2300", false, "no decision") }

    // Inside the crossing window (00:30) → next start is tonight's 23:00.
    let insideAfterMidnight = at(c, 2026, 6, 15, 0, 30)
    if let d = decide(s, now: insideAfterMidnight, latest: TrustedTime.expectedRound(at: insideAfterMidnight)) {
        sck("midnight/inside-goes-to-next-2300", d.startDate == at(c, 2026, 6, 15, 23, 0),
            "\(d.startDate)")
    } else { sck("midnight/inside-goes-to-next-2300", false, "no decision") }
}

// MARK: - DST: wall-clock anchoring across transitions (America/New_York)

private func dstTests() {
    let c = cal("America/New_York")
    let s = Schedule(windows: [win(4, 0, 5, 0)], calendar: c)

    // Spring forward: 2026-03-08, clocks jump 02:00 EST → 03:00 EDT (23-hour day).
    // Consecutive 04:00 starts that straddle the transition are 23h apart, not 24h:
    //   2026-03-07 04:00 EST → 2026-03-08 04:00 EDT == 23h == 27600 rounds.
    let beforeSpring = decide(s, now: at(c, 2026, 3, 7, 0, 0), latest: TrustedTime.expectedRound(at: at(c, 2026, 3, 7, 0, 0)))
    let onSpring = decide(s, now: at(c, 2026, 3, 8, 0, 0), latest: TrustedTime.expectedRound(at: at(c, 2026, 3, 8, 0, 0)))
    if let a = beforeSpring, let b = onSpring {
        sck("dst/spring-forward-23h", b.startRound - a.startRound == 27600,
            "delta=\(b.startRound - a.startRound)")
    } else { sck("dst/spring-forward-23h", false, "no decision") }

    // Fall back: 2026-11-01, clocks fall 02:00 EDT → 01:00 EST (25-hour day).
    //   2026-10-31 04:00 EDT → 2026-11-01 04:00 EST == 25h == 30000 rounds.
    let beforeFall = decide(s, now: at(c, 2026, 10, 31, 0, 0), latest: TrustedTime.expectedRound(at: at(c, 2026, 10, 31, 0, 0)))
    let onFall = decide(s, now: at(c, 2026, 11, 1, 0, 0), latest: TrustedTime.expectedRound(at: at(c, 2026, 11, 1, 0, 0)))
    if let a = beforeFall, let b = onFall {
        sck("dst/fall-back-25h", b.startRound - a.startRound == 30000,
            "delta=\(b.startRound - a.startRound)")
    } else { sck("dst/fall-back-25h", false, "no decision") }
}

// MARK: - isOpenNow (advisory "in a window right now?" — display only, never authorization)

private func isOpenNowTests() {
    let c = cal("UTC")
    let s = Schedule(windows: [win(4, 0, 5, 0)], calendar: c)

    // Inside / on the inclusive start / just before / after / on the exclusive end.
    sck("open-now/inside", s.isOpenNow(at: at(c, 2026, 6, 15, 4, 30)))
    sck("open-now/at-start-inclusive", s.isOpenNow(at: at(c, 2026, 6, 15, 4, 0)))
    sck("open-now/before-closed", !s.isOpenNow(at: at(c, 2026, 6, 15, 3, 59)))
    sck("open-now/after-closed", !s.isOpenNow(at: at(c, 2026, 6, 15, 6, 0)))
    sck("open-now/at-end-exclusive", !s.isOpenNow(at: at(c, 2026, 6, 15, 5, 0)))

    // Midnight-crossing 23:00 → 01:00: open both sides of midnight, shut at noon.
    let cross = Schedule(windows: [win(23, 0, 1, 0)], calendar: c)
    sck("open-now/cross-before-midnight", cross.isOpenNow(at: at(c, 2026, 6, 15, 23, 30)))
    sck("open-now/cross-after-midnight", cross.isOpenNow(at: at(c, 2026, 6, 16, 0, 30)))
    sck("open-now/cross-daytime-closed", !cross.isOpenNow(at: at(c, 2026, 6, 15, 12, 0)))

    // Multiple windows: being inside the SECOND one counts; between them does not.
    let multi = Schedule(windows: [win(4, 0, 5, 0), win(20, 0, 21, 0)], calendar: c)
    sck("open-now/second-window", multi.isOpenNow(at: at(c, 2026, 6, 15, 20, 30)))
    sck("open-now/between-windows-closed", !multi.isOpenNow(at: at(c, 2026, 6, 15, 12, 0)))

    // No windows ⇒ never open.
    sck("open-now/no-windows", !Schedule(windows: [], calendar: c).isOpenNow(at: at(c, 2026, 6, 15, 4, 30)))

    // DST spring-forward day (2026-03-08, 02:00→03:00 EDT): a 04:00–05:00 window is
    // still correctly open at 04:30 EDT — the wall-clock walk absorbs the earlier jump.
    let ny = cal("America/New_York")
    sck("open-now/dst-spring-forward-open",
        Schedule(windows: [win(4, 0, 5, 0)], calendar: ny).isOpenNow(at: at(ny, 2026, 3, 8, 4, 30)))
}

// MARK: - Fail-closed buckets

private func failClosedTests() {
    let c = cal("UTC")
    let now = at(c, 2026, 6, 15, 0, 0)

    // No windows configured.
    let empty = Schedule(windows: [], calendar: c)
    sck("fail/no-windows", empty.nextLock(now: now, verifiedLatest: 1) == .failure(.noWindows))

    // Zero-span window (start == end) is degenerate, never a 24-hour window.
    let degen = Schedule(windows: [win(4, 0, 4, 0)], calendar: c)
    sck("fail/degenerate-window",
        degen.nextLock(now: now, verifiedLatest: TrustedTime.expectedRound(at: now)) == .failure(.degenerateWindow))

    // verifiedLatest implausibly far ahead (≈ a year of rounds) → no window within
    // the lookahead horizon clears freshness → fail closed, never a near target.
    let s = Schedule(windows: [win(4, 0, 5, 0)], calendar: c)
    let huge = TrustedTime.expectedRound(at: now) + 100_000_000
    sck("fail/nothing-within-horizon",
        s.nextLock(now: now, verifiedLatest: huge) == .failure(.noValidStartWithinHorizon))
}

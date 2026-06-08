// Advisory.swift — the DISPLAY-ONLY list advisory (padlock colour + "next window"
// text), derived from the plaintext VLT1 framing of a vault's on-disk copies plus
// the schedule, WITHOUT a network round or an unseal.
//
// Why this exists: the list cannot run the authoritative gate (VaultStore.load) for
// every row on every refresh, but the *recurring schedule* alone is not enough — a
// vault sealed FORWARD (the "Lock now" button, the background re-seal agent, or a
// prior session) is genuinely closed for this wall-clock window even though the
// schedule still places "now" inside a window. Reading the vault's OWN committed
// window from the plaintext VLT1 header fixes that: a forward seal reads as closed,
// not "open now". The rounds stay UNTRUSTED (SECURITY_INVARIANTS I2/I3) — this never
// authorizes access; opening always re-runs the real gate.

import Foundation

/// What a vault's list row should say. Display only — never the authoritative state.
struct VaultAdvisory: Equatable {
    /// The vault's own committed window places NOW inside it ("Open now", green).
    let isOpenNow: Bool
    /// Wall-clock instant the vault next opens (nil when unknown / no schedule).
    let nextOpening: Date?
}

enum VaultAdvisor {
    /// Project a vault's display advisory from the plaintext display-round pairs of
    /// its readable on-disk copies (`copies` — primary and/or `.bak`; unreadable or
    /// non-VLT1 copies are simply omitted), the locally-expected current round
    /// (`current` — display only, from the wall clock), and the schedule (used only
    /// to forecast the next opening when the vault itself cannot say).
    ///
    /// Mirrors `VaultStore.decide` for display: a copy sealed to the FUTURE vetoes
    /// "open now" even if the sibling reads open (anti-shortening, I8). An expired or
    /// unreadable vault reads closed (load would re-seal it forward), and falls back
    /// to the schedule's forecast for its next opening.
    static func advise(copies: [(start: UInt64, end: UInt64)],
                       current: UInt64,
                       schedule: Schedule,
                       now: Date) -> VaultAdvisory {
        var sawOpen = false
        var sawFuture = false
        var earliestFuture: UInt64? = nil
        for c in copies {
            if c.start > current {
                sawFuture = true
                earliestFuture = min(earliestFuture ?? c.start, c.start)
            } else if current <= c.end {
                sawOpen = true                 // start <= current <= end
            }
            // else: start <= current && current > end  → expired (neither)
        }
        if sawOpen && !sawFuture {
            return VaultAdvisory(isOpenNow: true, nextOpening: nil)
        }
        // Closed. A vault sealed strictly forward (and nothing open) knows its own
        // next opening exactly — prefer it over the schedule's forecast, so the row
        // stays honest even if the schedule was changed after the seal.
        if let f = earliestFuture, !sawOpen {
            return VaultAdvisory(isOpenNow: false, nextOpening: TrustedTime.date(forRound: f))
        }
        // Expired / unreadable: load will re-seal forward; the schedule is the best
        // available forecast of the next opening.
        return VaultAdvisory(isOpenNow: false, nextOpening: schedule.nextWindowOpening(after: now))
    }
}

// TrustedTime.swift — the Swift-side round/time arithmetic and seal-target gate
// (FORMAT.md §8). Trusted time is enforced on BOTH sides of the helper boundary:
// the helper refuses a too-near seal target against the live network, and this
// file refuses it again in Swift before a `seal` is ever spawned. Two
// independent checks, both fail-closed; neither alone is load-bearing.
//
// The local clock is used here ONLY to detect a suspiciously-old "latest" (a
// reason to DENY), never to grant access — a standard account cannot wind the
// clock back, and future drand rounds are unforgeable (FORMAT.md §8).

import Foundation

enum TrustedTime {
    /// expectedRound(now) = floor((now − genesis) / period) + 1, clamped to ≥ 1.
    /// Round 1 is published at genesis; round N at genesis + (N−1)·period.
    static func expectedRound(at date: Date) -> UInt64 {
        let now = Int64(date.timeIntervalSince1970)
        let genesis = Int64(VaultConstants.DRAND_GENESIS_UNIX)
        if now <= genesis { return 1 }
        let period = Int64(VaultConstants.DRAND_PERIOD_SECONDS)
        return UInt64((now - genesis) / period) + 1
    }

    /// The Swift-side freshness gate. Returns `.roundTooNear` if `targetRound`
    /// does not clear `verifiedLatest + FRESHNESS_MARGIN_ROUNDS`, mirroring the
    /// helper's own rule (seal.go) exactly: a target at or below the margin is
    /// refused. Returns `nil` when the target is far enough in the future.
    static func validateSealTarget(targetRound: UInt64, verifiedLatest: UInt64) -> HelperError? {
        let margin = UInt64(VaultConstants.FRESHNESS_MARGIN_ROUNDS)
        let (threshold, overflow) = verifiedLatest.addingReportingOverflow(margin)
        if overflow || targetRound <= threshold {
            return .roundTooNear
        }
        return nil
    }

    /// One-sided stale-round defense (FORMAT.md §8): true if the verified latest
    /// round is older than the clock implies by more than the tolerance. This is
    /// only ever a reason to deny.
    static func isStale(verifiedLatest: UInt64, now: Date) -> Bool {
        let expected = expectedRound(at: now)
        let tol = UInt64(VaultConstants.STALE_ROUND_TOLERANCE_ROUNDS)
        return expected > tol && verifiedLatest < expected - tol
    }
}

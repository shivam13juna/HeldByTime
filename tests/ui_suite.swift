// ui_suite.swift — Task 9 tests for the UI-supporting logic that lives in
// VaultCore (and is therefore unit-testable offline): the structured plaintext
// model (VaultContent), the locked-screen presentation mapper (LockScreen), and
// the round→display-time arithmetic (TrustedTime.date). The SwiftUI views
// themselves can't run headless and are covered by the `ui/typecheck` gate in
// run_tests instead.

import Foundation

func runUISuite() {
    vaultContentTests()
    lockScreenTests()
    roundDisplayTimeTests()
}

// MARK: - VaultContent (the plaintext PW01 seals)

private func vaultContentTests() {
    // Round-trip preserves notes + secrets exactly.
    let c = VaultContent(notes: "remember: 04:00 window",
                         secrets: [VaultSecret(id: UUID(), label: "Example account", value: "hunter2"),
                                   VaultSecret(id: UUID(), label: "Example service", value: "")])
    do {
        let bytes = try c.encode()
        let back = try VaultContent.decode(bytes)
        check("ui/content-roundtrip", back == c, "decoded != original")
    } catch {
        fail("ui/content-roundtrip", "threw \(error)")
    }

    // An arbitrary number of arbitrarily-labelled secrets survives the round-trip
    // — nothing in the model is fixed to two named fields.
    do {
        let many = VaultContent(notes: "n", secrets: (0..<7).map {
            VaultSecret(label: "secret #\($0)", value: "v\($0)")
        })
        let back = try VaultContent.decode(try many.encode())
        check("ui/content-many-secrets", back == many && back.secrets.count == 7)
    } catch {
        fail("ui/content-many-secrets", "threw \(error)")
    }

    // Empty content is valid (FORMAT.md: empty notes JSON is allowed) and stable.
    do {
        let empty = VaultContent()
        let back = try VaultContent.decode(try empty.encode())
        check("ui/content-empty-valid", back == empty)
    } catch {
        fail("ui/content-empty-valid", "threw \(error)")
    }

    // Encoding is deterministic (sorted keys) — the same content yields the same
    // bytes across calls.
    do {
        let a = try c.encode(); let b = try c.encode()
        check("ui/content-deterministic", a == b, "encode not stable")
    } catch {
        fail("ui/content-deterministic", "threw \(error)")
    }

    // Over-cap notes fail closed with .sizeLimit, never silently truncate.
    do {
        let huge = VaultContent(notes: String(repeating: "A", count: VaultConstants.MAX_PLAINTEXT_NOTES_BYTES + 16))
        _ = try huge.encode()
        fail("ui/content-oversize", "expected sizeLimit, returned normally")
    } catch let e as VaultFormatError {
        check("ui/content-oversize", tag(e) == "sizeLimit", "threw \(tag(e))")
    } catch {
        fail("ui/content-oversize", "threw non-format \(error)")
    }

    // Decode rejects garbage (not our JSON shape) as parseError.
    expectThrow("ui/content-decode-garbage", "parseError") {
        _ = try VaultContent.decode(Array("not json at all".utf8))
    }

    // Masking hides both value AND length; empty shows an em dash; revealing is
    // the view's job, so masked is never the cleartext.
    let secret = VaultSecret(label: "x", value: "short")
    let longSecret = VaultSecret(label: "y", value: "a-much-longer-secret-value")
    check("ui/secret-mask-hides-value", secret.masked != "short" && !secret.masked.contains("s"))
    check("ui/secret-mask-fixed-width", secret.masked == longSecret.masked, "mask leaks length")
    check("ui/secret-mask-empty", VaultSecret(label: "z", value: "").masked == "—")

    // The first-run template seeds a single blank, unlabelled secret row — no
    // secret name is hard-coded; the user labels and adds the rest.
    let t = VaultContent.initialTemplate
    check("ui/content-template", t.notes.isEmpty && t.secrets.count == 1
          && t.secrets.allSatisfy { $0.value.isEmpty && $0.label.isEmpty })
}

// MARK: - LockScreen presentation mapper

private func lockScreenTests() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!

    // openWindow is the ONLY result that authorizes the password prompt.
    let open = LockScreen.describe(.openWindow(window: Manifest.Window(startRound: 10, endRound: 20),
                                               payload: Data()), calendar: cal)
    check("ui/lock-open-canprompt", open.canPrompt && open.untilLocalTime == nil)

    // Every locked/sealed/offline/failed state must keep the prompt hidden.
    let locked = LockScreen.describe(.lockedUntil(displayStartRound: 1_000_000), calendar: cal)
    check("ui/lock-locked-noprompt", !locked.canPrompt)
    check("ui/lock-locked-has-until", locked.untilLocalTime != nil, "expected a display time")
    check("ui/lock-locked-retry", locked.canRetry)

    // The coarse relative phrase is present whenever an until-time is, and tracks
    // the gap from `now` (computed once — not a live countdown). Pin a `now` and a
    // round ~6 hours ahead so the phrase is deterministic.
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let sixHoursAhead = TrustedTime.expectedRound(at: now.addingTimeInterval(6 * 3600))
    let lockedRel = LockScreen.describe(.lockedUntil(displayStartRound: sixHoursAhead),
                                        calendar: cal, now: now)
    check("ui/lock-relative-present", lockedRel.untilRelative != nil, "expected a relative phrase")
    check("ui/lock-relative-hours", lockedRel.untilRelative?.contains("6 hours") == true,
          "expected '~6 hours', got \(lockedRel.untilRelative ?? "nil")")

    // lockedUntil with no hint round still describes (no crash, no until/relative).
    let lockedNoHint = LockScreen.describe(.lockedUntil(displayStartRound: nil), calendar: cal)
    check("ui/lock-locked-nohint",
          !lockedNoHint.canPrompt && lockedNoHint.untilLocalTime == nil
              && lockedNoHint.untilRelative == nil)

    let resealed = LockScreen.describe(.resealed(window: Manifest.Window(startRound: 2_000_000, endRound: 2_000_100)),
                                       calendar: cal)
    check("ui/lock-resealed", !resealed.canPrompt && resealed.untilLocalTime != nil)

    let offline = LockScreen.describe(.offline, calendar: cal)
    check("ui/lock-offline", !offline.canPrompt && offline.canRetry && offline.untilLocalTime == nil)
    check("ui/lock-offline-mentions-drand", offline.message.contains("drand"))

    // Fail-closed must NOT offer a retry that could loop, and never prompts.
    let failed = LockScreen.describe(.failClosed(reason: "no usable vault copy"), calendar: cal)
    check("ui/lock-failclosed", !failed.canPrompt && !failed.canRetry)
    check("ui/lock-failclosed-detail", failed.message.contains("no usable vault copy"))
}

// MARK: - round → display time

private func roundDisplayTimeTests() {
    // Round 1 is published at genesis; round N at genesis + (N-1)*period.
    let genesis = TimeInterval(VaultConstants.DRAND_GENESIS_UNIX)
    let period = TimeInterval(VaultConstants.DRAND_PERIOD_SECONDS)
    check("ui/round1-at-genesis",
          TrustedTime.date(forRound: 1).timeIntervalSince1970 == genesis)
    check("ui/round-n-formula",
          TrustedTime.date(forRound: 1001).timeIntervalSince1970 == genesis + 1000 * period)

    // date(forRound:) is the inverse of expectedRound at a round boundary: the
    // round current AT a round's publication instant is that round.
    let d = TrustedTime.date(forRound: 5000)
    check("ui/round-date-inverts-expected",
          TrustedTime.expectedRound(at: d) == 5000,
          "expectedRound(date(5000)) = \(TrustedTime.expectedRound(at: d))")
}

// diagnostics_suite.swift — offline coverage for the SECRET-FREE diagnostics log
// (DiagnosticLog). Proves it round-trips events, formats only non-secret tokens,
// stays bounded (capped), and clears. The "no secret can reach it" guarantee is
// structural (the closed DiagnosticEvent enum) and additionally fenced statically
// by run_tests (leak/diagnostics-typed); here we exercise behaviour.

import Foundation

func runDiagnosticsSuite() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("vault-diag-\(UUID().uuidString)", isDirectory: true)
    let url = tmp.appendingPathComponent("diagnostics.log")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let log = DiagnosticLog(url: url, maxLines: 5)

    // Empty before anything is recorded.
    check("diag/empty-initially", log.tail().isEmpty, "no log file yet ⇒ no lines")

    log.record(.appLaunched, source: .app)
    log.record(.checkedVault(.locked, round: 12_345_678), source: .app)
    log.record(.agentRan(.offline), source: .agent)
    log.record(.resealedForward(round: 99_000), source: .app)

    let lines = log.tail()
    check("diag/records-appended", lines.count == 4, "expected 4 lines, got \(lines.count)")

    let joined = lines.joined(separator: "\n")
    check("diag/has-launch", joined.contains("app launched"))
    check("diag/has-round", joined.contains("12345678"), "round number must be shown for troubleshooting")
    check("diag/source-tag", joined.contains("[agent]") && joined.contains("[app]"),
          "lines must be tagged with the emitting process")
    check("diag/agent-offline-phrasing", joined.contains("background agent ran")
            && joined.contains("offline"),
          "agent offline run must be human-readable")

    // Coarse unlock failure carries no oracle detail.
    log.record(.unlock(success: false), source: .app)
    check("diag/unlock-coarse", log.tail().last?.contains("unlock failed") == true,
          "unlock failure must be coarse (no password-vs-corrupt detail)")

    // Cap holds: many records ⇒ never more than maxLines.
    for r in 0..<50 { log.record(.resealedForward(round: UInt64(r)), source: .app) }
    check("diag/capped", log.tail().count <= 5, "log must be trimmed to maxLines")
    check("diag/cap-keeps-newest", log.tail().last?.contains("round 49") == true,
          "the most recent entry must survive trimming")

    // Quarantine record carries the hash + reason only (I6 hash-only).
    log.clear()
    log.record(.quarantine(side: "primary", sha256Hex: "deadbeef", reason: "outer != manifest"),
               source: .app)
    let q = log.tail().last ?? ""
    check("diag/quarantine-hash-only", q.contains("deadbeef") && q.contains("outer != manifest"),
          "quarantine line is hash + reason, never raw bytes")

    // Agent uninstall outcome renders as a non-secret, human-readable line.
    log.record(.agentRemoved(success: true), source: .app)
    check("diag/agent-removed-phrasing", log.tail().last?.contains("re-seal agent removed") == true,
          "agent uninstall must be human-readable and secret-free")

    // Clear empties it.
    log.clear()
    check("diag/clear", log.tail().isEmpty, "clear() removes all entries")

    runMergeChecks()
    runLocalizeChecks()
}

// MARK: - Display localisation (UTC on disk → local time in the viewer)

private func runLocalizeChecks() {
    // A fixed zone (IST, +05:30, no DST) makes the expected strings exact and
    // independent of the machine the tests run on.
    let ist = TimeZone(identifier: "Asia/Kolkata")!

    // A stored UTC line is re-rendered in IST, keeping the original UTC in parens.
    // 12:34:56Z + 05:30 = 18:04:56 local.
    let utcLine = "2026-05-30T12:34:56Z [app] app launched"
    check("diag/localize-ist",
          DiagnosticLog.localize(utcLine, in: ist)
            == "2026-05-30 18:04:56 IST (12:34:56Z) [app] app launched",
          "UTC stamp must render in the given zone (with zone letters + original UTC)")

    // Only the timestamp changes — the source tag and phrase are preserved verbatim.
    check("diag/localize-keeps-content",
          DiagnosticLog.localize(utcLine, in: ist).hasSuffix("[app] app launched"),
          "the event text after the timestamp must be untouched")

    // A line without a parseable leading timestamp is returned unchanged (old/blank).
    let junk = "not-a-timestamp here"
    check("diag/localize-passthrough",
          DiagnosticLog.localize(junk, in: ist) == junk,
          "non-timestamp lines must pass through unchanged")

    // Merged view: ordering still follows the UTC timestamp (chronological), while
    // each displayed line is localised. 10:00:00Z/10:00:15Z + 05:30 = 15:30:00/15.
    let a = ["2026-05-27T10:00:00Z [app] app launched"]
    let b = ["2026-05-27T10:00:15Z [agent] background agent ran → locked"]
    let merged = DiagnosticLog.merge([(tag: "Vault A", lines: a), (tag: "Vault B", lines: b)],
                                     displayIn: ist)
    check("diag/merge-localized",
          merged.count == 2
            && merged[0] == "[Vault A] 2026-05-27 15:30:00 IST (10:00:00Z) [app] app launched"
            && merged[1].hasPrefix("[Vault B] 2026-05-27 15:30:15 IST (10:00:15Z)"),
          "merged lines keep UTC ordering but display local (IST) time")

    // merge() WITHOUT displayIn is unchanged (raw UTC) — back-compatible default.
    check("diag/merge-default-utc",
          DiagnosticLog.merge([(tag: "Vault A", lines: a)]) == ["[Vault A] " + a[0]],
          "default merge (no displayIn) must keep the raw UTC line")
}

// MARK: - Merge across logs (the engine helper behind the app's merged activity view)

private func runMergeChecks() {
    // Empty inputs ⇒ no lines (no groups, and groups with no lines).
    check("diag/merge-empty", DiagnosticLog.merge([]).isEmpty, "no groups ⇒ no lines")
    check("diag/merge-empty-groups",
          DiagnosticLog.merge([(tag: "A", lines: []), (tag: "B", lines: [])]).isEmpty,
          "groups with no lines ⇒ no lines")

    // Cross-group chronology: lines from different logs interleave by their ISO
    // timestamp, NOT by group order. Synthetic distinct timestamps make it exact.
    let a = ["2026-05-27T10:00:00Z [app] app launched",
             "2026-05-27T10:00:30Z [app] checked vault → locked (round 100)"]
    let b = ["2026-05-27T10:00:15Z [agent] background agent ran → locked"]
    let merged = DiagnosticLog.merge([(tag: "Vault A", lines: a), (tag: "Vault B", lines: b)])

    check("diag/merge-count", merged.count == 3, "expected 3 lines, got \(merged.count)")
    check("diag/merge-chronological",
          merged[0].hasPrefix("[Vault A] 2026-05-27T10:00:00Z")
            && merged[1].hasPrefix("[Vault B] 2026-05-27T10:00:15Z")
            && merged[2].hasPrefix("[Vault A] 2026-05-27T10:00:30Z"),
          "lines must be ordered by timestamp across groups, not by group order")
    check("diag/merge-tag-and-content-intact",
          merged[1] == "[Vault B] 2026-05-27T10:00:15Z [agent] background agent ran → locked",
          "each line keeps its source tag AND its original (untruncated) content")

    // A single group preserves its own order and tags every line.
    let single = DiagnosticLog.merge([(tag: "Solo", lines: a)])
    check("diag/merge-single-group",
          single == ["[Solo] " + a[0], "[Solo] " + a[1]],
          "single group ⇒ same order, every line tagged")
}

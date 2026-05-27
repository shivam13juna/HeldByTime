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

    // Clear empties it.
    log.clear()
    check("diag/clear", log.tail().isEmpty, "clear() removes all entries")

    runMergeChecks()
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

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
}

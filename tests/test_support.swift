// test_support.swift — shared test harness (no entry point, no top-level code).
//
// Emits machine-readable `RESULT: PASS|FAIL <name>` lines consumed by run_tests.
// Each suite passes a fully-qualified name (e.g. "format/pw01-roundtrip").

import Foundation

var failures = 0

func pass(_ n: String) { print("RESULT: PASS \(n)") }
func fail(_ n: String, _ d: String = "") {
    print("RESULT: FAIL \(n)" + (d.isEmpty ? "" : " -- \(d)"))
    failures += 1
}
func check(_ n: String, _ cond: Bool, _ d: String = "") { cond ? pass(n) : fail(n, d) }
func info(_ n: String, _ d: String) { print("RESULT: INFO \(n) -- \(d)") }

func tag(_ e: VaultFormatError) -> String {
    switch e {
    case .parseError: return "parseError"
    case .authError: return "authError"
    case .unsupportedVersion: return "unsupportedVersion"
    case .corrupt: return "corrupt"
    case .sizeLimit: return "sizeLimit"
    case .invariantViolation: return "invariantViolation"
    }
}

func expectThrow(_ n: String, _ expectedTag: String, _ body: () throws -> Void) {
    do {
        try body()
        fail(n, "expected throw \(expectedTag), returned normally")
    } catch let e as VaultFormatError {
        let t = tag(e)
        check(n, t == expectedTag, "threw \(t) (\(e)), expected \(expectedTag)")
    } catch {
        fail(n, "threw non-format error \(error)")
    }
}

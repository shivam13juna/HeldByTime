// HelperWire.swift — the Swift side of the helper boundary (FORMAT.md §9).
//
// The helper speaks a CLOSED domain of exactly seven codes on stderr as JSON
// (`{"error":<code>,"detail":<text>}`), writes its result only to stdout, and
// only on success. This file defines the Swift mirror of that domain and the
// TOTAL mapping from a finished subprocess `(timedOut, exitCode, stdout, stderr)`
// tuple to a `Result<Data, HelperError>`.
//
// The mapping is deliberately exhaustive and fail-closed (SECURITY_INVARIANTS I1,
// I9): a known code maps to its specific case; anything outside the contract —
// an unknown code, malformed/oversized stderr, a non-zero exit without valid
// JSON, a stdout payload present alongside an error, or stderr noise on an
// otherwise-successful exit — collapses to `.failClosed`. There is no silent
// success path and no `default` that could swallow an unrecognised state.

import Foundation

/// The closed Swift mirror of the helper error domain. The first seven cases are
/// exactly the helper's wire codes (FORMAT.md §9); `.failClosed` is the single
/// sink for every outcome outside the contract, so callers can switch totally
/// (no `default`) and still treat the unexpected as denial.
enum HelperError: Error, Equatable {
    case roundNotReady      // round_not_ready: target round not yet published
    case roundTooNear       // round_too_near: seal target inside the freshness margin
    case staleRound         // stale_round: network "latest" suspiciously old vs the clock
    case authFailed         // auth_failed: beacon/ciphertext failed verification
    case parseError(String) // parse_error: bad args / unreadable input / malformed response
    case chainMismatch      // chain_mismatch: an endpoint served a different chain
    case timeout            // timeout: unreachable, or the helper was killed on our timeout
    case failClosed(String) // anything outside the closed contract (see file header)
}

enum HelperWire {
    /// The six closed codes that carry no Swift-side detail. `parse_error` is
    /// handled separately because it forwards the helper's detail string.
    private static let detaillessCodes: [String: HelperError] = [
        "round_not_ready": .roundNotReady,
        "round_too_near": .roundTooNear,
        "stale_round": .staleRound,
        "auth_failed": .authFailed,
        "chain_mismatch": .chainMismatch,
        "timeout": .timeout,
    ]

    /// The exact JSON envelope the helper writes on stderr.
    private struct ErrorEnvelope: Decodable {
        let error: String
        let detail: String?
    }

    /// Total map from a finished subprocess to the closed Swift domain.
    ///
    /// - `timedOut`: the helper exceeded our timeout and was killed — fail closed
    ///   as `.timeout` regardless of whatever partial bytes the streams hold.
    /// - `*Truncated`: a stream exceeded its byte cap. An over-cap stream means we
    ///   never saw the helper's full, framed output, so we cannot trust it.
    static func map(timedOut: Bool,
                    exitCode: Int32,
                    stdout: Data,
                    stdoutTruncated: Bool,
                    stderr: Data,
                    stderrTruncated: Bool) -> Result<Data, HelperError> {
        if timedOut {
            return .failure(.timeout)
        }
        if stdoutTruncated {
            return .failure(.failClosed("stdout exceeded size cap"))
        }
        if stderrTruncated {
            return .failure(.failClosed("stderr exceeded size cap"))
        }

        if exitCode == 0 {
            // Success is exit 0 with the payload on stdout and NOTHING on stderr.
            // The helper writes its result only on success and never logs, so any
            // stderr content on a zero exit is anomalous — fail closed.
            if !stderr.isEmpty {
                return .failure(.failClosed("stderr present on success exit"))
            }
            return .success(stdout)
        }

        // Non-zero exit: there must be no stdout payload alongside the error, and
        // stderr must be exactly one valid closed-domain JSON envelope.
        if !stdout.isEmpty {
            return .failure(.failClosed("stdout present alongside error exit"))
        }
        let trimmed = trimTrailingWhitespace(stderr)
        guard !trimmed.isEmpty,
              let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: trimmed) else {
            return .failure(.failClosed("non-zero exit without valid JSON error"))
        }
        if env.error == "parse_error" {
            return .failure(.parseError(env.detail ?? ""))
        }
        if let mapped = detaillessCodes[env.error] {
            return .failure(mapped)
        }
        return .failure(.failClosed("unknown error code: \(env.error)"))
    }

    /// Trim trailing spaces/tabs/newlines/CRs so the helper's single trailing
    /// newline does not defeat the JSON decode. Leading bytes are left intact:
    /// the helper emits exactly one line and nothing before it.
    private static func trimTrailingWhitespace(_ data: Data) -> Data {
        var end = data.endIndex
        while end > data.startIndex {
            let b = data[data.index(before: end)]
            if b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d {
                end = data.index(before: end)
            } else {
                break
            }
        }
        return data.subdata(in: data.startIndex..<end)
    }
}

// VaultSealClient.swift — the typed Swift API over the `vaultseal` helper.
//
// Three operations, mirroring the helper's three subcommands (FORMAT.md §3):
//
//   currentRound()                       -> verified latest round (+ clock view)
//   seal(payload:targetRound:…)          -> manifest||PW01 bytes -> sealed payload
//   unseal(sealed:)                      -> sealed payload -> manifest||PW01 bytes
//
// The payload is OPAQUE here — this layer time-locks/unlocks bytes and never
// inspects, decrypts, or parses them (that separation is what lets defensive
// re-seal stay passwordless later, Task 6). `seal` additionally refuses a
// non-future target on the Swift side before spawning, so the freshness rule is
// enforced twice (here and in the helper).

import Foundation

/// The successful result of `current-round` (helper JSON, FORMAT.md §8).
struct CurrentRoundInfo: Equatable, Decodable {
    let round: UInt64        // max verified latest across endpoints
    let expectedNow: UInt64  // round implied by the local clock
    let unixTime: Int64      // the clock value the helper used

    enum CodingKeys: String, CodingKey {
        case round
        case expectedNow = "expected_now"
        case unixTime = "unix_time"
    }
}

/// One endpoint's reachability, from the helper's `endpoints` probe. `code` is
/// "" when `ok`, else one of the closed helper-domain codes (e.g. "timeout",
/// "chain_mismatch"). The first-run self-test applies the >=1-hard / >=2-warn
/// policy over these and treats any `chain_mismatch` as a hard failure.
struct EndpointStatus: Equatable, Decodable {
    let endpoint: String
    let ok: Bool
    let round: UInt64
    let code: String
}

/// The helper's per-endpoint diagnostic report (FORMAT.md §3; helper `endpoints`).
struct EndpointReport: Equatable, Decodable {
    let endpoints: [EndpointStatus]
    let okCount: Int
    let total: Int

    enum CodingKeys: String, CodingKey {
        case endpoints
        case okCount = "ok_count"
        case total
    }
}

struct VaultSealClient {
    let runner: HelperRunner

    /// Query the verified latest round. Fail-closed on any boundary anomaly.
    func currentRound() -> Result<CurrentRoundInfo, HelperError> {
        switch runner.run(arguments: ["current-round"], stdin: Data()) {
        case .failure(let e):
            return .failure(e)
        case .success(let out):
            guard let info = try? JSONDecoder().decode(CurrentRoundInfo.self, from: out) else {
                return .failure(.failClosed("malformed current-round JSON"))
            }
            return .success(info)
        }
    }

    /// Time-lock `payload` to `targetRound`. The caller supplies the
    /// `verifiedLatest` it already obtained from `currentRound()`, so the
    /// Swift-side freshness gate runs WITHOUT another network round-trip; a
    /// too-near target is refused here, before the helper is ever spawned.
    func seal(payload: Data, targetRound: UInt64, verifiedLatest: UInt64) -> Result<Data, HelperError> {
        if let tooNear = TrustedTime.validateSealTarget(targetRound: targetRound,
                                                        verifiedLatest: verifiedLatest) {
            return .failure(tooNear)
        }
        return runner.run(arguments: ["seal", "--round", String(targetRound)], stdin: payload)
    }

    /// Convenience: fetch the verified latest itself, then seal. Used where the
    /// caller has no fresh `CurrentRoundInfo` in hand.
    func seal(payload: Data, targetRound: UInt64) -> Result<Data, HelperError> {
        switch currentRound() {
        case .failure(let e):
            return .failure(e)
        case .success(let info):
            return seal(payload: payload, targetRound: targetRound, verifiedLatest: info.round)
        }
    }

    /// Probe each compiled-in drand endpoint independently (the helper's
    /// `endpoints` command). Used only by the first-run self-test to apply the
    /// reachability policy; the hot path uses `currentRound()`. A clean probe
    /// returns a report even when every endpoint is down (`okCount == 0`).
    func probeEndpoints() -> Result<EndpointReport, HelperError> {
        switch runner.run(arguments: ["endpoints"], stdin: Data()) {
        case .failure(let e):
            return .failure(e)
        case .success(let out):
            guard let report = try? JSONDecoder().decode(EndpointReport.self, from: out) else {
                return .failure(.failClosed("malformed endpoints JSON"))
            }
            return .success(report)
        }
    }

    /// Time-unlock a sealed payload, returning the recovered manifest||PW01 bytes.
    /// If the target round is unpublished the payload stays cryptographically
    /// locked and `.roundNotReady` is returned (FORMAT.md §3).
    func unseal(sealed: Data) -> Result<Data, HelperError> {
        runner.run(arguments: ["unseal"], stdin: sealed)
    }
}

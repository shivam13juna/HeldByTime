// SelfTestEngine.swift — the on-device self-test gate (app.md §9, §10 step 10).
//
// Build-time green does not prove THIS machine is green: signing, quarantine, a
// missing exec bit, a 1 GiB Argon2 allocation failure on this hardware, or a
// drand endpoint blocked by a content filter can all fail only at runtime. The engine is
// the runtime counterpart to the build-time gates, and first-run setup
// (FirstRunSetup) MUST refuse to store any real secret until it is satisfied.
//
// It SHIPS IN RELEASE (it is not `#if DEBUG`): first-run setup calls it through
// the UI path, and that is the ONLY way to reach it in a release build — there
// is no CLI, flag, env var, or hidden command surface in VaultCore. The
// developer dry-run wrappers (DryRun.swift) are the sole CLI-ish surface and are
// `#if DEBUG`-only.
//
// Every environment-dependent capability is taken through `SelfTestServices`, so
// the policy/choreography (the security-critical part) is unit-testable offline
// while production wires the real `vaultseal` subprocess + real Argon2.

import Foundation

/// The raw, environment-dependent capabilities the self-test orchestrates. In
/// production `LiveSelfTestServices` wraps the real Argon2 binding and the real
/// `vaultseal` client; tests inject a fake to drive every branch offline.
protocol SelfTestServices {
    func argon2(t: UInt32, mKiB: UInt32, p: UInt32, version: UInt32,
                password: [UInt8], salt: [UInt8], outLen: Int) -> Result<[UInt8], VaultFormatError>
    func helperPreflight() -> HelperError?
    func currentRound() -> Result<CurrentRoundInfo, HelperError>
    func seal(payload: Data, targetRound: UInt64, verifiedLatest: UInt64) -> Result<Data, HelperError>
    func unseal(sealed: Data) -> Result<Data, HelperError>
    func probeEndpoints() -> Result<EndpointReport, HelperError>
}

/// Production capabilities: the real vendored Argon2id and the real bundled
/// `vaultseal` subprocess. This is the conformer the shipped app uses.
struct LiveSelfTestServices: SelfTestServices {
    let client: VaultSealClient

    func argon2(t: UInt32, mKiB: UInt32, p: UInt32, version: UInt32,
                password: [UInt8], salt: [UInt8], outLen: Int) -> Result<[UInt8], VaultFormatError> {
        do {
            return .success(try Argon2.raw(t: t, mKiB: mKiB, p: p, version: version,
                                           password: password, salt: salt, outLen: outLen))
        } catch let e as VaultFormatError {
            return .failure(e)
        } catch {
            return .failure(.invariantViolation("argon2: \(error)"))
        }
    }

    func helperPreflight() -> HelperError? { client.runner.preflight() }
    func currentRound() -> Result<CurrentRoundInfo, HelperError> { client.currentRound() }
    func seal(payload: Data, targetRound: UInt64, verifiedLatest: UInt64) -> Result<Data, HelperError> {
        client.seal(payload: payload, targetRound: targetRound, verifiedLatest: verifiedLatest)
    }
    func unseal(sealed: Data) -> Result<Data, HelperError> { client.unseal(sealed: sealed) }
    func probeEndpoints() -> Result<EndpointReport, HelperError> { client.probeEndpoints() }
}

struct SelfTestEngine {
    /// The checks the engine performs, in order. `CaseIterable` lets the UI drive
    /// the list from one vocabulary without hard-coding it twice.
    enum Step: String, CaseIterable {
        case argon2Vector       // Argon2id KAT — proves correct params/output on this build
        case argon2Benchmark    // Argon2id at 1 GiB production params — alloc-fail ⇒ fail closed; times unlock
        case helperBinaryValid  // bundled vaultseal: regular file, exec bit, pinned hash matches
        case helperRoundTrip    // real seal→persist→unseal of a throwaway payload (correctly future-locked)
        case endpointsReachable // ≥1 drand endpoint reachable = pass; warn unless ≥2; forged chain = fail
        case backupExclusion    // vault dir carries isExcludedFromBackup (Time Machine / iCloud)
    }

    /// A step can pass, warn (proceed only with explicit user confirmation), or
    /// fail (refuse to store real secrets).
    enum Outcome: Equatable { case pass, warn, fail }

    struct StepResult: Equatable {
        let step: Step
        let outcome: Outcome
        let detail: String
    }

    /// The overall verdict over a full run.
    enum GateDecision: Equatable {
        case clear                       // every step passed — safe to store real secrets
        case needsConfirmation([Step])   // warnings but no failures — proceed ONLY on explicit confirm
        case blocked([Step])             // ≥1 hard failure — refuse to store any real secret
    }

    let services: SelfTestServices
    /// Unlock-latency budget for the 1 GiB benchmark (ms). Over budget ⇒ warn,
    /// never fail (a slow machine still works). Injectable so tests can exercise
    /// the warn branch without a genuinely slow derivation.
    let benchmarkBudgetMs: Double

    init(services: SelfTestServices, benchmarkBudgetMs: Double = 5000) {
        self.services = services
        self.benchmarkBudgetMs = benchmarkBudgetMs
    }

    // Fast, independently cross-validated Argon2id vector (OpenSSL oracle, see
    // argon2_suite.swift). The 8 MiB vector keeps the correctness check quick;
    // the 1 GiB production-parameter exercise is the separate benchmark step.
    private static let katPassword = Array("password".utf8)
    private static let katSalt = Array("somesalt".utf8)
    private static let katExpectedHex =
        "95fa07340ba8003501e2d4748cd5ad71666e2fc02071e3be9818da7ec62a717c"

    /// Run every step and return one result each. Steps are independent: a
    /// failure is recorded, never thrown, so the caller can show the full
    /// picture and refuse real secrets unless the gate is satisfied. `scratchDir`
    /// hosts the throwaway round-trip payload (NEVER the real vault path);
    /// `vaultDir` is the real vault directory whose backup-exclusion is verified.
    func run(scratchDir: URL, vaultDir: URL) -> [StepResult] {
        Step.allCases.map { step in
            switch step {
            case .argon2Vector:       return checkArgon2Vector()
            case .argon2Benchmark:    return checkArgon2Benchmark()
            case .helperBinaryValid:  return checkHelperBinary()
            case .helperRoundTrip:    return checkHelperRoundTrip(scratchDir: scratchDir)
            case .endpointsReachable: return checkEndpoints()
            case .backupExclusion:    return checkBackupExclusion(vaultDir: vaultDir)
            }
        }
    }

    /// Reduce a run to the gate verdict. Any failure blocks; otherwise any
    /// warning needs explicit confirmation; otherwise clear.
    static func gate(_ results: [StepResult]) -> GateDecision {
        let failed = results.filter { $0.outcome == .fail }.map { $0.step }
        if !failed.isEmpty { return .blocked(failed) }
        let warned = results.filter { $0.outcome == .warn }.map { $0.step }
        if !warned.isEmpty { return .needsConfirmation(warned) }
        return .clear
    }

    // MARK: - steps

    private func checkArgon2Vector() -> StepResult {
        switch services.argon2(t: 3, mKiB: 8192, p: 4, version: 19,
                               password: Self.katPassword, salt: Self.katSalt, outLen: 32) {
        case .success(let out):
            let hex = Hex.encode(out)
            return hex == Self.katExpectedHex
                ? StepResult(step: .argon2Vector, outcome: .pass, detail: "KAT matched")
                : StepResult(step: .argon2Vector, outcome: .fail, detail: "KAT mismatch: \(hex)")
        case .failure(let e):
            return StepResult(step: .argon2Vector, outcome: .fail, detail: "Argon2 failed: \(e)")
        }
    }

    private func checkArgon2Benchmark() -> StepResult {
        let salt = SecureRandom.bytes(VaultConstants.ARGON2_SALT_LEN)
        let pw = SecureRandom.bytes(16)
        let start = Date()
        switch services.argon2(t: UInt32(VaultConstants.ARGON2_T),
                               mKiB: UInt32(VaultConstants.ARGON2_M_KIB),
                               p: UInt32(VaultConstants.ARGON2_P),
                               version: UInt32(VaultConstants.ARGON2_VERSION),
                               password: pw, salt: salt, outLen: VaultConstants.ARGON2_OUTPUT_LEN) {
        case .failure(let e):
            // A 1 GiB allocation failure on this machine fails CLOSED — never a
            // silent downgrade to weaker params.
            return StepResult(step: .argon2Benchmark, outcome: .fail,
                              detail: "production-parameter derivation failed (allocation?): \(e)")
        case .success:
            let ms = Date().timeIntervalSince(start) * 1000
            if ms > benchmarkBudgetMs {
                return StepResult(step: .argon2Benchmark, outcome: .warn,
                                  detail: "slow: \(Int(ms)) ms at 1 GiB (> \(Int(benchmarkBudgetMs)) ms budget); unlock will feel sluggish")
            }
            return StepResult(step: .argon2Benchmark, outcome: .pass, detail: "\(Int(ms)) ms at 1 GiB params")
        }
    }

    private func checkHelperBinary() -> StepResult {
        if let err = services.helperPreflight() {
            return StepResult(step: .helperBinaryValid, outcome: .fail, detail: "\(err)")
        }
        return StepResult(step: .helperBinaryValid, outcome: .pass, detail: "regular file, exec bit, pinned hash matched")
    }

    private func checkHelperRoundTrip(scratchDir: URL) -> StepResult {
        let info: CurrentRoundInfo
        switch services.currentRound() {
        case .success(let i): info = i
        case .failure(let e): return StepResult(step: .helperRoundTrip, outcome: .fail, detail: "current-round failed: \(e)")
        }

        // A safely-future target: beyond the freshness margin AND the minimum
        // lock floor, so the helper's own freshness rule accepts the seal.
        let target = info.round
            + UInt64(VaultConstants.FRESHNESS_MARGIN_ROUNDS)
            + UInt64(VaultConstants.MIN_LOCK_DURATION_ROUNDS)

        // Throwaway random payload, written to the scratch dir (never the vault),
        // so the round-trip also exercises this machine's real filesystem path.
        let payload = Data(SecureRandom.bytes(64))
        let sealedURL = scratchDir.appendingPathComponent("selftest.sealed")
        do {
            try payload.write(to: scratchDir.appendingPathComponent("selftest-payload.bin"))
        } catch {
            return StepResult(step: .helperRoundTrip, outcome: .fail, detail: "scratch write failed: \(error)")
        }

        let sealed: Data
        switch services.seal(payload: payload, targetRound: target, verifiedLatest: info.round) {
        case .success(let s): sealed = s
        case .failure(let e): return StepResult(step: .helperRoundTrip, outcome: .fail, detail: "seal failed: \(e)")
        }

        let reloaded: Data
        do {
            try sealed.write(to: sealedURL)
            reloaded = try Data(contentsOf: sealedURL)
        } catch {
            return StepResult(step: .helperRoundTrip, outcome: .fail, detail: "sealed-blob scratch round-trip failed: \(error)")
        }

        // The blob is genuinely sealed to a FUTURE round, so the cryptographically
        // CORRECT result of unsealing it now is round_not_ready. A success would
        // mean a future seal opened immediately — alarming, and a hard failure.
        switch services.unseal(sealed: reloaded) {
        case .failure(.roundNotReady):
            return StepResult(step: .helperRoundTrip, outcome: .pass,
                              detail: "sealed \(sealed.count)B to round \(target); unseal correctly reports locked")
        case .success:
            return StepResult(step: .helperRoundTrip, outcome: .fail,
                              detail: "a freshly future-sealed blob unsealed immediately — time-lock is not holding")
        case .failure(let e):
            return StepResult(step: .helperRoundTrip, outcome: .fail,
                              detail: "unseal returned \(e), expected round_not_ready")
        }
    }

    private func checkEndpoints() -> StepResult {
        switch services.probeEndpoints() {
        case .failure(let e):
            return StepResult(step: .endpointsReachable, outcome: .fail, detail: "endpoint probe failed: \(e)")
        case .success(let report):
            // A forged chain on ANY endpoint is a hard failure regardless of the
            // reachable count — never proceed against a poisoned mirror.
            if let forged = report.endpoints.first(where: { $0.code == "chain_mismatch" }) {
                return StepResult(step: .endpointsReachable, outcome: .fail,
                                  detail: "endpoint \(forged.endpoint) served a forged chain (chain_mismatch)")
            }
            let detail = report.endpoints.map {
                "\($0.endpoint): " + ($0.ok ? "ok(r\($0.round))" : ($0.code.isEmpty ? "down" : $0.code))
            }.joined(separator: ", ")
            switch report.okCount {
            case 0:
                return StepResult(step: .endpointsReachable, outcome: .fail,
                                  detail: "no drand endpoint reachable (blocked by a content filter or firewall?) — the vault will not open. [\(detail)]")
            case 1:
                return StepResult(step: .endpointsReachable, outcome: .warn,
                                  detail: "only 1 of \(report.total) endpoints reachable; if it is later blocked the vault will not open — whitelist a second. [\(detail)]")
            default:
                return StepResult(step: .endpointsReachable, outcome: .pass,
                                  detail: "\(report.okCount)/\(report.total) endpoints reachable. [\(detail)]")
            }
        }
    }

    private func checkBackupExclusion(vaultDir: URL) -> StepResult {
        do {
            let vals = try vaultDir.resourceValues(forKeys: [.isExcludedFromBackupKey])
            if vals.isExcludedFromBackup == true {
                return StepResult(step: .backupExclusion, outcome: .pass,
                                  detail: "vault directory excluded from Time Machine / iCloud backup")
            }
            return StepResult(step: .backupExclusion, outcome: .fail,
                              detail: "isExcludedFromBackup is not set on the vault directory")
        } catch {
            return StepResult(step: .backupExclusion, outcome: .fail,
                              detail: "could not read the backup-exclusion attribute: \(error)")
        }
    }
}

// SelfTestEngine.swift — the on-device self-test, shared by release and debug.
//
// Build-time green does not prove THIS machine is green (app.md §10.10): signing,
// quarantine, a missing exec bit, wrong Argon2 params on this hardware, or a
// drand endpoint blocked by Canopy can all fail only at runtime. The engine is
// the runtime counterpart to the build-time gates.
//
// It SHIPS IN RELEASE (it is not `#if DEBUG`): the first-run setup (Task 8) calls
// it through the UI path, and that is the ONLY way to reach it in a release
// build — there is no CLI, flag, env var, or hidden command surface in VaultCore.
// The developer dry-run wrappers (DryRun.swift) are the sole CLI-ish surface and
// are `#if DEBUG`-only.
//
// This is the Task-4 skeleton: the step vocabulary plus the steps that are
// honest to run now (a real Argon2id KAT and the real binary integrity check).
// The full first-run gate — separate-temp-dir isolation with a throwaway
// payload, the ≥2-independent-endpoints reachability policy, and the data-loss
// confirmation — is completed in Task 8 on top of this structure.

import Foundation

struct SelfTestEngine {
    /// The checks the engine performs, in order. `CaseIterable` lets Task 8 drive
    /// the UI from the vocabulary without hard-coding the list twice.
    enum Step: String, CaseIterable {
        case argon2Vector      // Argon2id KAT — catches alloc failure / wrong params here
        case helperBinaryValid // bundled vaultseal: regular file, exec bit, hash matches
        case helperResponds    // vaultseal current-round verifies live against the network
    }

    struct StepResult: Equatable {
        let step: Step
        let passed: Bool
        let detail: String
    }

    let client: VaultSealClient

    /// Fast, independently-cross-validated Argon2id vector (OpenSSL oracle, see
    /// argon2_suite.swift). Using the 8 MiB vector keeps the on-device check
    /// quick while still exercising the same code path; the full 1 GiB
    /// production-parameter exercise is part of the Task 8 gate.
    private static let katPassword = Array("password".utf8)
    private static let katSalt = Array("somesalt".utf8)
    private static let katExpectedHex =
        "95fa07340ba8003501e2d4748cd5ad71666e2fc02071e3be9818da7ec62a717c"

    /// Run every step and return one result each. Steps are independent: a
    /// failure is recorded, never thrown, so the caller (first-run UI) can show
    /// the full picture and refuse to store real secrets unless all pass.
    func run() -> [StepResult] {
        Step.allCases.map { step in
            switch step {
            case .argon2Vector:    return Self.checkArgon2()
            case .helperBinaryValid: return checkHelperBinary()
            case .helperResponds:  return checkHelperResponds()
            }
        }
    }

    private static func checkArgon2() -> StepResult {
        do {
            let out = try Argon2.raw(t: 3, mKiB: 8192, p: 4, version: 19,
                                     password: katPassword, salt: katSalt, outLen: 32)
            let hex = Hex.encode(out)
            return StepResult(step: .argon2Vector, passed: hex == katExpectedHex,
                              detail: hex == katExpectedHex ? "KAT matched" : "KAT mismatch: \(hex)")
        } catch {
            return StepResult(step: .argon2Vector, passed: false, detail: "Argon2 failed: \(error)")
        }
    }

    private func checkHelperBinary() -> StepResult {
        if let err = client.runner.preflight() {
            return StepResult(step: .helperBinaryValid, passed: false, detail: "\(err)")
        }
        return StepResult(step: .helperBinaryValid, passed: true, detail: "regular file, exec bit, hash matched")
    }

    private func checkHelperResponds() -> StepResult {
        switch client.currentRound() {
        case .success(let info):
            return StepResult(step: .helperResponds, passed: true, detail: "verified round \(info.round)")
        case .failure(let err):
            return StepResult(step: .helperResponds, passed: false, detail: "\(err)")
        }
    }
}

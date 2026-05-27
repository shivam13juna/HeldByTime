// FirstRunSetup.swift — the gated create-vault flow (app.md §10 step 10, §11).
//
// First run is the one moment we can refuse to proceed BEFORE any real secret
// exists. It enforces, in order:
//   1. Password rules (PasswordPolicy): valid + exact-byte confirm.
//   2. Explicit acknowledgment of the data-loss warnings that cannot be verified
//      without admin (Time Machine / APFS snapshots / cloud sync — §9). The
//      auto-verifiable part (isExcludedFromBackup) is a self-test step.
//   3. The on-device self-test gate (SelfTestEngine): build-time green does not
//      prove THIS machine is green. A hard failure BLOCKS; a warning (e.g. only
//      one reachable drand endpoint) proceeds ONLY with explicit confirmation.
//   4. Only then: derive the key under a fresh salt, seal the initial notes to
//      the FIRST scheduled window, and write the vault.
//
// This is the engine layer (no SwiftUI — that is Task 9). It is fully testable
// offline via an injected SelfTestServices + the store's SealService seam.

import Foundation

struct FirstRunSetup {
    let store: VaultStore
    let services: SelfTestServices
    /// Forwarded to the self-test's 1 GiB benchmark budget.
    let benchmarkBudgetMs: Double

    init(store: VaultStore, services: SelfTestServices, benchmarkBudgetMs: Double = 5000) {
        self.store = store
        self.services = services
        self.benchmarkBudgetMs = benchmarkBudgetMs
    }

    /// Why setup refused. Closed; the UI maps each to a clear message.
    enum SetupError: Error, Equatable {
        case password(PasswordError)                      // fails the hard password gates
        case passwordMismatch                             // confirm bytes differ
        case dataLossNotAcknowledged                      // user has not confirmed the §9 warnings
        case selfTestBlocked([SelfTestEngine.Step])       // ≥1 hard self-test failure
        case warningsNotConfirmed([SelfTestEngine.Step])  // self-test warnings, caller did not confirm
        case schedule(ScheduleError)                      // no resolvable first window
        case helper(HelperError)                          // could not get a verified round to seal
        case store(StoreError)                            // directory / seal / durable-write failure
        case io(String)                                   // scratch-dir lifecycle failure
    }

    struct SetupReport: Equatable {
        let selfTest: [SelfTestEngine.StepResult]
        let createdWindow: Manifest.Window
    }

    /// Run ONLY the self-test gate (no vault write), e.g. to render the per-step
    /// UI before the user commits a password. Ensures the vault directory exists
    /// (so the backup-exclusion check is meaningful) and runs in a throwaway
    /// scratch dir that is deleted — and asserted deleted — on every path.
    func runSelfTest() -> Result<[SelfTestEngine.StepResult], SetupError> {
        do { try store.ensureDirectory() }
        catch let e as StoreError { return .failure(.store(e)) }
        catch { return .failure(.io("ensureDirectory: \(error)")) }

        return withScratchDir { scratch in
            SelfTestEngine(services: services, benchmarkBudgetMs: benchmarkBudgetMs)
                .run(scratchDir: scratch, vaultDir: store.dir)
        }
    }

    /// The full gated create. On success the vault exists, sealed to its first
    /// window; until then no real secret has touched disk.
    func create(password: String,
                confirmPassword: String,
                initialNotes: [UInt8],
                acknowledgeDataLossWarnings: Bool,
                confirmWarnings: Bool) -> Result<SetupReport, SetupError> {
        // 1. Password: hard gates, then exact-byte confirm.
        let pwBytes: [UInt8]
        switch PasswordPolicy.validate(password) {
        case .success(let b): pwBytes = b
        case .failure(let e): return .failure(.password(e))
        }
        guard PasswordPolicy.confirms(password, confirmPassword) else {
            return .failure(.passwordMismatch)
        }

        // 2. The non-auto-verifiable data-loss warnings must be acknowledged.
        guard acknowledgeDataLossWarnings else {
            return .failure(.dataLossNotAcknowledged)
        }

        // 3. Self-test gate (ensures the dir, runs in a cleaned scratch dir).
        let results: [SelfTestEngine.StepResult]
        switch runSelfTest() {
        case .success(let r): results = r
        case .failure(let e): return .failure(e)
        }
        switch SelfTestEngine.gate(results) {
        case .blocked(let steps):
            return .failure(.selfTestBlocked(steps))
        case .needsConfirmation(let steps):
            guard confirmWarnings else { return .failure(.warningsNotConfirmed(steps)) }
        case .clear:
            break
        }

        // 4. Compute the FIRST window from a verified round (never the local
        //    clock alone; same trusted-time path as every other seal).
        let info: CurrentRoundInfo
        switch services.currentRound() {
        case .success(let i): info = i
        case .failure(let e): return .failure(.helper(e))
        }
        // First creation: honor the soonest future window (no minimum-lock floor;
        // there is no prior commitment to protect). Re-seals keep the floor.
        let decision: ScheduleDecision
        switch store.schedule.nextLock(now: store.clock(), verifiedLatest: info.round,
                                       enforceMinLock: false) {
        case .success(let d): decision = d
        case .failure(let e): return .failure(.schedule(e))
        }

        // 5. Fresh salt + nonce (FORMAT.md §7), derive the key, seal the notes,
        //    commit to the window. commit re-checks seal freshness on its side.
        let salt = SecureRandom.bytes(VaultConstants.ARGON2_SALT_LEN)
        let nonce = SecureRandom.bytes(VaultConstants.GCM_NONCE_LEN)
        let pw01: [UInt8]
        do {
            let key = try KeyDerivation.deriveKey(password: pwBytes, salt: salt)
            pw01 = try PW01.seal(notes: initialNotes, key: key, salt: salt, nonce: nonce)
        } catch let e as VaultFormatError {
            return .failure(.store(.format(e)))
        } catch {
            return .failure(.store(.format(.invariantViolation("\(error)"))))
        }

        switch store.commit(pw01: pw01, window: decision.window, verifiedLatest: info.round) {
        case .success:
            return .success(SetupReport(selfTest: results, createdWindow: decision.window))
        case .failure(let e):
            return .failure(.store(e))
        }
    }

    // MARK: - scratch isolation

    /// Run `body` with a fresh throwaway scratch directory, then delete it and
    /// ASSERT it is gone — on both the success and failure of `body`. The
    /// self-test's throwaway payload lives here, never the real vault path; a
    /// scratch dir that survives is itself a (small) leak and fails closed.
    private func withScratchDir<T>(_ body: (URL) -> T) -> Result<T, SetupError> {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-selftest-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return .failure(.io("scratch create: \(error)"))
        }
        let value = body(scratch)
        try? FileManager.default.removeItem(at: scratch)
        if FileManager.default.fileExists(atPath: scratch.path) {
            return .failure(.io("self-test scratch dir not deleted: \(scratch.path)"))
        }
        return .success(value)
    }
}

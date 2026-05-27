// setup_suite.swift — Task 8: first-run setup + on-device self-test gate.
//
// Covers three pure/engine layers, all offline:
//   1. PasswordPolicy — encode (no normalization), the hard gates (empty / min
//      scalars / max bytes), exact-byte confirm (NFC≠NFD), and the advisory
//      weakness heuristic.
//   2. SelfTestEngine — every step's pass/warn/fail branch and the gate verdict,
//      driven by a fully-injected FakeSelfTestServices (so the argon2/network
//      branches are deterministic and never touch the real binary or drand).
//   3. FirstRunSetup — the gated create flow: password + confirm + data-loss
//      acknowledgment + the self-test gate, then a REAL future-locked vault
//      sealed to the first window (re-openable with the password at that window).
//
// FakeSeal (the offline time-lock simulator) is reused from store_suite.

import Foundation
import CryptoKit

private func suk(_ n: String, _ cond: Bool, _ d: String = "") { check("setup/" + n, cond, d) }

// MARK: - injected self-test capabilities (deterministic, offline)

/// A controllable SelfTestServices. Defaults to an all-green machine; each field
/// is flipped per test to drive a single branch.
private final class FakeSelfTestServices: SelfTestServices {
    var argon2VectorCorrect = true       // KAT (8 MiB) returns the expected bytes
    var argon2BenchmarkFails = false     // simulate a 1 GiB allocation failure
    var preflightError: HelperError? = nil
    var currentRoundResult: Result<CurrentRoundInfo, HelperError>
    var sealResult: Result<Data, HelperError> = .success(Data("SEALED".utf8))
    var unsealResult: Result<Data, HelperError> = .failure(.roundNotReady) // correct: future-locked
    var endpointsResult: Result<EndpointReport, HelperError>

    init(round: UInt64) {
        currentRoundResult = .success(CurrentRoundInfo(round: round, expectedNow: round, unixTime: 0))
        endpointsResult = .success(EndpointReport(
            endpoints: [EndpointStatus(endpoint: "https://api.drand.sh", ok: true, round: round, code: ""),
                        EndpointStatus(endpoint: "https://api2.drand.sh", ok: true, round: round, code: "")],
            okCount: 2, total: 2))
    }

    private static let katBytes = Hex.decode("95fa07340ba8003501e2d4748cd5ad71666e2fc02071e3be9818da7ec62a717c")!

    func argon2(t: UInt32, mKiB: UInt32, p: UInt32, version: UInt32,
                password: [UInt8], salt: [UInt8], outLen: Int) -> Result<[UInt8], VaultFormatError> {
        if mKiB == 8192 { // the KAT call
            return .success(argon2VectorCorrect ? Self.katBytes : [UInt8](repeating: 0xAB, count: 32))
        }
        // the 1 GiB benchmark call
        return argon2BenchmarkFails
            ? .failure(.invariantViolation("argon2 rc -22"))
            : .success([UInt8](repeating: 0, count: 32))
    }
    func helperPreflight() -> HelperError? { preflightError }
    func currentRound() -> Result<CurrentRoundInfo, HelperError> { currentRoundResult }
    func seal(payload: Data, targetRound: UInt64, verifiedLatest: UInt64) -> Result<Data, HelperError> { sealResult }
    func unseal(sealed: Data) -> Result<Data, HelperError> { unsealResult }
    func probeEndpoints() -> Result<EndpointReport, HelperError> { endpointsResult }
}

func runSetupSuite() {
    passwordPolicyTests()
    selfTestEngineTests()
    firstRunSetupTests()
}

// MARK: - 1. PasswordPolicy

private func passwordPolicyTests() {
    // Hard gates.
    if case .failure(.empty) = PasswordPolicy.validate("") { suk("pw/empty-rejected", true) }
    else { suk("pw/empty-rejected", false) }

    // Minimum is counted in Unicode SCALARS, not bytes: 11 scalars rejected, 12 ok.
    let elevenAcute = String(repeating: "\u{00E9}", count: 11)   // 11 scalars, 22 bytes
    let twelveAcute = String(repeating: "\u{00E9}", count: 12)   // 12 scalars, 24 bytes
    if case .failure(.tooShort(let s)) = PasswordPolicy.validate(elevenAcute) {
        suk("pw/too-short-by-scalars", s == 11)
    } else { suk("pw/too-short-by-scalars", false) }
    if case .success(let bytes) = PasswordPolicy.validate(twelveAcute) {
        suk("pw/min-length-ok-multibyte", bytes.count == 24) // 12 scalars but 24 UTF-8 bytes
    } else { suk("pw/min-length-ok-multibyte", false) }

    // Byte cap: exactly MAX_PASSWORD_BYTES ok, one more rejected.
    let maxBytes = String(repeating: "a", count: VaultConstants.MAX_PASSWORD_BYTES)
    let overBytes = String(repeating: "a", count: VaultConstants.MAX_PASSWORD_BYTES + 1)
    if case .success = PasswordPolicy.validate(maxBytes) { suk("pw/max-bytes-ok", true) }
    else { suk("pw/max-bytes-ok", false) }
    if case .failure(.tooLong(let b)) = PasswordPolicy.validate(overBytes) {
        suk("pw/over-max-bytes-rejected", b == VaultConstants.MAX_PASSWORD_BYTES + 1)
    } else { suk("pw/over-max-bytes-rejected", false) }

    // Exact-byte confirm: identical-looking but differently-encoded é must NOT match.
    let composed = String(UnicodeScalar(0x00E9)!)               // "é" (1 scalar)
    let decomposed = "e" + String(UnicodeScalar(0x0301)!)       // "é" (e + combining acute)
    suk("pw/confirm-nfc-ne-nfd", PasswordPolicy.confirms(composed, decomposed) == false)
    suk("pw/confirm-same-matches", PasswordPolicy.confirms("hunter2hunter2", "hunter2hunter2") == true)
    suk("pw/encode-no-normalization", PasswordPolicy.encode(composed) != PasswordPolicy.encode(decomposed))

    // Weakness heuristic: advisory only.
    suk("pw/weak-warns-low-variety", PasswordPolicy.weaknessWarning(String(repeating: "a", count: 12)) != nil)
    suk("pw/strong-passphrase-silent", PasswordPolicy.weaknessWarning("correct horse battery staple") == nil)
    suk("pw/short-but-varied-silent", PasswordPolicy.weaknessWarning("Abcd1234!xyz") == nil) // 12, 4 classes
}

// MARK: - 2. SelfTestEngine

// A vault dir that really carries isExcludedFromBackup (set by ensureDirectory).
private func excludedVaultDir() -> (VaultStore, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vaultsetup-\(UUID().uuidString)")
    let store = VaultStore(dir: dir, client: FakeSeal(R: 1000),
                           schedule: Schedule(windows: [DailyWindow(start: TimeOfDay(hour: 4, minute: 0)!,
                                                                     end: TimeOfDay(hour: 5, minute: 0)!)],
                                              calendar: Calendar(identifier: .gregorian)))
    try! store.ensureDirectory()
    return (store, dir)
}

private func scratch() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("vaultscratch-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func outcome(_ rs: [SelfTestEngine.StepResult], _ s: SelfTestEngine.Step) -> SelfTestEngine.Outcome? {
    rs.first { $0.step == s }?.outcome
}

private func selfTestEngineTests() {
    let (store, vdir) = excludedVaultDir(); defer { try? FileManager.default.removeItem(at: vdir) }
    let vaultDir = store.dir

    func runWith(_ fake: FakeSelfTestServices, budget: Double = 5000) -> [SelfTestEngine.StepResult] {
        let sc = scratch(); defer { try? FileManager.default.removeItem(at: sc) }
        return SelfTestEngine(services: fake, benchmarkBudgetMs: budget).run(scratchDir: sc, vaultDir: vaultDir)
    }

    // All-green machine: every step passes, gate is clear.
    let allGood = runWith(FakeSelfTestServices(round: 1000))
    suk("selftest/all-pass", allGood.allSatisfy { $0.outcome == .pass })
    suk("selftest/gate-clear", SelfTestEngine.gate(allGood) == .clear)
    suk("selftest/step-count", allGood.count == SelfTestEngine.Step.allCases.count)

    // Argon2 KAT mismatch ⇒ hard fail + gate blocked on that step.
    let badKAT = FakeSelfTestServices(round: 1000); badKAT.argon2VectorCorrect = false
    let kr = runWith(badKAT)
    suk("selftest/argon2-vector-mismatch-fails", outcome(kr, .argon2Vector) == .fail)
    suk("selftest/gate-blocked-on-fail", SelfTestEngine.gate(kr) == .blocked([.argon2Vector]))

    // 1 GiB allocation failure ⇒ benchmark fails CLOSED (no downgrade).
    let allocFail = FakeSelfTestServices(round: 1000); allocFail.argon2BenchmarkFails = true
    suk("selftest/benchmark-allocfail-fails", outcome(runWith(allocFail), .argon2Benchmark) == .fail)

    // Benchmark over (negative) budget ⇒ warn, never fail.
    let slow = runWith(FakeSelfTestServices(round: 1000), budget: -1)
    suk("selftest/benchmark-slow-warns", outcome(slow, .argon2Benchmark) == .warn)

    // Tampered / missing helper binary ⇒ integrity step fails.
    let tampered = FakeSelfTestServices(round: 1000); tampered.preflightError = .failClosed("hash mismatch")
    suk("selftest/preflight-fail", outcome(runWith(tampered), .helperBinaryValid) == .fail)

    // Round-trip: offline current-round, seal failure, and an alarming immediate
    // unseal all fail the round-trip step; a correct round_not_ready passes.
    let offline = FakeSelfTestServices(round: 1000); offline.currentRoundResult = .failure(.timeout)
    suk("selftest/roundtrip-offline-fails", outcome(runWith(offline), .helperRoundTrip) == .fail)
    let sealFail = FakeSelfTestServices(round: 1000); sealFail.sealResult = .failure(.timeout)
    suk("selftest/roundtrip-seal-fails", outcome(runWith(sealFail), .helperRoundTrip) == .fail)
    let opensNow = FakeSelfTestServices(round: 1000); opensNow.unsealResult = .success(Data("PLAIN".utf8))
    suk("selftest/roundtrip-immediate-open-fails", outcome(runWith(opensNow), .helperRoundTrip) == .fail)
    suk("selftest/roundtrip-locked-passes", outcome(runWith(FakeSelfTestServices(round: 1000)), .helperRoundTrip) == .pass)

    // Endpoint policy: ≥2 pass, exactly 1 warns, 0 fails, forged chain fails,
    // probe transport error fails.
    let one = FakeSelfTestServices(round: 1000)
    one.endpointsResult = .success(EndpointReport(
        endpoints: [EndpointStatus(endpoint: "a", ok: true, round: 1000, code: ""),
                    EndpointStatus(endpoint: "b", ok: false, round: 0, code: "timeout")],
        okCount: 1, total: 2))
    suk("selftest/endpoints-one-warns", outcome(runWith(one), .endpointsReachable) == .warn)
    suk("selftest/gate-warn-needs-confirm",
        SelfTestEngine.gate(runWith(one)) == .needsConfirmation([.endpointsReachable]))

    let zero = FakeSelfTestServices(round: 1000)
    zero.endpointsResult = .success(EndpointReport(
        endpoints: [EndpointStatus(endpoint: "a", ok: false, round: 0, code: "timeout")], okCount: 0, total: 1))
    suk("selftest/endpoints-zero-fails", outcome(runWith(zero), .endpointsReachable) == .fail)

    let forged = FakeSelfTestServices(round: 1000)
    forged.endpointsResult = .success(EndpointReport(
        endpoints: [EndpointStatus(endpoint: "a", ok: true, round: 1000, code: ""),
                    EndpointStatus(endpoint: "b", ok: false, round: 0, code: "chain_mismatch")],
        okCount: 1, total: 2))
    suk("selftest/endpoints-chain-mismatch-fails", outcome(runWith(forged), .endpointsReachable) == .fail)

    let probeErr = FakeSelfTestServices(round: 1000); probeErr.endpointsResult = .failure(.timeout)
    suk("selftest/endpoints-probe-error-fails", outcome(runWith(probeErr), .endpointsReachable) == .fail)

    // Backup exclusion: a plain dir WITHOUT the attribute fails the step.
    let plain = FileManager.default.temporaryDirectory.appendingPathComponent("vaultplain-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: plain) }
    let sc = scratch(); defer { try? FileManager.default.removeItem(at: sc) }
    let plainResults = SelfTestEngine(services: FakeSelfTestServices(round: 1000))
        .run(scratchDir: sc, vaultDir: plain)
    suk("selftest/backup-exclusion-missing-fails", outcome(plainResults, .backupExclusion) == .fail)

    // gate() reduction over synthetic results.
    let r: (SelfTestEngine.Step, SelfTestEngine.Outcome) -> SelfTestEngine.StepResult = {
        SelfTestEngine.StepResult(step: $0, outcome: $1, detail: "")
    }
    suk("gate/clear", SelfTestEngine.gate([r(.argon2Vector, .pass), r(.backupExclusion, .pass)]) == .clear)
    suk("gate/warn", SelfTestEngine.gate([r(.argon2Vector, .pass), r(.endpointsReachable, .warn)])
        == .needsConfirmation([.endpointsReachable]))
    suk("gate/blocked-beats-warn",
        SelfTestEngine.gate([r(.endpointsReachable, .warn), r(.helperBinaryValid, .fail)]) == .blocked([.helperBinaryValid]))
}

// MARK: - 3. FirstRunSetup

private func firstRunSetupTests() {
    // Deterministic clock + round, mirroring the store/session suites so the
    // schedule floors and the fake time-lock agree.
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    var noon = DateComponents(); noon.year = 2026; noon.month = 6; noon.day = 1; noon.hour = 12
    let now = cal.date(from: noon)!
    let R = TrustedTime.expectedRound(at: now)
    let schedule = Schedule(windows: [DailyWindow(start: TimeOfDay(hour: 4, minute: 0)!,
                                                  end: TimeOfDay(hour: 5, minute: 0)!)], calendar: cal)
    let password = "correct horse battery staple"
    let notes = Array("admin pw: hunter2\nCanopy: swordfish".utf8)

    func freshSetup(_ configure: (FakeSelfTestServices) -> Void = { _ in })
        -> (FirstRunSetup, VaultStore, FakeSeal, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vaultsetup-\(UUID().uuidString)")
        let fake = FakeSeal(R: R)
        let store = VaultStore(dir: dir, client: fake, schedule: schedule, clock: { now })
        let services = FakeSelfTestServices(round: R)
        configure(services)
        return (FirstRunSetup(store: store, services: services), store, fake, dir)
    }

    // Rejects an invalid password before anything else.
    do {
        let (setup, _, fake, dir) = freshSetup(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = setup.create(password: "short", confirmPassword: "short", initialNotes: notes,
                             acknowledgeDataLossWarnings: true, confirmWarnings: true)
        var ok = false; if case .failure(.password(.tooShort)) = r { ok = true }
        suk("create/rejects-short-password", ok && fake.sealCalls == 0)
    }

    // Rejects a confirm mismatch.
    do {
        let (setup, _, fake, dir) = freshSetup(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = setup.create(password: password, confirmPassword: password + "x", initialNotes: notes,
                             acknowledgeDataLossWarnings: true, confirmWarnings: true)
        var ok = false; if case .failure(.passwordMismatch) = r { ok = true }
        suk("create/rejects-confirm-mismatch", ok && fake.sealCalls == 0)
    }

    // Rejects until the data-loss warnings are acknowledged.
    do {
        let (setup, _, fake, dir) = freshSetup(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = setup.create(password: password, confirmPassword: password, initialNotes: notes,
                             acknowledgeDataLossWarnings: false, confirmWarnings: true)
        var ok = false; if case .failure(.dataLossNotAcknowledged) = r { ok = true }
        suk("create/requires-dataloss-ack", ok && fake.sealCalls == 0)
    }

    // A hard self-test failure (no reachable endpoint) BLOCKS the create — and
    // crucially nothing is sealed.
    do {
        let (setup, _, fake, dir) = freshSetup({ s in
            s.endpointsResult = .success(EndpointReport(
                endpoints: [EndpointStatus(endpoint: "a", ok: false, round: 0, code: "timeout")],
                okCount: 0, total: 1))
        }); defer { try? FileManager.default.removeItem(at: dir) }
        let r = setup.create(password: password, confirmPassword: password, initialNotes: notes,
                             acknowledgeDataLossWarnings: true, confirmWarnings: true)
        var ok = false
        if case .failure(.selfTestBlocked(let steps)) = r { ok = steps.contains(.endpointsReachable) }
        suk("create/blocked-on-selftest-fail", ok && fake.sealCalls == 0)
    }

    // A self-test WARNING (single reachable endpoint) requires explicit
    // confirmation: refused without it, proceeds with it.
    do {
        let (setup, _, fake, dir) = freshSetup({ s in
            s.endpointsResult = .success(EndpointReport(
                endpoints: [EndpointStatus(endpoint: "a", ok: true, round: R, code: ""),
                            EndpointStatus(endpoint: "b", ok: false, round: 0, code: "timeout")],
                okCount: 1, total: 2))
        }); defer { try? FileManager.default.removeItem(at: dir) }
        let refused = setup.create(password: password, confirmPassword: password, initialNotes: notes,
                                   acknowledgeDataLossWarnings: true, confirmWarnings: false)
        var ref = false; if case .failure(.warningsNotConfirmed) = refused { ref = true }
        suk("create/warn-refused-without-confirm", ref && fake.sealCalls == 0)

        let proceeded = setup.create(password: password, confirmPassword: password, initialNotes: notes,
                                     acknowledgeDataLossWarnings: true, confirmWarnings: true)
        var prc = false; if case .success = proceeded { prc = true }
        suk("create/warn-proceeds-with-confirm", prc && fake.sealCalls == 1)
    }

    // Full happy path: creates a REAL future-locked vault sealed to the first
    // window; it cannot open now, but re-opens with the password once the round
    // reaches the committed start, recovering the initial notes.
    do {
        let (setup, store, fake, dir) = freshSetup(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = setup.create(password: password, confirmPassword: password, initialNotes: notes,
                             acknowledgeDataLossWarnings: true, confirmWarnings: true)
        guard case .success(let report) = r else { suk("create/succeeds", false); return }
        suk("create/succeeds", fake.sealCalls == 1)
        suk("create/window-is-forward", report.createdWindow.startRound > R)
        // First creation does NOT enforce the minimum-lock floor (it honors the
        // soonest future window — proven in schedule_suite create/*). It MUST
        // still clear the freshness margin, or the helper would reject the seal.
        suk("create/clears-freshness",
            report.createdWindow.startRound > R + UInt64(VaultConstants.FRESHNESS_MARGIN_ROUNDS))

        // Right after creation the vault is future-locked: no access.
        var lockedNow = false
        if case .lockedUntil = store.load().result { lockedNow = true }
        suk("create/locked-immediately", lockedNow)

        // Advance to the committed start: it opens, and the password recovers the
        // exact initial notes.
        fake.R = report.createdWindow.startRound
        guard case .openWindow(let w, let payload) = store.load().result, w == report.createdWindow else {
            suk("create/opens-at-window", false); return
        }
        suk("create/opens-at-window", true)
        switch VaultSession.open(store: store, window: w, payload: payload, password: Array(password.utf8)) {
        case .success(let (recovered, _)): suk("create/recovers-initial-notes", recovered == notes)
        case .failure: suk("create/recovers-initial-notes", false)
        }
    }
}

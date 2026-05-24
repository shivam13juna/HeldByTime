// helper_suite.swift — Task 4: Swift helper-boundary wrapper + trusted time.
//
// Three layers, tested from pure to live:
//   1. HelperWire.map — the TOTAL (timedOut, exit, stdout, stderr) -> Result
//      mapping, every branch including all fail-closed buckets.
//   2. TrustedTime — round/time math and the Swift-side seal-target refusal.
//   3. HelperRunner / VaultSealClient — real subprocess hardening against
//      generated fixture executables (absolute path, no shell, EMPTY env, capped
//      IO both ways, timeout = fail-closed, exec-bit + SHA-256 launch check).
//
// Fixtures are tiny bash scripts. Because the runner clears the environment,
// `$PATH` is empty in the child, so fixtures call externals by absolute path
// (/bin/cat, /bin/sleep) or use bash builtins (printf/echo) — and the env
// isolation test relies on exactly that emptiness.

import Foundation
import CryptoKit
import Darwin

private func hck(_ n: String, _ cond: Bool, _ d: String = "") { check("helper/" + n, cond, d) }

/// Write a fixture script, set its mode, and return (url, its SHA-256).
private func writeFixture(_ dir: URL, _ name: String, _ script: String, exec: Bool = true) -> (URL, [UInt8]) {
    let url = dir.appendingPathComponent(name)
    try! Data(script.utf8).write(to: url)
    chmod(url.path, exec ? 0o755 : 0o644)
    let sha = Array(SHA256.hash(data: try! Data(contentsOf: url)))
    return (url, sha)
}

private func matches(_ r: Result<Data, HelperError>, _ want: HelperError) -> Bool {
    guard case .failure(let got) = r else { return false }
    return got == want
}
private func isSuccess(_ r: Result<Data, HelperError>, _ bytes: Data) -> Bool {
    if case .success(let d) = r { return d == bytes }
    return false
}
private func isFailClosed(_ r: Result<Data, HelperError>) -> Bool {
    if case .failure(.failClosed) = r { return true }
    return false
}

func runHelperSuite() {
    wireMappingTests()
    trustedTimeTests()
    subprocessTests()
}

// MARK: - 1. HelperWire.map (pure)

private func wireMappingTests() {
    let payload = Data("opaque sealed bytes".utf8)

    // Success: exit 0, payload on stdout, nothing on stderr.
    hck("map/success", isSuccess(
        HelperWire.map(timedOut: false, exitCode: 0, stdout: payload, stdoutTruncated: false,
                       stderr: Data(), stderrTruncated: false), payload))

    // Strict success: any stderr on a zero exit is anomalous -> fail closed.
    hck("map/stderr-on-success-failclosed", isFailClosed(
        HelperWire.map(timedOut: false, exitCode: 0, stdout: payload, stdoutTruncated: false,
                       stderr: Data("noise".utf8), stderrTruncated: false)))

    // timedOut short-circuits to .timeout regardless of stream contents.
    hck("map/timeout", matches(
        HelperWire.map(timedOut: true, exitCode: 0, stdout: payload, stdoutTruncated: false,
                       stderr: Data(), stderrTruncated: false), .timeout))

    // Each of the six detailless codes maps to its specific case.
    let codeCases: [(String, HelperError)] = [
        ("round_not_ready", .roundNotReady), ("round_too_near", .roundTooNear),
        ("stale_round", .staleRound), ("auth_failed", .authFailed),
        ("chain_mismatch", .chainMismatch), ("timeout", .timeout),
    ]
    for (code, want) in codeCases {
        let stderr = Data("{\"error\":\"\(code)\"}\n".utf8)
        hck("map/code-\(code)", matches(
            HelperWire.map(timedOut: false, exitCode: 1, stdout: Data(), stdoutTruncated: false,
                           stderr: stderr, stderrTruncated: false), want))
    }

    // parse_error forwards its detail string.
    let pe = HelperWire.map(timedOut: false, exitCode: 1, stdout: Data(), stdoutTruncated: false,
                            stderr: Data("{\"error\":\"parse_error\",\"detail\":\"bad args\"}".utf8),
                            stderrTruncated: false)
    hck("map/parse-error-detail", { if case .failure(.parseError(let d)) = pe { return d == "bad args" }; return false }())

    // Unknown code -> fail closed.
    hck("map/unknown-code-failclosed", isFailClosed(
        HelperWire.map(timedOut: false, exitCode: 1, stdout: Data(), stdoutTruncated: false,
                       stderr: Data("{\"error\":\"banana\"}".utf8), stderrTruncated: false)))

    // Non-zero exit, stderr is not JSON -> fail closed.
    hck("map/nonjson-stderr-failclosed", isFailClosed(
        HelperWire.map(timedOut: false, exitCode: 1, stdout: Data(), stdoutTruncated: false,
                       stderr: Data("not json".utf8), stderrTruncated: false)))

    // Non-zero exit, empty stderr -> fail closed.
    hck("map/nonzero-no-json-failclosed", isFailClosed(
        HelperWire.map(timedOut: false, exitCode: 3, stdout: Data(), stdoutTruncated: false,
                       stderr: Data(), stderrTruncated: false)))

    // stdout payload present alongside an error exit -> fail closed.
    hck("map/stdout-with-error-failclosed", isFailClosed(
        HelperWire.map(timedOut: false, exitCode: 1, stdout: payload, stdoutTruncated: false,
                       stderr: Data("{\"error\":\"auth_failed\"}".utf8), stderrTruncated: false)))

    // Either stream over its cap -> fail closed (we never saw the full output).
    hck("map/stdout-truncated-failclosed", isFailClosed(
        HelperWire.map(timedOut: false, exitCode: 0, stdout: payload, stdoutTruncated: true,
                       stderr: Data(), stderrTruncated: false)))
    hck("map/stderr-truncated-failclosed", isFailClosed(
        HelperWire.map(timedOut: false, exitCode: 1, stdout: Data(), stdoutTruncated: false,
                       stderr: Data("{\"error\":\"timeout\"}".utf8), stderrTruncated: true)))
}

// MARK: - 2. TrustedTime (pure)

private func trustedTimeTests() {
    let genesis = Date(timeIntervalSince1970: Double(VaultConstants.DRAND_GENESIS_UNIX))
    hck("time/expected-at-genesis", TrustedTime.expectedRound(at: genesis) == 1,
        "\(TrustedTime.expectedRound(at: genesis))")
    let plus1000 = genesis.addingTimeInterval(Double(VaultConstants.DRAND_PERIOD_SECONDS * 1000))
    hck("time/expected-genesis+1000", TrustedTime.expectedRound(at: plus1000) == 1001,
        "\(TrustedTime.expectedRound(at: plus1000))")
    hck("time/expected-before-genesis-clamps", TrustedTime.expectedRound(at: Date(timeIntervalSince1970: 0)) == 1)

    // Seal-target gate: latest=1000, margin=FRESHNESS_MARGIN_ROUNDS.
    let latest: UInt64 = 1000
    let margin = UInt64(VaultConstants.FRESHNESS_MARGIN_ROUNDS)
    hck("time/seal-at-margin-too-near",
        TrustedTime.validateSealTarget(targetRound: latest + margin, verifiedLatest: latest) == .roundTooNear)
    hck("time/seal-below-margin-too-near",
        TrustedTime.validateSealTarget(targetRound: latest + margin - 1, verifiedLatest: latest) == .roundTooNear)
    hck("time/seal-past-too-near",
        TrustedTime.validateSealTarget(targetRound: 500, verifiedLatest: latest) == .roundTooNear)
    hck("time/seal-just-far-enough-ok",
        TrustedTime.validateSealTarget(targetRound: latest + margin + 1, verifiedLatest: latest) == nil)

    // Staleness: latest far behind the clock-implied round is stale; fresh is not.
    let now = Date(timeIntervalSince1970: Double(VaultConstants.DRAND_GENESIS_UNIX) + 3_000_000)
    let expectedNow = TrustedTime.expectedRound(at: now)
    hck("time/stale-detected", TrustedTime.isStale(verifiedLatest: 5, now: now))
    hck("time/fresh-not-stale", !TrustedTime.isStale(verifiedLatest: expectedNow, now: now))
}

// MARK: - 3. HelperRunner / VaultSealClient (real subprocess)

private func subprocessTests() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vaulttest-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    func runner(_ url: URL, _ sha: [UInt8], timeoutMs: Int = 4000,
                maxStdout: Int = VaultConstants.MAX_STDOUT_BYTES,
                maxStdin: Int = VaultConstants.MAX_SEALED_PAYLOAD_BYTES) -> HelperRunner {
        HelperRunner(executableURL: url, expectedSHA256: sha, timeoutMilliseconds: timeoutMs,
                     maxStdinBytes: maxStdin, maxStdoutBytes: maxStdout)
    }

    // --- Fixtures ---
    let (echo, echoSHA) = writeFixture(dir, "echoback", "#!/bin/bash\nexec /bin/cat\n")
    let (cur, curSHA) = writeFixture(dir, "currentround",
        "#!/bin/bash\nprintf '{\"round\":1005,\"expected_now\":1000,\"unix_time\":1700000000}'\n")
    let (rnr, rnrSHA) = writeFixture(dir, "rnr", "#!/bin/bash\nprintf '{\"error\":\"round_not_ready\"}\\n' >&2\nexit 1\n")
    let (pe, peSHA) = writeFixture(dir, "pe", "#!/bin/bash\nprintf '{\"error\":\"parse_error\",\"detail\":\"x\"}\\n' >&2\nexit 1\n")
    let (unk, unkSHA) = writeFixture(dir, "unk", "#!/bin/bash\nprintf '{\"error\":\"nope\"}\\n' >&2\nexit 1\n")
    let (bad, badSHA) = writeFixture(dir, "bad", "#!/bin/bash\nprintf 'not json\\n' >&2\nexit 1\n")
    let (empty, emptySHA) = writeFixture(dir, "empty", "#!/bin/bash\nexit 4\n")
    let (swe, sweSHA) = writeFixture(dir, "swe", "#!/bin/bash\nprintf 'leak'\nprintf '{\"error\":\"auth_failed\"}\\n' >&2\nexit 1\n")
    let (sos, sosSHA) = writeFixture(dir, "sos", "#!/bin/bash\nprintf 'ok'\nprintf 'noise\\n' >&2\nexit 0\n")
    let (hang, hangSHA) = writeFixture(dir, "hang", "#!/bin/bash\nexec /bin/sleep 5\n")
    let (big, bigSHA) = writeFixture(dir, "big", "#!/bin/bash\nprintf 'A%.0s' {1..4096}\n")
    let (envf, envSHA) = writeFixture(dir, "envf", "#!/bin/bash\necho \"leak=${VAULT_TEST_LEAK:-NONE}\"\n")
    let (noexec, noexecSHA) = writeFixture(dir, "noexec", "#!/bin/bash\nexec /bin/cat\n", exec: false)

    // --- Launch integrity ---
    hck("run/echo-roundtrip", isSuccess(
        runner(echo, echoSHA).run(arguments: ["x"], stdin: Data("hello world".utf8)), Data("hello world".utf8)))
    hck("run/wrong-hash-failclosed", isFailClosed(
        runner(echo, [UInt8](repeating: 0, count: 32)).run(arguments: [], stdin: Data())))
    hck("run/empty-hash-failclosed", isFailClosed(
        runner(echo, []).run(arguments: [], stdin: Data())))
    hck("run/no-exec-bit-failclosed", isFailClosed(
        runner(noexec, noexecSHA).run(arguments: [], stdin: Data())))
    hck("run/missing-file-failclosed", isFailClosed(
        runner(dir.appendingPathComponent("does-not-exist"), echoSHA).run(arguments: [], stdin: Data())))

    // Symlink to a valid binary is rejected (lstat sees S_IFLNK, not S_IFREG).
    let link = dir.appendingPathComponent("echo-link")
    symlink(echo.path, link.path)
    hck("run/symlink-failclosed", isFailClosed(
        runner(link, echoSHA).run(arguments: [], stdin: Data())))

    // --- Error-code mapping through the real binary ---
    hck("run/code-round-not-ready", matches(runner(rnr, rnrSHA).run(arguments: [], stdin: Data()), .roundNotReady))
    hck("run/code-parse-error", { if case .failure(.parseError) = runner(pe, peSHA).run(arguments: [], stdin: Data()) { return true }; return false }())
    hck("run/unknown-code-failclosed", isFailClosed(runner(unk, unkSHA).run(arguments: [], stdin: Data())))
    hck("run/nonjson-failclosed", isFailClosed(runner(bad, badSHA).run(arguments: [], stdin: Data())))
    hck("run/nonzero-no-json-failclosed", isFailClosed(runner(empty, emptySHA).run(arguments: [], stdin: Data())))
    hck("run/stdout-with-error-failclosed", isFailClosed(runner(swe, sweSHA).run(arguments: [], stdin: Data())))
    hck("run/stderr-on-success-failclosed", isFailClosed(runner(sos, sosSHA).run(arguments: [], stdin: Data())))

    // --- Timeout = fail-closed ---
    let t0 = Date()
    let timed = runner(hang, hangSHA, timeoutMs: 400).run(arguments: [], stdin: Data())
    hck("run/timeout", matches(timed, .timeout), "elapsed \(Date().timeIntervalSince(t0))s")
    hck("run/timeout-prompt", Date().timeIntervalSince(t0) < 3.0, "killed promptly")

    // --- Oversized stdout (small cap) = fail-closed ---
    hck("run/oversized-stdout-failclosed", isFailClosed(
        runner(big, bigSHA, maxStdout: 1024).run(arguments: [], stdin: Data())))

    // --- stdin cap refused before launch ---
    hck("run/stdin-cap-failclosed", isFailClosed(
        runner(echo, echoSHA, maxStdin: 8).run(arguments: [], stdin: Data(repeating: 0x41, count: 16))))

    // --- Empty environment: a parent var must NOT reach the child ---
    setenv("VAULT_TEST_LEAK", "should-not-leak", 1)
    let envOut = runner(envf, envSHA).run(arguments: [], stdin: Data())
    if case .success(let d) = envOut {
        let s = String(decoding: d, as: UTF8.self)
        hck("run/empty-env", s.contains("leak=NONE") && !s.contains("should-not-leak"), s.trimmingCharacters(in: .whitespacesAndNewlines))
    } else {
        hck("run/empty-env", false, "env fixture did not succeed")
    }
    unsetenv("VAULT_TEST_LEAK")

    // --- VaultSealClient ---
    let curClient = VaultSealClient(runner: runner(cur, curSHA))
    switch curClient.currentRound() {
    case .success(let info): hck("client/current-round", info.round == 1005 && info.expectedNow == 1000)
    case .failure(let e): hck("client/current-round", false, "\(e)")
    }

    // Swift-side refusal: a too-near target must be denied WITHOUT spawning the
    // helper (echoback would otherwise echo the payload back as success).
    let sealClient = VaultSealClient(runner: runner(echo, echoSHA))
    hck("client/seal-too-near-refused",
        matches(sealClient.seal(payload: Data("P".utf8), targetRound: 1010, verifiedLatest: 1000), .roundTooNear))
    // Far-enough target proceeds to spawn (echoback returns the forwarded stdin).
    hck("client/seal-far-enough-spawns",
        isSuccess(sealClient.seal(payload: Data("P".utf8), targetRound: 1021, verifiedLatest: 1000), Data("P".utf8)))
    hck("client/unseal-forwards",
        isSuccess(sealClient.unseal(sealed: Data("SEALED".utf8)), Data("SEALED".utf8)))

    // --- SelfTestEngine skeleton ---
    let engine = SelfTestEngine(client: VaultSealClient(runner: runner(cur, curSHA)))
    let results = engine.run()
    hck("selftest/step-count", results.count == SelfTestEngine.Step.allCases.count)
    func stepPassed(_ rs: [SelfTestEngine.StepResult], _ s: SelfTestEngine.Step) -> Bool {
        rs.first { $0.step == s }?.passed ?? false
    }
    hck("selftest/argon2-vector", stepPassed(results, .argon2Vector))
    hck("selftest/helper-binary-valid", stepPassed(results, .helperBinaryValid))
    hck("selftest/helper-responds", stepPassed(results, .helperResponds))

    // Negative: a tampered helper fails the binary-integrity step (argon2 still passes).
    let badEngine = SelfTestEngine(client: VaultSealClient(runner: runner(cur, [UInt8](repeating: 0, count: 32))))
    let badResults = badEngine.run()
    hck("selftest/tamper-fails-binary", !stepPassed(badResults, .helperBinaryValid) && stepPassed(badResults, .argon2Vector))
}

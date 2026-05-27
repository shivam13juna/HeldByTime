// tests/e2e/main.swift — Task 12: LIVE end-to-end test across a REAL drand round
// boundary, driving the REAL `vaultseal` helper (not the offline FakeSeal) through
// the real VaultStore / VaultSession / VLT1 / manifest / PW01 path.
// app.md §10 step 14, §11 ("Required tests" — the live counterparts).
//
// This is deliberately NOT part of `./run_tests`, which is offline by design. It
// needs the network and a few minutes of real wall-clock time, so it is its own
// command, `./e2e_test`. The offline harness keeps a STATIC gate (run_tests step
// 7f, `e2e/harness-gate`) asserting this file + the script + the checklist exist
// and cover the required legs — mirroring Task 11's `build/bundling-gate`.
//
// quicknet has a 3-second period and FRESHNESS_MARGIN_ROUNDS = 20 (~60s), so a
// window can be sealed ~90s out and actually crossed live. Legs (each emits the
// same `RESULT:` lines the unit suites use, consumed by `e2e_test`):
//
//   1. seal to a near-future round   -> load() is LOCKED, won't open early; the
//      on-disk blob does NOT contain the plaintext sentinel (it is sealed).
//   2. wait for the round            -> load() is openWindow; the password
//      decrypts the sentinel; a WRONG password fails closed (no plaintext).
//   3. interactive window-end reseal -> session.reseal moves protection FORWARD;
//      load() is locked again (both files re-sealed to a future round).
//   4. expired (the force-kill analogue) -> a vault whose committed window has
//      fully passed is defensively, PASSWORDLESSLY re-sealed forward on next load.
//   5. offline at unlock             -> the REAL helper, run behind a dead proxy,
//      fails closed (non-zero exit, empty stdout, closed-domain error on stderr).
//   6. no durable plaintext          -> after every write, the scratch vault files
//      hold only sealed bytes (sentinel absent) and are mode 0600.
//   7. multi-vault                    -> two real vaults under one root, enumerated
//      by VaultRegistry, each independently locked; deleting one leaves the other
//      intact (the shape the re-seal agent iterates).
//
// Throwaway sentinel payload + scratch dirs ONLY — never a real secret. The real
// admin / Canopy passwords are entered only via the GUI first-run (see E2E.md);
// the live GUI launch + manual force-kill + system-wide leak scan are that
// checklist's job, since a windowed .app cannot be driven head­less from here.

import Foundation
import CryptoKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)   // survive a trap with partial output (as tests/main.swift)

// MARK: - args + the real helper

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    fail("e2e/args", "usage: e2e_live <helper-path>")
    exit(1)
}
let helperPath = argv[1]
guard let helperData = FileManager.default.contents(atPath: helperPath) else {
    fail("e2e/helper-present", "cannot read helper at \(helperPath)")
    exit(1)
}
// The expected hash IS the bytes we will preflight — exactly what build.sh compiles
// in. Computing it here drives the real HelperRunner integrity check against the
// actual on-disk binary (the live equivalent of BundledHelper.sha256).
let helperHash = Array(SHA256.hash(data: helperData))
let runner = HelperRunner(executableURL: URL(fileURLWithPath: helperPath), expectedSHA256: helperHash)
let client = VaultSealClient(runner: runner)

// MARK: - throwaway payload (never a real secret)

let sentinel = "E2E_PLAINTEXT_SENTINEL_\(UInt64.random(in: 0 ..< UInt64.max))"
let password = Array("e2e-throwaway-passphrase-123".utf8)            // >= 12 scalars
let wrongPassword = Array("not-the-right-passphrase".utf8)
let content = VaultContent(notes: "live e2e note \(sentinel)",
                           secrets: [VaultSecret(label: "sentinel", value: sentinel)])
guard let notesBytes = try? content.encode() else {
    fail("e2e/encode-content", "VaultContent.encode failed")
    exit(1)
}

// A real daily-window schedule so the forward (interactive + defensive) re-seals
// have a valid `nextLock` target to move protection to.
guard let s = TimeOfDay(hour: 3, minute: 0), let e = TimeOfDay(hour: 5, minute: 0) else {
    fail("e2e/schedule", "TimeOfDay construction failed"); exit(1)
}
let schedule = Schedule(windows: [DailyWindow(start: s, end: e)], calendar: .current)

let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("vault-e2e-\(UInt64.random(in: 0 ..< UInt64.max))", isDirectory: true)
func scratch(_ name: String) -> URL { scratchRoot.appendingPathComponent(name, isDirectory: true) }
defer { try? FileManager.default.removeItem(at: scratchRoot) }

// MARK: - small live helpers

func makeStore(_ dir: URL) -> VaultStore { VaultStore(dir: dir, client: client, schedule: schedule) }

func latestRound() -> UInt64? {
    if case .success(let info) = client.currentRound() { return info.round }
    return nil
}

/// Poll `pred` every 3s up to `timeoutSec`. Returns the final predicate value.
func waitUntil(_ timeoutSec: Double, _ pred: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSec)
    while Date() < deadline {
        if pred() { return true }
        Thread.sleep(forTimeInterval: 3)
    }
    return pred()
}

/// Seal `notesBytes` into a fresh vault committed to [start, end] (direct commit,
/// bypassing the daily-schedule mapping so we can choose a near-future boundary).
func sealVault(_ dir: URL, start: UInt64, end: UInt64, latest: UInt64) -> Bool {
    let store = makeStore(dir)
    try? store.ensureDirectory()
    let salt = SecureRandom.bytes(VaultConstants.ARGON2_SALT_LEN)
    let nonce = SecureRandom.bytes(VaultConstants.GCM_NONCE_LEN)
    guard let key = try? KeyDerivation.deriveKey(password: password, salt: salt),
          let pw01 = try? PW01.seal(notes: notesBytes, key: key, salt: salt, nonce: nonce) else { return false }
    let window = Manifest.Window(startRound: start, endRound: end)
    if case .failure = store.commit(pw01: pw01, window: window, verifiedLatest: latest) { return false }
    return true
}

/// True if any file directly in `dir` contains `needle` in cleartext.
func diskContains(_ dir: URL, _ needle: String) -> Bool {
    let needleData = Data(needle.utf8)
    guard let items = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil) else { return false }
    for f in items {
        if let d = FileManager.default.contents(atPath: f.path), d.range(of: needleData) != nil {
            return true
        }
    }
    return false
}

func fileMode(_ url: URL) -> mode_t? {
    var st = stat()
    if lstat(url.path, &st) != 0 { return nil }
    return st.st_mode & 0o777
}

// ======================================================================
// LEG 1+2 — seal near-future, won't open early, opens at the round boundary
// ======================================================================
guard let r0 = latestRound() else {
    fail("e2e/current-round", "real helper current-round failed (network/Canopy down?)")
    exit(1)
}
pass("e2e/current-round")   // a drand-verified round through the real helper

let dir1 = scratch("interactive")
let start1 = r0 + 30                  // ~90s out: clears the helper's latest+margin recheck
let end1 = start1 + 30                // ~90s open window: ample time to unseal before it expires
check("e2e/seal-near-future", sealVault(dir1, start: start1, end: end1, latest: r0),
      "commit to a near-future round failed")

let store1 = makeStore(dir1)
if case .lockedUntil = store1.load().result {
    pass("e2e/locked-before-window")          // the time-lock holds: no early open
} else {
    fail("e2e/locked-before-window", "expected lockedUntil before the start round")
}
check("e2e/sealed-not-plaintext", !diskContains(dir1, sentinel),
      "plaintext sentinel found in the sealed on-disk blob")

info("e2e/waiting-open", "waiting up to 180s for round \(start1) (~90s)")
let openedOK = waitUntil(180) {
    if case .openWindow = store1.load().result { return true }
    return false
}
if openedOK, case .openWindow(let window, let payload) = store1.load().result {
    pass("e2e/opens-at-round")                 // the window opened exactly when its round was published
    switch VaultSession.open(store: store1, window: window, payload: payload, password: password) {
    case .success(let r):
        check("e2e/decrypts-sentinel", r.notes == notesBytes, "recovered notes != sealed notes")
        // Wrong password must fail closed with NO partial plaintext.
        if case .failure(.format(.authError)) =
            VaultSession.open(store: store1, window: window, payload: payload, password: wrongPassword) {
            pass("e2e/wrong-password-failclosed")
        } else {
            fail("e2e/wrong-password-failclosed", "wrong password did not map to authError")
        }
        // ----- LEG 3: interactive window-end re-seal moves protection FORWARD -----
        switch r.session.reseal(notes: notesBytes, trigger: .windowEndReached) {
        case .success(let w2):
            check("e2e/interactive-reseal-forward", w2.startRound > end1,
                  "re-seal target \(w2.startRound) not past the old end \(end1)")
            if case .lockedUntil = store1.load().result {
                pass("e2e/relocked-after-reseal")   // both files now sealed to a future round
            } else {
                fail("e2e/relocked-after-reseal", "vault not locked after interactive re-seal")
            }
        case .failure(let err):
            fail("e2e/interactive-reseal-forward", "reseal failed: \(err)")
        }
    case .failure(let err):
        fail("e2e/opens-at-round", "open/decrypt failed: \(err)")
    }
} else {
    fail("e2e/opens-at-round", "window did not open within the timeout")
}

// ======================================================================
// LEG 4 — expired (the force-kill-mid-window analogue): on the next launch a
// vault whose committed window has fully passed is defensively, PASSWORDLESSLY
// re-sealed forward. (store2 holds no password — the path is passwordless by
// construction; here we prove it end-to-end against the real network.)
// ======================================================================
guard let r1 = latestRound() else {
    fail("e2e/current-round-2", "real helper current-round failed before leg 4")
    exit(1)
}
let dir2 = scratch("defensive")
let start2 = r1 + 30
let end2 = start2 + 4                  // ~12s window: expires shortly after it opens
check("e2e/seal-short-window", sealVault(dir2, start: start2, end: end2, latest: r1),
      "commit of the short-window vault failed")

let store2 = makeStore(dir2)
info("e2e/waiting-expiry", "waiting up to 240s for round > \(end2)")
let expiredOK = waitUntil(240) { (latestRound() ?? 0) > end2 }
check("e2e/reached-expiry", expiredOK, "the short window never expired within the timeout")

let out2 = store2.load()
if case .resealed(let w) = out2.result {
    pass("e2e/defensive-reseal")                         // passwordless forward re-seal fired on launch
    check("e2e/defensive-forward", w.startRound > end2, "defensive target not forward of the old end")
    if case .lockedUntil = store2.load().result {
        pass("e2e/relocked-after-defensive")
    } else {
        fail("e2e/relocked-after-defensive", "vault not locked after defensive re-seal")
    }
} else {
    fail("e2e/defensive-reseal", "expected .resealed, got \(out2.result)")
}

// ======================================================================
// LEG 5 — offline at unlock: the REAL helper, run behind a dead proxy, must fail
// closed (non-zero exit, empty stdout, a closed-domain JSON error on stderr). The
// hot path's HelperRunner gives the child an empty environment, so we invoke the
// real binary directly here to inject the proxy — exactly how the Go hermetic
// tests black-hole the network. load()'s offline -> .offline mapping itself is
// proven in store_suite with FakeSeal; this proves the real binary's behaviour.
// ======================================================================
do {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: helperPath)
    p.arguments = ["current-round"]
    p.environment = ["HTTPS_PROXY": "http://127.0.0.1:1",
                     "HTTP_PROXY": "http://127.0.0.1:1",
                     "ALL_PROXY": "http://127.0.0.1:1"]
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do {
        try p.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let failedClosed = p.terminationStatus != 0 && outData.isEmpty && !errData.isEmpty
        check("e2e/offline-failclosed", failedClosed,
              "exit=\(p.terminationStatus) stdoutBytes=\(outData.count) stderrBytes=\(errData.count)")
    } catch {
        fail("e2e/offline-failclosed", "could not spawn helper: \(error)")
    }
}

// ======================================================================
// LEG 6 — no durable plaintext: after all of the above writes/re-seals, the
// scratch vault files contain only sealed bytes (sentinel absent) and are 0600.
// (System-wide locations — Saved Application State, caches — belong to the GUI
// launch; scan_leak.sh + E2E.md cover those after the manual force-kill.)
// ======================================================================
check("e2e/no-plaintext-interactive", !diskContains(dir1, sentinel),
      "sentinel present in \(dir1.lastPathComponent) after re-seals")
check("e2e/no-plaintext-defensive", !diskContains(dir2, sentinel),
      "sentinel present in \(dir2.lastPathComponent) after re-seals")
let m1 = fileMode(dir1.appendingPathComponent("vault.dat"))
let m2 = fileMode(dir2.appendingPathComponent("vault.dat"))
check("e2e/files-0600", m1 == 0o600 && m2 == 0o600, "modes: primary1=\(m1.map{String($0,radix:8)} ?? "nil") primary2=\(m2.map{String($0,radix:8)} ?? "nil")")

// ======================================================================
// LEG 7 — multi-vault: TWO real vaults under one root, sealed via the real helper
// to different near-future rounds, enumerated by VaultRegistry and each
// independently time-locked. This is the exact shape the re-seal agent iterates
// (env.registry.list() → per-vault load()); here we prove against the real network
// that the registry discovers both, that each vault's gate is independent, and that
// deleting one leaves the other intact (no shared state, no cross-contamination).
// ======================================================================
guard let r3 = latestRound() else {
    fail("e2e/current-round-3", "real helper current-round failed before leg 7")
    exit(1)
}
let mvRoot = scratch("multivault")
let registry = VaultRegistry(root: mvRoot)
guard case .success(let vaultA) = registry.create(label: "Vault A"),
      case .success(let vaultB) = registry.create(label: "Vault B") else {
    fail("e2e/multivault-create", "VaultRegistry.create failed")
    exit(1)
}
// Different start rounds so the two vaults are genuinely distinct seals.
let sealedA = sealVault(vaultA.dir, start: r3 + 30, end: r3 + 60, latest: r3)
let sealedB = sealVault(vaultB.dir, start: r3 + 40, end: r3 + 70, latest: r3)
check("e2e/multivault-sealed", sealedA && sealedB, "sealing one or both vaults failed")

// The registry discovers BOTH sealed vaults (a dir with a vault.dat IS a vault).
let listed = registry.list()
check("e2e/multivault-enumerated",
      listed.count == 2 && listed.contains { $0.id == vaultA.id }
                        && listed.contains { $0.id == vaultB.id },
      "registry did not enumerate both vaults (got \(listed.count))")

// Each vault is independently locked before its own window — the per-vault gate
// the agent relies on. One vault's state never authorizes the other.
var eachLocked = !listed.isEmpty
for entry in listed {
    if case .lockedUntil = makeStore(entry.dir).load().result { continue }
    eachLocked = false
}
check("e2e/multivault-each-locked", eachLocked,
      "every enumerated vault must be lockedUntil before its window")

// Isolation: permanently deleting one vault leaves the other fully intact.
if case .failure(let err) = registry.delete(id: vaultA.id) {
    fail("e2e/multivault-delete-isolated", "delete failed: \(err)")
} else {
    let after = registry.list()
    check("e2e/multivault-delete-isolated",
          after.count == 1 && after.first?.id == vaultB.id,
          "deleting Vault A must leave exactly Vault B")
}
check("e2e/multivault-no-plaintext", !diskContains(vaultB.dir, sentinel),
      "sentinel present in a sealed multi-vault blob")

// MARK: - verdict
if failures == 0 {
    print("E2E: all live legs passed.")
    exit(0)
} else {
    print("E2E: \(failures) live leg(s) failed.")
    exit(1)
}

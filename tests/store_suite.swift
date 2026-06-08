// store_suite.swift — Task 6: the vault store (THE DANGEROUS TASK).
//
// Layers, pure -> live:
//   1. decide(_:_:) — the TOTAL primary×.bak decision matrix: every one of the
//      8×8 combinations is exercised, plus the governing invariants
//      (future ⇒ never .open; open+no-future ⇒ .open; etc.).
//   2. SecureFile — path/inode hardening (symlink, hardlink, wrong mode/owner)
//      and the durable write transaction (both files, 0600, byte-equality).
//   3. classify(_:verifiedRound:) — each terminal state from a real on-disk file.
//   4. load() — end-to-end recovery incl. the honest crash-intermediate states,
//      defensive (passwordless) forward re-seal, no-raw quarantine, offline.
//
// A `FakeSeal` stands in for the network helper: its "seal" tags a payload with
// its target round and its "unseal" returns round_not_ready until the verified
// round reaches that target — a faithful, offline time-lock simulator.

import Foundation
import CryptoKit
import Darwin

private func stk(_ n: String, _ cond: Bool, _ d: String = "") { check("store/" + n, cond, d) }

// MARK: - Fake seal service (offline time-lock simulator)

// Internal (not file-private) so the Task 7 session suite can reuse it.
final class FakeSeal: SealService {
    var R: UInt64
    var offline = false
    private(set) var sealCalls = 0
    private static let prefix = Data("FAKESEAL".utf8)

    init(R: UInt64) { self.R = R }

    func currentRound() -> Result<CurrentRoundInfo, HelperError> {
        if offline { return .failure(.timeout) }
        return .success(CurrentRoundInfo(round: R, expectedNow: R, unixTime: 0))
    }

    func seal(payload: Data, targetRound: UInt64, verifiedLatest: UInt64) -> Result<Data, HelperError> {
        sealCalls += 1
        var out = FakeSeal.prefix
        var t = targetRound
        withUnsafeBytes(of: &t) { out.append(contentsOf: $0) }
        out.append(payload)
        return .success(out)
    }

    func unseal(sealed: Data) -> Result<Data, HelperError> {
        guard sealed.count >= FakeSeal.prefix.count + 8,
              sealed.prefix(FakeSeal.prefix.count) == FakeSeal.prefix else {
            return .failure(.authFailed)   // not one of our blobs: forged/corrupt
        }
        let tStart = sealed.startIndex + FakeSeal.prefix.count
        let target = sealed.subdata(in: tStart..<tStart + 8).withUnsafeBytes {
            $0.loadUnaligned(as: UInt64.self)
        }
        if R < target { return .failure(.roundNotReady) }   // still sealed to the future
        return .success(sealed.subdata(in: tStart + 8..<sealed.endIndex))
    }
}

// MARK: - Fixture builders

private func tmpDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("vaultstore-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func somePW01() -> [UInt8] {
    // Opaque inner bytes — the store reuses these verbatim and never decrypts.
    // A real PW01 header prefix keeps it representative; contents are irrelevant.
    Array("PW01".utf8) + [UInt8](repeating: 0xAB, count: 80)
}

/// Build a VLT1 file sealed to `target`, committing `window`, with an optional
/// display override to forge a tampered (outer≠manifest) file. Uses a throwaway
/// builder seal so it never perturbs the store's `sealCalls` counter.
private func writeSealed(_ url: URL, window: Manifest.Window,
                         target: UInt64, displayOverride: Manifest.Window? = nil) {
    let builder = FakeSeal(R: 0)
    let manifest = try! Manifest.encode(window)
    let payload = Data(manifest + somePW01())
    let sealed = try! builder.seal(payload: payload, targetRound: target, verifiedLatest: 0).get()
    let disp = displayOverride ?? window
    let vlt1 = try! VLT1.encode(VLT1.Container(displayStartRound: disp.startRound,
                                               displayEndRound: disp.endRound,
                                               sealedPayload: [UInt8](sealed)))
    try! Data(vlt1).write(to: url)
    chmod(url.path, 0o600)
}

private func writeGarbage(_ url: URL) {
    try! Data("not a vault file at all".utf8).write(to: url)
    chmod(url.path, 0o600)
}

private func win(_ s: UInt64, _ e: UInt64) -> Manifest.Window { Manifest.Window(startRound: s, endRound: e) }

func runStoreSuite() {
    decideMatrixTests()
    secureFileTests()
    classifyTests()
    loadRecoveryTests()
}

// MARK: - 1. decide(_:_:) — total matrix

private func decideMatrixTests() {
    let all = VaultFileState.allCases

    // Totality: a value for every one of the 8×8 combinations (the compiler also
    // proves this — there is no `default`). We assert the count to lock the axis.
    stk("decide/state-count-8", all.count == 8, "\(all.count)")
    var covered = 0
    for p in all { for b in all { _ = VaultStore.decide(p, b); covered += 1 } }
    stk("decide/all-64-covered", covered == 64, "\(covered)")

    // Invariant A: a futureClaimed copy anywhere ⇒ NEVER .open (anti-shortening).
    var futureNeverOpens = true
    for p in all where p == .futureClaimed { for b in all { if case .open = VaultStore.decide(p, b) { futureNeverOpens = false } } }
    for b in all where b == .futureClaimed { for p in all { if case .open = VaultStore.decide(p, b) { futureNeverOpens = false } } }
    stk("decide/future-vetoes-open", futureNeverOpens)

    // Invariant B: an openWindow copy with NO futureClaimed present ⇒ .open.
    var openGrantsWhenNoFuture = true
    for p in all { for b in all {
        guard p != .futureClaimed, b != .futureClaimed, p != .indeterminate, b != .indeterminate else { continue }
        if p == .openWindow || b == .openWindow {
            if case .open = VaultStore.decide(p, b) {} else { openGrantsWhenNoFuture = false }
        }
    } }
    stk("decide/open-grants-without-future", openGrantsWhenNoFuture)

    // Invariant C: indeterminate anywhere ⇒ locked.
    var indetLocks = true
    for s in all {
        if VaultStore.decide(.indeterminate, s) != .locked { indetLocks = false }
        if VaultStore.decide(s, .indeterminate) != .locked { indetLocks = false }
    }
    stk("decide/indeterminate-locks", indetLocks)

    // Spot-checks against the §11 illustrative matrix rows.
    stk("decide/future-x-expired-locked", VaultStore.decide(.futureClaimed, .expired) == .locked)
    stk("decide/expired-x-future-locked", VaultStore.decide(.expired, .futureClaimed) == .locked)
    stk("decide/expired-x-missing-reseal", VaultStore.decide(.expired, .missing) == .reseal(.primary))
    stk("decide/corrupt-x-future-sync-bak", VaultStore.decide(.corrupt, .futureClaimed) == .syncBackup(from: .backup))
    stk("decide/future-x-missing-sync-pri", VaultStore.decide(.futureClaimed, .missing) == .syncBackup(from: .primary))
    stk("decide/tampered-x-expired-reseal-bak", VaultStore.decide(.tampered, .expired) == .reseal(.backup))
    stk("decide/expired-x-expired-reseal-pri", VaultStore.decide(.expired, .expired) == .reseal(.primary))
    stk("decide/both-missing-failclosed", VaultStore.decide(.missing, .missing) == .failClosed)
    stk("decide/both-corrupt-failclosed", VaultStore.decide(.corrupt, .corrupt) == .failClosed)
    stk("decide/open-x-expired-open-pri", VaultStore.decide(.openWindow, .expired) == .open(.primary))
    stk("decide/expired-x-open-open-bak", VaultStore.decide(.expired, .openWindow) == .open(.backup))
}

// MARK: - 2. SecureFile (hardening + durable write)

private func secureFileTests() {
    let dir = tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Good file: a 0600 regular file reads back its bytes.
    let good = dir.appendingPathComponent("good.bin")
    let payload: [UInt8] = Array("hardened bytes".utf8)
    try! Data(payload).write(to: good); chmod(good.path, 0o600)
    if case .bytes(let b) = SecureFile.readHardened(good.path, cap: 1 << 20) {
        stk("secfile/read-good", b == payload)
    } else { stk("secfile/read-good", false) }

    // Missing.
    stk("secfile/read-missing", SecureFile.readHardened(dir.appendingPathComponent("nope").path, cap: 1024) == .missing)

    // Wrong mode (group/world readable) is refused.
    let loose = dir.appendingPathComponent("loose.bin")
    try! Data(payload).write(to: loose); chmod(loose.path, 0o644)
    if case .unreadable = SecureFile.readHardened(loose.path, cap: 1024) { stk("secfile/wrong-mode", true) }
    else { stk("secfile/wrong-mode", false) }

    // Symlink is refused (O_NOFOLLOW).
    let link = dir.appendingPathComponent("link.bin")
    symlink(good.path, link.path)
    if case .unreadable = SecureFile.readHardened(link.path, cap: 1024) { stk("secfile/symlink", true) }
    else { stk("secfile/symlink", false) }

    // Hard link (st_nlink == 2) is refused.
    let hard = dir.appendingPathComponent("hard.bin")
    Darwin.link(good.path, hard.path)
    if case .unreadable = SecureFile.readHardened(hard.path, cap: 1024) { stk("secfile/hardlink", true) }
    else { stk("secfile/hardlink", false) }
    unlink(hard.path)   // drop the extra link so `good` is single-link again

    // Over-cap read is refused.
    if case .unreadable = SecureFile.readHardened(good.path, cap: 4) { stk("secfile/over-cap", true) }
    else { stk("secfile/over-cap", false) }
}

// MARK: - 3. classify — each terminal state

private func classifyTests() {
    let dir = tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let R: UInt64 = 1_000_000
    let fake = FakeSeal(R: R)
    let store = VaultStore(dir: dir, client: fake, schedule: Schedule(windows: [], calendar: .current))
    let p = store.primaryURL

    func state(_ build: (URL) -> Void) -> VaultFileState {
        try? FileManager.default.removeItem(at: p)
        build(p)
        return store.classify(p, verifiedRound: R).state
    }

    stk("classify/missing", store.classify(p, verifiedRound: R).state == .missing)
    stk("classify/corrupt-garbage", state { writeGarbage($0) } == .corrupt)
    // Future: sealed to a round beyond R.
    stk("classify/future-claimed", state { writeSealed($0, window: win(R + 5000, R + 6000), target: R + 5000) } == .futureClaimed)
    // Open: start <= R <= end, sealed to start (<= R, so unsealable).
    stk("classify/open-window", state { writeSealed($0, window: win(R - 100, R + 100), target: R - 100) } == .openWindow)
    // Expired: R > end.
    stk("classify/expired", state { writeSealed($0, window: win(R - 2000, R - 1000), target: R - 2000) } == .expired)
    // Tampered: VLT1 display rounds disagree with the sealed manifest.
    stk("classify/tampered", state {
        writeSealed($0, window: win(R - 100, R + 100), target: R - 100,
                    displayOverride: win(R - 999, R + 999))
    } == .tampered)
    // Impossible: unsealable (target <= R) but manifest.start > R.
    stk("classify/impossible-corrupt", state { writeSealed($0, window: win(R + 10, R + 20), target: R) } == .corrupt)
    // Unreadable: symlink.
    stk("classify/unreadable-symlink", state { url in
        let real = dir.appendingPathComponent("real.dat")
        writeSealed(real, window: win(R - 100, R + 100), target: R - 100)
        symlink(real.path, url.path)
    } == .unreadable)
    // Indeterminate: a transient (timeout) on unseal means we could not classify.
    let timeoutStore = VaultStore(dir: dir, client: TimeoutUnseal(R: R),
                                  schedule: Schedule(windows: [], calendar: .current))
    try? FileManager.default.removeItem(at: p)
    writeSealed(p, window: win(R - 100, R + 100), target: R - 100)
    stk("classify/indeterminate-timeout", timeoutStore.classify(p, verifiedRound: R).state == .indeterminate)
}

/// A seal service whose unseal always times out (transient network failure).
private final class TimeoutUnseal: SealService {
    let R: UInt64
    init(R: UInt64) { self.R = R }
    func currentRound() -> Result<CurrentRoundInfo, HelperError> { .success(CurrentRoundInfo(round: R, expectedNow: R, unixTime: 0)) }
    func seal(payload: Data, targetRound: UInt64, verifiedLatest: UInt64) -> Result<Data, HelperError> { .failure(.timeout) }
    func unseal(sealed: Data) -> Result<Data, HelperError> { .failure(.timeout) }
}

// MARK: - 4. load() — end-to-end recovery

private func loadRecoveryTests() {
    // Deterministic clock + a verified round consistent with it, so the schedule's
    // freshness/min-lock floors and the fake's time-lock all agree.
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    var noon = DateComponents(); noon.year = 2026; noon.month = 6; noon.day = 1; noon.hour = 12
    let now = cal.date(from: noon)!
    let R = TrustedTime.expectedRound(at: now)
    let schedule = Schedule(windows: [DailyWindow(start: TimeOfDay(hour: 4, minute: 0)!,
                                                  end: TimeOfDay(hour: 5, minute: 0)!)], calendar: cal)

    func freshStore() -> (VaultStore, FakeSeal, URL) {
        let dir = tmpDir()
        let fake = FakeSeal(R: R)
        return (VaultStore(dir: dir, client: fake, schedule: schedule, clock: { now }), fake, dir)
    }
    func cleanup(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    // Offline: no verified round ⇒ .offline, no write.
    do {
        let (store, fake, dir) = freshStore(); defer { cleanup(dir) }
        fake.offline = true
        stk("load/offline", store.load().result == .offline)
    }

    // Both missing ⇒ fail closed.
    do {
        let (store, _, dir) = freshStore(); defer { cleanup(dir) }
        if case .failClosed = store.load().result { stk("load/both-missing-failclosed", true) }
        else { stk("load/both-missing-failclosed", false) }
    }

    // Open window primary ⇒ grant access with the unsealed payload.
    do {
        let (store, fake, dir) = freshStore(); defer { cleanup(dir) }
        writeSealed(store.primaryURL, window: win(R - 100, R + 100), target: R - 100)
        writeSealed(store.backupURL, window: win(R - 100, R + 100), target: R - 100)
        if case .openWindow(let w, let payload) = store.load().result {
            stk("load/open-window", w == win(R - 100, R + 100) && payload.count >= Manifest.length)
        } else { stk("load/open-window", false) }
    }

    // Honest crash state (expired primary, .bak deleted) ⇒ defensive forward
    // re-seal; afterwards BOTH copies are future-sealed and the seal was invoked.
    do {
        let (store, fake, dir) = freshStore(); defer { cleanup(dir) }
        writeSealed(store.primaryURL, window: win(R - 2000, R - 1000), target: R - 2000)
        // .bak intentionally absent
        let outcome = store.load()
        var resealed = false
        if case .resealed(let w) = outcome.result { resealed = w.startRound > R }
        stk("load/expired-missing-reseals-forward", resealed && fake.sealCalls == 1)
        // Both files now present, identical, and classified futureClaimed (no access).
        let cp = store.classify(store.primaryURL, verifiedRound: R).state
        let cb = store.classify(store.backupURL, verifiedRound: R).state
        stk("load/reseal-both-future", cp == .futureClaimed && cb == .futureClaimed)
    }

    // Honest crash state (new future primary, .bak deleted) ⇒ syncBackup restores
    // redundancy from the future primary; NO access, NO new seal.
    do {
        let (store, fake, dir) = freshStore(); defer { cleanup(dir) }
        writeSealed(store.primaryURL, window: win(R + 5000, R + 6000), target: R + 5000)
        let outcome = store.load()
        var locked = false
        if case .lockedUntil = outcome.result { locked = true }
        let cb = store.classify(store.backupURL, verifiedRound: R).state
        stk("load/future-missing-syncs-backup", locked && cb == .futureClaimed && fake.sealCalls == 0)
    }

    // Both future-claimed ⇒ locked, no access, no write.
    do {
        let (store, fake, dir) = freshStore(); defer { cleanup(dir) }
        writeSealed(store.primaryURL, window: win(R + 5000, R + 6000), target: R + 5000)
        writeSealed(store.backupURL, window: win(R + 5000, R + 6000), target: R + 5000)
        var locked = false
        if case .lockedUntil = store.load().result { locked = true }
        stk("load/both-future-locked", locked && fake.sealCalls == 0)
    }

    // Tampered primary + expired .bak ⇒ deny prompt, quarantine primary (hash
    // only), re-seal the valid .bak FORWARD.
    do {
        let (store, fake, dir) = freshStore(); defer { cleanup(dir) }
        writeSealed(store.primaryURL, window: win(R - 100, R + 100), target: R - 100,
                    displayOverride: win(R - 9, R + 9))   // outer != manifest
        writeSealed(store.backupURL, window: win(R - 2000, R - 1000), target: R - 2000)
        let outcome = store.load()
        var resealed = false
        if case .resealed(let w) = outcome.result { resealed = w.startRound > R }
        let q = outcome.quarantines.first { $0.side == .primary }
        stk("load/tampered-bak-expired-reseals", resealed && fake.sealCalls == 1)
        stk("load/tampered-quarantined", q != nil && q?.reason == "outer != manifest")
        // No-raw quarantine: the record carries a 64-hex-char SHA-256 and nothing else.
        stk("load/quarantine-hash-only", (q?.sha256Hex.count ?? 0) == 64)
    }

    // The durable write leaves both files at 0600, byte-identical.
    do {
        let (store, _, dir) = freshStore(); defer { cleanup(dir) }
        let pw01 = somePW01()
        let w = win(R + 7000, R + 8000)
        let r = store.commit(pw01: pw01, window: w, verifiedLatest: R)
        var ok = false; if case .success = r { ok = true }
        stk("load/commit-success", ok)
        let pData = try? Data(contentsOf: store.primaryURL)
        let bData = try? Data(contentsOf: store.backupURL)
        stk("load/commit-pair-identical", pData != nil && pData == bData)
        var ps = stat(); var bs = stat()
        stat(store.primaryURL.path, &ps); stat(store.backupURL.path, &bs)
        stk("load/commit-mode-0600", (ps.st_mode & 0o777) == 0o600 && (bs.st_mode & 0o777) == 0o600)
    }

    // ensureDirectory sets isExcludedFromBackup and 0700.
    do {
        let dir = tmpDir().appendingPathComponent("EncryptedVault"); defer { cleanup(dir.deletingLastPathComponent()) }
        let store = VaultStore(dir: dir, client: FakeSeal(R: R), schedule: schedule, clock: { now })
        var threw = false
        do { try store.ensureDirectory() } catch { threw = true }
        let v = try? dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        stk("load/ensure-dir-excluded", !threw && v?.isExcludedFromBackup == true)
    }

    // ---- VaultAdvisor: the DISPLAY-ONLY list advisory (mirrors decide() for display).
    // The key case is a vault sealed FORWARD: it must read CLOSED even while a recurring
    // schedule still places "now" inside a window (the "Lock now"-inside-the-window bug).
    do {
        let cur: UInt64 = 1_000_000
        func adv(_ copies: [(start: UInt64, end: UInt64)]) -> VaultAdvisory {
            VaultAdvisor.advise(copies: copies, current: cur, schedule: schedule, now: now)
        }
        stk("advisor/open-now", adv([(cur - 10, cur + 10)]).isOpenNow)
        stk("advisor/open-at-start-inclusive", adv([(cur, cur + 10)]).isOpenNow)
        stk("advisor/open-at-end-inclusive", adv([(cur - 10, cur)]).isOpenNow)
        stk("advisor/forward-sealed-closed", !adv([(cur + 100, cur + 200)]).isOpenNow,
            "sealed to the future ⇒ NOT open now (the Lock-now-in-window bug)")
        stk("advisor/forward-sealed-next-opening",
            adv([(cur + 100, cur + 200)]).nextOpening == TrustedTime.date(forRound: cur + 100),
            "closed-forward ⇒ next opening = committed start round")
        stk("advisor/future-vetoes-open",
            !adv([(cur - 10, cur + 10), (cur + 100, cur + 200)]).isOpenNow,
            "a future copy vetoes an open sibling (anti-shortening I8)")
        stk("advisor/expired-closed", !adv([(cur - 200, cur - 100)]).isOpenNow)
        stk("advisor/expired-uses-schedule-forecast",
            adv([(cur - 200, cur - 100)]).nextOpening == schedule.nextWindowOpening(after: now),
            "expired ⇒ schedule forecast (load will re-seal it forward)")
        stk("advisor/no-readable-copies-closed", !adv([]).isOpenNow,
            "unreadable/corrupt vault ⇒ closed (not openable)")
    }
}

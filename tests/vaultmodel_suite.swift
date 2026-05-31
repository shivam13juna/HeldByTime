// vaultmodel_suite.swift — offline coverage for VaultModel, the per-VAULT UI
// coordinator. VaultModel owns nothing security-critical (every lock decision is
// the engine's); it routes VaultStore/VaultSession results into @Published state.
// This suite proves that routing, with the security-relevant edges pinned:
//   * the pure reducers (load result → phase, load outcome → secret-free events),
//   * unlock routing — decode→unlocked / coarse failure / undecodable→failed,
//   * lock() — forward-only re-seal, plaintext cleared on seal, fail-closed offline,
//   * a schedule edit never changes the lock, and the re-entrancy guard.
//
// It drives the model with a FakeSeal-backed store (injected via the makeStore seam)
// so nothing touches the network — the same offline simulator store_suite/session_
// suite use. Most checks are synchronous (pure reducers, the sync lock() path, and
// the split-out applyOpenResult); the one genuinely-async path, reload(), is driven
// through a bounded run-loop pump. Only TWO real Argon2 derivations occur (the open
// path and lock(); the fail-closed paths short-circuit before any key work).

import Foundation

private func vmk(_ n: String, _ cond: Bool, _ d: String = "") { check("vaultmodel/" + n, cond, d) }
private func vmWin(_ s: UInt64, _ e: UInt64) -> Manifest.Window { Manifest.Window(startRound: s, endRound: e) }

/// Seed an OPEN-window vault on disk — a real, decryptable PW01 under a manifest,
/// time-locked via a throwaway builder seal. Same shape as session_suite's seeder.
private func seedOpen(_ store: VaultStore, window: Manifest.Window, target: UInt64,
                      password: [UInt8], notes: [UInt8]) {
    let salt = SecureRandom.bytes(VaultConstants.ARGON2_SALT_LEN)
    let nonce = SecureRandom.bytes(VaultConstants.GCM_NONCE_LEN)
    let key = try! KeyDerivation.deriveKey(password: password, salt: salt)
    let pw01 = try! PW01.seal(notes: notes, key: key, salt: salt, nonce: nonce)
    let manifest = try! Manifest.encode(window)
    let builder = FakeSeal(R: 0)
    let sealed = try! builder.seal(payload: Data(manifest + pw01), targetRound: target, verifiedLatest: 0).get()
    let vlt1 = try! VLT1.encode(VLT1.Container(displayStartRound: window.startRound,
                                               displayEndRound: window.endRound,
                                               sealedPayload: [UInt8](sealed)))
    _ = store.writeVaultPair(vlt1)
}

func runVaultModelSuite() {
    // Deterministic UTC clock + a verified round consistent with it, plus a daily
    // 04:00–05:00 window — mirrors session_suite so the fake time-lock and the
    // schedule floors agree.
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    var noon = DateComponents(); noon.year = 2026; noon.month = 6; noon.day = 1; noon.hour = 12
    let now = cal.date(from: noon)!
    let R = TrustedTime.expectedRound(at: now)
    let schedule = Schedule(windows: [DailyWindow(start: TimeOfDay(hour: 4, minute: 0)!,
                                                  end: TimeOfDay(hour: 5, minute: 0)!)], calendar: cal)
    let password = Array("correct horse battery staple".utf8)

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("vault-vm-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let env = AppEnvironment(vaultsRoot: root,
                             helperURL: root.appendingPathComponent("vaultseal"),
                             compiledHelperSHA256: [])

    func freshEntry(_ label: String = "Vault") -> VaultEntry {
        guard case .success(let e) = env.registry.create(label: label) else {
            fatalError("registry.create failed in vaultmodel test setup")
        }
        return e
    }
    // A FakeSeal store over a vault's dir (the makeStore seam's test value).
    func fakeStore(_ dir: URL, _ fake: FakeSeal) -> VaultStore {
        VaultStore(dir: dir, client: fake, schedule: schedule, clock: { now })
    }

    // ===== Pure reducers (no crypto, no async) =====

    // phase(for:) — .openWindow is the ONLY result that surfaces the password prompt.
    do {
        let win = vmWin(R + 10, R + 20); let payload = Data([1, 2, 3, 4])
        if case let .unlockPrompt(w, p) = VaultModel.phase(for: .openWindow(window: win, payload: payload),
                                                           calendar: cal, now: now) {
            vmk("reducer-open-window-prompts", w == win && p == payload,
                "open window ⇒ .unlockPrompt carrying the same window + payload")
        } else {
            vmk("reducer-open-window-prompts", false, "expected .unlockPrompt")
        }
    }

    // phase(for:) — every non-open result is .locked with the matching LockScreenInfo.
    do {
        let cases: [VaultLoadResult] = [.lockedUntil(displayStartRound: R + 5000),
                                        .resealed(window: vmWin(R + 5000, R + 5100)),
                                        .offline,
                                        .failClosed(reason: "no usable copy")]
        var ok = true
        for result in cases {
            guard case let .locked(info) = VaultModel.phase(for: result, calendar: cal, now: now),
                  info == LockScreen.describe(result, calendar: cal, now: now) else { ok = false; break }
        }
        vmk("reducer-locked-maps-to-locked", ok,
            "lockedUntil / resealed / offline / failClosed ⇒ .locked(LockScreen.describe)")
    }

    // events(for:) — each result maps to exactly one checkedVault(kind, round).
    do {
        let cases: [(VaultLoadResult, DiagnosticEvent.LoadKind, UInt64?)] = [
            (.openWindow(window: vmWin(777, 800), payload: Data()), .openWindow, 777),
            (.lockedUntil(displayStartRound: 42),                   .locked,     42),
            (.resealed(window: vmWin(999, 1000)),                   .resealed,   999),
            (.offline,                                              .offline,    nil),
            (.failClosed(reason: "x"),                              .failClosed, nil),
        ]
        var ok = true
        for (result, kind, round) in cases {
            let events = VaultModel.events(for: VaultLoadOutcome(result: result, quarantines: []))
            guard events.count == 1, case let .checkedVault(k, r) = events[0], k == kind, r == round
            else { ok = false; break }
        }
        vmk("events-checkedvault-kind-round", ok,
            "each load result maps to one checkedVault(kind, round) event")
    }

    // events(for:) — a quarantine becomes a hash-only record (side + sha256 + reason).
    do {
        let q = QuarantineRecord(side: .primary, sha256Hex: "deadbeef", reason: "outer != manifest")
        let events = VaultModel.events(for: VaultLoadOutcome(result: .failClosed(reason: "bad"),
                                                             quarantines: [q]))
        var ok = events.count == 2
        if case .checkedVault(.failClosed, nil) = events[0] {} else { ok = false }
        if case let .quarantine(side, hash, reason) = events[1] {
            ok = ok && side == "primary" && hash == "deadbeef" && reason == "outer != manifest"
        } else { ok = false }
        vmk("events-quarantine-hash-only", ok,
            "a quarantine maps to a hash-only event (side + sha256 + reason, never bytes)")
    }

    // ===== applyOpenResult (sync unlock routing; no run loop, no crypto) =====

    // A decodable open ⇒ content decoded, phase .unlocked, logged unlock(success).
    do {
        let entry = freshEntry(); let vm = VaultModel(entry: entry, env: env)
        vm.diagnosticsLog.clear()
        let want = VaultContent(notes: "top secret", secrets: [VaultSecret(label: "pw", value: "hunter2")])
        let session = VaultSession(store: fakeStore(entry.dir, FakeSeal(R: R)),
                                   password: password, openWindow: vmWin(R - 100, R + 100))
        vm.applyOpenResult(.success((notes: try! want.encode(), session: session)))
        var unlocked = false
        if case .unlocked = vm.phase { unlocked = true }
        vmk("unlock-right-password-decodes",
            unlocked && vm.content == want && vm.isUnlocking == false
              && (vm.diagnosticsLog.tail().last?.contains("unlocked") == true),
            "a decodable open ⇒ content decoded, .unlocked, logged unlock(success)")
    }

    // Wrong password ⇒ coarse: stays at the prompt, generic error, NO content built,
    // logs a coarse unlock failure (no password-vs-corrupt oracle).
    do {
        let entry = freshEntry(); let vm = VaultModel(entry: entry, env: env)
        vm.diagnosticsLog.clear()
        vm.phase = .unlockPrompt(window: vmWin(R - 100, R + 100), payload: Data([0]))
        vm.applyOpenResult(.failure(.format(.authError)))
        var stillPrompt = false
        if case .unlockPrompt = vm.phase { stillPrompt = true }
        vmk("unlock-wrong-password-coarse",
            stillPrompt && vm.content == VaultContent()
              && vm.unlockError == "Could not unlock. Check your password and try again."
              && (vm.diagnosticsLog.tail().last?.contains("unlock failed") == true),
            "wrong password ⇒ stays at prompt, generic error, no content, coarse log")
    }

    // Decrypts but the bytes aren't valid VaultContent ⇒ .failed, never partial content.
    do {
        let entry = freshEntry(); let vm = VaultModel(entry: entry, env: env)
        let session = VaultSession(store: fakeStore(entry.dir, FakeSeal(R: R)),
                                   password: password, openWindow: vmWin(R - 100, R + 100))
        vm.applyOpenResult(.success((notes: Array("{ not vault content".utf8), session: session)))
        var failed = false
        if case .failed = vm.phase { failed = true }
        vmk("unlock-undecodable-content-fails", failed && vm.content == VaultContent(),
            "decrypted-but-undecodable ⇒ .failed, never partial content")
    }

    // ===== lock() (sync re-seal; forward-only, fail-closed) =====

    // A successful Lock re-seals FORWARD and drops the plaintext from the model.
    do {
        let entry = freshEntry(); let vm = VaultModel(entry: entry, env: env)
        vm.diagnosticsLog.clear()
        let session = VaultSession(store: fakeStore(entry.dir, FakeSeal(R: R)),
                                   password: password, openWindow: vmWin(R - 100, R + 100))
        vm.phase = .unlocked(session)
        vm.content = VaultContent(notes: "edit me", secrets: [VaultSecret(label: "x", value: "y")])
        let ok = vm.lock(trigger: .lockButton)
        var locked = false
        if case .locked = vm.phase { locked = true }
        let last = vm.diagnosticsLog.tail().last ?? ""
        vmk("lock-forward-only", ok && locked && last.contains("re-sealed forward to round"),
            "Lock ⇒ true, phase .locked, logs a forward re-seal")
        vmk("lock-clears-plaintext", vm.content == VaultContent(),
            "after a successful seal the model holds NO plaintext")
    }

    // Offline ⇒ fail-closed: Lock returns false, the session STAYS open, an error
    // surfaces, a coarse re-seal-failed line is logged, and nothing is sealed.
    do {
        let entry = freshEntry(); let vm = VaultModel(entry: entry, env: env)
        vm.diagnosticsLog.clear()
        let fake = FakeSeal(R: R); fake.offline = true
        let session = VaultSession(store: fakeStore(entry.dir, fake),
                                   password: password, openWindow: vmWin(R - 100, R + 100))
        vm.phase = .unlocked(session)
        vm.content = VaultContent(notes: "keep me")
        let ok = vm.lock(trigger: .lockButton)
        var stillUnlocked = false
        if case .unlocked = vm.phase { stillUnlocked = true }
        let last = vm.diagnosticsLog.tail().last ?? ""
        vmk("lock-failclosed-stays-open",
            ok == false && stillUnlocked && (vm.unlockError?.isEmpty == false)
              && last.contains("re-seal failed") && fake.sealCalls == 0,
            "offline Lock ⇒ false, stays unlocked, error shown, coarse log, nothing sealed")
    }

    // Over-cap notes ⇒ encode() fails BEFORE any seal: false, size message, no seal.
    do {
        let entry = freshEntry(); let vm = VaultModel(entry: entry, env: env)
        let fake = FakeSeal(R: R)
        let session = VaultSession(store: fakeStore(entry.dir, fake),
                                   password: password, openWindow: vmWin(R - 100, R + 100))
        vm.phase = .unlocked(session)
        vm.content = VaultContent(notes: String(repeating: "a", count: VaultConstants.MAX_PLAINTEXT_NOTES_BYTES + 1))
        let ok = vm.lock(trigger: .lockButton)
        vmk("notes-too-large-no-seal",
            ok == false && (vm.unlockError?.contains("too large") == true) && fake.sealCalls == 0,
            "over-cap notes ⇒ lock() false with a size error and NO seal attempted")
    }

    // ===== schedule edit + re-entrancy =====

    // applySchedule persists the windows but NEVER changes the phase — a schedule
    // edit cannot grant access (load() still gates on the committed manifest).
    do {
        let entry = freshEntry(); let vm = VaultModel(entry: entry, env: env)
        vm.phase = .locked(LockScreen.describe(.offline, calendar: cal, now: now))
        let newPrefs = SchedulePrefs(windows: [WindowPrefs(startHour: 6, startMinute: 0, endHour: 7, endMinute: 0)])
        vm.applySchedule(newPrefs)
        var stillLocked = false
        if case .locked = vm.phase { stillLocked = true }
        let persisted = try? SchedulePrefs.load(from: entry.dir.appendingPathComponent("schedule.json"))
        let pw = persisted?.windows.first
        vmk("schedule-change-never-unlocks",
            stillLocked && vm.schedulePrefs == newPrefs
              && pw?.startHour == 6 && pw?.startMinute == 0 && pw?.endHour == 7 && pw?.endMinute == 0,
            "applySchedule persists the windows but leaves the phase (and the lock) untouched")
    }

    // unlock() is a no-op while one is already in flight (re-entrancy guard): it must
    // not clear the prior error or re-enter. Observable because unlock() only clears
    // unlockError AFTER passing the guard.
    do {
        let entry = freshEntry()
        let vm = VaultModel(entry: entry, env: env, makeStore: { cfg, _ in fakeStore(cfg.vaultDir, FakeSeal(R: R)) })
        vm.phase = .unlockPrompt(window: vmWin(R - 100, R + 100), payload: Data([0]))
        vm.unlockError = "previous error"
        vm.isUnlocking = true                 // pretend an unlock is mid-flight
        vm.unlock(password: "anything")       // guard !isUnlocking trips ⇒ no-op
        vmk("reentrancy-unlock-ignored",
            vm.unlockError == "previous error" && vm.isUnlocking == true,
            "unlock() while one is in flight is ignored (prior error not cleared, no re-entry)")
    }

    // ===== reload() end-to-end (the one async path; bounded run-loop pump) =====

    // A seeded open-window vault, loaded through the REAL async reload(): the load
    // resolves to .unlockPrompt and the secret-free check is logged. Proves the
    // global→main wiring drives the pure reducers, not just the reducers alone.
    do {
        let entry = freshEntry()
        let seedStore = fakeStore(entry.dir, FakeSeal(R: R))
        seedOpen(seedStore, window: vmWin(R - 100, R + 100), target: R - 100,
                 password: password, notes: try! VaultContent(notes: "n", secrets: []).encode())
        let vm = VaultModel(entry: entry, env: env, makeStore: { cfg, _ in fakeStore(cfg.vaultDir, FakeSeal(R: R)) })
        vm.diagnosticsLog.clear()
        vm.reload()
        // Pump the main run loop until reload's main-thread hop applies (bounded).
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if case .loading = vm.phase {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            } else { break }
        }
        var prompt = false
        if case .unlockPrompt = vm.phase { prompt = true }
        vmk("reload-end-to-end-open-window",
            prompt && vm.diagnosticsLog.tail().contains { $0.contains("checked vault") },
            "reload() over a seeded open vault ⇒ .unlockPrompt and a logged check")
    }
}

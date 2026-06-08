// session_suite.swift — Task 7: re-seal triggers (lifecycle).
//
// Exercises VaultSession end-to-end against the offline FakeSeal time-lock
// simulator (reused from store_suite):
//   1. open(): an open-window payload + the right password decrypts; the wrong
//      password fails closed with no plaintext.
//   2. hasWindowEnded(): the committed-end predicate the UI polls.
//   3. reseal(): the interactive engine — a FULL forward cycle (edit → re-seal →
//      the new blob is future-locked, then re-opens with the same password at the
//      new start), the anti-shortening floor, and the fail-closed paths (offline,
//      stale round, no schedule window) that must leave the on-disk blob untouched.
//
// These derive a real ~1 GiB Argon2 key on the forward paths (the fail-closed
// paths short-circuit before that), so the suite stays small and deliberate.

import Foundation
import CryptoKit

private func ssk(_ n: String, _ cond: Bool, _ d: String = "") { check("session/" + n, cond, d) }

private func sessTmpDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("vaultsess-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func sWin(_ s: UInt64, _ e: UInt64) -> Manifest.Window { Manifest.Window(startRound: s, endRound: e) }

/// Seed an OPEN-window vault on disk: a REAL PW01 (so it is decryptable) under a
/// manifest committing `window`, time-locked to `target` via a throwaway builder
/// seal (so the store's own `sealCalls` counter is untouched).
private func seedOpenVault(_ store: VaultStore, window: Manifest.Window, target: UInt64,
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

func runSessionSuite() {
    // Deterministic clock + a verified round consistent with it, mirroring the
    // store suite so the schedule floors and the fake time-lock agree.
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    var noon = DateComponents(); noon.year = 2026; noon.month = 6; noon.day = 1; noon.hour = 12
    let now = cal.date(from: noon)!
    let R = TrustedTime.expectedRound(at: now)
    let schedule = Schedule(windows: [DailyWindow(start: TimeOfDay(hour: 4, minute: 0)!,
                                                  end: TimeOfDay(hour: 5, minute: 0)!)], calendar: cal)
    let emptySchedule = Schedule(windows: [], calendar: cal)

    let password = Array("correct horse battery staple".utf8)
    let notes1 = Array("account: hunter2\nservice: swordfish".utf8)
    let notes2 = Array("account: hunter2 (rotated)\nservice: swordfish".utf8)

    func freshStore(_ sched: Schedule = schedule) -> (VaultStore, FakeSeal, URL) {
        let dir = sessTmpDir()
        let fake = FakeSeal(R: R)
        return (VaultStore(dir: dir, client: fake, schedule: sched, clock: { now }), fake, dir)
    }
    func cleanup(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    // 1. open(): right password decrypts an open-window payload; wrong fails closed.
    do {
        let (store, _, dir) = freshStore(); defer { cleanup(dir) }
        seedOpenVault(store, window: sWin(R - 100, R + 100), target: R - 100,
                      password: password, notes: notes1)
        guard case .openWindow(let w, let payload) = store.load().result else {
            ssk("open/loads-open-window", false); return
        }
        ssk("open/loads-open-window", w == sWin(R - 100, R + 100))

        switch VaultSession.open(store: store, window: w, payload: payload, password: password) {
        case .success(let (notes, _)):
            ssk("open/right-password-decrypts", notes == notes1)
        case .failure:
            ssk("open/right-password-decrypts", false)
        }

        switch VaultSession.open(store: store, window: w, payload: payload, password: Array("wrong".utf8)) {
        case .failure(.format(.authError)):
            ssk("open/wrong-password-fails-closed", true)
        default:
            ssk("open/wrong-password-fails-closed", false)
        }
    }

    // 2. hasWindowEnded(): false inside the committed end, true once past it.
    do {
        let (store, _, dir) = freshStore(); defer { cleanup(dir) }
        let session = VaultSession(store: store, password: password, openWindow: sWin(R - 100, R + 100))
        ssk("windowend/inside-false", session.hasWindowEnded(verifiedRound: R + 100) == false)
        ssk("windowend/past-true", session.hasWindowEnded(verifiedRound: R + 101) == true)
    }

    // 3. reseal(): full forward cycle. Edit notes → re-seal (window-end trigger) →
    //    the new blob is future-locked and re-opens with the same password once R
    //    reaches the new start, recovering the EDITED notes.
    do {
        let (store, fake, dir) = freshStore(); defer { cleanup(dir) }
        seedOpenVault(store, window: sWin(R - 100, R + 100), target: R - 100,
                      password: password, notes: notes1)
        let before = fake.sealCalls
        let session = VaultSession(store: store, password: password, openWindow: sWin(R - 100, R + 100))

        switch session.reseal(notes: notes2, trigger: .windowEndReached) {
        case .success(let w):
            ssk("reseal/returns-forward-window", w.startRound > R)
            // Anti-shortening floor (I8): the new lock is at least the minimum
            // duration out — a Lock can never produce a near-immediate unlock.
            ssk("reseal/respects-min-lock",
                w.startRound - R >= UInt64(VaultConstants.MIN_LOCK_DURATION_ROUNDS))
            ssk("reseal/sealed-once", fake.sealCalls == before + 1)

            // Right after the re-seal, BOTH copies are future-locked: no access.
            let cp = store.classify(store.primaryURL, verifiedRound: R).state
            let cb = store.classify(store.backupURL, verifiedRound: R).state
            ssk("reseal/both-future-locked", cp == .futureClaimed && cb == .futureClaimed)

            // Advance the verified round to the new start: it now opens, and the
            // EDITED notes come back under a freshly-derived key.
            fake.R = w.startRound
            guard case .openWindow(let w2, let payload2) = store.load().result, w2 == w else {
                ssk("reseal/reopens-at-new-start", false); return
            }
            ssk("reseal/reopens-at-new-start", true)
            switch VaultSession.open(store: store, window: w2, payload: payload2, password: password) {
            case .success(let (notes, _)):
                ssk("reseal/recovers-edited-notes", notes == notes2)
            case .failure:
                ssk("reseal/recovers-edited-notes", false)
            }
        case .failure:
            ssk("reseal/returns-forward-window", false)
        }
    }

    // 3b. Every trigger funnels through the SAME engine: offline ⇒ all fail closed,
    //     and the on-disk open-window blob is left byte-for-byte untouched (no write).
    do {
        let (store, fake, dir) = freshStore(); defer { cleanup(dir) }
        seedOpenVault(store, window: sWin(R - 100, R + 100), target: R - 100,
                      password: password, notes: notes1)
        let onDiskBefore = try! Data(contentsOf: store.primaryURL)
        let session = VaultSession(store: store, password: password, openWindow: sWin(R - 100, R + 100))
        fake.offline = true

        var allFailClosed = true
        for t in [VaultSession.Trigger.lockButton, .gracefulQuit, .windowEndReached] {
            if case .success = session.reseal(notes: notes2, trigger: t) { allFailClosed = false }
        }
        ssk("reseal/offline-all-triggers-fail", allFailClosed && fake.sealCalls == 0)
        let onDiskAfter = try? Data(contentsOf: store.primaryURL)
        ssk("reseal/offline-leaves-blob-untouched", onDiskAfter == onDiskBefore)
    }

    // 3c. A stale verified round (latest far behind the local clock) ⇒ fail closed,
    //     before any key derivation, with no write.
    do {
        let (store, fake, dir) = freshStore(); defer { cleanup(dir) }
        seedOpenVault(store, window: sWin(R - 100, R + 100), target: R - 100,
                      password: password, notes: notes1)
        let session = VaultSession(store: store, password: password, openWindow: sWin(R - 100, R + 100))
        fake.R = R - 5000   // way below expectedRound(now) - tolerance
        var staleFailed = false
        if case .failure(.helper(.staleRound)) = session.reseal(notes: notes2, trigger: .lockButton) {
            staleFailed = true
        }
        ssk("reseal/stale-round-fails-closed", staleFailed && fake.sealCalls == 0)
    }

    // 3d. No configurable window ⇒ schedule fails closed; nothing is sealed.
    do {
        let (store, fake, dir) = freshStore(emptySchedule); defer { cleanup(dir) }
        seedOpenVault(store, window: sWin(R - 100, R + 100), target: R - 100,
                      password: password, notes: notes1)
        let session = VaultSession(store: store, password: password, openWindow: sWin(R - 100, R + 100))
        var schedFailed = false
        if case .failure(.schedule(.noWindows)) = session.reseal(notes: notes2, trigger: .gracefulQuit) {
            schedFailed = true
        }
        ssk("reseal/no-window-fails-closed", schedFailed && fake.sealCalls == 0)
    }

    // 4. makeSetAsidePayload(): the DETACHED in-RAM re-lock used when leaving a vault
    //    with unsaved edits. The bytes are byte-identical to an open-window payload,
    //    so they (a) round-trip back through open() with the password and (b) seal
    //    forward PASSWORDLESSLY through defensiveReseal — the two reuse paths the app
    //    relies on (re-entry, and the at-window-end commit). No write, no network.
    do {
        let (store, fake, dir) = freshStore(); defer { cleanup(dir) }
        let win = sWin(R - 100, R + 100)
        let session = VaultSession(store: store, password: password, openWindow: win)

        guard case .success(let stash) = session.makeSetAsidePayload(notes: notes2) else {
            ssk("setaside/produces-payload", false); return
        }
        ssk("setaside/produces-payload", true)

        // Shape: manifest(openWindow) || PW01 — the first 54 bytes ARE the committed
        // window, which is why open() and defensiveReseal both consume it unchanged.
        let manifestBytes = Array([UInt8](stash)[0..<Manifest.length])
        ssk("setaside/prefixed-with-window", (try? Manifest.decode(manifestBytes)) == win)

        // Making it touched neither disk nor the time-lock network (RAM-only).
        ssk("setaside/no-disk-write", (try? Data(contentsOf: store.primaryURL)) == nil)
        ssk("setaside/no-seal-call", fake.sealCalls == 0)

        // Re-entry reuses open() verbatim: the right password recovers the EDITED notes…
        switch VaultSession.open(store: store, window: win, payload: stash, password: password) {
        case .success(let (notes, _)): ssk("setaside/reopens-with-password", notes == notes2)
        case .failure: ssk("setaside/reopens-with-password", false)
        }
        // …and a wrong password fails closed with no plaintext.
        switch VaultSession.open(store: store, window: win, payload: stash, password: Array("nope".utf8)) {
        case .failure(.format(.authError)): ssk("setaside/wrong-password-fails-closed", true)
        default: ssk("setaside/wrong-password-fails-closed", false)
        }

        // Window-end commit reuses defensiveReseal verbatim (passwordless): the stash
        // seals to a strictly FUTURE window, then re-opens there with the SAME password,
        // recovering the edits — exactly the at-expiry path, I8-clean.
        switch store.defensiveReseal(unsealedPayload: stash, verifiedLatest: R) {
        case .success(let w):
            ssk("setaside/seals-forward", w.startRound > R && fake.sealCalls == 1)
            fake.R = w.startRound
            guard case .openWindow(let w2, let payload2) = store.load().result, w2 == w else {
                ssk("setaside/forward-reopens", false); return
            }
            ssk("setaside/forward-reopens", true)
            switch VaultSession.open(store: store, window: w2, payload: payload2, password: password) {
            case .success(let (notes, _)): ssk("setaside/forward-recovers-edits", notes == notes2)
            case .failure: ssk("setaside/forward-recovers-edits", false)
            }
        case .failure:
            ssk("setaside/seals-forward", false)
        }
    }

    // 4b. Over-cap notes can't be set aside: fail-closed, no payload (and no ~1 GiB
    //     key derivation — encode rejects the size first).
    do {
        let (store, _, dir) = freshStore(); defer { cleanup(dir) }
        let session = VaultSession(store: store, password: password, openWindow: sWin(R - 100, R + 100))
        let huge = [UInt8](repeating: 0x41, count: VaultConstants.MAX_PLAINTEXT_NOTES_BYTES + 1)
        var rejected = false
        if case .failure = session.makeSetAsidePayload(notes: huge) { rejected = true }
        ssk("setaside/over-cap-fails-closed", rejected)
    }
}

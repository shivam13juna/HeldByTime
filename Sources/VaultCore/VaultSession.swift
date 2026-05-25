// VaultSession.swift — Task 7: re-seal triggers (lifecycle). app.md §6 (the two
// re-seal paths + the window-end ⚠ note), §10 steps 7/9, §11 ¶2/¶4–5, DiD #2.
//
// A VaultSession is an OPEN, in-memory vault: the user's password (held only
// while the app is unlocked) plus the COMMITTED window we opened under. It owns
// the three INTERACTIVE re-seal triggers, which all funnel into one `reseal`:
//
//   • Lock button            → reseal, stay in the app (now locked)
//   • Graceful quit (Cmd-Q)  → reseal, then exit
//   • Committed window-end   → reseal (a live session can't be force-closed by
//     reached while running     crypto; the app re-locks itself at targetEndRound)
//
// The FOURTH lifecycle event — the launch-time, NO-password defensive re-seal when
// R > end — is NOT here; it lives in VaultStore.load()/defensiveReseal (Task 6).
//
// Cardinal rules this file enforces:
//   * Interactive re-seal re-encrypts the notes with a FRESH salt + FRESH nonce
//     (FORMAT.md §7) — re-deriving the key each time — so no two saves share a
//     key+nonce (DiD #3). That is why we hold the password, not just the key.
//   * Forward-only / anti-shortening (I8): a re-seal only ever moves protection
//     forward. We seal to the NEXT schedule window, and `Schedule.nextLock`
//     already guarantees the target clears the freshness + minimum-lock floors;
//     we additionally refuse outright to commit a target that is not strictly
//     future of the verified round (belt-and-suspenders — the helper rejects it
//     too). There is no path here that produces a sooner-than-floor unlock.
//   * Fail closed: no verified round (offline) / a stale round / no valid future
//     window ⇒ NO write. The on-disk blob is left as-is; if it is past/expired the
//     launch defensive re-seal (Task 6) closes the gap on the next start.

import Foundation
import CryptoKit

struct VaultSession {
    /// Which lifecycle event drove this re-seal. Purely descriptive — every
    /// trigger takes the exact same code path, so none can be a weaker bypass.
    enum Trigger: Equatable {
        case lockButton          // user pressed Lock; stay open but locked
        case gracefulQuit        // Cmd-Q / menu quit; reseal then exit
        case windowEndReached    // committed targetEndRound passed while running
    }

    let store: VaultStore
    /// The exact password bytes the user entered (UTF-8, no normalization — see
    /// FORMAT.md §7). Retained ONLY in memory while the vault is open so each
    /// re-seal can re-derive the key under a fresh salt. (Durable-plaintext /
    /// secure-wipe hardening is Task 10; in-memory residue is root-owned, §11.)
    private let password: [UInt8]
    /// The window we opened under, read from the manifest (the authoritative
    /// source — never the mutable schedule). Drives window-end detection.
    let openWindow: Manifest.Window

    init(store: VaultStore, password: [UInt8], openWindow: Manifest.Window) {
        self.store = store
        self.password = password
        self.openWindow = openWindow
    }

    // MARK: - Open (decrypt) — bridge from VaultStore.load() to a live session

    /// Turn an open-window load result + the user's password into the decrypted
    /// notes and a live session. The key is re-derived from the salt stored in the
    /// PW01 header. Fail-closed: a wrong password yields `.authError` with no
    /// partial plaintext (CryptoKit verifies the GCM tag before returning bytes).
    static func open(store: VaultStore, window: Manifest.Window, payload: Data,
                     password: [UInt8]) -> Result<(notes: [UInt8], session: VaultSession), StoreError> {
        let bytes = [UInt8](payload)
        guard bytes.count > Manifest.length else {
            return .failure(.format(.parseError("payload too short for PW01")))
        }
        let pw01 = Array(bytes[Manifest.length...])   // manifest(54) || PW01
        do {
            let salt = try PW01.salt(from: pw01)
            let key = try KeyDerivation.deriveKey(password: password, salt: salt)
            let notes = try PW01.open(pw01, key: key)
            let session = VaultSession(store: store, password: password, openWindow: window)
            return .success((notes, session))
        } catch let e as VaultFormatError {
            return .failure(.format(e))
        } catch {
            return .failure(.format(.invariantViolation("\(error)")))
        }
    }

    // MARK: - Window-end detection

    /// True once the verified round has passed the COMMITTED end (the manifest,
    /// not the schedule). The UI polls this while open; when it flips, fire
    /// `reseal(notes:trigger: .windowEndReached)` to re-lock the live session.
    func hasWindowEnded(verifiedRound R: UInt64) -> Bool {
        R > openWindow.endRound
    }

    // MARK: - Interactive re-seal (the engine all three triggers call)

    /// Re-encrypt `notes` under a fresh salt+nonce and time-lock them to the NEXT
    /// schedule window, durably writing both files. Returns the committed window
    /// on success. Fail-closed and forward-only throughout.
    ///
    /// Order is deliberately fail-fast-before-expensive: the verified round and
    /// the forward window are resolved BEFORE the ~1 GiB Argon2 derivation, so an
    /// offline / stale / no-window failure costs nothing.
    func reseal(notes: [UInt8], trigger: Trigger) -> Result<Manifest.Window, StoreError> {
        // 1. A drand-verified round is mandatory (same gate as load()). Offline or
        //    a suspiciously-old "latest" ⇒ no write.
        let R: UInt64
        switch store.client.currentRound() {
        case .failure(let e):
            return .failure(.helper(e))
        case .success(let info):
            if TrustedTime.isStale(verifiedLatest: info.round, now: store.clock()) {
                return .failure(.helper(.staleRound))
            }
            R = info.round
        }

        // 2. The NEXT lock target. nextLock enforces the freshness + minimum-lock
        //    floors, so it can only return a genuinely future, non-trivial window.
        let decision: ScheduleDecision
        switch store.schedule.nextLock(now: store.clock(), verifiedLatest: R) {
        case .failure(let e):
            return .failure(.schedule(e))
        case .success(let d):
            decision = d
        }

        // 3. Forward-only / anti-shortening (I8): refuse to commit a target that is
        //    not strictly future of the verified round. nextLock already guarantees
        //    this; the check makes the invariant explicit and unmissable.
        guard decision.window.startRound > R else {
            return .failure(.verifyFailed("reseal target \(decision.window.startRound) not future of \(R)"))
        }

        // 4. Build a FRESH PW01: new salt + new nonce, key re-derived (FORMAT.md §7).
        let salt = SecureRandom.bytes(VaultConstants.ARGON2_SALT_LEN)
        let nonce = SecureRandom.bytes(VaultConstants.GCM_NONCE_LEN)
        let pw01: [UInt8]
        do {
            let key = try KeyDerivation.deriveKey(password: password, salt: salt)
            pw01 = try PW01.seal(notes: notes, key: key, salt: salt, nonce: nonce)
        } catch let e as VaultFormatError {
            return .failure(.format(e))
        } catch {
            return .failure(.format(.invariantViolation("\(error)")))
        }

        // 5. Seal to the start round, frame, and durably write both files (Task 6).
        return store.commit(pw01: pw01, window: decision.window, verifiedLatest: R)
            .map { decision.window }
    }
}

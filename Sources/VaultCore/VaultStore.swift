// VaultStore.swift — Task 6: the vault store. THE DANGEROUS TASK (app.md §6,
// §10 steps 8–9, §11 recovery decision matrix, SECURITY_INVARIANTS I3/I8/I12).
//
// Built in the small passes §10 step 8 demands:
//   (a) read+validate one file        -> SecureFile.readHardened (path/inode hardening)
//   (b) classify ONE file's state     -> classify(_:verifiedRound:) -> VaultFileState
//   (c) compare primary vs .bak       -> two classifications
//   (d) total decision, NO `default`  -> decide(_:_:) over the 8×8 matrix
//   (e) the write transaction         -> commit / writeVaultPair (durable, §6 order)
//   (f) defensive (passwordless) re-seal on top
//
// The cardinal rules this file enforces:
//   * Unseal IS the gate (I-unseal-as-gate): a future round stays cryptographically
//     locked; we never trust the plaintext VLT1 display rounds for access.
//   * The manifest (read only after a successful unseal) is the SOLE authorization
//     source for the window — never the mutable schedule.
//   * Fail closed: any uncertainty (offline, can't classify, both copies bad) ⇒
//     no access, no risky write.
//   * No-raw-quarantine: a tampered/corrupt copy yields only a HASH + diagnostic,
//     never its (possibly now-decryptable) bytes.
//   * Defensive re-seal is PASSWORDLESS: it reuses the existing PW01 bytes verbatim
//     and only moves the committed interval FORWARD (I8 anti-shortening).

import Foundation
import CryptoKit
import Darwin

// MARK: - Seal service boundary (injectable for tests)

/// The three helper operations the store needs. `VaultSealClient` is the
/// production conformer (over the hardened subprocess); tests inject a fake so
/// the store's classification/recovery logic can be exercised offline.
protocol SealService {
    func currentRound() -> Result<CurrentRoundInfo, HelperError>
    func seal(payload: Data, targetRound: UInt64, verifiedLatest: UInt64) -> Result<Data, HelperError>
    func unseal(sealed: Data) -> Result<Data, HelperError>
}

extension VaultSealClient: SealService {}

// MARK: - Closed store error domain

enum StoreError: Error, Equatable {
    case io(String)                  // filesystem / durability failure
    case helper(HelperError)         // a helper-boundary failure during seal
    case format(VaultFormatError)    // a manifest/VLT1 encode/decode failure
    case schedule(ScheduleError)     // could not compute a forward window
    case verifyFailed(String)        // post-write byte-equality / mode re-check failed
}

// MARK: - Classified state (the matrix axis)

/// The terminal classification of ONE on-disk copy, given a verified round R.
/// Deliberately a plain tag (no associated values) so the primary×`.bak`
/// decision matrix can be a total switch the compiler checks (no `default`).
/// `future-valid-after-ready` from the spec text is not a distinct terminal
/// state: a future seal is unreadable (so unverifiable — `futureClaimed`), and
/// once its round is ready it resolves to `openWindow` or `expired`.
enum VaultFileState: CaseIterable, Equatable {
    case missing         // no file
    case unreadable      // bad owner / mode / symlink / hardlink / IO (path-inode hardening)
    case corrupt         // VLT1 won't parse, OR forged/garbage outer, OR manifest won't decode,
                         //   OR an impossible round (unsealed but R < manifest.start)
    case tampered        // unsealed + manifest decoded, but VLT1 display != manifest (outer≠manifest)
    case futureClaimed   // unseal -> round_not_ready: sealed to a FUTURE round, UNTRUSTED (not "valid")
    case openWindow      // unsealed, outer==manifest, manifest.start <= R <= manifest.end
    case expired         // unsealed, outer==manifest, R > manifest.end (recoverable, must move forward)
    case indeterminate   // offline / transient helper failure: we could not classify -> fail closed
}

enum CopySource: Equatable { case primary, backup }

/// The fail-closed action chosen for a (primary, `.bak`) pair.
enum VaultAction: Equatable {
    case open(CopySource)             // open window: prompt password, decrypt this copy
    case reseal(CopySource)           // passwordless forward re-seal of this valid expired copy (writes BOTH)
    case syncBackup(from: CopySource) // copy the trusted copy over the other file; grants NO access
    case locked                       // a future/ambiguous commitment is active: no access, no write
    case failClosed                   // nothing usable: no access, no write
}

// MARK: - Results

/// A hash-only quarantine record. By construction it can hold ONLY a digest and
/// diagnostic text — never the raw (possibly decryptable) bytes — which is the
/// no-raw-quarantine invariant expressed at the type level (§11 DiD #6).
struct QuarantineRecord: Equatable {
    let side: CopySource
    let sha256Hex: String
    let reason: String
}

enum VaultLoadResult: Equatable {
    case openWindow(window: Manifest.Window, payload: Data)  // UI: prompt, then PW01.open(payload[54...])
    case lockedUntil(displayStartRound: UInt64?)             // locked screen (round is an untrusted hint)
    case resealed(window: Manifest.Window)                   // moved forward defensively; now locked
    case failClosed(reason: String)                          // unreadable/corrupt: no access
    case offline                                             // could not obtain a verified round
}

struct VaultLoadOutcome: Equatable {
    let result: VaultLoadResult
    let quarantines: [QuarantineRecord]
}

// MARK: - The store

struct VaultStore {
    let dir: URL
    let client: SealService
    let schedule: Schedule
    /// Injectable clock — defaults to the wall clock, fixed in tests for
    /// deterministic schedule arithmetic.
    let clock: () -> Date

    init(dir: URL, client: SealService, schedule: Schedule, clock: @escaping () -> Date = { Date() }) {
        self.dir = dir
        self.client = client
        self.schedule = schedule
        self.clock = clock
    }

    var primaryURL: URL { dir.appendingPathComponent("vault.dat") }
    var backupURL: URL { dir.appendingPathComponent("vault.dat.bak") }

    /// Read ceiling: a full VLT1 file is at most a 30-byte header wrapping the
    /// 2 MiB sealed-payload cap, plus slack.
    private var readCap: Int { VaultConstants.MAX_SEALED_PAYLOAD_BYTES + 4096 }

    // MARK: - Directory setup (excluded from OS backups; 0700)

    /// Create the vault directory (0700) if absent and set+verify
    /// `isExcludedFromBackup` (Time Machine + iCloud) — an automatic OS backup of
    /// an expired vault is an escape hatch (§9, §11).
    func ensureDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        try Self.excludeFromBackup(dir)
    }

    /// Set+verify `isExcludedFromBackup` on an existing directory (Time Machine +
    /// iCloud). Fail-closed: we set the flag, drop Foundation's cached resource
    /// values, re-read, and throw if it did not stick — a vault dir that cannot be
    /// kept out of OS backups must never be treated as protected. Extracted from
    /// `ensureDirectory()` so vault import can re-apply the same guarantee to a
    /// freshly reconstituted directory.
    static func excludeFromBackup(_ dir: URL) throws {
        var u = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try u.setResourceValues(values)
        u.removeAllCachedResourceValues()
        let got = try u.resourceValues(forKeys: [.isExcludedFromBackupKey])
        guard got.isExcludedFromBackup == true else {
            throw StoreError.io("isExcludedFromBackup not set")
        }
    }

    // MARK: - (b) classify ONE file

    /// The data classify carries forward for the action executor.
    struct Classified {
        let state: VaultFileState
        var window: Manifest.Window? = nil   // for open/expired
        var unsealedPayload: Data? = nil     // manifest||PW01, for defensive re-seal
        var rawBytes: [UInt8]? = nil         // on-disk VLT1 bytes, for syncBackup + quarantine hash
        var displayStart: UInt64? = nil      // untrusted VLT1 hint for the locked screen
    }

    func classify(_ url: URL, verifiedRound R: UInt64) -> Classified {
        switch SecureFile.readHardened(url.path, cap: readCap) {
        case .missing:
            return Classified(state: .missing)
        case .unreadable:
            return Classified(state: .unreadable)
        case .bytes(let raw):
            // Plaintext outer framing. A parse failure is corruption, not access.
            guard let container = try? VLT1.decode(raw) else {
                return Classified(state: .corrupt, rawBytes: raw)
            }
            // Unseal is the authoritative gate.
            switch client.unseal(sealed: Data(container.sealedPayload)) {
            case .failure(let e):
                switch e {
                case .roundNotReady:
                    // Sealed to a future round: cannot read the manifest, so UNTRUSTED.
                    return Classified(state: .futureClaimed, rawBytes: raw,
                                      displayStart: container.displayStartRound)
                case .authFailed, .parseError:
                    // Forged/garbage outer ciphertext: corrupt, fail closed.
                    return Classified(state: .corrupt, rawBytes: raw)
                case .timeout, .chainMismatch, .staleRound, .roundTooNear, .failClosed:
                    // Offline / config / transient: we genuinely could not classify.
                    return Classified(state: .indeterminate, rawBytes: raw,
                                      displayStart: container.displayStartRound)
                }
            case .success(let payload):
                let bytes = [UInt8](payload)
                guard bytes.count >= Manifest.length,
                      let window = try? Manifest.decode(Array(bytes[0..<Manifest.length])) else {
                    return Classified(state: .corrupt, rawBytes: raw)
                }
                // outer == manifest (only checkable now that we have unsealed).
                guard container.displayStartRound == window.startRound,
                      container.displayEndRound == window.endRound else {
                    return Classified(state: .tampered, rawBytes: raw)
                }
                if R < window.startRound {
                    // Unsealed yet R is before the committed start: an impossible
                    // (tampered) round relationship. Fail closed.
                    return Classified(state: .corrupt, rawBytes: raw)
                } else if R <= window.endRound {
                    return Classified(state: .openWindow, window: window, unsealedPayload: payload,
                                      rawBytes: raw, displayStart: window.startRound)
                } else {
                    return Classified(state: .expired, window: window, unsealedPayload: payload,
                                      rawBytes: raw, displayStart: window.startRound)
                }
            }
        }
    }

    // MARK: - (d) the total decision function (NO default)

    /// Choose the fail-closed action for a (primary, `.bak`) state pair. This is a
    /// total switch: the Swift compiler proves every one of the 8×8 combinations
    /// is handled — an unhandled pair fails to COMPILE rather than silently
    /// allowing access (§11). The illustrative matrix in §11 is a subset of this.
    ///
    /// Governing principles (§6, §11 ¶6):
    ///   * Indeterminate anywhere ⇒ locked (we could not verify — fail closed).
    ///   * An openWindow copy grants access — but ONLY if NO futureClaimed copy
    ///     exists (a forward commitment vetoes access; anti-shortening, I8).
    ///   * A futureClaimed copy present ⇒ never grant access. Rebuild a
    ///     missing/corrupt/unreadable sibling FROM it (restore redundancy); when
    ///     it coexists with a recoverable expired/tampered copy the state is
    ///     dishonest (the delete-old-.bak-first write order can't produce it), so
    ///     leave both untouched rather than risk clobbering — just lock.
    ///   * No open, no future, a VALID expired copy ⇒ re-seal it FORWARD (closes
    ///     the password-only escape hatch). futureClaimed is NOT "valid".
    ///   * Nothing recoverable ⇒ fail closed.
    static func decide(_ p: VaultFileState, _ b: VaultFileState) -> VaultAction {
        switch (p, b) {
        // 1. Could not classify a copy: fail closed.
        case (.indeterminate, _), (_, .indeterminate):
            return .locked

        // 2. Open window grants access — unless a future commitment vetoes it.
        case (.openWindow, .futureClaimed), (.futureClaimed, .openWindow):
            return .locked
        case (.openWindow, _):
            return .open(.primary)
        case (_, .openWindow):
            return .open(.backup)

        // 3. A future commitment is present (no open copy now): never grant access.
        //    Restore redundancy from the future copy when the sibling carries no
        //    recoverable content; otherwise (dishonest pairing) leave both alone.
        case (.futureClaimed, .missing), (.futureClaimed, .corrupt), (.futureClaimed, .unreadable):
            return .syncBackup(from: .primary)
        case (.missing, .futureClaimed), (.corrupt, .futureClaimed), (.unreadable, .futureClaimed):
            return .syncBackup(from: .backup)
        case (.futureClaimed, .futureClaimed),
             (.futureClaimed, .expired), (.expired, .futureClaimed),
             (.futureClaimed, .tampered), (.tampered, .futureClaimed):
            return .locked

        // 4. No open, no future: re-seal a valid expired copy FORWARD.
        case (.expired, _):
            return .reseal(.primary)
        case (_, .expired):
            return .reseal(.backup)

        // 5. Nothing recoverable: fail closed.
        case (.missing, .missing), (.missing, .corrupt), (.missing, .tampered), (.missing, .unreadable),
             (.corrupt, .missing), (.corrupt, .corrupt), (.corrupt, .tampered), (.corrupt, .unreadable),
             (.tampered, .missing), (.tampered, .corrupt), (.tampered, .tampered), (.tampered, .unreadable),
             (.unreadable, .missing), (.unreadable, .corrupt), (.unreadable, .tampered), (.unreadable, .unreadable):
            return .failClosed
        }
    }

    // MARK: - load orchestration

    func load() -> VaultLoadOutcome {
        // Verified round is mandatory. No round ⇒ offline ⇒ locked, no prompt,
        // no rewrap (§6).
        let info: CurrentRoundInfo
        switch client.currentRound() {
        case .failure:
            return VaultLoadOutcome(result: .offline, quarantines: [])
        case .success(let i):
            info = i
        }
        // A suspiciously-old "latest" vs the local clock is fail-closed: deny.
        if TrustedTime.isStale(verifiedLatest: info.round, now: clock()) {
            return VaultLoadOutcome(result: .offline, quarantines: [])
        }
        let R = info.round

        let cp = classify(primaryURL, verifiedRound: R)
        let cb = classify(backupURL, verifiedRound: R)

        var quarantines: [QuarantineRecord] = []
        appendQuarantine(&quarantines, side: .primary, cp)
        appendQuarantine(&quarantines, side: .backup, cb)

        func chosen(_ src: CopySource) -> Classified { src == .primary ? cp : cb }

        switch Self.decide(cp.state, cb.state) {
        case .open(let src):
            let c = chosen(src)
            guard let window = c.window, let payload = c.unsealedPayload else {
                return VaultLoadOutcome(result: .failClosed(reason: "open without payload"),
                                        quarantines: quarantines)
            }
            return VaultLoadOutcome(result: .openWindow(window: window, payload: payload),
                                    quarantines: quarantines)

        case .reseal(let src):
            let c = chosen(src)
            guard let payload = c.unsealedPayload else {
                return VaultLoadOutcome(result: .failClosed(reason: "reseal without payload"),
                                        quarantines: quarantines)
            }
            switch defensiveReseal(unsealedPayload: payload, verifiedLatest: R) {
            case .success(let w):
                return VaultLoadOutcome(result: .resealed(window: w), quarantines: quarantines)
            case .failure(let e):
                return VaultLoadOutcome(result: .failClosed(reason: "reseal failed: \(e)"),
                                        quarantines: quarantines)
            }

        case .syncBackup(let src):
            let c = chosen(src)
            guard let raw = c.rawBytes else {
                return VaultLoadOutcome(result: .failClosed(reason: "sync without bytes"),
                                        quarantines: quarantines)
            }
            switch writeVaultPair(raw) {
            case .success:
                return VaultLoadOutcome(result: .lockedUntil(displayStartRound: c.displayStart),
                                        quarantines: quarantines)
            case .failure(let e):
                return VaultLoadOutcome(result: .failClosed(reason: "sync failed: \(e)"),
                                        quarantines: quarantines)
            }

        case .locked:
            let hint = cp.displayStart ?? cb.displayStart
            return VaultLoadOutcome(result: .lockedUntil(displayStartRound: hint), quarantines: quarantines)

        case .failClosed:
            return VaultLoadOutcome(result: .failClosed(reason: "no usable vault copy"),
                                    quarantines: quarantines)
        }
    }

    // MARK: - (f) defensive (passwordless) re-seal + the seal/write primitive

    /// Re-seal a recovered (expired) payload FORWARD without the password: reuse
    /// the existing PW01 bytes verbatim (AES plaintext untouched) under a manifest
    /// committing the NEXT schedule window, then durably write both files.
    func defensiveReseal(unsealedPayload: Data, verifiedLatest R: UInt64) -> Result<Manifest.Window, StoreError> {
        let bytes = [UInt8](unsealedPayload)
        guard bytes.count >= Manifest.length else {
            return .failure(.format(.parseError("unsealed payload too short")))
        }
        let pw01 = Array(bytes[Manifest.length...])   // reused verbatim — never decrypted

        let decision: ScheduleDecision
        switch schedule.nextLock(now: clock(), verifiedLatest: R) {
        case .failure(let e): return .failure(.schedule(e))
        case .success(let d): decision = d
        }
        return commit(pw01: pw01, window: decision.window, verifiedLatest: R).map { decision.window }
    }

    /// Seal a `manifest(window) || pw01` payload to `window.startRound`, frame it
    /// as VLT1, and durably write both files. Shared by defensive re-seal here and
    /// by the (Task 7) interactive re-seal, which supplies a freshly AES-sealed
    /// PW01 from the in-memory notes.
    func commit(pw01: [UInt8], window: Manifest.Window, verifiedLatest R: UInt64) -> Result<Void, StoreError> {
        let manifest: [UInt8]
        do { manifest = try Manifest.encode(window) }
        catch let e as VaultFormatError { return .failure(.format(e)) }
        catch { return .failure(.format(.invariantViolation("\(error)"))) }

        let sealed: Data
        switch client.seal(payload: Data(manifest + pw01),
                           targetRound: window.startRound, verifiedLatest: R) {
        case .failure(let e): return .failure(.helper(e))
        case .success(let s): sealed = s
        }

        let vlt1: [UInt8]
        do {
            vlt1 = try VLT1.encode(VLT1.Container(displayStartRound: window.startRound,
                                                  displayEndRound: window.endRound,
                                                  sealedPayload: [UInt8](sealed)))
        }
        catch let e as VaultFormatError { return .failure(.format(e)) }
        catch { return .failure(.format(.invariantViolation("\(error)"))) }

        return writeVaultPair(vlt1)
    }

    // MARK: - (e) the durable write transaction

    /// Write identical bytes to vault.dat and vault.dat.bak in the exact
    /// escape-hatch-free order (§6, §9), then verify. A crash mid-sequence may
    /// lose redundancy but never leaves an expired (password-only) `.bak` beside
    /// a future-sealed primary, and never a partial `.bak`.
    func writeVaultPair(_ vlt1Bytes: [UInt8]) -> Result<Void, StoreError> {
        let dirPath = dir.path
        let primary = primaryURL.path
        let backup = backupURL.path
        let primaryTmp = dir.appendingPathComponent("vault.dat.tmp").path
        let backupTmp = dir.appendingPathComponent("vault.dat.bak.tmp").path
        do {
            try SecureFile.writeTempDurable(primaryTmp, vlt1Bytes)            // 1
            try SecureFile.removeDurable(backup, dirPath: dirPath)            // 2 delete old .bak FIRST
            try SecureFile.renameDurable(from: primaryTmp, to: primary,      // 3
                                         dirPath: dirPath, fsyncFile: true)
            try SecureFile.writeTempDurable(backupTmp, vlt1Bytes)            // 4
            try SecureFile.renameDurable(from: backupTmp, to: backup,        // 5
                                         dirPath: dirPath, fsyncFile: false)
        } catch let e as SecureFileError {
            if case .io(let m) = e { return .failure(.io(m)) }
            return .failure(.io("\(e)"))
        } catch {
            return .failure(.io("\(error)"))
        }
        if let v = verifyPair(expected: vlt1Bytes) { return .failure(v) }    // 6
        return .success(())
    }

    /// Post-write: re-read both files through the same hardening and confirm the
    /// byte-equality invariant + 0600/owner/non-symlink/single-link — so the
    /// writer never leaves an ambiguous state for recovery to untangle later.
    private func verifyPair(expected: [UInt8]) -> StoreError? {
        for url in [primaryURL, backupURL] {
            switch SecureFile.readHardened(url.path, cap: readCap) {
            case .bytes(let b):
                if b != expected { return .verifyFailed("byte mismatch at \(url.lastPathComponent)") }
            case .missing:
                return .verifyFailed("\(url.lastPathComponent) missing after write")
            case .unreadable(let why):
                return .verifyFailed("\(url.lastPathComponent): \(why)")
            }
        }
        return nil
    }

    // MARK: - quarantine (hash-only)

    private func appendQuarantine(_ out: inout [QuarantineRecord], side: CopySource, _ c: Classified) {
        guard c.state == .tampered || c.state == .corrupt, let raw = c.rawBytes else { return }
        let sha = Hex.encode(Array(SHA256.hash(data: Data(raw))))
        out.append(QuarantineRecord(side: side, sha256Hex: sha,
                                    reason: c.state == .tampered ? "outer != manifest" : "unparseable/forged"))
    }
}

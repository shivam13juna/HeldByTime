// argon2_suite.swift — Task 2b: Argon2id correctness, production KDF, end-to-end.
//
// Correctness is anchored by two Argon2id vectors generated with OpenSSL 3.6.1's
// independent ARGON2ID implementation (a different codebase from the vendored
// phc reference), so agreement is genuine cross-validation:
//   pass="password" salt="somesalt" t=3 m=8192 out=32
//     p=4 -> 95fa07340ba8003501e2d4748cd5ad71666e2fc02071e3be9818da7ec62a717c
//     p=1 -> c1bc4d00af5ae21bebc081ad618694850511146225d8d3a070ed95b983b8d474

import Foundation
import CryptoKit

func runArgon2Suite() {
    func ck(_ n: String, _ cond: Bool, _ d: String = "") { check("argon2/" + n, cond, d) }
    func et(_ n: String, _ t: String, _ b: () throws -> Void) { expectThrow("argon2/" + n, t, b) }

    let pwd = Array("password".utf8)
    let salt8 = Array("somesalt".utf8)

    // Cross-check against the independent OpenSSL oracle (no secret/ad).
    do {
        let k4 = try Argon2.raw(t: 3, mKiB: 8192, p: 4, version: 19, password: pwd, salt: salt8, outLen: 32)
        ck("openssl-kat-p4", Hex.encode(k4) == "95fa07340ba8003501e2d4748cd5ad71666e2fc02071e3be9818da7ec62a717c", Hex.encode(k4))
        let k1 = try Argon2.raw(t: 3, mKiB: 8192, p: 1, version: 19, password: pwd, salt: salt8, outLen: 32)
        ck("openssl-kat-p1", Hex.encode(k1) == "c1bc4d00af5ae21bebc081ad618694850511146225d8d3a070ed95b983b8d474", Hex.encode(k1))
    } catch { fail("argon2/kat-setup", "\(error)") }

    // Production deriveKey at the frozen 1 GiB params: determinism, salt sensitivity, benchmark.
    do {
        let p = Array("correct horse battery staple".utf8)
        let s = (0..<16).map { UInt8($0) }
        let t0 = Date()
        let key = try KeyDerivation.deriveKey(password: p, salt: s)
        let dt = Date().timeIntervalSince(t0)
        ck("derivekey-len", key.bitCount == 256)
        ck("derivekey-deterministic", key == (try KeyDerivation.deriveKey(password: p, salt: s)))
        let s2 = (0..<16).map { UInt8($0 + 1) }
        ck("derivekey-salt-sensitive", key != (try KeyDerivation.deriveKey(password: p, salt: s2)))
        ck("benchmark-1GiB-completes", dt < 30.0, String(format: "%.3fs", dt))
        info("argon2/benchmark-1GiB", String(format: "%.3fs for 1 GiB t=3 p=4 on this machine", dt))
    } catch { fail("argon2/derivekey-setup", "\(error)") }

    et("reject-empty-password", "invariantViolation") {
        _ = try KeyDerivation.deriveKey(password: [], salt: (0..<16).map { UInt8($0) })
    }

    // End-to-end: password -> Argon2id key -> PW01 seal/open, and wrong password fails closed.
    do {
        let p = Array("a strong passphrase 123".utf8)
        let s = (0..<16).map { UInt8(0x10 + $0) }
        let nonce = (0..<12).map { UInt8(0x20 + $0) }
        let key = try KeyDerivation.deriveKey(password: p, salt: s)
        let notes = Array("end to end secret".utf8)
        let container = try PW01.seal(notes: notes, key: key, salt: s, nonce: nonce)
        ck("e2e-roundtrip", try PW01.open(container, key: key) == notes)
        let wrongKey = try KeyDerivation.deriveKey(password: Array("WRONG passphrase 123".utf8), salt: s)
        et("e2e-wrong-password", "authError") { _ = try PW01.open(container, key: wrongKey) }
    } catch { fail("argon2/e2e-setup", "\(error)") }
}

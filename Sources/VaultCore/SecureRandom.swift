// SecureRandom.swift — the one source of fresh salts and nonces.
//
// FORMAT.md §7: "Salt and nonce: drawn from the system CSPRNG, fresh for every
// encryption; never reused across saves." Every interactive re-seal (VaultSession)
// draws a new salt + nonce here, so no two saves share a key+nonce pair (reusing
// one under AES-GCM is fatal — SECURITY_INVARIANTS DiD #3).
//
// We draw from `SystemRandomNumberGenerator`, which on Apple platforms is the
// system CSPRNG (arc4random) and is documented as safe for cryptographic use. It
// needs no extra framework and works for any byte count — unlike CryptoKit's
// `SymmetricKeySize(bitCount:)`, which only accepts standard key sizes.

import Foundation

enum SecureRandom {
    /// `count` bytes from the system CSPRNG.
    static func bytes(_ count: Int) -> [UInt8] {
        precondition(count > 0, "SecureRandom.bytes(\(count)): need a positive count")
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
    }
}

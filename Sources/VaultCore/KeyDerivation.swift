// KeyDerivation.swift — production password → AES-256 key (frozen Argon2id params).
//
// This is the only production caller of Argon2. It pins t/m/p/version/outLen to
// the frozen constants (FORMAT.md §7, SECURITY_INVARIANTS.md I10). The password
// is the caller's exact UTF-8 bytes (no trim/normalize — FORMAT.md §7); the salt
// is the 16-byte CSPRNG value stored in the PW01 header.

import Foundation
import CryptoKit

enum KeyDerivation {
    static func deriveKey(password: [UInt8], salt: [UInt8]) throws -> SymmetricKey {
        guard !password.isEmpty else {
            throw VaultFormatError.invariantViolation("empty password")
        }
        guard password.count <= VaultConstants.MAX_PASSWORD_BYTES else {
            throw VaultFormatError.sizeLimit("password \(password.count)")
        }
        guard salt.count == VaultConstants.ARGON2_SALT_LEN else {
            throw VaultFormatError.invariantViolation("salt len \(salt.count)")
        }
        let keyBytes = try Argon2.raw(
            t: UInt32(VaultConstants.ARGON2_T),
            mKiB: UInt32(VaultConstants.ARGON2_M_KIB),
            p: UInt32(VaultConstants.ARGON2_P),
            version: UInt32(VaultConstants.ARGON2_VERSION),
            password: password,
            salt: salt,
            outLen: VaultConstants.ARGON2_OUTPUT_LEN
        )
        return SymmetricKey(data: Data(keyBytes))
    }
}

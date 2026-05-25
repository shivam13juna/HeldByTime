// PW01.swift — inner AES-256-GCM container for the notes (FORMAT.md §5).
//
// Layout (header = first 47 bytes, which is also the AES-GCM AAD):
//   magic "PW01" | version | kdf_id | m_kib u32 | t u32 | p u32 |
//   argon2_version u8 | salt[16] | nonce[12] | ciphertext+tag
//
// The stored Argon2 params are self-describing but PINNED: any header whose
// params differ from the frozen constants is rejected (no negotiation, no
// downgrade — SECURITY_INVARIANTS.md I10). The key is supplied by the caller
// (it comes from Argon2id over the password in 2b); this file does not derive it.

import Foundation
import CryptoKit

enum PW01 {
    static let headerLen = 47
    static let kdfArgon2id: UInt8 = 1

    static func seal(notes: [UInt8], key: SymmetricKey, salt: [UInt8], nonce: [UInt8]) throws -> [UInt8] {
        guard notes.count <= VaultConstants.MAX_PLAINTEXT_NOTES_BYTES else {
            throw VaultFormatError.sizeLimit("notes \(notes.count)")
        }
        guard salt.count == VaultConstants.ARGON2_SALT_LEN else {
            throw VaultFormatError.invariantViolation("salt len \(salt.count)")
        }
        guard nonce.count == VaultConstants.GCM_NONCE_LEN else {
            throw VaultFormatError.invariantViolation("nonce len \(nonce.count)")
        }
        guard key.bitCount == VaultConstants.AES_KEY_LEN * 8 else {
            throw VaultFormatError.invariantViolation("key bits \(key.bitCount)")
        }

        var w = ByteWriter()
        w.ascii(VaultConstants.PW01_MAGIC)
        w.u8(UInt8(VaultConstants.PW01_VERSION))
        w.u8(kdfArgon2id)
        w.u32le(UInt32(VaultConstants.ARGON2_M_KIB))
        w.u32le(UInt32(VaultConstants.ARGON2_T))
        w.u32le(UInt32(VaultConstants.ARGON2_P))
        w.u8(UInt8(VaultConstants.ARGON2_VERSION))
        w.raw(salt)
        w.raw(nonce)
        let header = w.bytes
        precondition(header.count == headerLen, "PW01 header must be \(headerLen) bytes")

        let box = try AES.GCM.seal(
            Data(notes),
            using: key,
            nonce: try AES.GCM.Nonce(data: Data(nonce)),
            authenticating: Data(header)
        )
        return header + Array(box.ciphertext) + Array(box.tag)
    }

    /// The 16-byte Argon2 salt recorded in the header — needed to RE-derive the
    /// key from the password (PW01 itself never derives). Keeps the header-offset
    /// arithmetic in one place: magic(4)|version(1)|kdf(1)|m(4)|t(4)|p(4)|argon2v(1)
    /// = 19 bytes before the salt.
    static let saltOffset = 19
    static func salt(from container: [UInt8]) throws -> [UInt8] {
        guard container.count >= saltOffset + VaultConstants.ARGON2_SALT_LEN else {
            throw VaultFormatError.corrupt("PW01 too short for salt \(container.count)")
        }
        return Array(container[saltOffset..<saltOffset + VaultConstants.ARGON2_SALT_LEN])
    }

    static func open(_ container: [UInt8], key: SymmetricKey) throws -> [UInt8] {
        guard container.count >= headerLen + VaultConstants.MIN_CIPHERTEXT_TAG_LEN else {
            throw VaultFormatError.corrupt("PW01 too short \(container.count)")
        }
        guard key.bitCount == VaultConstants.AES_KEY_LEN * 8 else {
            throw VaultFormatError.invariantViolation("key bits \(key.bitCount)")
        }

        var r = ByteReader(container)
        guard try r.take(4) == Array(VaultConstants.PW01_MAGIC.utf8) else {
            throw VaultFormatError.parseError("PW01 magic")
        }
        let version = try r.u8()
        guard Int(version) == VaultConstants.PW01_VERSION else {
            throw VaultFormatError.unsupportedVersion("PW01 version \(version)")
        }
        let kdf = try r.u8()
        guard kdf == kdfArgon2id else {
            throw VaultFormatError.unsupportedVersion("kdf_id \(kdf)")
        }
        guard Int(try r.u32le()) == VaultConstants.ARGON2_M_KIB else {
            throw VaultFormatError.invariantViolation("argon2 m")
        }
        guard Int(try r.u32le()) == VaultConstants.ARGON2_T else {
            throw VaultFormatError.invariantViolation("argon2 t")
        }
        guard Int(try r.u32le()) == VaultConstants.ARGON2_P else {
            throw VaultFormatError.invariantViolation("argon2 p")
        }
        guard Int(try r.u8()) == VaultConstants.ARGON2_VERSION else {
            throw VaultFormatError.invariantViolation("argon2 version")
        }
        _ = try r.take(VaultConstants.ARGON2_SALT_LEN)   // salt: advances cursor, used only for key derivation
        let nonce = try r.take(VaultConstants.GCM_NONCE_LEN)

        let ctTag = r.rest()
        guard ctTag.count >= VaultConstants.MIN_CIPHERTEXT_TAG_LEN else {
            throw VaultFormatError.corrupt("PW01 ct+tag \(ctTag.count)")
        }
        let ct = Array(ctTag[0..<ctTag.count - VaultConstants.GCM_TAG_LEN])
        let tag = Array(ctTag[ctTag.count - VaultConstants.GCM_TAG_LEN..<ctTag.count])
        let header = Array(container[0..<headerLen])

        do {
            let box = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: Data(nonce)),
                ciphertext: Data(ct),
                tag: Data(tag)
            )
            return Array(try AES.GCM.open(box, using: key, authenticating: Data(header)))
        } catch {
            // CryptoKit returns plaintext only after the tag verifies, so a
            // failure here means no plaintext was produced. Fail closed.
            throw VaultFormatError.authError
        }
    }
}

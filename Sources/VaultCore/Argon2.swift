// Argon2.swift — thin Swift binding over the vendored Argon2id (via the C shim).
//
// `raw` takes arbitrary parameters (used by the cross-check tests); production
// callers go through KeyDerivation.deriveKey, which pins the frozen parameters.
// Any nonzero return code — including ARGON2_MEMORY_ALLOCATION_ERROR (-22) —
// fails closed (SECURITY_INVARIANTS.md I1); there is no downgrade path.

import Foundation
import CArgon2

enum Argon2 {
    static func raw(t: UInt32, mKiB: UInt32, p: UInt32, version: UInt32,
                    password: [UInt8], salt: [UInt8], outLen: Int,
                    secret: [UInt8] = [], ad: [UInt8] = []) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: outLen)
        let rc: Int32 = password.withUnsafeBufferPointer { pwd in
            salt.withUnsafeBufferPointer { slt in
                secret.withUnsafeBufferPointer { sec in
                    ad.withUnsafeBufferPointer { ad in
                        out.withUnsafeMutableBufferPointer { o in
                            vault_argon2id(t, mKiB, p, version,
                                           pwd.baseAddress, password.count,
                                           slt.baseAddress, salt.count,
                                           sec.baseAddress, secret.count,
                                           ad.baseAddress, ad.count,
                                           o.baseAddress, outLen)
                        }
                    }
                }
            }
        }
        guard rc == 0 else {   // ARGON2_OK == 0
            throw VaultFormatError.invariantViolation("argon2 rc \(rc)")
        }
        return out
    }
}

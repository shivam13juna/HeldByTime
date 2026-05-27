// PasswordPolicy.swift — the password → key-material rules (FORMAT.md §7).
//
// The password is the ONLY secrecy layer after a vault expires (the owner knows
// it, so Argon2 isn't what stops the owner — it stops a thief of an expired
// blob). Three jobs, all pure and deterministic so first-run setup (Task 8) and
// the SwiftUI fields (Task 9) share one source of truth:
//
//   1. encode  — the exact, lossless UTF-8 byte path into Argon2 (no trim, no
//      Unicode normalization, no case folding). A "same-looking but different
//      bytes" confirm can therefore never silently produce an unopenable vault.
//   2. validate — reject empty / above MAX_PASSWORD_BYTES. These are the only HARD
//      gates: an empty password is a dead-end (the unlock field can't submit it),
//      and the byte cap is an Argon2/format limit. Password STRENGTH is NOT a hard
//      gate — it is the owner's call. The minimum length is advisory only (see #3);
//      we warn, we never prohibit (the user owns the strength/usability tradeoff).
//   3. weaknessWarning — a blunt, dependency-free length/variety heuristic that
//      ADVISES (recommending at least MIN_PASSWORD_LENGTH) but never blocks (no
//      vendored zxcvbn — an extra dependency + attack surface a zero-fallback vault
//      doesn't need). The UI surfaces it inline and, if still weak, asks the owner
//      to confirm "create anyway".

import Foundation

/// Why a password was rejected. Hard gates only — STRENGTH is advisory (see
/// `weaknessWarning`), never a rejection reason.
enum PasswordError: Error, Equatable {
    case empty
    case tooLong(bytes: Int)      // UTF-8 encoding exceeds MAX_PASSWORD_BYTES
}

enum PasswordPolicy {
    /// The exact bytes fed to Argon2: UTF-8 of the characters as entered.
    /// Swift's `String.utf8` preserves the stored scalars verbatim — it does NOT
    /// normalize — which is precisely the no-normalization rule FORMAT.md §7
    /// requires. Nothing here trims whitespace or folds case.
    static func encode(_ entered: String) -> [UInt8] {
        Array(entered.utf8)
    }

    /// Validate against the hard gates, returning the encoded key-material bytes
    /// on success. The ONLY rejections are empty (a non-submittable dead-end) and
    /// over the byte cap (an Argon2/format limit). A short-but-non-empty password
    /// is ACCEPTED here — length is advisory (see `weaknessWarning`), the owner's
    /// call, never a block.
    static func validate(_ entered: String) -> Result<[UInt8], PasswordError> {
        let bytes = encode(entered)
        if bytes.isEmpty {
            return .failure(.empty)
        }
        if bytes.count > VaultConstants.MAX_PASSWORD_BYTES {
            return .failure(.tooLong(bytes: bytes.count))
        }
        return .success(bytes)
    }

    /// Exact-byte confirm: the two entries match iff their identical encoding
    /// paths yield the same bytes. This is what guarantees the confirm field
    /// catches "looks the same, different scalars" before a vault is created.
    static func confirms(_ first: String, _ second: String) -> Bool {
        encode(first) == encode(second)
    }

    /// A blunt, advisory weakness warning (nil = no concern). Heuristic only:
    /// length in Unicode scalars plus how many character classes appear
    /// (lowercase / uppercase / digit / other — "other" includes symbols and
    /// any non-ASCII, which count as variety). A long passphrase passes on
    /// length alone; a short, low-variety password is warned. This does NOT
    /// block and is NOT a dictionary check — it cannot catch "Password1234".
    /// `MIN_PASSWORD_LENGTH` is the *recommended* minimum the heuristic leans on,
    /// not a hard gate (validate accepts shorter — strength is the owner's call).
    static func weaknessWarning(_ entered: String) -> String? {
        var lower = false, upper = false, digit = false, other = false
        for s in entered.unicodeScalars {
            switch s.value {
            case 0x61...0x7A: lower = true   // a-z
            case 0x41...0x5A: upper = true   // A-Z
            case 0x30...0x39: digit = true   // 0-9
            default:          other = true   // symbols, spaces, non-ASCII
            }
        }
        let length = entered.unicodeScalars.count
        let classes = [lower, upper, digit, other].filter { $0 }.count

        // Strong enough — no warning — if any of:
        //   • a genuinely long passphrase (≥20), regardless of variety, or
        //   • ≥16 with at least two classes, or
        //   • ≥ the recommended minimum with at least three classes.
        if length >= 20 { return nil }
        if length >= 16 && classes >= 2 { return nil }
        if length >= VaultConstants.MIN_PASSWORD_LENGTH && classes >= 3 { return nil }

        return "Weak password: it is short and low-variety. "
            + "Prefer a longer passphrase, or mix uppercase, lowercase, digits, and symbols. "
            + "After the vault expires, this password is the only thing protecting its contents."
    }
}

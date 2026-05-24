// Errors.swift — the closed core/format error domain (FORMAT.md §9).
//
// This is one of the two closed error domains. The decoder throws only these
// cases; callers switch only on this closed set. Any unexpected condition maps
// to one of these (never a silent success). See SECURITY_INVARIANTS.md I1, I10.

enum VaultFormatError: Error, Equatable {
    case parseError(String)          // structural: bad magic, length, framing
    case authError                   // AES-GCM tag verification failed
    case unsupportedVersion(String)  // unknown magic/version byte
    case corrupt(String)             // well-formed framing, impossible contents
    case sizeLimit(String)           // a bounded field exceeded its cap
    case invariantViolation(String)  // a frozen-constant / pinned value mismatch
}

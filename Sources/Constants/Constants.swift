// Constants.swift — frozen vault constants (Task 1).
//
// Pure value declarations ONLY. No crypto, no parser, no file I/O, no SwiftUI.
// These are checked, value-for-value, against spec/constants.json and the
// FORMAT.md constants table by tests/consistency_check.swift. Editing a value
// here without editing the JSON, the Go constants, and FORMAT.md is a build
// failure (see SECURITY_INVARIANTS.md I11).

enum VaultConstants {

    // --- Argon2id KDF -------------------------------------------------------
    static let ARGON2_VERSION = 19          // 0x13
    static let ARGON2_M_KIB = 1_048_576     // 1 GiB
    static let ARGON2_T = 3
    static let ARGON2_P = 4
    static let ARGON2_OUTPUT_LEN = 32
    static let ARGON2_SALT_LEN = 16

    // --- AES-256-GCM AEAD ---------------------------------------------------
    static let AES_KEY_LEN = 32
    static let GCM_NONCE_LEN = 12
    static let GCM_TAG_LEN = 16
    static let MIN_CIPHERTEXT_TAG_LEN = 16

    // --- Format identifiers / versions --------------------------------------
    static let VLT1_MAGIC = "VLT1"
    static let PW01_MAGIC = "PW01"
    static let VAULT_FORMAT_VERSION = 1
    static let PW01_VERSION = 1
    static let MANIFEST_VERSION = 1

    // --- Size caps / password policy ----------------------------------------
    static let MIN_PASSWORD_LENGTH = 12
    static let MAX_PASSWORD_BYTES = 1024
    static let MAX_PLAINTEXT_NOTES_BYTES = 1_048_576   // 1 MiB
    static let MAX_SEALED_PAYLOAD_BYTES = 2_097_152    // 2 MiB
    static let MAX_STDOUT_BYTES = 4_194_304            // 4 MiB
    static let MAX_STDERR_BYTES = 65_536               // 64 KiB

    // --- Policy: drand rounds / timing --------------------------------------
    static let HELPER_TIMEOUT_MS = 10_000
    static let FRESHNESS_MARGIN_ROUNDS = 20
    static let MIN_LOCK_DURATION_ROUNDS = 1_200
    static let STALE_ROUND_TOLERANCE_ROUNDS = 10

    // --- drand quicknet identity (check-only mirror; helper keeps its own
    //     compiled-in copy — see SECURITY_INVARIANTS.md I11) -----------------
    static let DRAND_CHAIN_HASH =
        "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"
    static let DRAND_GROUP_PUBLIC_KEY =
        "83cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d1064510d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a"
    static let DRAND_GENESIS_UNIX = 1_692_803_367
    static let DRAND_PERIOD_SECONDS = 3
    static let DRAND_SCHEME = "bls-unchained-g1-rfc9380"
    static let DRAND_BEACON_ID = "quicknet"
}

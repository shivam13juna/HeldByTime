// constdump-swift — emits the compiled Swift constants as JSON on stdout.
//
// Used only by the consistency test. It sources every value from
// VaultConstants, so a wrong value in Constants.swift surfaces here and fails
// the comparison against spec/constants.json. Adding a constant without listing
// it here yields a key-set mismatch, which the test also rejects.

import Foundation

let intValues: [String: Int] = [
    "ARGON2_VERSION": VaultConstants.ARGON2_VERSION,
    "ARGON2_M_KIB": VaultConstants.ARGON2_M_KIB,
    "ARGON2_T": VaultConstants.ARGON2_T,
    "ARGON2_P": VaultConstants.ARGON2_P,
    "ARGON2_OUTPUT_LEN": VaultConstants.ARGON2_OUTPUT_LEN,
    "ARGON2_SALT_LEN": VaultConstants.ARGON2_SALT_LEN,
    "AES_KEY_LEN": VaultConstants.AES_KEY_LEN,
    "GCM_NONCE_LEN": VaultConstants.GCM_NONCE_LEN,
    "GCM_TAG_LEN": VaultConstants.GCM_TAG_LEN,
    "MIN_CIPHERTEXT_TAG_LEN": VaultConstants.MIN_CIPHERTEXT_TAG_LEN,
    "VAULT_FORMAT_VERSION": VaultConstants.VAULT_FORMAT_VERSION,
    "PW01_VERSION": VaultConstants.PW01_VERSION,
    "MANIFEST_VERSION": VaultConstants.MANIFEST_VERSION,
    "MIN_PASSWORD_LENGTH": VaultConstants.MIN_PASSWORD_LENGTH,
    "MAX_PASSWORD_BYTES": VaultConstants.MAX_PASSWORD_BYTES,
    "MAX_PLAINTEXT_NOTES_BYTES": VaultConstants.MAX_PLAINTEXT_NOTES_BYTES,
    "MAX_SEALED_PAYLOAD_BYTES": VaultConstants.MAX_SEALED_PAYLOAD_BYTES,
    "MAX_STDOUT_BYTES": VaultConstants.MAX_STDOUT_BYTES,
    "MAX_STDERR_BYTES": VaultConstants.MAX_STDERR_BYTES,
    "HELPER_TIMEOUT_MS": VaultConstants.HELPER_TIMEOUT_MS,
    "FRESHNESS_MARGIN_ROUNDS": VaultConstants.FRESHNESS_MARGIN_ROUNDS,
    "MIN_LOCK_DURATION_ROUNDS": VaultConstants.MIN_LOCK_DURATION_ROUNDS,
    "STALE_ROUND_TOLERANCE_ROUNDS": VaultConstants.STALE_ROUND_TOLERANCE_ROUNDS,
    "DRAND_GENESIS_UNIX": VaultConstants.DRAND_GENESIS_UNIX,
    "DRAND_PERIOD_SECONDS": VaultConstants.DRAND_PERIOD_SECONDS,
]

let stringValues: [String: String] = [
    "VLT1_MAGIC": VaultConstants.VLT1_MAGIC,
    "PW01_MAGIC": VaultConstants.PW01_MAGIC,
    "DRAND_CHAIN_HASH": VaultConstants.DRAND_CHAIN_HASH,
    "DRAND_GROUP_PUBLIC_KEY": VaultConstants.DRAND_GROUP_PUBLIC_KEY,
    "DRAND_SCHEME": VaultConstants.DRAND_SCHEME,
    "DRAND_BEACON_ID": VaultConstants.DRAND_BEACON_ID,
]

var merged: [String: Any] = [:]
for (k, v) in intValues { merged[k] = v }
for (k, v) in stringValues { merged[k] = v }

let data = try JSONSerialization.data(
    withJSONObject: merged,
    options: [.sortedKeys, .prettyPrinted]
)
FileHandle.standardOutput.write(data)

// Package constants holds the frozen vault constants for the Go helper.
//
// These are checked, value-for-value, against spec/constants.json and the
// FORMAT.md constants table by tests/consistency_check.swift. The drand
// identity values are compiled in here and used directly by the (future)
// helper crypto; the JSON copy exists only for drift detection and is never
// loaded at runtime (see SECURITY_INVARIANTS.md I9, I11).
package constants

const (
	// Argon2id KDF
	ARGON2_VERSION    = 19      // 0x13
	ARGON2_M_KIB      = 1048576 // 1 GiB
	ARGON2_T          = 3
	ARGON2_P          = 4
	ARGON2_OUTPUT_LEN = 32
	ARGON2_SALT_LEN   = 16

	// AES-256-GCM AEAD
	AES_KEY_LEN            = 32
	GCM_NONCE_LEN          = 12
	GCM_TAG_LEN            = 16
	MIN_CIPHERTEXT_TAG_LEN = 16

	// Format identifiers / versions
	VLT1_MAGIC           = "VLT1"
	PW01_MAGIC           = "PW01"
	VAULT_FORMAT_VERSION = 1
	PW01_VERSION         = 1
	MANIFEST_VERSION     = 1

	// Size caps / password policy
	MIN_PASSWORD_LENGTH       = 12
	MAX_PASSWORD_BYTES        = 1024
	MAX_PLAINTEXT_NOTES_BYTES = 1048576 // 1 MiB
	MAX_SEALED_PAYLOAD_BYTES  = 2097152 // 2 MiB
	MAX_STDOUT_BYTES          = 4194304 // 4 MiB
	MAX_STDERR_BYTES          = 65536   // 64 KiB

	// Policy: drand rounds / timing
	HELPER_TIMEOUT_MS            = 10000
	FRESHNESS_MARGIN_ROUNDS      = 20
	MIN_LOCK_DURATION_ROUNDS     = 1200
	STALE_ROUND_TOLERANCE_ROUNDS = 10

	// drand quicknet identity
	DRAND_CHAIN_HASH       = "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"
	DRAND_GROUP_PUBLIC_KEY = "83cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d1064510d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a"
	DRAND_GENESIS_UNIX     = 1692803367
	DRAND_PERIOD_SECONDS   = 3
	DRAND_SCHEME           = "bls-unchained-g1-rfc9380"
	DRAND_BEACON_ID        = "quicknet"
)

// All is the check-only projection consumed by cmd/constdump for the
// consistency test. Runtime helper code references the typed consts above
// directly; this map is never used as a configuration input.
var All = map[string]interface{}{
	"ARGON2_VERSION":               ARGON2_VERSION,
	"ARGON2_M_KIB":                 ARGON2_M_KIB,
	"ARGON2_T":                     ARGON2_T,
	"ARGON2_P":                     ARGON2_P,
	"ARGON2_OUTPUT_LEN":            ARGON2_OUTPUT_LEN,
	"ARGON2_SALT_LEN":              ARGON2_SALT_LEN,
	"AES_KEY_LEN":                  AES_KEY_LEN,
	"GCM_NONCE_LEN":                GCM_NONCE_LEN,
	"GCM_TAG_LEN":                  GCM_TAG_LEN,
	"MIN_CIPHERTEXT_TAG_LEN":       MIN_CIPHERTEXT_TAG_LEN,
	"VLT1_MAGIC":                   VLT1_MAGIC,
	"PW01_MAGIC":                   PW01_MAGIC,
	"VAULT_FORMAT_VERSION":         VAULT_FORMAT_VERSION,
	"PW01_VERSION":                 PW01_VERSION,
	"MANIFEST_VERSION":             MANIFEST_VERSION,
	"MIN_PASSWORD_LENGTH":          MIN_PASSWORD_LENGTH,
	"MAX_PASSWORD_BYTES":           MAX_PASSWORD_BYTES,
	"MAX_PLAINTEXT_NOTES_BYTES":    MAX_PLAINTEXT_NOTES_BYTES,
	"MAX_SEALED_PAYLOAD_BYTES":     MAX_SEALED_PAYLOAD_BYTES,
	"MAX_STDOUT_BYTES":             MAX_STDOUT_BYTES,
	"MAX_STDERR_BYTES":             MAX_STDERR_BYTES,
	"HELPER_TIMEOUT_MS":            HELPER_TIMEOUT_MS,
	"FRESHNESS_MARGIN_ROUNDS":      FRESHNESS_MARGIN_ROUNDS,
	"MIN_LOCK_DURATION_ROUNDS":     MIN_LOCK_DURATION_ROUNDS,
	"STALE_ROUND_TOLERANCE_ROUNDS": STALE_ROUND_TOLERANCE_ROUNDS,
	"DRAND_CHAIN_HASH":             DRAND_CHAIN_HASH,
	"DRAND_GROUP_PUBLIC_KEY":       DRAND_GROUP_PUBLIC_KEY,
	"DRAND_GENESIS_UNIX":           DRAND_GENESIS_UNIX,
	"DRAND_PERIOD_SECONDS":         DRAND_PERIOD_SECONDS,
	"DRAND_SCHEME":                 DRAND_SCHEME,
	"DRAND_BEACON_ID":              DRAND_BEACON_ID,
}

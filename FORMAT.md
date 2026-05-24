# FORMAT.md — Vault on-disk format (bytes-on-paper spec)

**Status:** frozen for v1. This document is the authority the encoder and decoder are
written against; it exists *before* any parser code so the two cannot co-evolve the
same wrong behavior. Any deviation between this file, `spec/constants.json`, the Swift
constants, and the Go constants is a build failure (see the consistency test).

There is **exactly one** format version in v1. Unknown magic or version ⇒ **fail
closed** (no migration subsystem, no best-effort parsing).

---

## 1. Layering (outermost → innermost)

```
notes (UTF-8 JSON, may be empty)
  └─①─ AES-256-GCM (key = Argon2id(password))         → PW01 container
        └── manifest (authoritative) || PW01 bytes     → tlock plaintext
              └─②─ tlock seal to a future drand round  → sealed payload (opaque)
                    └── VLT1 framing (plaintext, UNTRUSTED display header) → vault.dat
```

- **VLT1 outer header** is *plaintext and untrusted* — a display/routing hint only.
- **manifest** is the *authoritative* record of which chain/rounds the vault is bound
  to; it lives **inside** the tlock layer but **outside** the AES layer, so it can be
  read after a passwordless unseal (for defensive re-seal) without ever touching notes.
- **PW01/AES** protects the **notes only** — never the target rounds.

All multi-byte integers are **little-endian, fixed width** (no varints). All `MAGIC`
fields are 4 ASCII bytes. Lengths are validated against the caps in §6 *before*
allocation.

---

## 2. VLT1 outer container (`vault.dat`)

| Offset | Field                         | Type        | Notes |
|-------:|-------------------------------|-------------|-------|
| 0      | `magic`                       | 4 × u8      | ASCII `VLT1` (= `VLT1_MAGIC`) |
| 4      | `format_version`              | u8          | = `VAULT_FORMAT_VERSION` (1); any other ⇒ fail closed |
| 5      | `flags`                       | u8          | reserved, MUST be 0 in v1 |
| 6      | `display_start_round`         | u64 LE      | UNTRUSTED hint for the locked screen |
| 14     | `display_end_round`           | u64 LE      | UNTRUSTED hint for the locked screen |
| 22     | `payload_len`                 | u64 LE      | length of `sealed_payload`; MUST ≤ `MAX_SEALED_PAYLOAD_BYTES` |
| 30     | `sealed_payload`              | `payload_len` × u8 | opaque tlock ciphertext (§3) |

- Total header is 30 bytes; `sealed_payload` follows immediately.
- `display_*` rounds are **never** used for an access decision. They exist so the
  locked screen can say "locked until ~HH:MM" without unsealing. The authoritative
  rounds come from the manifest (§4), readable only *after* a successful unseal.
- If `payload_len` ≠ the actual remaining byte count ⇒ `parse_error` (fail closed).

---

## 3. Sealed payload (tlock layer)

`sealed_payload` is the byte-exact output of the `vaultseal` helper's `seal` command
and the byte-exact input to its `unseal` command. It is **opaque** to the VLT1 parser:
the outer layer never interprets it, only frames it. It is bounded by
`MAX_SEALED_PAYLOAD_BYTES`. Its plaintext (revealed only when the target round has
published) is exactly: `manifest (§4) || PW01 container (§5)`.

---

## 4. Manifest (authoritative; tlock plaintext, AES-outside)

Fixed binary layout, no JSON:

| Offset | Field                | Type     | Notes |
|-------:|----------------------|----------|-------|
| 0      | `magic`              | 4 × u8   | ASCII `MFST` |
| 4      | `version`            | u8       | = `MANIFEST_VERSION` (1); any other ⇒ fail closed |
| 5      | `reserved`           | u8       | MUST be 0 |
| 6      | `chain_hash`         | 32 × u8  | raw bytes; MUST equal `DRAND_CHAIN_HASH` decoded, else `invariant_violation` (the helper-domain `chain_mismatch` is the *helper's* equivalent) |
| 38     | `target_start_round` | u64 LE   | first round at/after which opening is permitted |
| 46     | `target_end_round`   | u64 LE   | committed end; re-seal forward at/after this round |

Manifest is 54 bytes. After unseal, the decoder MUST verify
`manifest.chain_hash == DRAND_CHAIN_HASH` and that `target_end_round >
target_start_round`; otherwise fail closed. The VLT1 `display_*` fields are compared
to the manifest **for display sanity only** — a mismatch is treated as untrusted
(prefer the manifest), never as authorization.

---

## 5. PW01 inner container (AES-256-GCM of notes)

| Offset | Field            | Type     | Notes |
|-------:|------------------|----------|-------|
| 0      | `magic`          | 4 × u8   | ASCII `PW01` (= `PW01_MAGIC`) |
| 4      | `version`        | u8       | = `PW01_VERSION` (1); any other ⇒ fail closed |
| 5      | `kdf_id`         | u8       | 1 = Argon2id; any other ⇒ fail closed |
| 6      | `argon2_m_kib`   | u32 LE   | MUST equal `ARGON2_M_KIB` |
| 10     | `argon2_t`       | u32 LE   | MUST equal `ARGON2_T` |
| 14     | `argon2_p`       | u32 LE   | MUST equal `ARGON2_P` |
| 18     | `argon2_version` | u8       | MUST equal `ARGON2_VERSION` (19 = 0x13) |
| 19     | `salt`           | 16 × u8  | `ARGON2_SALT_LEN`; fresh per encryption (§7) |
| 35     | `nonce`          | 12 × u8  | `GCM_NONCE_LEN`; fresh per encryption (§7) |
| 47     | `ciphertext+tag` | ≥ 16 × u8| AES-256-GCM output; last `GCM_TAG_LEN` bytes are the tag |

- Header is the first **47 bytes** (offsets 0..46 inclusive).
- The Argon2 parameters are stored for self-description, but v1 **pins** them: the
  decoder MUST reject any header whose params differ from the frozen constants
  (`invariant_violation`) — there is no parameter negotiation and no downgrade.
- `ciphertext+tag` length MUST be ≥ `MIN_CIPHERTEXT_TAG_LEN` (16). Empty notes are
  valid (an empty vault still encrypts to a real, non-empty ciphertext+tag).

### 5.1 AEAD AAD (exact byte range)

The AES-256-GCM **additional authenticated data is the entire PW01 header**, i.e.
bytes `[0, 47)` of the PW01 container (magic … nonce, inclusive). The plaintext is the
notes JSON. The tag authenticates header + ciphertext. Any tampering with the stored
Argon2 params, salt, or nonce therefore fails authentication.

---

## 6. Size caps (validated before allocation)

| Constant | Meaning |
|----------|---------|
| `MAX_PASSWORD_BYTES` | reject passwords whose UTF-8 encoding exceeds this |
| `MAX_PLAINTEXT_NOTES_BYTES` | reject notes JSON larger than this before encrypting |
| `MAX_SEALED_PAYLOAD_BYTES` | reject/refuse a sealed payload larger than this |
| `MAX_STDOUT_BYTES` / `MAX_STDERR_BYTES` | caps on helper subprocess output |

---

## 7. Password → key-derivation input, and randomness

- **Password encoding:** UTF-8 bytes of the exact characters entered. **No trimming,
  no Unicode normalization, no case folding.** Reject empty. Reject if the UTF-8
  encoding exceeds `MAX_PASSWORD_BYTES`.
- **Minimum length:** reject if the entered password has fewer than
  `MIN_PASSWORD_LENGTH` Unicode scalar values (a hard gate, distinct from the
  byte cap). A separate weak-password *warning* (lightweight heuristic, no external
  dependency) may advise but does not block above the minimum.
- **Salt and nonce:** drawn from the system CSPRNG, **fresh for every encryption**;
  never reused across saves. `ARGON2_SALT_LEN` and `GCM_NONCE_LEN` bytes respectively.
- **KDF:** Argon2id only (`ARGON2_M_KIB`/`ARGON2_T`/`ARGON2_P`/`ARGON2_VERSION`,
  output `ARGON2_OUTPUT_LEN` = the AES-256 key). No PBKDF2 fallback.

---

## 8. Round ↔ time and stale-round rule

drand quicknet rounds advance every `DRAND_PERIOD_SECONDS` from `DRAND_GENESIS_UNIX`.
The **authoritative** round/time mapping is the drand client's own `RoundAt`
function (used identically by the Go helper and surfaced to Swift); the formula below
is the documented convention and is reconciled against that library at implementation:

```
expectedRound(now) = floor((now − DRAND_GENESIS_UNIX) / DRAND_PERIOD_SECONDS) + 1
```

**Stale-round defense (one-sided, fail-closed):** given the helper's
network-`verifiedLatest` round, reject as `stale_round` if

```
verifiedLatest < expectedRound(now) − STALE_ROUND_TOLERANCE_ROUNDS
```

The local clock is used **only** to *reject* a suspiciously-old "latest" (fail
closed); it is **never** used to *grant* access. A standard (non-admin) account cannot
move the clock backward, and future rounds are unforgeable, so this is safe.

**Freshness / lock-duration policy:** a seal target round MUST be at least
`FRESHNESS_MARGIN_ROUNDS` beyond the verified latest, and a vault's
`target_end_round − target_start_round` MUST be ≥ `MIN_LOCK_DURATION_ROUNDS`.

---

## 9. Error domains (two closed sets; unknown ⇒ fail closed)

**Core / format domain:** `parse_error`, `auth_error`, `unsupported_version`,
`corrupt`, `size_limit`, `invariant_violation`.

**Helper domain** (machine-readable JSON on the helper's stderr): `round_not_ready`,
`round_too_near`, `stale_round`, `auth_failed`, `parse_error`, `chain_mismatch`,
`timeout`.

The Swift↔helper boundary mapping is total: known code → its specific fail-closed
action; unknown code → fail closed; malformed/oversized stderr → fail closed; non-zero
exit without valid JSON → fail closed; any stdout payload present alongside an error →
fail closed.

---

## 10. Machine-checkable constants table

The block below is parsed by the consistency test (`tests/consistency_check.swift`)
and compared, key-for-key and value-for-value, against `spec/constants.json`, the
compiled Swift constants, and the compiled Go constants. Numbers are bare; strings are
double-quoted. Editing this block without editing the other three sources is a build
failure.

<!-- CONSTANTS-TABLE-BEGIN -->
ARGON2_VERSION = 19
ARGON2_M_KIB = 1048576
ARGON2_T = 3
ARGON2_P = 4
ARGON2_OUTPUT_LEN = 32
ARGON2_SALT_LEN = 16
AES_KEY_LEN = 32
GCM_NONCE_LEN = 12
GCM_TAG_LEN = 16
MIN_CIPHERTEXT_TAG_LEN = 16
VLT1_MAGIC = "VLT1"
PW01_MAGIC = "PW01"
VAULT_FORMAT_VERSION = 1
PW01_VERSION = 1
MANIFEST_VERSION = 1
MIN_PASSWORD_LENGTH = 12
MAX_PASSWORD_BYTES = 1024
MAX_PLAINTEXT_NOTES_BYTES = 1048576
MAX_SEALED_PAYLOAD_BYTES = 2097152
MAX_STDOUT_BYTES = 4194304
MAX_STDERR_BYTES = 65536
HELPER_TIMEOUT_MS = 10000
FRESHNESS_MARGIN_ROUNDS = 20
MIN_LOCK_DURATION_ROUNDS = 1200
STALE_ROUND_TOLERANCE_ROUNDS = 10
DRAND_CHAIN_HASH = "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"
DRAND_GROUP_PUBLIC_KEY = "83cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d1064510d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a"
DRAND_GENESIS_UNIX = 1692803367
DRAND_PERIOD_SECONDS = 3
DRAND_SCHEME = "bls-unchained-g1-rfc9380"
DRAND_BEACON_ID = "quicknet"
<!-- CONSTANTS-TABLE-END -->

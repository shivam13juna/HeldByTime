# app.md — Time-Locked Encrypted Vault (macOS)

A native macOS app that stores text notes encrypted at rest, and — crucially —
can **only be opened during user-defined daily time windows**, enforced by
*time-lock cryptography* so that the restriction holds even against the owner.

> Status: design / pre-implementation. This document captures everything
> discussed and the proposed implementation. No app code has been written yet.

---

## 1. Purpose & threat model

This is **not** primarily a tool to hide data from a third-party attacker.
It is a **self-control / commitment device** ("Ulysses pact"). The adversary
we are designing against is **the owner's own future self** during a period
when they have committed to not accessing the content.

That single fact drives every design choice:

- A normal app-level lock (a password prompt, a "blocked app") does **not** stop
  the owner, because the owner *knows the password*. Knowing the algorithm never
  reveals a password (brute force against a strong password + Argon2id is
  centuries), but the owner doesn't need to brute force anything — they already
  hold the key. Any purely local "only unlock between 4–5am" check is just an
  `if (clock)` guard sitting in front of a decryption the owner can perform
  anyway (via terminal, by changing the clock, or by editing the app).
- Therefore, to make a time restriction *real*, **the decryption key must not be
  in the owner's possession outside the allowed window.** The only ways to
  achieve that are (a) a server that releases the key on schedule, or
  (b) **time-lock cryptography**, which needs no server of our own. We chose (b).
- **Foundation — standard (non-admin) account.** The owner runs a standard macOS
  account and **cannot authenticate as admin**. This is load-bearing: it means
  the owner cannot change the system clock, read swap / other-process memory, or
  configure Time Machine — which closes several bypasses (see §11). The Mac admin
  password exists only as an offline emergency backup held by a trusted third
  party; it is **not** the vault master password, so it does
  not weaken the daily-window commitment. If the owner could self-elevate, the
  closed bypasses would reopen.

### What this does and does not guarantee

| Guarantee | Holds? | Notes |
|---|---|---|
| Cannot open **before** the next window starts | ✅ Hard (math) | Not bypassable by clock change, terminal, or password — and as a standard user you can't even change the clock |
| Thief who steals the file can't read it | ✅ Hard | Inner password/AES layer |
| Cannot read **after** the window ends | ⚠️ Strong | App re-seals on Lock / quit / committed window-end; the launch open-vs-reseal decision is anchored to the **committed end round**, not the mutable schedule. Residual: a hard crash leaves the blob manually-decryptable until next launch (§6, §11) |
| No access **during** an open window | ❌ Inherent ceiling | While open you have full plaintext access — can copy, paste, screenshot (§11) |
| Keep long-random copy-pasted secrets out of reach out-of-window | ✅ In practice | Un-memorizable from occasional viewing; vault is sealed out-of-window. Residual = *deliberately* stashing a copy (clipboard residue out of scope — see §2) |
| Recover a forgotten **vault master** password | ❌ Never | No backdoor; lost master password = vault contents gone forever |
| Regain Mac **admin** if locked out | ✅ Via trusted party | A trusted third party holds the admin password as anti-brick backup (NOT the vault master password) |

---

## 2. Decisions locked in

- **Platform:** macOS (Apple Silicon). Distributed as a real
  double-clickable **`.app` bundle** — there is **no terminal entry point** the
  user interacts with.
- **Unlock model:** **password + time-lock** (both required), see §4.
- **Schedule:** one or more **daily time windows** defined by the user
  (e.g. a single window `04:00–05:00`). The vault is openable only inside a
  window; outside it, it is cryptographically sealed until the next window start.
- **Storage:** single vault file containing all text notes.
- **Re-lock trigger:** the vault re-seals on any of:
  1. a **manual "Lock" button** — seal now, stay in the app (for "done early");
  2. a **graceful quit** (Cmd-Q / menu Quit) — the app seals *before* exiting;
  3. the **window's end time** (e.g. `05:00`) being reached while running;
  4. **defensively on any launch outside a window** — backstop for the only
     non-interceptable case: a hard crash / force-kill / power loss.

  Net effect: you never need to keep the app running, and a normal quit always
  seals. The single residual gap is "app violently killed mid-window," caught at
  the next launch (4).
- **Backups:** a **single** redundant copy (retention = 1), **overwritten on
  every save** and **sealed to the same future target** as the live vault. It
  guards against disk corruption / accidental deletion of the one file — it is
  **not** a version history. ⚠️ Dated/historical backups are explicitly
  forbidden: an old backup is sealed to a *past* target, so its time-lock has
  expired and it becomes openable anytime with only the password — a hidden
  escape hatch that defeats the commitment (see §7a).
- **No fallback / no escape hatch:** zero weakening. There is no password-only
  copy and no recovery path around the time-lock. drand-down or forgotten master
  password = no access, by design. (Anti-brick exception: the *Mac admin*
  password also exists as an offline backup held by a trusted third party — a
  separate secret, not the vault master password.)

### What's stored, and special handling

Contents are text notes plus one or more high-value secrets — for example an
account-recovery password or a content-filter password. Such secrets are long,
random, copy-pasted, and needed only ~1–2×/month, so they are not realistically
memorizable from occasional viewing — which is why a single daily window is
acceptable for them. Required handling:

- **Your content filter / firewall must allow `api.drand.sh` (mandatory).** The
  vault needs drand to unseal; if a filter blocks it and the password for that
  same filter is *inside* the vault, you hard-deadlock. Allow it before relying
  on the vault. (Confirm it is reachable first.)
- **Secrets masked by default** in the UI, revealed only on an explicit tap — a
  small friction so an idle glance doesn't expose them.
- **Setup warning.** Because contents include machine master-keys, the app states
  bluntly at setup that forgetting the vault master password loses them
  permanently (Mac admin recovery then depends on the trusted third party's backup).

> **Out of scope (owner's decision):** clipboard-residue and screen-capture
> defenses (auto-clear, concealed pasteboard, `NSWindow.sharingType`) are **not**
> implemented — the owner does not run a clipboard-history manager and accepts
> that a legitimately-open window grants full plaintext access. These are inherent
> commitment-device ceilings, not bugs.

### Rejected ideas (and why)

- **Custom / secret encryption algorithm** — rejected. "Don't roll your own
  crypto." A secret algorithm lowers security (silent failures) and gives no
  benefit, since secrecy must come from the *key*, not the algorithm
  (Kerckhoffs's principle).
- **Multiple rounds of encryption (cipher A then cipher B)** — rejected. One
  correctly-used strong cipher (AES-256-GCM) is already beyond brute force.
  Stacking ciphers does nothing about the real weak point (the owner holds the
  password) and *adds* bug surface. Effort goes into a strong key-derivation
  step (Argon2id) instead.
- **Purely local time check** — rejected. Cosmetic; bypassable (see §1).

---

## 3. How time-lock cryptography works (drand / tlock)

**drand** is a public, decentralized "randomness beacon" run by the *League of
Entropy* (Cloudflare, Protocol Labs, EPFL, Kudelski, universities, …). It
publishes a fresh, unpredictable, publicly-verifiable value at a fixed cadence,
forever. We use its **"quicknet"** chain:

- Chain hash: `52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971`
- Period: **3 seconds**; genesis: Unix `1692803367` (Aug 2023).
- Supports **timelock encryption** (BLS signatures on G1).

**tlock** (the time-lock scheme built on drand) lets you encrypt data addressed
to a *future beacon round* (= a future moment in time). The decryption key for
that round **does not exist yet** — it only comes into being when the network
reaches that round and publishes the value. Until then, the ciphertext is
undecryptable **by everyone, including the person who created it**. No password,
no clock change, and no amount of compute can open it early. When the time
arrives, anyone can fetch the now-published value and decrypt — which is exactly
why we keep a password layer underneath (see §4).

- Reference tool: `tle` from `github.com/drand/tlock` (Apache-2.0, free).
- It needs **network access at decrypt time** to fetch the round's value.

---

## 4. Cryptographic design — two layers

Notes are wrapped twice; **both** locks must open to read them.

```
  plaintext notes (JSON)
        │  ① inner: AES-256-GCM, key = Argon2id(password, random salt)  →  PW01
        ▼
  manifest { target, chainHash }  +  PW01     (manifest is plaintext, not secret)
        │  ② outer: tlock seal to drand round for time T (next window start)
        ▼
  on-disk vault blob   ──►  also copied to the single same-target backup (§2)
```

- **Inner (password):** protects against anyone who has the file but not the
  password — including after the time-lock has expired (tlock output is public).
- **Outer (time-lock):** makes the file undecryptable by *anyone* until time `T`.

To read: ② time-unseal (only works at/after `T`, needs internet) → ① password
+ Argon2id → AES-decrypt → plaintext in memory.

### File format (custom container — nothing else parses it)

```
[ magic "VLT1" (4) ][ version (1) ]
[ chainHash (32) ][ targetStartRound (8) ][ targetEndRound (8) ][ payloadLen (8) ]
                                         ← plaintext, UNTRUSTED (display/routing hint only)
[ tlock-sealed payload … ]              ← outer layer (age/tlock framing)

  the tlock-sealed payload, once unsealed (no password needed), is:
  [ manifest: binary fixed-layout struct — NOT JSON ]                            ← authoritative, NOT secret
    [ formatVersion (1) ][ chainHash (32) ][ targetStartRound (8) ][ targetEndRound (8) ]
  [ PW01 inner container: ]
    [ magic "PW01" (4) ][ version (1) ]
    [ argon2 params: m,t,p (3 × uint32 LE — fixed width, no varints) ][ salt (16) ][ AES-GCM nonce (12) ]
    [ AES-GCM ciphertext + tag … ]
```

- **Three places, three roles.** The outer **VLT1 header** is plaintext-but-
  untrusted — readable *before* `T` so the app can show "locked until X" without
  decrypting. The **manifest** sits inside the tlock layer but *outside* the AES
  layer, so a tlock-unseal exposes it **without the password** — this is what lets
  the passwordless defensive re-seal (§6) update the target without bricking
  consistency. The **PW01/AES plaintext holds only the notes** — never the target.
- **Authoritative access interval = the manifest, readable only AFTER unseal.** The
  manifest commits the authorized window `[targetStartRound, targetEndRound]`.
  Before a successful tlock-unseal the manifest is unreadable, so the locked screen
  can only use the untrusted VLT1 hint for *display* — it never authorizes access.
  After unseal, verify VLT1 equals the manifest on every field the manifest also
  carries — `chainHash`, `targetStartRound`, `targetEndRound` — and that
  `VLT1.version` and `manifest.formatVersion` are each individually supported; any
  mismatch ⇒ reject. (`payloadLen` lives only in VLT1, so it is checked
  *structurally* during outer parsing — it must equal the actual sealed-payload
  length — not as a manifest-equality field.) The app gates "show password prompt" on
  `start ≤ verifiedRound ≤ end` **from the manifest, never the mutable schedule** —
  so editing the schedule cannot turn an expired seal into access (§6, §11).
  Outer = display hint, manifest = truth.
- **The GCM ciphertext authenticates the PW01 header as associated data (AAD)** —
  magic, version, argon2 params, salt, nonce length — so any edit to them fails
  cleanly at the tag instead of mis-parsing.
- **Parser hardening.** VLT1 / manifest / PW01 use a canonical fixed layout with
  explicit length prefixes and a bounded maximum size; parsing is **canonical,
  deterministic, and fail-closed** — no best-effort parsing, no duplicate encodings,
  no ignored trailing bytes, no unknown critical fields, exact length validation,
  and every parse-failure path denies access.
- **Bytes-on-paper before code (`FORMAT.md`).** Before any parser is written, a
  `FORMAT.md` pins the spec so encoder and decoder can't co-evolve the same wrong
  behavior: **all multi-byte integers little-endian, fixed width** (no varints);
  exact widths as shown above; **manifest is a binary fixed-layout struct, not JSON**
  (no canonical-JSON ambiguity); a hard **max vault size and max payload length**;
  the **exact AAD byte range** for AES-GCM (the whole PW01 header: magic, version,
  the three `uint32` params, salt, nonce); and **two separate closed error domains**,
  each member mapped to an explicit fail-closed action: a **core/format domain**
  (`parse_error`, `auth_error` [GCM tag], `unsupported_version`, `corrupt`,
  `size_limit`, `invariant_violation`) and the **helper domain** (§9:
  `round_not_ready`, `round_too_near`, `stale_round`, `auth_failed`, `parse_error`,
  `chain_mismatch`, `timeout`). It also pins the
  **exact AEAD lengths and bounds**: nonce = **12 bytes**, tag = **16 bytes**,
  minimum ciphertext+tag = **16 bytes**, **empty notes JSON is allowed** (an empty
  vault is valid and still encrypts to a real ciphertext), and explicit caps on
  **max plaintext-notes size** and **max sealed-payload size**.
- **Randomness source (pinned).** The Argon2 **salt** and AES-GCM **nonce** come
  **only from the system CSPRNG** (`SecRandomCopyBytes` / CryptoKit), **fresh per
  encryption** — never a counter, clock, or PRNG. A test asserts no deterministic
  nonce/salt reuse leaks in through a test-only seam.
- **Single format version in v1 (no migration).** Any unknown/unsupported VLT1,
  PW01, or manifest version **fails closed** — no best-effort migration, no partial
  upgrade, no compatibility shim. The version bytes only *reserve* future evolution
  (re-seal-forward during an open window, §9 health check); v1 reads exactly one.

---

## 5. Schedule model

User configures **one or more daily windows**, each `start`–`end` (local time).
Example requested: a single window **04:00–05:00**.

- **Next-start computation:** the nearest window-start that is not just strictly in
  the future but whose **start round also clears `verifiedLatest + margin` and the
  minimum lock duration**. If now is before today's start → today's start; if now is
  inside/after the window → tomorrow's start (so locking mid-window means done until
  tomorrow). **If the nearest start is too near** (its round would be ≤ `latest +
  margin`, e.g. you Lock seconds before the window opens), **skip forward to the next
  valid window** rather than computing a target the helper will reject — the schedule
  and the helper's freshness rule (§9) must agree so the vault never wedges on a
  failed re-seal at a boundary.
- Multiple windows per day are supported by the same logic (pick the nearest
  *valid* future start).

---

## 6. Lifecycle / flow

```
On launch the manifest is NOT yet readable (it is inside the tlock layer). Read the
VLT1 header as an untrusted display/routing hint only, fetch the drand-verified
current round R, then let the tlock-unseal attempt itself be the authoritative
locked-vs-open gate:

attempt tlock-unseal  (needs network)
  • round-not-ready (still sealed to a future round) — or offline:
      → LOCKED. Show "locked until <VLT1.targetStartRound>" (display hint only),
        no password prompt, do NOT rewrap
  • unseal succeeds → read manifest (now authoritative) → verify outer == manifest:
      if mismatch                          → tampered/corrupt: fail closed, no prompt.
                                             "Quarantine" = record only a HASH +
                                             diagnostic of the mismatch, NEVER the raw
                                             (now-unsealed, decryptable) bytes — keeping
                                             those would manufacture a fresh escape
                                             hatch. Then hand to fail-closed recovery
                                             (below): re-seal any valid expired copy
                                             FORWARD; never leave it openable
      if R < manifest.start                → impossible/corrupt state: fail closed, no prompt
      if manifest.start ≤ R ≤ manifest.end → prompt password → AES-decrypt → edit
      if R > manifest.end (crash/force-kill gap) → passwordless defensive re-seal

User presses "Lock"                        → interactive re-seal, stay in app (locked)
Graceful quit (Cmd-Q / menu)               → interactive re-seal, then exit
Committed targetEndRound reached running   → interactive re-seal

  Two re-seal paths:

  • interactive re-seal  (Lock / quit / window-end — app is OPEN, has password +
    plaintext):
        re-encrypt notes with AES-GCM (fresh nonce) → wrap with a manifest whose
        committed interval = NEXT window [start, end] → tlock-seal to start → write.

  • defensive re-seal  (R > targetEndRound, NO password available):
        tlock-unseal (round is past) → reuse the existing PW01 bytes verbatim
        (AES plaintext untouched) → rebuild the manifest with the recomputed NEXT
        [start, end] → tlock-reseal → write.

  Backup write order (tmp+rename every step, never a direct copy; never leave a
  future-sealed primary beside an expired .bak):
    write vault.dat.tmp + F_FULLFSYNC → delete old .bak → rename over vault.dat
    (F_FULLFSYNC file + dir) → write vault.dat.bak.tmp + F_FULLFSYNC → rename over
    .bak (F_FULLFSYNC dir) → post-write re-parse both + verify byte-equality and
    0600/owner/no-symlink/st_nlink==1. A crash mid-sequence may lose redundancy but
    never keeps an expired (password-only) escape hatch or a partial .bak.

  Recovery on vault.dat/.bak disagreement (fail-closed): prefer the most-locked
  valid copy; if ANY surviving copy is future-sealed, do not offer access; re-seal
  an expired-but-valid copy forward first; never prefer an expired .bak over a
  future primary.
```

> ⚠️ **Window-end: app-enforced, but the decision is now manifest-anchored.**
> tlock only guarantees "not before `targetStartRound`"; after the start round the
> blob is unsealable until something re-seals it. Two things enforce the end:
> (a) a live running session is re-sealed by the app at the committed
> `targetEndRound` / on Lock / on quit — crypto can't force-close an already-open
> in-memory session; (b) on every launch the open-vs-reseal choice is taken from
> the **committed `targetEndRound`**, never the mutable schedule, so editing the
> schedule cannot turn an expired seal into authorized access. The one residual
> gap is unchanged: a **hard crash / force-kill / power loss** mid-window leaves
> the blob sealed to a past round, so it is decryptable by deliberate tlock +
> password tooling until the **next launch** runs the defensive re-seal.
> Committing the interval removes the *low-friction in-app* bypass; it cannot stop
> deliberate manual decryption during that gap. This is the accepted best-effort
> boundary on the *end*.

---

## 7. Downsides & risks of the time-lock approach

1. **Third-party dependency / longevity.** Decryptability depends on the drand
   network continuing to operate the *quicknet* chain. If that chain were
   retired or the network shut down, sealed data could become **permanently
   unrecoverable**. Mitigations: drand is decentralized (many operators) and has
   run since 2023; one can also run a private relay. Still a real long-term risk
   — not ideal for irreplaceable archival data.
2. **Internet required to unlock.** No connectivity during your window = no
   access until you're back online.
3. **No emergency override, ever.** Sealed-until-4am means 4am or nothing, even
   for a genuine emergency. By design.
4. **Time-lock provides no secrecy after expiry.** Once `T` passes, the outer
   layer is public; secrecy then rests entirely on the inner password layer
   (hence the two-layer design).
5. **Window-end not cryptographically enforceable** (see §6). Only the *start*
   of access is hard; the *end* relies on the app re-sealing.
6. **Full access during an open window.** A commitment device can't stop you
   from copying plaintext out while it's legitimately open.
7. **Forgotten password = lost data.** No recovery path, by design.
8. **Metadata leak (minor).** Fetching a round value reveals you're decrypting
   around now; it never reveals the contents.
9. **Clock/round mapping correctness.** Sealing targets a computed beacon round;
   the library handles this, but config (genesis/period) must match the chain.

### 7a. Why historical backups are forbidden
Each saved file is time-locked to *that save's* next-window-start. A backup kept
from an earlier session is therefore sealed to a target time **already in the
past**, so its time-lock has expired — it can be opened **anytime, outside any
window, with only the password.** A history of backups is thus a pile of escape
hatches that silently defeat the whole commitment. Hence: exactly **one** backup,
always overwritten and always carrying the same *future* target as the live
vault. No dated copies, no version history, and the user should not manually copy
the vault file elsewhere mid-cycle for the same reason.

### Is it a free service?
**Yes — fully free.** drand/League of Entropy is a public good: no account, no
API key, no cost. `tle` and the tlock libraries are open-source (Apache-2.0).
The only "cost" is the no-SLA dependency risk in (1)/(2) above.

---

## 8. Settled decisions (previously open)

- **Windows per day:** **multiple windows supported.** User defines any number of
  daily `start`–`end` windows (example: a single `04:00–05:00`).
- **Backup retention:** **1** — a single same-target redundant copy, overwritten
  each save (see §2, §7a). No version history.
- **Durability stance:** **zero fallback, zero weakening.** No escape hatch, no
  password-only copy. drand-down or forgotten password = permanent no-access, by
  design. The owner accepts the drand-longevity risk (§7 item 1) as the price of
  a truly binding commitment.

---

## 9. Proposed implementation

- **UI / app shell:** Swift + SwiftUI, packaged as a `.app` bundle (buildable
  with Command Line Tools; no full Xcode required). Handles windows config,
  password entry, the AES/Argon2id layer, scheduling, lock button, backups.
- **Crypto — inner layer:** CryptoKit (AES-256-GCM) + Argon2id for password→key.
  Argon2id via a **vendored reference C implementation pinned to an exact commit**
  (CryptoKit lacks Argon2); ship the **RFC 9106 test vectors** to prove the build,
  and **fail closed** on allocation failure (never silently downgrade). The GCM seal
  authenticates the PW01 header as AAD (§4).
- **Frozen constants — one machine-readable source of truth, not ceremonial docs.**
  The authority is a single canonical **`spec/constants.json`** (not the prose of
  `FORMAT.md`, which would be brittle to parse). Pinned before any fixtures exist (a
  range would let the impl drift and still "pass"), and guarded by a **consistency
  test** built the concrete way: small **Swift and Go "constant-dumper" programs**
  emit their compiled values as JSON, and the test compares those against
  `spec/constants.json` **and** the `FORMAT.md` constants table, **failing on missing
  key / extra key / type mismatch / value mismatch / malformed table / placeholder /
  any skipped test (unless allowlisted)**. We **check, not code-generate** (a codegen
  toolchain is unnecessary ceremony here); a mismatch fails `./run_tests`, so a
  correct doc can never sit beside wrong code. **The JSON also carries the
  security-critical drand identity/time constants** — `DRAND_CHAIN_HASH`,
  `DRAND_GROUP_PUBLIC_KEY`, `DRAND_GENESIS_UNIX = 1692803367`,
  `DRAND_PERIOD_SECONDS = 3`, `DRAND_SCHEME` — because the stale-round rule depends on
  genesis+period and chain-pinning depends on the hash+pubkey; left in Go-only prose
  they could drift from Swift. **Guard:** `constants.json` is a **build-time
  consistency check only** — the Go helper keeps these values **compiled-in/hardcoded**
  and never loads them from the JSON at runtime (a runtime-loaded chain hash would be
  a forged-chain escape hatch); the test asserts the compiled-in values *equal* the
  JSON, nothing more.
  `ARGON2_M_KIB = 1048576` (**1 GiB**), `ARGON2_T = 3`, `ARGON2_P = 4`,
  `ARGON2_VERSION = 0x13`, `ARGON2_OUTPUT_LEN = 32` — stronger than RFC 9106's
  memory-constrained profile on both memory and lanes; this protects the *thief of an
  expired blob* (post-expiry the password is the only secrecy layer — the owner knows
  the password, so the KDF isn't what stops the owner). **On-device benchmark gate:**
  Argon2 must complete reliably, allocation failure **fails closed** (never a silent
  downgrade), and unlock latency must be acceptable on this machine.
  `MAX_PASSWORD_BYTES = 1024`;
  `MAX_PLAINTEXT_NOTES_BYTES = 1 MiB`; `MAX_SEALED_PAYLOAD_BYTES = 2 MiB`;
  `MAX_STDOUT_BYTES = 4 MiB` / `MAX_STDERR_BYTES = 64 KiB`; and the policy constants
  pinned to **concrete numbers** (at quicknet's 3 s/round): `HELPER_TIMEOUT_MS = 10000`
  (~10 s), `FRESHNESS_MARGIN_ROUNDS = 20` (~60 s), `MIN_LOCK_DURATION_ROUNDS = 1200`
  (~1 h floor), `STALE_ROUND_TOLERANCE_ROUNDS = 10` (~30 s; absorbs network latency +
  clock skew). All fixed at build time (the crypto constants are golden-fixture-
  critical; the policy ones are tunable but frozen per build, never runtime-variable
  — no symbolic placeholders reach code or tests).
  **Argon2id only — no PBKDF2 fallback** (greenfield, no legacy vaults to import);
  the PW01 version byte allows a future KDF swap if ever needed.
- **Password→bytes encoding (pinned in `FORMAT.md`):** the password becomes key
  material as **UTF-8, no trimming, no Unicode normalization, reject empty, with a
  sane max byte length**; the confirm-password field compares the **exact byte
  sequence** after the identical encoding path — so "same-looking but different
  bytes" can never silently produce an unopenable vault.
- **Password quality (the only post-expiry secrecy layer).** Enforce a **minimum
  length (~12 chars)** and show a **blunt warning** on a weak password — a
  lightweight length/variety heuristic, **not a vendored zxcvbn** (an extra
  dependency + attack surface a zero-fallback vault doesn't need). No KDF rescues a
  trivial password against a thief who has the expired blob and the public params.
- **Crypto — outer layer:** a tiny custom **Go helper** (`vaultseal`, built on the
  `drand/tlock` library) compiled for `arm64-darwin` and **bundled inside the
  `.app`**. Hardened contract: **stdin → stdout only** (the `manifest + PW01` payload
  is piped, never written to disk); commands limited to `seal --round N` / `unseal` /
  `current-round`; **no file-path or network flags exposed**; **chain hash and
  drand endpoints hardcoded** (`api.drand.sh` + failover — each must be allow-listed
  by any content filter to help); no plaintext logging. **The helper is a security API, not a
  CLI:** errors are a **closed set of machine-readable JSON codes on stderr** —
  `round_not_ready`, `round_too_near`, `stale_round`, `auth_failed`, `parse_error`,
  `chain_mismatch`, `timeout` (the **helper error domain**, distinct from the
  core/format domain in §4) — and **Swift switches only on that closed set; any
  unknown code ⇒ fail closed.** The Swift→helper boundary mapping is explicit and
  total: known code → its specific fail-closed action; unknown code → fail closed;
  malformed/oversized stderr → fail closed; non-zero exit without valid JSON → fail
  closed; and **any stdout payload present alongside an error → fail closed** (a
  success payload is only ever trusted on a clean zero exit with no error).
  `current-round` returns the drand-client-**verified** latest round so Swift can
  compute the target and **refuse to seal to a round ≤ latest + margin** — trusted
  time without a bespoke Swift BLS verifier (see §11). **The helper enforces the same
  freshness invariant itself**: `seal --round N` independently fetches the verified
  current round and **rejects any round ≤ latest + margin** (past, current, or too-
  near), so a Swift-side bug cannot seal to an already-openable target — the trusted-
  time rule holds on both sides, not just in Swift. **Stale-drand defense (authentic
  ≠ recent):** a signature-valid round only proves it was *real*, not *current*; the
  helper additionally requires the verified latest round to be **fresh enough vs the
  round expected from pinned genesis/period + the local clock**, by this exact rule
  (pinned in `FORMAT.md` / `SECURITY_INVARIANTS.md`, not prose):
  `expectedRound = floor((nowUnix − genesisUnix) / periodSeconds)`; if
  `verifiedLatestRound < expectedRound − STALE_ROUND_TOLERANCE_ROUNDS` ⇒ `stale_round`.
  The local clock is used **only for this reject path (fail-closed) — never to grant
  access**. The check is deliberately **one-sided**: a round *ahead* of real time
  can't be forged (future rounds need a threshold signature that doesn't exist yet),
  and a backward clock only lowers the floor without letting the attacker seal to a
  past target (the target is computed from the verified round, not the clock) — and a
  standard account can't move the clock backward anyway. When multiple endpoints
  respond, use the **maximum verified round seen**, not the first success, so one
  lagging mirror can't drag perceived-latest into the past. **Chain pinning:** hardcode the
  quicknet chain hash **and the group public key**, and have the drand client
  **verify that fetched chain-info hashes to the pinned chain hash** before use — this
  transitively validates genesis/period/scheme (the chain hash is a hash *of* that
  info), so a wrong or malicious endpoint can't substitute a different network without
  hardcoding each field separately. Go deps pinned **and enforced, not advisory**:
  `go.mod` exact versions of `drand/tlock` + the drand client, committed `go.sum` +
  `vendor/`, and `build.sh` builds with **`go build -mod=vendor`**, runs
  **`go mod verify`**, and **fails if `vendor/` is missing or dirty** (checksum the
  vendor tree; under git also `git diff --exit-code go.mod go.sum vendor/`).
- **Subprocess hardening (Swift → helper):** invoke the helper by its **absolute
  bundled path only** — never via `PATH`, the working directory, or a shell
  (`/bin/sh`); pass a **minimal sanitized environment**; **cap stdout/stderr size**
  and **time out** every call, treating a timeout as **fail-closed**; verify the
  helper's executable bit and a **pinned hash of the bundled binary on every launch**
  (cheap integrity check — catches accidental corruption / low-effort tampering;
  per §11 this is integrity, not a commitment boundary). The expected hash is
  **compiled into the Swift binary (or build-generated source), never read from a
  writable sidecar** next to the helper — a sidecar an adversary could edit would
  make the check worthless.
- **Storage:** single vault file in
  `~/Library/Application Support/EncryptedVault/vault.dat`; one redundant copy
  `vault.dat.bak` in the same folder, overwritten on every save with identical
  sealed bytes (same target). No `backups/` history folder. Directory `0700`,
  files `0600`.
- **OS/versioned backups are the same escape hatch as a dated `.bak`.** A vault from
  an earlier session, captured by Time Machine, an APFS local snapshot, or a cloud
  sync's version history, is sealed to a now-*past* round → password-only openable →
  defeats the commitment exactly like a historical `.bak` (§7a). Defense (no admin
  needed): set **`isExcludedFromBackup` (`NSURLIsExcludedFromBackupKey`)** on the
  vault directory at creation — this excludes it from Time Machine *and* iCloud — and
  verify the attribute at launch. What that attribute can't guarantee (pre-existing
  APFS snapshots, an admin/MDM-forced backup policy, third-party cloud sync of the
  folder) gets a **hard setup warning + explicit manual confirmation**, plus the
  instruction never to place the vault in a synced folder (Desktop/Documents/Drive/
  Dropbox). Honest scope: like the in-window copy ceiling, a determined owner can
  still arrange an external capture; this closes the *accidental/automatic* hatch.
- **Durable, escape-hatch-free writes (every step tmp+rename, never a direct copy):**
  write `vault.dat.tmp` → `F_FULLFSYNC` → **delete old `.bak`** → `rename` over
  `vault.dat` (`F_FULLFSYNC` file + dir) → write `vault.dat.bak.tmp` → `F_FULLFSYNC`
  → `rename` over `.bak` (`F_FULLFSYNC` dir). A direct copy could leave a *partial*
  `.bak` that later looks meaningful; tmp+rename never exposes one. On macOS plain
  `fsync` does **not** flush to the platter — use **`fcntl(F_FULLFSYNC)`** (this app
  trades speed for durability). A crash may lose redundancy but never leaves an
  expired `.bak` beside a future-sealed primary (§6).
- **Post-write verification.** After committing, **re-parse both files**, confirm the
  intended byte-equality invariant (primary and `.bak` are the same sealed bytes), and
  re-check `0600` / owner / not-a-symlink / `st_nlink == 1` — so the writer never
  *leaves* an ambiguous state for recovery to untangle later. Fail-closed recovery on
  any `vault.dat`/`.bak` disagreement.
- **Path / inode hardening (adversary is the owner).** Treat `vault.dat` and `.bak`
  as possibly tampered: **`lstat` and refuse symlinks** (open with `O_NOFOLLOW`);
  **verify owner == current uid and mode is exactly `0600`** (reject group/world-
  readable); create the temp file **only inside the vault directory** and `rename`
  **only within that same directory**; treat an **unexpected hard-link count
  (`st_nlink > 1`)** as tampered. This stops "future me" from turning `.bak` into a
  symlink/hardlink so the delete-old-`.bak` step preserves a stashed expired copy.
- **No durable plaintext leakage (SwiftUI text editing is a live risk, not solved).**
  Never log/print the password, PW01 bytes, or decrypted JSON; **disable AppKit state
  restoration, editor autosave, and undo persistence**; on the notes/secret fields
  **disable spellcheck, grammar, data-detectors, and text substitutions** (these can
  ship text to system services or on-disk caches); **no recent-documents**; write no
  plaintext temp/diagnostic/editor-cache files; and disable process **core dumps
  (`setrlimit(RLIMIT_CORE, 0)`)**. If `TextEditor` can't be fully locked down, drop to
  a custom **`NSTextView` (`NSViewRepresentable`) wrapper** to control the text
  system. Scope (honest): in-memory `String` copies during an *open* session are
  unavoidable in SwiftUI and out of scope — the standard account already blocks
  swap/other-process reads (§11); the gate is **no durable plaintext after quit or
  crash**.
- **drand health check at unlock (no migration engine yet).** The format is already
  forward-migration-capable — VLT1 `version`, PW01 `version`, manifest
  `formatVersion`, and the per-blob `chainHash` are all stored, and the existing
  interactive re-seal (§6) already re-wraps forward during an open window. So v1
  adds only a **lightweight health check** when a window opens (confirm the live
  quicknet chain-info still matches the pinned values; warn on helper/dependency
  version drift) — not a separate automated chain-migration subsystem (YAGNI for
  v1, and extra bug surface in a zero-weakening vault).

### Environment verified on this machine
- Swift 6.2.4, SwiftUI + CryptoKit + CommonCrypto link with Command Line Tools.
- Go 1.26.3 (to build the `vaultseal` helper).
- drand quicknet reachable (period 3s) over HTTPS.

---

## 10. Suggested build order

1. Minimal scaffold + test harness only (no `.app` packaging yet). **Deliverable
   docs first:** `FORMAT.md` (bytes-on-paper spec, §4) and `SECURITY_INVARIANTS.md`
   (the non-negotiables: fail-closed everywhere, unseal-as-gate, manifest-as-truth,
   trusted time both sides, no escape-hatch `.bak`, uncertainty ⇒ deny). Acceptance
   rule: **`FORMAT.md` exists before any parser code; any fail-open behavior is a
   release blocker; any uncertainty defaults to deny, never "try recovery."** Also
   **freeze the exact constants** in a canonical **`spec/constants.json`** (Argon2
   1 GiB/t=3/p=4/v0x13/out32, max-size caps, helper timeout, lock-duration + freshness
   margins, **plus the drand identity/time constants — chain hash, group pubkey,
   genesis, period, scheme**) before fixtures exist — a range lets the impl drift
   while still "passing." Add the **constants-consistency test** (Swift + Go
   constant-dumpers → JSON; compare to `constants.json` and the `FORMAT.md` table;
   fail on missing/extra/type/value/malformed/placeholder/skip; check, don't
   code-generate; helper keeps drand values compiled-in, JSON is check-only). Add a
   **Task-1 negative-scope guard** (a phase test, retired when Task 2 opens): fail if
   implementation source dirs, SwiftUI imports, or `.app` artifacts exist, or if
   parser/crypto symbol *definitions* (`parseVLT1`, `decodePW01`, `seal`, `unseal`…)
   appear outside docs/tests. **Acceptance:** `./run_tests` runs clean from a fresh
   checkout; `FORMAT.md` + `SECURITY_INVARIANTS.md` + `spec/constants.json` exist; the
   consistency test is real (not a placeholder); skipped/TODO tests fail the harness
   unless allowlisted; and **no parser, crypto, store, UI, or `.app` code is added
   yet.**
2. Inner crypto: Argon2id + AES-256-GCM + PW01, with **RFC 9106 vectors + tamper +
   AAD tests** + **on-device Argon2 benchmark** (alloc-fail ⇒ fail closed); password→
   bytes per `FORMAT.md` (UTF-8 / no-normalize / no-trim / reject-empty / max-len /
   exact-byte confirm) + **min-length + weak-password warning**.
3. VLT1 + manifest + PW01 parser/encoder **to `FORMAT.md`**: canonical, fixed-width
   LE integers, length-prefixed, bounded, fail-closed; round-trip + `outer ==
   manifest` tests. Unknown version ⇒ fail closed (single format version in v1).
4. Manifest commits the access interval `[targetStartRound, targetEndRound]`;
   access gated on verified round ∈ interval (not the mutable schedule).
5. Go `vaultseal` helper (`seal`/`unseal`/`current-round`) + integration tests.
6. Swift wrapper: verified round → target mapping, refuse non-future targets. Add a
   **dry-run seal/unseal** command **compiled only under `DEBUG`** — the release build
   **fails if any dry-run symbol/flag is present** and the shipped `.app` exposes no
   CLI surface. (The dry-run *interface* is DEBUG-only, but the underlying
   **`SelfTestEngine` ships in release** — the on-device first-run self-test calls it
   through the UI path, never a CLI/flag/hidden command; see Task 8.)
   *Milestone:* after steps 1–6, `./run_tests` is green (crypto + format + helper
   gates) **before** any vault-store code is written.
7. Schedule logic incl. **DST, midnight-crossing, adjacent/overlapping windows**,
   and **"too-near start skips forward"** — never compute a start the helper's
   `latest + margin` rule would reject (§5, §9).
8. Vault store — **the dangerous task; build it in small internal passes, not one
   shot:** (a) read/validate one file; (b) classify file state
   {missing, parse-corrupt, **future-claimed**, future-valid-after-ready,
   open-window-valid, expired-valid, tampered, bad-owner/mode/link/path}; (c) compare
   primary/`.bak` states; (d) choose the fail-closed action from an **enum-driven
   total decision function (no `default`/fallthrough; test asserts every combination
   is handled)** over the primary×`.bak` matrix (same- vs different-target; see §11);
   (e) the
   write transaction protocol; (f) failure-injection tests. Then interactive +
   **strictly passwordless defensive re-seal** (never prompts/decrypts/parses notes)
   on top.
9. Backup write protocol (delete-old-`.bak`-first) + **fail-closed recovery** +
   **path/inode hardening** (`O_NOFOLLOW`, refuse symlinks, verify owner+`0600`,
   reject `st_nlink > 1`, same-dir temp/rename), with stale-`.bak` /
   crash-during-each-write-phase / symlink-and-hardlink attack tests.
10. First-run setup: create vault, confirm password ×2, set schedule, then a
    **hard on-device self-test gate** that must pass *before any real secret is
    stored* — this is the runtime counterpart to build-time gates, run on the
    user's actual machine. It is driven by a shared **`SelfTestEngine` that ships in
    both release and debug** (release exposes it *only* through this first-run UI
    path — no CLI/flag/hidden command; DEBUG may additionally wrap it with developer
    dry-run surfaces). The engine performs: Argon2id RFC-vector check (catches alloc
    failure / wrong
    params on this hardware), **bundled `vaultseal` is executable + signature-valid +
    completes a real seal/unseal/`current-round` round-trip** (catches broken
    signing, quarantine, missing exec bit), and drand reachability through any content filter.
    Plus the data-loss warning. Build-time green does not imply this machine is green;
    refuse real secrets until it is. **Self-test must not leak:** throwaway random
    payload in a **separate temp dir** (never the real vault path), no real notes,
    cleanup + assert-deleted on success *and* failure. **Endpoint policy
    (deliberate): ≥1 endpoint reachable is the hard pass condition**
    (availability), but **strongly warn unless ≥2 independent endpoints pass** —
    a single reachable mirror is fragile when a filter's own password may live *inside*
    the vault; the setup screen states plainly "if your only working drand endpoint is
    later blocked, the vault will not open." Per-endpoint reachability is shown.
    Also **set + verify `isExcludedFromBackup` on the vault dir and hard-warn** about
    Time Machine / APFS snapshots / cloud sync it can't cover, requiring explicit
    confirmation (§9) — an automatic OS backup of an expired vault is an escape hatch.
11. SwiftUI: lock screen (locked-until vs. password), notes editor with
    masked/reveal secrets, **Lock button**, settings. Seal on graceful quit.
12. No-durable-plaintext-leakage pass: no secret logging; **state restoration,
    autosave, and undo persistence all off**; **spellcheck / grammar / data-detectors
    / substitutions off on secret fields**; **no recent-documents**; no plaintext
    temp/diagnostic/cache files; **core dumps disabled (`setrlimit(RLIMIT_CORE, 0)`)**;
    dir `0700` / files `0600`; **custom `NSTextView` (`NSViewRepresentable`) wrapper
    if `TextEditor` can't be fully locked down**. Gate = no durable plaintext after
    quit/crash.
13. `.app` bundling (Info.plist, bundle ID, embed + sign `vaultseal`) with
    build-script checks (`codesign --verify --deep --strict`, `otool -L`, `file`).
    **`build.sh` runs the §11 hard-gate tests first and refuses to assemble/sign the
    bundle if any are red** — so any `.app` produced by the official `build.sh` path
    has passed them (a process gate, not a crypto boundary). This is the concrete
    enforcement of "no real secrets until gates pass".
14. End-to-end test across a real window boundary (incl. force-kill mid-window and
    offline-at-unlock); final hardening review (§11).

---

## 11. Adversarial review & hardening

Reviewed from the perspective of *the owner in a weak moment*: same machine,
**standard (non-admin) account**, knows the master password, can run userspace
tools and edit their own config files, but **cannot** change the clock, read
swap, or self-elevate.

**Unifying test.** Out-of-window data is safe **iff** the on-disk file is sealed
to a genuinely *future* drand round **and** no copy made during a window
survives. The time-lock itself is unbreakable (you would have to break BLS), so
every exploit reduces to either: (1) get the file sealed to a *past* round, or
(2) keep an in-window copy.

| Corner | Status on a standard account | Handling |
|---|---|---|
| Roll clock back → seal to a past round | 🟢 Neutralized — can't change clock without admin | Trusted-time defense below anyway |
| Edit schedule + force-kill → grant out-of-window access | 🟢 Neutralized — open-vs-reseal uses the committed interval, not mutable config | Commit `[start, end]` in manifest (DiD #2) |
| Swap / other-process memory residue | 🟢 Blocked — root-owned | — |
| Saved App State / autosave residue | 🟠 User-space, real | Disable state restoration & autosave; no plaintext temp files; dir `0700` / files `0600` |
| Copy file / plaintext during window | 🔴 Inherent ceiling — privilege-independent | Accepted by owner; clipboard / screen-capture defenses explicitly **out of scope** (§2) |
| Stale `.bak` after a crash | 🟠 | Defensive re-seal overwrites *both* files |
| Symlink/hardlink `vault.dat`/`.bak` to preserve a stashed expired copy | 🟠 User-space, real | Path/inode hardening: `O_NOFOLLOW`, refuse symlinks, verify owner+`0600`, reject `st_nlink > 1`, same-dir temp/rename (§9, DiD #5) |
| OS/versioned backup (Time Machine, APFS snapshot, cloud sync) keeps an expired vault | 🟠 Accidental/automatic, real | `isExcludedFromBackup` on the vault dir (no admin) + hard setup warning for what it can't cover (§9); raw-quarantine ban (DiD #6) |

**Defense-in-depth (implemented regardless of the no-admin assumption):**
1. **Trusted-time seal target.** Compute the seal target from the drand-client-
   **verified** latest round reported by the helper — never the local clock or an
   HTTP `Date` header; **refuse to seal to a round ≤ latest + margin** (a target
   can never already be openable); enforce a minimum lock duration. This is
   enforced **on both sides** — Swift computes the target, and the helper's `seal`
   independently re-checks freshness and rejects a stale/too-near round — so no
   single bug can produce an already-openable seal. **Authentic ≠ recent:** a
   signature-valid round only proves it was real, so the helper also rejects a
   round that is *stale* vs the clock-derived expectation (`stale_round`), using the
   local clock **only to reject** (fail-closed), never to grant — safe because a
   standard account can't move the clock backward; and it takes the **max verified
   round** across endpoints. Verification lives in the helper's drand client (chain
   pinned by hash **and** group public key) — no bespoke Swift BLS verifier.
   (Insurance should the owner ever gain admin.)
2. **Committed access interval in the tlock-sealed manifest.** The manifest commits
   `[targetStartRound, targetEndRound]` *inside the tlock layer but outside the
   AES/password layer*, so it is readable after a tlock-unseal **without the
   password** — which lets the passwordless defensive re-seal (§6) update it
   without bricking outer/manifest consistency. (Storing it in the AES plaintext
   would make passwordless re-seal impossible.) Authorization to open is gated on
   `start ≤ verifiedRound ≤ end` **from the manifest, never the mutable schedule**,
   so editing the schedule cannot convert an expired seal into access. Honest
   scope: this removes the *low-friction in-app* bypass; after a crash the past-
   sealed blob is still decryptable by deliberate manual tooling (§6). **Anti-
   shortening invariant:** while the on-disk target is still *future*, launch never
   unseals or rewraps; the interval is recomputed **only** once the seal has
   *expired*, where it can only move protection forward.
3. **Fresh AES-GCM nonce on every save** (reusing a key+nonce under GCM is fatal),
   and the **PW01 header is authenticated as GCM associated data** so tampering
   with KDF params/salt fails at the tag rather than mis-parsing.
4. **Defensive re-seal covers both `vault.dat` and `vault.dat.bak`** (each via
   durable fsync→rename).
5. **Escape-hatch-free backup ordering.** Delete the old `.bak` before committing a
   freshly future-sealed primary, then recreate it — a crash may lose redundancy
   but never leaves an expired (password-only-openable) `.bak` beside a future
   primary (§6).
6. **Fail-closed recovery + no-raw-quarantine.** On `vault.dat`/`.bak` disagreement,
   prefer the most-locked valid copy; offer no access if any surviving copy is
   future-sealed; **re-seal expired-but-valid copies forward first** (§6). Crucially,
   **never preserve a raw copy of a blob that has successfully time-unsealed and is
   past/open/expired** — that is just another historical escape hatch. Tamper
   "quarantine" keeps **only a hash + diagnostic record**, not the decryptable bytes;
   if a valid expired copy exists alongside a tampered one, deny the prompt but still
   **re-seal the valid copy forward** so no openable copy is left behind.

**Recovery decision matrix (primary × `.bak`).** The table below is *illustrative*;
Task 8 requires this as a **real enum-driven total decision function — no `default`
/ fallthrough — with a test asserting every (primary × `.bak`) combination has an
explicit decision** (not "infer the rest"; an unhandled combination must fail to
compile or fail closed, never silently allow). The full state set —
`missing`, `parse-corrupt`, **`future-claimed`** (sealed to a future round — cannot
yet be verified, so *untrusted*, **not** "future-valid"), `future-valid-after-ready`,
`open-window-valid`, `expired-valid`, `tampered (outer≠manifest once ready)`,
`bad owner/mode/link/path` — **crossed with same-target vs different-target**. The key
rename matters: *(`outer == manifest` is only checkable after a successful unseal;
while a seal is still `future-claimed` we cannot distinguish a lying VLT1 from an
honest one — the answer is "no access" either way.)*

| primary | `.bak` | action |
|---|---|---|
| future-claimed | expired-valid | locked, **no prompt** (any future copy ⇒ no access) |
| expired-valid | future-claimed | locked, **no prompt** |
| expired-valid | missing | **defensive re-seal** forward |
| parse-corrupt | future-claimed | locked; treat `.bak` as the live copy |
| tampered (`outer≠manifest` once ready) | expired-valid | **deny prompt; hash/diagnostic-only quarantine (never raw bytes); re-seal the valid `.bak` FORWARD** |
| both expired-valid, **different** targets | **re-seal forward first**, then access per window |
| both corrupt / both missing | **no access** (fail closed) |

**The honest ceiling.** This is a strong defense against *impulsive* weak-moment
access — the out-of-window wall is real cryptography. It is **not** an absolute
cage against a *premeditated* owner during an open window, who can always retain
a copy; that limit is true of every commitment device and cannot be engineered
away locally. It is mitigated socially by a trusted third party holding the admin-password
backup. **Code-signing and the on-device self-test are integrity checks** — they
catch broken builds, quarantine, and accidental tampering; they are **not** a
commitment boundary against a premeditated owner who can replace the `.app`/helper
in its user-writable location *before* a future allowed window. That does not break
"cannot open before the window" (the blob stays future-sealed regardless of which
binary is present); it only falls inside the already-accepted open-window ceiling.

**Required tests (hard gates before any real secret goes in).** `build.sh` refuses
to assemble/sign the `.app` unless these are green — so any `.app` produced by the
official `build.sh` path has passed them (a process gate, not a crypto boundary).
- Argon2id RFC 9106 vectors; AES-GCM ciphertext-tamper + AAD-tamper rejection.
- **Constants consistency:** Swift + Go constant-dumpers and the `FORMAT.md` table
  all compare equal to the canonical `spec/constants.json` (including the drand
  chain hash / group pubkey / genesis / period / scheme); the test fails on
  missing/extra/type/value/malformed/placeholder — a correct doc can't sit beside
  wrong code.
- **Negative-scope (Task-1 phase guard):** no implementation source dirs, SwiftUI
  imports, `.app` artifacts, or parser/crypto symbol definitions exist before Task 2.
- **No silent-skip:** a skipped or TODO test **fails `./run_tests`** unless it is in
  an explicit allowlist — a green run can never mean "tested nothing."
- **Argon2 on-device benchmark:** completes reliably at the frozen params, allocation
  failure **fails closed** (no silent downgrade), unlock latency within budget.
- **Password quality:** below-minimum length rejected; weak password warned before
  acceptance.
- **No dry-run in release:** release build fails if any dry-run symbol/flag is present;
  the `.app` exposes no CLI/URL surface.
- **Golden binary fixtures**, not just round-trips: byte-exact encode/decode for the
  deterministic parts (PW01 with pinned salt+nonce, manifest, VLT1 framing) so a
  buggy encoder+decoder can't agree on a wrong format; **decode-only** fixtures for a
  full tlock-sealed vault (sealing is non-deterministic, so not byte-reproducible).
- Strict parse: unknown / duplicate / trailing bytes and out-of-bound lengths all
  rejected; every parse-failure path denies access. **Parser tests must include
  hand-authored malformed byte sequences, not only mutations of encoder output** —
  round-trip-only tests hide a shared wrong assumption between encoder and decoder.
- **No partial plaintext on auth failure:** a wrong password → GCM tag failure →
  **no plaintext object constructed, no editor state populated, no partial-notes
  recovery attempt** — the failure is total and silent of contents.
- `outer == manifest` mismatch on **any** of `chainHash` / `start` / `end` (or an
  unsupported version) → fail closed; and `VLT1.payloadLen` ≠ actual sealed-payload
  length → fail closed at parse. Both VLT1-tamper directions: future-while-expired ⇒
  mismatch fail-closed (quarantine, no re-seal); past-while-future ⇒ round-not-ready,
  locked, no prompt.
- Edit schedule outside the committed window → cannot create access.
- Stale expired `.bak` → never used as a password-only bypass.
- **Write-protocol failure injection** (via a file-op seam): force-kill *and*
  simulated failure of `vault.dat.tmp`-write / `F_FULLFSYNC` / delete-old-`.bak` /
  rename-over-`vault.dat` / dir-`F_FULLFSYNC` / `vault.dat.bak.tmp`-write /
  rename-over-`.bak` / chmod — after each, the store must be **either the old intact
  state or the new intact future-sealed state**. (Precise: a pre-rename crash may
  leave the *old* file, which can be expired/open-window-valid — that is "valid" but
  **not "locked"**; the next launch must then **defensively re-seal it before any
  prompt**.) The protocol must **never create an additional expired copy beside a
  future-sealed copy**, a partial-but-accepted file, or a silent success.
- Launch with `verifiedRound > targetEndRound` → defensive re-seal, not a prompt.
- **Force-kill *after* a successful tlock-unseal but *before* password entry** →
  nothing was written, on-disk blob is still past-sealed → next launch performs the
  defensive re-seal (or stays fail-closed if the committed end has not yet passed),
  never silently grants access.
- **Path/inode tampering:** `vault.dat` or `.bak` is a symlink, a hardlink
  (`st_nlink > 1`), or group/world-readable / wrong-owner → rejected, fail closed;
  delete-old-`.bak` must not follow a symlink to a stashed copy.
- **Recovery matrix totality:** a test enumerates **every** (primary × `.bak`) state
  pair and asserts each maps to an explicit decision — no `default`, no fallthrough,
  no silently-allowed combination.
- **No raw expired escape hatch:** tamper quarantine stores only a hash/diagnostic,
  never raw unsealed bytes; a valid expired copy beside a tampered one is **re-sealed
  forward**, not left openable; the vault dir carries `isExcludedFromBackup` and the
  attribute is re-verified at launch.
- DST / timezone, midnight-crossing, adjacent and overlapping windows.
- **Too-near start skips forward:** Lock/re-seal moments before a window opens →
  the computed start clears `latest + margin` and min-duration (skip to the next
  valid window), so the schedule never hands the helper a round it will reject.
- Offline at unlock → fail closed (no prompt if tlock can't verify/unseal).
- **On-device first-run self-test gate** (the runtime counterpart to these build
  gates): refuse to store any real secret until Argon2id RFC vectors pass *on this
  machine*, the bundled `vaultseal` is executable + signature-valid + completes a
  real seal/unseal/`current-round` round-trip, and **at least one** configured drand
  endpoint is reachable (unreachable configured endpoints produce
  visible warnings, not a hard failure — matches §10's deliberate availability call).
- **No durable plaintext after quit/crash**: state restoration / autosave / undo
  persistence off, **spellcheck / grammar / data-detectors / substitutions off on
  secret fields**, no recent-documents, no plaintext temp/diagnostic/cache files, core
  dumps disabled.
- **Durable-write specifics:** writes use `F_FULLFSYNC` (not bare `fsync`); `.bak` is
  written tmp+rename (never a direct copy); post-write re-parse confirms byte-equality
  and `0600`/owner/no-symlink/`st_nlink==1`.
- `vaultseal` **negative CLI contract**: `--in <file>`, `--endpoint <host>`,
  `--chain <other>`, `--url …`, and any unknown flag → non-zero exit, JSON error on
  stderr, no stdout payload, no file touched (forbidden bypass surfaces stay shut).
- `vaultseal` **helper-side round rejection** (trusted time isn't Swift-only):
  `seal --round <past>` fails, `seal --round <latest>` fails, and
  `seal --round <latest+1>` fails when below the configured margin — each a non-zero
  exit with a JSON error and no sealed output.
- **Stale-drand rejection:** a signature-valid but *stale* "latest" round (older than
  the clock-derived expectation by more than tolerance) → `stale_round`, no seal; and
  with several endpoints the **max verified round** is used, not the first reply.
  Swift treats any **unknown error code as fail-closed**.
- **Defensive re-seal is strictly passwordless:** it must **never** prompt, AES-
  decrypt, parse notes, or construct plaintext — only `unseal → parse manifest+PW01
  bytes → new manifest → reseal`. A test asserts no decrypt/prompt path is reachable.
- **Vendor enforcement:** build fails when `vendor/` is missing/dirty or
  `go mod verify` fails (pinning is enforced, not advisory).
- `vaultseal` on a future-sealed blob from a terminal → stays cryptographically
  locked (proves the wall is crypto, not an app guard).
- **Subprocess invocation:** helper called by absolute bundled path, never a shell;
  a hung helper hits the timeout and is treated **fail-closed**; oversized
  stdout/stderr is capped; a tampered/corrupt helper binary fails the launch hash
  check.
- **First-run self-test isolation:** the release-shipped `SelfTestEngine` runs in a
  separate temp dir with a throwaway payload, never writes the real vault path, and
  leaves **no plaintext artifact** on success or failure. A test asserts the engine
  is reachable in a release build **only** via the first-run UI path — no CLI, flag,
  env var, or hidden command exposes it (the dry-run wrappers around it are
  `DEBUG`-only and absent from the release binary).

**Biggest practical risk: implementation bugs**, not the design — custom crypto
glue, the two-file write protocol, recovery, and schedule logic are where first-
pass defects hide (vault corruption, an escape-hatch `.bak`, or plaintext leaking
to disk). Mitigation: the gate tests above before trusting real data.

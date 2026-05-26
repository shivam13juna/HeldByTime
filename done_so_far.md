# done_so_far.md — implementation handoff (Tasks 1–3)

This document plus `app.md` (the full design), `FORMAT.md` (the byte spec),
`SECURITY_INVARIANTS.md` (the non-negotiables) and the codebase should be enough to
pick up at **Task 4 (Swift seal/unseal wrapper + trusted time — the ⏸ milestone)** and
continue.

- **Read order for a new developer:** `app.md` §1–§11 → `SECURITY_INVARIANTS.md` →
  `FORMAT.md` → this file → the source.
- **Task tracker / build order:** `app.md` §10 (12 tasks). Tasks 1 and 2 are done.
- **Golden rule still in force:** Tasks 1–4 must be green on `./run_tests` before any
  vault-store (Task 6) or UI (Task 9) code. Any fail-open is a release blocker.

---

## How to build and test (everything)

```sh
./run_tests        # the one command. Exit 0 = green. Bash (has a #!/usr/bin/env bash shebang).
```

What it does, in order (each step prints `RESULT: PASS|FAIL <name>` lines). Step
numbers match the `# ----` comments in `run_tests`:

1. **Phase guard** — fails if a SwiftUI/AppKit/Cocoa import appears (forbidden before
   Task 9) or a `.app` bundle exists (forbidden before Task 11). *(The stricter Task-1
   negative-scope guard — "no crypto/parser code yet" — was retired when Task 2 opened,
   as planned.)*
2. **Placeholder scan** — fails on `TODO|FIXME|XXX|PLACEHOLDER|HACK` in deliverables
   (scans `FORMAT.md SECURITY_INVARIANTS.md spec Sources Tools helper tests`,
   **excluding `vendor/`**; not `app.md`/`run_tests`).
3. **Swift constant dumper** build+run → `build/constants-swift.json`.
4. **Go constant dumper** build+run → `build/constants-go.json`.
5. **Constants consistency** (`tests/consistency_check.swift`) — parses
   `spec/constants.json`, both dumps, and the `FORMAT.md` constants table; fails on any
   missing/extra key, type/value mismatch, or malformed table.
5b. **Helper vendor integrity + build** (Task 3) — `go mod verify`, then
   `go build -mod=vendor` of `cmd/vaultseal` and `cmd/hermetictests`. The `-mod=vendor`
   build fails on "inconsistent vendoring" — that is the dirty/missing-vendor guard.
5c. **Helper hermetic tests** — runs `build/hermetictests` with the network black-holed
   to a dead proxy (proves it needs no network): real-beacon round-trip, fail-closed
   behaviours, and 13 negative-CLI cases.
5d. **Helper unit tests** — `go test -mod=vendor ./internal/...` (the `httptest` coverage
   of the real `drandnet` HTTP layer, incl. the `chain_mismatch` defense).
6. **Argon2id static lib** — `clang` builds the vendored portable `ref` build +
   `Sources/CArgon2/shim.c` into `build/libargon2.a`.
7. **Test binary** — `swiftc` compiles `Sources/Constants` + `Sources/VaultCore/*` +
   `tests/{test_support,format_suite,argon2_suite,main}.swift`, linked against
   `libargon2.a` and the `CArgon2` module → `build/vault_tests`, then runs it.

**Aggregation rule:** exit 0 only if zero `FAIL` lines and zero un-allowlisted `SKIP`
lines (`tests/skip-allowlist.txt`). `RESULT: INFO` lines are informational (e.g. the
Argon2 benchmark timing) and not counted.

**Toolchain prerequisites:** Swift/clang (Command Line Tools), **Go 1.26+**. The whole
harness is **offline**: the Go deps build from the committed `helper/vendor/` via
`-mod=vendor` (no module download, even on a clean machine), and the helper tests are
hermetic by construction. Network is only needed if you *change* Go deps (re-run
`cd helper && go mod tidy && go mod vendor`).

### Test-harness conventions (reuse these for new suites)
- Test binaries print `RESULT: PASS|FAIL|SKIP|INFO <name> [-- detail]` to stdout and
  exit non-zero on any failure.
- `run_exec EXE NAME [args...]` (a bash function in `run_tests`) runs a binary, collects
  its `RESULT:` lines, and — crucially — emits a `FAIL <name>/exit` if the binary exits
  non-zero **without** a `FAIL` line (catches crashes/traps that would otherwise be
  silent because buffered stdout is lost on a trap; `tests/main.swift` also sets
  `setvbuf(stdout, nil, _IONBF, 0)` so partial output survives a trap).
- Two patterns are now in use, both fine to copy:
  - **RESULT-line binary** (Swift `vault_tests`, Go `cmd/hermetictests`): prints its own
    `RESULT:` lines; the harness `run_exec`s it.
  - **Plain `go test`** (`internal/drandnet`): the harness runs `go test` and emits a
    single `RESULT: PASS|FAIL helper/go-test` from its exit code, dumping the log on fail.

---

## Repository layout (after Task 3)

```
app.md                      full design (authoritative intent)
FORMAT.md                   byte-on-paper spec + machine-checkable constants table
SECURITY_INVARIANTS.md      14 numbered invariants (I1..I14) + honest ceiling
done_so_far.md              this file
run_tests                   the harness (bash)
.gitignore                  ignores /build, *.app, helper binaries

spec/constants.json         ★ SINGLE SOURCE OF TRUTH for all frozen constants
Sources/
  Constants/Constants.swift     Swift mirror of constants (checked, not generated)
  CArgon2/                       C module bridging vendored Argon2 to Swift
    include/module.modulemap
    include/vault_argon2.h       declares vault_argon2id()
    shim.c                       builds argon2_context, calls argon2id_ctx()
  VaultCore/                     ★ the crypto/format core (pure Swift + CryptoKit + CArgon2)
    Errors.swift                 closed core/format error domain (VaultFormatError)
    Bytes.swift                  LE ByteReader/ByteWriter (bounds-checked) + Hex
    PW01.swift                   AES-256-GCM notes container (seal/open)
    Manifest.swift               54-byte authoritative window record
    VLT1.swift                   outer container framing (untrusted display header)
    Argon2.swift                 Argon2.raw(...) binding (any nonzero rc => throw)
    KeyDerivation.swift          deriveKey(password,salt) at frozen 1 GiB params
    HelperRunner/HelperWire/TrustedTime/VaultSealClient/SelfTestEngine/DryRun.swift  (Task 4)
    Schedule.swift               (Task 5) daily windows -> next lock target
    SecureFile.swift             (Task 6) path/inode-hardened read + durable write tx
    VaultStore.swift             (Task 6) classify / total decide matrix / load / re-seal
    SecureRandom.swift           (Task 7) system-CSPRNG salt/nonce source
    VaultSession.swift           (Task 7) open vault: interactive re-seal triggers (Lock/quit/window-end)
    PasswordPolicy.swift         (Task 8) password→bytes rules (encode/validate/confirm/weak-warning)
    SelfTestEngine.swift         (Task 8 ✅) full on-device gate over an injectable SelfTestServices
    FirstRunSetup.swift          (Task 8) the gated create-vault flow (engine; no SwiftUI)
Tools/
  constdump-swift/main.swift     emits Swift constants as JSON (consistency test)
helper/                          ★ Go module "vaultseal" (go 1.26) — the drand-facing helper
  go.mod / go.sum                pinned deps (tlock/drand/kyber/age); see Task 3
  vendor/                        committed, pinned dependency tree (15 modules); -mod=vendor
  internal/constants/constants.go  Go mirror of constants + check-only All map
  internal/wire/errors.go        closed helper error domain + JSON-on-stderr encoder
  internal/drandnet/network.go   self-implemented tlock.Network over stdlib net/http
  internal/drandnet/network_test.go  httptest coverage of the real HTTP layer
  internal/seal/seal.go          seal / unseal / current-round logic
  cmd/vaultseal/main.go          the helper binary (strict CLI; stdin->stdout; seal/unseal/current-round/endpoints)
  cmd/hermetictests/main.go      offline RESULT-line test harness (fake net + real-beacon KAT)
  cmd/constdump/main.go          emits Go constants as JSON
vendor/argon2/                   pinned phc-winner-argon2 (ref build) + PINNED.txt + LICENSE
tests/
  consistency_check.swift        standalone constants comparator (own executable)
  test_support.swift             shared RESULT harness (pass/fail/check/expectThrow)
  format_suite.swift             runFormatSuite()  — Task 2a tests
  argon2_suite.swift             runArgon2Suite()  — Task 2b tests
  helper_suite.swift             runHelperSuite()  — Task 4 tests
  schedule_suite.swift           runScheduleSuite()— Task 5 tests
  store_suite.swift              runStoreSuite()   — Task 6 tests (FakeSeal offline)
  session_suite.swift            runSessionSuite() — Task 7 tests (reuses FakeSeal)
  setup_suite.swift              runSetupSuite()   — Task 8 tests (PasswordPolicy + self-test + first-run, offline)
  main.swift                     entry point: runs all suites
  skip-allowlist.txt             allowed SKIP names (currently none)
build/                           generated; gitignored
```

★ = the load-bearing pieces later tasks touch or depend on.

---

## Task 1 — scaffold, docs, constants, harness (DONE)

Goal: freeze the spec and stand up a real, non-ceremonial test harness **before** any
crypto/parser code, so docs and code cannot drift.

Delivered:
- **`spec/constants.json`** — the canonical authority for **31 constants**: Argon2
  params, AEAD sizes, format magics/versions, size caps, password policy, drand round
  policy, and the **verified drand quicknet identity**.
  - The drand chain hash, group public key, genesis, period and scheme were fetched
    live and **cross-checked against two independent endpoints** (`api.drand.sh` and
    `drand.cloudflare.com`) — they agree. Public key is 96 bytes (192 hex).
  - **Guard (SECURITY_INVARIANTS I11):** this JSON is a *build-time check only*. The Go
    helper (Task 3) must keep the drand values **compiled-in** and must NOT load them
    from this JSON at runtime (a runtime-loaded chain hash = forged-chain escape hatch).
- **`FORMAT.md`** — full byte layouts (VLT1 30B header, manifest 54B, PW01 47B header),
  the exact AES-GCM AAD range, password→bytes rules, CSPRNG rule, the stale-round
  formula, both closed error domains, and a machine-checkable constants table between
  `<!-- CONSTANTS-TABLE-BEGIN/END -->` markers (parsed by the consistency test).
- **`SECURITY_INVARIANTS.md`** — invariants I1..I14 (fail-closed, unseal-as-gate,
  manifest-as-truth, trusted-time-both-sides, no-escape-hatch-backup, no-raw-quarantine,
  passwordless-reseal, forward-only-locking, helper-is-closed-API, one-format-version,
  single-constants-source, durable atomic writes, no-durable-plaintext, no-dev-escape-
  hatch) plus the honest force-kill ceiling.
- **`run_tests`** harness + **`tests/consistency_check.swift`** + Swift/Go constant
  dumpers. Consistency is **checked, not code-generated** (deliberate: no codegen
  toolchain). No-silent-skip enforced via `tests/skip-allowlist.txt`.

Proven non-ceremonial: 5 injected faults (wrong Swift value, missing JSON key, extra
`FORMAT.md` key, forbidden source dir, placeholder token) were each caught, then the
repo restored to green.

---

## Task 2 — inner crypto + VLT1/manifest/PW01 format (DONE)

Built in two halves so there was a green baseline before the C-bridging step.

### 2a — format core (pure Swift + CryptoKit)
- **`VaultFormatError`** (`Errors.swift`): the closed core/format domain —
  `parseError`, `authError`, `unsupportedVersion`, `corrupt`, `sizeLimit`,
  `invariantViolation`. Callers switch only on these.
- **`Bytes.swift`**: fixed-width little-endian read/write; every out-of-range read
  **throws `parseError`** (never traps) so malformed input fails closed.
- **`PW01.seal/open`**: AES-256-GCM with the 47-byte PW01 header as AAD. Stored Argon2
  params are **pinned** — `open` rejects any header whose params ≠ frozen constants
  (`invariantViolation`); no negotiation, no downgrade. `open` maps any AES failure to
  `authError` (CryptoKit yields plaintext only after the tag verifies, so no partial
  plaintext escapes). The key is supplied by the caller (PW01 does not derive it).
- **`Manifest.encode/decode`**: 54-byte record; decode verifies magic, version,
  reserved==0, `chain_hash == DRAND_CHAIN_HASH`, and `end > start`.
- **`VLT1.encode/decode`**: 30-byte plaintext header; `display_*` rounds are
  UNTRUSTED hints (never used for access). Decode enforces magic/version/flags, the size
  cap, and `payload_len == actual remaining bytes`.

Tests (`format_suite.swift`): AES-256-GCM anchored to two well-known KATs
(McGrew/Viega GCM cases 13 & 14); PW01 **golden header is byte-exact** + deterministic;
round-trip; empty notes; wrong-key, AAD-tamper, ciphertext-tamper → `authError`;
unknown-version, param-mismatch, too-short; manifest and VLT1 bad-magic/version/length/
flags/oversize; ByteReader overrun. All fail closed with the expected error case.

### 2b — Argon2id (vendored C + Swift binding)
- **Vendored** `phc-winner-argon2` at commit `f57e61e19229e23c4445b85494dbf7c07de721cb`
  (20190702). **Portable `ref` build only** — `opt.c` (x86 SSE) is intentionally
  excluded; this is an arm64 target. See `vendor/argon2/PINNED.txt` (commit + per-file
  SHA-256 + license note). The vendored set: `argon2.c core.c encoding.c ref.c
  thread.c blake2/blake2b.c` + `include/argon2.h`.
- **`Sources/CArgon2/`**: a module map exposing `vault_argon2.h`, whose `shim.c`
  builds the `argon2_context` and calls `argon2id_ctx()`. One entry point
  `vault_argon2id(...)` is used by both production (secret/ad NULL) and the KAT test
  (secret/ad set), so Swift never hand-constructs the context struct.
- **`Argon2.raw(...)`**: arbitrary-param binding; any nonzero return (incl.
  `ARGON2_MEMORY_ALLOCATION_ERROR = -22`) ⇒ `throw` (fail closed, no downgrade).
- **`KeyDerivation.deriveKey(password,salt)`**: the only production caller; pins t=3,
  m=1 GiB, p=4, version=0x13, out=32 → an `AES.SymmetricKey`.

Tests (`argon2_suite.swift`): **cross-validated against OpenSSL 3.6.1's independent
ARGON2ID** — the vendored phc lib reproduces OpenSSL's output byte-for-byte at p=4 and
p=1 (vectors and params are documented in the file's header comment). Plus 1 GiB
deriveKey determinism + salt-sensitivity + a **benchmark gate** (completed in ~0.45s on
the dev machine; emitted as `RESULT: INFO`), empty-password rejection, and an
**end-to-end** password→Argon2id key→PW01 seal/open with wrong-password → `authError`.

Proven non-ceremonial: injecting a wrong expected Argon2 vector was caught, then
restored to green. (At Task 2's completion the harness ran 45 checks; the current total
including Task 3 is in the **Current status** section at the end.)

### Build details (Swift / Argon2 toolchain) for later tasks
- Swift: `swiftc -O <Constants + VaultCore + test files> -I Sources/CArgon2/include
  -Xcc -Ivendor/argon2/include -L build -largon2 -o build/vault_tests`. CLT-only, no
  SwiftPM/Package.swift.
- Argon2 C flags: `-O3 -Ivendor/argon2/include -Ivendor/argon2/src
  -ISources/CArgon2/include`, archived with `ar rcs`.
- This shell is **zsh**; `run_tests` forces bash via shebang (word-splitting of flag
  vars relies on it — don't run the harness's clang/swiftc lines verbatim in zsh).

---

## Task 3 — Go `vaultseal` helper (DONE)

Goal: the **only** component that talks to the drand network. It time-locks/-unlocks the
opaque `manifest || PW01` payload and reports the current round, behind a deliberately
tiny, fail-closed CLI. A Swift wrapper (Task 4) will drive it as a subprocess.

### Dependency decision (read before touching `helper/go.mod`)
- Uses the **audited `github.com/drand/tlock` v1.2.0** IBE crypto + `kyber` BLS. We do
  **not** roll our own time-lock/IBE/hash-to-curve (Kerckhoffs).
- **We implement the `tlock.Network` interface ourselves** (`internal/drandnet`) over
  stdlib `net/http`. That prunes the entire heavy drand *client* stack (Prometheus, zap,
  `drand/go-clients`, the gRPC client). It also gives us the control the contract
  demands: compiled-in endpoints, our own closed error domain, explicit chain
  verification, max-round-across-endpoints — none of which tlock's stock HTTP network
  offers.
- **Unavoidable:** core `tlock` imports `drand/v2/common` (the `chain.Beacon` type),
  which transitively links `protobuf`/`grpc` **type stubs**. The helper never opens a
  gRPC socket (HTTP GET via stdlib only) — it is dead-linked code. Shedding it would
  mean hand-rolling the IBE construction, which we refuse to do.
- **Pins:** `tlock v1.2.0`, `drand/v2 v2.0.2`, `kyber v1.3.1`, `kyber-bls12381 v0.3.1`,
  `age v1.1.1` — tlock's own tested set, **not** `go mod tidy`'s floated-latest. Vendored
  and committed (15 modules, ~19M). `go mod verify` is clean.
- **Quicknet scheme** = `crypto.SchemeFromName("bls-unchained-g1-rfc9380")`; sigs are 48-byte
  G1, the group public key is 96-byte G2.

### What it does
- **`internal/wire`** — the closed helper error domain (exactly 7 codes:
  `round_not_ready`, `round_too_near`, `stale_round`, `auth_failed`, `parse_error`,
  `chain_mismatch`, `timeout`) and a JSON-on-stderr encoder bounded under
  `MAX_STDERR_BYTES`. An `Error` can never carry a code outside the closed set
  (`Emit` collapses any stray code to `parse_error`).
- **`internal/drandnet.Network`** — implements `tlock.Network`. Chain hash, group pubkey,
  scheme, genesis, period and the endpoint list are **compiled in** from
  `internal/constants` — never from a file/env/flag (no forged-chain escape hatch,
  I9). Every consulted endpoint's `/info` is verified against those values; a 200 `/info`
  advertising a **different** chain is **fatal** `chain_mismatch` (even if another mirror
  is healthy). Fetched signatures are **BLS-verified** against the compiled-in pubkey
  before use (defense in depth — tlock's `TimeUnlock` also verifies). `SwitchChainHash`
  is disabled and decryption runs `.Strict()` so a chainhash embedded in a ciphertext is
  never trusted. `VerifiedLatest()` returns the **max** verified latest across endpoints.
  HTTP **425/404 ⇒ `round_not_ready`**; bodies are size-capped (64 KiB).
- **`internal/seal`** — `Seal` (verifies freshness: rejects `round <= latest +
  FRESHNESS_MARGIN_ROUNDS` as `round_too_near`), `Unseal` (maps a tlock decrypt failure
  to the closed domain; the Network preserves the real `Signature()` cause that tlock
  flattens into `ErrTooEarly`), and `CurrentRound` (rejects a network latest that is
  `< expected(now) - STALE_ROUND_TOLERANCE_ROUNDS` as `stale_round`; the clock only ever
  *rejects*, never grants). All three **buffer the full result and write stdout only on
  success** — never a partial result beside an error.
- **`cmd/vaultseal`** — strict CLI: exactly `seal --round N` | `unseal` | `current-round`
  and nothing else. Any extra token, unknown flag, `--round=N` form, non-digit/zero/
  negative round ⇒ `parse_error` *before* any network or crypto work. There are **no**
  file/network/chain override flags; input is stdin only, result is stdout only.

### Tests (all wired into `./run_tests`, offline)
- **`cmd/hermetictests`** (RESULT-line harness, run with the network black-holed to a
  dead proxy to *prove* it needs no network): real-beacon **round-trip** (seal→unseal of
  a payload using a real quicknet beacon for round 1000000, exercising genuine tlock
  crypto + BLS verify); future-round-locked (`round_not_ready`); **forged beacon**
  rejected (`auth_failed`); corrupt ciphertext fail-closed; freshness boundary
  (`<=latest+margin` rejected, `+1` accepted, past rejected); `stale_round`;
  `current-round` happy + `timeout` propagation; **13 negative-CLI cases** (each: non-zero
  exit, empty stdout, closed-domain JSON on stderr).
- **`internal/drandnet/network_test.go`** (`go test` + in-process `httptest`): the real
  HTTP layer — `VerifiedLatest` happy + max-across-endpoints; **`chain_mismatch` fatal**
  for wrong hash/pubkey/scheme/period/genesis (even with a healthy second endpoint);
  HTTP-layer signature verify (real sig passes, valid-but-wrong sig ⇒ `auth_failed`);
  425/404 ⇒ `round_not_ready`; response size cap; `ExpectedRound` math.
- **Vendor enforcement:** `run_tests` runs `go mod verify` and builds with `-mod=vendor`
  (which fails on "inconsistent vendoring" — that *is* the dirty/missing-vendor guard).
- **Placeholder scan** now excludes `vendor/` (third-party code legitimately contains
  TODO/FIXME).

**Also proven live (not in the offline harness):** a real seal→wait-for-round→unseal
across an actual drand round boundary recovered the exact plaintext — the genuine
HTTP-fetch + verify + decrypt path end to end.

### Decisions a Task 4 developer should know
- **Sealed payload format** is binary (non-armored) age. Opaque to VLT1; Task 6 frames it.
- **Timeout semantics:** the helper's per-request HTTP timeout is `HELPER_TIMEOUT_MS`;
  with 3 endpoints the worst case is a multiple of that. The **authoritative**
  fail-closed kill is the Swift wrapper's job (Task 4) — it owns the overall budget and
  must terminate the subprocess. Treat the helper's internal timeout as best-effort.
- **Endpoints** (`api.drand.sh`, `api2`, `api3`) live only in the Go helper (Swift talks
  to the helper, not drand), so they are intentionally **not** in the cross-checked
  `constants.json`. They must be Canopy-whitelisted (Task 8 self-test verifies).
- The helper does **one** operation per process and exits; `lastSigErr` state is per-process.

Current state: **73 checks, all PASS.**

---

## Helper contract — what Task 4 (and 6) depend on

These were the Task 3 requirements; the helper now implements all of them. They are
listed here as the **boundary contract** the Swift wrapper must honour exactly.

1. **Helper contract (app.md §9, SECURITY_INVARIANTS I9):** `vaultseal` exposes only
   `seal --round N` / `unseal` / `current-round`; **stdin→stdout only**; **no
   file-path/network/chain override flags**; chain hash + group pubkey + endpoints
   **compiled-in** (`helper/internal/constants`; the values are cross-checked to
   `spec/constants.json` by the consistency test — endpoints are helper-only and are
   *not* in that JSON). Errors are the closed **helper domain** JSON on stderr:
   `round_not_ready`, `round_too_near`, `stale_round`, `auth_failed`, `parse_error`,
   `chain_mismatch`, `timeout`. **Task 4 must switch only on that closed set;** unknown
   code ⇒ fail closed; any stdout alongside a non-zero exit ⇒ fail closed.
2. **The sealed payload piped through the helper is exactly `manifest || PW01`** — see
   `FORMAT.md` §3/§4/§5. VLT1 framing (Task 6) wraps the helper's output; the helper
   itself never sees VLT1.
3. **Trusted time / stale-round** (`FORMAT.md` §8): the helper rejects `seal --round N`
   if `N <= verifiedLatest + FRESHNESS_MARGIN_ROUNDS` (`round_too_near`) and rejects
   `current-round` as `stale_round` if `verifiedLatest < expectedRound(now) -
   STALE_ROUND_TOLERANCE_ROUNDS`, using the **max verified round across endpoints**.
   *As built:* because we pruned the drand client, the round/time map is the documented
   `ExpectedRound` formula implemented directly (`internal/drandnet`), not the library's
   `RoundAt`; the stale tolerance absorbs any off-by-one (the live network runs ~1 round
   ahead of the formula, which is within tolerance).
4. **Vendoring discipline for Go (done):** deps pinned, `vendor/` committed, built with
   `-mod=vendor`; the build fails if `vendor/` is missing/dirty or `go mod verify` fails.
   Scheme `bls-unchained-g1-rfc9380` (G1) is supported via `github.com/drand/tlock`.
5. **Constants are frozen.** If a later task needs a new *cross-language* constant, add it
   to `spec/constants.json` **and** `Constants.swift` **and** `helper/internal/constants`
   **and** the `FORMAT.md` table in the same change, or the consistency test fails.
   (Helper-only values like the endpoint list stay in the Go helper.)
6. **Canopy/network:** the helper's endpoints must be Canopy-whitelisted or the vault
   deadlocks; `api.drand.sh` is the primary. Self-test (Task 8) will verify reachability.

---

## Remaining tasks (4–12) — the road ahead

This is the planned scope for the tasks not yet started (Tasks 1–3 are done; see their
sections above). The entries below are a **map**, not a spec: objective + key
deliverables + **hard gates** (enough to know what each task is and when it's done). They
are intentionally *not* self-contained — the authoritative detail lives in `app.md`, and
duplicating it here would create a second source of truth that drifts. **Before
implementing a task, read its `app.md` sections.**

### Where the full detail lives (task → `app.md`)

| Task | Full detail in `app.md` | Don't-miss specifics |
|------|-------------------------|----------------------|
| 4 Swift wrapper     | §9 (subprocess hardening), §10 step 6, §11 ¶1 | launch-time hash check; total error mapping; `DEBUG`-only dry-run |
| 5 Schedule          | §5, §10 step 7 | too-near-skips-forward; DST / midnight-crossing |
| 6 Vault store ⚠     | §6 (lifecycle/flow + state machine), §10 steps 8–9, **§11 "recovery decision matrix" (~line 742)**, §11 ¶4–6, §7a | the primary×`.bak` matrix MUST be enum-total; no-raw-quarantine; backup write order |
| 7 Re-seal triggers  | §6, §10 steps 7/9, §11 ¶4–5 | forward-only / anti-shortening (I8) |
| 8 Setup + self-test | §9 (self-test), §10 step 10, §11 | `SelfTestEngine` ships in release, UI-path-only; ≥1 hard / ≥2 warn endpoints |
| 9 SwiftUI           | §10 step 11 | masked + reveal-on-tap; first task allowed `import SwiftUI` |
| 10 No-leakage       | §9 (no-durable-plaintext), §10 step 12, §11 | `RLIMIT_CORE=0`; spellcheck/autosave/restoration off; `NSTextView` fallback |
| 11 `.app` bundling  | §10 steps 13–14, §11 | build-gated on tests; sign nested helper first; no-`DEBUG`-symbol check |
| 12 E2E              | §10 step 14, §11 (corner-case table) | real window boundary + force-kill-mid-window |

> Note: `app.md` §10 numbers its build steps 1–14, which map onto the 12 tracker tasks
> (Task 2 covers §10 steps 2–4; Task 6 covers steps 8–9). The §11 adversarial review —
> especially the **recovery decision matrix** and the **corner-case table** — is the
> single most important thing to read before Tasks 6, 7, and 12; that is where an
> "innocent" fallback turns into an escape hatch.

Phases A→C must stay in order; the milestone after Task 4 is a hard stop before any
store/UI code.

### PHASE A (crypto + format + helper) — Tasks 1–4 done ✅ (MILESTONE reached)

**Task 4 — Swift seal/unseal wrapper + trusted time. ✅ MILESTONE.** `./run_tests`
green across 1–4 (126 PASS / 0 FAIL). The Swift side of the helper boundary, in
`Sources/VaultCore/`:
- `HelperRunner.swift` — hardened invocation: absolute path via `Process.executableURL`
  (never `/bin/sh`), **empty environment** (`[:]`; nothing inherited), stdin refused
  above its cap before launch, stdout/stderr read under caps with over-cap ⇒ fail-closed,
  timeout ⇒ `terminate → SIGKILL → .timeout`, and a launch-time integrity check
  (`lstat` regular-file + reject symlink, owner-exec bit, `O_NOFOLLOW` read, SHA-256 vs
  an **injected** expected hash). The expected hash is a constructor parameter, NOT a
  file/sidecar; the app layer supplies the **compiled-in** value at bundling time
  (Task 11). An empty/short expected hash is itself fail-closed.
- `HelperWire.swift` — the closed Swift mirror of the 7 helper codes plus a single
  `.failClosed(String)` sink, and the TOTAL `map(timedOut, exit, stdout, stderr)` →
  `Result` (known code → its case; parse_error forwards detail; unknown code /
  non-JSON stderr / non-zero-without-JSON / stdout-alongside-error / stderr-on-success /
  either stream over cap → fail closed). No `default`, no silent success.
- `TrustedTime.swift` — `expectedRound(at:)`, the Swift-side `validateSealTarget`
  (refuses `target <= latest + FRESHNESS_MARGIN_ROUNDS`, overflow-safe), and one-sided
  `isStale`. Freshness is enforced on BOTH sides; neither alone is load-bearing.
- `VaultSealClient.swift` — typed `currentRound` / `seal(…verifiedLatest:)` /
  `seal(…)` / `unseal`; `seal` refuses a too-near target BEFORE spawning. Payload stays
  opaque (no decrypt/parse), which keeps Task 6's defensive re-seal passwordless.
- `SelfTestEngine.swift` — **ships in release** (not `#if DEBUG`); reachable only via the
  engine API (no CLI/flag/env). Skeleton steps: `argon2Vector` (real OpenSSL-cross-checked
  KAT), `helperBinaryValid` (real preflight), `helperResponds` (live current-round). The
  full first-run gate (separate-temp-dir isolation, ≥2-endpoint reachability policy,
  data-loss confirmation) is Task 8 on top of this.
- `DryRun.swift` — developer wrappers, **entirely `#if DEBUG`**, embedding the sentinel
  `VAULT_DRYRUN_SURFACE_V1`.
- Hard gates in `run_tests`: subprocess hardening suite (`tests/helper_suite.swift`, real
  fixture executables) + a **dry-run release gate** (step 7b: compiles VaultCore release vs
  `-D DEBUG` with `-wmo -emit-object`, asserts the marker is ABSENT from release and
  PRESENT in debug — so the gate is provably non-vacuous).
- **No vault store, no UI, no real secrets yet** (SECURITY_INVARIANTS I-discipline).

### PHASE B (schedule, store, lifecycle)

**Task 5 — Schedule logic. ✅** `./run_tests` green (152 PASS / 0 FAIL). Daily wall-clock
windows → the next LOCK target (a start round + end round for the manifest), in
`Sources/VaultCore/Schedule.swift`:
- `TimeOfDay` (range-validated; nil ⇒ fail closed at construction), `DailyWindow`
  (`end < start` by seconds-of-day ⇒ crosses midnight; `end == start` is **degenerate**,
  NOT a 24-h window — this is a time-LOCK), and `Schedule { windows, calendar }`. The
  `Calendar` carries the time zone and is **injected** so DST/midnight are handled by the
  calendar, not by adding fixed seconds.
- `nextLock(now:verifiedLatest:) -> Result<ScheduleDecision, ScheduleError>` picks the
  **soonest VALID start** across all windows (min over candidates — adjacent/overlapping
  need no special case). A candidate start must be strictly future AND clear two
  **independent** floors, else it skips forward to that window's next daily occurrence:
  - **freshness:** `startRound > verifiedLatest + FRESHNESS_MARGIN_ROUNDS` (so the
    helper's own seal-freshness rule accepts the target — schedule and helper must agree
    or the vault wedges on a rejected boundary re-seal).
  - **minimum lock:** `startRound − nowRound >= MIN_LOCK_DURATION_ROUNDS` measured from
    the local-clock round (`expectedRound`), so a Lock seconds before open isn't a
    near-zero commitment.
- Boundaries map to rounds via the new **`TrustedTime.roundForTime(at:)`** — the round
  published *at or after* a date (ceil: `ceil((t−genesis)/period)+1`), the inverse used
  for *future* boundaries so a window opens no earlier (read half-open, closes no later)
  than the wall clock asks. Contrast `expectedRound` (floor, the current round, used to
  deny on a stale latest).
- Fail-closed buckets (`ScheduleError`): `.noWindows`, `.degenerateWindow` (span < one
  period), `.noValidStartWithinHorizon` (defensive 16-occurrence/window lookahead cap;
  normal operation resolves in ≤2 occurrences — the cap only stops a runaway search when
  `verifiedLatest` is implausibly far ahead). Never emits a target the helper would reject.
- Gates (`tests/schedule_suite.swift`, 26 checks): `roundForTime` ceil vs `expectedRound`
  floor at/over a publication boundary; today/inside→tomorrow/after→tomorrow selection;
  **each skip floor proven independently** (min-lock skips with freshness slack; freshness
  skips with min-lock slack); adjacent + overlapping + cross-window "later-today beats
  tomorrow"; midnight crossing (start today / end next day / inside→next night);
  **DST 23-h spring-forward (27600 rounds) and 25-h fall-back (30000 rounds)** in
  America/New_York; and the three fail-closed buckets.

**Task 6 — Vault store. ✅ THE DANGEROUS TASK.** `./run_tests` green (197 PASS / 0 FAIL).
Two new core files + a `SealService` injection seam, built as the six §10-step-8 passes:
- **`Sources/VaultCore/SecureFile.swift`** — the OS-level primitives. `readHardened`
  opens `O_RDONLY|O_NOFOLLOW|O_CLOEXEC`, `fstat`s the fd (no TOCTOU), and refuses
  anything that isn't a regular file owned by the current uid, mode exactly `0600`,
  `st_nlink == 1` (→ `.missing` / `.unreadable(reason)` / `.bytes`). Durable write
  primitives: `writeTempDurable` (`O_CREAT|O_EXCL|O_NOFOLLOW`, full write, `F_FULLFSYNC`),
  `renameDurable` (rename + `F_FULLFSYNC` file&dir), `removeDurable`, `fsyncDir` — raw
  POSIX because FileManager offers no `F_FULLFSYNC` / `O_NOFOLLOW`-create / same-dir
  guarantee.
- **`Sources/VaultCore/VaultStore.swift`** —
  - `protocol SealService` (currentRound/seal/unseal); `VaultSealClient` conforms; tests
    inject a fake. This is what keeps the store testable offline.
  - **(b) `classify(_:verifiedRound:)`** → `VaultFileState` (8 cases, plain tag/no
    associated values): `missing, unreadable, corrupt, tampered, futureClaimed,
    openWindow, expired, indeterminate`. **Unseal IS the gate**: `round_not_ready` ⇒
    `futureClaimed` (UNTRUSTED — manifest unreadable); `auth_failed`/`parse_error` ⇒
    `corrupt`; `timeout`/`chain_mismatch`/etc ⇒ `indeterminate`; on success → decode
    manifest, check `outer==manifest` (else `tampered`), then `R<start` ⇒ `corrupt`
    (impossible), `start≤R≤end` ⇒ `openWindow`, `R>end` ⇒ `expired`. (The spec's
    `future-valid-after-ready` is not a terminal state — a future seal is unreadable, so
    it resolves to open/expired only once its round is ready; documented in-file.)
  - **(d) `static decide(_:_:) -> VaultAction`** — the TOTAL primary×`.bak` matrix as one
    `switch (p,b)` with **NO `default`** (the compiler proves all 64 combos; an unhandled
    pair fails to COMPILE). Governing rules: indeterminate anywhere ⇒ `locked`; an
    `openWindow` copy grants `.open` **only if NO `futureClaimed` present** (future vetoes
    access — anti-shortening I8); a `futureClaimed` present ⇒ never access, only restore
    redundancy (`syncBackup`) from it when the sibling has no recoverable content,
    otherwise `locked`; no-open-no-future + a valid `expired` copy ⇒ `reseal` it FORWARD;
    nothing recoverable ⇒ `failClosed`. `futureClaimed` is explicitly NOT "valid".
  - **`load()`** orchestrates: get verified round (fail ⇒ `.offline`; `isStale` ⇒
    `.offline`), classify both, collect **hash-only `QuarantineRecord`s** for
    tampered/corrupt sides, run `decide`, execute. Returns `VaultLoadResult`
    {`openWindow(window,payload)`, `lockedUntil(displayStartRound?)`, `resealed(window)`,
    `failClosed(reason)`, `offline`}. The store never decrypts (payload handed up for the
    UI to PW01.open with the password) — which keeps defensive re-seal passwordless.
  - **(f) `defensiveReseal`** (passwordless): reuse the unsealed PW01 bytes verbatim,
    `schedule.nextLock(now,R)` → NEXT window, `commit`. **(e) `commit` / `writeVaultPair`**
    do the §6 order exactly: write `vault.dat.tmp`+fsync → delete old `.bak` → rename over
    `vault.dat` (fsync file+dir) → write `vault.dat.bak.tmp`+fsync → rename over `.bak`
    (fsync dir) → **post-verify** (re-read both hardened, byte-equality, 0600/owner/link).
  - `ensureDirectory()` creates the dir `0700` and **sets+verifies `isExcludedFromBackup`**.
  - Closed `StoreError` domain {io, helper, format, schedule, verifyFailed}.
- **No-raw-quarantine enforced at the TYPE level:** `QuarantineRecord` has only
  `sha256Hex` + reason + side — it structurally cannot hold the raw/decryptable bytes.
- Gates (`tests/store_suite.swift`, 46 checks): decide totality (all 64) + invariants
  (future-vetoes-open, open-grants-without-future, indeterminate-locks) + §11 matrix-row
  spot-checks; SecureFile symlink/hardlink/wrong-mode/over-cap/missing; classify for each
  of the 8 states; load() for offline, both-missing-failclosed, open-window, the two
  honest crash states (**(expired,missing)⇒reseal-forward-both-future**;
  **(future,missing)⇒syncBackup-no-access-no-seal**), both-future-locked, tampered+expired
  ⇒ reseal-`.bak`-forward + hash-only quarantine, durable-write pair identical/0600,
  `isExcludedFromBackup`. A `FakeSeal` simulates the time-lock offline (seal tags target;
  unseal returns `round_not_ready` until `R≥target`).

**Task 7 — Re-seal triggers (lifecycle). ✅** `./run_tests` green (212 PASS / 0 FAIL).
The INTERACTIVE re-seal path (app open, has password + plaintext) and the three triggers
that drive it, plus the CSPRNG source — all in `Sources/VaultCore/`:
- **`SecureRandom.swift`** — the single source of fresh salts + nonces, from
  `SystemRandomNumberGenerator` (the system CSPRNG on Apple platforms; works for any
  byte count — note CryptoKit's `SymmetricKeySize(bitCount:)` traps on non-standard
  sizes like 96, which is why we don't use it). Every re-seal draws a new salt + nonce
  here so no two saves share a key+nonce (FORMAT.md §7, DiD #3).
- **`VaultSession.swift`** — an OPEN, in-memory vault: the user's password (held only
  while unlocked) + the **committed window** we opened under (from the manifest, never
  the schedule).
  - `Trigger { lockButton, gracefulQuit, windowEndReached }` — the three interactive
    events, all funnelling into ONE `reseal`, so none can be a weaker bypass. (The 4th
    lifecycle event — the launch-time, NO-password defensive re-seal when `R>end` — is
    NOT here; it lives in `VaultStore.load()`/`defensiveReseal` from Task 6.)
  - **`static open(store:window:payload:password:)`** — bridges `load()`'s
    `.openWindow(window,payload)` to a live session: re-derives the key from the salt in
    the PW01 header (via the new `PW01.salt(from:)` accessor that keeps the header-offset
    in one place), `PW01.open`s, returns `(notes, session)`. A wrong password ⇒
    `.format(.authError)`, no partial plaintext.
  - **`hasWindowEnded(verifiedRound:)`** — `R > openWindow.endRound`; the predicate the
    UI polls to fire the window-end re-seal on a live session (crypto can't force-close
    an already-open session — §6 ⚠ note).
  - **`reseal(notes:trigger:)`** — the engine: (1) mandatory drand-verified round
    (offline / `isStale` ⇒ fail closed, no write); (2) `schedule.nextLock` → the NEXT
    window (enforces the freshness + min-lock floors); (3) **forward-only guard** —
    refuse to commit a target not strictly future of `R` (I8 anti-shortening, explicit
    on top of nextLock's guarantee and the helper's own check); (4) build a FRESH PW01
    (new salt+nonce, key re-derived); (5) `store.commit` (seal to start, durable write
    both, verify). Ordered fail-fast-before-Argon2 so the fail-closed paths cost nothing.
- Gates (`tests/session_suite.swift`, 15 checks, reuses the offline `FakeSeal`):
  open round-trip (right pw decrypts / wrong pw fails closed); `hasWindowEnded`
  inside/past; a **full forward cycle** (edit notes → `reseal(.windowEndReached)` ⇒ both
  copies future-locked, one seal, then re-opens at the new start recovering the EDITED
  notes under a freshly-derived key); the **anti-shortening floor**
  (`startRound − R ≥ MIN_LOCK_DURATION_ROUNDS`); and the fail-closed paths — offline (all
  three triggers fail, on-disk blob byte-for-byte untouched, 0 seals), stale round, and
  no-schedule-window — each leaving the vault unwritten.

### PHASE C (setup, UI, leakage, packaging)

**Task 8 — First-run setup + on-device self-test gate. ✅** `./run_tests` green
(254 PASS / 0 FAIL). The engine layer only — **no SwiftUI** (still gated to Task 9);
the first-run UI (Task 9) drives these. New Go command + three new `VaultCore` files,
all offline-testable:
- **Helper `endpoints` command (Go).** A 4th read-only `vaultseal` subcommand (no
  flags, stdin-empty, JSON-on-success): `drandnet.ProbeEndpoints()` reaches each
  compiled-in endpoint **independently** and reports `{endpoint, ok, round, code}` per
  endpoint plus `ok_count`/`total`. Unlike the hot-path `VerifiedLatest` (fatal on any
  chain mismatch, returns the max), the probe is **non-fatal per endpoint** — it reports
  every endpoint's state (a forged chain shows as `code:"chain_mismatch"`, not an abort)
  and lets the Swift policy decide. An all-down probe is still a SUCCESSFUL operation
  (exit 0, `ok_count:0`). Surface still has zero override flags (I9 intact). Gates:
  httptest coverage (`network_test.go`: all-ok / one-down-non-fatal /
  chain-mismatch-reported-not-fatal) + hermetic offline `cli/endpoints-offline`
  (well-formed report behind a dead proxy) + two negative-CLI cases.
- **`PasswordPolicy.swift`** — `encode` (UTF-8, NO trim/normalize/casefold — Swift's
  `String.utf8` preserves scalars verbatim, the FORMAT.md §7 rule); `validate`
  (`.empty` / `.tooShort(scalars)` below `MIN_PASSWORD_LENGTH` counted in **Unicode
  scalars not bytes** / `.tooLong(bytes)` above `MAX_PASSWORD_BYTES`); `confirms`
  (exact-byte compare — NFC≠NFD caught); `weaknessWarning` (blunt length/variety
  heuristic, advisory only, no zxcvbn).
- **`SelfTestEngine.swift`** (completed from the Task-4 skeleton) — now over an
  injectable **`SelfTestServices`** (production `LiveSelfTestServices` wraps real Argon2
  + the real `vaultseal` client; tests inject a fake → every branch runs offline). Steps
  (each `pass`/`warn`/`fail`): `argon2Vector` (8 MiB OpenSSL-cross-checked KAT),
  `argon2Benchmark` (**1 GiB production params**, alloc-fail ⇒ **fail closed**, over the
  injectable latency budget ⇒ warn), `helperBinaryValid` (pinned-hash preflight),
  `helperRoundTrip` (current-round + seal a throwaway random payload to a safely-future
  round + persist/reload it in the scratch dir + unseal → the CORRECT result is
  `round_not_ready`; an immediate open is a hard fail), `endpointsReachable` (**≥1 = pass,
  exactly 1 = warn, 0 = fail, any `chain_mismatch` = hard fail**), `backupExclusion`
  (vault dir carries `isExcludedFromBackup`). `gate()` → `.clear` / `.needsConfirmation`
  / `.blocked` (any fail blocks; else any warn needs confirmation).
- **`FirstRunSetup.swift`** — the gated create flow (engine, no UI): validate password +
  exact-byte confirm → require explicit **data-loss acknowledgment** (the Time Machine /
  APFS-snapshot / cloud-sync warnings that can't be auto-verified without admin) → run
  the self-test gate in a **throwaway scratch dir deleted + asserted-deleted on every
  path** (`withScratchDir`) → enforce the gate (block on fail; warnings need
  `confirmWarnings`) → only then derive the key (fresh salt+nonce), seal the initial
  notes to the **first scheduled window** (`schedule.nextLock` from a verified round),
  and `commit`. Closed `SetupError` domain.
- Gates (`tests/setup_suite.swift`, reuses `FakeSeal`): PasswordPolicy (empty / short-by-
  scalars / max-bytes / over-cap / **NFC≠NFD confirm** / no-normalization / weak-warning);
  SelfTestEngine every step's pass/warn/fail + the three gate verdicts; FirstRunSetup
  (rejects bad password / confirm-mismatch / un-acknowledged data-loss / hard-failure
  blocks with **0 seals** / warning refused-without-confirm then proceeds-with-confirm /
  **full happy path → a real future-locked vault that re-opens with the password at the
  committed window and recovers the initial notes**). The Task-4 `helper_suite`
  SelfTestEngine block was migrated here (its real-subprocess capabilities stay covered by
  the `HelperRunner`/`VaultSealClient` integration tests).

**Task 9 — SwiftUI views.** Locked screen (locked-until / offline); unlock; notes
editor with masked + reveal-on-tap secrets; settings (windows); Lock button. *(First
task allowed to import SwiftUI — the phase guard enforces this.)*

**Task 10 — No-durable-plaintext-leakage pass.** No logging of secrets; state
restoration / autosave / undo persistence off; spellcheck/grammar/data-detectors/
substitutions off on secret fields; no recent-documents; no plaintext temp/cache/diag
files; core dumps off (`RLIMIT_CORE=0`); `0700`/`0600`; custom `NSTextView` wrapper if
`TextEditor` can't be locked down. Scope = no durable plaintext after quit/crash. Gate:
offline-at-unlock → fail closed.

**Task 11 — `.app` bundling + signing.** `build.sh` **runs the gate tests first and
refuses to assemble/sign if any are red** → `go build -mod=vendor` helper (arm64) →
`swiftc` → assemble `.app` (Info.plist, no CLI/URL surface) → **release build fails if
any `DEBUG` dry-run symbol/flag present** → sign nested `vaultseal` first, then ad-hoc
sign the bundle → verify `codesign --verify --deep --strict`, `otool -L`, `file`, Finder
double-click. (Signing + self-test = integrity, not a commitment boundary.)

**Task 12 — End-to-end test across a real window boundary.** Seal near-future → won't
open early → opens at round → window-end re-seal → force-kill mid-window → defensive
re-seal closes the gap → offline-at-unlock fails closed → final §11 review.

> The harness must stay green at every task boundary. New gates are added per task; none
> are ever removed. Any fail-open discovered at any point is a release blocker.

---

## Current status
- Tasks 1–8: **complete, `./run_tests` green (254 checks).**
- No UI, no `.app`, no real secrets yet (by design). The store, session, self-test, and
  first-run flow are all **engine layers** driven only by tests; nothing wires them to an
  app shell yet. `FirstRunSetup`/`SelfTestEngine` are what the first-run UI (Task 9)
  calls; the three interactive re-seal triggers are what the running-app UI wires to
  events (Lock button / Cmd-Q / a window-end poll).
- Next: **Task 9 — SwiftUI views.** Locked screen (locked-until vs offline), unlock,
  notes editor with **masked + reveal-on-tap** secrets, settings (windows), **Lock
  button**; seal on graceful quit. This is the **first task allowed to `import SwiftUI`**
  — the `run_tests` phase guard (step 1) currently FAILS the build on any
  SwiftUI/AppKit/Cocoa import, so that guard must be **relaxed for Task 9** (e.g. allow
  the imports only under the new UI source dir) as part of the task, not silently
  deleted. The UI wires to the existing engines: `FirstRunSetup.create(...)` /
  `runSelfTest()` for onboarding, `VaultStore.load()` for the locked/open decision,
  `VaultSession.open(...)` + `reseal(...)` for the unlocked session and its triggers.
  Keep all secret handling ready for Task 10's no-durable-plaintext pass (don't add
  logging/autosave/state-restoration now). **Before implementing, read `app.md` §10 step
  11 and §11** (masked/reveal; the open-vs-locked screen uses `load()`'s result, never the
  mutable schedule). Per the project's milestone discipline, the user instigates Task 9.

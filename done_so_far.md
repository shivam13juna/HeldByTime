# done_so_far.md — implementation handoff (Tasks 1–2)

This document plus `app.md` (the full design), `FORMAT.md` (the byte spec),
`SECURITY_INVARIANTS.md` (the non-negotiables) and the codebase should be enough to
pick up at **Task 3 (Go `vaultseal` helper)** and continue.

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

What it does, in order (each step prints `RESULT: PASS|FAIL <name>` lines):

1. **Phase guard** — fails if a SwiftUI/AppKit/Cocoa import appears (forbidden before
   Task 9) or a `.app` bundle exists (forbidden before Task 11). *(The stricter Task-1
   negative-scope guard — "no crypto/parser code yet" — was retired when Task 2 opened,
   as planned.)*
2. **Placeholder scan** — fails on `TODO|FIXME|XXX|PLACEHOLDER|HACK` in deliverables
   (scans `FORMAT.md SECURITY_INVARIANTS.md spec Sources Tools helper tests`; not
   `app.md`/`run_tests`).
3. **Swift constant dumper** build+run → `build/constants-swift.json`.
4. **Go constant dumper** build+run → `build/constants-go.json`.
5. **Constants consistency** (`tests/consistency_check.swift`) — parses
   `spec/constants.json`, both dumps, and the `FORMAT.md` constants table; fails on any
   missing/extra key, type/value mismatch, or malformed table.
6. **Argon2id static lib** — `clang` builds the vendored portable `ref` build +
   `Sources/CArgon2/shim.c` into `build/libargon2.a`.
7. **Test binary** — `swiftc` compiles `Sources/Constants` + `Sources/VaultCore/*` +
   `tests/{test_support,format_suite,argon2_suite,main}.swift`, linked against
   `libargon2.a` and the `CArgon2` module → `build/vault_tests`, then runs it.

**Aggregation rule:** exit 0 only if zero `FAIL` lines and zero un-allowlisted `SKIP`
lines (`tests/skip-allowlist.txt`). `RESULT: INFO` lines are informational (e.g. the
Argon2 benchmark timing) and not counted.

### Test-harness conventions (reuse these for Task 3+)
- Test binaries print `RESULT: PASS|FAIL|SKIP|INFO <name> [-- detail]` to stdout and
  exit non-zero on any failure.
- `run_exec EXE NAME [args...]` (a bash function in `run_tests`) runs a binary, collects
  its `RESULT:` lines, and — crucially — emits a `FAIL <name>/exit` if the binary exits
  non-zero **without** a `FAIL` line (catches crashes/traps that would otherwise be
  silent because buffered stdout is lost on a trap; `tests/main.swift` also sets
  `setvbuf(stdout, nil, _IONBF, 0)` so partial output survives a trap).
- Add a Go test step for Task 3 the same way: build it, `run_exec` it (or for `go test`,
  translate its output to `RESULT:` lines, or just gate on its exit code via a wrapper
  that emits one `RESULT:` line).

---

## Repository layout (after Task 2)

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
Tools/
  constdump-swift/main.swift     emits Swift constants as JSON (consistency test)
helper/                          ★ Go module "vaultseal" — Task 3 lives here
  go.mod                         module vaultseal (go 1.26); NO deps yet
  internal/constants/constants.go  Go mirror of constants + check-only All map
  cmd/constdump/main.go          emits Go constants as JSON
vendor/argon2/                   pinned phc-winner-argon2 (ref build) + PINNED.txt + LICENSE
tests/
  consistency_check.swift        standalone constants comparator (own executable)
  test_support.swift             shared RESULT harness (pass/fail/check/expectThrow)
  format_suite.swift             runFormatSuite()  — Task 2a tests
  argon2_suite.swift             runArgon2Suite()  — Task 2b tests
  main.swift                     entry point: runs both suites
  skip-allowlist.txt             allowed SKIP names (currently none)
build/                           generated; gitignored
```

★ = the things Task 3+ will touch or depend on.

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
restored to green. Current state: **45 checks, all PASS**.

### Build details Task 3 may need to mirror
- Swift: `swiftc -O <Constants + VaultCore + test files> -I Sources/CArgon2/include
  -Xcc -Ivendor/argon2/include -L build -largon2 -o build/vault_tests`. CLT-only, no
  SwiftPM/Package.swift.
- Argon2 C flags: `-O3 -Ivendor/argon2/include -Ivendor/argon2/src
  -ISources/CArgon2/include`, archived with `ar rcs`.
- This shell is **zsh**; `run_tests` forces bash via shebang (word-splitting of flag
  vars relies on it — don't run the harness's clang/swiftc lines verbatim in zsh).

---

## Notes / decisions a Task 3 developer must respect

1. **Helper contract (app.md §9, SECURITY_INVARIANTS I9):** `vaultseal` exposes only
   `seal --round N` / `unseal` / `current-round`; **stdin→stdout only**; **no
   file-path/network/chain override flags**; chain hash + group pubkey + endpoints
   **compiled-in** (use `helper/internal/constants` values; cross-checked to
   `spec/constants.json` by the consistency test). Errors are the closed **helper
   domain** JSON on stderr: `round_not_ready`, `round_too_near`, `stale_round`,
   `auth_failed`, `parse_error`, `chain_mismatch`, `timeout`. Swift will switch only on
   that closed set; unknown ⇒ fail closed; any stdout alongside an error ⇒ fail closed.
2. **The sealed payload piped through the helper is exactly `manifest || PW01`** — see
   `FORMAT.md` §3/§4/§5. VLT1 framing (Task 6) wraps the helper's output; the helper
   itself never sees VLT1.
3. **Trusted time / stale-round** (`FORMAT.md` §8): reject `seal --round N` if
   `N <= verifiedLatest + FRESHNESS_MARGIN_ROUNDS`; reject `current-round` as
   `stale_round` if `verifiedLatest < expectedRound(now) - STALE_ROUND_TOLERANCE_ROUNDS`.
   Use the **drand client's own `RoundAt`** as the authority and reconcile the documented
   formula's off-by-one against it (the tolerance absorbs it). Use the **max verified
   round across endpoints**, not the first reply.
4. **Vendoring discipline for Go:** pin deps, commit `vendor/`, build with
   `-mod=vendor`, and make the build fail if `vendor/` is missing/dirty or
   `go mod verify` fails (enforced, not advisory). drand quicknet uses scheme
   `bls-unchained-g1-rfc9380` (G1) — pick a tlock/drand library that supports it.
5. **Constants are frozen.** If Task 3 needs a new constant, add it to
   `spec/constants.json` **and** `Constants.swift` **and** `helper/internal/constants`
   **and** the `FORMAT.md` table in the same change, or the consistency test fails.
6. **Canopy/network:** the helper's endpoints must be Canopy-whitelisted or the vault
   deadlocks; `api.drand.sh` is the primary. Self-test (Task 8) will verify reachability.

---

## Remaining tasks (3–12) — the road ahead

This is the planned scope for the tasks not yet started. The entries below are a
**map**, not a spec: objective + key deliverables + **hard gates** (enough to know what
each task is and when it's done). They are intentionally *not* self-contained — the
authoritative detail lives in `app.md`, and duplicating it here would create a second
source of truth that drifts. **Before implementing a task, read its `app.md` sections.**

### Where the full detail lives (task → `app.md`)

| Task | Full detail in `app.md` | Don't-miss specifics |
|------|-------------------------|----------------------|
| 3 Helper            | §9 (helper contract), §10 step 5, §11 | closed helper error domain; stdin→stdout; pinned-compiled-in values |
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

### PHASE A (crypto + format + helper) — finish what 1–2 started

**Task 3 — Go `vaultseal` helper.** *(see "Notes a Task 3 developer must respect" above)*
- Objective: the only component that talks to the drand network. tlock seal/unseal of
  the `manifest || PW01` payload, plus `current-round`.
- Deliverables: pinned + vendored drand/tlock client (`-mod=vendor`, `go mod verify`,
  build fails if dirty); chain hash + group pubkey + endpoints **compiled-in** from
  `helper/internal/constants`; commands `seal --round N` / `unseal` / `current-round`
  only; **stdin→stdout only**, no file/network/chain flags; closed-set JSON error codes
  on stderr.
- Hard gates: negative-CLI tests (every forbidden flag/arg → non-zero exit, JSON error,
  no stdout, no file touched); helper-side round rejection (`seal --round <past|latest|
  latest+1-below-margin>` all fail); **stale-round** rejection; a future-sealed blob
  stays cryptographically locked from a terminal; vendor-enforcement test.

**Task 4 — Swift seal/unseal wrapper + trusted time. ⏸ MILESTONE.**
- Objective: the Swift side of the helper boundary; the last thing before store/UI.
- Deliverables: subprocess invocation by **absolute bundled path, never a shell**,
  minimal env, capped IO, timeout = fail-closed, exec-bit + **launch-time hash check**
  (expected hash compiled in, not a writable sidecar); total error mapping (known code →
  specific fail-closed action; unknown / malformed stderr / non-zero-without-JSON /
  stdout-alongside-error → fail closed); refuse non-future targets on the Swift side too;
  the shared **`SelfTestEngine`** skeleton (ships in release; dev dry-run wrappers
  `DEBUG`-only).
- Hard gates: round→target mapping refuses `<= latest+margin`; closed-error-code switch
  with unknown ⇒ fail closed; subprocess hardening tests; **release build fails if any
  `DEBUG` dry-run symbol/flag is present.**
- **After Task 4: `./run_tests` green across 1–4. No vault store, no UI, no real
  secrets until here (SECURITY_INVARIANTS I-discipline).**

### PHASE B (schedule, store, lifecycle)

**Task 5 — Schedule logic.** Multiple daily windows → the nearest future start round
that also clears `latest + FRESHNESS_MARGIN_ROUNDS` and `MIN_LOCK_DURATION_ROUNDS`
(too-near skips forward). Gates: DST/timezone, midnight-crossing, adjacent, overlapping,
too-near-skips-forward.

**Task 6 — Vault store. ⚠ THE DANGEROUS TASK.** Build as six small passes:
(a) read/validate one file → (b) classify state {missing, parse-corrupt,
future-claimed, future-valid-after-ready, open-window-valid, expired-valid, tampered,
bad-owner/mode/link/path} → (c) compare primary vs `.bak` → (d) **enum-driven total
decision (no `default`)** over the primary×`.bak` matrix → (e) write transaction →
(f) failure-injection.
- Unseal-as-gate; manifest mismatch → quarantine; `R<start` → corrupt; in-interval →
  prompt; `R>end` → defensive (passwordless) re-seal.
- **No-raw-quarantine** (hash/diagnostic only); re-seal valid-expired copies forward.
- **Durable writes (I12):** tmp + `F_FULLFSYNC` + atomic rename for *every* step
  (incl. `.bak` via `vault.dat.bak.tmp`, never a direct copy); delete-old-`.bak`-first;
  post-write re-parse + byte-equality + `0600`/owner/no-symlink/`st_nlink==1`.
- Path/inode hardening (`O_NOFOLLOW`, refuse symlinks/hardlinks, same-dir temp+rename);
  set `isExcludedFromBackup` at dir creation.
- Gates: stale `.bak`; symlink/hardlink/wrong-mode; force-kill + simulated-fail at each
  write step (invariant: old-intact OR new-future-sealed; never an extra expired copy
  beside a future one); force-kill-after-unseal-before-password; `R>end` re-seals; VLT1
  tamper both directions; recovery-matrix totality; no-raw-escape-hatch.

**Task 7 — Re-seal triggers (lifecycle).** Lock button; graceful quit; committed
end-round reached while running; defensive re-seal on launch when `R>end`. Enforce the
**forward-only / anti-shortening** invariant (I8).

### PHASE C (setup, UI, leakage, packaging)

**Task 8 — First-run setup + on-device self-test gate.** Create vault, confirm
password ×2 (exact-byte + min-length + weak-warning), set schedule, then a **hard
self-test before any real secret is stored**, driven by the release-shipped
`SelfTestEngine` (UI path only — no CLI/flag): Argon2 RFC-vector + on-device benchmark;
bundled `vaultseal` executable + signature-valid + real seal/unseal/current-round
round-trip; **≥1 drand endpoint reachable through Canopy = hard pass, strongly warn
unless ≥2**. Verify `isExcludedFromBackup`; hard-warn about Time Machine/APFS
snapshots/cloud sync. Self-test runs on a throwaway payload in a temp dir, never the
real vault path, cleaned up on success *and* failure.

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
- Tasks 1, 2: **complete, `./run_tests` green (45 checks).**
- No vault-store, no UI, no `.app`, no real secrets yet (by design).
- Next: **Task 3 — Go `vaultseal` helper.** Then Task 4 (Swift wrapper + trusted time)
  reaches the milestone after which the store/UI work may begin.

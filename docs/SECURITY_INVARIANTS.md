# SECURITY_INVARIANTS.md — non-negotiables

These are the rules the whole codebase is held to. Each is phrased so a test or review
can cite it by number. **Violating any of these is a release blocker, not a bug to
triage later.** The app is a *commitment device*: the adversary is the owner's own
future self, so "convenience" fallbacks are exactly the threat.

---

## I1 — Fail closed, always
Every uncertain outcome denies access. drand unreachable, round not yet published,
stale "latest" round, Argon2 allocation failure, any parse anomaly, file disagreement,
path/inode anomaly, subprocess timeout, authentication failure, an unknown error code,
or any stdout payload arriving alongside an error ⇒ **locked**. There is no "try
recovery / best effort" branch. **Uncertainty ⇒ deny.**

## I2 — Unseal is the gate
The authoritative locked-vs-open decision is the tlock-unseal attempt itself, run
against the live drand network. A future/unpublished round cannot be unsealed by
anyone — including the owner and including this app. UI hints (the VLT1 `display_*`
fields) never make an access decision.

## I3 — Manifest is the sole authorization source
After a successful unseal, `manifest.target_start_round` / `target_end_round` (with
`manifest.chain_hash == DRAND_CHAIN_HASH`) are the authority for the open window. The
plaintext VLT1 outer header is a display hint only and is never trusted for routing or
authorization.

## I4 — Trusted time on both sides, authentic AND recent
Seal targets and the open decision use drand network time, not the local clock. A
signature-valid round proves it was *real*, not *current*; a "latest" round older than
the clock-derived expectation by more than `STALE_ROUND_TOLERANCE_ROUNDS` is rejected
(`stale_round`). The local clock is used only to *reject* (fail closed), never to
*grant*.

## I5 — No escape-hatch backup
Exactly one same-target backup (`vault.dat.bak`) is retained, overwritten each save.
**No dated/versioned history** — an old backup has an expired time-lock and would be
openable, defeating the commitment. The backup is always written by tmp+rename
(`vault.dat.bak.tmp` → rename), never by copying decrypted bytes.

## I6 — No raw expired blob is ever preserved
A successfully-unsealed past/expired payload is never written back to disk in
openable form. Tamper quarantine stores a **hash/diagnostic record only**, never the
raw bytes. A valid-but-expired copy is **re-sealed forward**/// before any access, never
left readable.

## I7 — Defensive re-seal is strictly passwordless
The launch-time / window-end re-seal path must never prompt for a password,
AES-decrypt, parse notes, or construct plaintext. It only does
`unseal → read manifest + PW01 bytes → new manifest → re-seal`. No decrypt/prompt code
path may be reachable from it.

## I8 — Forward-only locking (anti-shortening)
Any re-seal commits a target window that does not open earlier than the current one.
The vault can never be made to open sooner than it already would.

## I9 — Helper is a closed security API
The `vaultseal` helper exposes only `seal --round N` / `unseal` / `current-round`,
communicates stdin→stdout only (payload never written to disk by the helper), and
hardcodes the chain hash, group public key, and endpoints. **No file-path flag, no
network/endpoint override flag, no chain override.** Errors are the closed helper
domain in FORMAT.md §9; Swift switches only on that closed set, unknown ⇒ fail closed.

## I10 — One format version, no migration
There is a single on-disk format version. Unknown magic/version ⇒ fail closed. Stored
Argon2 parameters MUST equal the frozen constants; there is no negotiation and no
downgrade path.

## I11 — Single source of truth for constants
`spec/constants.json` is canonical. Swift, Go, and the `FORMAT.md` constants table are
*checked* against it (not code-generated). A mismatch fails `./run_tests`. The drand
chain hash / public key live in the JSON for drift-detection only; the helper keeps
them compiled-in and never loads them from the JSON at runtime.

## I12 — Durable, atomic writes (macOS reality)
Every persistent write is tmp-file + `F_FULLFSYNC` + atomic rename (file and
directory), never an in-place rewrite or a plain `fsync`. After writing, re-parse both
files and verify byte-equality and `0600` / owner / no-symlink / `st_nlink == 1`.

## I13 — No durable plaintext leakage
No secret (password, derived key, PW01 plaintext, manifest, notes) is ever logged,
swapped to a plaintext temp/cache/diagnostic file, retained in app state restoration /
autosave / undo persistence, indexed by spellcheck/grammar/data-detectors/recent-docs,
or written to a core dump. Scope: **no durable plaintext after quit or crash.**

## I14 — No developer escape hatch in release
The release binary exposes the self-test only through the first-run UI path. No CLI,
flag, env var, URL scheme, debug menu, or maintenance unlock. Developer dry-run
wrappers are `DEBUG`-only and absent from the release build.

---

### Honest ceiling (stated, not hidden)
This design gives a hard cryptographic "cannot open before the start round" wall. It
does **not** give a cryptographic "must close at the end round" wall: after the start
round publishes, the payload is unsealable until the app re-seals it, so a hard
crash/force-kill mid-window leaves a gap in which deliberate manual tooling could open
the vault until the next launch performs the defensive re-seal (I7). The app is a
strong commitment device against impulsive access, not an absolute cage against
premeditated action during an already-open window.

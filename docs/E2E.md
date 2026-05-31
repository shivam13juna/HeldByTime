# E2E.md — Task 12: end-to-end verification across a real window boundary

This is the final task (app.md §10 step 14, §11). It has two halves:

1. **Automated live E2E** (`./e2e_test`) — drives the **real `vaultseal` helper**
   against **real drand** across a **genuine round boundary**, through the real
   `VaultStore`/`VaultSession`/VLT1/manifest/PW01 engine. Throwaway sentinel only.
2. **Manual GUI checklist** (below) — the first **live launch of the built `.app`**,
   with the force-kill-mid-window and the system-wide durable-plaintext scan that a
   windowed app cannot exercise headless.

Neither half is part of `./run_tests` (offline by design). The offline harness
keeps a static fence, `e2e/harness-gate` (run_tests step 7f), that these files
exist and cover the required legs — the same pattern as Task 11's `build/bundling-gate`.

---

## Part 1 — automated live E2E

```sh
./build.sh          # produce build/dist/EncryptedVault.app (gated on ./run_tests)
./e2e_test          # ~3–4 min: crosses two real quicknet round boundaries
```

Requires the network (a content filter must allow `api.drand.sh`). `e2e_test` compiles
`tests/e2e/main.swift` with the real engine and runs it against the bundled signed
helper. Legs (each prints a `RESULT:` line):

| Leg | RESULT names | Proves |
|---|---|---|
| current round | `e2e/current-round` | the real helper reaches drand and returns a verified round |
| seal near-future | `e2e/seal-near-future`, `e2e/locked-before-window`, `e2e/sealed-not-plaintext` | sealed to a future round → **won't open early**; blob is sealed (no plaintext) |
| opens at round | `e2e/opens-at-round`, `e2e/decrypts-sentinel`, `e2e/wrong-password-failclosed` | opens exactly at its round; right password decrypts; wrong password fails closed |
| interactive re-seal | `e2e/interactive-reseal-forward`, `e2e/relocked-after-reseal` | window-end re-seal moves protection **forward**, re-locks both files |
| defensive re-seal | `e2e/seal-short-window`, `e2e/reached-expiry`, `e2e/defensive-reseal`, `e2e/defensive-forward`, `e2e/relocked-after-defensive` | an **expired** vault (force-kill analogue) is re-sealed forward **passwordlessly** on next launch |
| offline | `e2e/offline-failclosed` | the real helper behind a dead proxy fails closed (non-zero, empty stdout, closed-domain error) |
| no leak (scratch) | `e2e/no-plaintext-interactive`, `e2e/no-plaintext-defensive`, `e2e/files-0600` | scratch vault files hold only sealed bytes; mode 0600 |
| multi-vault | `e2e/multivault-sealed`, `e2e/multivault-enumerated`, `e2e/multivault-each-locked`, `e2e/multivault-delete-isolated`, `e2e/multivault-no-plaintext` | two real vaults under one root are enumerated by the registry, each **independently** locked; deleting one leaves the other intact (the shape the re-seal agent iterates) |

Expected tail: `E2E: all live legs passed.` and exit 0.

> Honest scope: `e2e_test` proves the **engine** live path. load()'s offline →
> `.offline` mapping is unit-proven in `store_suite` with `FakeSeal`; here the real
> binary's offline fail-closed behaviour is proven directly. The GUI behaviours
> (state restoration, editor caches, real force-kill) are Part 2.

---

## Part 2 — manual GUI checklist (the first live launch)

Use a **throwaway sentinel** in the notes during this test (e.g. `LEAKPROBE-7f3a`),
**not** a real secret of yours — so `scan_leak.sh` can search for it in
cleartext. Store the real secrets only after this checklist is green.

Set a **short test window** in Settings (e.g. opening 2–3 minutes out, lasting ~2
minutes) so you can cross a boundary by hand without waiting hours.

- [ ] **1. Double-click `build/dist/EncryptedVault.app` in Finder.** It launches as
      a windowed app — there is **no** terminal entry point, no CLI flags, no URL
      scheme. First run shows the setup + self-test gate.
- [ ] **2. First-run self-test passes** on this machine (Argon2id vector, helper
      preflight + round-trip, ≥1 drand endpoint reachable, backup
      exclusion). If it blocks, fix the cause (content-filter allow-list!) before storing
      anything real.
- [ ] **3. Create the vault** with the throwaway sentinel in the notes; confirm the
      password twice; acknowledge the data-loss warning. The vault seals to the
      first scheduled window.
- [ ] **4. Quit (Cmd-Q) and relaunch before the window opens** → the lock screen
      shows "locked until …" with **no password field** (sealed; can't open early).
- [ ] **5. At the window, relaunch** → password prompt appears; unlock → the
      sentinel notes are shown. (This is the live open across a real boundary.)
- [ ] **6. Force-kill mid-window:** with the vault open, in another terminal run
      `kill -9 $(pgrep -x EncryptedVault)` (or Force Quit in Activity Monitor).
- [ ] **7. Scan for durable plaintext immediately:**

      ```sh
      Tools/scan_leak.sh LEAKPROBE-7f3a
      ```

      Expect `PASS — no durable plaintext sentinel found.` This checks the vault
      dir, **Saved Application State**, caches, preferences, crash reports, and
      `$TMPDIR`. A hit is a release blocker.
- [ ] **8. Relaunch after the window has ended** → the launch performs the
      **defensive re-seal** (no prompt) and shows the lock screen; the vault is now
      sealed forward to the next window.
- [ ] **9. Offline test:** turn off Wi-Fi (or have a content filter block `api.drand.sh`) and
      relaunch during a window → it **fails closed** (locked/offline, **no**
      password prompt). Re-enable to recover.
- [ ] **10. Lock button** re-seals and re-locks without quitting.
- [ ] **11. Uninstall (do this last).** From the vault list, open the **•••** menu →
      **Uninstall application…**. Leave the checkbox **off** and confirm: the app
      moves *itself* to the Trash and quits. Verify the background helper is gone
      (`launchctl print gui/$(id -u)/app.encryptedvault.reseal` → "Could not find
      service", and `~/Library/LaunchAgents/app.encryptedvault.reseal.plist` is
      removed) while your data under `~/Library/Application Support/EncryptedVault`
      is **kept** (reinstall + launch re-creates the helper and re-opens the vaults).
      Then, on a throwaway vault, repeat with the checkbox **on**, type
      `delete my vaults`, and confirm → the data directory is removed too.

When all boxes are checked and `e2e_test` is green, the build is verified for real
use. Replace the throwaway sentinel with your real secrets on a
final clean run (and re-run `scan_leak.sh` once more with a throwaway probe first,
not the real secret).

---

## Final §11 hardening review (sign-off)

The §11 corner-case table, mapped to where each is enforced and proven:

| §11 corner / required test | Enforced in | Proven by |
|---|---|---|
| Roll clock back → seal to a past round | helper trusted-time (compiled-in chain, stale/too-near reject) | `helper` hermetic + `network_test.go`; live `e2e/seal-near-future` |
| Edit schedule + force-kill → out-of-window access | open/re-seal use the **manifest** interval, never the mutable schedule | `store_suite` (edit-schedule-can't-open); live `e2e/opens-at-round` gated on manifest |
| Stale `.bak` after a crash | defensive re-seal overwrites **both** files | `store_suite`; live `e2e/defensive-reseal` + `relocked-after-defensive` |
| Symlink/hardlink `vault.dat`/`.bak` | `SecureFile` O_NOFOLLOW, owner+0600, `st_nlink==1` | `store_suite` path/inode cases |
| OS/versioned backup keeps an expired vault | `isExcludedFromBackup` on the dir (re-verified) | `store_suite`; self-test `backupExclusion` |
| Copy plaintext during an open window | **accepted ceiling** (§2/§11) — privilege-independent | n/a (documented, social mitigation = a trusted third party's admin backup) |
| Seal to a future round, won't open early | unseal-as-gate (crypto) | live `e2e/locked-before-window` |
| Window-end / Lock / quit re-seal forward only (I8) | `VaultSession.reseal` forward guard + `nextLock` floors | `session_suite`; live `e2e/interactive-reseal-forward` |
| Force-kill after unseal, before password | nothing written; next launch re-seals or stays locked | live `e2e/defensive-reseal` (expired path); GUI step 6–8 |
| Offline at unlock | `load()` → `.offline`, no prompt; helper fails closed | `store_suite` (FakeSeal); live `e2e/offline-failclosed`; GUI step 9 |
| No durable plaintext after quit/crash | core dumps off, state restoration/autosave/undo off, hardened NSTextView, dir 0700/files 0600, no logging | `hardening_suite` + step-7d static guard; live `e2e/no-plaintext-*` + `files-0600`; GUI step 7 (`scan_leak.sh`) |
| Defensive re-seal is strictly passwordless | `VaultStore.defensiveReseal` takes no password; never decrypts | `store_suite` (no decrypt path); live `e2e/defensive-reseal` (store holds no password) |
| `.app` exposes no CLI/URL/document surface | Info.plist (no URLTypes/DocumentTypes); @main parses no argv | `build/bundling-gate`; GUI step 1 |

**The honest ceiling (unchanged, app.md §11):** this is a strong defense against
*impulsive* out-of-window access — the wall is real cryptography. It is **not** an
absolute cage against a *premeditated* owner who, during an open window, retains a
copy or replaces the user-writable `.app`/helper before a future window. That limit
is inherent to every local commitment device and is mitigated socially (a trusted
third party holds the admin-password backup). Code-signing + the self-test are **integrity**
checks, not a commitment boundary.

# HeldByTime — runtime flow chart

The complete decision map for the app at runtime: creating a vault, the authoritative
open/`load()` gate, unlocking, editing, leaving (clean vs. set-aside), the warm
in-RAM lifecycle, every re-seal trigger, window-end handling, and quit.

It renders as connected "scenes" — each box's exit (`══▶ SCENE n`) jumps to another
scene. Read the master map first, then drill into any branch.

> The schedule and the list badges are **advisory only**. Access is *never* granted from
> them — only from a drand-verified round plus the committed manifest, decided inside
> `VaultStore.load()` (Scene 3).

## Contents

- [Scene 0: Launch](#scene-0-launch)
- [Scene 1: Vault list, the hub](#scene-1-vault-list-the-hub)
- [Scene 2: Create a vault](#scene-2-create-a-vault)
- [Scene 3: Open a vault, the load() gate](#scene-3-open-a-vault-the-load-gate)
- [Scene 4: Unlock with password](#scene-4-unlock-with-password)
- [Scene 5: Editing and isDirty](#scene-5-editing-and-isdirty)
- [Scene 6: Leaving, clean vs set-aside](#scene-6-leaving-clean-vs-set-aside)
- [Scene 7: Warm lifecycle](#scene-7-warm-lifecycle)
- [Scene 8: Locking](#scene-8-locking)
- [Scene 9: Window-end while editing](#scene-9-window-end-while-editing)
- [Scene 10: Quit](#scene-10-quit)
- [Scene 11: Background re-seal agent](#scene-11-background-re-seal-agent)
- [Invariants every branch obeys](#invariants-every-branch-obeys)

---

## Master map

```
                    ┌──────────────────────────────────────────┐
                    │  SCENE 0  App launch / bootstrap          │
                    └───────────────────┬──────────────────────┘
                                        ▼
        ┌───────────────────────────────────────────────────────────┐
        │  SCENE 1  VAULT LIST (the hub) ◀──────────────────────┐    │
        └───┬─────────┬─────────┬─────────┬─────────┬───────────┘    │
            │New      │Open     │Rename   │Delete   │Export/Import    │
            ▼         ▼         │         │         │                 │
        SCENE 2   SCENE 3       └─(label)─┴─(unlink)┴─(bundle)────────┘
       (create)  (open→load gate)              all return to list
                     │
                     ▼ openWindow only
                 SCENE 4 (unlock) ─▶ SCENE 5 (edit) ─▶ SCENE 6 (leave)
                                          │                  │
                                          ▼                  ▼
                                   SCENE 8 (lock)     clean→list / dirty→SCENE 7 (warm)
                                   SCENE 9 (window-end)
                                   SCENE 10 (quit)

   Separate OS process, always running:  SCENE 11  Background re-seal agent
```

---

## Scene 0: Launch

```
app starts
  │
  ├─ ProcessHardening.disableCoreDumps()      (no secret can land in a core file)
  ├─ disable window-state restoration         (no editor text persisted across launches)
  ├─ purge obsolete single-vault layout
  ├─ (re)install background re-seal LaunchAgent  ── off-main ──▶ SCENE 11
  └─ refreshEntries()  ══▶ SCENE 1
```

`warmEdits` is **empty** at launch — set-aside stashes are RAM-only and never survive a
quit/crash (by design).

---

## Scene 1: Vault list, the hub

```
[LIST]  shows each vault with an ADVISORY badge (schedule-derived, NOT the lock state):
        • green "Open now — unlock with your password"   (schedule says in-window)
        • "Next window <date>"                            (schedule says closed)
        • orange "Unsaved edits kept in memory"           (warmEdits[id] present)

   user picks an action:
     ├─ New vault ............ ══▶ SCENE 2
     ├─ Open <vault> ......... ══▶ SCENE 3
     ├─ Rename .............. (label only; never part of the lock) ─▶ [LIST]
     ├─ Delete .............. type-to-confirm ─▶ unlink dir + drop warmEdits[id] ─▶ [LIST]
     ├─ Export/Import ....... .vault bundle (never decrypts) ─▶ [LIST]
     └─ Uninstall ........... remove agent (+ opt wipe data) ─▶ trash app
```

---

## Scene 2: Create a vault

```
beginCreate
  │
  ▼
registry.create(dir + default label)
  │   success                         failure
  ▼                                     └─▶ [FAILED screen]
[FIRST-RUN SETUP]
  user sets:  password  +  initial secrets/notes (starts with 1 blank row)  +  schedule
  │
  ├─ Cancel ─▶ delete the empty dir ─▶ [LIST]
  │
  └─ Finish ─▶ SEAL the initial content FORWARD to the first window (time-lock)
                 │
                 ▼
            apply chosen label + refresh agent triggers
                 │
                 ▼
            open(fresh vault) ══▶ SCENE 3
                 │
                 ▼
   ── because it was just sealed to a FUTURE window, load() classifies it
      futureClaimed ⇒ you land on the LOCKED screen until that window opens.
      (A commitment device: you can't read back what you just sealed.)
```

---

## Scene 3: Open a vault, the load() gate

This is the heart. The schedule is **never** consulted for access — only drand plus the
committed manifest.

```
open(entry)
  │   warmEdits[entry.id]?
  ├─ yes ─▶ reload(preferringStash: warm.payload)   (wire onUnlockedFromStash)
  └─ no  ─▶ reload()
                │
                ▼  [LOADING spinner]  — runs off-main
        VaultStore.load():

   STEP A  get drand verified round
     ├─ network fails ............................. ▶ result = .offline
     └─ round older than local clock (stale) ...... ▶ result = .offline

   STEP B  classify vault.dat AND vault.dat.bak (each independently):
     each file → one of:
        missing | unreadable | corrupt | tampered      ← unusable
        indeterminate                                  ← offline mid-check (can't tell)
        futureClaimed                                  ← sealed to a FUTURE round (locked)
        openWindow                                     ← unsealed, start ≤ R ≤ end  ✅
        expired                                        ← unsealed, R > end (recoverable)

   STEP C  decide(primary, backup)  — total 8×8 matrix, fail-closed:
     ┌─────────────────────────────────────────────┬──────────────────────────┐
     │ condition                                    │ action  → load result    │
     ├─────────────────────────────────────────────┼──────────────────────────┤
     │ indeterminate anywhere                       │ LOCKED  → .lockedUntil   │
     │ an openWindow copy AND no futureClaimed      │ OPEN    → .openWindow ✅ │
     │ openWindow BUT a futureClaimed also present  │ LOCKED  → .lockedUntil   │  (future vetoes)
     │ futureClaimed + sibling missing/corrupt/bad  │ SYNC    → .lockedUntil   │  (restore .bak)
     │ futureClaimed dishonest pairing              │ LOCKED  → .lockedUntil   │
     │ expired (no open, no future)                 │ RESEAL  → .resealed      │  (forward, passwordless)
     │   └─ reseal write fails                      │         → .failClosed    │
     │ nothing usable                               │ FAIL    → .failClosed    │
     └─────────────────────────────────────────────┴──────────────────────────┘
```

Then the UI maps the result (`applyLoadResult`):

```
   result is .openWindow(window, diskPayload)?
     │
     ├─ a pending STASH whose window == this window?   (re-entry, SCENE 7)
     │     ├─ yes ─▶ [UNLOCK PROMPT] fed the STASH payload   (reenteredFromStash = true)
     │     └─ no  ─▶ [UNLOCK PROMPT] fed the DISK payload     (stash dropped, AppModel keeps warm copy)
     │                                                          ══▶ SCENE 4
     │
   .lockedUntil / .resealed / .offline / .failClosed
     └─▶ [LOCKED SCREEN]  with the matching message:
            • "locked until <round/date>"     (lockedUntil)
            • "re-sealed forward; now locked" (resealed — was expired)
            • "offline — couldn't reach the time-lock network" (offline)
            • "no usable vault copy"          (failClosed)
         from here: Back ══▶ SCENE 1   (nothing decrypted, nothing to seal)
```

---

## Scene 4: Unlock with password

```
[UNLOCK PROMPT]  user types password, hits Unlock
  │
  ▼  [isUnlocking spinner]  — Argon2id off-main (deliberately ~1s, the cost that protects an expired blob)
VaultSession.open(window, payload, password):
     re-derive key from salt in PW01 header → AES-GCM open (tag verified BEFORE any plaintext)
  │
  ├─ FAILURE (wrong password / corrupt) ─▶ unlockError "Could not unlock…"   (stay at prompt, retry)
  │        └─ deliberately generic: no password-vs-corrupt oracle, no partial plaintext
  │
  └─ SUCCESS ─▶ decode notes
        ├─ decode fails ─▶ [FAILED screen] "decrypted but contents unreadable"  (never partial content)
        └─ decode ok ─▶ [UNLOCKED editor]   ══▶ SCENE 5
                          • content = notes, baseline = notes
                          • if reenteredFromStash: onUnlockedFromStash() ⇒ AppModel drops warm copy
                          • arm the while-open window-end monitor (SCENE 9)
```

---

## Scene 5: Editing and isDirty

```
[UNLOCKED editor]  — edit notes / add / reveal / copy / delete secrets

   isDirty  =  unlocked  AND ( reenteredFromStash  OR  content ≠ baseline )
                                     │                      │
                       came back from a stash       made an actual change
                       (newer than disk even
                        with no new edit)

   from here the user can:
     ├─ Lock now ............ ══▶ SCENE 8 (reseal, stay in app)
     ├─ Back ................ ══▶ SCENE 6 (leave)
     ├─ Cmd-Q ............... ══▶ SCENE 10 (quit)
     ├─ Settings ............ edit schedule (never grants access; refreshes agent triggers)
     └─ (window ends) ....... ══▶ SCENE 9 (forced re-lock)
```

---

## Scene 6: Leaving, clean vs set-aside

```
Back pressed  →  closeCurrent():

   isDirty AND unlocked?
     │
     ├─ NO (clean, or not unlocked) ─▶ setDown()  (zero plaintext, stop timer; DISK untouched,
     │                                  still openable this window with the password) ══▶ SCENE 1
     │
     └─ YES ─▶ prepareSetAside()   [Setting aside… overlay]
                 │   off-main: encode notes → makeSetAsidePayload
                 │     = manifest(openWindow) ‖ FRESH-PW01(edits)   (fresh salt+nonce; NO disk, NO network)
                 │
                 ├─ encode over cap ─▶ completion(nil) ─▶ sealError shown, EDITOR STAYS
                 │                                         (edits never silently lost)
                 │
                 └─ payload ─▶ warmEdits[id] = WarmStash(payload, openWindow, store, logURL)
                               arm 60s warm monitor → setDown() ══▶ SCENE 1   (now WARM, SCENE 7)
```

The on-disk blob still holds the **last sealed** content; the **newer** edits live only in
`warmEdits` (RAM).

---

## Scene 7: Warm lifecycle

A warm vault (set aside in RAM) has three possible fates:

```
[WARM]  warmEdits[id] present, vault off-screen, list shows orange badge

  (1) RE-ENTER  (user taps Open) ─▶ SCENE 3 with preferringStash
        load() confirms same open window?
          ├─ yes ─▶ prompt fed the STASH (newer edits); on unlock, warm copy dropped → live session owns it
          └─ no  ─▶ stash dropped UNUSED (never decrypt outside its window); warm copy retained to seal later

  (2) WINDOW ENDS  (60s warm monitor, pollWarmStashes — skips the on-screen vault)
        for each off-screen stash:  verified round > openWindow.endRound  AND not stale?
          ├─ yes ─▶ defensiveReseal(stash) FORWARD (passwordless, PW01 reused verbatim)
          │           └─ success ─▶ remove from warmEdits, log "re-sealed forward", refresh list
          └─ no  ─▶ leave it (offline / still in window) — ciphertext, safe to hold, retry next tick

  (3) QUIT  ─▶ SCENE 10
```

---

## Scene 8: Locking

All re-seal triggers funnel into one engine.

```
trigger: Lock now | Cmd-Q-save | window-end-while-open
  │
  ▼  [Sealing… spinner]  VaultSession.reseal(notes, trigger):
   1. drand verified round?  ── offline/stale ─▶ FAIL
   2. schedule.nextLock → next FUTURE window  ── none ─▶ FAIL
   3. forward-only guard: target.start > R   ── else ─▶ FAIL   (I8 anti-shortening)
   4. FRESH salt + FRESH nonce, re-derive key, AES-GCM seal   (no two saves share key+nonce)
   5. tlock-seal manifest‖PW01 → durable two-file write (delete old .bak FIRST) → verify
  │
  ├─ SUCCESS ─▶ drop plaintext+baseline ─▶ [LOCKED SCREEN] "locked until next window"
  └─ FAILURE ─▶ sealError "couldn't re-lock (online?)… notes unchanged on disk", VAULT STAYS OPEN
                  (never a silent unsealed state)
```

---

## Scene 9: Window-end while editing

```
60s while-open monitor (pollWindowEnd), also fired on app-activation / wake-from-sleep:
   fetch verified round
     │
     └─ round > committed openWindow.endRound?
          ├─ no  ─▶ keep editing (still in window / offline / malformed reply = no-op, retry)
          └─ yes ─▶ relockForWindowEnd()  (POSITIVE confirmation — plaintext goes regardless):
                      reseal current content forward
                        ├─ success ─▶ [LOCKED] "locked until next window"
                        └─ failure ─▶ clear plaintext anyway ─▶ [LOCKED] "offline"
                                       (the agent / next-launch defensive reseal closes the blob)
```

---

## Scene 10: Quit

Cmd-Q / menu / last window closed.

```
applicationShouldTerminate:
   hasUnsavedWork? = (open dirty editor)  OR  (any warmEdits)
     │
     ├─ NO ─▶ terminate NOW   (clean/locked vaults seal nothing; reopen with password this window)
     │
     └─ YES ─▶ alert "Quit with unsaved changes?" (singular/plural by count):
                 ├─ Seal & Quit ─▶ sealAllForQuit():
                 │      seal the open dirty session + every warm stash (forward, passwordless for stashes)
                 │        ├─ ALL succeeded ─▶ terminate NOW
                 │        └─ ANY failed (offline) ─▶ CANCEL quit (sealed ones gone from warm,
                 │                                    the rest stay in RAM & visible — never silent loss)
                 ├─ Discard & Quit ─▶ terminate NOW   (in-RAM edits lost; disk blobs stay openable this window)
                 └─ Cancel ─▶ stay
```

---

## Scene 11: Background re-seal agent

A separate OS process (`LaunchAgent`), reveal-incapable.

```
woken periodically + right after each vault's window-end (calendar triggers):
   for EVERY vault:  run load()  (same authoritative gate, SCENE 3 STEP A–C)
     └─ expired ─▶ defensiveReseal FORWARD (passwordless) → log "agent ran → re-sealed forward"
   ── it can NEVER reveal: no password, no decrypt. It only closes expired blobs forward.
```

---

## Invariants every branch obeys

- **`load()` is the only gate.** Schedule/badges are advisory; access needs drand + the committed manifest.
- **Fail-closed everywhere.** Offline / stale / can't-classify / can't-write ⇒ no access, no risky write.
- **Forward-only (I8).** Every reseal — interactive, defensive, warm-monitor, quit — targets a strictly future window.
- **No durable plaintext, ever.** Warm stashes are RAM-only ciphertext; a disk-resident password-openable blob mid-window would be the forbidden escape hatch.
- **One crypto shape.** Stash = `manifest ‖ PW01` = a load payload, so re-entry reuses `VaultSession.open` and window-end sealing reuses `defensiveReseal` verbatim.

> Known soft spot: the Scene 7-(2) warm-monitor seal can race a Scene 3 `load()` defensive
> reseal of the same vault at the exact window boundary. Both produce valid forward seals;
> only *which valid version wins* is at stake, for the already-volatile set-aside edits. No
> corruption, no plaintext exposure. The class-wide fix would be a per-vault `flock` around
> `writeVaultPair` (shared with the agent).

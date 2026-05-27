# EncryptedVault

A native macOS app for notes and secrets that can **only be opened during time
windows you choose** — and the restriction holds even for you, the owner.

Most "locked" apps just put a password in front of your data. But if you know the
password, nothing actually stops you from opening it whenever you want. The lock
is a suggestion. EncryptedVault is different: outside your chosen window, the key
to decrypt the vault **does not exist on your machine yet**. There is nothing to
bypass, because there is nothing to unlock.

---

## Why you might want this

Some things are better on a schedule than on demand. EncryptedVault lets you put
that schedule into the data itself instead of relying on willpower or a setting
you can quietly turn off.

- **Time-boxed access to credentials.** Keep passwords, recovery codes, or account
  logins reachable only during a set window each day, rather than always-on.
- **A deliberate pause.** Make certain content available only at a planned time,
  so opening it is a decision you made in advance, not an impulse.
- **A commitment you can't casually undo.** Once a window closes, the vault re-seals
  forward to the next one automatically — there's no "just this once" override,
  because the math doesn't have one.

It's a tool for people who'd rather design their access up front than re-decide it
every day.

---

## How it works

Two independent locks protect every vault:

1. **Time-lock (the outer lock).** The vault is sealed with
   [time-lock cryptography](https://drand.love/) — built on the public **drand**
   randomness beacon. Each window corresponds to a future beacon round, and the
   key needed to open the vault is only derivable *once that round has been
   published*. Your Mac's clock plays no part in granting access: changing the
   system time, using the Terminal, or editing the app does nothing. Only the real
   beacon, reached over the network, can open the door — and only on schedule.

2. **Password (the inner lock).** Inside the time-lock, the contents are encrypted
   with **AES-256-GCM**, with your key stretched by **Argon2id**. So even a copy of
   the sealed file is useless to anyone without your password.

When a window ends — or when you lock the vault, quit, or relaunch — the app
**re-seals forward** to the next window. A small background helper also re-seals
any expired vault on a schedule, so a vault left open isn't left open. The
background helper can *only* re-seal; it can never reveal contents.

You can keep **multiple independent vaults**, each on its own daily schedule.

---

## What it guarantees (and what it doesn't)

Being honest about the boundaries is part of the design.

| | |
|---|---|
| **Can't open before the window** | ✅ Enforced by cryptography — not a clock check, not bypassable by changing the time or using the Terminal. |
| **A stolen file stays unreadable** | ✅ Protected by the password + AES layer. |
| **Can't read after the window ends** | ✅ The app re-seals forward on lock, quit, relaunch, and on a background timer. |
| **During an open window** | The contents are fully available — you can read, copy, and use them. That's the point of the window. |
| **A forgotten password** | There is no backdoor and no recovery. A lost password means the contents are gone for good. |

In short: it's a strong, real wall against opening something *outside* the time you
set for yourself. It is not a cage against someone who, during an open window,
deliberately copies the contents elsewhere — no local tool can prevent that.

---

## Requirements

- **macOS on Apple Silicon.** Distributed as a normal double-clickable `.app` —
  there is no command-line tool to run and no setup in a terminal.
- **A network connection.** Opening and sealing a vault contacts the drand beacon
  (`api.drand.sh`). If your network filters outbound traffic, that host must be
  allowed, or vaults won't be able to open. The app's first-run check verifies
  this before you store anything.
- **No administrator account needed.** It runs entirely as a standard user.

---

## First run

On first launch, the app runs a quick on-device check — confirming encryption
works on your machine and that the time-lock network is reachable — *before* you
store anything. Once that passes, you choose a password, set one or more daily
windows, add your notes and secrets, and create the vault. It seals immediately to
the next window.

> **Important:** your password is the only thing that can ever open the vault's
> contents, and there is no way to recover it. Choose something you won't forget,
> and don't store the vault in Time Machine, iCloud, or any synced folder.

---

## Building from source

```sh
./build.sh          # runs the full test gate, then produces build/dist/EncryptedVault.app
```

`build.sh` won't produce an app unless the test suite passes first. For the live,
across-a-real-window verification steps, see [E2E.md](E2E.md). The on-disk file
format is documented in [FORMAT.md](FORMAT.md), the design rationale in
[app.md](app.md), and the non-negotiable security properties in
[SECURITY_INVARIANTS.md](SECURITY_INVARIANTS.md).

# Contributing to HeldByTime

HeldByTime is a time-locked vault for macOS — a *commitment device* that is
deliberately adversarial to its own owner's future self. Because of that, the bar
for changes is unusual: a contribution that merely **works** is not enough; it must
not weaken any of the security invariants the whole design rests on. This guide
covers how to set up, build, and test — and the non-negotiables to respect.

> There is no build server doing the thinking for you: `build.sh` refuses to
> assemble the app unless the full test suite is green. Treat `./run_tests` as the
> contract.

---

## 🧰 Prerequisites

You need an **Apple-Silicon Mac on macOS 14+** (the build produces and *asserts*
arm64-only binaries) and three things installed:

| Tool | Why it's needed | Install |
|---|---|---|
| **Xcode Command Line Tools** | `swiftc`/`swift` (the app + engine) and `clang` (the Argon2 C library) | `xcode-select --install` |
| **Go ≥ 1.26** | builds `vaultseal`, the drand time-lock helper (see `helper/go.mod`) | `brew install go` |
| Standard macOS CLI — `codesign`, `plutil`, `sips`, `iconutil`, `otool`, `ditto`, `shasum`, … | bundle assembly + signing in `build.sh` | already on macOS — nothing to install |

That's the whole list. The toolchain in [`.github/workflows/release.yml`](.github/workflows/release.yml)
is the source of truth and matches the above.

**Dependencies are vendored and pinned**, so the build is hermetic — no
`go mod download`, no network fetch:

- `vendor/argon2/` — the Argon2id C source, compiled into a static lib.
- `helper/vendor/` — the Go module tree (drand / tlock / …), enforced at test time
  by `go mod verify` and `go build -mod=vendor`.

> 💡 *Learned the hard way:* if Go got onto your machine as a Homebrew **dependency**,
> `brew autoremove` can silently remove it (and then `build.sh` fails at the gate with
> `go: command not found`). `brew install go` marks it *installed on request*, which
> `autoremove` won't touch.

---

## 🔨 Build & test

```sh
./run_tests        # the gate — every check must pass (FAIL=0)
./build.sh         # runs ./run_tests first, then assembles + signs build/dist/HeldByTime.app
```

- `run_tests` builds the Swift engine + app offline, runs the Go helper's tests, and
  enforces the guards below. A single red check fails the whole run.
- `build.sh` will **not** produce an app if the gate is red — so any app from this
  official path has passed the suite. `build/` is gitignored and ephemeral.
- Live, across-a-real-time-window verification (the part a unit test can't cover) is
  in **[docs/E2E.md](docs/E2E.md)**. Walk it for anything touching seal / unseal /
  re-seal.

If a check ever flakes with `input file '…' was modified during the build`, that's
swiftc noticing a source file's timestamp changed mid-compile (e.g. an editor or
file-watcher touched it) — re-run; it isn't a code failure.

---

## 🗺️ Repo map

| Path | What it is |
|---|---|
| `Sources/VaultCore/` | The headless security **engine** — sealing, unsealing, schedule, re-seal. **No SwiftUI/AppKit.** |
| `Sources/VaultApp/` | The SwiftUI app (`Views/` + models). A few non-UI files here are also compiled *headless* into the test binary. |
| `Sources/ResealAgent/` | The reveal-incapable background re-seal helper (`main.swift`). |
| `Sources/Constants/` + `spec/constants.json` | Single source of truth for protocol constants. |
| `helper/` | The Go `vaultseal` time-lock helper (`cmd/`, `internal/`, vendored deps). |
| `vendor/argon2/` | Vendored Argon2id C source. |
| `tests/` | Swift test suites (+ `tests/e2e/`); run via `./run_tests`. |
| `docs/` | Design (`app.md`), file format (`FORMAT.md`), invariants (`SECURITY_INVARIANTS.md`), live checks (`E2E.md`). |

---

## 🚫 Ground rules (non-negotiable)

These are enforced by the test gate **and** by review. The full set with rationale is
**[docs/SECURITY_INVARIANTS.md](docs/SECURITY_INVARIANTS.md)** (I1–I14). The ones a
change is most likely to trip:

- **Keep `./run_tests` green, and add tests for new behavior.** It's the gate
  `build.sh` enforces; a red PR cannot ship.
- **Fail closed; never weaken (I1, I5, I14).** No escape-hatch backup, no recovery
  path, no privilege escalation. The app runs as a **standard user with zero admin
  rights** — never add a fallback that assumes more, or that opens a vault any way
  other than *the right password during an open window*.
- **No secret ever reaches durable storage or a log (I13).** The activity log is
  secret-free by construction, and specific files sit under a no-`print`/`NSLog` fence
  (the `leak/guard` check). Never log a password, plaintext, or vault contents.
- **Forward-only (I8).** A vault's unlock time can only move *later*, never earlier —
  nothing may shorten an existing lock.
- **The engine stays headless.** `Sources/VaultCore` must not import
  SwiftUI/AppKit/Cocoa, and the specific `Sources/VaultApp` files pulled into the
  offline test binary must stay UI-free too (the `scope/ui-import` and
  `scope/app-headless` guards). This keeps the security logic unit-testable without a
  GUI.
- **Dependencies stay vendored & pinned (I9).** Don't add an un-vendored module. To
  change a Go dependency: edit `go.mod`, run `go mod vendor`, and commit
  `helper/vendor/` so `go mod verify` passes.
- **Constants have one source (I11).** `spec/constants.json` == Swift == Go ==
  `docs/FORMAT.md`; the consistency check fails if they drift. Change them together.
- **No developer escape hatch in the shipped binary (I14).** No dry-run / debug
  surface in release builds (the `dryrun/release-gate` check).
- **Keep personal identity out of the app.** The bundle must reveal no author
  identity; attribution lives only in `LICENSE` and the README badge.

---

## 📬 Submitting changes

1. Branch off `main`.
2. Make your change **with tests**, and confirm `./run_tests` is green. For anything
   on the lock / unlock / re-seal path, also walk the relevant **[docs/E2E.md](docs/E2E.md)**
   steps — unit tests can't cross a real time window.
3. Write a clear commit message describing the *why*, not just the *what*.
4. Open a PR. Expect review focused on the invariants above; if your change touches
   one, explain how it stays within it.

Thanks for contributing — and for respecting that, here, "secure" beats "convenient"
every time.

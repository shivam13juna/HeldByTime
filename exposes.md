# Public Exposure Checklist

This file lists the ways this repository can expose personal or private context if
made public. It focuses on privacy/identity leakage, not only credential leakage.

## 1. Git Commit Identity

The Git history currently exposes the commit author name and email:

- Name: `Shivam prasad`
- Email: `shivam13juna@gmail.com`

This appears in normal GitHub commit views and remains visible in history unless
the repository is rewritten or published as a fresh cleaned repository.

Mitigations:

- Use GitHub's noreply email for future commits.
- Consider publishing a fresh repo with a clean initial commit.
- If preserving history, rewrite author metadata before making it public.

## 2. GitHub Username And Repository URL

The remote and README badge expose the GitHub account/repo:

- `git@github.com:shivam13juna/mac-encryptor-app.git`
- README release badge for `shivam13juna/mac-encryptor-app`

This ties the project to the `shivam13juna` account.

Mitigations:

- Accept this if the project is intentionally under that account.
- Otherwise publish under an organization or alternate account.
- Update README badges and release links before public release.

## 3. License Name

`LICENSE` contains:

- `Copyright (c) 2026 Shivam Prasad`

This exposes a real name.

Mitigations:

- Keep it if you want legal attribution under your real name.
- Use a handle or organization name if you prefer less personal attribution.

## 4. Bundle Identifier

The app bundle identifier exposes the first name:

- `com.shivam.encryptedvault`

Locations:

- `build.sh`
- `Tools/scan_leak.sh`
- generated app `Info.plist`
- macOS saved-state/cache/preference paths after install

Installed artifacts may include paths such as:

- `~/Library/Preferences/com.shivam.encryptedvault.plist`
- `~/Library/Caches/com.shivam.encryptedvault`
- `~/Library/Saved Application State/com.shivam.encryptedvault.savedState`

Mitigations:

- Rename to a generic identifier before public release, e.g.
  `app.encryptedvault` or `org.encryptedvault.app`.
- If using a GitHub namespace, use `io.github.<handle>.encryptedvault`, but note
  that this still exposes the handle.

## 5. LaunchAgent Identifier

The background reseal LaunchAgent label exposes the first name:

- `com.shivam.encryptedvault.reseal`

Installed artifact:

- `~/Library/LaunchAgents/com.shivam.encryptedvault.reseal.plist`

This is visible in the source and on machines where the app is installed.

Mitigations:

- Rename the label before public release, e.g. `app.encryptedvault.reseal`.
- Update tests and scripts that reference the old identifier.

## 6. Personal Threat Model In Docs

Several docs reveal a specific personal setup:

- standard macOS account
- no self-held admin authentication
- Mac admin password backed up by a trusted third party
- references to a sister
- Canopy website filter
- Canopy password stored in the vault
- macOS admin password stored in the vault
- self-control / lesser-self / future-self framing

Most explicit files:

- `app.md`
- `E2E.md`
- `done_so_far.md`
- `improvements.md`

This does not reveal actual passwords, but it reveals how the system is used and
who may hold recovery material.

Mitigations:

- Remove `done_so_far.md` from the public repo.
- Rewrite `app.md` as a generic threat model.
- Rewrite `E2E.md` to use generic examples.
- Replace "sister" with "trusted third party" if the detail is still needed.
- Replace "Canopy" with "network filter" unless naming it is important.
- Avoid naming exact secrets like "my macOS admin password" in public docs.

## 7. Public Bypass Analysis

`improvements.md` documents bypass scenarios and fixes. This can be useful for
review, but it also tells readers exactly where the current implementation is
weak, including:

- missing window-end auto-lock wiring
- failed reseal on quit
- expired-blob gap
- LaunchAgent interference
- mutable schedule policy
- helper ergonomics

Mitigations:

- Keep it private until the high-priority issues are fixed.
- Or publish it intentionally as a security roadmap.
- If public, make sure it does not include personal details.

## 8. Test Fixtures With Example Secrets

Tests include fake/example values such as:

- `hunter2`
- `swordfish`
- `correct horse battery staple`
- labels like `macOS admin password`
- labels like `Canopy password`

These do not appear to be real secrets, but public readers may still infer the
real categories of secrets this app was built to protect.

Mitigations:

- Replace labels with generic examples like `Example account` and `Example code`.
- Keep test values obviously fake.

## 9. App/Release Branding

The README and release workflow expose:

- app name: `EncryptedVault`
- release repo path under `shivam13juna`
- ad-hoc signing status
- Apple Silicon/macOS target

This is not private by itself, but combined with GitHub identity it links the
project, release artifacts, and installed app identity back to the same person.

Mitigations:

- Decide whether the app is personally branded or project-branded.
- If project-branded, update bundle IDs, release links, and README badges.

## 10. Local Paths In Generated Output

Tracked source does not appear to contain local absolute paths like
`/Users/shivam13juna/...`, but command outputs and generated build artifacts can.
The `build/` directory is ignored and should not be committed.

Mitigations:

- Keep `build/` ignored.
- Do not commit command logs.
- Re-run `git status --short` before making the repo public.

## 11. Assets

Tracked PNG assets do not appear to carry obvious EXIF-style metadata from the
basic `sips` inspection. However, images can still visually reveal personal
branding or design traces.

Current assets:

- `assets/icon.png`
- `assets/cover_image.png`
- `assets/v1_icon.png`
- untracked `assets/v2_icon.png`

Mitigations:

- Review images visually before publishing.
- Decide whether `assets/v2_icon.png` should be committed or ignored.
- Strip metadata if using externally created assets.

## 12. Vendored Dependencies

Vendored dependency code does not expose personal information, but it makes the
repo large and public scanners will inspect it. It can also include upstream
metadata, licenses, and test vectors.

Mitigations:

- Keep vendoring if reproducibility is worth it.
- Otherwise document dependency fetching and remove vendored trees.

## Current Assessment

No actual private keys, API tokens, vault files, or real plaintext passwords were
found in the source scan.

The main public exposure risk is personal identity and operational context:

- real name
- personal Gmail
- GitHub handle
- `com.shivam...` app and LaunchAgent identifiers
- sister/trusted-third-party recovery setup
- Canopy/network-filter setup
- categories of secrets stored in the vault
- detailed bypass/security roadmap

For a public release, prefer a scrubbed public repo or a fresh public initial
commit after renaming identifiers and sanitizing the personal docs.

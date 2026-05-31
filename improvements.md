# Commitment-Device Bypass Scenarios And Fixes

This document is written for the actual goal of this repo: a standard-account
macOS user wants access only during clear-headed morning windows, and wants the
app to block impulsive access at weaker times.

The threat model here is not "an admin/root attacker can never extract anything."
It is "same user, standard account, knows the password, may be tempted later, and
should not have a cheap path to open the vault outside the intended window."

## Priority Summary

1. Wire forced window-end locking. This is the largest current bypass.
2. Fail closed on quit/close when reseal fails.
3. Shrink the expired-blob exposure window after a morning window has passed.
4. Treat schedule changes as protected policy, not ordinary preferences.
5. Pin schedule time zone and harden schedule persistence.
6. Reduce the ergonomics of manual outer time-lock tooling.

## 1. Unlocked App Left Open After The Morning Window

### Scenario

The user opens the vault in the morning, reads or edits secrets, then leaves the
app open. Later, during a weaker time, the app may still show plaintext.

The repo has the core primitive for this:

- `VaultSession.hasWindowEnded(verifiedRound:)`
- `VaultSession.Trigger.windowEndReached`

But the UI/model layer does not appear to call it. This makes the "window end"
reseal trigger mostly aspirational.

### Impact

This directly defeats the main commitment-device goal. It does not require admin
rights, terminal skills, helper tooling, or crypto attacks. It is just leaving the
window open.

### Fix

Add a forced window-end monitor while the vault is unlocked:

- Start a timer when entering `.unlocked`.
- Poll `VaultSealClient.currentRound()` periodically.
- If `session.hasWindowEnded(verifiedRound:)` returns true, immediately call
  `session.reseal(notes:trigger: .windowEndReached)`.
- Clear `VaultModel.content` before or immediately after the transition.
- Also run the same check on app activation and wake-from-sleep notifications.

Recommended behavior:

- If reseal succeeds: transition to locked.
- If reseal fails because offline/stale/no valid future window: hide plaintext
  anyway, show a blocking "cannot safely reseal" state, and retry in the
  background until it succeeds.

## 2. Quit Or Close While Reseal Fails

### Scenario

The user opens the vault during the morning window. Later, the app tries to reseal
on quit/close, but reseal fails because the network is unavailable, drand is
blocked, the latest round is stale, or the schedule cannot produce a future
window.

Currently, `VaultModel.sealForQuit()` calls `lock(trigger: .gracefulQuit)` but
returns `true` regardless of whether `lock()` succeeded.

### Impact

After the start round has been published, the outer time-lock is no longer the
barrier. If reseal fails, the on-disk file can remain protected only by the
password layer until a later defensive reseal succeeds. For this use case, that
is a bypass path: later self already knows the password.

### Fix

Make quit/close fail closed:

- If the vault is unlocked and reseal fails, return `.terminateCancel`.
- Keep the app open in a blocking "reseal required" state.
- Hide plaintext while retrying reseal.
- Offer only non-secret diagnostics and retry controls.

If you want an emergency escape, it should not leave plaintext visible or silently
permit a password-only blob. The default should be: no reseal, no quit.

## 3. Expired Blob Gap After A Morning Window

### Scenario

Once a drand round is published, it is public forever. A vault sealed to that
round can be outer-unsealed forever unless the app or agent reseals it forward.

The background `vaultreseal` LaunchAgent is meant to close this gap, but it runs
as the same standard user and currently uses a broad interval. Same-user future
self can also interfere with their own LaunchAgent.

### Impact

This is not a pre-morning bypass. Before the start round exists, password alone
does not help. The risk is after a morning window has started or passed: if an
expired blob survives, later self may be able to use the password layer directly
after stripping the time-lock.

### Fix

Reduce the time an expired blob can exist:

- Lower `LaunchAgentPlist.defaultIntervalSeconds` from 2 hours to something like
  1-5 minutes.
- Add a scheduled run near each window end, not only interval polling.
- Run the agent on wake and app launch.
- Surface "last agent run" and "last successful reseal" prominently in the app.
- If the agent has not run recently, show a warning during morning use.

Hard truth: a same-user LaunchAgent is not a hard security boundary. It is useful
friction and cleanup, not an authority stronger than the user.

## 4. Disabling Or Interfering With The Reseal Agent

### Scenario

Because the agent is installed in the user's LaunchAgents domain, the same
standard account can disable it, unload it, edit the plist, block its network, or
delete the app bundle that contains the helper.

### Impact

This turns "expired blob gap is short" into "expired blob gap lasts until the app
is launched again and successfully reseals." That creates an impulse path after
the morning round has been published.

### Fix

Improve tamper visibility and reduce reliance on the agent:

- On every app launch, verify the LaunchAgent is installed and points at the
  current bundle.
- Record agent failures in secret-free diagnostics.
- Show a non-dismissable warning if the agent is missing or stale.
- Prefer in-app window-end locking as the primary protection.
- Treat the agent as a cleanup net, not the main enforcement path.

A stronger always-on service would require admin-level installation, which is
outside your current standard-account constraint.

## 5. Schedule Changes During Clear-Headed Access

### Scenario

While the vault is open, the user can open Settings and change future windows.
You said morning-you will not intentionally schedule evening access, so this may
be acceptable socially. But technically, the schedule is mutable policy and is
stored outside the sealed payload.

Direct edits to `schedule.json` also affect the next reseal target.

### Impact

Changing the schedule does not open the currently sealed vault early, because
authorization comes from the manifest inside the time-locked payload. But it can
affect where the next reseal points. That means policy can drift without the same
ceremony as editing the protected content.

### Fix Options

Choose one policy:

- Immutable schedule: set morning windows at creation and never edit them.
- Delayed schedule changes: edits take effect after 24-72 hours.
- Narrowing-only edits: allow removing/reducing windows immediately, but delay
  widening or adding windows.
- Seal schedule policy inside the vault content and commit it in the manifest.

For your stated goal, immutable or delayed schedule changes are the cleanest.

## 6. Time Zone Drift

### Scenario

Schedule mapping uses the current local calendar/time zone. If the system time
zone changes before a reseal, "04:00 morning" can map to a different absolute
drand round.

On a standard account, changing system time itself is usually blocked, but time
zone changes may be easier depending on system settings.

### Impact

This does not forge drand or open an existing seal early. It can affect future
reseal targets, which matters for a strict "morning only" policy.

### Fix

Persist a vault time zone at creation:

- Add `timeZoneIdentifier` to `schedule.json`.
- Build `Schedule.calendar` from that stored time zone.
- Do not use `Calendar.current` for committed policy.
- Show the pinned time zone in Settings.

## 7. Manual Use Of The Bundled Helper After Start Round

### Scenario

The shipped app includes `vaultseal`, a small helper that can `unseal` and `seal`.
That is good separation, but it also gives technical future self a ready-made
tool for manipulating the outer time-lock after the target round has published.

It still cannot decrypt the inner AES layer without the password. But your threat
model assumes later self knows the password.

### Impact

Before the morning round, this does not help. After the morning round, if reseal
has not happened, it lowers the effort needed to unwrap the outer layer.

### Fix Options

- Keep the helper but rely on faster resealing and better window-end locking.
- Move helper functionality behind a less convenient app-only boundary.
- Do not ship extra debug or dry-run surfaces in release. The repo already gates
  `DryRun.swift` behind `DEBUG`; keep that invariant.

This is an ergonomics/friction issue, not the main cryptographic boundary.

## 8. Copying Or Exporting Secrets During The Morning Window

### Scenario

During an authorized morning window, clear-headed self can copy secrets elsewhere,
take screenshots, save notes, or manually write them into another app.

### Impact

No local app can cryptographically prevent this once it deliberately reveals
plaintext. This is the honest ceiling of any commitment device.

### Fix

Use product friction, not fake security claims:

- Keep secrets masked by default.
- Require explicit reveal per secret.
- Auto-hide revealed secret values after a short interval.
- Add a morning-only "review mode" that reveals one item at a time.
- Avoid clipboard convenience for high-risk secrets, or clear clipboard after a
  short delay if copying is added later.

## 9. Creating A Parallel Vault Or External Copy

### Scenario

During morning access, the user could create another vault with weaker windows,
copy the plaintext elsewhere, or save a duplicate outside the app.

### Impact

This is another authorized-window limitation. The app cannot prevent deliberate
exfiltration while access is allowed.

### Fix

Reduce accidental paths:

- Do not add export features.
- Do not add "duplicate vault" features that copy plaintext.
- Make new-vault creation from existing content impossible without re-entering
  content manually.
- Consider a warning when creating a vault with broad windows.

## 10. Missing Backup Exclusion

### Scenario

The test `store/load/ensure-dir-excluded` currently failed on this machine. The
directory did get a backup-exclusion xattr, but Foundation did not report
`isExcludedFromBackup == true` in the test run.

### Impact

If backup exclusion is unreliable, old sealed files can end up in Time Machine,
iCloud, or another backup system. Old copies may later become expired/password-only
artifacts after their drand round has published.

### Fix

Treat this as release-blocking until understood:

- Make backup-exclusion verification reliable on the supported macOS versions.
- Consider checking the backup-exclusion xattr directly as a fallback.
- Warn during first-run self-test if the exclusion cannot be verified.
- Keep telling users not to put vault dirs in synced or backed-up locations.

## 11. Build Or Local-Dev Surface Confusion

### Scenario

A local developer build has an empty `BundledHelper.sha256`, so helper preflight
fails closed unless built through `build.sh`. This is safe, but confusing. A
future local build could accidentally introduce a debug surface or helper hash
sidecar if the release gates are weakened.

### Impact

Mostly maintenance risk. The current repo has useful gates for this.

### Fix

Keep these release invariants:

- `build.sh` must inject the signed helper hash into the binary.
- Release builds must not include `DEBUG` dry-run surfaces.
- No URL scheme, CLI unlock, debug menu, env override, endpoint override, or
  chain override.
- `run_tests` should remain a hard pre-build gate.

## Recommended Implementation Order

1. Add unlocked-session window-end enforcement.
2. Change quit/close behavior so failed reseal cancels termination.
3. Clear plaintext immediately on any window-end or reseal-failure transition.
4. Lower the reseal agent interval and add wake/window-end runs.
5. Pin the schedule time zone.
6. Decide whether schedule edits are immutable, delayed, or narrowing-only.
7. Fix and harden backup-exclusion verification.
8. Add tests for all of the above, especially window-end enforcement and failed
   reseal on quit.

## Bottom Line

The pre-window crypto wall is strong for a standard-account user: before the
drand round exists, knowing the password is not enough.

The weaker area is after the morning round has existed: the app must aggressively
close plaintext and reseal forward. For the stated goal, the most important work
is not stronger cryptography. It is making the post-window cleanup unavoidable,
visible, and fast.


So indeed about this issue 1 we do nothing in round three.

That is if you cannot reach the network at all you do nothing.

So we can implement this issue of logging again when the window ends.

But as i said if network not reachable do nothing.

I think issue 2 and 3 are both about the same thing, but while vault is open, we can have heartbeat every 1 minute, "what's the current drand round now?" Then it compares that round R against the vault's committed end round (endRound, from the manifest). If R > endRound, the morning window is over → re-lock.

about issue 4, dont' worry about it, 2 hours is enough. 

other issues don't feel like actula issues. Now, how's backup being implemented, does backup make sense? BTW I think this application should have opption of exporting/importing, for migrating to new machine. 

I get it, exported vault is not time-locked but it is password-locked, so it is still better than nothing. And we can also add a warning when exporting, "exported vault is not time-locked, be careful about where you store it and who you share it with". I don't think it's something that bothers me, as even if you export is, it's not unlockable before window arrives. We can add import/export vaults functionality in the three dots option. 
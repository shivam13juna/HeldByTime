// main.swift — the headless re-seal agent (bundled as Contents/Helpers/vaultreseal
// and driven by the per-user LaunchAgent; see LaunchAgentPlist for the why).
//
// REVEAL-INCAPABLE BY CONSTRUCTION. This program has no password input, no
// plaintext path, and no UI. All it does is run VaultStore.load() once and exit.
// load() is the same authoritative state machine the app uses:
//   * expired (round published, blob now password-only) ⇒ passwordless FORWARD
//     re-seal — reuses the PW01 bytes verbatim, re-locking to the next window.
//     This is the whole point: it slams the password-only escape hatch shut.
//   * open window ⇒ load() returns the (still AES-encrypted) payload, which we
//     DISCARD without a password — the agent never decrypts, never writes here.
//   * offline / future-sealed / nothing recoverable ⇒ no write. We exit 0 anyway
//     so launchd simply retries on its next interval (and on wake).
//
// So whether run by launchd, from a terminal, or by a curious future self, this
// agent can only ever RE-LOCK a vault — never open one. It is the time-lock's
// ally, not an entry point. Top-level code is the entry point (file is main.swift);
// no @main, so it does not collide with the app's @main and stays out of the UI
// type-check / leak globs.
//
// MULTI-VAULT: the agent enumerates EVERY vault under the root and re-seals each
// INDEPENDENTLY. A failure on one vault (offline, malformed, future-sealed) is
// recorded to that vault's own log and the agent moves on — one bad vault never
// blocks re-sealing the rest. With zero vaults there is simply nothing to do.

import Foundation

// Resolve where we (and our sibling vaultseal) live, plus the vaults root.
guard let env = AppEnvironment.resealAgent() else {
    exit(2)   // couldn't locate ourselves — fail closed, change nothing.
}

// Enumerate the vaults; an unreadable/empty root yields [] (nothing to re-seal).
for entry in env.registry.list() {
    let config = env.configuration(for: entry)

    // The schedule (windows) is only consulted to pick the NEXT window for a
    // forward re-seal; a missing file falls back to the default, never "always open".
    let prefs = (try? SchedulePrefs.load(from: config.schedulePrefsURL)) ?? .default

    let runner = HelperRunner(executableURL: config.helperURL,
                              expectedSHA256: config.compiledHelperSHA256)
    let client = VaultSealClient(runner: runner)
    let store = VaultStore(dir: config.vaultDir, client: client, schedule: prefs.schedule)

    // Run the load state machine for its re-seal SIDE EFFECT only; the result
    // (which may carry a still-encrypted payload for the open-window case) is
    // intentionally dropped — we have no password and never construct plaintext.
    let outcome = store.load()

    // Record a SECRET-FREE line to THIS vault's trail so DiagnosticsView (and the
    // merged log) show the agent ran and what it did (re-sealed / locked / offline
    // / …). Maps the result to a closed kind; carries no payload.
    let kind: DiagnosticEvent.LoadKind
    switch outcome.result {
    case .openWindow: kind = .openWindow
    case .lockedUntil: kind = .locked
    case .resealed:   kind = .resealed
    case .offline:    kind = .offline
    case .failClosed: kind = .failClosed
    }
    DiagnosticLog(url: config.diagnosticsLogURL).record(.agentRan(kind), source: .agent)
}

exit(0)

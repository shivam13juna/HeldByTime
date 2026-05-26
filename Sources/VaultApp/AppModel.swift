// AppModel.swift — Task 9: the UI coordinator that wires the SwiftUI views to
// the VaultCore engines (FirstRunSetup, VaultStore, VaultSession). It owns the
// top-level phase the app shows and nothing security-critical: every decision
// (locked vs open, fail-closed, forward-only re-seal) is made by the engines —
// the model only routes their results into `@Published` state.
//
// Threading note (deliberately deferred to Tasks 11–12): the engine calls here
// run synchronously on the calling thread. They perform a `vaultseal` subprocess
// round-trip and can block up to the helper timeout, so the packaging/E2E tasks
// will move `perform(...)` onto a background queue. Task 9 is the first task
// allowed to import SwiftUI and is gated by type-check only (no .app yet), so
// the wiring is kept synchronous and obviously correct rather than concurrent.
//
// No secret is logged or persisted in plaintext here; in-memory copies during an
// open session are the accepted ceiling (app.md §11). The Task 10 leakage pass
// hardens the editor's text system on top of this.

import Foundation
import Combine

/// The single top-level state the root view switches on.
enum AppPhase {
    case launching                                              // before bootstrap()
    case firstRun(FirstRunModel)                                // no vault yet → setup flow
    case loading                                                // running VaultStore.load()
    case locked(LockScreenInfo)                                 // sealed / offline / re-locked
    case unlockPrompt(window: Manifest.Window, payload: Data)   // open window → ask password
    case unlocked(VaultSession)                                 // decrypted, editing
    case failed(String)                                         // unrecoverable setup/wiring error
}

final class AppModel: ObservableObject {
    @Published var phase: AppPhase = .launching
    /// The decrypted content while unlocked; bound by the editor. Cleared on lock.
    @Published var content = VaultContent()
    /// Transient message for the unlock prompt (e.g. wrong password).
    @Published var unlockError: String?
    /// The schedule the user configured (windows). Settings edits this.
    @Published var schedulePrefs: SchedulePrefs

    private let config: AppConfiguration

    init(config: AppConfiguration = .live) {
        self.config = config
        self.schedulePrefs = (try? SchedulePrefs.load(from: config.schedulePrefsURL)) ?? .default
    }

    // MARK: - Production engine wiring

    /// Build a `VaultStore` over the bundled `vaultseal` helper and the current
    /// schedule. The helper hash is compiled-in at bundling time (Task 11); an
    /// empty hash makes `HelperRunner.preflight` fail closed, so the app simply
    /// will not seal/unseal until that step fills it — the correct default.
    private func makeStore() -> VaultStore {
        let runner = HelperRunner(executableURL: config.helperURL,
                                  expectedSHA256: config.compiledHelperSHA256)
        let client = VaultSealClient(runner: runner)
        return VaultStore(dir: config.vaultDir, client: client, schedule: schedulePrefs.schedule)
    }

    private var vaultExists: Bool {
        FileManager.default.fileExists(atPath: config.vaultDir.appendingPathComponent("vault.dat").path)
    }

    // MARK: - Lifecycle

    /// Decide the opening screen: first-run setup if no vault file exists, else
    /// run the load state-machine and route its result.
    func bootstrap() {
        guard vaultExists else {
            phase = .firstRun(FirstRunModel(config: config) { [weak self] in self?.reload() })
            return
        }
        reload()
    }

    /// Run `VaultStore.load()` and map the outcome to a phase. The load is the
    /// authoritative locked-vs-open gate; we never consult the schedule for access.
    func reload() {
        phase = .loading
        let store = makeStore()
        let outcome = store.load()
        switch outcome.result {
        case .openWindow(let window, let payload):
            unlockError = nil
            phase = .unlockPrompt(window: window, payload: payload)
        case .lockedUntil, .resealed, .offline, .failClosed:
            phase = .locked(LockScreen.describe(outcome.result, calendar: schedulePrefs.calendar))
        }
    }

    // MARK: - Unlock / edit / lock

    /// Try to decrypt the open-window payload with the entered password. A wrong
    /// password yields an auth failure with no partial plaintext (VaultSession).
    func unlock(password: String) {
        guard case let .unlockPrompt(window, payload) = phase else { return }
        let store = makeStore()
        let pw = PasswordPolicy.encode(password)
        switch VaultSession.open(store: store, window: window, payload: payload, password: pw) {
        case .failure:
            // Deliberately generic — never reveal whether it was the password vs
            // a structural problem, and never construct partial content.
            unlockError = "Could not unlock. Check your password and try again."
        case .success(let opened):
            do {
                content = try VaultContent.decode(opened.notes)
            } catch {
                // Decrypted but the plaintext isn't our content shape — corrupt.
                phase = .failed("The vault decrypted but its contents are unreadable.")
                return
            }
            unlockError = nil
            phase = .unlocked(opened.session)
        }
    }

    /// Re-seal the (possibly edited) content forward and return to the locked
    /// screen. Used by the Lock button and the window-end trigger. Fail-closed:
    /// if sealing fails (offline / stale / no window) the session stays open and
    /// the error surfaces — we never drop to an unsealed state silently.
    @discardableResult
    func lock(trigger: VaultSession.Trigger = .lockButton) -> Bool {
        guard case let .unlocked(session) = phase else { return false }
        let notes: [UInt8]
        do { notes = try content.encode() }
        catch { unlockError = "Notes too large to save."; return false }
        switch session.reseal(notes: notes, trigger: trigger) {
        case .success(let window):
            content = VaultContent()            // drop plaintext from the model
            phase = .locked(LockScreen.describe(.lockedUntil(displayStartRound: window.startRound),
                                                calendar: schedulePrefs.calendar))
            return true
        case .failure:
            unlockError = "Could not re-lock the vault (are you online?). Your notes are unchanged on disk."
            return false
        }
    }

    /// Seal-on-graceful-quit (Cmd-Q / menu). Returns true once it is safe to
    /// terminate. If unlocked we re-seal first (best effort); whether or not that
    /// succeeds we allow termination — a failed seal leaves the on-disk blob as
    /// it was, and the launch-time defensive re-seal closes the gap next start.
    func sealForQuit() -> Bool {
        if case .unlocked = phase { _ = lock(trigger: .gracefulQuit) }
        return true
    }

    // MARK: - Settings

    /// Persist edited windows and re-evaluate (a schedule change never grants
    /// access — load() still gates on the committed manifest, not the schedule).
    func applySchedule(_ prefs: SchedulePrefs) {
        schedulePrefs = prefs
        try? prefs.save(to: config.schedulePrefsURL)
    }
}

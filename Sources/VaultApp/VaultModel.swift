// VaultModel.swift — the per-VAULT UI coordinator. One instance per open vault.
// It wires the SwiftUI screens to the VaultCore engines (VaultStore, VaultSession)
// for a single vault directory, and owns nothing security-critical: every decision
// (locked vs open, fail-closed, forward-only re-seal) is made by the engines — the
// model only routes their results into `@Published` state. Split out of AppModel
// so the app can hold many of these at once (multi-vault); AppModel is now the
// coordinator that selects between them.
//
// No secret is logged or persisted in plaintext here; in-memory copies during an
// open session are the accepted ceiling (app.md §11). Diagnostics are recorded to
// THIS vault's secret-free log (DiagnosticLog / I13).

import Foundation
import Combine

/// The state a single vault's screen switches on. The whole-app phases (vault
/// list, creating, failed) live on AppModel; this is only the per-vault machine.
enum VaultPhase {
    case loading                                                // running VaultStore.load()
    case locked(LockScreenInfo)                                 // sealed / offline / re-locked
    case unlockPrompt(window: Manifest.Window, payload: Data)   // open window → ask password
    case unlocked(VaultSession)                                 // decrypted, editing
    case failed(String)                                         // unrecoverable contents/wiring error
}

final class VaultModel: ObservableObject, Identifiable {
    /// Stable id = the vault's subdirectory name (from VaultRegistry).
    let id: String
    /// The user-chosen, NON-secret display label.
    @Published var label: String
    @Published var phase: VaultPhase = .loading
    /// The decrypted content while unlocked; bound by the editor. Cleared on lock.
    @Published var content = VaultContent()
    /// Transient message for the unlock prompt (e.g. wrong password).
    @Published var unlockError: String?
    /// This vault's schedule (windows). Settings edits this.
    @Published var schedulePrefs: SchedulePrefs

    let config: AppConfiguration

    /// This vault's secret-free diagnostics trail (shared with the background
    /// agent). Exposed so DiagnosticsView can read it; logging stays in this model.
    var diagnosticsLog: DiagnosticLog { DiagnosticLog(url: config.diagnosticsLogURL) }

    init(entry: VaultEntry, env: AppEnvironment) {
        self.id = entry.id
        self.label = entry.meta.label
        self.config = env.configuration(for: entry)
        self.schedulePrefs = (try? SchedulePrefs.load(from: config.schedulePrefsURL)) ?? .default
    }

    /// DISPLAY ONLY — the advisory wall-clock instant this vault next opens
    /// (drives the list's "opens at …" hint). Never authorizes access.
    var nextWindowOpening: Date? { schedulePrefs.schedule.nextWindowOpening(after: Date()) }

    // MARK: - engine wiring

    private func makeStore() -> VaultStore {
        let runner = HelperRunner(executableURL: config.helperURL,
                                  expectedSHA256: config.compiledHelperSHA256)
        let client = VaultSealClient(runner: runner)
        return VaultStore(dir: config.vaultDir, client: client, schedule: schedulePrefs.schedule)
    }

    // MARK: - load / unlock / edit / lock

    /// Run `VaultStore.load()` and map the outcome to a phase. The load is the
    /// authoritative locked-vs-open gate; we never consult the schedule for access.
    func reload() {
        phase = .loading
        let store = makeStore()
        let outcome = store.load()
        logOutcome(outcome)
        switch outcome.result {
        case .openWindow(let window, let payload):
            unlockError = nil
            phase = .unlockPrompt(window: window, payload: payload)
        case .lockedUntil, .resealed, .offline, .failClosed:
            phase = .locked(LockScreen.describe(outcome.result, calendar: schedulePrefs.calendar))
        }
    }

    /// Record a load() outcome (and any hash-only quarantine records) to this
    /// vault's secret-free trail — round numbers and a closed outcome kind only,
    /// never any decrypted payload (I13).
    private func logOutcome(_ outcome: VaultLoadOutcome) {
        let kind: DiagnosticEvent.LoadKind
        let round: UInt64?
        switch outcome.result {
        case .openWindow(let window, _): kind = .openWindow; round = window.startRound
        case .lockedUntil(let r):        kind = .locked;     round = r
        case .resealed(let window):      kind = .resealed;   round = window.startRound
        case .offline:                   kind = .offline;    round = nil
        case .failClosed:                kind = .failClosed; round = nil
        }
        let log = diagnosticsLog
        log.record(.checkedVault(kind, round: round), source: .app)
        for q in outcome.quarantines {
            log.record(.quarantine(side: q.side == .primary ? "primary" : "backup",
                                    sha256Hex: q.sha256Hex, reason: q.reason), source: .app)
        }
    }

    /// Try to decrypt the open-window payload with the entered password. A wrong
    /// password yields an auth failure with no partial plaintext (VaultSession).
    func unlock(password: String) {
        guard case let .unlockPrompt(window, payload) = phase else { return }
        let store = makeStore()
        let pw = PasswordPolicy.encode(password)
        switch VaultSession.open(store: store, window: window, payload: payload, password: pw) {
        case .failure:
            // Deliberately generic — never reveal whether it was the password vs a
            // structural problem, and never construct partial content. The log is
            // equally coarse (no password-vs-corrupt oracle).
            diagnosticsLog.record(.unlock(success: false), source: .app)
            unlockError = "Could not unlock. Check your password and try again."
        case .success(let opened):
            do {
                content = try VaultContent.decode(opened.notes)
            } catch {
                phase = .failed("The vault decrypted but its contents are unreadable.")
                return
            }
            diagnosticsLog.record(.unlock(success: true), source: .app)
            unlockError = nil
            phase = .unlocked(opened.session)
        }
    }

    /// Re-seal the (possibly edited) content forward and return to the locked
    /// screen. Fail-closed: if sealing fails (offline / stale / no window) the
    /// session stays open and the error surfaces — never a silent unsealed state.
    @discardableResult
    func lock(trigger: VaultSession.Trigger = .lockButton) -> Bool {
        guard case let .unlocked(session) = phase else { return false }
        let notes: [UInt8]
        do { notes = try content.encode() }
        catch { unlockError = "Notes too large to save."; return false }
        switch session.reseal(notes: notes, trigger: trigger) {
        case .success(let window):
            diagnosticsLog.record(.resealedForward(round: window.startRound), source: .app)
            content = VaultContent()            // drop plaintext from the model
            phase = .locked(LockScreen.describe(.lockedUntil(displayStartRound: window.startRound),
                                                calendar: schedulePrefs.calendar))
            return true
        case .failure:
            diagnosticsLog.record(.resealFailed, source: .app)
            unlockError = "Could not re-lock the vault (are you online?). Your notes are unchanged on disk."
            return false
        }
    }

    /// Seal-on-graceful-quit / on leaving the vault. Returns true once it is safe
    /// to proceed. If unlocked we re-seal first (best effort); whether or not that
    /// succeeds we allow proceeding — a failed seal leaves the on-disk blob as it
    /// was, and the launch-time / agent defensive re-seal closes the gap.
    @discardableResult
    func sealForQuit() -> Bool {
        if case .unlocked = phase { _ = lock(trigger: .gracefulQuit) }
        return true
    }

    // MARK: - settings

    /// Persist edited windows and re-evaluate (a schedule change never grants
    /// access — load() still gates on the committed manifest, not the schedule).
    func applySchedule(_ prefs: SchedulePrefs) {
        schedulePrefs = prefs
        try? prefs.save(to: config.schedulePrefsURL)
    }
}

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

    /// True while the (Argon2) unlock or the (networked) interactive re-seal runs
    /// OFF the main thread, so the UI can show an honest spinner instead of a
    /// frozen window. Each also guards its operation against re-entrant taps.
    /// NEITHER affects the lock decision — they are display/concurrency state only.
    @Published var isUnlocking = false
    @Published var isSealing = false
    /// Re-entrancy guard for `reload()` (the `.loading` phase drives its UI).
    private var loadInFlight = false

    let config: AppConfiguration

    /// Test seam: builds the VaultStore for this vault. nil ⇒ the live store (real
    /// HelperRunner + VaultSealClient). Injected so offline tests can drive the model
    /// with a FakeSeal-backed store; the production call site passes nothing, so its
    /// behaviour is unchanged.
    private let storeFactory: ((AppConfiguration, Schedule) -> VaultStore)?

    /// This vault's secret-free diagnostics trail (shared with the background
    /// agent). Exposed so DiagnosticsView can read it; logging stays in this model.
    var diagnosticsLog: DiagnosticLog { DiagnosticLog(url: config.diagnosticsLogURL) }

    init(entry: VaultEntry, env: AppEnvironment,
         makeStore: ((AppConfiguration, Schedule) -> VaultStore)? = nil) {
        self.id = entry.id
        self.label = entry.meta.label
        self.config = env.configuration(for: entry)
        self.storeFactory = makeStore
        self.schedulePrefs = (try? SchedulePrefs.load(from: config.schedulePrefsURL)) ?? .default
    }

    /// DISPLAY ONLY — the advisory wall-clock instant this vault next opens
    /// (drives the list's "opens at …" hint). Never authorizes access.
    var nextWindowOpening: Date? { schedulePrefs.schedule.nextWindowOpening(after: Date()) }

    // MARK: - engine wiring

    private func makeStore() -> VaultStore {
        if let storeFactory { return storeFactory(config, schedulePrefs.schedule) }
        let runner = HelperRunner(executableURL: config.helperURL,
                                  expectedSHA256: config.compiledHelperSHA256)
        let client = VaultSealClient(runner: runner)
        return VaultStore(dir: config.vaultDir, client: client, schedule: schedulePrefs.schedule)
    }

    // MARK: - Pure reducers (no I/O, no async — unit-tested headless)

    /// Map a load result to the per-vault phase. PURE: the authoritative
    /// locked-vs-open decision was already made by `VaultStore.load()`; this only
    /// chooses what to show, and `.openWindow` is the ONLY result that exposes the
    /// password prompt. `now` only affects the lock screen's display "until" text.
    static func phase(for result: VaultLoadResult, calendar: Calendar, now: Date = Date()) -> VaultPhase {
        switch result {
        case .openWindow(let window, let payload):
            return .unlockPrompt(window: window, payload: payload)
        case .lockedUntil, .resealed, .offline, .failClosed:
            return .locked(LockScreen.describe(result, calendar: calendar, now: now))
        }
    }

    /// Map a load outcome to the SECRET-FREE diagnostic events to record: the load
    /// kind + verified round, then one I6 hash-only line per quarantine. PURE — it
    /// carries only round numbers, a closed kind, and the hash/reason, never a
    /// payload (I13). `logOutcome` just writes what this returns.
    static func events(for outcome: VaultLoadOutcome) -> [DiagnosticEvent] {
        let kind: DiagnosticEvent.LoadKind
        let round: UInt64?
        switch outcome.result {
        case .openWindow(let window, _): kind = .openWindow; round = window.startRound
        case .lockedUntil(let r):        kind = .locked;     round = r
        case .resealed(let window):      kind = .resealed;   round = window.startRound
        case .offline:                   kind = .offline;    round = nil
        case .failClosed:                kind = .failClosed; round = nil
        }
        var events: [DiagnosticEvent] = [.checkedVault(kind, round: round)]
        for q in outcome.quarantines {
            events.append(.quarantine(side: q.side == .primary ? "primary" : "backup",
                                       sha256Hex: q.sha256Hex, reason: q.reason))
        }
        return events
    }

    // MARK: - load / unlock / edit / lock

    /// Run `VaultStore.load()` and map the outcome to a phase. The load is the
    /// authoritative locked-vs-open gate; we never consult the schedule for access.
    ///
    /// `load()` shells out to the helper and reaches drand over the network (2–10s),
    /// so it runs on a background queue and routes the result back on main — the
    /// `.loading` phase shows a spinner meanwhile instead of freezing the window.
    /// The lock decision is unchanged; only *where* it runs moved off the main thread.
    func reload() {
        guard !loadInFlight else { return }   // ignore re-entrant taps while in flight
        loadInFlight = true
        phase = .loading
        let store = makeStore()
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = store.load()
            DispatchQueue.main.async {
                self.loadInFlight = false
                self.logOutcome(outcome)
                if case .openWindow = outcome.result { self.unlockError = nil }
                self.phase = Self.phase(for: outcome.result, calendar: self.schedulePrefs.calendar)
            }
        }
    }

    /// Record a load() outcome (and any hash-only quarantine records) to this
    /// vault's secret-free trail — round numbers and a closed outcome kind only,
    /// never any decrypted payload (I13).
    private func logOutcome(_ outcome: VaultLoadOutcome) {
        let log = diagnosticsLog
        for event in Self.events(for: outcome) { log.record(event, source: .app) }
    }

    /// Try to decrypt the open-window payload with the entered password. A wrong
    /// password yields an auth failure with no partial plaintext (VaultSession).
    ///
    /// Argon2id is deliberately expensive (it is the cost that protects an expired
    /// blob from a thief), so the open runs on a background queue with `isUnlocking`
    /// driving a spinner; the result is applied on main. Fail-closed semantics are
    /// unchanged — a wrong password still yields a generic failure and no content.
    func unlock(password: String) {
        guard case let .unlockPrompt(window, payload) = phase, !isUnlocking else { return }
        let store = makeStore()
        let pw = PasswordPolicy.encode(password)
        isUnlocking = true
        unlockError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = VaultSession.open(store: store, window: window, payload: payload, password: pw)
            DispatchQueue.main.async { self.applyOpenResult(result) }
        }
    }

    /// Apply a `VaultSession.open` result to state — the main-thread half of
    /// `unlock`, split out so the routing is unit-testable without a run loop.
    /// Fail-closed: a failure is deliberately generic (never a password-vs-corrupt
    /// oracle) and builds NO content; a success that decrypts but won't decode lands
    /// in `.failed`, never partial content. The log is equally coarse.
    func applyOpenResult(_ result: Result<(notes: [UInt8], session: VaultSession), StoreError>) {
        isUnlocking = false
        switch result {
        case .failure:
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

    /// Whether the vault is currently open (decrypted, editing).
    var isUnlocked: Bool {
        if case .unlocked = phase { return true }
        return false
    }

    /// Interactive re-seal that runs the (networked) seal OFF the main thread so the
    /// editor shows a "Sealing…" indicator instead of freezing. Same fail-closed,
    /// forward-only semantics as `lock()` — only the threading differs. `completion`
    /// runs on main with true on a successful forward re-seal, false otherwise, so
    /// the caller can decide whether to stay (Lock now) or navigate away (closeCurrent).
    /// `lock()` is retained for the synchronous Cmd-Q teardown path, which cannot await.
    func sealInteractively(trigger: VaultSession.Trigger, completion: @escaping (Bool) -> Void) {
        guard case let .unlocked(session) = phase, !isSealing else { completion(false); return }
        let notes: [UInt8]
        do { notes = try content.encode() }
        catch { unlockError = "Notes too large to save."; completion(false); return }
        isSealing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = session.reseal(notes: notes, trigger: trigger)
            DispatchQueue.main.async {
                self.isSealing = false
                switch result {
                case .success(let window):
                    self.diagnosticsLog.record(.resealedForward(round: window.startRound), source: .app)
                    self.content = VaultContent()           // drop plaintext from the model
                    self.phase = .locked(LockScreen.describe(.lockedUntil(displayStartRound: window.startRound),
                                                             calendar: self.schedulePrefs.calendar))
                    completion(true)
                case .failure:
                    self.diagnosticsLog.record(.resealFailed, source: .app)
                    self.unlockError = "Could not re-lock the vault (are you online?). Your notes are unchanged on disk."
                    completion(false)
                }
            }
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

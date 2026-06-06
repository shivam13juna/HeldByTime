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
    /// The per-vault screen state. Its `didSet` is the single place the
    /// while-unlocked window-end monitor is armed/disarmed (see that section): the
    /// monitor runs only in `.unlocked` and stops on every transition out of it.
    @Published var phase: VaultPhase = .loading { didSet { syncWindowEndMonitor() } }
    /// The decrypted content while unlocked; bound by the editor. Cleared on lock.
    @Published var content = VaultContent()
    /// The decrypted content AS LOADED at unlock — the baseline the editor diffs
    /// against to know whether there are unsaved edits (`isDirty`). Held only while
    /// unlocked and dropped alongside `content` on every lock, so no extra plaintext
    /// copy outlives the open session (app.md §11).
    private var loadedBaseline: VaultContent?
    /// Transient message for the unlock prompt (e.g. wrong password).
    @Published var unlockError: String?
    /// Transient message shown IN THE EDITOR when a re-seal (Lock now / Save & Lock /
    /// Save & Quit) cannot complete — e.g. offline, so the forward seal's round fetch
    /// fails, or notes over the size cap. Kept SEPARATE from `unlockError` (the unlock
    /// PROMPT's auth message) because a failed seal leaves the vault open and editable:
    /// the editor surfaces this so the lock action is never a silent no-op (the notes
    /// are unchanged on disk). Cleared when a seal is retried or succeeds, and on a
    /// fresh unlock.
    @Published var sealError: String?
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

    /// The while-unlocked window-end heartbeat (armed only in `.unlocked`) and its
    /// in-flight guard so a slow poll cannot stack. Foundation `Timer`/`DispatchQueue`
    /// only — this file is compiled into the offline test binary and must stay
    /// AppKit-free (run_tests `scope/app-headless`), so wake/activation re-checks are
    /// pushed in from the AppKit layer via `recheckWindowEnd()`.
    private var windowEndTimer: Timer?
    private var windowEndPollInFlight = false
    /// How often the open session re-checks the verified round against its committed
    /// window end. A minute is responsive enough to close an out-of-window session
    /// while costing one cheap `current-round` call per minute.
    static let windowEndPollInterval: TimeInterval = 60

    let config: AppConfiguration

    /// Test seam: builds the VaultStore for this vault. nil ⇒ the live store (real
    /// HelperRunner + VaultSealClient). Injected so offline tests can drive the model
    /// with a FakeSeal-backed store; the production call site passes nothing, so its
    /// behaviour is unchanged.
    private let storeFactory: ((AppConfiguration, Schedule) -> VaultStore)?

    /// Called after a schedule edit is persisted. The app wires this to refresh the
    /// background re-seal agent's window-end triggers immediately (so an edit takes
    /// effect now, not at the next launch). Defaults to a no-op for headless tests
    /// and any caller that does not manage the agent.
    private let onScheduleChanged: () -> Void

    /// This vault's secret-free diagnostics trail (shared with the background
    /// agent). Exposed so DiagnosticsView can read it; logging stays in this model.
    var diagnosticsLog: DiagnosticLog { DiagnosticLog(url: config.diagnosticsLogURL) }

    init(entry: VaultEntry, env: AppEnvironment,
         makeStore: ((AppConfiguration, Schedule) -> VaultStore)? = nil,
         onScheduleChanged: @escaping () -> Void = {}) {
        self.id = entry.id
        self.label = entry.meta.label
        self.config = env.configuration(for: entry)
        self.storeFactory = makeStore
        self.onScheduleChanged = onScheduleChanged
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
            loadedBaseline = content        // the diff target for unsaved-edits detection
            diagnosticsLog.record(.unlock(success: true), source: .app)
            unlockError = nil
            sealError = nil                 // a freshly opened editor shows no stale seal error
            phase = .unlocked(opened.session)
        }
    }

    /// Record (secret-free) that the user copied a secret VALUE to the clipboard —
    /// the one action where vault plaintext deliberately crosses the app boundary.
    /// Logs only THAT it happened (I13 / DiagnosticLog is secret-free): never the
    /// secret's label or value.
    func recordSecretCopied() {
        diagnosticsLog.record(.copiedSecret, source: .app)
    }

    /// Re-seal the (possibly edited) content forward and return to the locked
    /// screen. Fail-closed: if sealing fails (offline / stale / no window) the
    /// session stays open and the error surfaces — never a silent unsealed state.
    @discardableResult
    func lock(trigger: VaultSession.Trigger = .lockButton) -> Bool {
        guard case let .unlocked(session) = phase else { return false }
        sealError = nil
        let notes: [UInt8]
        do { notes = try content.encode() }
        catch { sealError = "Notes too large to save."; return false }
        switch session.reseal(notes: notes, trigger: trigger) {
        case .success(let window):
            diagnosticsLog.record(.resealedForward(round: window.startRound), source: .app)
            content = VaultContent()            // drop plaintext from the model
            loadedBaseline = nil                // …and its baseline copy
            phase = .locked(LockScreen.describe(.lockedUntil(displayStartRound: window.startRound),
                                                calendar: schedulePrefs.calendar))
            return true
        case .failure:
            diagnosticsLog.record(.resealFailed, source: .app)
            sealError = "Could not re-lock the vault (are you online?). Your notes are unchanged on disk."
            return false
        }
    }

    /// Whether the vault is currently open (decrypted, editing).
    var isUnlocked: Bool {
        if case .unlocked = phase { return true }
        return false
    }

    /// Whether the open editor holds changes not yet written to disk. Drives the
    /// "unsaved changes" prompt on leaving and the graceful-quit warning. False unless
    /// we are unlocked AND the live content differs from the baseline captured at
    /// unlock — so a read-only open session (or any locked state) is never "dirty".
    /// Model 1: leaving a clean vault just SETS IT DOWN (no seal) and it reopens in its
    /// current window with the password; only unsaved edits force a discard-vs-save
    /// choice, because saving means sealing forward (locked until the next window).
    var isDirty: Bool {
        guard case .unlocked = phase, let baseline = loadedBaseline else { return false }
        return content != baseline
    }

    /// Interactive re-seal that runs the (networked) seal OFF the main thread so the
    /// editor shows a "Sealing…" indicator instead of freezing. Same fail-closed,
    /// forward-only semantics as `lock()` — only the threading differs. `completion`
    /// runs on main with true on a successful forward re-seal, false otherwise, so
    /// the caller can decide whether to stay (Lock now) or navigate away (closeCurrent).
    /// `lock()` is retained for the synchronous Cmd-Q teardown path, which cannot await.
    func sealInteractively(trigger: VaultSession.Trigger, completion: @escaping (Bool) -> Void) {
        guard case let .unlocked(session) = phase, !isSealing else { completion(false); return }
        sealError = nil
        let notes: [UInt8]
        do { notes = try content.encode() }
        catch { sealError = "Notes too large to save."; completion(false); return }
        isSealing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = session.reseal(notes: notes, trigger: trigger)
            DispatchQueue.main.async {
                self.isSealing = false
                switch result {
                case .success(let window):
                    self.diagnosticsLog.record(.resealedForward(round: window.startRound), source: .app)
                    self.content = VaultContent()           // drop plaintext from the model
                    self.loadedBaseline = nil               // …and its baseline copy
                    self.phase = .locked(LockScreen.describe(.lockedUntil(displayStartRound: window.startRound),
                                                             calendar: self.schedulePrefs.calendar))
                    completion(true)
                case .failure:
                    self.diagnosticsLog.record(.resealFailed, source: .app)
                    self.sealError = "Could not re-lock the vault (are you online?). Your notes are unchanged on disk."
                    completion(false)
                }
            }
        }
    }

    /// Save-and-quit: re-seal the open session FORWARD so the edits are persisted, and
    /// report whether that actually succeeded. Returns true when there is nothing to
    /// save (no open session) OR the forward seal succeeded; returns false when an open
    /// session could NOT be sealed (e.g. offline) — in which case the plaintext is still
    /// in the model, `sealError` is set, and the caller MUST NOT quit (quitting would
    /// silently lose the very edits the user asked to save). The synchronous `lock()` is
    /// used here because the AppKit terminate reply cannot await.
    @discardableResult
    func sealForQuit() -> Bool {
        if case .unlocked = phase { return lock(trigger: .gracefulQuit) }
        return true
    }

    /// Set the vault DOWN without sealing — the Model 1 leave path. Synchronously drops
    /// the in-RAM plaintext and stops the window-end monitor, leaving the on-disk blob
    /// UNTOUCHED (still openable in its current window; it reopens with the password).
    /// The model is released right after we navigate away, but we don't wait on ARC: we
    /// zero the plaintext here and now and invalidate the timer, so no orphaned heartbeat
    /// can fire on a model that's no longer on screen. Idempotent and safe from any phase
    /// — a non-unlocked vault holds no plaintext and has no timer, so this is a no-op
    /// there. Never seals (that would be a forward re-lock; leaving must not lock you out).
    func setDown() {
        windowEndTimer?.invalidate()
        windowEndTimer = nil
        content = VaultContent()
        loadedBaseline = nil
    }

    // MARK: - Window-end monitor (forced re-lock while unlocked)

    deinit { windowEndTimer?.invalidate() }

    /// Arm the heartbeat exactly while unlocked; stop it on any other phase. Driven
    /// from `phase.didSet`, so it tracks every transition (unlock, lock, reload,
    /// window-end re-lock) without each call site having to remember.
    private func syncWindowEndMonitor() {
        if case .unlocked = phase {
            windowEndTimer?.invalidate()
            // `.common` mode so the timer keeps firing during menu tracking / scrolling.
            let timer = Timer(timeInterval: Self.windowEndPollInterval, repeats: true) { [weak self] _ in
                self?.pollWindowEnd()
            }
            RunLoop.main.add(timer, forMode: .common)
            windowEndTimer = timer
        } else {
            windowEndTimer?.invalidate()
            windowEndTimer = nil
        }
    }

    /// One heartbeat: fetch the verified round OFF the main thread, then route the
    /// result back on main. Also the entry point the AppKit layer calls on
    /// app-activation / wake-from-sleep (a laptop asleep past the window would never
    /// have ticked). Offline / failure is a no-op that retries next tick — we fire on
    /// a confirmed round past the end, never on the mere absence of one.
    func recheckWindowEnd() { pollWindowEnd() }

    private func pollWindowEnd() {
        guard case let .unlocked(session) = phase, !windowEndPollInFlight else { return }
        windowEndPollInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let result = session.store.client.currentRound()
            DispatchQueue.main.async { self.applyWindowEndPoll(result, session: session) }
        }
    }

    /// Main-thread half of a heartbeat, split out so it is unit-testable without a
    /// run loop or the network. A verified round strictly past the COMMITTED end ⇒
    /// re-lock now. Anything else — still in window, offline, or a malformed reply —
    /// is a no-op that keeps the session open. The `openWindow` match guards the rare
    /// race where the user re-locked and re-opened a new window under us between the
    /// poll dispatch and its return.
    func applyWindowEndPoll(_ result: Result<CurrentRoundInfo, HelperError>, session: VaultSession) {
        windowEndPollInFlight = false
        guard case let .unlocked(current) = phase, current.openWindow == session.openWindow else { return }
        guard case let .success(info) = result, session.hasWindowEnded(verifiedRound: info.round) else { return }
        relockForWindowEnd(session: session)
    }

    /// Re-lock a session whose committed window has verifiably ended. We have POSITIVE
    /// confirmation (a round past `endRound`), so the plaintext goes regardless of
    /// whether the forward re-seal can be written this instant:
    ///   • success ⇒ re-sealed forward, locked at the next window;
    ///   • failure ⇒ clear the plaintext anyway and drop to a locked screen — the
    ///     on-disk blob is closed by the agent / next-launch defensive re-seal.
    /// Honouring the window beats saving an edit made in the rare offline instant at
    /// the boundary; the poll that detected the end had just succeeded online, so this
    /// failure path is a corner of a corner.
    @discardableResult
    func relockForWindowEnd(session: VaultSession) -> Bool {
        guard case .unlocked = phase else { return false }
        let resealed: Result<Manifest.Window, StoreError>
        if let notes = try? content.encode() {
            resealed = session.reseal(notes: notes, trigger: .windowEndReached)
        } else {
            // Over-cap notes can't be re-sealed — still hide the now-out-of-window
            // plaintext and drop to a locked screen (fail-closed, never left open).
            resealed = .failure(.format(.sizeLimit("notes over cap at window end")))
        }
        switch resealed {
        case .success(let window):
            diagnosticsLog.record(.resealedForward(round: window.startRound), source: .app)
            content = VaultContent()
            loadedBaseline = nil
            phase = .locked(LockScreen.describe(.lockedUntil(displayStartRound: window.startRound),
                                                calendar: schedulePrefs.calendar))
            return true
        case .failure:
            diagnosticsLog.record(.resealFailed, source: .app)
            content = VaultContent()    // confirmed out-of-window ⇒ hide plaintext regardless
            loadedBaseline = nil
            phase = .locked(LockScreen.describe(.offline, calendar: schedulePrefs.calendar))
            return false
        }
    }

    // MARK: - settings

    /// Persist edited windows and re-evaluate (a schedule change never grants
    /// access — load() still gates on the committed manifest, not the schedule).
    func applySchedule(_ prefs: SchedulePrefs) {
        schedulePrefs = prefs
        try? prefs.save(to: config.schedulePrefsURL)
        // Refresh the agent's window-end triggers now (it never grants access — the
        // committed manifest still gates load(); this only changes when the agent
        // next wakes to re-seal).
        onScheduleChanged()
    }
}

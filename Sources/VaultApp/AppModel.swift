// AppModel.swift — the APP-LEVEL coordinator. It owns the top-level screen the
// app shows (the vault list, a create flow, an open vault, or a terminal error),
// the set of vaults on disk, and the app-global appearance preference. Per-vault
// behaviour (load / unlock / lock / re-seal) lives in VaultModel; AppModel only
// selects between vaults and routes between whole-app screens.
//
// It installs/refreshes the background re-seal LaunchAgent on launch and purges
// the obsolete single-vault layout. App-scope diagnostics (launch, agent install)
// go to the app-level log (env.appLogURL); each vault's own activity goes to its
// own diagnostics.log via its VaultModel. No secret is handled here.

import Foundation
import Combine

/// The single top-level screen the root view switches on.
enum AppScreen {
    case launching                  // before bootstrap()
    case list                       // the vault list (home); also the empty state
    case creating(FirstRunModel)    // first-run setup for a NEW vault
    case open(VaultModel)           // a selected vault → its own VaultPhase machine
    case failed(String)             // app-level wiring error
}

/// One vault's unsaved edits, re-locked into an in-RAM ciphertext stash because the user
/// LEFT it mid-window. Held off-screen until the user re-enters (decrypt the stash with
/// the password) or the window ends (seal it forward, passwordless). RAM-only on purpose —
/// a password-openable blob written to disk mid-window would be exactly the escape hatch
/// §9 / I13 forbid — so it is lost if the app exits before it is sealed (the accepted
/// trade for not locking the vault forward the instant you step away).
struct WarmStash {
    let id: String                   // the vault's stable id (the warmEdits key)
    let label: String                // non-secret display label, for the window-end log line
    let payload: Data                // manifest(openWindow) || PW01 — re-entry + defensiveReseal both consume it
    let openWindow: Manifest.Window  // the window the edits belong to (a round past its end ⇒ seal forward)
    let store: VaultStore            // captured from the live session (carries the helper client + schedule + clock)
    let logURL: URL                  // this vault's secret-free diagnostics log (the vm is gone by window-end)
}

final class AppModel: ObservableObject {
    @Published var screen: AppScreen = .launching
    /// The vaults currently on disk (sealed). Drives the list; refreshed on change.
    @Published var entries: [VaultEntry] = []
    /// DISPLAY-ONLY advisory: each vault's next scheduled window opening (wall
    /// clock, from its schedule.json), keyed by vault id. Recomputed on every
    /// `refreshEntries()`. NEVER authorizes access — the list does not probe the
    /// real lock state (no network); opening the vault runs the authoritative gate.
    @Published var advisoryOpenings: [String: Date] = [:]
    /// DISPLAY-ONLY advisory: the vault ids whose schedule places NOW inside a window,
    /// so the list can show "Open now" instead of a future opening. Same caveat as
    /// `advisoryOpenings` — schedule-derived, NEVER the authoritative lock state (a
    /// schedule edited after sealing can disagree); opening the vault runs the real gate.
    @Published var advisoryOpenNow: Set<String> = []
    /// App-global cosmetic appearance (light/dark), shared by every vault.
    @Published var uiPrefs: UIPrefs
    /// A newer release the notify-only check found (nil = none / dismissed). Drives
    /// the home-screen banner. NEVER authorizes anything — purely informational.
    @Published var availableUpdate: AvailableUpdate?
    /// Vaults LEFT mid-window with unsaved edits, keyed by id — their edits re-locked into
    /// an in-RAM stash (see `WarmStash`) instead of forcing a discard/seal choice on
    /// "back". Drives the list's "kept in memory" badge. A warm vault re-opens to its
    /// newer in-RAM edits (with the password) and seals forward at its window-end.
    @Published var warmEdits: [String: WarmStash] = [:]

    /// 60s heartbeat that seals EXPIRED warm stashes forward (passwordless), armed only
    /// while `warmEdits` is non-empty. Foundation Timer only — no AppKit — so a missed
    /// tick (e.g. the Mac asleep) just seals on the next tick or at next launch (the
    /// background agent also re-seals expired vaults).
    private var warmMonitorTimer: Timer?
    private var warmPollInFlight = false
    static let warmPollInterval: TimeInterval = 60

    let env: AppEnvironment
    /// Performs the one outbound update request (injected so tests use a stub).
    private let updateChecker: UpdateChecking

    /// App-scope diagnostics (not tied to a vault): launch + agent registration.
    var appLog: DiagnosticLog { DiagnosticLog(url: env.appLogURL) }
    private var registry: VaultRegistry { env.registry }

    init(env: AppEnvironment = .live, updateChecker: UpdateChecking = LiveUpdateChecker()) {
        ProcessHardening.disableCoreDumps()   // no core file can hold decrypted secrets
        self.env = env
        self.updateChecker = updateChecker
        self.uiPrefs = (try? UIPrefs.load(from: env.uiPrefsURL)) ?? .default
    }

    // MARK: - Lifecycle

    /// Launch: drop the obsolete single-vault layout, (re)install the periodic
    /// re-seal LaunchAgent (best-effort, off the main thread — it shells out to
    /// launchctl), then show the vault list.
    func bootstrap() {
        registry.purgeLegacyTopLevelVault()
        appLog.record(.appLaunched, source: .app)

        // (Re)install the periodic re-seal agent, now ALSO firing right after each
        // window closes — calendar triggers built from every vault's current
        // schedule, so an expired vault re-seals within a minute instead of waiting
        // up to one StartInterval. Best-effort, off the main thread (it reads each
        // schedule.json and shells out to launchctl); captures the value-type env,
        // never self.
        let log = appLog
        let env = self.env
        DispatchQueue.global(qos: .utility).async {
            let ok = ResealAgentInstaller.installOrRefresh(
                calendarTimes: Self.resealFireTimes(env: env))
            log.record(.agentRegistered(success: ok), source: .app)
        }

        refreshEntries()
        screen = .list
    }

    /// The re-seal agent's calendar fire-times: every vault's window-end (advanced a
    /// minute by `LaunchAgentPlist.fireTimes`), unioned across all vaults, so launchd
    /// wakes the agent right after each window closes. Reads each vault's
    /// schedule.json, falling back to the DEFAULT schedule exactly as the agent does
    /// (ResealAgent/main.swift), so the triggers match what the agent will actually
    /// re-seal. Static + env-only (no self) so it runs cleanly on the install
    /// background queue and is unit-testable offline. Recomputed every launch ⇒ the
    /// on-disk triggers always reflect the schedules as of the last app launch.
    static func resealFireTimes(env: AppEnvironment) -> [DailyFireTime] {
        var windows: [DailyWindow] = []
        for entry in env.registry.list() {
            let url = env.configuration(for: entry).schedulePrefsURL
            let prefs = (try? SchedulePrefs.load(from: url)) ?? .default
            windows.append(contentsOf: prefs.schedule.windows)
        }
        return LaunchAgentPlist.fireTimes(forWindowEnds: windows)
    }

    /// Reload ONLY the agent's window-end triggers from the CURRENT on-disk
    /// schedules — after a schedule edit, or a vault create / delete / import — so
    /// they reflect reality immediately instead of waiting for the next launch.
    /// Silent: a pure trigger reload (`kickstart: false`) makes no immediate agent
    /// run and no extra log line, matching "a schedule change only affects the next
    /// re-seal". Off the main thread (reads schedule.json + shells out to launchctl);
    /// `env` is a value type, so this captures no self.
    func refreshResealSchedule() {
        let env = self.env
        DispatchQueue.global(qos: .utility).async {
            _ = ResealAgentInstaller.installOrRefresh(
                calendarTimes: Self.resealFireTimes(env: env), kickstart: false)
        }
    }

    /// Re-read the vault directories from disk and recompute, for each, the advisory
    /// next opening AND the advisory "open now" flag. DISPLAY ONLY — never the
    /// authoritative state (opening runs the real gate). "Open now" is read from each
    /// vault's OWN committed window (the plaintext VLT1 header of its on-disk copies),
    /// not the recurring schedule, so a vault sealed forward — "Lock now", the re-seal
    /// agent, or a prior session — correctly reads closed even while the schedule still
    /// places now inside a window. The schedule only forecasts the next opening when the
    /// vault itself can't (expired / unreadable). The VLT1 rounds stay untrusted (I2/I3).
    func refreshEntries() {
        entries = registry.list()
        let now = Date()
        let current = TrustedTime.expectedRound(at: now)
        var openings: [String: Date] = [:]
        var openNow: Set<String> = []
        for entry in entries {
            let config = env.configuration(for: entry)
            let prefs = (try? SchedulePrefs.load(from: config.schedulePrefsURL)) ?? .default
            let advisory = VaultAdvisor.advise(copies: Self.peekVaultWindows(config),
                                               current: current, schedule: prefs.schedule, now: now)
            if advisory.isOpenNow { openNow.insert(entry.id) }
            if let next = advisory.nextOpening { openings[entry.id] = next }
        }
        advisoryOpenings = openings
        advisoryOpenNow = openNow
    }

    /// Peek the plaintext VLT1 display-round pair from each readable on-disk copy of a
    /// vault (primary + `.bak`) — a 30-byte header read per copy, never the sealed
    /// payload. Feeds the DISPLAY-ONLY advisory above; the rounds are untrusted (I2/I3)
    /// and never authorize access. Unreadable / non-VLT1 copies are simply omitted.
    private static func peekVaultWindows(_ config: AppConfiguration) -> [(start: UInt64, end: UInt64)] {
        [config.vaultPrimaryURL, config.vaultBackupURL].compactMap {
            Self.readHeaderPrefix($0, count: VLT1.headerLen).flatMap(VLT1.peekDisplayRounds)
        }
    }

    /// Read at most the first `count` bytes of a file (a VLT1 header), or nil if it
    /// can't be read or is shorter. Best-effort: a vault.dat mid atomic-replace reads
    /// as either the whole old or the whole new file (rename is atomic) — both valid.
    private static func readHeaderPrefix(_ url: URL, count: Int) -> [UInt8]? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: count), data.count >= count else { return nil }
        return [UInt8](data)
    }

    // MARK: - Navigation

    /// Open an existing vault: build its model and run the load state-machine. If the
    /// vault was left this window with unsaved edits (a warm stash), re-entry PREFERS the
    /// newer in-RAM edits over disk — and the warm copy is dropped once it becomes a live
    /// on-screen session (which re-stashes on its own leave).
    func open(_ entry: VaultEntry) {
        // The vault signals schedule edits back up so we can refresh the agent's
        // window-end triggers immediately (a schedule change must not wait for the
        // next launch to take effect).
        let vm = VaultModel(entry: entry, env: env,
                            onScheduleChanged: { [weak self] in self?.refreshResealSchedule() })
        screen = .open(vm)
        if let warm = warmEdits[entry.id] {
            vm.onUnlockedFromStash = { [weak self] in
                self?.warmEdits.removeValue(forKey: entry.id)
                self?.syncWarmMonitor()
            }
            vm.reload(preferringStash: warm.payload)
        } else {
            vm.reload()
        }
    }

    /// Leave the current vault and return to the list. If it holds unsaved edits, those
    /// are SET ASIDE — re-locked into an in-RAM ciphertext stash (see `WarmStash`) so the
    /// user can re-open this window with the password and the edits seal forward only at
    /// window-end — instead of forcing a discard-or-seal choice. A clean (or non-unlocked)
    /// vault is just SET DOWN: drop its in-RAM session WITHOUT sealing, so the on-disk blob
    /// stays openable this window and reopens with the password. Forward sealing stays
    /// reserved for Lock now / window-end / quit-to-save.
    func closeCurrent() {
        guard case .open(let vm) = screen else { screen = .list; return }
        // Unsaved edits → re-lock them into an in-RAM stash (async ~1s key derivation; the
        // editor shows "Setting aside…"). On failure (over-cap notes) the editor STAYS
        // with sealError shown, so the edits are never silently lost.
        guard vm.isDirty, case .unlocked(let session) = vm.phase else {
            setDownAndShowList(vm)
            return
        }
        let id = vm.id, label = vm.label
        let store = session.store, window = session.openWindow
        let logURL = vm.config.diagnosticsLogURL
        vm.prepareSetAside { [weak self] payload in
            guard let self, let payload else { return }
            self.warmEdits[id] = WarmStash(id: id, label: label, payload: payload,
                                           openWindow: window, store: store, logURL: logURL)
            self.syncWarmMonitor()
            self.setDownAndShowList(vm)
        }
    }

    /// Navigate to the list and tear `vm` down (zero its plaintext, stop its window-end
    /// timer). Shared by the clean-leave and post-set-aside paths; the stash, if any, is
    /// already captured into `warmEdits` before this runs.
    private func setDownAndShowList(_ vm: VaultModel) {
        refreshEntries()
        screen = .list
        vm.setDown()
    }

    // MARK: - Warm edits (set aside in RAM)

    /// Arm the warm-stash heartbeat exactly while there are warm stashes; stop it when
    /// none remain. Called after every change to `warmEdits`.
    private func syncWarmMonitor() {
        if warmEdits.isEmpty {
            warmMonitorTimer?.invalidate(); warmMonitorTimer = nil
        } else if warmMonitorTimer == nil {
            // `.common` mode so it keeps firing during menu tracking / scrolling.
            let timer = Timer(timeInterval: Self.warmPollInterval, repeats: true) { [weak self] _ in
                self?.pollWarmStashes()
            }
            RunLoop.main.add(timer, forMode: .common)
            warmMonitorTimer = timer
        }
    }

    /// One heartbeat: for every OFF-SCREEN warm stash, fetch the verified round and, when
    /// it is strictly past the stash's committed window end, seal the stash FORWARD
    /// without the password — reusing `VaultStore.defensiveReseal`, so the PW01 bytes ride
    /// verbatim and only the committed window moves forward (I8 anti-shortening intact).
    /// The on-screen vault is skipped (its own session owns its window-end). Offline or
    /// still-in-window stashes are left for a later tick — the stash is ciphertext, safe to
    /// hold. All network + writes happen off the main thread. Internal (not private) so
    /// the headless suite can drive one heartbeat with a controlled fake round.
    func pollWarmStashes() {
        guard !warmPollInFlight, !warmEdits.isEmpty else { return }
        warmPollInFlight = true
        let onScreen = currentOpenVaultId
        let candidates = warmEdits.filter { $0.key != onScreen }
        DispatchQueue.global(qos: .utility).async {
            var sealed: [(id: String, round: UInt64, logURL: URL)] = []
            for (id, stash) in candidates {
                guard case .success(let info) = stash.store.client.currentRound(),
                      !TrustedTime.isStale(verifiedLatest: info.round, now: stash.store.clock()),
                      info.round > stash.openWindow.endRound else { continue }
                if case .success(let w) = stash.store.defensiveReseal(unsealedPayload: stash.payload,
                                                                      verifiedLatest: info.round) {
                    sealed.append((id, w.startRound, stash.logURL))
                }
            }
            DispatchQueue.main.async {
                self.warmPollInFlight = false
                for s in sealed {
                    self.warmEdits.removeValue(forKey: s.id)
                    DiagnosticLog(url: s.logURL).record(.resealedForward(round: s.round), source: .app)
                }
                if !sealed.isEmpty { self.refreshEntries() }
                self.syncWarmMonitor()
            }
        }
    }

    /// The id of the vault currently on screen, if any — skipped by the warm monitor so it
    /// never races the on-screen session over the same vault.
    private var currentOpenVaultId: String? {
        if case .open(let vm) = screen { return vm.id }
        return nil
    }

    // MARK: - Create

    /// Begin creating a new vault: allocate its directory (+ default label) and
    /// drive FirstRunSetup into it. The dir is NOT listed until a vault.dat is
    /// sealed; cancelling removes the empty allocation.
    func beginCreate() {
        switch registry.create(label: defaultLabel()) {
        case .failure:
            screen = .failed("Could not create a new vault directory.")
        case .success(let entry):
            let config = env.configuration(for: entry)
            let frm = FirstRunModel(
                config: config,
                defaultLabel: entry.meta.label,
                onComplete: { [weak self] label in self?.finishCreate(entry, label: label) },
                onCancel:   { [weak self] in self?.cancelCreate(entry) })
            screen = .creating(frm)
        }
    }

    private func finishCreate(_ entry: VaultEntry, label: String) {
        // Apply the name chosen during setup (NON-secret metadata; a blank name
        // keeps the default). Reuses the same rename path as the list view and is
        // independent of the seal. refreshEntries then re-reads the new label.
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != entry.meta.label {
            _ = registry.rename(id: entry.id, to: trimmed)
        }
        refreshEntries()
        refreshResealSchedule()        // the new vault's window-end joins the triggers
        if let fresh = entries.first(where: { $0.id == entry.id }) {
            open(fresh)            // jump straight into the new vault
        } else {
            screen = .list
        }
    }

    private func cancelCreate(_ entry: VaultEntry) {
        _ = registry.delete(id: entry.id)   // unlink the empty allocated dir
        refreshEntries()
        screen = .list
    }

    /// "Vault N" where N is one past the current count — a sensible default the
    /// user can rename later.
    private func defaultLabel() -> String { "Vault \(registry.list().count + 1)" }

    // MARK: - Delete

    /// Permanently delete a vault (unlink its directory; never Trash). If it is the
    /// one currently open, fall back to the list.
    func deleteVault(_ entry: VaultEntry) {
        _ = registry.delete(id: entry.id)
        if case .open(let vm) = screen, vm.id == entry.id { screen = .list }
        warmEdits.removeValue(forKey: entry.id)   // a deleted vault has no stash to seal
        syncWarmMonitor()
        refreshEntries()
        refreshResealSchedule()        // drop the removed vault's window-end trigger
    }

    // MARK: - Rename

    /// Relabel a vault (NON-secret metadata only — the label is never part of the
    /// lock). A blank name is ignored. Refreshes the list to show the new label.
    func renameVault(_ entry: VaultEntry, to newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.meta.label else { return }
        _ = registry.rename(id: entry.id, to: trimmed)
        refreshEntries()
    }

    // MARK: - Merged activity log

    /// Tag for the app-scope (non-vault) log in the merged view.
    private static let appLogTag = "App"

    /// Every log line — the app-scope log plus each vault's diagnostics.log —
    /// merged into one chronological list, each line prefixed with its source
    /// (the app, or the vault's label). All of it is secret-free by construction
    /// (DiagnosticLog / I13). The merge/sort/tag is the engine's `DiagnosticLog.merge`
    /// (pure + unit-tested); here we only gather each log's tail and its tag.
    func mergedLogLines() -> [String] {
        var groups: [(tag: String, lines: [String])] = [(Self.appLogTag, appLog.tail())]
        for entry in entries {
            let log = DiagnosticLog(url: env.configuration(for: entry).diagnosticsLogURL)
            groups.append((entry.meta.label, log.tail()))
        }
        return DiagnosticLog.merge(groups, displayIn: .current)
    }

    /// Clear the app-scope log and every vault's diagnostics.log. All non-secret;
    /// safe to wipe at any time (diagnostics, not an audit trail).
    func clearAllLogs() {
        appLog.clear()
        for entry in entries {
            DiagnosticLog(url: env.configuration(for: entry).diagnosticsLogURL).clear()
        }
    }

    // MARK: - Appearance

    /// Persist the cosmetic appearance choice (app-global). Never affects any lock.
    func applyAppearance(_ appearance: Appearance) {
        uiPrefs.appearance = appearance
        try? uiPrefs.save(to: env.uiPrefsURL)
    }

    // MARK: - Update check (notify-only)

    /// Minimum spacing between AUTOMATIC checks, so relaunching the app doesn't hit
    /// GitHub every launch. A manual "Check now" (`force: true`) bypasses it.
    private static let updateCheckInterval: TimeInterval = 6 * 3600

    /// Notify-only update check. Respects the user's `autoCheckUpdates` preference
    /// (unless `force`, the manual "Check now"), throttles automatic checks, and on
    /// a newer release publishes `availableUpdate` so the list shows a banner —
    /// UNLESS the user already chose to skip exactly that version. It NEVER downloads
    /// or installs; it only learns a version + URL. Fails silent. Records a
    /// secret-free app-scope line so the activity log shows it ran. Triggered from
    /// the list view's `onAppear` (NOT bootstrap), so the headless tests — which
    /// never render a view — make no network call.
    func checkForUpdates(force: Bool = false) {
        if !force {
            guard uiPrefs.autoCheckUpdates else { return }
            if let last = uiPrefs.lastUpdateCheck,
               Date().timeIntervalSince(last) < Self.updateCheckInterval { return }
        }
        // Stamp the attempt time immediately so rapid relaunches don't re-fire.
        uiPrefs.lastUpdateCheck = Date()
        try? uiPrefs.save(to: env.uiPrefsURL)

        let log = appLog
        let skipped = uiPrefs.skippedUpdateVersion
        updateChecker.check(currentVersion: AppVersion.current) { [weak self] update in
            DispatchQueue.main.async {
                log.record(.checkedForUpdates(available: update?.version), source: .app)
                guard let self else { return }
                // Honor a prior "skip this version"; a newer one still surfaces.
                if let update, update.version != skipped { self.availableUpdate = update }
            }
        }
    }

    /// Hide the banner for a SPECIFIC version permanently (until a strictly newer one
    /// appears). Persists the skipped version; non-secret.
    func skipUpdate(_ update: AvailableUpdate) {
        uiPrefs.skippedUpdateVersion = update.version
        try? uiPrefs.save(to: env.uiPrefsURL)
        if availableUpdate?.version == update.version { availableUpdate = nil }
    }

    /// Dismiss the banner for THIS session only (it may reappear next launch). No
    /// persistence — distinct from `skipUpdate`.
    func dismissUpdateBanner() { availableUpdate = nil }

    /// Turn the automatic check on/off (persisted). Turning it ON runs an immediate
    /// forced check so the user sees a result right away.
    func setAutoCheckUpdates(_ enabled: Bool) {
        uiPrefs.autoCheckUpdates = enabled
        try? uiPrefs.save(to: env.uiPrefsURL)
        if enabled { checkForUpdates(force: true) }
    }

    // MARK: - Uninstall

    /// Prepare to remove the app: take down its background footprint and, if
    /// `deleteVaults`, wipe its data — so the user can then trash the .app (the
    /// VIEW performs the final auto-trash + quit once this completes).
    ///
    /// Order: (1) bootout + delete the re-seal LaunchAgent; (2) when `deleteVaults`,
    /// unlink EVERY vault and the app-scope residue (app log + appearance) — the
    /// whole vault data tree, each unlinked and NEVER Trashed. It only ever
    /// DESTROYS; it never reveals a secret. Runs off the main thread (launchctl +
    /// filesystem) and reports the agent-removal outcome back on the main thread.
    func uninstallApplication(deleteVaults: Bool, completion: @escaping (Bool) -> Void) {
        let log = appLog
        let env = self.env
        DispatchQueue.global(qos: .utility).async {
            let agentGone = ResealAgentInstaller.uninstall()
            log.record(.agentRemoved(success: agentGone), source: .app)
            if deleteVaults {
                env.registry.deleteAll()                                  // every vault dir
                try? FileManager.default.removeItem(at: env.vaultsRoot)   // app.log, ui.json, the root
            }
            DispatchQueue.main.async { completion(agentGone) }
        }
    }

    // MARK: - Quit

    /// The open vault that has UNSAVED edits, if any — the only case a graceful quit
    /// (Cmd-Q / menu) must warn about. Model 1: a clean (or no) open vault is just set
    /// down — it stays openable in its current window and reopens with the password —
    /// so quitting seals nothing and locks no one out. Only unsaved edits force a
    /// choice, because saving them means sealing forward (locked until the next
    /// window). The AppKit delegate reads this to decide whether to show the warning;
    /// the forward seal on "Save & Quit" is VaultModel.sealForQuit().
    var openVaultWithUnsavedEdits: VaultModel? {
        if case .open(let vm) = screen, vm.isDirty { return vm }
        return nil
    }

    /// Whether a graceful quit (Cmd-Q / menu) must warn: there are unsaved IN-MEMORY edits
    /// — an open dirty editor AND/OR one or more vaults SET ASIDE this window (warmEdits).
    /// All of it is sealed to disk only at window-end, so quitting would otherwise lose it.
    var hasUnsavedWork: Bool { openVaultWithUnsavedEdits != nil || !warmEdits.isEmpty }

    /// How many distinct vaults hold unsaved in-memory edits (the open dirty editor, if
    /// any, plus every set-aside vault) — drives the quit warning's singular/plural copy.
    var unsavedWorkCount: Int { (openVaultWithUnsavedEdits != nil ? 1 : 0) + warmEdits.count }

    /// Forward-seal EVERY piece of in-RAM work for a graceful quit (the option-1 "Seal &
    /// Quit"): the open dirty session (if any) and every warm stash. Each becomes locked
    /// until its next window. SYNCHRONOUS — the AppKit terminate reply can't await — so it
    /// reaches the network on the main thread exactly like the existing Cmd-Q seal. Returns
    /// true ONLY if EVERYTHING persisted; false if any couldn't (e.g. offline), in which
    /// case the ones that DID seal are gone from `warmEdits` and the rest stay in RAM
    /// intact — the caller must then CANCEL the quit so nothing is silently lost. Warm
    /// stashes seal PASSWORDLESSLY (reusing defensiveReseal — the PW01 rides verbatim, only
    /// the window moves forward, I8-clean).
    func sealAllForQuit() -> Bool {
        var allSealed = true
        if let vm = openVaultWithUnsavedEdits, !vm.sealForQuit() { allSealed = false }
        for (id, stash) in Array(warmEdits) {
            guard case .success(let info) = stash.store.client.currentRound(),
                  !TrustedTime.isStale(verifiedLatest: info.round, now: stash.store.clock()),
                  case .success(let w) = stash.store.defensiveReseal(unsealedPayload: stash.payload,
                                                                     verifiedLatest: info.round) else {
                allSealed = false
                continue
            }
            DiagnosticLog(url: stash.logURL).record(.resealedForward(round: w.startRound), source: .app)
            warmEdits.removeValue(forKey: id)
        }
        syncWarmMonitor()
        return allSealed
    }

    /// Re-check the open vault's window-end immediately. Pushed in from the AppKit
    /// layer on app-activation / wake-from-sleep — events VaultModel can't observe
    /// itself without importing AppKit (which would break the headless test binary).
    /// A no-op when no vault is open or it isn't unlocked.
    func recheckOpenVaultWindow() {
        if case .open(let vm) = screen { vm.recheckWindowEnd() }
    }

    // MARK: - Export / Import (portable .vault bundle, for machine migration)

    /// Closed outcome of an export/import. Carries only non-secret diagnostic text.
    enum PortError: Error, Equatable {
        case missingVault           // export: the vault has no vault.dat to pack
        case io(String)             // a read / write / allocation failure
        case badBundle(String)      // import: not a valid or not-whitelisted bundle
        case tooMany(Int)           // export: more vaults than one archive can hold
    }

    /// The vault-directory files a portable bundle carries. `diagnostics.log` is
    /// deliberately left out — it is machine-local activity, and the destination
    /// machine starts a fresh trail. `meta.json` rides along only so import can read
    /// the original label; the new vault gets a fresh meta (see `importVault`).
    private static let portableFiles = ["vault.dat", "vault.dat.bak", "schedule.json", "meta.json"]

    /// Pack one vault's sealed files into a single inner bundle blob (the exact bytes
    /// `exportVault` writes for one vault, and one outer entry of a multi-vault
    /// archive). NEVER decrypts — the bytes stay time-locked + password-locked exactly
    /// as on disk. Fails closed if the vault has nothing sealed yet (no `vault.dat`).
    private func packVaultFiles(_ entry: VaultEntry) -> Result<Data, PortError> {
        let dir = entry.dir
        var packed: [(name: String, data: Data)] = []
        for name in Self.portableFiles {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(name)) {
                packed.append((name: name, data: data))
            } else if name == VaultRegistry.vaultFileName {
                return .failure(.missingVault)
            }
        }
        return .success(VaultBundle.pack(packed))
    }

    /// Pack a single vault's sealed files into one portable `.vault` file at `dest`.
    /// The export is as protected as the live vault (until its round publishes — the
    /// migration trade-off the UI warns about). Records a secret-free export event in
    /// the vault's own diagnostics log.
    func exportVault(_ entry: VaultEntry, to dest: URL) -> Result<Void, PortError> {
        let blob: Data
        switch packVaultFiles(entry) {
        case .failure(let e): return .failure(e)
        case .success(let b): blob = b
        }
        do { try blob.write(to: dest, options: .atomic) }
        catch { return .failure(.io("write bundle: \(error)")) }
        DiagnosticLog(url: env.configuration(for: entry).diagnosticsLogURL)
            .record(.vaultExported, source: .app)
        return .success(())
    }

    /// Pack one OR MORE vaults' sealed files into a single portable `.vault` archive
    /// at `dest`. The archive is a bundle-of-bundles: each vault is packed into its
    /// own inner bundle (identical to what `exportVault` writes), and those inner
    /// blobs become the entries of an OUTER bundle named `vault-0…vault-N`. Same
    /// audited container both layers — no new parsing path — and like the single-vault
    /// export it NEVER decrypts. Fails closed before writing anything if any selected
    /// vault has nothing sealed, or if there are more vaults than one archive can hold.
    /// Records a secret-free export event in EACH vault's own diagnostics log.
    func exportVaults(_ entries: [VaultEntry], to dest: URL) -> Result<Void, PortError> {
        guard !entries.isEmpty else { return .failure(.missingVault) }
        guard entries.count <= VaultBundle.maxEntries else {
            return .failure(.tooMany(VaultBundle.maxEntries))
        }
        var outer: [(name: String, data: Data)] = []
        for (i, entry) in entries.enumerated() {
            switch packVaultFiles(entry) {
            case .failure(let e): return .failure(e)         // fail-closed: nothing written
            case .success(let blob): outer.append((name: "vault-\(i)", data: blob))
            }
        }
        do { try VaultBundle.pack(outer).write(to: dest, options: .atomic) }
        catch { return .failure(.io("write archive: \(error)")) }
        for entry in entries {
            DiagnosticLog(url: env.configuration(for: entry).diagnosticsLogURL)
                .record(.vaultExported, source: .app)
        }
        return .success(())
    }

    /// Reconstitute ONE vault from its unpacked entries as a NEW vault (fresh id).
    /// Fully validated and whitelisted: only the four known filenames are accepted,
    /// `vault.dat` is required, and the freshly-allocated directory is re-marked
    /// excluded-from-backup (fail-closed — an import that can't be kept out of OS
    /// backups is backed out entirely). Does NOT refresh the list: callers refresh
    /// once after the whole (possibly multi-vault) import settles.
    private func installVault(_ unpacked: [(name: String, data: Data)]) -> Result<VaultEntry, PortError> {
        let allowed = Set(Self.portableFiles)
        var files: [String: Data] = [:]
        for (name, data) in unpacked {
            guard allowed.contains(name) else { return .failure(.badBundle("unexpected entry “\(name)”")) }
            files[name] = data
        }
        guard let vaultDat = files[VaultRegistry.vaultFileName] else {
            return .failure(.badBundle("no \(VaultRegistry.vaultFileName) in bundle"))
        }

        // Allocate a fresh vault dir (new UUID + a current-dated meta). The label is
        // taken from the bundle's meta when present, suffixed so it never silently
        // collides with an existing vault of the same name.
        let label = Self.bundleLabel(files["meta.json"]).map { "\($0) (imported)" } ?? "Imported vault"
        guard case .success(let entry) = registry.create(label: label) else {
            return .failure(.io("could not allocate a vault directory"))
        }

        // Write the sealed files (NOT meta.json — registry.create already wrote a
        // fresh one). 0600, atomic. Then re-apply backup-exclusion the bundle could
        // not carry. Any failure backs this vault's directory out.
        func write(_ name: String, _ data: Data) -> Bool {
            let url = entry.dir.appendingPathComponent(name)
            guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        }
        var ok = write(VaultRegistry.vaultFileName, vaultDat)
        if let bak = files["vault.dat.bak"] { ok = ok && write("vault.dat.bak", bak) }
        if let sched = files["schedule.json"] { ok = ok && write("schedule.json", sched) }
        if ok { do { try VaultStore.excludeFromBackup(entry.dir) } catch { ok = false } }

        guard ok else {
            _ = registry.delete(id: entry.id)
            return .failure(.io("could not write the imported vault"))
        }
        DiagnosticLog(url: env.configuration(for: entry).diagnosticsLogURL)
            .record(.vaultImported, source: .app)
        return .success(entry)
    }

    /// Reconstitute a vault from a single-vault portable `.vault` file as a NEW vault
    /// (fresh id). Refreshes the list and returns the new entry.
    @discardableResult
    func importVault(from src: URL) -> Result<VaultEntry, PortError> {
        guard let raw = try? Data(contentsOf: src) else {
            return .failure(.io("cannot read \(src.lastPathComponent)"))
        }
        let unpacked: [(name: String, data: Data)]
        do { unpacked = try VaultBundle.unpack(raw) }
        catch { return .failure(.badBundle("\(error)")) }
        let result = installVault(unpacked)
        if case .success = result { refreshEntries(); refreshResealSchedule() }
        return result
    }

    /// Import EVERY vault contained in a portable `.vault` file. Handles both shapes
    /// transparently: a legacy single-vault bundle (entries are the sealed files
    /// directly) imports as one vault; a multi-vault archive (entries are inner
    /// bundles named `vault-N`) imports them all. Fail-closed for the batch — every
    /// inner vault is unpacked and validated BEFORE any is written, and if writing one
    /// fails the vaults already created in THIS import are rolled back, so an import
    /// lands all of its vaults or none. Refreshes the list once; returns the new
    /// entries.
    @discardableResult
    func importArchive(from src: URL) -> Result<[VaultEntry], PortError> {
        guard let raw = try? Data(contentsOf: src) else {
            return .failure(.io("cannot read \(src.lastPathComponent)"))
        }
        let outer: [(name: String, data: Data)]
        do { outer = try VaultBundle.unpack(raw) }
        catch { return .failure(.badBundle("\(error)")) }
        guard !outer.isEmpty else { return .failure(.badBundle("the file contains no vaults")) }

        // Disambiguate the two shapes by entry names. A legacy single bundle's entries
        // are the sealed files (`vault.dat`, …); a multi archive's are `vault-N`. The
        // two name sets are disjoint, so one is never misread as the other.
        let portable = Set(Self.portableFiles)
        let perVault: [[(name: String, data: Data)]]
        if outer.contains(where: { portable.contains($0.name) }) {
            perVault = [outer]                               // one legacy vault
        } else {
            // Multi archive: each outer entry is an inner bundle. Unpack + validate
            // them ALL up front so one corrupt inner aborts before anything is written.
            var parsed: [[(name: String, data: Data)]] = []
            for (_, blob) in outer {
                do { parsed.append(try VaultBundle.unpack(blob)) }
                catch { return .failure(.badBundle("\(error)")) }
            }
            perVault = parsed
        }

        // Install all; if any fails, roll back everything created in this import.
        var created: [VaultEntry] = []
        for files in perVault {
            switch installVault(files) {
            case .success(let entry): created.append(entry)
            case .failure(let err):
                for entry in created { _ = registry.delete(id: entry.id) }
                return .failure(err)
            }
        }
        refreshEntries()
        refreshResealSchedule()
        return .success(created)
    }

    /// The non-secret display label inside a bundle's meta.json, if it has a usable
    /// one. A missing/garbled/blank label simply yields nil (import falls back to a
    /// generic name) — a metadata problem never blocks the migration.
    private static func bundleLabel(_ metaData: Data?) -> String? {
        guard let metaData,
              let meta = try? JSONDecoder().decode(VaultMeta.self, from: metaData) else { return nil }
        let trimmed = meta.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

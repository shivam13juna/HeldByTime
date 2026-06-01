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

final class AppModel: ObservableObject {
    @Published var screen: AppScreen = .launching
    /// The vaults currently on disk (sealed). Drives the list; refreshed on change.
    @Published var entries: [VaultEntry] = []
    /// DISPLAY-ONLY advisory: each vault's next scheduled window opening (wall
    /// clock, from its schedule.json), keyed by vault id. Recomputed on every
    /// `refreshEntries()`. NEVER authorizes access — the list does not probe the
    /// real lock state (no network); opening the vault runs the authoritative gate.
    @Published var advisoryOpenings: [String: Date] = [:]
    /// App-global cosmetic appearance (light/dark), shared by every vault.
    @Published var uiPrefs: UIPrefs

    let env: AppEnvironment

    /// App-scope diagnostics (not tied to a vault): launch + agent registration.
    var appLog: DiagnosticLog { DiagnosticLog(url: env.appLogURL) }
    private var registry: VaultRegistry { env.registry }

    init(env: AppEnvironment = .live) {
        ProcessHardening.disableCoreDumps()   // no core file can hold decrypted secrets
        self.env = env
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

    /// Re-read the vault directories from disk and recompute the advisory next
    /// opening for each (wall-clock, schedule-derived — see `advisoryOpenings`).
    func refreshEntries() {
        entries = registry.list()
        let now = Date()
        var openings: [String: Date] = [:]
        for entry in entries {
            let url = env.configuration(for: entry).schedulePrefsURL
            let prefs = (try? SchedulePrefs.load(from: url)) ?? .default
            if let next = prefs.schedule.nextWindowOpening(after: now) {
                openings[entry.id] = next
            }
        }
        advisoryOpenings = openings
    }

    // MARK: - Navigation

    /// Open an existing vault: build its model and run the load state-machine.
    func open(_ entry: VaultEntry) {
        // The vault signals schedule edits back up so we can refresh the agent's
        // window-end triggers immediately (a schedule change must not wait for the
        // next launch to take effect).
        let vm = VaultModel(entry: entry, env: env,
                            onScheduleChanged: { [weak self] in self?.refreshResealSchedule() })
        screen = .open(vm)
        vm.reload()
    }

    /// Leave the current vault and return to the list, sealing first if it is open.
    /// When unlocked, the seal is networked, so it runs off the main thread (the
    /// editor shows a "Sealing…" overlay) and we navigate once it completes — best
    /// effort, like quit: a failed seal is closed by the launch-time / agent
    /// defensive re-seal, never left silently unsealed.
    func closeCurrent() {
        if case .open(let vm) = screen, vm.isUnlocked {
            vm.sealInteractively(trigger: .gracefulQuit) { [weak self] _ in
                self?.refreshEntries()
                self?.screen = .list
            }
            return
        }
        refreshEntries()
        screen = .list
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
                onComplete: { [weak self] in self?.finishCreate(entry) },
                onCancel:   { [weak self] in self?.cancelCreate(entry) })
            screen = .creating(frm)
        }
    }

    private func finishCreate(_ entry: VaultEntry) {
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

    // MARK: - Uninstall

    /// Prepare to remove the app: take down its background footprint and, if
    /// `deleteVaults`, wipe its data — so the user can then trash the .app (the
    /// VIEW performs the final auto-trash + quit once this completes).
    ///
    /// Order: (1) bootout + delete the re-seal LaunchAgent; (2) when `deleteVaults`,
    /// unlink EVERY vault and the app-scope residue (app log + appearance) — the
    /// whole EncryptedVault data tree, each unlinked and NEVER Trashed. It only ever
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

    /// Seal-on-graceful-quit (Cmd-Q / menu). Seals the open vault if any, then
    /// reports it is safe to terminate.
    func sealForQuit() -> Bool {
        if case .open(let vm) = screen { return vm.sealForQuit() }
        return true
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

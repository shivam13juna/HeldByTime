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

        let log = appLog
        DispatchQueue.global(qos: .utility).async {
            let ok = ResealAgentInstaller.installOrRefresh()
            log.record(.agentRegistered(success: ok), source: .app)
        }

        refreshEntries()
        screen = .list
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
        let vm = VaultModel(entry: entry, env: env)
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
        return DiagnosticLog.merge(groups)
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

    // MARK: - Quit

    /// Seal-on-graceful-quit (Cmd-Q / menu). Seals the open vault if any, then
    /// reports it is safe to terminate.
    func sealForQuit() -> Bool {
        if case .open(let vm) = screen { return vm.sealForQuit() }
        return true
    }
}

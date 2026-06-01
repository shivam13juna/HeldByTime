// appmodel_suite.swift — offline coverage for AppModel, the APP-LEVEL coordinator
// (the vault list, whole-app screen routing, and the app-global appearance). AppModel
// owns NO security decision — every lock is a vault's VaultModel/engine — so this
// suite pins its WIRING: launch bootstrap (record + legacy purge + screen), the
// registry-backed list + advisory openings, screen routing (open / create / delete /
// rename), the merged secret-free activity log, clear-all, appearance persistence,
// and seal-on-quit delegation.
//
// Everything runs over a fresh temp vaults root per check, with NO network and NO
// real launchd: AppModel.bootstrap()'s agent install is the zero-argument
// ResealAgentInstaller.installOrRefresh(), whose FIRST line is a guard on the
// bundled agent binary existing — and it does NOT in the test bundle, so the call
// returns false WITHOUT writing a plist or shelling out to launchctl. A directory
// becomes a LISTED vault the moment a vault.dat exists (the registry's "vault.dat
// presence = a vault" rule — see registry_suite), so the list/route/log wiring under
// test needs no sealing, no Argon2, no FakeSeal.
//
// AppModel is headless-testable at all because FirstRunModel and UIPrefs/Appearance
// were extracted into Foundation-only files (run_tests scope/app-headless pins this).
// NOTE: appmodel/finish-create-opens-new from the plan is intentionally NOT here —
// finishCreate is private and reachable only through FirstRunModel.create()'s
// networked success path, which has no offline seam today (unlike VaultModel.makeStore).

import Foundation

private func amk(_ n: String, _ cond: Bool, _ d: String = "") { check("appmodel/" + n, cond, d) }

func runAppModelSuite() {
    let fm = FileManager.default
    var roots: [URL] = []
    defer { for r in roots { try? fm.removeItem(at: r) } }

    // A fresh, isolated vaults root + environment per check (several checks assert on
    // the whole list, so they must not see each other's vaults).
    func freshEnv() -> AppEnvironment {
        let r = fm.temporaryDirectory.appendingPathComponent("vault-app-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: r, withIntermediateDirectories: true)
        roots.append(r)
        return AppEnvironment(vaultsRoot: r,
                              helperURL: r.appendingPathComponent("vaultseal"),
                              compiledHelperSHA256: [])
    }
    // Allocate a vault dir and drop a vault.dat so the registry LISTS it (no real seal
    // needed for the routing/list/log wiring). `at:` controls createdAt for ordering.
    func makeVault(_ env: AppEnvironment, _ label: String, at t: TimeInterval) -> VaultEntry {
        guard case .success(let e) = env.registry.create(label: label, now: Date(timeIntervalSince1970: t)) else {
            fatalError("registry.create failed in appmodel test setup")
        }
        try? Data("x".utf8).write(to: e.dir.appendingPathComponent(VaultRegistry.vaultFileName))
        return e
    }
    // Bounded wait for a background (global-queue) effect — bootstrap installs the
    // agent off the main thread, so we poll the app log until the line lands.
    func waitUntil(_ secs: Double, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(secs)
        while Date() < deadline {
            if cond() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return cond()
    }

    // ===== Lifecycle: bootstrap =====

    // bootstrap() records the launch, drops the obsolete single-vault layout (keeping
    // the app-global ui.json), and shows the list.
    do {
        let env = freshEnv()
        try? Data("x".utf8).write(to: env.vaultsRoot.appendingPathComponent("vault.dat"))
        try? Data("x".utf8).write(to: env.vaultsRoot.appendingPathComponent("schedule.json"))
        try? Data("{\"appearance\":\"dark\"}".utf8).write(to: env.uiPrefsURL)
        let model = AppModel(env: env)
        model.bootstrap()
        var isList = false; if case .list = model.screen { isList = true }
        let launched = model.appLog.tail().contains { $0.contains("app launched") }
        let purged = !fm.fileExists(atPath: env.vaultsRoot.appendingPathComponent("vault.dat").path)
        let keptUI = fm.fileExists(atPath: env.uiPrefsURL.path)
        amk("bootstrap-records-launch",
            isList && launched && purged && keptUI,
            "bootstrap ⇒ .list, logs 'app launched', purges the legacy top-level vault, keeps ui.json")
    }

    // bootstrap() registers the re-seal agent off the main thread and records the
    // outcome. In the test bundle the agent binary is absent ⇒ installOrRefresh()
    // returns false WITHOUT touching launchd, but the wiring still logs the (skipped)
    // result — the bridge the installer itself can't log.
    do {
        let env = freshEnv()
        let model = AppModel(env: env)
        model.bootstrap()
        let armed = waitUntil(8) { model.appLog.tail().contains { $0.contains("re-seal agent") } }
        amk("bootstrap-registers-agent", armed,
            "bootstrap records an agentRegistered outcome (best-effort install wiring)")
    }

    // refreshEntries lists every sealed vault oldest-first and computes a DISPLAY-ONLY
    // advisory next-opening for each (the default schedule has a window ⇒ non-nil).
    do {
        let env = freshEnv()
        let a = makeVault(env, "Personal", at: 1000)
        let b = makeVault(env, "Work", at: 2000)
        let model = AppModel(env: env)
        model.refreshEntries()
        amk("refresh-lists-sealed-vaults",
            model.entries.count == 2
              && model.entries.first?.id == a.id && model.entries.last?.id == b.id
              && model.advisoryOpenings[a.id] != nil && model.advisoryOpenings[b.id] != nil,
            "two sealed vaults ⇒ both listed oldest-first, each with an advisory opening")
    }

    // ===== Navigation =====

    // open(entry) builds that vault's model, routes to it, and triggers the load.
    do {
        let env = freshEnv()
        let a = makeVault(env, "V", at: 1000)
        let model = AppModel(env: env)
        model.open(a)
        var ok = false
        if case .open(let vm) = model.screen { ok = (vm.id == a.id) }
        amk("open-builds-model-and-loads", ok,
            "open(entry) ⇒ screen .open(vm) with vm.id == entry.id (load kicked off)")
    }

    // ===== Create flow (allocate / cancel) =====

    // beginCreate allocates a directory and enters setup, but the vault is NOT listed
    // until a vault.dat is actually sealed into it.
    do {
        let env = freshEnv()
        let model = AppModel(env: env)
        model.beginCreate()
        var creating = false; if case .creating = model.screen { creating = true }
        amk("begin-create-allocates",
            creating && env.registry.list().isEmpty,
            "beginCreate ⇒ .creating; dir allocated but not listed until a vault.dat is sealed")
    }

    // Cancelling setup (via the FirstRunModel's cancel) unlinks the empty allocation
    // and returns to the list.
    do {
        let env = freshEnv()
        let model = AppModel(env: env)
        model.beginCreate()
        let allocated = (try? fm.contentsOfDirectory(at: env.vaultsRoot, includingPropertiesForKeys: nil)) ?? []
        var cancelled = false
        if case .creating(let frm) = model.screen { frm.cancel(); cancelled = true }
        var isList = false; if case .list = model.screen { isList = true }
        let after = (try? fm.contentsOfDirectory(at: env.vaultsRoot, includingPropertiesForKeys: nil)) ?? []
        amk("cancel-create-unlinks",
            cancelled && isList && allocated.count == 1 && after.isEmpty,
            "cancel() unlinks the empty allocated dir and returns to .list")
    }

    // ===== Delete =====

    // Deleting the currently-open vault falls back to the list and removes it.
    do {
        let env = freshEnv()
        let a = makeVault(env, "V", at: 1000)
        let model = AppModel(env: env)
        model.refreshEntries()
        model.open(a)
        model.deleteVault(a)
        var isList = false; if case .list = model.screen { isList = true }
        amk("delete-current-falls-back-to-list",
            isList && !model.entries.contains { $0.id == a.id } && !fm.fileExists(atPath: a.dir.path),
            "deleting the open vault ⇒ back to .list, gone from entries and unlinked on disk")
    }

    // Deleting A leaves B intact (model-level mirror of e2e/multivault-delete-isolated).
    do {
        let env = freshEnv()
        let a = makeVault(env, "A", at: 1000)
        let b = makeVault(env, "B", at: 2000)
        let model = AppModel(env: env)
        model.refreshEntries()
        model.deleteVault(a)
        amk("delete-isolated",
            !model.entries.contains { $0.id == a.id } && model.entries.contains { $0.id == b.id }
              && fm.fileExists(atPath: b.dir.path) && !fm.fileExists(atPath: a.dir.path),
            "deleting A leaves B intact on disk and in the list")
    }

    // ===== Rename =====

    // A blank or identical name is ignored; a real, different name updates the label.
    do {
        let env = freshEnv()
        let a = makeVault(env, "Original", at: 1000)
        let model = AppModel(env: env)
        model.refreshEntries()
        model.renameVault(a, to: "   ")
        let afterBlank = model.entries.first { $0.id == a.id }?.meta.label
        model.renameVault(a, to: "Original")
        let afterSame = model.entries.first { $0.id == a.id }?.meta.label
        model.renameVault(a, to: "Renamed")
        let afterReal = model.entries.first { $0.id == a.id }?.meta.label
        amk("rename-ignores-blank",
            afterBlank == "Original" && afterSame == "Original" && afterReal == "Renamed",
            "blank/identical rename is a no-op; a real rename updates the label")
    }

    // ===== Merged activity log =====

    // mergedLogLines prefixes [App] and each vault's label, ordered by the raw UTC
    // timestamp (storage stays UTC even when displayed locally). Secret-free inputs.
    do {
        let env = freshEnv()
        let a = makeVault(env, "Work", at: 1000)
        let model = AppModel(env: env)
        model.refreshEntries()
        DiagnosticLog(url: env.appLogURL)
            .record(.appLaunched, source: .app, now: Date(timeIntervalSince1970: 1000))
        DiagnosticLog(url: env.configuration(for: a).diagnosticsLogURL)
            .record(.checkedVault(.locked, round: nil), source: .app, now: Date(timeIntervalSince1970: 2000))
        let merged = model.mergedLogLines()
        let appIdx = merged.firstIndex { $0.hasPrefix("[App]") && $0.contains("app launched") }
        let vaultIdx = merged.firstIndex { $0.hasPrefix("[Work]") && $0.contains("checked vault") }
        amk("merged-log-tags-and-orders",
            appIdx != nil && vaultIdx != nil && appIdx! < vaultIdx!,
            "merged log tags [App]/[label] and orders by UTC (earlier app line before the later vault line)")
    }

    // clearAllLogs empties the app-scope log AND every vault's diagnostics.log.
    do {
        let env = freshEnv()
        let a = makeVault(env, "V", at: 1000)
        let model = AppModel(env: env)
        model.refreshEntries()
        DiagnosticLog(url: env.appLogURL).record(.appLaunched, source: .app)
        let vlog = DiagnosticLog(url: env.configuration(for: a).diagnosticsLogURL)
        vlog.record(.checkedVault(.locked, round: nil), source: .app)
        let hadBoth = !DiagnosticLog(url: env.appLogURL).tail().isEmpty && !vlog.tail().isEmpty
        model.clearAllLogs()
        amk("clear-all-logs-wipes-every-log",
            hadBoth && DiagnosticLog(url: env.appLogURL).tail().isEmpty && vlog.tail().isEmpty,
            "clearAllLogs empties the app log and every vault's diagnostics.log")
    }

    // ===== Appearance =====

    // applyAppearance updates the in-memory pref, persists ui.json, and touches NO
    // screen/route (it is cosmetic — never a lock decision).
    do {
        let env = freshEnv()
        let model = AppModel(env: env)
        var wasLaunching = false; if case .launching = model.screen { wasLaunching = true }
        model.applyAppearance(.dark)
        let persisted = try? UIPrefs.load(from: env.uiPrefsURL)
        var stillLaunching = false; if case .launching = model.screen { stillLaunching = true }
        amk("appearance-persists",
            model.uiPrefs.appearance == .dark && persisted?.appearance == .dark
              && wasLaunching && stillLaunching,
            "applyAppearance updates uiPrefs, writes ui.json, and changes no screen/lock state")
    }

    // ===== Quit =====

    // sealForQuit is true with no open vault, and delegates to the open vault
    // otherwise (which, not unlocked, has nothing decrypted to seal ⇒ safe).
    do {
        let env = freshEnv()
        let model = AppModel(env: env)
        let noVault = model.sealForQuit()
        let a = makeVault(env, "V", at: 1000)
        model.open(a)
        let withVault = model.sealForQuit()
        amk("sealforquit",
            noVault == true && withVault == true,
            "sealForQuit ⇒ true with no open vault, and delegates to the open vault (safe) otherwise")
    }

    // ===== Export / Import (portable .vault bundle) =====

    // A vault exported to a .vault file and imported back ⇒ a NEW vault (fresh id)
    // with byte-identical sealed contents, an "(imported)" label, both vaults listed,
    // and a secret-free export event logged. (Backup-exclusion is checked separately.)
    do {
        let env = freshEnv()
        let a = makeVault(env, "Migrate Me", at: 1000)
        let vaultBytes = Data((0..<128).map { UInt8($0 & 0xff) })
        try? vaultBytes.write(to: a.dir.appendingPathComponent(VaultRegistry.vaultFileName))
        try? Data("{\"windows\":[]}".utf8).write(to: a.dir.appendingPathComponent("schedule.json"))
        let model = AppModel(env: env)
        model.refreshEntries()

        let dest = env.vaultsRoot.appendingPathComponent("export.vault")
        var exportOK = false
        if case .success = model.exportVault(a, to: dest) { exportOK = true }
        let fileThere = fm.fileExists(atPath: dest.path)
        let logged = DiagnosticLog(url: env.configuration(for: a).diagnosticsLogURL)
            .tail().contains { $0.contains("exported a portable copy") }

        var newEntry: VaultEntry?
        if case .success(let e) = model.importVault(from: dest) { newEntry = e }
        let listed = env.registry.list()
        let newBytes = newEntry.flatMap { try? Data(contentsOf: $0.dir.appendingPathComponent(VaultRegistry.vaultFileName)) }
        let labelOK = newEntry?.meta.label.contains("imported") == true
        let freshId = newEntry != nil && newEntry?.id != a.id
        let bothListed = listed.contains { $0.id == a.id }
            && (newEntry.map { ne in listed.contains { $0.id == ne.id } } ?? false)

        amk("export-import-roundtrip",
            exportOK && fileThere && logged && freshId && newBytes == vaultBytes && labelOK && bothListed,
            "export→import ⇒ a new vault with identical sealed bytes, '(imported)' label, both listed, export logged")
    }

    // Import re-applies backup-exclusion to the reconstituted dir (fail-closed: import
    // only SUCCEEDS if exclusion stuck, so success ⇒ the dir is excluded). Asserted
    // on its own so the env-sensitive xattr read can't mask the roundtrip wiring.
    do {
        let env = freshEnv()
        let a = makeVault(env, "X", at: 1000)
        try? Data("sealed".utf8).write(to: a.dir.appendingPathComponent(VaultRegistry.vaultFileName))
        let model = AppModel(env: env)
        let dest = env.vaultsRoot.appendingPathComponent("x.vault")
        _ = model.exportVault(a, to: dest)
        var excluded = false
        if case .success(let e) = model.importVault(from: dest) {
            excluded = ((try? e.dir.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup) == true
        }
        amk("export-import-backup-exclusion", excluded,
            "an imported vault directory is excluded from OS backup (Time Machine / iCloud)")
    }

    // Exporting a vault with no sealed vault.dat ⇒ missingVault (nothing to migrate).
    do {
        let env = freshEnv()
        guard case .success(let empty) = env.registry.create(label: "Empty") else {
            fatalError("registry.create failed in export test setup")
        }
        let model = AppModel(env: env)
        var missing = false
        if case .failure(.missingVault) = model.exportVault(empty, to: env.vaultsRoot.appendingPathComponent("e.vault")) {
            missing = true
        }
        amk("export-missing-vault", missing,
            "exporting a vault with no vault.dat ⇒ .missingVault (nothing sealed yet)")
    }

    // A bundle with no vault.dat ⇒ badBundle (can't reconstitute a vault).
    do {
        let env = freshEnv()
        let model = AppModel(env: env)
        let p = env.vaultsRoot.appendingPathComponent("noVault.vault")
        try? VaultBundle.pack([("schedule.json", Data("{}".utf8))]).write(to: p)
        var bad = false
        if case .failure(.badBundle) = model.importVault(from: p) { bad = true }
        amk("import-rejects-missing-vaultdat", bad && env.registry.list().isEmpty,
            "a bundle without vault.dat ⇒ .badBundle and no vault is created")
    }

    // A bundle carrying a non-whitelisted entry ⇒ badBundle (only the four known
    // filenames are ever written into a vault directory).
    do {
        let env = freshEnv()
        let model = AppModel(env: env)
        let p = env.vaultsRoot.appendingPathComponent("weird.vault")
        try? VaultBundle.pack([("vault.dat", Data("x".utf8)), ("evil.txt", Data("y".utf8))]).write(to: p)
        var bad = false
        if case .failure(.badBundle) = model.importVault(from: p) { bad = true }
        amk("import-rejects-unknown-entry", bad && env.registry.list().isEmpty,
            "a bundle with an unexpected entry name ⇒ .badBundle and no vault is created")
    }

    // Multi-vault export → import: exportVaults packs several vaults into ONE archive,
    // importArchive reconstitutes every one (fresh ids, '(imported)' labels, identical
    // sealed bytes), and all of them — plus the originals — are listed.
    do {
        let env = freshEnv()
        let a = makeVault(env, "Alpha", at: 1000)
        let b = makeVault(env, "Beta", at: 2000)
        let aBytes = Data((0..<96).map { UInt8($0 & 0xff) })
        let bBytes = Data("beta sealed bytes".utf8)
        try? aBytes.write(to: a.dir.appendingPathComponent(VaultRegistry.vaultFileName))
        try? bBytes.write(to: b.dir.appendingPathComponent(VaultRegistry.vaultFileName))
        let model = AppModel(env: env)
        model.refreshEntries()

        let dest = env.vaultsRoot.appendingPathComponent("two.vault")
        var exportOK = false
        if case .success = model.exportVaults([a, b], to: dest) { exportOK = true }

        var imported: [VaultEntry] = []
        if case .success(let es) = model.importArchive(from: dest) { imported = es }
        let importedBytes = Set(imported.compactMap { e in
            try? Data(contentsOf: e.dir.appendingPathComponent(VaultRegistry.vaultFileName))
        })
        let bytesMatch = importedBytes == Set([aBytes, bBytes])
        let freshIds = imported.count == 2 && Set(imported.map { $0.id }).isDisjoint(with: [a.id, b.id])
        let labelsOK = imported.allSatisfy { $0.meta.label.contains("imported") }
        let allListed = env.registry.list().count == 4

        amk("export-import-multi-roundtrip",
            exportOK && bytesMatch && freshIds && labelsOK && allListed,
            "exportVaults([a,b]) → importArchive ⇒ two fresh vaults carrying both original blobs, all four listed")
    }

    // importArchive transparently reads a LEGACY single-vault bundle (the shape
    // exportVault writes) as exactly one vault — old single exports still import.
    do {
        let env = freshEnv()
        let a = makeVault(env, "Solo", at: 1000)
        let bytes = Data("solo sealed bytes".utf8)
        try? bytes.write(to: a.dir.appendingPathComponent(VaultRegistry.vaultFileName))
        let model = AppModel(env: env)
        let dest = env.vaultsRoot.appendingPathComponent("solo.vault")
        _ = model.exportVault(a, to: dest)          // legacy single-vault format

        var imported: [VaultEntry] = []
        if case .success(let es) = model.importArchive(from: dest) { imported = es }
        let sameBytes = imported.first.flatMap {
            try? Data(contentsOf: $0.dir.appendingPathComponent(VaultRegistry.vaultFileName))
        } == bytes
        amk("import-archive-reads-legacy-single", imported.count == 1 && sameBytes,
            "importArchive reads a single-vault bundle as one imported vault (backward compatible)")
    }

    // Exporting more vaults than one archive can hold ⇒ tooMany, BEFORE any file is
    // written (the outer container caps at VaultBundle.maxEntries).
    do {
        let env = freshEnv()
        let model = AppModel(env: env)
        let many = (0...VaultBundle.maxEntries).map { i -> VaultEntry in
            guard case .success(let e) = env.registry.create(label: "V\(i)") else {
                fatalError("registry.create failed in tooMany setup")
            }
            return e
        }
        let dest = env.vaultsRoot.appendingPathComponent("too-many.vault")
        var tooMany = false
        if case .failure(.tooMany(VaultBundle.maxEntries)) = model.exportVaults(many, to: dest) { tooMany = true }
        amk("export-too-many", tooMany && !fm.fileExists(atPath: dest.path),
            "exporting more than maxEntries vaults ⇒ .tooMany and nothing written")
    }

    // A multi archive with one corrupt inner bundle ⇒ badBundle, and NOTHING is
    // imported: every inner is validated up front, so a single bad one aborts the
    // whole batch before any vault is created (all-or-none).
    do {
        let env = freshEnv()
        let model = AppModel(env: env)
        let goodInner = VaultBundle.pack([("vault.dat", Data("ok".utf8))])
        let outer = VaultBundle.pack([
            ("vault-0", goodInner),
            ("vault-1", Data("not a valid inner bundle".utf8)),
        ])
        let p = env.vaultsRoot.appendingPathComponent("corrupt-multi.vault")
        try? outer.write(to: p)
        var bad = false
        if case .failure(.badBundle) = model.importArchive(from: p) { bad = true }
        amk("import-archive-corrupt-inner-rollback", bad && env.registry.list().isEmpty,
            "a multi archive with one corrupt inner ⇒ .badBundle and no vault is created")
    }
}

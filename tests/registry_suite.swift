// registry_suite.swift — offline coverage for the multi-vault data layer
// (VaultRegistry + the Schedule advisory next-opening). Exercises scan/create/
// delete/rename over a temp root, the "vault.dat presence = a vault" rule, the
// untitled-meta fallback, legacy-dummy purge (keeping ui.json), id hardening,
// and the DISPLAY-ONLY next-window computation. No drand, no sealing — this
// layer never touches vault bytes.

import Foundation

private func touch(_ url: URL, _ contents: String = "x") {
    try? contents.data(using: .utf8)!.write(to: url)
}

func runRegistrySuite() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("vault-reg-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    let reg = VaultRegistry(root: root)

    // Empty root ⇒ no vaults.
    check("reg/empty", reg.list().isEmpty && !reg.hasAnyVault, "fresh root has no vaults")

    // create() allocates a dir + meta but NO vault.dat yet ⇒ not listed.
    guard case .success(let alloc) = reg.create(label: "Personal",
                                                now: Date(timeIntervalSince1970: 1000)) else {
        fail("reg/create-alloc", "create() failed"); return
    }
    check("reg/alloc-not-listed", reg.list().isEmpty,
          "an allocated-but-unsealed vault must not appear in the list")
    check("reg/alloc-dir-exists", fm.fileExists(atPath: alloc.dir.path), "allocation creates the dir")

    // Once a vault.dat lands, it IS a vault.
    touch(alloc.dir.appendingPathComponent(VaultRegistry.vaultFileName))
    let listed = reg.list()
    check("reg/sealed-listed", listed.count == 1 && listed.first?.id == alloc.id,
          "a dir with vault.dat is listed")
    check("reg/meta-roundtrip", listed.first?.meta.label == "Personal",
          "meta.json label round-trips")

    // A second vault, created later, sorts after the first (oldest-first).
    guard case .success(let second) = reg.create(label: "Work",
                                                 now: Date(timeIntervalSince1970: 2000)) else {
        fail("reg/create-second", "create() failed"); return
    }
    touch(second.dir.appendingPathComponent(VaultRegistry.vaultFileName))
    let two = reg.list()
    check("reg/two-vaults", two.count == 2, "expected 2 vaults, got \(two.count)")
    check("reg/sorted-oldest-first", two.first?.meta.label == "Personal" && two.last?.meta.label == "Work",
          "list is ordered by createdAt")
    check("reg/has-any", reg.hasAnyVault, "hasAnyVault true with sealed vaults")

    // Missing/garbled meta ⇒ a real vault still shows, labelled generically.
    let orphan = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? fm.createDirectory(at: orphan, withIntermediateDirectories: true)
    touch(orphan.appendingPathComponent(VaultRegistry.vaultFileName))
    touch(orphan.appendingPathComponent("meta.json"), "{ this is not json")
    let withOrphan = reg.list()
    check("reg/untitled-shown", withOrphan.contains { $0.meta.label == VaultRegistry.untitledLabel },
          "a vault with corrupt meta is shown as Untitled, never hidden")

    // rename relabels in place.
    guard case .success = reg.rename(id: second.id, to: "Work v2") else {
        fail("reg/rename", "rename failed"); return
    }
    check("reg/renamed", reg.list().contains { $0.id == second.id && $0.meta.label == "Work v2" },
          "rename updates the label")

    // delete is permanent: the whole dir is unlinked.
    guard case .success = reg.delete(id: alloc.id) else { fail("reg/delete", "delete failed"); return }
    check("reg/deleted-gone", !fm.fileExists(atPath: alloc.dir.path),
          "delete unlinks the entire vault directory")
    check("reg/deleted-not-listed", !reg.list().contains { $0.id == alloc.id },
          "deleted vault no longer appears")

    // id hardening: traversal / empty / dotdot are rejected, root untouched.
    for bad in ["", ".", "..", "../escape", "a/b"] {
        if case .success = reg.delete(id: bad) {
            fail("reg/id-hardening", "delete accepted unsafe id '\(bad)'"); return
        }
    }
    check("reg/id-hardening", true, "unsafe ids rejected")
    check("reg/root-intact", fm.fileExists(atPath: root.path), "root survives rejected ids")

    // Legacy purge: a pre-multi-vault top-level vault.dat is removed; ui.json kept.
    touch(root.appendingPathComponent("vault.dat"))
    touch(root.appendingPathComponent("vault.dat.bak"))
    touch(root.appendingPathComponent("schedule.json"))
    touch(root.appendingPathComponent("diagnostics.log"))
    touch(root.appendingPathComponent("ui.json"), "{\"appearance\":\"dark\"}")
    reg.purgeLegacyTopLevelVault()
    check("reg/legacy-purged",
          !fm.fileExists(atPath: root.appendingPathComponent("vault.dat").path)
            && !fm.fileExists(atPath: root.appendingPathComponent("vault.dat.bak").path)
            && !fm.fileExists(atPath: root.appendingPathComponent("schedule.json").path)
            && !fm.fileExists(atPath: root.appendingPathComponent("diagnostics.log").path),
          "legacy top-level vault files are removed")
    check("reg/legacy-keeps-ui", fm.fileExists(atPath: root.appendingPathComponent("ui.json").path),
          "app-global ui.json (appearance) is preserved by the purge")
    check("reg/legacy-keeps-subdirs", reg.list().contains { $0.id == second.id },
          "purge does not touch real vault subdirectories")

    // Schedule advisory: next opening is the soonest future window start (DISPLAY).
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let win = DailyWindow(start: TimeOfDay(hour: 4, minute: 0)!, end: TimeOfDay(hour: 5, minute: 0)!)
    let sched = Schedule(windows: [win], calendar: cal)
    // 2001-01-01 00:00:00 UTC = referenceDate; next 04:00 opening is +4h.
    let now = Date(timeIntervalSinceReferenceDate: 0)
    let opening = sched.nextWindowOpening(after: now)
    check("reg/next-opening", opening == now.addingTimeInterval(4 * 3600),
          "advisory next opening is the soonest future window start")
    check("reg/no-windows-nil", Schedule(windows: [], calendar: cal).nextWindowOpening(after: now) == nil,
          "no windows ⇒ no advisory opening")
}

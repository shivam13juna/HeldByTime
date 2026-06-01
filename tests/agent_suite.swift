// agent_suite.swift — offline coverage for ResealAgentInstaller, the side-effecting
// app-side half of the re-seal LaunchAgent (the pure plist spec is LaunchAgentPlist,
// already covered by reseal_suite). The installer's THREE side effects — does the
// bundled agent exist, persist the plist, run launchctl — are injected here, so we
// exercise the install ACT without touching launchd or the real filesystem: the
// decisions (install vs skip vs fail-quiet) and the exact launchctl sequence, which
// is the behavioural contract launchd actually sees. The real bootstrap into a live
// GUI session stays manual (E2E.md); this proves the wiring beneath it.
//
// Nothing here is secret: the installer only ever handles a non-secret plist and a
// path, and (per the leak/logging fence) never logs.

import Foundation

func runAgentSuite() {
    // A throwaway tree standing in for the bundle + ~/Library/LaunchAgents. We never
    // actually create these files (writePlist is faked); the URLs just have to be
    // stable and distinct.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("vault-agent-\(UUID().uuidString)", isDirectory: true)
    let agent = root.appendingPathComponent("EncryptedVault.app/Contents/Helpers/vaultreseal")
    let plistURL = root.appendingPathComponent("LaunchAgents/\(LaunchAgentPlist.resealLabel).plist")
    let uid: uid_t = 501
    let domain = "gui/\(uid)"
    let label = LaunchAgentPlist.resealLabel

    // --- agent/skips-when-binary-absent ---
    // No bundled agent ⇒ nothing to arm: returns false, writes no plist, and NEVER
    // calls launchctl (arming launchd at a missing path is the one thing to avoid).
    do {
        var wrote = false
        var ran: [[String]] = []
        let ok = ResealAgentInstaller.installOrRefresh(
            agentURL: agent, plistURL: plistURL, uid: uid,
            fileExists: { _ in false },
            writePlist: { _, _ in wrote = true },
            run: { ran.append($0) })
        check("agent/skips-when-binary-absent",
              ok == false && wrote == false && ran.isEmpty,
              "absent agent ⇒ false, no plist written, launchctl never called")
    }

    // The remaining cases assume the bundled agent IS present (only at its path).
    let exists: (String) -> Bool = { $0 == agent.path }

    // --- agent/writes-plist + agent/plist-points-at-current-bundle ---
    // Present agent ⇒ true; the plist is written at plistURL with EXACTLY the bytes
    // LaunchAgentPlist.reseal produces for this agent path (so the spec is the single
    // source of truth), and those bytes point launchd at THIS bundle's agent path —
    // the self-heal-after-move contract.
    do {
        var written: (data: Data, url: URL)?
        let ok = ResealAgentInstaller.installOrRefresh(
            agentURL: agent, plistURL: plistURL, uid: uid,
            fileExists: exists,
            writePlist: { written = ($0, $1) },
            run: { _ in })
        check("agent/writes-plist",
              ok && written?.url == plistURL
                && written?.data == LaunchAgentPlist.reseal(programPath: agent.path),
              "present agent ⇒ true; plist written at plistURL with the exact spec bytes")
        let body = written.flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
        check("agent/plist-points-at-current-bundle",
              body.contains(agent.path),
              "the written plist's ProgramArguments must carry the injected agent path")
    }

    // --- agent/launchctl-sequence ---  (the core behavioural contract)
    // launchctl must be bootout → bootstrap → kickstart, in that order, in the user's
    // gui/<uid> domain, kickstarting the labelled job.
    do {
        var ran: [[String]] = []
        _ = ResealAgentInstaller.installOrRefresh(
            agentURL: agent, plistURL: plistURL, uid: uid,
            fileExists: exists,
            writePlist: { _, _ in },
            run: { ran.append($0) })
        check("agent/launchctl-sequence",
              ran.count == 3
                && ran[0] == ["bootout",   domain, plistURL.path]
                && ran[1] == ["bootstrap", domain, plistURL.path]
                && ran[2] == ["kickstart", "\(domain)/\(label)"],
              "launchctl must be bootout → bootstrap → kickstart in gui/<uid> with the job label")
    }

    // --- agent/idempotent-refresh ---
    // A later call with a CHANGED agent path (the .app moved) rewrites the plist to
    // the new path and re-issues the full bootout→bootstrap→kickstart — the self-heal.
    do {
        let moved = root.appendingPathComponent("Moved.app/Contents/Helpers/vaultreseal")
        var written: (data: Data, url: URL)?
        var ran: [[String]] = []
        let ok = ResealAgentInstaller.installOrRefresh(
            agentURL: moved, plistURL: plistURL, uid: uid,
            fileExists: { $0 == moved.path },
            writePlist: { written = ($0, $1) },
            run: { ran.append($0) })
        let body = written.flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
        check("agent/idempotent-refresh",
              ok && body.contains(moved.path)
                && ran.count == 3 && ran[0] == ["bootout", domain, plistURL.path],
              "a changed agent path ⇒ rewritten plist + fresh bootout→bootstrap→kickstart")
    }

    // --- agent/write-failure-failquiet ---
    // If the plist can't be persisted there's nothing to bootstrap: return false,
    // call launchctl zero times, and never crash (best-effort install).
    do {
        struct WriteError: Error {}
        var ran: [[String]] = []
        let ok = ResealAgentInstaller.installOrRefresh(
            agentURL: agent, plistURL: plistURL, uid: uid,
            fileExists: exists,
            writePlist: { _, _ in throw WriteError() },
            run: { ran.append($0) })
        check("agent/write-failure-failquiet",
              ok == false && ran.isEmpty,
              "a plist write failure ⇒ false, launchctl never called, no crash")
    }

    // --- agent/returns-true-regardless-of-launchctl ---
    // launchctl is best-effort: the return means "plist written + bootstrap attempted",
    // NOT "loaded". Even if every launchctl call is a no-op, the success path is true.
    do {
        let ok = ResealAgentInstaller.installOrRefresh(
            agentURL: agent, plistURL: plistURL, uid: uid,
            fileExists: exists,
            writePlist: { _, _ in },
            run: { _ in /* pretend launchctl achieved nothing */ })
        check("agent/returns-true-regardless-of-launchctl", ok == true,
              "success path returns true once the plist is written + bootstrap attempted")
    }

    // --- agent/calendar-times-reach-plist ---
    // calendarTimes passed to installOrRefresh must land in the written plist as
    // StartCalendarInterval — the window-end boundary wiring. The single source of
    // truth is LaunchAgentPlist.reseal, so we compare against its bytes for the same
    // path + times (proving the installer threads them through unchanged).
    do {
        let times = [DailyFireTime(hour: 5, minute: 1), DailyFireTime(hour: 17, minute: 31)]
        var written: (data: Data, url: URL)?
        let ok = ResealAgentInstaller.installOrRefresh(
            agentURL: agent, plistURL: plistURL, uid: uid,
            calendarTimes: times,
            fileExists: exists,
            writePlist: { written = ($0, $1) },
            run: { _ in })
        check("agent/calendar-times-reach-plist",
              ok && written?.data == LaunchAgentPlist.reseal(programPath: agent.path, calendarTimes: times),
              "installOrRefresh threads calendarTimes into the written plist (window-end boundaries)")
    }

    // --- agent/install-no-kickstart ---
    // kickstart:false is a pure trigger RELOAD (used after a schedule edit / vault
    // add / remove): bootout → bootstrap to load the new calendar entries, but NO
    // kickstart — the agent must not run now (a schedule change only affects the
    // NEXT re-seal).
    do {
        var ran: [[String]] = []
        let ok = ResealAgentInstaller.installOrRefresh(
            agentURL: agent, plistURL: plistURL, uid: uid,
            kickstart: false,
            fileExists: exists,
            writePlist: { _, _ in },
            run: { ran.append($0) })
        check("agent/install-no-kickstart",
              ok && ran == [["bootout", domain, plistURL.path], ["bootstrap", domain, plistURL.path]],
              "kickstart:false ⇒ bootout → bootstrap only (reload triggers, no immediate run)")
    }

    // --- agent/uninstall-boots-out-then-removes ---  (the uninstall behavioural contract)
    // Uninstall must unload the job by LABEL (gui/<uid>/<label>) and THEN delete the
    // plist — in that order — and report the agent gone.
    do {
        var ran: [[String]] = []
        var removed: [URL] = []
        let ok = ResealAgentInstaller.uninstall(
            plistURL: plistURL, uid: uid,
            fileExists: { _ in true },          // plist present
            removeFile: { removed.append($0) },
            run: { ran.append($0) })
        check("agent/uninstall-boots-out-then-removes",
              ok && ran == [["bootout", "\(domain)/\(label)"]] && removed == [plistURL],
              "uninstall ⇒ bootout gui/<uid>/<label>, then delete the plist, return true")
    }

    // --- agent/uninstall-when-absent ---
    // No plist on disk ⇒ still boot out (harmless), DON'T call removeFile, return
    // true (the end state is "agent gone" either way).
    do {
        var ran: [[String]] = []
        var removed: [URL] = []
        let ok = ResealAgentInstaller.uninstall(
            plistURL: plistURL, uid: uid,
            fileExists: { _ in false },         // already absent
            removeFile: { removed.append($0) },
            run: { ran.append($0) })
        check("agent/uninstall-when-absent",
              ok && ran == [["bootout", "\(domain)/\(label)"]] && removed.isEmpty,
              "absent plist ⇒ bootout only, no remove, still true (already uninstalled)")
    }

    // --- agent/uninstall-remove-failure-failquiet ---
    // The plist exists but can't be deleted ⇒ return false (no crash); bootout was
    // still attempted (best-effort, mirroring the install side).
    do {
        struct RemoveError: Error {}
        var ran: [[String]] = []
        let ok = ResealAgentInstaller.uninstall(
            plistURL: plistURL, uid: uid,
            fileExists: { _ in true },
            removeFile: { _ in throw RemoveError() },
            run: { ran.append($0) })
        check("agent/uninstall-remove-failure-failquiet",
              ok == false && ran == [["bootout", "\(domain)/\(label)"]],
              "a plist-delete failure ⇒ false, bootout still attempted, no crash")
    }
}

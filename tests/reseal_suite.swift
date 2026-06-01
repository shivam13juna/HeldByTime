// reseal_suite.swift — offline coverage for the re-seal LaunchAgent SPEC
// (LaunchAgentPlist). The agent's behaviour itself is VaultStore.load(), already
// exercised by store_suite (expired ⇒ forward re-seal, etc.); here we only prove
// the generated launchd plist is well-formed and carries the keys launchd needs
// — including that the program path survives XML-escaping intact (a path with an
// ampersand round-trips through the plist parser unchanged).

import Foundation

func runResealSuite() {
    // A deliberately awkward path: spaces AND an ampersand, to catch any
    // hand-rolled / unescaped XML regression.
    let path = "/Applications/Tools & Vaults/EncryptedVault.app/Contents/Helpers/vaultreseal"
    let data = LaunchAgentPlist.reseal(programPath: path, intervalSeconds: 7200)

    check("reseal/plist-nonempty", !data.isEmpty, "serialised plist must not be empty")

    guard let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let dict = obj as? [String: Any] else {
        fail("reseal/plist-wellformed", "generated plist did not parse as a dictionary")
        return
    }
    pass("reseal/plist-wellformed")

    check("reseal/plist-label", dict["Label"] as? String == LaunchAgentPlist.resealLabel,
          "Label must equal the stable agent label")
    check("reseal/plist-runatload", dict["RunAtLoad"] as? Bool == true,
          "RunAtLoad must be true (runs at login)")
    check("reseal/plist-interval", dict["StartInterval"] as? Int == 7200,
          "StartInterval must carry the requested period")
    check("reseal/plist-background", dict["ProcessType"] as? String == "Background",
          "ProcessType must be Background")
    check("reseal/plist-program",
          (dict["ProgramArguments"] as? [String])?.first == path,
          "the program path (with spaces & ampersand) must round-trip exactly")
    check("reseal/plist-no-logsurface",
          dict["StandardOutPath"] as? String == "/dev/null"
            && dict["StandardErrorPath"] as? String == "/dev/null",
          "agent stdio must be discarded (no log surface)")

    // The default interval is a sane, frequent cadence (multiple times a day).
    check("reseal/default-interval-frequent",
          LaunchAgentPlist.defaultIntervalSeconds > 0
            && LaunchAgentPlist.defaultIntervalSeconds <= 6 * 3600,
          "default re-seal interval should fire several times a day")

    // ===== Window-end boundaries (StartCalendarInterval) =====

    func win(_ sh: Int, _ sm: Int, _ eh: Int, _ em: Int) -> DailyWindow {
        DailyWindow(start: TimeOfDay(hour: sh, minute: sm)!, end: TimeOfDay(hour: eh, minute: em)!)
    }

    // fireTimes advances each window-END by one minute (so the end round has
    // published and the vault is `expired` by the time the agent runs).
    check("reseal/firetimes-margin",
          LaunchAgentPlist.fireTimes(forWindowEnds: [win(4, 0, 5, 0)]) == [DailyFireTime(hour: 5, minute: 1)],
          "a window ending 05:00 ⇒ a single fire at 05:01 (+1min margin)")

    // Identical ends across windows/vaults collapse to one entry; result is sorted
    // (so the generated plist is byte-stable regardless of input order).
    check("reseal/firetimes-dedup-and-sort",
          LaunchAgentPlist.fireTimes(forWindowEnds: [win(16, 0, 17, 30), win(4, 0, 5, 0), win(3, 0, 5, 0)])
            == [DailyFireTime(hour: 5, minute: 1), DailyFireTime(hour: 17, minute: 31)],
          "identical ends collapse to one entry; result is sorted (05:01 before 17:31)")

    // A window ending at 23:59 wraps its +1min fire to 00:00 (next day).
    check("reseal/firetimes-midnight-wrap",
          LaunchAgentPlist.fireTimes(forWindowEnds: [win(23, 0, 23, 59)]) == [DailyFireTime(hour: 0, minute: 0)],
          "a window ending 23:59 ⇒ fire wraps to 00:00")

    // No windows ⇒ no calendar entries (the agent then relies on StartInterval alone).
    check("reseal/firetimes-empty",
          LaunchAgentPlist.fireTimes(forWindowEnds: []).isEmpty,
          "no windows ⇒ no calendar entries")

    // Empty calendarTimes ⇒ the plist is byte-identical to the interval-only form,
    // and carries NO StartCalendarInterval key (the no-regression contract).
    check("reseal/plist-empty-calendar-byte-identical",
          LaunchAgentPlist.reseal(programPath: path)
            == LaunchAgentPlist.reseal(programPath: path, calendarTimes: []),
          "explicit empty calendarTimes ⇒ byte-identical to the default (interval-only) plist")
    check("reseal/plist-calendar-absent-when-empty",
          dict["StartCalendarInterval"] == nil,
          "no calendar times ⇒ no StartCalendarInterval key")

    // Non-empty calendarTimes land in the plist as a sorted array of {Hour,Minute},
    // ALONGSIDE the periodic StartInterval (both triggers coexist).
    let calData = LaunchAgentPlist.reseal(
        programPath: path,
        calendarTimes: LaunchAgentPlist.fireTimes(forWindowEnds: [win(16, 0, 17, 30), win(4, 0, 5, 0)]))
    if let calObj = try? PropertyListSerialization.propertyList(from: calData, format: nil),
       let calDict = calObj as? [String: Any] {
        let cal = calDict["StartCalendarInterval"] as? [[String: Any]]
        check("reseal/plist-calendar-entries",
              cal?.count == 2
                && (cal?[0]["Hour"] as? Int) == 5 && (cal?[0]["Minute"] as? Int) == 1
                && (cal?[1]["Hour"] as? Int) == 17 && (cal?[1]["Minute"] as? Int) == 31,
              "StartCalendarInterval carries the window-end boundaries, sorted, +1min")
        check("reseal/plist-calendar-keeps-interval",
              calDict["StartInterval"] as? Int == LaunchAgentPlist.defaultIntervalSeconds,
              "the periodic StartInterval safety net remains alongside the boundaries")
    } else {
        fail("reseal/plist-calendar-entries", "plist with calendar times did not parse")
        fail("reseal/plist-calendar-keeps-interval", "plist with calendar times did not parse")
    }
}

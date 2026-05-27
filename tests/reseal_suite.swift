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
}

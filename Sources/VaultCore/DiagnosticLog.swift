// DiagnosticLog.swift — a SECRET-FREE diagnostics trail so the user can answer
// "why didn't the vault behave the way I expected?" (why is it locked / offline,
// did the background re-seal run, etc.). Written by both the app and the headless
// re-seal agent to a small, capped file in the vault directory; surfaced read-only
// by DiagnosticsView.
//
// SECURITY (SECURITY_INVARIANTS I13): I13 forbids any SECRET in a diagnostic file
// (password, derived key, PW01 plaintext, manifest, notes) — it does NOT forbid a
// diagnostic file. This type is secret-free BY CONSTRUCTION: the only way to write
// is `record(_ event: DiagnosticEvent)`, and `DiagnosticEvent` is a closed enum
// whose cases carry only non-secret fields — drand round numbers, a closed outcome
// kind, a hex hash (already the I6 "hash-only" quarantine record), and booleans.
// There is no `record(String)` / `record(Data)` sink, so user content / a password
// can never reach the log. A run_tests fence (`leak/diagnostics-typed`) asserts no
// content/secret type appears in this file's API.
//
// It writes the file directly — never through the print / NSLog / unified-logging
// family, which the leak/logging fence forbids in the engine. Best-effort: every
// failure is swallowed.

import Foundation

/// A closed set of loggable, NON-SECRET events. Fields are limited to round
/// numbers, a closed outcome kind, a hex digest, and booleans.
public enum DiagnosticEvent {
    /// The on-disk vault state a `VaultStore.load()` resolved to. Mirrors
    /// `VaultLoadResult` minus any payload, so nothing decrypted is carried.
    public enum LoadKind: String {
        case openWindow, locked, resealed, offline, failClosed
    }

    case appLaunched
    case agentRan(LoadKind)                 // the background re-seal agent's load() outcome
    case checkedVault(LoadKind, round: UInt64?)  // the app's load() outcome (+ verified round)
    case resealedForward(round: UInt64)     // a forward re-seal succeeded (target start round)
    case resealFailed                       // a re-seal/seal failed (offline / no window) — coarse
    case unlock(success: Bool)              // coarse on purpose (no password-vs-corrupt oracle)
    case quarantine(side: String, sha256Hex: String, reason: String)  // I6 hash-only record
    case agentRegistered(success: Bool)     // the LaunchAgent (re)install outcome
    case agentRemoved(success: Bool)        // the LaunchAgent uninstall (bootout + plist delete) outcome
}

/// Appends non-secret events to a small capped text file and reads them back.
/// Holds only a URL, so any layer (app or agent) can make one over the shared file.
public struct DiagnosticLog {
    public let url: URL
    /// Hard cap: the file is trimmed to its last `maxLines` on every write, so it
    /// can never grow without bound. Diagnostics, not an audit trail.
    public let maxLines: Int

    public init(url: URL, maxLines: Int = 200) {
        self.url = url
        self.maxLines = maxLines
    }

    /// Append one event (timestamped), then trim to the last `maxLines`. Atomic
    /// write so a concurrent app/agent writer can never corrupt the file (one
    /// writer wins; at worst a single line is dropped — acceptable for diagnostics).
    public func record(_ event: DiagnosticEvent, source: Source, now: Date = Date()) {
        let line = Self.format(event, source: source, at: now)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text += line + "\n"
        let kept = text.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(maxLines).joined(separator: "\n")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let bytes = (kept + "\n").data(using: .utf8) else { return }
        try? bytes.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The most recent lines, oldest first (for the viewer). Empty if no log yet.
    public func tail(maxLines limit: Int = 200) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(limit).map(String.init)
    }

    /// Erase the diagnostics file (non-secret content; safe to clear anytime).
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Merge several already-read, tagged log groups into ONE chronological list.
    /// Each group is `(tag, lines)` where `lines` is a log's `tail()` (oldest-first)
    /// and `tag` is a NON-SECRET source label (e.g. a vault's name, or "App"). Every
    /// line is prefixed `"[tag] "` and the whole set is ordered by the ISO-8601
    /// timestamp each line begins with — the formats are identical across logs, so
    /// lexical order is chronological. Ordering ALWAYS uses the raw (UTC) line;
    /// `displayIn`, when set, only re-renders each line's timestamp into that zone
    /// for the viewer (storage stays UTC, so the sort stays correct). Pure and
    /// secret-free (inputs are already secret-free lines + non-secret tags), so it
    /// lives in the engine and is unit-testable headless. Used by the app's merged
    /// activity-log view.
    public static func merge(_ groups: [(tag: String, lines: [String])],
                             displayIn tz: TimeZone? = nil) -> [String] {
        var tagged: [(key: String, decorated: String)] = []
        for group in groups {
            for line in group.lines {
                let shown = tz.map { localize(line, in: $0) } ?? line
                tagged.append((key: line, decorated: "[\(group.tag)] \(shown)"))
            }
        }
        return tagged.sorted { $0.key < $1.key }.map(\.decorated)
    }

    /// Which process emitted the line.
    public enum Source: String { case app, agent }

    // MARK: - Formatting (only non-secret tokens ever reach a line)

    static func format(_ event: DiagnosticEvent, source: Source, at now: Date) -> String {
        "\(iso.string(from: now)) [\(source.rawValue)] \(phrase(event))"
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func phrase(_ event: DiagnosticEvent) -> String {
        switch event {
        case .appLaunched:
            return "app launched"
        case .agentRan(let kind):
            return "background agent ran → \(describe(kind))"
        case .checkedVault(let kind, let round):
            return "checked vault → \(describe(kind))" + (round.map { " (round \($0))" } ?? "")
        case .resealedForward(let round):
            return "re-sealed forward to round \(round)"
        case .resealFailed:
            return "re-seal failed (offline or no window) — vault left unchanged"
        case .unlock(let ok):
            return ok ? "unlocked" : "unlock failed"
        case .quarantine(let side, let hash, let reason):
            return "quarantined \(side) copy: \(reason) (sha256 \(hash))"
        case .agentRegistered(let ok):
            return ok ? "re-seal agent (re)registered" : "re-seal agent registration skipped/failed"
        case .agentRemoved(let ok):
            return ok ? "re-seal agent removed (uninstall)" : "re-seal agent removal failed (uninstall)"
        }
    }

    private static func describe(_ kind: DiagnosticEvent.LoadKind) -> String {
        switch kind {
        case .openWindow: return "open window"
        case .locked:     return "locked"
        case .resealed:   return "re-sealed forward (was expired)"
        case .offline:    return "offline — could not reach the time-lock network"
        case .failClosed: return "fail-closed (no usable vault copy)"
        }
    }

    // MARK: - Display localisation (storage stays UTC; only the VIEWER converts)

    /// Re-render a log line's leading UTC ISO-8601 timestamp into `tz` for DISPLAY
    /// ONLY. Storage stays UTC — so `merge()` ordering and cross-log comparison stay
    /// stable and old lines keep parsing — while the viewer shows local wall-clock
    /// time, the zone's letters, and the original UTC time in parentheses, e.g.
    ///   `2026-05-30T12:34:56Z [app] …`  →  `2026-05-30 18:04:56 IST (12:34:56Z) [app] …`
    /// A line whose first token isn't a parseable timestamp is returned unchanged
    /// (graceful for blank/old/malformed lines). No secret is involved: the input is
    /// an already-written, secret-free line and the output only re-times it.
    public static func localize(_ line: String, in tz: TimeZone = .current) -> String {
        let parts = line.split(separator: " ", maxSplits: 1)
        guard let stamp = parts.first, let date = iso.date(from: String(stamp)) else { return line }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = tz
        local.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let rest = parts.count > 1 ? " " + String(parts[1]) : ""
        return "\(local.string(from: date)) \(zoneLetters(tz, at: date)) (\(utcTime.string(from: date)))\(rest)"
    }

    /// Short letters for `tz` at `date`: the OS abbreviation when it is alphabetic
    /// (PST, EST, JST…); otherwise — when the OS only has a numeric offset like
    /// "GMT+5:30" (true for India, Nepal, …) — the initials of the long English name
    /// (date-correct for DST), so "India Standard Time" → "IST" and the user sees real
    /// zone letters rather than a redundant offset next to the UTC value. Falls back to
    /// whatever the OS gave if no sensible initials exist.
    static func zoneLetters(_ tz: TimeZone, at date: Date) -> String {
        let osAbbr = tz.abbreviation(for: date) ?? ""
        if !osAbbr.isEmpty && osAbbr.allSatisfy(\.isLetter) { return osAbbr }
        let style: NSTimeZone.NameStyle = tz.isDaylightSavingTime(for: date) ? .daylightSaving : .standard
        let longName = tz.localizedName(for: style, locale: Locale(identifier: "en_US")) ?? osAbbr
        let initials = String(longName.split(separator: " ").compactMap(\.first).filter(\.isUppercase))
        return initials.count >= 2 ? initials : osAbbr
    }

    /// The original UTC wall-clock time, shown in parentheses beside the local time.
    private static let utcTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm:ss'Z'"
        return f
    }()
}

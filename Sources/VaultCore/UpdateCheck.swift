// UpdateCheck.swift — the PURE, non-networked core of the notify-only update
// check: compare the running app's version to a release tag, and parse the
// (non-secret) fields out of a GitHub "latest release" JSON body. Foundation-only
// and side-effect-free, so it is unit-tested headless exactly like the rest of
// VaultCore. The actual network fetch (URLSession) lives in the app layer
// (UpdateChecker.swift); nothing here touches the network, the disk, or a secret.
//
// SECURITY: the update check is NOTIFY-ONLY — it never downloads or runs anything.
// It reads a public version string + a release-page URL and decides "is there a
// newer version?", so the app can show a banner; the user updates manually. No
// code is fetched or executed, so this adds NO code-execution surface to the
// vault. The only inputs are a public version tag and a URL — never a secret.

import Foundation

/// A newer release the user could choose to install. Both fields are public,
/// non-secret metadata: the version string shown in the banner and the URL of the
/// release page opened in the browser. Carries no payload and no executable.
public struct AvailableUpdate: Equatable {
    /// Normalized version (no leading "v"), e.g. "1.5.0".
    public let version: String
    /// The GitHub release page (`html_url`) to open in the browser.
    public let releaseURL: URL

    public init(version: String, releaseURL: URL) {
        self.version = version
        self.releaseURL = releaseURL
    }
}

/// Pure version policy: dotted-numeric comparison and GitHub-release JSON parsing.
/// No I/O of any kind.
public enum UpdateCheck {

    /// True iff `remote` is strictly newer than `current`. Compares the leading run
    /// of dotted integer components, tolerating a leading "v"/"V" and ignoring any
    /// trailing pre-release suffix (`"1.5.0-beta" → [1,5,0]`). Missing trailing
    /// components count as 0, so `"1.5" == "1.5.0"`.
    public static func isNewer(remote: String, than current: String) -> Bool {
        let r = components(remote), c = components(current)
        for i in 0..<max(r.count, c.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Split a version/tag into its leading run of dotted integer components.
    /// `"v1.5.0-beta.2" → [1, 5, 0]`: a leading "v" is dropped and the parse stops
    /// at the first character that is neither a digit nor a dot, so a pre-release
    /// suffix neither crashes nor counts.
    static func components(_ raw: String) -> [Int] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let body = (trimmed.first == "v" || trimmed.first == "V") ? trimmed.dropFirst() : Substring(trimmed)
        let head = body.prefix { $0.isNumber || $0 == "." }
        return head.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// Parse the (non-secret) tag + release-page URL out of a GitHub
    /// `releases/latest` JSON body. Returns nil for a garbled/empty body or a
    /// missing field — the caller treats nil as "no usable update info" and stays
    /// silent. Pure JSON reading; no network, no secret.
    public static func parseLatestRelease(_ data: Data) -> (tag: String, url: URL)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String, !tag.isEmpty,
              let urlString = obj["html_url"] as? String,
              let url = URL(string: urlString)
        else { return nil }
        return (tag: tag, url: url)
    }

    /// One-call policy: parse a GitHub release body and, if its tag is newer than
    /// `current`, return the `AvailableUpdate` to surface (else nil = up to date /
    /// unusable). The version is normalized (no leading "v").
    public static func update(from data: Data, current: String) -> AvailableUpdate? {
        guard let (tag, url) = parseLatestRelease(data),
              isNewer(remote: tag, than: current) else { return nil }
        let version = (tag.first == "v" || tag.first == "V") ? String(tag.dropFirst()) : tag
        return AvailableUpdate(version: version, releaseURL: url)
    }
}

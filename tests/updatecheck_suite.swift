// updatecheck_suite.swift — tests for the PURE, non-networked update policy in
// VaultCore (UpdateCheck): the dotted-numeric version comparison and the GitHub
// "latest release" JSON parsing. The live network fetch (UpdateChecker.swift) and
// the AppModel/banner wiring are GUI/Foundation app-layer code covered by the
// ui/typecheck gate and a manual run; here we pin the off-by-one-prone math and
// the parse, which are exactly the bits a bug would silently break.

import Foundation

func runUpdateCheckSuite() {
    versionCompareTests()
    releaseParseTests()
    updatePolicyTests()
}

// MARK: - isNewer (dotted-numeric comparison)

private func versionCompareTests() {
    // Strictly newer in each position.
    check("update/newer-patch", UpdateCheck.isNewer(remote: "1.4.3", than: "1.4.2"))
    check("update/newer-minor", UpdateCheck.isNewer(remote: "1.5.0", than: "1.4.9"))
    check("update/newer-major", UpdateCheck.isNewer(remote: "2.0.0", than: "1.9.9"))

    // Equal is NOT newer (no banner when already current).
    check("update/equal-not-newer", !UpdateCheck.isNewer(remote: "1.4.2", than: "1.4.2"))

    // Older remote (a downgrade) is never offered.
    check("update/older-not-newer", !UpdateCheck.isNewer(remote: "1.4.1", than: "1.4.2"))
    check("update/older-major-not-newer", !UpdateCheck.isNewer(remote: "1.9.9", than: "2.0.0"))

    // A leading "v" on either side is tolerated.
    check("update/v-prefix-remote", UpdateCheck.isNewer(remote: "v1.5.0", than: "1.4.2"))
    check("update/v-prefix-both", UpdateCheck.isNewer(remote: "v1.5.0", than: "v1.5.0") == false)

    // Missing trailing components count as 0, so "1.5" == "1.5.0".
    check("update/short-equals-padded", !UpdateCheck.isNewer(remote: "1.5", than: "1.5.0"))
    check("update/short-newer", UpdateCheck.isNewer(remote: "1.6", than: "1.5.9"))

    // A pre-release suffix is ignored (parsed to its numeric head), so a
    // "-beta" tag of the SAME numbers is not treated as newer.
    check("update/prerelease-ignored", !UpdateCheck.isNewer(remote: "1.4.2-beta.1", than: "1.4.2"))
    check("update/prerelease-numeric-head", UpdateCheck.isNewer(remote: "1.5.0-rc1", than: "1.4.2"))

    // Double-digit components compare numerically, not lexically (10 > 9).
    check("update/numeric-not-lexical", UpdateCheck.isNewer(remote: "1.10.0", than: "1.9.0"))
}

// MARK: - parseLatestRelease (GitHub JSON)

private func releaseParseTests() {
    let good = Data("""
    {"tag_name":"v1.5.0","html_url":"https://github.com/owner/repo/releases/tag/v1.5.0","name":"1.5.0"}
    """.utf8)
    if let (tag, url) = UpdateCheck.parseLatestRelease(good) {
        check("update/parse-tag", tag == "v1.5.0", "got \(tag)")
        check("update/parse-url", url.absoluteString == "https://github.com/owner/repo/releases/tag/v1.5.0")
    } else {
        fail("update/parse-good", "expected a parsed release, got nil")
    }

    // Missing tag_name → nil (can't decide a version).
    check("update/parse-no-tag",
          UpdateCheck.parseLatestRelease(Data(#"{"html_url":"https://x/y"}"#.utf8)) == nil)
    // Missing html_url → nil (nowhere to send the user).
    check("update/parse-no-url",
          UpdateCheck.parseLatestRelease(Data(#"{"tag_name":"v1.5.0"}"#.utf8)) == nil)
    // Empty tag → nil.
    check("update/parse-empty-tag",
          UpdateCheck.parseLatestRelease(Data(#"{"tag_name":"","html_url":"https://x/y"}"#.utf8)) == nil)
    // Not JSON / not an object → nil, never a crash (a 404 body, an HTML error page).
    check("update/parse-garbage", UpdateCheck.parseLatestRelease(Data("Not Found".utf8)) == nil)
    check("update/parse-empty", UpdateCheck.parseLatestRelease(Data()) == nil)
}

// MARK: - update(from:current:) end-to-end policy

private func updatePolicyTests() {
    let body = Data("""
    {"tag_name":"v1.5.0","html_url":"https://github.com/owner/repo/releases/tag/v1.5.0"}
    """.utf8)

    // Newer → an AvailableUpdate with the "v" stripped from the displayed version.
    if let u = UpdateCheck.update(from: body, current: "1.4.2") {
        check("update/policy-version-normalized", u.version == "1.5.0", "got \(u.version)")
        check("update/policy-url", u.releaseURL.absoluteString.hasSuffix("/v1.5.0"))
    } else {
        fail("update/policy-newer", "expected an update, got nil")
    }

    // Same version → nil (no banner).
    check("update/policy-same-nil", UpdateCheck.update(from: body, current: "1.5.0") == nil)
    // Current is ahead of the latest release → nil.
    check("update/policy-ahead-nil", UpdateCheck.update(from: body, current: "1.6.0") == nil)
    // Garbage body → nil (fail silent).
    check("update/policy-garbage-nil", UpdateCheck.update(from: Data("nope".utf8), current: "1.4.2") == nil)
}

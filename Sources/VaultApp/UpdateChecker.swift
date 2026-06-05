// UpdateChecker.swift — the LIVE, networked half of the notify-only update check.
// It performs ONE outbound request — a plain GET to the PUBLIC GitHub
// "latest release" endpoint — and hands the body to the pure policy in VaultCore
// (UpdateCheck). This is the app's ONLY direct network call; everything
// crypto/drand-related runs inside the bundled Go helper, never here.
//
// Notify-only: it learns "a newer version exists" + the release-page URL so the
// app can show a banner. It NEVER downloads or runs an update — no code-execution
// surface is added; the user updates manually. Foundation-only (no AppKit/SwiftUI)
// so it does not drag the headless test binary into the GUI frameworks. NO token
// is embedded: the endpoint is public + read-only, and a shipped token would
// itself be a leak. Against a still-PRIVATE repo the endpoint returns 404, which
// this treats as "no update" — so the feature is simply dormant until the repo is
// public.

import Foundation

/// Abstracts the network fetch so AppModel can be unit-tested with a stub (the
/// live implementation hits GitHub; a test injects a canned result), mirroring the
/// self-test services injection in FirstRunModel.
protocol UpdateChecking {
    /// Fetch the latest release and compare to `currentVersion`, calling back with
    /// the update to surface (nil = up to date / unreachable / private). The
    /// callback may arrive on any queue; callers marshal to main.
    func check(currentVersion: String, completion: @escaping (AvailableUpdate?) -> Void)
}

/// The shipped checker: GETs the public GitHub latest-release endpoint for the
/// HeldByTime repo and applies the pure VaultCore policy. Fails SILENT on any
/// problem (offline, rate-limited, private repo → 404, garbled body): the user
/// simply sees no banner. Never throws into the UI.
struct LiveUpdateChecker: UpdateChecking {
    /// The PUBLIC repository the releases come from. This is the GitHub handle
    /// already shown in the README badge + Releases link — not a personal name —
    /// and the only identifying string the check carries. Rename here if the GitHub
    /// account is ever renamed.
    static let repository = "shivam13juna/HeldByTime"

    private var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
    }

    func check(currentVersion: String, completion: @escaping (AvailableUpdate?) -> Void) {
        var request = URLRequest(url: latestReleaseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        // GitHub rejects API requests without a User-Agent; use a generic,
        // non-identifying one (no version, no machine info).
        request.setValue("HeldByTime-update-check", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data = data else { completion(nil); return }
            completion(UpdateCheck.update(from: data, current: currentVersion))
        }.resume()
    }
}

/// The running app's marketing version — `CFBundleShortVersionString`, which
/// build.sh stamps from the root VERSION file. Falls back to "0" so a non-bundled
/// dev build simply treats any release as newer.
enum AppVersion {
    static var current: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }
}

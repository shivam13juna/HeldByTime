// VaultApp.swift — the SwiftUI app shell (@main). Routes the AppModel's phase to
// the right screen and seals the vault on a graceful quit (Cmd-Q / menu Quit) via
// the AppKit application delegate — one of app.md §2's four re-seal triggers. The
// window is fixed-size and single; there is no document model and no
// recent-documents (NSDocument architecture is never used), so nothing populates
// a recents list or autosaves a document.
//
// Task 10 (no durable plaintext, app.md §9 / I13): the delegate disables Saved
// Application State / window restoration (which can persist editor contents
// across launches) and process core dumps at the earliest launch hook.

import SwiftUI
import AppKit

@main
struct VaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup(Self.windowTitle) {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 700, minHeight: 600)
                .onAppear {
                    appDelegate.model = model
                    model.bootstrap()
                }
        }
        .windowResizability(.contentSize)
        // No "New Window" — a single vault window, no document surface.
        .commands { CommandGroup(replacing: .newItem) {} }
    }

    /// Title-bar text: the product name plus the running version
    /// (`CFBundleShortVersionString`, stamped from the root VERSION file by
    /// build.sh), e.g. "HeldByTime 1.4.3". Shown so the owner can read their
    /// installed version at a glance — and match it against the update banner.
    /// A non-literal `String` binds the `StringProtocol` WindowGroup initializer
    /// (a plain title), not the LocalizedStringKey one.
    private static var windowTitle: String { "HeldByTime \(AppVersion.current)" }
}

/// Seals on graceful termination. `applicationShouldTerminate` re-seals an open
/// session before the process exits; if nothing is open it terminates at once.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    /// Earliest launch hook: kill the durable-plaintext leak surfaces before any
    /// secret can exist in memory (app.md §9 / I13).
    func applicationWillFinishLaunching(_ notification: Notification) {
        ProcessHardening.disableCoreDumps()
        // Disable Saved Application State / window restoration — it can persist
        // editor contents to ~/Library/Saved Application State across launches.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders: mark every window non-restorable too.
        for window in NSApplication.shared.windows { window.isRestorable = false }
        // Wake-from-sleep is the one window-end trigger the in-app timer can miss (a
        // laptop asleep past the window never ticked), so re-check the open vault on
        // wake. AppKit-only API, so it lives here, not in the headless VaultModel.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// We never participate in state restoration, so report no support (and the
    /// windows above are non-restorable regardless).
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    /// On app-activation and on wake, immediately re-check the open vault's window —
    /// forwarded into the model layer (which can't observe these AppKit events).
    func applicationDidBecomeActive(_ notification: Notification) {
        model?.recheckOpenVaultWindow()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        model?.recheckOpenVaultWindow()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        return model.sealForQuit() ? .terminateNow : .terminateCancel
    }

    // Closing the last window quits (and so re-seals through the path above).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Switches on the app-level screen. Each case is a small dedicated view. A
/// selected vault gets its own VaultModel injected into the environment so its
/// subtree (locked / unlock / editor) observes that one vault.
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        screenView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // One place applies the user's light/dark choice to the whole app.
            .preferredColorScheme(model.uiPrefs.appearance.colorScheme)
    }

    @ViewBuilder
    private var screenView: some View {
        switch model.screen {
        case .launching:
            ProgressView("Loading…").padding()
        case .list:
            VaultListView()
        case .creating(let setup):
            FirstRunView(setup: setup)
        case .open(let vault):
            VaultRootView(vault: vault).environmentObject(vault)
        case .failed(let message):
            FailedView(message: message, log: model.appLog)
        }
    }
}

/// One selected vault. Switches on the vault's own phase; for every sealed state
/// it floats a back-to-list control (the open editor carries its own navigation).
struct VaultRootView: View {
    @ObservedObject var vault: VaultModel
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // A dedicated header row for the back control on every sealed state, so
            // it can never overlap the centered lock card. The open editor draws its
            // own "Vaults" header, so we add nothing above it.
            if !isUnlocked {
                HStack {
                    backButton
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
            phaseView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch vault.phase {
        case .loading:
            ProgressView("Loading your vault…").padding()
        case .locked(let info):
            LockedView(info: info)
        case .unlockPrompt:
            UnlockView()
        case .unlocked:
            NotesEditorView()
        case .failed(let message):
            FailedView(message: message, log: vault.diagnosticsLog)
        }
    }

    /// Shown for every state except the open editor (which has its own header
    /// with a "Vaults" button). Leaving an open editor seals first (closeCurrent).
    private var backButton: some View {
        Button { app.closeCurrent() } label: {
            Label("All vaults", systemImage: "chevron.left")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var isUnlocked: Bool {
        if case .unlocked = vault.phase { return true }
        return false
    }
}

/// A terminal error screen (wiring/contents unrecoverable). No retry that could
/// loop. Offers no access path; just the log and Quit. The log to show is passed
/// in (a vault's own log, or the app-level log at the top level).
struct FailedView: View {
    let message: String
    let log: DiagnosticLog
    @State private var showLog = false
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.octagon").font(.largeTitle)
            Text("Vault unavailable").font(.title2).bold()
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack {
                Button("View log") { showLog = true }
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .sheet(isPresented: $showLog) { DiagnosticsView(log: log) }
    }
}

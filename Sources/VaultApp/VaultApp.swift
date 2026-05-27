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
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 460, minHeight: 420)
                .onAppear {
                    appDelegate.model = model
                    model.bootstrap()
                }
        }
        .windowResizability(.contentSize)
        // No "New Window" — a single vault window, no document surface.
        .commands { CommandGroup(replacing: .newItem) {} }
    }
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
    }

    /// We never participate in state restoration, so report no support (and the
    /// windows above are non-restorable regardless).
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        return model.sealForQuit() ? .terminateNow : .terminateCancel
    }

    // Closing the last window quits (and so re-seals through the path above).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Switches on the model phase. Each case is a small dedicated view.
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        phaseView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // One place applies the user's light/dark choice to the whole app.
            .preferredColorScheme(model.uiPrefs.appearance.colorScheme)
    }

    @ViewBuilder
    private var phaseView: some View {
        switch model.phase {
        case .launching, .loading:
            ProgressView("Checking the time-lock…").padding()
        case .firstRun(let setup):
            FirstRunView(setup: setup)
        case .locked(let info):
            LockedView(info: info)
        case .unlockPrompt:
            UnlockView()
        case .unlocked:
            NotesEditorView()
        case .failed(let message):
            FailedView(message: message)
        }
    }
}

/// A terminal error screen (wiring/contents unrecoverable). No retry that could
/// loop; the user must quit. Deliberately blunt and offers no access path.
struct FailedView: View {
    let message: String
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
        .sheet(isPresented: $showLog) { DiagnosticsView() }
    }
}

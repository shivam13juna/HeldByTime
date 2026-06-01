// FirstRunModel.swift — the observable state machine behind the first-run setup
// UI (FirstRunView.swift). It collects the password (×2, exact-byte confirmed),
// the initial secrets, the daily windows, the data-loss acknowledgment, and runs
// the on-device self-test gate — refusing to create the vault until the gate is
// satisfied (or its warnings are explicitly confirmed). No real secret touches
// disk until create() succeeds (the engine enforces this; this only collects).
//
// Split out of FirstRunView.swift so it stays Foundation/Combine-only (no
// SwiftUI): that lets AppModel — which holds a FirstRunModel in its `.creating`
// screen — compile and be unit-tested in the offline, headless test binary,
// exactly like the engine. The SwiftUI view that observes this model is still in
// FirstRunView.swift; nothing about the live behaviour changes.

import Foundation
import Combine

/// Drives the setup flow. All policy lives in FirstRunSetup/SelfTestEngine; this
/// only marshals input and surfaces results.
final class FirstRunModel: ObservableObject {
    @Published var password = ""
    @Published var confirmPassword = ""
    @Published var content = VaultContent.initialTemplate
    @Published var prefs = SchedulePrefs.default
    @Published var acknowledgeDataLoss = false

    @Published var selfTest: [SelfTestEngine.StepResult] = []
    /// The networked operation in flight (nil = idle). Drives a centered modal so
    /// the user can't miss that the app is working — and so the message matches
    /// what they pressed (Create vs Run self-test), not a generic "self-test" line.
    @Published var activity: Activity?
    @Published var errorMessage: String?

    enum Activity { case selfTest, creating }

    /// True while any networked operation is running (buttons disable on this).
    var running: Bool { activity != nil }

    /// Title/subtitle for the working popup, matching the pressed action.
    var activityTitle: String {
        switch activity {
        case .creating: return "Creating your vault…"
        case .selfTest: return "Running self-test…"
        case nil:       return ""
        }
    }
    var activitySubtitle: String {
        switch activity {
        case .creating: return "Setting up encryption and connecting to the time-lock "
            + "network. This can take up to 30 seconds."
        case .selfTest: return "Making sure encryption works and the time-lock network "
            + "is reachable."
        case nil:       return ""
        }
    }
    /// Set when the gate passed but with warnings; the view asks to confirm.
    @Published var pendingWarnings: [SelfTestEngine.Step]?
    /// Set when the owner pressed Create with a weak (advisory) password; the view
    /// asks to confirm "create anyway". Never blocks — strength is the owner's call.
    @Published var pendingWeakPassword = false

    private let config: AppConfiguration
    private let onComplete: () -> Void
    private let onCancel: () -> Void

    init(config: AppConfiguration,
         onComplete: @escaping () -> Void,
         onCancel: @escaping () -> Void = {}) {
        self.config = config
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    /// Abandon setup before any vault.dat is sealed (the coordinator removes the
    /// empty allocated directory).
    func cancel() { onCancel() }

    /// Live, advisory weakness hint (does not block).
    var weaknessWarning: String? {
        password.isEmpty ? nil : PasswordPolicy.weaknessWarning(password)
    }

    var passwordsMatch: Bool { PasswordPolicy.confirms(password, confirmPassword) }

    private func makeStore() -> VaultStore {
        let runner = HelperRunner(executableURL: config.helperURL,
                                  expectedSHA256: config.compiledHelperSHA256)
        let client = VaultSealClient(runner: runner)
        return VaultStore(dir: config.vaultDir, client: client, schedule: prefs.schedule)
    }

    private func makeSetup() -> FirstRunSetup {
        let runner = HelperRunner(executableURL: config.helperURL,
                                  expectedSHA256: config.compiledHelperSHA256)
        let services = LiveSelfTestServices(client: VaultSealClient(runner: runner))
        return FirstRunSetup(store: makeStore(), services: services)
    }

    /// Run only the self-test gate (no vault write) so the user can see the
    /// per-step report before committing a password.
    func runSelfTest() {
        guard !running else { return }
        activity = .selfTest
        errorMessage = nil
        // The self-test reaches drand over the network; run it off the main thread
        // so the popup actually animates instead of freezing the window.
        let setup = makeSetup()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = setup.runSelfTest()
            DispatchQueue.main.async {
                self.activity = nil
                switch result {
                case .success(let results): self.selfTest = results
                case .failure(let e): self.errorMessage = self.describe(e)
                }
            }
        }
    }

    /// Attempt to create the vault. `confirmWarnings` is passed through to the
    /// engine; when it returns `.warningsNotConfirmed` we stash the steps so the
    /// view can ask, then call again with `confirmWarnings: true`.
    func create(confirmWarnings: Bool = false, confirmWeak: Bool = false) {
        // Advisory weak-password confirm (NEVER blocks): if the password is weak and
        // the owner hasn't yet confirmed, ask once. We check before the (networked)
        // self-test so the prompt is immediate. Passing confirmWeak through the
        // self-test "create anyway" path keeps this from re-firing on that retry.
        if !confirmWeak, weaknessWarning != nil {
            pendingWeakPassword = true
            return
        }
        guard !running else { return }

        let notes: [UInt8]
        do { notes = try content.encode() }
        catch { errorMessage = "The initial notes are too large."; return }

        activity = .creating
        errorMessage = nil

        // Creation runs the self-test AND seals the first window — both networked —
        // so it runs off the main thread; the popup drives feedback and the result
        // is applied on main. No secret reaches disk unless create succeeds.
        let setup = makeSetup()
        let pw = password, cpw = confirmPassword, ack = acknowledgeDataLoss
        DispatchQueue.global(qos: .userInitiated).async {
            let result = setup.create(
                password: pw,
                confirmPassword: cpw,
                initialNotes: notes,
                acknowledgeDataLossWarnings: ack,
                confirmWarnings: confirmWarnings)
            DispatchQueue.main.async {
                self.activity = nil
                switch result {
                case .success(let report):
                    self.selfTest = report.selfTest
                    try? self.prefs.save(to: self.config.schedulePrefsURL)   // remember the windows
                    self.onComplete()                                        // → AppModel.open()
                case .failure(.warningsNotConfirmed(let steps)):
                    self.pendingWarnings = steps                             // view asks to confirm
                case .failure(let e):
                    self.errorMessage = self.describe(e)
                }
            }
        }
    }

    private func describe(_ e: FirstRunSetup.SetupError) -> String {
        switch e {
        case .password(.empty):            return "Enter a password."
        case .password(.tooLong):          return "Password is too long."
        case .passwordMismatch:            return "The two passwords don't match exactly."
        case .dataLossNotAcknowledged:     return "Please acknowledge the data-loss warning."
        case .selfTestBlocked(let steps):  return "Self-test failed: \(steps.map(\.rawValue).joined(separator: ", ")). The vault was not created."
        case .warningsNotConfirmed:        return "Self-test has warnings."
        case .schedule:                    return "No valid window could be scheduled. Check your windows."
        case .helper:                      return "Couldn't reach the time-lock network to set the first window."
        case .store:                       return "Could not write the vault file."
        case .io(let m):                   return "Setup error: \(m)"
        }
    }
}

// FirstRunView.swift — Task 9: the first-run setup UI driving FirstRunSetup
// (Task 8). It collects the password (×2, exact-byte confirmed), the initial
// secrets, the daily windows, the data-loss acknowledgment, and runs the
// on-device self-test gate — refusing to create the vault until the gate is
// satisfied (or its warnings are explicitly confirmed). No real secret touches
// disk until create() succeeds (the engine enforces this; the UI just collects).

import SwiftUI

/// Drives the setup flow. All policy lives in FirstRunSetup/SelfTestEngine; this
/// only marshals input and surfaces results.
final class FirstRunModel: ObservableObject {
    @Published var password = ""
    @Published var confirmPassword = ""
    @Published var content = VaultContent.initialTemplate
    @Published var prefs = SchedulePrefs.default
    @Published var acknowledgeDataLoss = false

    @Published var selfTest: [SelfTestEngine.StepResult] = []
    @Published var running = false
    @Published var errorMessage: String?
    /// Set when the gate passed but with warnings; the view asks to confirm.
    @Published var pendingWarnings: [SelfTestEngine.Step]?

    private let config: AppConfiguration
    private let onComplete: () -> Void

    init(config: AppConfiguration, onComplete: @escaping () -> Void) {
        self.config = config
        self.onComplete = onComplete
    }

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
        running = true
        errorMessage = nil
        defer { running = false }
        switch makeSetup().runSelfTest() {
        case .success(let results): selfTest = results
        case .failure(let e): errorMessage = describe(e)
        }
    }

    /// Attempt to create the vault. `confirmWarnings` is passed through to the
    /// engine; when it returns `.warningsNotConfirmed` we stash the steps so the
    /// view can ask, then call again with `confirmWarnings: true`.
    func create(confirmWarnings: Bool = false) {
        running = true
        errorMessage = nil
        defer { running = false }

        let notes: [UInt8]
        do { notes = try content.encode() }
        catch { errorMessage = "The initial notes are too large."; return }

        let result = makeSetup().create(
            password: password,
            confirmPassword: confirmPassword,
            initialNotes: notes,
            acknowledgeDataLossWarnings: acknowledgeDataLoss,
            confirmWarnings: confirmWarnings)

        switch result {
        case .success(let report):
            selfTest = report.selfTest
            try? prefs.save(to: config.schedulePrefsURL)   // remember the windows
            onComplete()                                   // → AppModel.reload()
        case .failure(.warningsNotConfirmed(let steps)):
            pendingWarnings = steps                        // view asks to confirm
        case .failure(let e):
            errorMessage = describe(e)
        }
    }

    private func describe(_ e: FirstRunSetup.SetupError) -> String {
        switch e {
        case .password(.empty):            return "Enter a password."
        case .password(.tooShort(let n)):  return "Password is too short (\(n) characters; need at least \(VaultConstants.MIN_PASSWORD_LENGTH))."
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

struct FirstRunView: View {
    @ObservedObject var setup: FirstRunModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Set up your vault").font(.largeTitle).bold()

                passwordSection
                secretsSection
                windowsSection
                dataLossSection
                selfTestSection

                if let err = setup.errorMessage {
                    Text(err).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("Run self-test") { setup.runSelfTest() }
                        .disabled(setup.running)
                    Button("Create vault") { setup.create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(setup.running || !canCreate)
                }
            }
            .padding(28)
            .frame(maxWidth: 560)
        }
        .alert("Proceed despite warnings?", isPresented: warningAlertBinding) {
            Button("Cancel", role: .cancel) { setup.pendingWarnings = nil }
            Button("Create anyway") {
                setup.pendingWarnings = nil
                setup.create(confirmWarnings: true)
            }
        } message: {
            Text("The self-test passed but with warnings: "
                 + (setup.pendingWarnings?.map(\.rawValue).joined(separator: ", ") ?? "")
                 + ". A single reachable drand endpoint is fragile — if it is later blocked, "
                 + "the vault will not open.")
        }
    }

    private var canCreate: Bool {
        !setup.password.isEmpty && setup.passwordsMatch && setup.acknowledgeDataLoss
    }

    private var warningAlertBinding: Binding<Bool> {
        Binding(get: { setup.pendingWarnings != nil },
                set: { if !$0 { setup.pendingWarnings = nil } })
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Vault password").font(.title3).bold()
            RevealableSecureField(placeholder: "Password", text: $setup.password)
            RevealableSecureField(placeholder: "Confirm password", text: $setup.confirmPassword)
            if !setup.confirmPassword.isEmpty && !setup.passwordsMatch {
                Text("Passwords don't match.").font(.caption).foregroundStyle(.red)
            }
            if let weak = setup.weaknessWarning {
                Text(weak).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var secretsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Initial secrets").font(.title3).bold()
            Text("Label each secret and paste its value, or leave them blank and "
                 + "add more later. You can add as many as you want.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($setup.content.secrets) { $secret in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        TextField("Label (e.g. macOS admin password)", text: $secret.label)
                            .textFieldStyle(.plain).font(.callout).foregroundStyle(.secondary)
                            .autocorrectionDisabled()
                        Spacer()
                        Button(role: .destructive) {
                            setup.content.secrets.removeAll { $0.id == secret.id }
                        } label: { Image(systemName: "trash") }
                            .help("Remove this secret")
                    }
                    RevealableSecureField(placeholder: "value", text: $secret.value)
                }
            }
            Button {
                setup.content.secrets.append(VaultSecret(label: ""))
            } label: { Label("Add secret", systemImage: "plus") }
        }
    }

    private var windowsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily windows").font(.title3).bold()
            ForEach($setup.prefs.windows) { $w in
                WindowEditorRow(window: $w) {
                    setup.prefs.windows.removeAll { $0.id == w.id }
                }
            }
            Button {
                setup.prefs.windows.append(WindowPrefs(startHour: 4, startMinute: 0, endHour: 5, endMinute: 0))
            } label: { Label("Add window", systemImage: "plus") }
        }
    }

    private var dataLossSection: some View {
        Toggle(isOn: $setup.acknowledgeDataLoss) {
            Text("I understand: if I forget this password the vault's contents are lost "
                 + "forever, and the vault must not be placed in Time Machine, an "
                 + "iCloud/Dropbox folder, or any synced location, or it can become "
                 + "openable out of window.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selfTestSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if setup.running { ProgressView("Running on-device self-test…") }
            if !setup.selfTest.isEmpty {
                Text("Self-test").font(.title3).bold()
                ForEach(setup.selfTest, id: \.step) { r in
                    HStack(spacing: 8) {
                        Image(systemName: symbol(r.outcome)).foregroundStyle(color(r.outcome))
                        Text(r.step.rawValue).bold()
                        Text(r.detail).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
            }
        }
    }

    private func symbol(_ o: SelfTestEngine.Outcome) -> String {
        switch o { case .pass: "checkmark.circle.fill"; case .warn: "exclamationmark.triangle.fill"; case .fail: "xmark.octagon.fill" }
    }
    private func color(_ o: SelfTestEngine.Outcome) -> Color {
        switch o { case .pass: .green; case .warn: .orange; case .fail: .red }
    }
}

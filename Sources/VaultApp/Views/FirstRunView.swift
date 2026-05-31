// FirstRunView.swift — Task 9: the first-run setup UI driving FirstRunSetup
// (Task 8). It collects the password (×2, exact-byte confirmed), the initial
// secrets, the daily windows, the data-loss acknowledgment, and runs the
// on-device self-test gate — refusing to create the vault until the gate is
// satisfied (or its warnings are explicitly confirmed). No real secret touches
// disk until create() succeeds (the engine enforces this; the UI just collects).

import SwiftUI

struct FirstRunView: View {
    @ObservedObject var setup: FirstRunModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Set up your vault").font(.largeTitle).bold()
                        Text("A time-locked vault — it can only be opened inside a daily window.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { setup.cancel() } label: {
                        Label("Cancel", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .disabled(setup.running)
                }
                .padding(.bottom, 4)

                passwordSection
                secretsSection
                windowsSection
                dataLossSection
                selfTestSection

                if let err = setup.errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    Button("Run self-test") { setup.runSelfTest() }
                        .controlSize(.large)
                        .disabled(setup.running)
                    Button("Create vault") { setup.create() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(setup.running || !canCreate)
                }
                .padding(.top, 4)
            }
            .padding(VaultUI.screenPadding)
            .frame(maxWidth: 580)
        }
        .overlay { if setup.running { activityOverlay } }
        .alert("Proceed despite warnings?", isPresented: warningAlertBinding) {
            Button("Cancel", role: .cancel) { setup.pendingWarnings = nil }
            Button("Create anyway") {
                setup.pendingWarnings = nil
                setup.create(confirmWarnings: true, confirmWeak: true)
            }
        } message: {
            Text("The self-test passed but with warnings: "
                 + (setup.pendingWarnings?.map(\.rawValue).joined(separator: ", ") ?? "")
                 + ". A single reachable drand endpoint is fragile — if it is later blocked, "
                 + "the vault will not open.")
        }
        .alert("Create with a weak password?", isPresented: weakPasswordAlertBinding) {
            Button("Cancel", role: .cancel) { setup.pendingWeakPassword = false }
            Button("Create anyway") {
                setup.pendingWeakPassword = false
                setup.create(confirmWeak: true)
            }
        } message: {
            Text((setup.weaknessWarning ?? "This password is weak.")
                 + "\n\nYou can use it anyway — but if you forget it there is no recovery, "
                 + "and once a window expires this password is all that protects the vault.")
        }
    }

    private var canCreate: Bool {
        !setup.password.isEmpty && setup.passwordsMatch && setup.acknowledgeDataLoss
            && !setup.prefs.windows.isEmpty   // a time-lock vault must seal to a window
    }

    private var warningAlertBinding: Binding<Bool> {
        Binding(get: { setup.pendingWarnings != nil },
                set: { if !$0 { setup.pendingWarnings = nil } })
    }

    private var weakPasswordAlertBinding: Binding<Bool> {
        Binding(get: { setup.pendingWeakPassword },
                set: { if !$0 { setup.pendingWeakPassword = false } })
    }

    private var passwordSection: some View {
        SectionCard(title: "Vault password", systemImage: "lock.fill") {
            VStack(alignment: .leading, spacing: 8) {
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
    }

    private var secretsSection: some View {
        SectionCard(title: "Initial secrets", systemImage: "key.fill",
                    subtitle: "Label each secret and paste its value, or leave them blank and "
                        + "add more later. You can add as many as you want.") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach($setup.content.secrets) { $secret in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Label (e.g. macOS admin password)", text: $secret.label)
                                .textFieldStyle(.plain).font(.callout.weight(.medium))
                                .autocorrectionDisabled()
                            Spacer()
                            Button(role: .destructive) {
                                setup.content.secrets.removeAll { $0.id == secret.id }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Remove this secret")
                        }
                        RevealableSecureField(placeholder: "value", text: $secret.value)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                }
                Button {
                    setup.content.secrets.append(VaultSecret(label: ""))
                } label: { Label("Add secret", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var windowsSection: some View {
        SectionCard(title: "Daily windows", systemImage: "clock.fill",
                    subtitle: "The vault time-locks to a window and can only be opened inside one. "
                        + "At least one window is required — there is no always-open mode.") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach($setup.prefs.windows) { $w in
                    WindowEditorRow(window: $w) {
                        setup.prefs.windows.removeAll { $0.id == w.id }
                    }
                }
                if setup.prefs.windows.isEmpty {
                    Text("Add at least one window to create the vault.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button {
                    setup.prefs.windows.append(WindowPrefs(startHour: 4, startMinute: 0, endHour: 5, endMinute: 0))
                } label: { Label("Add window", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
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
        .glassCard(padding: 16)
    }

    /// A centered, blocking popup shown while a networked operation runs — placed
    /// over the whole form so it can't be missed (the old inline spinner sat in the
    /// bottom-left of the scroll view). Its text matches the pressed action.
    private var activityOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(setup.activityTitle).font(.headline)
                Text(setup.activitySubtitle)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: 320)
            .glassCard()
        }
    }

    @ViewBuilder
    private var selfTestSection: some View {
        if !setup.selfTest.isEmpty {
            SectionCard(title: "Self-test", systemImage: "checkmark.shield.fill") {
                VStack(alignment: .leading, spacing: 6) {
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
    }

    private func symbol(_ o: SelfTestEngine.Outcome) -> String {
        switch o { case .pass: "checkmark.circle.fill"; case .warn: "exclamationmark.triangle.fill"; case .fail: "xmark.octagon.fill" }
    }
    private func color(_ o: SelfTestEngine.Outcome) -> Color {
        switch o { case .pass: .green; case .warn: .orange; case .fail: .red }
    }
}

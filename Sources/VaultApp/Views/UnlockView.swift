// UnlockView.swift — Task 9: the password prompt, reachable ONLY when
// VaultStore.load() returned `.openWindow` (the AppModel routes here for nothing
// else). A wrong password fails closed in VaultSession with no partial content;
// the view shows a single generic message and never hints whether the password
// or the file was at fault.

import SwiftUI

struct UnlockView: View {
    @EnvironmentObject private var vault: VaultModel
    @State private var password = ""

    var body: some View {
        VStack(spacing: 16) {
            GlyphBadge(systemImage: "lock.open.fill", tint: .green)
            Text("Window open").font(.title2).bold()
            Text("Enter your vault password to unlock.")
                .font(.callout)
                .foregroundStyle(.secondary)

            RevealableSecureField(placeholder: "Vault password", text: $password, onSubmit: submit)
                .frame(maxWidth: 300)
                .padding(.top, 4)

            if let err = vault.unlockError {
                Text(err).font(.callout).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button("Unlock", action: submit)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(password.isEmpty)
                .padding(.top, 4)
        }
        .glassCard()
        .frame(maxWidth: 380)
        .padding(VaultUI.screenPadding)
    }

    private func submit() {
        guard !password.isEmpty else { return }
        let entered = password
        password = ""                      // drop the field copy immediately
        vault.unlock(password: entered)
    }
}

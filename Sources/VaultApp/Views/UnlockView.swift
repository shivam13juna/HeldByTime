// UnlockView.swift — Task 9: the password prompt, reachable ONLY when
// VaultStore.load() returned `.openWindow` (the AppModel routes here for nothing
// else). A wrong password fails closed in VaultSession with no partial content;
// the view shows a single generic message and never hints whether the password
// or the file was at fault.

import SwiftUI

struct UnlockView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.open.fill").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Window open").font(.title2).bold()
            Text("Enter your vault password to unlock.")
                .foregroundStyle(.secondary)

            RevealableSecureField(placeholder: "Vault password", text: $password, onSubmit: submit)
                .frame(maxWidth: 300)

            if let err = model.unlockError {
                Text(err).font(.callout).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button("Unlock", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
        }
        .padding(36)
        .frame(maxWidth: 420)
    }

    private func submit() {
        guard !password.isEmpty else { return }
        let entered = password
        password = ""                      // drop the field copy immediately
        model.unlock(password: entered)
    }
}

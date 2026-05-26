// NotesEditorView.swift — the unlocked editor. Free-text notes plus the labelled
// secrets, each MASKED by default and revealed only on an explicit tap (app.md
// §2). The Lock button re-seals forward (VaultSession via the model) and returns
// to the locked screen; Cmd-Q does the same through the app delegate.
//
// Task 10 (no durable plaintext, app.md §9 / I13): the notes use the hardened
// NSTextView wrapper (HardenedTextEditor) because SwiftUI's TextEditor can't
// disable spellcheck / data-detectors / undo persistence. Secret VALUES are
// entered through SecureField (the secure field editor disables those services
// by construction); revealing shows a read-only plaintext echo, never an
// unhardened editable field. Nothing here logs or autosaves a secret.

import SwiftUI

struct NotesEditorView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    secretsSection
                    notesSection
                }
                .padding(20)
            }
        }
        .frame(minWidth: 480, minHeight: 460)
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var header: some View {
        HStack {
            Label("Vault open", systemImage: "lock.open.fill").font(.headline)
            Spacer()
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .help("Schedule")
            Button("Lock now") { model.lock() }
                .keyboardShortcut("l", modifiers: [.command])
                .help("Re-seal the vault until the next window")
        }
        .padding(12)
    }

    private var secretsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Secrets").font(.title3).bold()
            ForEach($model.content.secrets) { $secret in
                SecretRow(secret: $secret)
            }
            Button {
                model.content.secrets.append(VaultSecret(label: "New secret"))
            } label: { Label("Add secret", systemImage: "plus") }
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes").font(.title3).bold()
            // Hardened NSTextView — no spellcheck/data-detectors/undo persistence.
            HardenedTextEditor(text: $model.content.notes)
                .frame(minHeight: 160)
        }
    }
}

/// One secret row: label + value. Editing always happens in a SecureField (the
/// secure field editor masks input and disables spellcheck/data-detection by
/// construction — app.md §9). Tapping the eye reveals a READ-ONLY plaintext echo
/// so the value can be read without ever routing it through an unhardened,
/// editable field. Reveal is per-row and resets when the view rebuilds.
struct SecretRow: View {
    @Binding var secret: VaultSecret
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Label", text: $secret.label)
                .font(.callout).foregroundStyle(.secondary)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            HStack {
                SecureField("value", text: $secret.value)
                    .textFieldStyle(.roundedBorder)
                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .help(revealed ? "Hide" : "Reveal")
            }
            if revealed {
                // Read-only echo (selectable so it can be copied deliberately —
                // clipboard is an accepted out-of-scope surface, app.md §2).
                Text(secret.value.isEmpty ? "—" : secret.value)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
        }
        .padding(.vertical, 4)
    }
}

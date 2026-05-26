// NotesEditorView.swift — Task 9: the unlocked editor. Free-text notes plus the
// labelled secrets, each MASKED by default and revealed only on an explicit tap
// (app.md §2). The Lock button re-seals forward (VaultSession via the model) and
// returns to the locked screen; Cmd-Q does the same through the app delegate.
//
// Task 10 (no-durable-plaintext) will replace the plain TextEditor/SecureField
// with a hardened NSTextView wrapper and disable autosave / undo persistence /
// spellcheck / data-detectors on these fields. Task 9 keeps the standard SwiftUI
// controls (it is type-checked, not yet runnable) and adds no autosave/logging.

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
            TextEditor(text: $model.content.notes)
                .font(.body.monospaced())
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }
}

/// One secret row: label + value. The value is masked until the eye is tapped,
/// and editable in place. Revealing is per-row and resets when the view rebuilds.
struct SecretRow: View {
    @Binding var secret: VaultSecret
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Label", text: $secret.label)
                .font(.callout).foregroundStyle(.secondary)
                .textFieldStyle(.plain)
            HStack {
                if revealed {
                    TextField("value", text: $secret.value)
                        .textFieldStyle(.roundedBorder)
                } else {
                    // Masked, non-editing display — tap the eye to edit/reveal.
                    Text(secret.masked)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }
                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .help(revealed ? "Hide" : "Reveal")
            }
        }
        .padding(.vertical, 4)
    }
}

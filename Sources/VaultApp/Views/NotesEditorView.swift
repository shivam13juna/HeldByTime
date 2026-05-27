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
    @EnvironmentObject private var vault: VaultModel
    @EnvironmentObject private var app: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    secretsSection
                    notesSection
                }
                .padding(VaultUI.screenPadding)
            }
        }
        .frame(minWidth: 480, minHeight: 460)
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Leaving the open vault seals it first (closeCurrent → sealForQuit).
            Button { app.closeCurrent() } label: {
                Label("Vaults", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help("Lock and return to your vaults")
            Label(vault.label, systemImage: "lock.open.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Spacer()
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
            Button("Lock now") { vault.lock() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("l", modifiers: [.command])
                .help("Re-seal the vault until the next window")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var secretsSection: some View {
        SectionCard(title: "Secrets", systemImage: "key.fill") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach($vault.content.secrets) { $secret in
                    SecretRow(secret: $secret) {
                        vault.content.secrets.removeAll { $0.id == secret.id }
                    }
                }
                Button {
                    vault.content.secrets.append(VaultSecret(label: ""))
                } label: { Label("Add secret", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var notesSection: some View {
        SectionCard(title: "Notes", systemImage: "note.text") {
            // Hardened NSTextView — no spellcheck/data-detectors/undo persistence.
            HardenedTextEditor(text: $vault.content.notes)
                .frame(minHeight: 160)
        }
    }
}

/// One secret row: label + value. The value uses RevealableSecureField: masked
/// in a SecureField by default, and its eye toggle shows the cleartext in the
/// hardened single-line NSTextView (never an unhardened TextField), so the value
/// can be verified/read without a durable-plaintext surface (app.md §9). Reveal
/// is per-row and resets when the view rebuilds.
struct SecretRow: View {
    @Binding var secret: VaultSecret
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Label", text: $secret.label)
                    .font(.callout.weight(.medium))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                Spacer()
                Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
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
}

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
    /// Drives the "going back locks the vault" confirmation on the back button.
    @State private var confirmLeave = false

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
        .overlay { if vault.isSealing { sealingOverlay } }
        // Leaving with unsaved edits forces a choice (Model 1): Discard keeps the vault
        // openable in this window but drops the edits; Save & Lock seals it forward
        // (saved, but locked until its next window). A clean back skips this entirely.
        .alert("Unsaved changes", isPresented: $confirmLeave) {
            Button("Discard Changes", role: .destructive) { app.closeCurrent() }
            Button("Save & Lock") {
                vault.sealInteractively(trigger: .lockButton) { ok in
                    if ok { app.closeCurrent() }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You've edited “\(vault.label)” but haven't saved. Discard keeps it "
                 + "openable in this window but loses your changes. Save & Lock keeps "
                 + "them but locks the vault until its next window\(nextOpeningSuffix).")
        }
    }

    /// Shown while the (networked) re-seal runs off the main thread — so leaving or
    /// locking the vault gives honest feedback instead of a frozen window.
    private var sealingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("Sealing the vault…").font(.callout).foregroundStyle(.secondary)
            }
            .padding(28)
            .glassCard()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Model 1: going back SETS THE VAULT DOWN — it stays openable in this window
            // and reopens with the password, so a plain back needs no warning. The only
            // catch is UNSAVED edits: leaving drops them, so confirm first when dirty
            // (Discard vs Save & Lock). "Lock now" is always explicit and needs no prompt.
            Button {
                if vault.isDirty { confirmLeave = true } else { app.closeCurrent() }
            } label: {
                Label("Vaults", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(vault.isSealing)
            .help("Lock and return to your vaults")
            Label(vault.label, systemImage: "lock.open.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Spacer()
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .disabled(vault.isSealing)
                .help("Settings")
            Button("Lock now") { vault.sealInteractively(trigger: .lockButton) { _ in } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("l", modifiers: [.command])
                .disabled(vault.isSealing)
                .help("Re-seal the vault until the next window")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var secretsSection: some View {
        SectionCard(title: "Secrets", systemImage: "key.fill") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach($vault.content.secrets) { $secret in
                    SecretRow(secret: $secret, onCopy: copySecret) {
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

    /// Advisory "(date)" of this vault's next opening, shown in the unsaved-changes
    /// prompt's "Save & Lock … locks it until its next window …" line — the same
    /// schedule-derived hint the vault list shows. Empty when no upcoming opening is
    /// known (e.g. an empty schedule), so the sentence still reads.
    private var nextOpeningSuffix: String {
        guard let opening = vault.nextWindowOpening else { return "" }
        return " (\(opening.formatted(date: .abbreviated, time: .shortened)))"
    }

    /// Copy a stored secret's VALUE to the clipboard for pasting elsewhere. Per the
    /// owner's choice the value is NOT auto-cleared — it persists until they copy
    /// something else; SecretClipboard marks the item concealed so clipboard-history
    /// apps skip it. We also log a secret-free note that a copy happened.
    private func copySecret(_ value: String) {
        guard !value.isEmpty else { return }
        SecretClipboard.copy(value)
        vault.recordSecretCopied()
    }
}

/// One secret row: label + value. The value uses RevealableSecureField: masked
/// in a SecureField by default, and its eye toggle shows the cleartext in the
/// hardened single-line NSTextView (never an unhardened TextField), so the value
/// can be verified/read without a durable-plaintext surface (app.md §9). Reveal
/// is per-row and resets when the view rebuilds.
struct SecretRow: View {
    @Binding var secret: VaultSecret
    /// Copy the current value to the clipboard (the owner supplies the write + log).
    let onCopy: (String) -> Void
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
            RevealableSecureField(placeholder: "value", text: $secret.value, onCopy: onCopy)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

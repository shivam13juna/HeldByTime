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
            // A re-seal (Lock now / Save & Lock / Save & Quit) that couldn't complete —
            // e.g. offline — surfaces here instead of failing silently. The vault is still
            // open and the notes are unchanged on disk; the banner says so and is dismissible.
            if let err = vault.sealError { sealErrorBanner(err) }
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
        .overlay {
            if vault.isSealing { busyOverlay("Sealing the vault…") }
            else if vault.isSettingAside { busyOverlay("Setting aside…") }
        }
    }

    /// A modal "busy" veil shown while a background operation runs off the main thread —
    /// a networked re-seal ("Sealing the vault…") or the local set-aside key derivation
    /// ("Setting aside…") — so leaving or locking gives honest feedback instead of a
    /// frozen window.
    private func busyOverlay(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            .padding(28)
            .glassCard()
        }
    }

    /// The inline warning shown when `vault.sealError` is set — a re-seal that couldn't
    /// complete (offline, or notes over the cap). It makes the failed lock visible rather
    /// than a silent no-op; the user can dismiss it, and it also clears itself on the next
    /// seal attempt or a successful seal.
    private func sealErrorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { vault.sealError = nil } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Going back SETS THE VAULT ASIDE: a clean vault is set down (it reopens this
            // window with the password); a vault with unsaved edits has them re-locked into
            // an in-RAM stash and sealed forward only at window-end. Either way back is
            // safe and needs no prompt — `closeCurrent` does the dirty-vs-clean split.
            Button {
                app.closeCurrent()
            } label: {
                Label("Vaults", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(vault.isSealing || vault.isSettingAside)
            .help("Set aside and return to your vaults (unsaved edits are kept in memory until the window ends)")
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

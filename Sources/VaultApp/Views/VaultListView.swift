// VaultListView.swift — the multi-vault home. Lists every vault on disk and lets
// the user open one, create another, relabel or permanently delete one, and view
// the merged activity log. Each row shows an ADVISORY next-window opening (wall
// clock, schedule-derived) — never the real lock state: selecting a vault is the
// ONLY way to reach its authoritative lock screen, and this view never reads a
// vault's contents or sealed bytes.

import SwiftUI

struct VaultListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showMergedLog = false
    /// Rename: the targeted vault + the editable name (alert with a text field).
    @State private var renameTarget: VaultEntry?
    @State private var renameText = ""
    /// Delete: the targeted vault (drives the type-to-confirm sheet).
    @State private var deleteTarget: VaultEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if model.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.entries, id: \.id) { entry in
                            VaultRow(entry: entry,
                                     nextOpening: model.advisoryOpenings[entry.id],
                                     onOpen: { model.open(entry) },
                                     onRename: { startRename(entry) },
                                     onDelete: { deleteTarget = entry })
                        }
                    }
                }
            }
        }
        .padding(VaultUI.screenPadding)
        .frame(maxWidth: 820, maxHeight: .infinity, alignment: .top)
        .onAppear { model.refreshEntries() }
        .sheet(isPresented: $showMergedLog) {
            MergedLogView(loadLines: { model.mergedLogLines() },
                          clearAll: { model.clearAllLogs() })
        }
        .sheet(item: $deleteTarget) { entry in
            DeleteVaultSheet(entry: entry) { model.deleteVault(entry) }
        }
        .alert("Rename vault", isPresented: renameIsPresented) {
            TextField("Vault name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let entry = renameTarget { model.renameVault(entry, to: renameText) }
                renameTarget = nil
            }
        } message: {
            Text("Choose a new name for this vault. The name is just a label — it is "
                 + "not part of the lock.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your vaults").font(.largeTitle).bold()
                Text("Each vault time-locks on its own daily schedule.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                if !model.entries.isEmpty {
                    Button { showMergedLog = true } label: {
                        Label("Activity log", systemImage: "doc.text.magnifyingglass")
                    }
                    .controlSize(.large)
                }
                Button { model.beginCreate() } label: {
                    Label("New vault", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            GlyphBadge(systemImage: "lock.rectangle.stack", tint: .accentColor)
            Text("No vaults yet").font(.title3).bold()
            Text("Create your first time-locked vault to get started.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { model.beginCreate() } label: {
                Label("Create a vault", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard()
    }

    private func startRename(_ entry: VaultEntry) {
        renameText = entry.meta.label
        renameTarget = entry
    }

    /// `.alert(isPresented:)` needs a Bool binding; derive it from `renameTarget`
    /// (setting false clears the target).
    private var renameIsPresented: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }
}

/// One row in the vault list: lock glyph, label, and the ADVISORY next-window
/// opening, followed by three explicit per-vault actions — rename, delete, and
/// open — each a labelled icon button. No hidden menu and no row-wide tap target:
/// opening a vault is an intentional click on its own control (the only path to
/// that vault's authoritative lock screen).
struct VaultRow: View {
    let entry: VaultEntry
    /// Advisory next scheduled opening (wall clock). DISPLAY ONLY — never the real
    /// lock state; nil if the vault has no usable schedule.
    let nextOpening: Date?
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.meta.label)
                    .font(.headline)
                    .foregroundStyle(.primary)
                advisory
            }

            // Delete sits here, in the quiet zone by the name — deliberately far
            // from the Open button the user reaches for, since deletion is
            // permanent and irreversible. It is a quiet icon, not a target.
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .padding(.leading, 4)
            .help("Permanently delete this vault")

            Spacer()

            // The two intentional actions, grouped on the right.
            Button(action: onRename) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .foregroundStyle(.secondary)
            .help("Rename this vault")

            Button(action: onOpen) {
                Label("Open", systemImage: "lock.open")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.leading, 4)
            .help("Open this vault")
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }

    @ViewBuilder private var advisory: some View {
        if let next = nextOpening {
            Label("Next window \(next.formatted(date: .abbreviated, time: .shortened))",
                  systemImage: "calendar")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("No schedule set")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Type-to-confirm permanent deletion. Deleting a vault is IRREVERSIBLE (the sealed
/// blob is unlinked, never sent to the Trash — see VaultRegistry.delete) and there
/// is no recovery, so the Delete button stays disabled until the user types the
/// vault's exact name. This is deliberate friction for a commitment device.
struct DeleteVaultSheet: View {
    let entry: VaultEntry
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    private var matches: Bool { typed == entry.meta.label }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Delete this vault?", systemImage: "exclamationmark.triangle.fill")
                .font(.title2).bold()
                .foregroundStyle(.red)

            Text("This permanently deletes “\(entry.meta.label)” and everything sealed "
                 + "inside it. It is **not** moved to the Trash and **cannot** be "
                 + "recovered — even if you know the password.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Type the vault's name to confirm:")
                    .font(.callout).foregroundStyle(.secondary)
                TextField(entry.meta.label, text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .controlSize(.large)
                Button(role: .destructive) {
                    onConfirm()
                    dismiss()
                } label: { Text("Delete permanently") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!matches)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

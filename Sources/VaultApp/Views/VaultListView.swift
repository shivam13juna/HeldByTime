// VaultListView.swift — the multi-vault home. Lists every vault on disk and lets
// the user open one, create another, relabel or permanently delete one, and view
// the merged activity log. Each row shows an ADVISORY next-window opening (wall
// clock, schedule-derived) — never the real lock state: selecting a vault is the
// ONLY way to reach its authoritative lock screen, and this view never reads a
// vault's contents or sealed bytes.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct VaultListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showMergedLog = false
    /// Rename: the targeted vault + the editable name (alert with a text field).
    @State private var renameTarget: VaultEntry?
    @State private var renameText = ""
    /// Delete: the targeted vault (drives the type-to-confirm sheet).
    @State private var deleteTarget: VaultEntry?
    /// Uninstall: drives the confirm sheet; the fallback alert shows only if the
    /// app couldn't move itself to the Trash (translocation / read-only location).
    @State private var showUninstall = false
    @State private var trashFallback = false
    /// Export: a multi-select mode (entered from the app overflow menu) lets the user
    /// tick one or more vaults; `selected` holds their ids and `showExportWarning`
    /// drives the "not time-locked once shared" sheet shown BEFORE the save panel.
    /// `portError` surfaces any export/import failure as a dismissable alert.
    @State private var isSelecting = false
    @State private var selected: Set<String> = []
    @State private var showExportWarning = false
    @State private var portError: String?

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
                                     isSelecting: isSelecting,
                                     isSelected: selected.contains(entry.id),
                                     onToggleSelect: { toggleSelect(entry) },
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
        .sheet(isPresented: $showUninstall) {
            UninstallSheet(vaultCount: model.entries.count) { deleteVaults in
                performUninstall(deleteVaults: deleteVaults)
            }
        }
        .alert("Finish in the Finder", isPresented: $trashFallback) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("EncryptedVault's background helper has been removed (and any data "
                 + "you chose to delete is gone). To finish, drag EncryptedVault to "
                 + "the Trash.")
        }
        .sheet(isPresented: $showExportWarning) {
            ExportWarningSheet(count: selected.count,
                               onExport: { showExportWarning = false; runExportPanel() },
                               onCancel: { showExportWarning = false })
        }
        .alert("Couldn’t complete", isPresented: portErrorPresented) {
            Button("OK", role: .cancel) { portError = nil }
        } message: {
            Text(portError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isSelecting ? "Export vaults" : "Your vaults").font(.largeTitle).bold()
                Text(isSelecting
                     ? "Pick the vaults to save into one exported file."
                     : "Each vault time-locks on its own daily schedule.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if isSelecting { selectionControls } else { normalControls }
        }
    }

    /// The default header actions: activity log, new vault, and the app overflow menu.
    private var normalControls: some View {
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

            // App-level overflow at the far right of the header — a quiet menu, never a
            // primary control. Appearance is a GLOBAL app preference (ui.json), and
            // export/import act across vaults, so both live here rather than on a row.
            Menu {
                Picker("Appearance", selection: Binding(
                    get: { model.uiPrefs.appearance },
                    set: { model.applyAppearance($0) })) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }

                Divider()

                // Export enters a multi-select mode (one file can hold several vaults);
                // import reads one such file back. Both are app-level, not per-vault.
                Button { enterSelection() } label: {
                    Label("Export vaults…", systemImage: "square.and.arrow.up")
                }
                .disabled(model.entries.isEmpty)
                Button { runImportPanel() } label: {
                    Label("Import vaults…", systemImage: "square.and.arrow.down")
                }

                Divider()

                Button(role: .destructive) { showUninstall = true } label: {
                    Label("Uninstall application…", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
    }

    /// The header actions while picking vaults to export: select-all, cancel, and the
    /// primary Export button (disabled until at least one vault is ticked).
    private var selectionControls: some View {
        HStack(spacing: 8) {
            Button(allSelected ? "Deselect all" : "Select all") { toggleSelectAll() }
                .controlSize(.large)
                .disabled(model.entries.isEmpty)
            Button("Cancel") { exitSelection() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            Button { showExportWarning = true } label: {
                Label("Export \(selected.count)…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selected.isEmpty)
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

    /// True when every vault is ticked (drives the Select-all / Deselect-all label).
    private var allSelected: Bool {
        !model.entries.isEmpty && selected.count == model.entries.count
    }
    private func toggleSelect(_ entry: VaultEntry) {
        if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
    }
    private func toggleSelectAll() {
        if allSelected { selected.removeAll() } else { selected = Set(model.entries.map { $0.id }) }
    }
    private func enterSelection() { selected = []; isSelecting = true }
    private func exitSelection() { isSelecting = false; selected = [] }

    /// `.alert(isPresented:)` needs a Bool binding; derive it from `renameTarget`
    /// (setting false clears the target).
    private var renameIsPresented: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    /// Bool binding for the export/import error alert (cleared on dismiss).
    private var portErrorPresented: Binding<Bool> {
        Binding(get: { portError != nil },
                set: { if !$0 { portError = nil } })
    }

    /// The `.vault` content type used by both panels (custom extension; falls back
    /// to plain data on the off chance the system can't register it).
    private static let vaultType = UTType(filenameExtension: "vault") ?? .data

    /// After the warning sheet is accepted, ask where to save and write the selected
    /// vaults into one archive. On success, leave selection mode.
    private func runExportPanel() {
        let entries = model.entries.filter { selected.contains($0.id) }
        guard !entries.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.vaultType]
        panel.nameFieldStringValue = defaultExportName(entries)
        panel.canCreateDirectories = true
        panel.message = entries.count == 1
            ? "Choose where to save the exported vault. Keep it somewhere safe and "
              + "delete it once you've migrated."
            : "Choose where to save the exported vaults. Keep the file somewhere safe "
              + "and delete it once you've migrated."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if case .failure(let e) = model.exportVaults(entries, to: url) {
            portError = "Export failed: \(describe(e))"
        } else {
            exitSelection()
        }
    }

    /// A default file name for the chosen vaults: the single vault's label, or a
    /// count-stamped name for several.
    private func defaultExportName(_ entries: [VaultEntry]) -> String {
        entries.count == 1
            ? sanitizedFileName(entries[0].meta.label) + ".vault"
            : "EncryptedVault-\(entries.count)-vaults.vault"
    }

    /// Pick a `.vault` file and import every vault it contains (the model refreshes
    /// the list on success).
    private func runImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.vaultType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a vault file exported from EncryptedVault."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if case .failure(let e) = model.importArchive(from: url) {
            portError = "Import failed: \(describe(e))"
        }
    }

    /// A filesystem-safe default file name from a vault label (no path separators).
    private func sanitizedFileName(_ label: String) -> String {
        let cleaned = label.components(separatedBy: CharacterSet(charactersIn: "/\\:\0"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "vault" : cleaned
    }

    /// Non-secret, user-facing text for a port failure.
    private func describe(_ e: AppModel.PortError) -> String {
        switch e {
        case .missingVault:       return "one of the chosen vaults has nothing sealed to export yet."
        case .io(let detail):     return detail
        case .badBundle(let why): return "the file is not a valid vault export (\(why))."
        case .tooMany(let max):   return "you can export at most \(max) vaults in one file — "
                                       + "select fewer, or export in batches."
        }
    }

    /// Remove the background helper (+ optionally wipe data) via AppModel, then move
    /// the .app itself to the Trash and quit — the auto-trash uninstall.
    private func performUninstall(deleteVaults: Bool) {
        model.uninstallApplication(deleteVaults: deleteVaults) { _ in
            trashSelfAndQuit()
        }
    }

    /// Move this app bundle to the Trash, then terminate. If the move fails (e.g.
    /// Gatekeeper App Translocation or a read-only location), fall back to a notice
    /// asking the user to drag it to the Trash — never silently do nothing.
    private func trashSelfAndQuit() {
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
            DispatchQueue.main.async {
                if error == nil {
                    NSApplication.shared.terminate(nil)
                } else {
                    model.refreshEntries()   // data may be gone — don't show stale rows
                    trashFallback = true
                }
            }
        }
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
    /// Selection mode (export picker): show a checkbox in place of the lock glyph and
    /// turn the whole row into a toggle; the per-vault action buttons are hidden.
    let isSelecting: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 24)
            } else {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.meta.label)
                    .font(.headline)
                    .foregroundStyle(.primary)
                advisory
            }

            if !isSelecting {
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
            }

            Spacer()

            if !isSelecting {
                // The two intentional actions, grouped on the right. (Export is no
                // longer here — it's an app-level multi-select in the overflow menu.)
                Button(action: onRename) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
                .foregroundStyle(.secondary)
                .help("Rename this vault")

                Button(action: onOpen) {
                    // Closed padlock: this row only ever shows a vault in its locked
                    // state (the list never unlocks); "Open" is the action, lock.fill
                    // the current state.
                    Label("Open", systemImage: "lock.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.leading, 4)
                .help("Open this vault")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06))
        )
        .contentShape(Rectangle())
        .onTapGesture { if isSelecting { onToggleSelect() } }
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

            Text(markdown: "This permanently deletes “\(entry.meta.label)” and everything sealed "
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

/// Confirm uninstalling the whole application. It ALWAYS removes the background
/// re-seal helper and moves the app to the Trash. The opt-in checkbox ALSO wipes
/// every vault and all logs; because that is irreversible — and to match the
/// deliberate friction of single-vault delete — it requires typing a confirmation
/// phrase before the destructive button arms.
struct UninstallSheet: View {
    /// How many vaults exist now (for the destructive button's label).
    let vaultCount: Int
    /// Invoked on confirm with whether to ALSO wipe all vault data. The presenter
    /// performs the removal + auto-trash.
    let onConfirm: (_ deleteVaults: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var deleteVaults = false
    @State private var typed = ""

    /// The phrase the user must type to arm the data-wiping path.
    private static let confirmPhrase = "delete my vaults"
    /// Armed unless the destructive box is ticked without the exact phrase typed.
    private var armed: Bool { !deleteVaults || typed == Self.confirmPhrase }

    private var confirmLabel: String {
        guard deleteVaults else { return "Uninstall application" }
        return vaultCount > 0
            ? "Uninstall and delete \(vaultCount) vault\(vaultCount == 1 ? "" : "s")"
            : "Uninstall and delete all data"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Uninstall this application?", systemImage: "trash")
                .font(.title2).bold()

            Text(markdown: "This removes EncryptedVault's background re-seal helper and moves "
                 + "the app to the Trash. **Your vaults are kept** — reinstalling "
                 + "EncryptedVault re-opens them on their schedule.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $deleteVaults.animation()) {
                Text("Also permanently delete all my vaults and logs")
            }
            .toggleStyle(.checkbox)

            if deleteVaults {
                VStack(alignment: .leading, spacing: 6) {
                    Text(markdown: "This **permanently** deletes every vault and everything "
                         + "sealed inside — it is **not** moved to the Trash and "
                         + "**cannot** be recovered, even with the password.")
                        .font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Type “\(Self.confirmPhrase)” to confirm:")
                        .font(.callout).foregroundStyle(.secondary)
                    TextField(Self.confirmPhrase, text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button(role: deleteVaults ? .destructive : nil) {
                    let wipe = deleteVaults
                    dismiss()
                    onConfirm(wipe)
                } label: { Text(confirmLabel) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!armed)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// The warning shown BEFORE one or more vaults are exported. An exported file is a
/// copy that escapes the app's forward-reseal / window-end machinery: it stays
/// time-locked to its current round, but once that round publishes it can be opened
/// with only the password, forever, wherever the file sits. For a commitment device
/// that is the single biggest hole, so the user confirms with eyes open and is told
/// to store it safely and delete it after migrating.
struct ExportWarningSheet: View {
    /// How many vaults are being exported (drives the singular/plural copy).
    let count: Int
    let onExport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(count == 1 ? "Export this vault?" : "Export \(count) vaults?",
                  systemImage: "square.and.arrow.up")
                .font(.title2).bold()

            if count == 1 {
                Text(markdown: "The exported file is a **copy** for moving this vault to another "
                     + "Mac. It stays time-locked to its current window and protected by "
                     + "your password — but it will **not** re-lock itself the way the app "
                     + "does. Once its window passes, anyone who has the file **and** the "
                     + "password can open it.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(markdown: "The exported file is a **copy** for moving these vaults to another "
                     + "Mac. Each stays time-locked to its current window and protected by "
                     + "your password — but they will **not** re-lock themselves the way the "
                     + "app does. Once a vault's window passes, anyone who has the file "
                     + "**and** the password can open that vault.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Store it somewhere safe, and delete it once you've finished "
                 + "migrating.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button(count == 1 ? "Export…" : "Export \(count)…") { onExport() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

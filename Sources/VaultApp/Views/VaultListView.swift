// VaultListView.swift — the multi-vault home. Lists every vault on disk and lets
// the user open one or create another. This is the Phase-2 functional baseline:
// label + open + new vault. Phase 3 enriches each row with the advisory "opens
// at …" state, a per-vault menu (delete → type-to-confirm, rename), and a merged
// activity log. Selecting a vault is the ONLY way to reach its lock screen; this
// view never reads vault contents or the schedule.

import SwiftUI

struct VaultListView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if model.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.entries, id: \.id) { entry in
                            VaultRow(entry: entry) { model.open(entry) }
                        }
                    }
                }
            }
        }
        .padding(VaultUI.screenPadding)
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .top)
        .onAppear { model.refreshEntries() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your vaults").font(.largeTitle).bold()
                Text("Each vault time-locks on its own daily schedule.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.beginCreate() } label: {
                Label("New vault", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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
}

/// One row in the vault list: the label and a chevron, the whole row tappable to
/// open the vault. Advisory state + per-vault menu arrive in Phase 3.
struct VaultRow: View {
    let entry: VaultEntry
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text(entry.meta.label)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

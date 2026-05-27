// LockedView.swift — Task 9: shown whenever the vault is sealed, re-locked,
// offline, or fail-closed. It renders the pure `LockScreenInfo` the AppModel
// computed from `VaultStore.load()` — and crucially shows NO password field
// (`canPrompt` is false for every locked state; only `.openWindow` routes to
// UnlockView). This is the visible half of unseal-as-gate: there is nothing to
// type here that could open the vault early.
//
// The schedule is intentionally NOT editable from here: changing windows only
// affects the NEXT re-seal, never the current sealed window, so offering it on
// the locked screen is misleading. Windows are edited at first-run and from the
// open editor only — you cannot touch the lock while it is sealed.

import SwiftUI

struct LockedView: View {
    let info: LockScreenInfo
    @EnvironmentObject private var model: AppModel
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 18) {
            GlyphBadge(systemImage: icon, tint: tint)

            Text(info.title).font(.title).bold()

            // The coarse "Opens in about N hours" reassurance (not a live clock).
            if let relative = info.untilRelative {
                Text(relative)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(tint)
            }

            Text(info.message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if info.canRetry {
                Button("Check again") { model.reload() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }

            // Read-only diagnostics — helps explain "why is it locked / offline?"
            // without exposing the schedule (which must stay un-editable here).
            Button { showLog = true } label: {
                Label("View log", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .glassCard()
        .frame(maxWidth: 420)
        .padding(VaultUI.screenPadding)
        .sheet(isPresented: $showLog) { DiagnosticsView() }
    }

    private var icon: String {
        switch info.title {
        case "Offline":     return "wifi.slash"
        case "Unavailable": return "exclamationmark.octagon"
        default:            return "lock.fill"
        }
    }

    /// Accent the relative time + glyph by state: alarming red for an
    /// unavailable/offline state, calm accent otherwise.
    private var tint: Color {
        switch info.title {
        case "Unavailable": return .red
        case "Offline":     return .orange
        default:            return .accentColor
        }
    }
}

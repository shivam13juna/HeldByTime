// LockedView.swift — Task 9: shown whenever the vault is sealed, re-locked,
// offline, or fail-closed. It renders the pure `LockScreenInfo` the AppModel
// computed from `VaultStore.load()` — and crucially shows NO password field
// (`canPrompt` is false for every locked state; only `.openWindow` routes to
// UnlockView). This is the visible half of unseal-as-gate: there is nothing to
// type here that could open the vault early.

import SwiftUI

struct LockedView: View {
    let info: LockScreenInfo
    @EnvironmentObject private var model: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(info.title).font(.title).bold()
            Text(info.message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                if info.canRetry {
                    Button("Check again") { model.reload() }
                        .keyboardShortcut(.defaultAction)
                }
                Button("Schedule…") { showSettings = true }
            }
            .padding(.top, 4)
        }
        .padding(36)
        .frame(maxWidth: 460)
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var icon: String {
        switch info.title {
        case "Offline":     return "wifi.slash"
        case "Unavailable": return "exclamationmark.octagon"
        default:            return "lock.fill"
        }
    }
}

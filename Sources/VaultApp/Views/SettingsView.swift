// SettingsView.swift — Task 9: edit the daily windows. Editing the schedule can
// NEVER grant access: VaultStore.load() authorizes only on the committed
// manifest interval, not on these preferences (app.md §11). A schedule change
// only affects the NEXT re-seal's target window. Shown as a sheet from the
// locked screen and the editor.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SchedulePrefs = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Daily windows").font(.title2).bold()
            Text("The vault can only be opened inside one of these local-time windows. "
                 + "Changing them affects only the next time the vault re-seals — it never "
                 + "opens an already-sealed vault early.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach($draft.windows) { $w in
                WindowEditorRow(window: $w) {
                    draft.windows.removeAll { $0.id == w.id }
                }
            }

            Button {
                draft.windows.append(WindowPrefs(startHour: 4, startMinute: 0, endHour: 5, endMinute: 0))
            } label: { Label("Add window", systemImage: "plus") }

            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    model.applySchedule(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.windows.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460, height: 420)
        .onAppear { draft = model.schedulePrefs }
    }
}

/// A single editable window: start and end as hour/minute steppers.
struct WindowEditorRow: View {
    @Binding var window: WindowPrefs
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            timeField("From", hour: $window.startHour, minute: $window.startMinute)
            timeField("To", hour: $window.endHour, minute: $window.endMinute)
            Spacer()
            Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    private func timeField(_ label: String, hour: Binding<Int>, minute: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Stepper(value: hour, in: 0...23) { Text(String(format: "%02d", hour.wrappedValue)) }
                Text(":")
                Stepper(value: minute, in: 0...59) { Text(String(format: "%02d", minute.wrappedValue)) }
            }
        }
    }
}

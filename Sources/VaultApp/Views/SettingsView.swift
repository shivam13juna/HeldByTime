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
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Settings").font(.title2).bold()

                    SectionCard(title: "Daily windows", systemImage: "clock.fill",
                                subtitle: "The vault can only be opened inside one of these local-time "
                                    + "windows. Changing them affects only the next time the vault "
                                    + "re-seals — it never opens an already-sealed vault early.") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach($draft.windows) { $w in
                                WindowEditorRow(window: $w) {
                                    draft.windows.removeAll { $0.id == w.id }
                                }
                            }
                            if draft.windows.isEmpty {
                                Text("At least one window is required — there is no always-open mode. "
                                     + "Add a window to save.")
                                    .font(.caption).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Button {
                                draft.windows.append(WindowPrefs(startHour: 4, startMinute: 0, endHour: 5, endMinute: 0))
                            } label: { Label("Add window", systemImage: "plus") }
                                .buttonStyle(.borderless)
                        }
                    }

                    // Cosmetic appearance choice. Applies immediately (it isn't part
                    // of the schedule draft) and never affects the lock.
                    SectionCard(title: "Appearance", systemImage: "circle.lefthalf.filled") {
                        Picker("Appearance", selection: Binding(
                            get: { model.uiPrefs.appearance },
                            set: { model.applyAppearance($0) })) {
                            ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    // Read-only, secret-free activity log for troubleshooting.
                    SectionCard(title: "Diagnostics", systemImage: "doc.text.magnifyingglass",
                                subtitle: "A secret-free record of what the app and the background "
                                    + "re-seal agent did — useful if the vault doesn't behave as expected.") {
                        Button { showLog = true } label: {
                            Label("View activity log", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                }
                .padding(VaultUI.screenPadding)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .controlSize(.large)
                Button("Save") {
                    model.applySchedule(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.windows.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480, height: 460)
        .onAppear { draft = model.schedulePrefs }
        .sheet(isPresented: $showLog) { DiagnosticsView() }
    }
}

/// A single editable window: type the start/end hour and minute directly into
/// two-digit boxes (no steppers). Each box clamps to its valid range.
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
            HStack(spacing: 3) {
                TimeNumberField(value: hour, range: 0...23, hint: "HH")
                Text(":").font(.body.monospacedDigit())
                TimeNumberField(value: minute, range: 0...59, hint: "MM")
            }
        }
    }
}

/// A two-digit numeric entry box for an hour or minute. The user types the value
/// (digits only, max two); it is clamped to `range` live so a tap on Save always
/// sees the latest value, and zero-padded for display when focus leaves. Replaces
/// the up/down stepper.
struct TimeNumberField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let hint: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(hint, text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .font(.body.monospacedDigit())
            .frame(width: 46)
            .focused($focused)
            .onAppear { text = pad(value) }
            .onChange(of: value) { _, newValue in
                if !focused { text = pad(newValue) }     // external change (e.g. defaults on Add)
            }
            .onChange(of: text) { _, newText in
                let digits = String(newText.filter(\.isNumber).prefix(2))
                if digits != newText { text = digits; return }   // keep only ≤2 digits
                if let n = Int(digits) {                          // clamp live so Save is current
                    value = min(max(n, range.lowerBound), range.upperBound)
                }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { text = pad(value) }       // tidy to two digits on blur
            }
            .onSubmit { text = pad(value) }
    }

    private func pad(_ n: Int) -> String { String(format: "%02d", n) }
}

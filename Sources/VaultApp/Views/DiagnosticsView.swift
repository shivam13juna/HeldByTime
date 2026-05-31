// DiagnosticsView.swift — the read-only viewer for the SECRET-FREE diagnostics
// trail (DiagnosticLog). Reachable from Settings, the locked screen, and the
// failed screen, so when the vault "doesn't behave the way I expected" the user
// can see what actually happened: app launches, every background re-seal agent
// run, each load() outcome + reason (locked / offline / re-sealed / fail-closed),
// re-seal successes/failures, and hash-only quarantine records.
//
// It only READS the log and can CLEAR it — there is no way to write an entry from
// here, and the log itself can hold no secret (see DiagnosticLog / I13). It does
// NOT reference SettingsView, so it is safe to present from the locked screen
// (the schedule must not be reachable while sealed — leak/locked-no-schedule).

import SwiftUI

struct DiagnosticsView: View {
    /// The log to display — a vault's own diagnostics.log, or the app-level log.
    /// Passed in (not read from the environment) so the same viewer serves both
    /// a selected vault and the top-level failed screen.
    let log: DiagnosticLog
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Diagnostics", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            Group {
                if lines.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No diagnostics yet.")
                            .foregroundStyle(.secondary)
                        Text("Events appear here as the app and the background re-seal "
                             + "agent run. Nothing here is secret.")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                                    Text(line)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(idx)
                                }
                            }
                            .padding(12)
                        }
                        .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
                    }
                }
            }

            Divider()
            HStack {
                Button(role: .destructive) {
                    log.clear()
                    reload()
                } label: { Label("Clear log", systemImage: "trash") }
                    .disabled(lines.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 460)
        .onAppear { reload() }
    }

    private func reload() {
        // Stored UTC → the Mac's current zone for display (storage stays UTC).
        lines = log.tail().map { DiagnosticLog.localize($0) }
    }
}

// MergedLogView.swift — the combined activity log across EVERY vault plus the
// app-scope log, reachable from the vault list. Same read-only, secret-free trail
// as DiagnosticsView (DiagnosticLog / I13), but spanning all logs at once so the
// user can see, in one place, what the app and the background re-seal agent did
// across vaults. Each line is prefixed with its source ([App] or the vault label);
// lines are ordered chronologically by their ISO-8601 timestamp.
//
// It only READS the logs and can CLEAR them all — there is no way to write an entry
// from here, and the logs themselves can hold no secret. It does NOT reference the
// schedule, so it is safe to present alongside sealed vaults.

import SwiftUI

struct MergedLogView: View {
    /// Re-read all logs, merged + chronological. Called on appear and on refresh.
    let loadLines: () -> [String]
    /// Wipe every log (app-scope + all vaults). Non-secret; safe anytime.
    let clearAll: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Activity log", systemImage: "doc.text.magnifyingglass")
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
                        Text("No activity yet.")
                            .foregroundStyle(.secondary)
                        Text("Events from every vault and the background re-seal agent "
                             + "appear here as they happen. Nothing here is secret.")
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
                    clearAll()
                    reload()
                } label: { Label("Clear all logs", systemImage: "trash") }
                    .disabled(lines.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 480)
        .onAppear { reload() }
    }

    private func reload() {
        lines = loadLines()
    }
}

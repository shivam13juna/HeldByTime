// Theme.swift — the app's small design layer: a persisted appearance preference
// (System / Light / Dark) and a handful of reusable, native-feeling building
// blocks (a glass "card" surface, spacing tokens) so the screens stop being flat
// stacks of default controls.
//
// NOTHING here is security-relevant: the appearance choice is a cosmetic, non-
// secret preference stored as plain JSON beside the (also non-secret) schedule.
// It lives in its OWN file (ui.json) so a missing/old install falls back to the
// default WITHOUT touching schedule.json — the user's windows are never at risk
// from a UI-prefs decode failure.

import SwiftUI
import AppKit

// MARK: - Appearance preference

/// The user's light/dark choice. `.system` follows the OS; the other two pin it.
enum Appearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// Maps to SwiftUI's `.preferredColorScheme` input. `nil` means "follow the
    /// system", which is exactly what passing nil to that modifier does.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// Cosmetic, non-secret UI preferences. Persisted as plain JSON in its own file
/// so it is independent of the schedule (a decode failure here can never clobber
/// the user's windows). New fields should default so older files still decode.
struct UIPrefs: Codable, Equatable {
    var appearance: Appearance = .system

    static let `default` = UIPrefs()

    static func load(from url: URL) throws -> UIPrefs {
        try JSONDecoder().decode(UIPrefs.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - Design tokens

/// Shared spacing / shape constants so screens read consistently.
enum VaultUI {
    static let cornerRadius: CGFloat = 14
    static let cardPadding: CGFloat = 24
    static let screenPadding: CGFloat = 28
}

// MARK: - Reusable surfaces

extension View {
    /// Wrap content in a translucent rounded "card" — the native material look
    /// that adapts to light/dark automatically. Used for the hero panels.
    func glassCard(padding: CGFloat = VaultUI.cardPadding) -> some View {
        self
            .padding(padding)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: VaultUI.cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VaultUI.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}

/// A titled glass "section" panel for the form-style screens (editor, first-run,
/// settings). Groups a header (+ optional subtitle) with its content on one
/// material card, so the screens read as composed panels rather than flat stacks.
struct SectionCard<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(.secondary)
                }
                Text(title).font(.headline)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 18)
    }
}

/// A circular glyph badge used to anchor the lock/unlock screens — a soft
/// material disc behind an SF Symbol, instead of a bare gray icon.
struct GlyphBadge: View {
    let systemImage: String
    var tint: Color = .secondary
    var size: CGFloat = 92

    var body: some View {
        ZStack {
            Circle().fill(.regularMaterial)
            Circle().strokeBorder(Color.primary.opacity(0.06))
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

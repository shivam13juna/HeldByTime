// Theme.swift — the app's small SwiftUI design layer: reusable, native-feeling
// building blocks (a glass "card" surface, spacing tokens, a glyph badge) so the
// screens stop being flat stacks of default controls, plus the one SwiftUI-typed
// piece of the appearance preference (its `.preferredColorScheme` mapping).
//
// The appearance preference VALUE itself — the `Appearance` enum and the `UIPrefs`
// persisted to ui.json — now lives in UIPrefs.swift, Foundation-only, so AppModel
// can be unit-tested headless. Nothing here is security-relevant: the appearance
// choice is a cosmetic, non-secret preference stored as plain JSON in its OWN file
// (ui.json), independent of schedule.json, so a UI-prefs decode failure can never
// put the user's windows at risk.

import SwiftUI
import AppKit

// MARK: - Appearance → SwiftUI mapping

/// The `Appearance` enum itself (and `UIPrefs`) live in UIPrefs.swift so they stay
/// Foundation-only and headless-testable. The ONE SwiftUI-typed piece — the
/// mapping to `.preferredColorScheme`'s input — stays here, in the only VaultApp
/// file that needs SwiftUI for it. `nil` means "follow the system", which is
/// exactly what passing nil to that modifier does.
extension Appearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
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

// MARK: - Inline-markdown text

extension Text {
    /// Render a string that contains inline markdown (e.g. `**bold**`). SwiftUI only
    /// parses markdown when `Text` is handed a single string *literal*; our copy is
    /// assembled from `"…" + "…"` runtime Strings, which take the verbatim
    /// initializer and would show the literal `**` markers. Parsing to an
    /// AttributedString (inline elements only, whitespace preserved) makes the
    /// formatting render wherever the text is built at runtime.
    init(markdown: String) {
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            self.init(attributed)
        } else {
            self.init(verbatim: markdown)
        }
    }
}

// HardenedText.swift — Task 10 (no durable plaintext, app.md §9 / I13). SwiftUI's
// `TextEditor` cannot turn off the macOS text-"intelligence" services that can
// ship the typed text to a system service or an on-disk cache (continuous
// spellcheck, grammar, autocorrect, data/link detection, text/quote/dash
// substitution) and it keeps an undo stack. So the notes editor (and any other
// free-text vault field) drops to this `NSViewRepresentable` over a raw
// `NSTextView`, where every one of those can be disabled explicitly.
//
// Secret VALUES are entered through SwiftUI `SecureField` (NSSecureTextField):
// the secure field editor disables these same services by construction and turns
// on secure event input, so it is the right control for masked entry — reveal is
// a read-only echo (see NotesEditorView), never an unhardened editable field.

import SwiftUI
import AppKit

extension NSTextView {
    /// Disable every durable-plaintext leak surface of the AppKit text system.
    /// Called on creation and re-asserted on update so a later AppKit default
    /// flip can't silently re-enable a service.
    func applyVaultHardening() {
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        smartInsertDeleteEnabled = false
        allowsUndo = false                  // no persistable undo stack
        isAutomaticTextCompletionEnabled = false
        isRichText = false                  // plain text only — no attributes/attachments
        importsGraphics = false
        usesFontPanel = false
        usesRuler = false
        isRulerVisible = false
        usesFindBar = false
    }
}

/// A password field with a reveal (eye) toggle. Masked uses SwiftUI
/// `SecureField` (NSSecureTextField); revealed swaps to the hardened single-line
/// `HardenedTextEditor` above — NEVER an unhardened SwiftUI `TextField`. So
/// showing the cleartext adds no durable-plaintext surface (spellcheck,
/// autocorrect-learning and undo persistence stay disabled in both states),
/// preserving Task 10 / app.md §9 while still letting the user verify what they
/// typed. Reveal state is local and resets when the view is rebuilt.
struct RevealableSecureField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 6) {
            // Both states are borderless and sit inside ONE SwiftUI-drawn box, so
            // masked and revealed look identical (no native-bezel vs rounded
            // mismatch). The revealed control is the hardened NSTextView, not a
            // plain TextField — same no-leak guarantee in both states.
            Group {
                if revealed {
                    HardenedTextEditor(text: $text, singleLine: true,
                                       monospaced: false, bordered: false,
                                       onSubmit: onSubmit)
                        .frame(height: 17)
                } else {
                    SecureField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                        .onSubmit(onSubmit)
                }
            }
            .fieldBox()   // shared editable-field chrome (Theme.swift)

            Button { revealed.toggle() } label: {
                // Icon signifies the current STATE, not the action: an open eye when
                // the value is visible, a struck-through eye when it is masked.
                Image(systemName: revealed ? "eye" : "eye.slash")
            }
            .buttonStyle(.plain)
            .help(revealed ? "Hide" : "Show")
            .accessibilityLabel(revealed ? "Hide value" : "Show value")
        }
    }
}

/// A plain-text editor backed by a hardened `NSTextView`. Two-way bound to a
/// `String`. Multiline by default; `singleLine` gives a one-row field for short
/// values without the autocorrect/undo surface a SwiftUI `TextField` carries.
struct HardenedTextEditor: NSViewRepresentable {
    @Binding var text: String
    var singleLine = false
    var monospaced = true
    /// When false, draw no native bezel/background so the field can sit inside a
    /// caller-drawn container (used by RevealableSecureField for a uniform look).
    var bordered = true
    /// In `singleLine` mode, Enter calls this instead of inserting a newline —
    /// lets the field act like a submit-on-return password field while keeping
    /// the hardened `NSTextView` (no unhardened SwiftUI `TextField`).
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, singleLine: singleLine, onSubmit: onSubmit) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.applyVaultHardening()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.font = monospaced
            ? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = singleLine ? NSSize(width: 2, height: 2)
                                                  : NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = bordered     // borderless: let the container show through
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.borderType = bordered ? .bezelBorder : .noBorder
        scroll.drawsBackground = bordered
        scroll.hasVerticalScroller = !singleLine
        scroll.hasHorizontalScroller = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
        textView.applyVaultHardening()      // re-assert every update
    }

    /// Bridges `NSTextView` edits back to the SwiftUI binding. Holds no copy of
    /// the text beyond the binding itself.
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        private let singleLine: Bool
        private let onSubmit: () -> Void
        init(text: Binding<String>, singleLine: Bool, onSubmit: @escaping () -> Void) {
            self.text = text; self.singleLine = singleLine; self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // In single-line mode a password can't contain a newline; strip any
            // (e.g. a pasted trailing newline) so the bound value stays clean.
            text.wrappedValue = singleLine
                ? textView.string.replacingOccurrences(of: "\n", with: "")
                : textView.string
        }

        /// Single-line Enter → submit instead of inserting a newline.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if singleLine && selector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            return false
        }
    }
}

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

/// A plain-text editor backed by a hardened `NSTextView`. Two-way bound to a
/// `String`. Multiline by default; `singleLine` gives a one-row field for short
/// values without the autocorrect/undo surface a SwiftUI `TextField` carries.
struct HardenedTextEditor: NSViewRepresentable {
    @Binding var text: String
    var singleLine = false
    var monospaced = true

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

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
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
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
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

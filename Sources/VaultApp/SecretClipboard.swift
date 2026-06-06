// SecretClipboard.swift — the ONE place a vault secret deliberately crosses the
// app boundary: copying a stored secret VALUE to the system pasteboard so the
// owner can paste it into a login elsewhere. This is in-scope for the threat model
// (during an open window the contents are the owner's to use — see README), but
// the clipboard is a system-wide read surface, so the write is hardened the way
// password managers harden it:
//
//   • It is marked CONCEALED (`org.nspasteboard.ConcealedType`, the nspasteboard.org
//     de-facto convention) so well-behaved clipboard-history apps — Maccy, Paste,
//     Alfred, Raycast, … — skip persisting it to their history.
//   • Per the owner's choice the value is NOT auto-cleared: it stays on the
//     clipboard until they copy something else.
//
// Residual limitation: macOS exposes no public API to opt a pasteboard string out
// of Universal Clipboard, so a copied secret may still sync to the owner's other
// Apple devices. That is an accepted trade-off of "copy with no auto-clear".
//
// AppKit-only, so it stays in the app layer (never the headless engine/tests).

import AppKit

enum SecretClipboard {
    /// The nspasteboard.org marker that flags pasteboard contents as a password /
    /// concealed value; history managers check for it and skip storing the item.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Put `value` on the general pasteboard as plain text (so paste works anywhere)
    /// AND under the concealed type (so history managers skip it). `declareTypes`
    /// clears the previous contents first.
    static func copy(_ value: String) {
        let pb = NSPasteboard.general
        pb.declareTypes([.string, concealedType], owner: nil)
        pb.setString(value, forType: .string)
        pb.setString(value, forType: concealedType)
    }
}

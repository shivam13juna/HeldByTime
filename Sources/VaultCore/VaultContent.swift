// VaultContent.swift — Task 9: the structured plaintext the vault holds.
//
// The PW01 inner layer seals an opaque `[UInt8]` blob (app.md §4); this is the
// concrete shape of those bytes for the UI: free-form text notes plus a list of
// labelled high-value secrets (the macOS admin password and the Canopy password
// per app.md §2, but any number of labelled secrets is supported). Keeping the
// model in VaultCore (no SwiftUI) means its serialization and the masked-render
// rule are unit-testable; the SwiftUI editor only presents it.
//
// Cardinal rules:
//   * Deterministic JSON (sorted keys) so encode is stable across runs.
//   * encode() enforces MAX_PLAINTEXT_NOTES_BYTES and decode() the same cap —
//     fail closed (sizeLimit) rather than seal/parse something oversized.
//   * An empty vault is valid (FORMAT.md: empty notes JSON is allowed).
//   * `masked` renders a FIXED-WIDTH mask — never one bullet per character — so
//     an idle glance leaks neither the value nor its length (app.md §2).

import Foundation

/// One labelled secret. Masked by default in the UI; revealed only on an
/// explicit tap (app.md §2). `Identifiable` (stdlib, not SwiftUI) lets the
/// editor list rows by stable id while the label/value are edited.
struct VaultSecret: Codable, Equatable, Identifiable {
    let id: UUID
    var label: String
    var value: String

    init(id: UUID = UUID(), label: String, value: String = "") {
        self.id = id
        self.label = label
        self.value = value
    }

    /// The default masked rendering: a fixed run of bullets for any non-empty
    /// value (length-hiding), an em dash when empty. The reveal path shows the
    /// real `value` instead — that decision lives in the view, not here.
    var masked: String { value.isEmpty ? "—" : String(repeating: "•", count: 8) }
}

struct VaultContent: Codable, Equatable {
    var notes: String
    var secrets: [VaultSecret]

    init(notes: String = "", secrets: [VaultSecret] = []) {
        self.notes = notes
        self.secrets = secrets
    }

    /// The first-run template: empty notes and a single blank secret row to
    /// start from. The user labels it (e.g. "macOS admin password", "Canopy
    /// password" per app.md §2) and adds as many more as they want — nothing
    /// here is hard-coded to a specific secret.
    static var initialTemplate: VaultContent {
        VaultContent(notes: "", secrets: [VaultSecret(label: "")])
    }

    /// Serialize to the bytes PW01 seals. Deterministic (sorted keys). Throws
    /// `.sizeLimit` if the result exceeds MAX_PLAINTEXT_NOTES_BYTES, and
    /// `.invariantViolation` if JSON encoding itself fails (it should not).
    func encode() throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(self) }
        catch { throw VaultFormatError.invariantViolation("VaultContent encode: \(error)") }
        guard data.count <= VaultConstants.MAX_PLAINTEXT_NOTES_BYTES else {
            throw VaultFormatError.sizeLimit("notes \(data.count) > MAX_PLAINTEXT_NOTES_BYTES")
        }
        return [UInt8](data)
    }

    /// Parse plaintext bytes (the PW01-decrypted notes) back into content.
    /// Over-cap input is rejected before parsing (`.sizeLimit`); malformed JSON
    /// fails closed (`.parseError`). No best-effort recovery.
    static func decode(_ bytes: [UInt8]) throws -> VaultContent {
        guard bytes.count <= VaultConstants.MAX_PLAINTEXT_NOTES_BYTES else {
            throw VaultFormatError.sizeLimit("notes \(bytes.count) > MAX_PLAINTEXT_NOTES_BYTES")
        }
        do { return try JSONDecoder().decode(VaultContent.self, from: Data(bytes)) }
        catch { throw VaultFormatError.parseError("VaultContent decode") }
    }
}

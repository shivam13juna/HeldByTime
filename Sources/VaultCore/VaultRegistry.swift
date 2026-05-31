// VaultRegistry.swift — multi-vault: the parent directory that holds ONE
// subdirectory per vault. Each vault is self-contained (vault.dat / vault.dat.bak,
// schedule.json, diagnostics.log, meta.json). The app-global appearance (ui.json)
// lives at the ROOT beside the subdirs, never inside a vault, so it is shared.
//
// Enumeration is by SCAN — a subdirectory that contains a vault.dat IS a vault —
// never a top-level index file: a corrupt index could orphan EVERY vault, while a
// scan degrades at most one. Nothing here is secret: directory names are random
// UUIDs and the per-vault label is user-chosen NON-secret metadata (same trust
// tier as the schedule). This layer only allocates, lists, renames, and removes
// vault directories; it NEVER reads or writes a vault's sealed bytes.

import Foundation

/// Non-secret per-vault metadata, persisted as meta.json in the vault's dir.
/// `Date` is Codable as-is (no formatter needed); the file is human-readable JSON.
struct VaultMeta: Codable, Equatable {
    var label: String
    var createdAt: Date
}

/// One discovered vault: its stable id (the subdirectory name), its directory,
/// and its decoded metadata. A missing/garbled meta.json yields a safe default
/// label rather than hiding the vault — a metadata problem must never make a
/// vault with a real vault.dat disappear from the list.
struct VaultEntry: Equatable, Identifiable {
    let id: String
    let dir: URL
    let meta: VaultMeta
}

enum RegistryError: Error, Equatable {
    case invalidId(String)   // an id that is not a single safe path component
    case notFound            // no vault directory with a vault.dat for this id
    case io(String)          // filesystem failure (create / write / remove)
}

/// The set of vault directories under a single root. Pure Foundation; fully
/// testable offline. Holds no vault state — each call hits the filesystem.
struct VaultRegistry {
    /// The parent directory, e.g. …/Application Support/EncryptedVault.
    let root: URL

    static let vaultFileName = "vault.dat"
    private static let metaFileName = "meta.json"
    /// The default label shown for a real vault whose meta.json is missing/corrupt.
    static let untitledLabel = "Untitled vault"

    init(root: URL) { self.root = root }

    // MARK: - enumeration

    /// Every subdirectory of `root` that contains a vault.dat, oldest first
    /// (createdAt, then id, for a stable order). A subdir WITHOUT a vault.dat — a
    /// freshly-allocated vault whose first-run setup has not sealed yet, or an
    /// abandoned allocation — is NOT listed: the list shows only real, sealed
    /// vaults. Never throws; an unreadable root is simply empty.
    func list() -> [VaultEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var entries: [VaultEntry] = []
        for name in names {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard fm.fileExists(atPath: dir.appendingPathComponent(Self.vaultFileName).path) else { continue }
            entries.append(VaultEntry(id: name, dir: dir, meta: readMeta(dir: dir)))
        }
        return entries.sorted { ($0.meta.createdAt, $0.id) < ($1.meta.createdAt, $1.id) }
    }

    /// True once at least one real (sealed) vault exists — drives launch routing
    /// (the create-first-vault flow vs the vault list).
    var hasAnyVault: Bool { !list().isEmpty }

    // MARK: - lifecycle

    /// Allocate a fresh, empty vault directory (random UUID) at 0700 and write its
    /// metadata. Returns the directory; the caller seals a vault.dat into it via
    /// FirstRunSetup over a VaultStore(dir:). Until that seal lands the new dir is
    /// NOT listed, so an abandoned first-run leaves only an empty dir (clean up
    /// with `delete(id:)`).
    func create(label: String, now: Date = Date()) -> Result<VaultEntry, RegistryError> {
        let id = UUID().uuidString
        let dir = root.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return .failure(.io("create dir: \(error)"))
        }
        let meta = VaultMeta(label: label, createdAt: now)
        guard writeMeta(meta, dir: dir) else { return .failure(.io("write meta")) }
        return .success(VaultEntry(id: id, dir: dir, meta: meta))
    }

    /// Permanently remove a vault: unlink its entire directory (vault.dat,
    /// vault.dat.bak, schedule.json, diagnostics.log, meta.json). `removeItem`
    /// UNLINKS — it does NOT route through the Trash — so a "weaker future me"
    /// cannot recover the sealed blob from a Trash can. No secure-overwrite: on
    /// APFS/SSD it is theatre (copy-on-write, wear-levelling), and the blob was
    /// encrypted-at-rest the whole time regardless. Allowed in any vault state;
    /// it destroys, it never reveals.
    func delete(id: String) -> Result<Void, RegistryError> {
        guard let dir = safeDir(for: id) else { return .failure(.invalidId(id)) }
        do { try FileManager.default.removeItem(at: dir) }
        catch { return .failure(.io("delete: \(error)")) }
        return .success(())
    }

    /// Permanently remove EVERY vault under the root — each unlinked, never Trashed
    /// (same semantics as `delete(id:)`). Best-effort: it attempts every vault and
    /// returns how many were removed. Does NOT touch the root-level app files
    /// (ui.json / app.log); the caller (the "Uninstall + delete data" path) wipes
    /// those separately. It destroys, it never reveals.
    @discardableResult
    func deleteAll() -> Int {
        var removed = 0
        for entry in list() {
            if case .success = delete(id: entry.id) { removed += 1 }
        }
        return removed
    }

    /// Rename (relabel) a vault in place. Fails if there is no real vault for `id`.
    func rename(id: String, to label: String) -> Result<VaultEntry, RegistryError> {
        guard let dir = safeDir(for: id) else { return .failure(.invalidId(id)) }
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(Self.vaultFileName).path) else {
            return .failure(.notFound)
        }
        var meta = readMeta(dir: dir)
        meta.label = label
        guard writeMeta(meta, dir: dir) else { return .failure(.io("write meta")) }
        return .success(VaultEntry(id: id, dir: dir, meta: meta))
    }

    /// Delete the pre-multi-vault single vault that lived DIRECTLY in `root`
    /// (root/vault.dat, root/vault.dat.bak, root/schedule.json, root/diagnostics.log
    /// and any leftover .tmp). That layout is obsolete; the file there is a dummy.
    /// The app-global root/ui.json (appearance) is deliberately preserved — it is
    /// not vault data. Best-effort and idempotent.
    func purgeLegacyTopLevelVault() {
        let fm = FileManager.default
        for name in ["vault.dat", "vault.dat.bak", "vault.dat.tmp", "vault.dat.bak.tmp",
                     "schedule.json", "diagnostics.log"] {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
    }

    // MARK: - meta.json

    private func readMeta(dir: URL) -> VaultMeta {
        let url = dir.appendingPathComponent(Self.metaFileName)
        guard let data = try? Data(contentsOf: url),
              let meta = try? JSONDecoder().decode(VaultMeta.self, from: data) else {
            // A real vault with no/garbled meta still shows — labelled generically,
            // sorted to the front (epoch createdAt) so it is never lost.
            return VaultMeta(label: Self.untitledLabel, createdAt: Date(timeIntervalSince1970: 0))
        }
        return meta
    }

    @discardableResult
    private func writeMeta(_ meta: VaultMeta, dir: URL) -> Bool {
        let url = dir.appendingPathComponent(Self.metaFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(meta) else { return false }
        do { try data.write(to: url, options: .atomic) } catch { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    // MARK: - id hardening

    /// Resolve an id to its directory ONLY if it is a single, safe path component
    /// (guards against "..", "/", empty, or absolute paths escaping the root).
    private func safeDir(for id: String) -> URL? {
        guard !id.isEmpty, id != ".", id != "..",
              !id.contains("/"), !id.contains("\0") else { return nil }
        return root.appendingPathComponent(id, isDirectory: true)
    }
}

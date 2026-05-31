// VaultBundle.swift — a tiny, dependency-free container that packs a vault's
// on-disk files into ONE portable `.vault` file for migrating to another machine
// (and unpacks it on import). Same hand-rolled style as VLT1 / PW01: a magic, a
// version, length-prefixed named entries, and a trailing SHA-256 over everything
// before it for cheap corruption / truncation detection.
//
// SECURITY: this layer NEVER decrypts. It moves the already-sealed bytes verbatim,
// so a bundle is exactly as protected as the vault on disk — time-locked to its
// current round, password-locked underneath. The escape-hatch property is that a
// bundle, once copied off, is no longer reached by the app's forward re-seal /
// window-end machinery, so after its round publishes it becomes password-only;
// that is the migration trade-off the export UI warns about, not a defect here.
//
// Layout (all integers big-endian):
//   "EVB1" (4) | version u8 (=1) | count u8
//   count × [ nameLen u16 | name (UTF-8) | dataLen u32 | data ]
//   SHA-256 (32) of every preceding byte
//
// `unpack` is fully validating and fail-closed: bad magic / version / checksum /
// bounds / an unsafe entry name all throw, and nothing is returned partially. The
// caller (AppModel import) additionally whitelists which names it will write, so a
// bundle can only ever land inside a freshly-allocated vault directory.

import Foundation
import CryptoKit

enum VaultBundleError: Error, Equatable {
    case tooShort                       // smaller than the fixed header + digest
    case badMagic                       // not an "EVB1" container
    case unsupportedVersion(UInt8)      // a newer/unknown layout version
    case truncated                      // a length runs past the body, or trailing junk
    case checksumMismatch               // the SHA-256 trailer does not match the body
    case unsafeName(String)             // an entry name that is not a single safe component
    case tooLarge                       // input exceeds the defensive total cap
}

/// Packs/validates the portable vault bundle. Pure (no I/O), so it is unit-tested
/// headless alongside the rest of the engine.
enum VaultBundle {
    static let magic: [UInt8] = Array("EVB1".utf8)   // 4 bytes
    static let version: UInt8 = 1
    /// Defensive caps so a malformed / hostile file cannot drive a huge allocation.
    /// A real vault is four small files; these are generous ceilings, not targets.
    static let maxEntries = 16
    static let maxEntryBytes = 4 * 1024 * 1024       // 4 MiB per entry
    static let maxTotalBytes = 32 * 1024 * 1024      // 32 MiB per bundle

    private static let headerLen = 6                 // magic(4) + version(1) + count(1)
    private static let digestLen = 32                // SHA-256

    // MARK: - pack

    /// Pack named files into one bundle, preserving entry order. Never fails: the
    /// caller has already chosen a small, safe set of files. More than `maxEntries`
    /// is clamped (our callers pass four), and the digest covers exactly what is
    /// written.
    static func pack(_ entries: [(name: String, data: Data)]) -> Data {
        var out: [UInt8] = []
        out += magic
        out.append(version)
        let kept = entries.prefix(maxEntries)
        out.append(UInt8(kept.count))
        for entry in kept {
            let name = Array(entry.name.utf8)
            out += beU16(name.count)
            out += name
            out += beU32(entry.data.count)
            out += [UInt8](entry.data)
        }
        out += Array(SHA256.hash(data: Data(out)))
        return Data(out)
    }

    // MARK: - unpack

    /// Parse and fully validate a bundle. Fail-closed: any anomaly throws and no
    /// partial result is returned. The digest is verified BEFORE any length-driven
    /// parsing, so a corrupt/truncated body is rejected before it can mislead the
    /// cursor.
    static func unpack(_ bytes: Data) throws -> [(name: String, data: Data)] {
        guard bytes.count <= maxTotalBytes else { throw VaultBundleError.tooLarge }
        let buf = [UInt8](bytes)
        guard buf.count >= headerLen + digestLen else { throw VaultBundleError.tooShort }
        guard Array(buf[0..<magic.count]) == magic else { throw VaultBundleError.badMagic }
        let ver = buf[magic.count]
        guard ver == version else { throw VaultBundleError.unsupportedVersion(ver) }

        // Verify the trailing digest over everything before it FIRST.
        let bodyEnd = buf.count - digestLen
        let stored = Array(buf[bodyEnd..<buf.count])
        let actual = Array(SHA256.hash(data: Data(buf[0..<bodyEnd])))
        guard actual == stored else { throw VaultBundleError.checksumMismatch }

        let count = Int(buf[magic.count + 1])
        guard count <= maxEntries else { throw VaultBundleError.truncated }

        var i = headerLen
        var result: [(name: String, data: Data)] = []
        for _ in 0..<count {
            guard i + 2 <= bodyEnd else { throw VaultBundleError.truncated }
            let nameLen = Int(beU16(buf, at: i)); i += 2
            guard nameLen > 0, i + nameLen <= bodyEnd else { throw VaultBundleError.truncated }
            guard let name = String(bytes: buf[i..<i + nameLen], encoding: .utf8) else {
                throw VaultBundleError.truncated
            }
            i += nameLen
            try validateName(name)
            guard i + 4 <= bodyEnd else { throw VaultBundleError.truncated }
            let dataLen = Int(beU32(buf, at: i)); i += 4
            guard dataLen <= maxEntryBytes, i + dataLen <= bodyEnd else { throw VaultBundleError.truncated }
            let data = Data(buf[i..<i + dataLen]); i += dataLen
            result.append((name: name, data: data))
        }
        guard i == bodyEnd else { throw VaultBundleError.truncated }   // no trailing junk
        return result
    }

    /// An entry name must be a single, safe path component — never a path, a
    /// traversal, or a hidden separator — so import can only write inside the
    /// freshly-allocated vault directory.
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw VaultBundleError.unsafeName(name)
        }
    }

    // MARK: - big-endian helpers

    private static func beU16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private static func beU32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }
    private static func beU16(_ b: [UInt8], at i: Int) -> UInt16 { (UInt16(b[i]) << 8) | UInt16(b[i + 1]) }
    private static func beU32(_ b: [UInt8], at i: Int) -> UInt32 {
        (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }
}

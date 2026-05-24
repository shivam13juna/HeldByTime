// Manifest.swift — the authoritative window record (FORMAT.md §4).
//
// Lives inside the tlock layer but outside the AES layer, so it can be read
// after a passwordless unseal. It is the SOLE authorization source for the open
// window (SECURITY_INVARIANTS.md I3). Fixed 54-byte binary layout:
//   magic "MFST" | version | reserved | chain_hash[32] | start u64 | end u64

enum Manifest {
    static let length = 54

    struct Window: Equatable {
        let startRound: UInt64
        let endRound: UInt64
    }

    static func encode(_ w: Window) throws -> [UInt8] {
        guard w.endRound > w.startRound else {
            throw VaultFormatError.invariantViolation("end <= start")
        }
        guard let chain = Hex.decode(VaultConstants.DRAND_CHAIN_HASH), chain.count == 32 else {
            throw VaultFormatError.invariantViolation("chain hash constant")
        }
        var out = ByteWriter()
        out.ascii("MFST")
        out.u8(UInt8(VaultConstants.MANIFEST_VERSION))
        out.u8(0)
        out.raw(chain)
        out.u64le(w.startRound)
        out.u64le(w.endRound)
        return out.bytes
    }

    static func decode(_ b: [UInt8]) throws -> Window {
        guard b.count == length else {
            throw VaultFormatError.parseError("manifest length \(b.count)")
        }
        var r = ByteReader(b)
        guard try r.take(4) == Array("MFST".utf8) else {
            throw VaultFormatError.parseError("MFST magic")
        }
        let version = try r.u8()
        guard Int(version) == VaultConstants.MANIFEST_VERSION else {
            throw VaultFormatError.unsupportedVersion("manifest version \(version)")
        }
        guard try r.u8() == 0 else {
            throw VaultFormatError.corrupt("manifest reserved != 0")
        }
        let chain = try r.take(32)
        guard let expected = Hex.decode(VaultConstants.DRAND_CHAIN_HASH), chain == expected else {
            throw VaultFormatError.invariantViolation("manifest chain mismatch")
        }
        let start = try r.u64le()
        let end = try r.u64le()
        guard end > start else {
            throw VaultFormatError.invariantViolation("end <= start")
        }
        return Window(startRound: start, endRound: end)
    }
}

// VLT1.swift — outer container framing (FORMAT.md §2).
//
// The header is PLAINTEXT and UNTRUSTED: display_start/display_end are hints for
// the locked screen only and are NEVER used for an access decision
// (SECURITY_INVARIANTS.md I2, I3). The authoritative rounds live in the manifest,
// readable only after a successful unseal. Layout (30-byte header):
//   magic "VLT1" | format_version | flags | display_start u64 |
//   display_end u64 | payload_len u64 | sealed_payload

enum VLT1 {
    static let headerLen = 30

    struct Container: Equatable {
        let displayStartRound: UInt64
        let displayEndRound: UInt64
        let sealedPayload: [UInt8]
    }

    static func encode(_ c: Container) throws -> [UInt8] {
        guard c.sealedPayload.count <= VaultConstants.MAX_SEALED_PAYLOAD_BYTES else {
            throw VaultFormatError.sizeLimit("sealed payload \(c.sealedPayload.count)")
        }
        var w = ByteWriter()
        w.ascii(VaultConstants.VLT1_MAGIC)
        w.u8(UInt8(VaultConstants.VAULT_FORMAT_VERSION))
        w.u8(0)
        w.u64le(c.displayStartRound)
        w.u64le(c.displayEndRound)
        w.u64le(UInt64(c.sealedPayload.count))
        w.raw(c.sealedPayload)
        return w.bytes
    }

    static func decode(_ b: [UInt8]) throws -> Container {
        guard b.count >= headerLen else {
            throw VaultFormatError.parseError("VLT1 too short \(b.count)")
        }
        var r = ByteReader(b)
        guard try r.take(4) == Array(VaultConstants.VLT1_MAGIC.utf8) else {
            throw VaultFormatError.parseError("VLT1 magic")
        }
        let version = try r.u8()
        guard Int(version) == VaultConstants.VAULT_FORMAT_VERSION else {
            throw VaultFormatError.unsupportedVersion("VLT1 version \(version)")
        }
        guard try r.u8() == 0 else {
            throw VaultFormatError.corrupt("VLT1 flags != 0")
        }
        let ds = try r.u64le()
        let de = try r.u64le()
        let plen = try r.u64le()
        guard plen <= UInt64(VaultConstants.MAX_SEALED_PAYLOAD_BYTES) else {
            throw VaultFormatError.sizeLimit("payload_len \(plen)")
        }
        guard UInt64(r.remaining) == plen else {
            throw VaultFormatError.parseError("payload_len mismatch hdr=\(plen) actual=\(r.remaining)")
        }
        let payload = try r.take(Int(plen))
        return Container(displayStartRound: ds, displayEndRound: de, sealedPayload: payload)
    }
}

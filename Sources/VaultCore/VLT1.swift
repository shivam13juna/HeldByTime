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

    /// DISPLAY-ONLY peek of the two plaintext display rounds, reading ONLY the fixed
    /// 30-byte header — never the (up to 2 MiB) sealed payload. The list advisory uses
    /// this so a vault's row reflects its ACTUAL committed window from a 30-byte read.
    /// Returns nil for anything that is not a well-formed VLT1 header. Like `decode`,
    /// these rounds are UNTRUSTED hints and NEVER an access decision (I2/I3) — the gate
    /// is always the unseal.
    static func peekDisplayRounds(_ header: [UInt8]) -> (start: UInt64, end: UInt64)? {
        guard header.count >= headerLen else { return nil }
        var r = ByteReader(header)
        guard let magic = try? r.take(4), magic == Array(VaultConstants.VLT1_MAGIC.utf8),
              let version = try? r.u8(), Int(version) == VaultConstants.VAULT_FORMAT_VERSION,
              let flags = try? r.u8(), flags == 0,
              let ds = try? r.u64le(), let de = try? r.u64le() else {
            return nil
        }
        return (ds, de)
    }
}

// Bytes.swift — fixed-width little-endian reader/writer and hex helpers.
//
// All multi-byte integers in the vault format are little-endian, fixed width
// (FORMAT.md §1). The reader is bounds-checked: every out-of-range read throws
// parseError rather than trapping, so a malformed file fails closed.

import Foundation

enum Hex {
    static func decode(_ s: String) -> [UInt8]? {
        guard s.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }

    static func encode(_ b: [UInt8]) -> String {
        b.map { String(format: "%02x", $0) }.joined()
    }
}

struct ByteWriter {
    private(set) var bytes: [UInt8] = []
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u32le(_ v: UInt32) {
        for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xff)) }
    }
    mutating func u64le(_ v: UInt64) {
        for i in 0..<8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xff)) }
    }
    mutating func raw(_ v: [UInt8]) { bytes.append(contentsOf: v) }
    mutating func ascii(_ s: String) { bytes.append(contentsOf: Array(s.utf8)) }
}

struct ByteReader {
    private let b: [UInt8]
    private(set) var pos = 0
    init(_ bytes: [UInt8]) { b = bytes }

    var remaining: Int { b.count - pos }

    mutating func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0, pos + n <= b.count else {
            throw VaultFormatError.parseError("read \(n) at \(pos) of \(b.count)")
        }
        defer { pos += n }
        return Array(b[pos..<pos + n])
    }

    mutating func u8() throws -> UInt8 { try take(1)[0] }

    mutating func u32le() throws -> UInt32 {
        let x = try take(4)
        return UInt32(x[0]) | (UInt32(x[1]) << 8) | (UInt32(x[2]) << 16) | (UInt32(x[3]) << 24)
    }

    mutating func u64le() throws -> UInt64 {
        let x = try take(8)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(x[i]) << (8 * UInt64(i)) }
        return v
    }

    mutating func rest() -> [UInt8] {
        defer { pos = b.count }
        return Array(b[pos..<b.count])
    }
}

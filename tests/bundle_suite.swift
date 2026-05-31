// bundle_suite.swift — offline coverage for VaultBundle, the portable `.vault`
// container used by export/import (machine migration). The format is pure bytes
// (no I/O), so this suite pins the round-trip and, more importantly, the fail-closed
// rejections: bad magic, unsupported version, a corrupted/truncated body, and an
// unsafe entry name (the path-traversal guard that lets import trust the names).

import Foundation

private func bk(_ n: String, _ cond: Bool, _ d: String = "") { check("bundle/" + n, cond, d) }

/// Expect `unpack` to throw a specific VaultBundleError (tagged by case).
private func expectBundleThrow(_ n: String, _ want: VaultBundleError, _ bytes: Data) {
    do {
        _ = try VaultBundle.unpack(bytes)
        bk(n, false, "expected throw \(want), returned normally")
    } catch let e as VaultBundleError {
        bk(n, e == want, "threw \(e), expected \(want)")
    } catch {
        bk(n, false, "threw non-bundle error \(error)")
    }
}

func runBundleSuite() {
    let entries: [(name: String, data: Data)] = [
        ("vault.dat", Data((0..<300).map { UInt8($0 & 0xff) })),
        ("vault.dat.bak", Data((0..<300).map { UInt8($0 & 0xff) })),
        ("schedule.json", Data("{\"windows\":[]}".utf8)),
        ("meta.json", Data("{\"label\":\"V\"}".utf8)),
    ]

    // Round-trip: pack then unpack returns the same names + bytes in order.
    do {
        let packed = VaultBundle.pack(entries)
        let got = (try? VaultBundle.unpack(packed)) ?? []
        let same = got.count == entries.count
            && zip(got, entries).allSatisfy { $0.name == $1.name && $0.data == $1.data }
        bk("roundtrip", same, "pack→unpack preserves entry names + bytes in order")
    }

    // Empty bundle (zero entries) is still a valid, checksummed container.
    do {
        let packed = VaultBundle.pack([])
        let got = try? VaultBundle.unpack(packed)
        bk("roundtrip-empty", got?.isEmpty == true, "an entry-less bundle round-trips to []")
    }

    let good = VaultBundle.pack(entries)

    // Bad magic ⇒ badMagic (checked before anything else).
    do {
        var b = [UInt8](good); b[0] ^= 0xff
        expectBundleThrow("reject-bad-magic", .badMagic, Data(b))
    }

    // Unsupported version ⇒ unsupportedVersion (checked before the checksum).
    do {
        var b = [UInt8](good); b[4] = 2          // version byte (after the 4-byte magic)
        expectBundleThrow("reject-version", .unsupportedVersion(2), Data(b))
    }

    // A flipped body byte ⇒ checksumMismatch (the SHA-256 trailer no longer matches).
    do {
        var b = [UInt8](good); b[10] ^= 0x01      // inside the first entry, not magic/version
        expectBundleThrow("reject-checksum", .checksumMismatch, Data(b))
    }

    // Truncation below the fixed header+digest ⇒ tooShort.
    do {
        let b = [UInt8](good).prefix(5)
        expectBundleThrow("reject-too-short", .tooShort, Data(b))
    }

    // Dropping bytes from the tail breaks the digest first ⇒ checksumMismatch (still
    // fail-closed; the point is it never returns partial entries).
    do {
        let b = [UInt8](good).dropLast(20)
        expectBundleThrow("reject-truncated-tail", .checksumMismatch, Data(b))
    }

    // An unsafe entry name (path traversal) ⇒ unsafeName. `pack` doesn't validate
    // names, so this is exactly how a hostile bundle would smuggle one — and unpack
    // must refuse it (the property import relies on to trust the names it writes).
    do {
        let evil = VaultBundle.pack([("../escape", Data("x".utf8)), ("vault.dat", Data("y".utf8))])
        expectBundleThrow("reject-unsafe-name", .unsafeName("../escape"), evil)
    }

    // A name containing a slash is rejected too.
    do {
        let evil = VaultBundle.pack([("a/b", Data("x".utf8))])
        expectBundleThrow("reject-slash-name", .unsafeName("a/b"), evil)
    }

    // Oversized input ⇒ tooLarge (defensive cap, before any allocation/parse).
    do {
        let huge = Data(count: VaultBundle.maxTotalBytes + 1)
        expectBundleThrow("reject-too-large", .tooLarge, huge)
    }
}

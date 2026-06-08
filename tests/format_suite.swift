// format_suite.swift — Task 2a: AES-256-GCM + PW01/manifest/VLT1 codecs.
//
// AES-GCM is anchored to two well-known AES-256 KATs (McGrew/Viega GCM test
// cases 13 & 14) so the PW01 golden can trust CryptoKit's output; the golden
// then guards OUR framing (header layout + determinism), not AES itself.

import Foundation
import CryptoKit

private func aesKAT(_ name: String, keyHex: String, ivHex: String, ptHex: String,
                    aadHex: String, expCt: String, expTag: String) {
    guard let kb = Hex.decode(keyHex), let ib = Hex.decode(ivHex),
          let pb = Hex.decode(ptHex), let ab = Hex.decode(aadHex) else {
        fail("format/aesgcm-kat-\(name)", "bad hex input"); return
    }
    do {
        let box = try AES.GCM.seal(Data(pb), using: SymmetricKey(data: Data(kb)),
                                   nonce: try AES.GCM.Nonce(data: Data(ib)),
                                   authenticating: Data(ab))
        let ct = Hex.encode(Array(box.ciphertext)), tg = Hex.encode(Array(box.tag))
        check("format/aesgcm-kat-\(name)", ct == expCt && tg == expTag, "ct=\(ct) tag=\(tg)")
    } catch { fail("format/aesgcm-kat-\(name)", "\(error)") }
}

func runFormatSuite() {
    func ck(_ n: String, _ cond: Bool, _ d: String = "") { check("format/" + n, cond, d) }
    func et(_ n: String, _ t: String, _ b: () throws -> Void) { expectThrow("format/" + n, t, b) }

    let z64 = String(repeating: "0", count: 64)   // 32 zero bytes
    let z24 = String(repeating: "0", count: 24)   // 12 zero bytes
    let z32 = String(repeating: "0", count: 32)   // 16 zero bytes
    aesKAT("256-empty", keyHex: z64, ivHex: z24, ptHex: "", aadHex: "",
           expCt: "", expTag: "530f8afbc74536b9a963b4f1c4cb738b")
    aesKAT("256-block", keyHex: z64, ivHex: z24, ptHex: z32, aadHex: "",
           expCt: "cea7403d4d606b6e074ec5d3baf39d18", expTag: "d0d1c8a799996bf0265b98b5d48ab919")

    // ---- PW01 ----
    let key32 = SymmetricKey(data: Data(repeating: 0x42, count: 32))
    let wrongKey = SymmetricKey(data: Data(repeating: 0x43, count: 32))
    let salt16 = (0..<16).map { UInt8($0) }
    let nonce12 = (0..<12).map { UInt8(0xa0 + $0) }
    let notes = Array("hello vault — secret notes".utf8)

    do {
        let c = try PW01.seal(notes: notes, key: key32, salt: salt16, nonce: nonce12)
        let goldenHeader = "50573031010100001000030000000400000013000102030405060708090a0b0c0d0e0fa0a1a2a3a4a5a6a7a8a9aaab"
        ck("pw01-golden-header", Hex.encode(Array(c[0..<PW01.headerLen])) == goldenHeader,
           Hex.encode(Array(c[0..<PW01.headerLen])))
        let c2 = try PW01.seal(notes: notes, key: key32, salt: salt16, nonce: nonce12)
        ck("pw01-deterministic", c == c2)
        ck("pw01-roundtrip", try PW01.open(c, key: key32) == notes)
        let ce = try PW01.seal(notes: [], key: key32, salt: salt16, nonce: nonce12)
        ck("pw01-empty-notes", try PW01.open(ce, key: key32) == [])

        et("pw01-wrong-key", "authError") { _ = try PW01.open(c, key: wrongKey) }
        var ta = c; ta[19] ^= 0xff
        et("pw01-aad-tamper", "authError") { _ = try PW01.open(ta, key: key32) }
        var tc = c; tc[PW01.headerLen] ^= 0xff
        et("pw01-ct-tamper", "authError") { _ = try PW01.open(tc, key: key32) }
        var uv = c; uv[4] = 2
        et("pw01-unknown-version", "unsupportedVersion") { _ = try PW01.open(uv, key: key32) }
        var pm = c; pm[6] = 1; pm[7] = 0; pm[8] = 0; pm[9] = 0
        et("pw01-param-mismatch", "invariantViolation") { _ = try PW01.open(pm, key: key32) }
        et("pw01-too-short", "corrupt") { _ = try PW01.open(Array(c[0..<40]), key: key32) }
    } catch { fail("format/pw01-setup", "\(error)") }

    // ---- Manifest ----
    do {
        let m = try Manifest.encode(.init(startRound: 1000, endRound: 2200))
        ck("manifest-length", m.count == Manifest.length, "\(m.count)")
        ck("manifest-roundtrip", try Manifest.decode(m) == Manifest.Window(startRound: 1000, endRound: 2200))

        var badMagic = m; badMagic[0] = 0x00
        et("manifest-bad-magic", "parseError") { _ = try Manifest.decode(badMagic) }
        var badVer = m; badVer[4] = 2
        et("manifest-bad-version", "unsupportedVersion") { _ = try Manifest.decode(badVer) }
        var badRes = m; badRes[5] = 1
        et("manifest-reserved", "corrupt") { _ = try Manifest.decode(badRes) }
        var badChain = m; for i in 6..<38 { badChain[i] = 0xff }
        et("manifest-wrong-chain", "invariantViolation") { _ = try Manifest.decode(badChain) }
        et("manifest-end-le-start", "invariantViolation") {
            _ = try Manifest.encode(.init(startRound: 200, endRound: 100))
        }
        et("manifest-bad-length", "parseError") { _ = try Manifest.decode(Array(m[0..<53])) }
    } catch { fail("format/manifest-setup", "\(error)") }

    // ---- VLT1 ----
    do {
        let payload = (0..<64).map { UInt8(truncatingIfNeeded: $0 * 7) }
        let v = try VLT1.encode(.init(displayStartRound: 5, displayEndRound: 9, sealedPayload: payload))
        ck("vlt1-roundtrip", try VLT1.decode(v) == VLT1.Container(displayStartRound: 5, displayEndRound: 9, sealedPayload: payload))

        var badMagic = v; badMagic[0] = 0x00
        et("vlt1-bad-magic", "parseError") { _ = try VLT1.decode(badMagic) }
        var badVer = v; badVer[4] = 9
        et("vlt1-unknown-version", "unsupportedVersion") { _ = try VLT1.decode(badVer) }
        var badFlags = v; badFlags[5] = 1
        et("vlt1-flags", "corrupt") { _ = try VLT1.decode(badFlags) }
        et("vlt1-payload-len-mismatch", "parseError") { _ = try VLT1.decode(Array(v[0..<v.count - 1])) }
        var over = Array(v[0..<VLT1.headerLen])
        for i in 22..<30 { over[i] = 0xff }
        et("vlt1-oversize-len", "sizeLimit") { _ = try VLT1.decode(over) }

        // peekDisplayRounds: the list advisory reads the two display rounds from the
        // 30-byte header ALONE (never the sealed payload), and rejects non-headers.
        let hdr = Array(v[0..<VLT1.headerLen])
        ck("vlt1-peek-matches-decode",
           VLT1.peekDisplayRounds(hdr).map { [$0.start, $0.end] } == [5, 9])
        ck("vlt1-peek-header-only-suffices", VLT1.peekDisplayRounds(hdr) != nil)
        ck("vlt1-peek-too-short", VLT1.peekDisplayRounds(Array(v[0..<(VLT1.headerLen - 1)])) == nil)
        var pbm = hdr; pbm[0] = 0x00
        ck("vlt1-peek-bad-magic", VLT1.peekDisplayRounds(pbm) == nil)
        var pbv = hdr; pbv[4] = 9
        ck("vlt1-peek-bad-version", VLT1.peekDisplayRounds(pbv) == nil)
        var pbf = hdr; pbf[5] = 1
        ck("vlt1-peek-bad-flags", VLT1.peekDisplayRounds(pbf) == nil)
    } catch { fail("format/vlt1-setup", "\(error)") }

    et("bytereader-overrun", "parseError") {
        var r = ByteReader([0x01, 0x02])
        _ = try r.u64le()
    }
}

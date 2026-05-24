// consistency_check.swift — Task 1 constants-consistency test.
//
// Compares four sources of the frozen constants, key-for-key and value-for-value:
//   argv[1]  spec/constants.json            (the canonical authority)
//   argv[2]  build/constants-swift.json     (compiled Swift dump)
//   argv[3]  build/constants-go.json        (compiled Go dump)
//   argv[4]  FORMAT.md                       (machine-checkable constants block)
//
// Every value is normalized to a canonical String (integers -> decimal string,
// strings -> raw) so JSON numeric-type quirks cannot mask a mismatch. The test
// fails on: missing key, extra key, type/value mismatch, or a malformed FORMAT.md
// table. Emits `RESULT: PASS|FAIL <name> [-- detail]` lines and exits non-zero on
// any failure. (See SECURITY_INVARIANTS.md I11.)

import Foundation

func die(_ msg: String) -> Never {
    print("RESULT: FAIL consistency/harness -- \(msg)")
    exit(2)
}

// Canonicalize one JSON value to a comparable string. Integers only; any
// non-integer number or unexpected type is rejected (our constants are ints/strings).
func canon(_ v: Any) -> String? {
    if let s = v as? String { return s }
    if let n = v as? NSNumber {
        let i = n.int64Value
        // Reject any non-integral number (none are expected in our constants).
        if Double(i) != n.doubleValue { return nil }
        return String(i)
    }
    return nil
}

func loadJSON(_ path: String, _ label: String) -> [String: String] {
    guard let data = FileManager.default.contents(atPath: path) else {
        die("\(label): cannot read \(path)")
    }
    let obj: Any
    do { obj = try JSONSerialization.jsonObject(with: data) }
    catch { die("\(label): invalid JSON in \(path): \(error)") }
    guard let dict = obj as? [String: Any] else { die("\(label): \(path) is not a JSON object") }
    var out: [String: String] = [:]
    for (k, v) in dict {
        guard let c = canon(v) else { die("\(label): key \(k) has unsupported value type") }
        out[k] = c
    }
    return out
}

func loadFormatTable(_ path: String) -> [String: String] {
    guard let raw = FileManager.default.contents(atPath: path),
          let content = String(data: raw, encoding: .utf8) else {
        die("format: cannot read \(path)")
    }
    let beginMarker = "<!-- CONSTANTS-TABLE-BEGIN -->"
    let endMarker = "<!-- CONSTANTS-TABLE-END -->"
    guard let b = content.range(of: beginMarker), let e = content.range(of: endMarker),
          b.upperBound <= e.lowerBound else {
        die("format: constants table markers missing or out of order in \(path)")
    }
    let block = content[b.upperBound..<e.lowerBound]
    var out: [String: String] = [:]
    for rawLine in block.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        guard let eq = line.firstIndex(of: "=") else {
            die("format: malformed line (no '='): '\(line)'")
        }
        let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        var val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if key.isEmpty { die("format: empty key in line '\(line)'") }
        if val.hasPrefix("\"") {
            guard val.hasSuffix("\""), val.count >= 2 else {
                die("format: unterminated string for key \(key)")
            }
            val = String(val.dropFirst().dropLast())
        } else {
            guard let n = Int64(val) else {
                die("format: value for \(key) is neither quoted string nor integer: '\(val)'")
            }
            val = String(n)
        }
        if out[key] != nil { die("format: duplicate key \(key)") }
        out[key] = val
    }
    return out
}

// Compare a candidate against the reference; emit one RESULT line per source.
func compare(reference: [String: String], candidate: [String: String], name: String) -> Bool {
    let refKeys = Set(reference.keys)
    let candKeys = Set(candidate.keys)
    var problems: [String] = []
    let missing = refKeys.subtracting(candKeys).sorted()
    let extra = candKeys.subtracting(refKeys).sorted()
    if !missing.isEmpty { problems.append("missing=\(missing)") }
    if !extra.isEmpty { problems.append("extra=\(extra)") }
    for key in refKeys.intersection(candKeys).sorted() {
        if reference[key] != candidate[key] {
            problems.append("value[\(key)]: ref='\(reference[key]!)' \(name)='\(candidate[key]!)'")
        }
    }
    if problems.isEmpty {
        print("RESULT: PASS consistency/\(name)")
        return true
    } else {
        for p in problems { print("RESULT: FAIL consistency/\(name) -- \(p)") }
        return false
    }
}

let args = CommandLine.arguments
guard args.count == 5 else {
    die("usage: consistency_check <constants.json> <swift.json> <go.json> <FORMAT.md>")
}

let reference = loadJSON(args[1], "json")
let swiftDump = loadJSON(args[2], "swift")
let goDump = loadJSON(args[3], "go")
let formatTable = loadFormatTable(args[4])

var ok = true
ok = compare(reference: reference, candidate: swiftDump, name: "swift-vs-json") && ok
ok = compare(reference: reference, candidate: goDump, name: "go-vs-json") && ok
ok = compare(reference: reference, candidate: formatTable, name: "format-vs-json") && ok

if reference.isEmpty { print("RESULT: FAIL consistency/nonempty -- constants.json is empty"); ok = false }
else { print("RESULT: PASS consistency/nonempty -- \(reference.count) constants") }

exit(ok ? 0 : 1)

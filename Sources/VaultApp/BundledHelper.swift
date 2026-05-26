// BundledHelper.swift — Task 11. The single, compiled-in SHA-256 of the bundled
// `vaultseal` helper. `HelperRunner.preflight()` hashes the on-disk helper and
// refuses to launch it unless it equals this value (app.md §9 / §11: the expected
// hash must be compiled in, NEVER read from a writable sidecar).
//
// The committed value is DELIBERATELY EMPTY: an empty expectation is itself a
// fail-closed condition (HelperRunner returns "no expected helper hash
// configured"), so a build that has not gone through the official `build.sh`
// bundling path can never run the helper — and therefore can never store a real
// secret. `build.sh` rewrites this file in place with the freshly-built helper's
// real digest just before it compiles the app, then restores the empty default
// afterward so the working tree stays at fail-closed. Do not hand-edit the bytes.

enum BundledHelper {
    /// SHA-256 (32 bytes) of `Contents/Helpers/vaultseal`, injected by `build.sh`.
    /// Empty here ⇒ launch preflight fails closed until an official build runs.
    static let sha256: [UInt8] = []
}

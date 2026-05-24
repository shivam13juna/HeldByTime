// DryRun.swift — developer-only dry-run wrappers around the helper boundary.
//
// This entire file is wrapped in `#if DEBUG`, so it is ABSENT from a release
// build. It is the only CLI-ish surface over the helper; keeping it debug-only
// is what lets us guarantee the shipped `.app` exposes no seal/unseal command
// line (app.md §10.6, §11). The release build must not contain any dry-run
// symbol or flag.
//
// `dryRunSurfaceMarker` is a unique string literal used by the wrappers below.
// run_tests's dry-run gate asserts, via `strings`, that this marker is PRESENT
// in a `-D DEBUG` build and ABSENT from a release build — a robust, mangling-
// independent proof that the surface does not leak into release.

#if DEBUG
import Foundation

/// Sentinel string the release gate searches for. Must never appear in a
/// release binary.
let dryRunSurfaceMarker = "VAULT_DRYRUN_SURFACE_V1"

/// Developer dry-run wrappers. They add nothing to the security contract; they
/// exist only so a developer can drive a real seal/unseal against a built helper
/// from a debug harness. Each prints the marker so the surface is detectable.
enum DryRun {
    static func seal(runner: HelperRunner, payload: Data,
                     targetRound: UInt64, verifiedLatest: UInt64) -> Result<Data, HelperError> {
        FileHandle.standardError.write(Data("\(dryRunSurfaceMarker) seal round=\(targetRound)\n".utf8))
        return VaultSealClient(runner: runner).seal(payload: payload,
                                                    targetRound: targetRound,
                                                    verifiedLatest: verifiedLatest)
    }

    static func unseal(runner: HelperRunner, sealed: Data) -> Result<Data, HelperError> {
        FileHandle.standardError.write(Data("\(dryRunSurfaceMarker) unseal\n".utf8))
        return VaultSealClient(runner: runner).unseal(sealed: sealed)
    }

    static func currentRound(runner: HelperRunner) -> Result<CurrentRoundInfo, HelperError> {
        FileHandle.standardError.write(Data("\(dryRunSurfaceMarker) current-round\n".utf8))
        return VaultSealClient(runner: runner).currentRound()
    }
}
#endif

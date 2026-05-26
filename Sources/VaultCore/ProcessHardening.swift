// ProcessHardening.swift — Task 10 (no durable plaintext, app.md §9 / SECURITY
// INVARIANTS I13). The one piece of the leakage pass that is OS-level rather than
// SwiftUI, so it lives in VaultCore (no AppKit) and is genuinely unit-testable:
// disabling process core dumps. A core dump of a process holding the decrypted
// notes / derived key / password would be durable plaintext on disk, so we drop
// RLIMIT_CORE to zero at launch (called from the app delegate AND AppModel.init).
//
// The rest of the no-durable-plaintext surface (state restoration, editor
// autosave/undo, spellcheck/data-detectors) is text-system / AppKit and lives in
// the UI layer (HardenedText.swift, AppDelegate); it can't run headless and is
// covered by the type-check + the run_tests leak guard instead.

import Foundation

enum ProcessHardening {
    /// Set the soft AND hard core-dump size limit to 0, so a crash can never
    /// write a core file containing in-memory secrets. Lowering a limit needs no
    /// privilege (raising would); the change is irreversible within the process,
    /// which is exactly what we want. Idempotent. Returns false only if the
    /// syscall itself fails — callers treat that as best-effort (there is nothing
    /// safer to fall back to), but the unit test asserts it succeeds on the dev OS.
    @discardableResult
    static func disableCoreDumps() -> Bool {
        var limit = rlimit(rlim_cur: 0, rlim_max: 0)
        return setrlimit(RLIMIT_CORE, &limit) == 0
    }

    /// Read back the current core-dump limit (for the self-check / unit test).
    /// nil if `getrlimit` fails.
    static func coreDumpLimit() -> (cur: rlim_t, max: rlim_t)? {
        var limit = rlimit()
        guard getrlimit(RLIMIT_CORE, &limit) == 0 else { return nil }
        return (limit.rlim_cur, limit.rlim_max)
    }
}

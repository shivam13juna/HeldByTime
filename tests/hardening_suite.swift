// hardening_suite.swift — Task 10 (no durable plaintext, app.md §9 / I13). The
// text-system / state-restoration hardening is AppKit and can't run headless, so
// it is covered by the run_tests leak guard + the UI type-check. What CAN run
// here is the OS-level core-dump disable: we drop RLIMIT_CORE to zero and read it
// back with getrlimit to prove a crash can't write a core file full of plaintext.
//
// NOTE: this irreversibly lowers the test process's own core limit, which is
// harmless for a test binary. It runs last in main.swift for that reason.

import Foundation

func runHardeningSuite() {
    // The limit is readable before we touch it.
    check("hardening/core-limit-readable", ProcessHardening.coreDumpLimit() != nil)

    // Disabling succeeds on this OS, and the readback shows 0/0 (soft AND hard).
    check("hardening/disable-core-dumps-ok", ProcessHardening.disableCoreDumps())
    if let after = ProcessHardening.coreDumpLimit() {
        check("hardening/core-cur-zero", after.cur == 0, "rlim_cur = \(after.cur)")
        check("hardening/core-max-zero", after.max == 0, "rlim_max = \(after.max)")
    } else {
        fail("hardening/core-readback", "getrlimit failed after setrlimit")
    }

    // Idempotent: calling again keeps it at zero (and can never raise it back).
    _ = ProcessHardening.disableCoreDumps()
    check("hardening/core-stays-zero", ProcessHardening.coreDumpLimit()?.cur == 0)
}

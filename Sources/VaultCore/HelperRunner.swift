// HelperRunner.swift — hardened invocation of the bundled `vaultseal` helper.
//
// Every defense the helper boundary requires lives here (app.md §11
// "Subprocess invocation"; SECURITY_INVARIANTS I9):
//
//   • Absolute path, direct exec — never a shell. `Process.executableURL` runs
//     the binary itself; there is no `/bin/sh -c`, so argument/quoting injection
//     is impossible.
//   • Minimal environment — the child gets an EMPTY environment, so nothing from
//     the parent (or the user's shell) leaks in or influences it.
//   • Capped IO both directions — stdin is refused above its cap before launch;
//     stdout/stderr are read under caps, and an over-cap stream is fail-closed
//     (we never saw the full framed output, so we cannot trust it).
//   • Timeout = fail-closed — a hung helper is terminated, then killed, and the
//     call returns `.timeout`.
//   • Launch-time integrity — the binary must be a regular file (not a symlink),
//     carry the owner-exec bit, and hash to the expected SHA-256, which is
//     supplied by the caller (compiled in at bundling time — never a writable
//     sidecar). An empty expectation is itself a fail-closed condition.
//
// The actual `(timedOut, exit, stdout, stderr)` → result decision is delegated
// to `HelperWire.map`, keeping the contract logic pure and separately testable.

import Foundation
import CryptoKit
import Darwin

struct HelperRunner {
    let executableURL: URL
    /// Expected SHA-256 of the helper binary (32 bytes). Compiled in by the app
    /// layer at bundling time; an empty value fails the launch check closed.
    let expectedSHA256: [UInt8]
    let timeoutMilliseconds: Int
    let maxStdinBytes: Int
    let maxStdoutBytes: Int
    let maxStderrBytes: Int

    init(executableURL: URL,
         expectedSHA256: [UInt8],
         timeoutMilliseconds: Int = VaultConstants.HELPER_TIMEOUT_MS,
         maxStdinBytes: Int = VaultConstants.MAX_SEALED_PAYLOAD_BYTES,
         maxStdoutBytes: Int = VaultConstants.MAX_STDOUT_BYTES,
         maxStderrBytes: Int = VaultConstants.MAX_STDERR_BYTES) {
        self.executableURL = executableURL
        self.expectedSHA256 = expectedSHA256
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maxStdinBytes = maxStdinBytes
        self.maxStdoutBytes = maxStdoutBytes
        self.maxStderrBytes = maxStderrBytes
    }

    /// Verify the binary is safe to launch: a non-symlink regular file, owned by
    /// us-or-root concerns aside, exec-bit set, hashing to the compiled-in value.
    /// Returns a `.failClosed` HelperError describing the first failure, or nil.
    func preflight() -> HelperError? {
        guard expectedSHA256.count == VaultConstants.ARGON2_OUTPUT_LEN else {
            return .failClosed("no expected helper hash configured")
        }
        let path = executableURL.path

        // lstat (not stat): a symlink reports S_IFLNK and is rejected, so the
        // hash we compute below cannot be redirected to a different file.
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return .failClosed("helper not found: \(path)")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            return .failClosed("helper is not a regular file")
        }
        guard (st.st_mode & S_IXUSR) != 0 else {
            return .failClosed("helper missing exec bit")
        }

        // Read with O_NOFOLLOW so a symlink swapped in after the lstat still
        // cannot be followed (defense in depth against a TOCTOU race).
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            return .failClosed("helper open failed")
        }
        defer { close(fd) }
        guard let data = readAll(fd: fd, cap: maxStdoutBytes * 16) else {
            return .failClosed("helper read failed or too large")
        }
        let digest = SHA256.hash(data: data)
        guard Array(digest) == expectedSHA256 else {
            return .failClosed("helper hash mismatch")
        }
        return nil
    }

    /// Run the helper with the given arguments and stdin, returning its stdout on
    /// success or a closed-domain HelperError on any failure.
    func run(arguments: [String], stdin: Data) -> Result<Data, HelperError> {
        guard stdin.count <= maxStdinBytes else {
            return .failure(.failClosed("stdin exceeds size cap"))
        }
        if let preflightError = preflight() {
            return .failure(preflightError)
        }

        // A broken pipe (child exits before reading all of stdin) must surface as
        // a write error we ignore, not a process-killing SIGPIPE.
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = [:]   // empty: no inheritance from the parent

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return .failure(.failClosed("spawn failed: \(error)"))
        }

        // Drain stdout/stderr concurrently so a large stream can never deadlock
        // against our stdin write (pipe buffers are ~64 KiB).
        let readers = DispatchGroup()
        var outData = Data(), errData = Data()
        var outTrunc = false, errTrunc = false
        let queue = DispatchQueue(label: "vaultseal.helper.io", attributes: .concurrent)

        readers.enter()
        queue.async {
            (outData, outTrunc) = Self.readCapped(outPipe.fileHandleForReading, cap: self.maxStdoutBytes)
            readers.leave()
        }
        readers.enter()
        queue.async {
            (errData, errTrunc) = Self.readCapped(errPipe.fileHandleForReading, cap: self.maxStderrBytes)
            readers.leave()
        }
        // Feed stdin on its own queue, then close so the child sees EOF.
        queue.async {
            let h = inPipe.fileHandleForWriting
            try? h.write(contentsOf: stdin)
            try? h.close()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + .milliseconds(timeoutMilliseconds)) == .timedOut {
            timedOut = true
            process.terminate()                 // SIGTERM
            if exited.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }

        // Readers finish at EOF once the child's pipe ends close on exit. Bound
        // the wait so a wedged reader cannot hang the caller.
        _ = readers.wait(timeout: .now() + .seconds(2))

        return HelperWire.map(timedOut: timedOut,
                              exitCode: process.terminationStatus,
                              stdout: outData,
                              stdoutTruncated: outTrunc,
                              stderr: errData,
                              stderrTruncated: errTrunc)
    }

    /// Read a file handle to EOF, keeping at most `cap` bytes. If more than `cap`
    /// bytes arrive, the excess is read and discarded (so the child can finish
    /// and we can collect its exit code) and `truncated` is set.
    private static func readCapped(_ handle: FileHandle, cap: Int) -> (Data, Bool) {
        var collected = Data()
        var truncated = false
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if collected.count < cap {
                let room = cap - collected.count
                if chunk.count <= room {
                    collected.append(chunk)
                } else {
                    collected.append(chunk.prefix(room))
                    truncated = true
                }
            } else {
                truncated = true
            }
        }
        return (collected, truncated)
    }

    /// Read a raw fd to EOF with a hard byte ceiling. Returns nil if the ceiling
    /// is exceeded (the helper binary should never approach it).
    private func readAll(fd: Int32, cap: Int) -> Data? {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 { return nil }
            if n == 0 { break }
            if out.count + n > cap { return nil }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }
}

// SecureFile.swift — Task 6: path/inode-hardened reads and the durable,
// escape-hatch-free write transaction for the vault pair (app.md §6, §9;
// SECURITY_INVARIANTS I12).
//
// The adversary is the owner on a standard account: they can replace vault.dat
// or vault.dat.bak with a symlink/hardlink, loosen the mode, or stash an expired
// copy. So every read opens with O_NOFOLLOW and verifies regular-file + owner ==
// uid + mode 0600 + st_nlink == 1; anything else is refused and the caller
// classifies it as unreadable (never trusted). Every write goes
// tmp -> F_FULLFSYNC -> rename, strictly within the same directory, in the exact
// order that never leaves an expired ".bak" beside a future-sealed primary:
// write vault.dat.tmp + fsync -> delete old .bak -> rename over vault.dat
// (fsync file + dir) -> write .bak.tmp + fsync -> rename over .bak (fsync dir).
//
// On macOS a plain fsync does NOT flush to the platter; F_FULLFSYNC does (this
// vault trades speed for durability). These are raw POSIX primitives by design —
// FileManager offers no F_FULLFSYNC, no O_NOFOLLOW create, and no same-dir
// guarantee.

import Foundation
import Darwin

enum SecureFileError: Error, Equatable {
    case io(String)
}

enum SecureFile {

    /// Outcome of a hardened read attempt.
    enum ReadOutcome: Equatable {
        case missing                // ENOENT: no such file
        case unreadable(String)     // symlink / wrong owner / wrong mode / hardlink / IO
        case bytes([UInt8])         // a verified regular, 0600, single-link, owner-matching file
    }

    /// Open + verify + read a file without following any trap the owner planted.
    /// `cap` bounds the read so a swapped-in huge file cannot exhaust memory.
    static func readHardened(_ path: String, cap: Int) -> ReadOutcome {
        // O_NOFOLLOW: a symlink at `path` fails with ELOOP rather than being
        // followed, so the bytes/stat below describe the path itself.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            let e = errno
            if e == ENOENT { return .missing }
            if e == ELOOP { return .unreadable("symlink (O_NOFOLLOW)") }
            return .unreadable("open errno \(e)")
        }
        defer { close(fd) }

        // fstat the open descriptor (not the path) so there is no TOCTOU window
        // between the check and the read.
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .unreadable("fstat failed") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .unreadable("not a regular file") }
        guard st.st_uid == getuid() else { return .unreadable("owner != uid") }
        guard (st.st_mode & 0o777) == 0o600 else { return .unreadable("mode != 0600") }
        // A hard link count above 1 means a second name points at these bytes —
        // "future me" could keep a stashed copy alive through our delete step.
        guard st.st_nlink == 1 else { return .unreadable("st_nlink \(st.st_nlink) != 1") }

        guard let data = readAll(fd: fd, cap: cap) else { return .unreadable("read failed or over cap") }
        return .bytes(data)
    }

    // MARK: - Durable write primitives

    /// Create `tmpPath` fresh (unlinking any stale temp first), write all `bytes`,
    /// F_FULLFSYNC, close. O_EXCL + O_NOFOLLOW refuse to write through a
    /// pre-existing file or symlink at the temp path.
    static func writeTempDurable(_ tmpPath: String, _ bytes: [UInt8]) throws {
        unlink(tmpPath)   // remove any stale temp; ENOENT is fine
        let fd = open(tmpPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SecureFileError.io("create temp errno \(errno)") }

        var ok = true
        bytes.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n <= 0 { ok = false; break }
                off += n
            }
        }
        if ok && fcntl(fd, F_FULLFSYNC) != 0 { ok = false }
        close(fd)
        if !ok {
            unlink(tmpPath)
            throw SecureFileError.io("write/fsync temp failed")
        }
    }

    /// Atomically move `tmpPath` over `finalPath`, then F_FULLFSYNC the target
    /// file (if `fsyncFile`) and the directory so the rename itself is durable.
    static func renameDurable(from tmpPath: String, to finalPath: String,
                              dirPath: String, fsyncFile: Bool) throws {
        guard rename(tmpPath, finalPath) == 0 else { throw SecureFileError.io("rename errno \(errno)") }
        if fsyncFile {
            let ffd = open(finalPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if ffd >= 0 { _ = fcntl(ffd, F_FULLFSYNC); close(ffd) }
        }
        try fsyncDir(dirPath)
    }

    /// F_FULLFSYNC the directory so an unlink/rename is persisted, not just the
    /// file contents (a crash could otherwise resurrect a deleted .bak).
    static func fsyncDir(_ dirPath: String) throws {
        let dfd = open(dirPath, O_RDONLY | O_CLOEXEC)
        guard dfd >= 0 else { throw SecureFileError.io("open dir errno \(errno)") }
        defer { close(dfd) }
        guard fcntl(dfd, F_FULLFSYNC) == 0 else { throw SecureFileError.io("fsync dir failed") }
    }

    /// Unlink a path, then F_FULLFSYNC the directory so the deletion is durable.
    /// A missing file is success (the post-condition — "not present" — holds).
    static func removeDurable(_ path: String, dirPath: String) throws {
        if unlink(path) != 0 {
            let e = errno
            if e != ENOENT { throw SecureFileError.io("unlink errno \(e)") }
        }
        try fsyncDir(dirPath)
    }

    // MARK: - private

    /// Read a raw fd to EOF with a hard byte ceiling. Returns nil if the ceiling
    /// is exceeded (a legitimate vault file never approaches it).
    private static func readAll(fd: Int32, cap: Int) -> [UInt8]? {
        var out = [UInt8]()
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

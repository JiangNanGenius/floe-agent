// SPDX-License-Identifier: MPL-2.0
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A real advisory file lock shared by every `FurnitureAssetLibrary` instance
/// (or process) that publishes into the same library root. The actor alone is
/// deliberately not treated as global mutual exclusion.
final class FurnitureAssetFileLock {
    private let descriptor: Int32
    private var released = false

    init(url: URL) throws {
        let flags = Int32(O_RDWR) | Int32(O_CREAT) | Int32(O_CLOEXEC) | Int32(O_NOFOLLOW)
        let descriptor = url.path.withCString { open($0, flags, 0o600) }
        guard descriptor >= 0 else {
            throw FurnitureAssetLibraryError.io("the asset version lock file could not be opened")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            _ = close(descriptor)
            throw FurnitureAssetLibraryError.io("the asset version lock is not a regular file")
        }
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    /// Returns `false` when another open file description currently holds the
    /// lock; unexpected lock errors are surfaced rather than retried forever.
    func tryAcquire() throws -> Bool {
        while true {
            if flock(descriptor, Int32(LOCK_EX) | Int32(LOCK_NB)) == 0 { return true }
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK || code == EAGAIN { return false }
            throw FurnitureAssetLibraryError.io("the asset version lock could not be acquired")
        }
    }

    func release() {
        guard !released else { return }
        released = true
        _ = flock(descriptor, Int32(LOCK_UN))
        _ = close(descriptor)
    }
}

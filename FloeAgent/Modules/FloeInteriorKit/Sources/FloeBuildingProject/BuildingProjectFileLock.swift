import Darwin
import Dispatch
import Foundation

/// Cross-process advisory lock backed by flock(2). A new file descriptor is
/// opened for every operation, so two repository instances in the same process
/// also contend for the lock instead of sharing an in-memory mutex.
final class BuildingProjectFileLock {
    private var descriptor: Int32?

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    static func acquire(at url: URL, exclusive: Bool, timeout: TimeInterval) throws -> BuildingProjectFileLock {
        let path = url.path
        let descriptor = path.withCString { pointer in
            Darwin.open(pointer, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            throw BuildingProjectError.lockFailed(
                "open failed with errno \(errno): \(String(cString: strerror(errno)))"
            )
        }
        let operation = (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(max(0, timeout) * 1_000_000_000)
        while true {
            if flock(descriptor, operation) == 0 {
                return BuildingProjectFileLock(descriptor: descriptor)
            }
            let code = errno
            if code != EWOULDBLOCK && code != EAGAIN {
                _ = Darwin.close(descriptor)
                throw BuildingProjectError.lockFailed(
                    "flock failed with errno \(code): \(String(cString: strerror(code)))"
                )
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                _ = Darwin.close(descriptor)
                throw BuildingProjectError.lockTimeout
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    func release() {
        guard let descriptor else { return }
        self.descriptor = nil
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }
}

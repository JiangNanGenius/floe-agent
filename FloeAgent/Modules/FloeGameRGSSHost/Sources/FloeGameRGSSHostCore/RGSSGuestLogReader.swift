// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

/// Reads an actual captured job log, without following a final symlink or
/// blocking on a FIFO. The caller supplies the host-resolved staged log URL.
public enum RGSSGuestLogReader {
    public static func tail(of file: URL, maximumBytes: Int = 65_536) throws -> String {
        guard file.isFileURL, (1...1_048_576).contains(maximumBytes) else {
            throw RGSSGuestRunError.invalidRequest("log tail limit")
        }
        try Task.checkCancellation()
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw error() }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw error() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw RGSSGuestRunError.unsafeSourceEntry("job log is not a regular file")
        }
        let count = Int(min(info.st_size, off_t(maximumBytes)))
        let start = info.st_size - off_t(count)
        var data = Data(count: count)
        let readCount = try data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Int in
            var offset = 0
            while offset < count {
                try Task.checkCancellation()
                let result = pread(descriptor, bytes.baseAddress!.advanced(by: offset),
                                   min(65_536, count - offset), start + off_t(offset))
                if result < 0 {
                    if errno == EINTR { continue }
                    throw error()
                }
                if result == 0 { break }
                offset += result
            }
            return offset
        }
        data.count = readCount
        return String(decoding: data, as: UTF8.self)
    }

    private static func error() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

// FloeWorkspace — Reader byte sources and cancellation.
//
// SPDX-License-Identifier: MPL-2.0
//
// The reader never loads a document into one buffer. Both concrete sources
// answer bounded offset reads, so the index scan, windows and find all work
// on the same small working set. A file source opens a handle per read,
// keeping the value type `Sendable` and free of shared mutable state.

import Foundation

/// Bounded random-access byte source.
public protocol ReaderByteSource: Sendable {
    /// Total bytes in the source.
    var byteLength: Int64 { get }
    /// Reads at most `length` bytes starting at `offset` (clamped to EOF).
    func read(offset: Int64, length: Int) throws -> Data
}

/// Cancellation signal the reader polls between chunks. It is an explicit
/// closure so callers (UI tasks, qualification harnesses) can cancel
/// deterministically, and no reader code needs to assume a task context.
public struct ReaderCancellation: Sendable {
    private let isCancelled: @Sendable () -> Bool

    public init(_ isCancelled: @escaping @Sendable () -> Bool) {
        self.isCancelled = isCancelled
    }

    public static let never = ReaderCancellation { false }

    /// Cancellation of the current Swift task.
    public static func task() -> ReaderCancellation {
        ReaderCancellation { Task.isCancelled }
    }

    public var cancelled: Bool { isCancelled() }

    public func throwIfCancelled() throws {
        if isCancelled() { throw ReaderError.cancelled }
    }
}

/// In-memory source (Notes text documents, remote previews already staged by
/// the existing bounded remote reader).
public struct ReaderDataByteSource: ReaderByteSource {
    public let data: Data
    public init(data: Data) { self.data = data }
    public var byteLength: Int64 { Int64(data.count) }

    public func read(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, offset <= byteLength, length >= 0 else {
            throw ReaderError.sourceUnavailable("read out of range")
        }
        let start = Int(offset)
        let end = min(data.count, start + length)
        guard start <= end else { return Data() }
        return data.subdata(in: start..<end)
    }
}

/// File-backed source. Path resolution stays with the caller
/// (`WorkspacePathGuard` / the existing workspace file service); this type
/// only performs bounded reads of an already-authorized URL and never writes.
public struct ReaderFileByteSource: ReaderByteSource {
    public let url: URL
    public let byteLength: Int64

    public init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ReaderError.sourceUnavailable("not a regular file")
        }
        self.url = url
        self.byteLength = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    public func read(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, offset <= byteLength, length >= 0 else {
            throw ReaderError.sourceUnavailable("read out of range")
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ReaderError.sourceUnavailable("cannot open file")
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: length) ?? Data()
            return data
        } catch {
            throw ReaderError.sourceUnavailable("read failed")
        }
    }
}

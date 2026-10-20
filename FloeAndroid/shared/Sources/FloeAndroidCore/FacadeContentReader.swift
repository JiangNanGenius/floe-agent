// SPDX-License-Identifier: MPL-2.0
//
// RB-1 runtime bootstrap — bounded opaque-handle content reader.
//
// Purpose (contract frameBudget.oversizeItem + service-map contentreader):
// a single item larger than one frame is NOT truncated and NOT crammed into
// one message. The authoritative bytes stay inside Swift; the projection
// channel receives an opaque process-local handle plus scalar-safe chunk
// reads that reassemble byte-exactly. Binary attachments/keys NEVER cross
// this JSON channel. Handles expire honestly with the App instance: a new
// generation's reader knows no old handle (typed notFound), and the consumer
// must re-read through durable pages/attachment staging.
//
// This is a FOUNDATION in scope for RB1 (frame budget + reassembly
// correctness over caller-staged bytes). Later packages (RB3 conversation
// content, RB7 attachments) stage REAL store content through it; nothing
// here fabricates domain data or touches the filesystem.
//
// All state is guarded by one NSLock; every call is synchronous and JNI-safe.
// This source is NOT compiled/executed by the authoring package.
import Foundation

public final class FacadeContentReader: @unchecked Sendable {

    public enum Limits {
        public static let handlePrefix = "chunk:v1:"
        public static let handleHexLength = 32
        public static let maximumLiveHandles = 32
        /// Aggregate staged bytes bound for the current App instance.
        public static let maximumTotalBytes = 4_194_304
        /// One read request may not ask for more than the page budget.
        public static let maximumChunkBytes = 49_152
    }

    public enum StageOutcome: Sendable, Equatable {
        /// Closed typed rejection reasons (never a free-form error string).
        public enum Rejection: String, Sendable, Equatable {
            case contentSaturated
            case emptyContent
        }
        case staged(handle: String)
        case rejected(Rejection)
    }

    public enum ReadOutcome: Sendable {
        case slice(bytes: Data, nextOffset: Int, complete: Bool)
        case notFound
        case invalidOffset
    }

    private final class Blob: @unchecked Sendable {
        let handle: String
        let totalBytes: Int
        private let lock = NSLock()
        private var data: Data?
        init(handle: String, data: Data) {
            self.handle = handle
            self.totalBytes = data.count
            self.data = data
        }
        func read(offset: Int, length: Int) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            guard let data, offset >= 0, offset <= data.count,
                  length >= 0, offset + length <= data.count else { return nil }
            return data.subdata(in: offset..<(offset + length))
        }
        func invalidate() {
            lock.lock()
            if var buffer = data {
                buffer.resetBytes(in: 0..<buffer.count)
            }
            data = nil
            lock.unlock()
        }
        var isLive: Bool {
            lock.lock(); defer { lock.unlock() }
            return data != nil
        }
    }

    private let lock = NSLock()
    private var blobs: [String: Blob] = [:]
    private var order: [String] = []
    private var totalBytes = 0
    private let generation: UInt64

    /// A NEW reader per owner generation: old handles are process-death
    /// equivalent and resolve to typed notFound (honest expiry, no revival).
    public init(generation: UInt64) {
        self.generation = generation
    }

    // MARK: Stage

    /// Stage bounded UTF-8-encodable text bytes under an opaque handle.
    /// Callers stage ONLY content they already own inside Swift; this is not
    /// a general file manager and never accepts paths or binary attachments.
    public func stage(_ content: Data) -> StageOutcome {
        guard !content.isEmpty else { return .rejected(.emptyContent) }
        lock.lock()
        defer { lock.unlock() }
        guard blobs.count < Limits.maximumLiveHandles,
              totalBytes + content.count <= Limits.maximumTotalBytes else {
            return .rejected(.contentSaturated)
        }
        let handle = Self.mintHandle()
        let blob = Blob(handle: handle, data: content)
        blobs[handle] = blob
        order.append(handle)
        totalBytes += content.count
        return .staged(handle: handle)
    }

    // MARK: Read

    /// Scalar-safe bounded read. `offset` MUST be a UTF-8 scalar boundary
    /// (the first byte of a scalar, never a continuation byte); the returned
    /// `nextOffset` is always a boundary too, so successive chunks
    /// reassemble byte-exactly and each slice is independently valid UTF-8.
    public func read(handle: String, offset: Int, maxBytes: Int) -> ReadOutcome {
        guard maxBytes >= 0, maxBytes <= Limits.maximumChunkBytes else {
            return .invalidOffset
        }
        lock.lock()
        let blob = blobs[handle]
        lock.unlock()
        guard let blob, blob.isLive else { return .notFound }
        guard offset >= 0, offset <= blob.totalBytes else { return .invalidOffset }
        if offset > 0 {
            // Boundary check: reject continuation bytes at the requested start.
            if let probe = blob.read(offset: offset, length: 1),
               let first = probe.first, (first & 0xC0) == 0x80 {
                return .invalidOffset
            }
        }
        if offset == blob.totalBytes {
            return .slice(bytes: Data(), nextOffset: offset, complete: true)
        }
        // A zero-byte read cannot make progress. Answer typed instead of
        // silently returning content the caller did not budget for.
        guard maxBytes > 0 else { return .invalidOffset }
        let wanted = min(maxBytes, blob.totalBytes - offset)
        guard let window = blob.read(offset: offset, length: max(1, wanted)) else {
            return .notFound
        }
        // Find the largest COMPLETE scalar prefix of the window. A scalar
        // that is cut by the window end (not just by EOF) is never returned:
        // `nextOffset` always names the first byte of a scalar so successive
        // chunks reassemble byte-exactly and each slice is valid UTF-8.
        var end = 0
        var complete = 0
        while end < window.count {
            let lead = window[window.index(window.startIndex, offsetBy: end)]
            let expected: Int
            if lead & 0x80 == 0x00 { expected = 1 }
            else if lead & 0xE0 == 0xC0 { expected = 2 }
            else if lead & 0xF0 == 0xE0 { expected = 3 }
            else if lead & 0xF8 == 0xF0 { expected = 4 }
            else { return .invalidOffset }        // invalid UTF-8 lead byte
            if end + expected > window.count { break }   // incomplete in window
            end += expected
            complete = end
        }
        if complete == 0 {
            // maxBytes was smaller than the next whole scalar. Advance exactly
            // one complete scalar (<=4 bytes) so chunking never livelocks and
            // every slice stays scalar-aligned; the slice stays bounded.
            let probeLimit = min(4, blob.totalBytes - offset)
            guard let probe = blob.read(offset: offset, length: probeLimit),
                  let lead = probe.first else { return .notFound }
            let expected: Int
            if lead & 0x80 == 0x00 { expected = 1 }
            else if lead & 0xE0 == 0xC0 { expected = 2 }
            else if lead & 0xF0 == 0xE0 { expected = 3 }
            else if lead & 0xF8 == 0xF0 { expected = 4 }
            else { return .invalidOffset }
            guard expected <= probe.count else { return .invalidOffset } // truncated scalar
            let bytes = probe.subdata(in: 0..<expected)
            return .slice(bytes: bytes, nextOffset: offset + expected,
                          complete: offset + expected >= blob.totalBytes)
        }
        let bytes = window.subdata(in: 0..<complete)
        return .slice(bytes: bytes, nextOffset: offset + complete,
                      complete: offset + complete >= blob.totalBytes)
    }

    // MARK: Release

    /// Explicit release; also called when the owning generation retires.
    public func release(handle: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let blob = blobs.removeValue(forKey: handle) else { return }
        blob.invalidate()
        order.removeAll { $0 == handle }
        totalBytes = max(0, totalBytes - blob.totalBytes)
    }

    public func retireAll() {
        lock.lock()
        let all = blobs.values
        blobs.removeAll()
        order.removeAll()
        totalBytes = 0
        lock.unlock()
        for blob in all { blob.invalidate() }
    }

    public func statsSnapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "generation": generation,
            "liveHandles": blobs.count,
            "retainedBytes": totalBytes,
        ]
    }

    private static func mintHandle() -> String {
        var hex = ""
        hex.reserveCapacity(Limits.handleHexLength)
        for _ in 0..<16 { hex += String(format: "%02x", UInt8.random(in: 0...255)) }
        return Limits.handlePrefix + hex
    }
}

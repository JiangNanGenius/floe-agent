import Foundation

/// Injected static resources. The real app loads `Resources/BridgeRPC/SKILL.md`
/// and the remote control page; tests inject fixed strings.
/// A missing resource is reported explicitly instead of serving invented copy.
public protocol BridgeRPCResourceProvider: Sendable {
    func skillMarkdown() -> String?
    func remotePageHTML() -> String?
    var remotePageHeaders: [String: String] { get }
}

public extension BridgeRPCResourceProvider {
    var remotePageHeaders: [String: String] { [:] }
}

public struct BridgeRPCEmptyResources: BridgeRPCResourceProvider {
    public init() {}
    public func skillMarkdown() -> String? { nil }
    public func remotePageHTML() -> String? { nil }
}

/// Injected, already-redacted log access. Implementations must never expose raw
/// request text, credentials, pairing keys or full payloads. Returning nil for
/// a channel means that channel is unavailable.
public protocol BridgeRPCLogSource: Sendable {
    func recentLog(limit: Int, matching: String?) -> [String]
    func logFiles() -> [String]?
    func logHistory(date: String?) -> String?
}

public struct BridgeRPCNoLogs: BridgeRPCLogSource {
    public init() {}
    public func recentLog(limit: Int, matching: String?) -> [String] { [] }
    public func logFiles() -> [String]? { nil }
    public func logHistory(date: String?) -> String? { nil }
}

/// One bounded byte stream for a media/debug consumer. This is deliberately
/// outside the JSON envelope path; the ticket authorizes the initial GET only.
public final class BridgeRPCStreamChannel: @unchecked Sendable {
    private let lock = BridgeRPCLock()
    private var outstandingBytes = 0
    private let bufferLimit: Int
    private var finished = false
    private var continuation: AsyncStream<Data>.Continuation?
    private let stream: AsyncStream<Data>

    public init(bufferBytes: Int) {
        self.bufferLimit = max(1, bufferBytes)
        var captured: AsyncStream<Data>.Continuation?
        self.stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { continuation in
            captured = continuation
        }
        self.continuation = captured
    }

    public var sequence: BridgeRPCStreamSequence {
        BridgeRPCStreamSequence(channel: self)
    }

    /// Producer entry point. False means the consumer is gone or the bounded
    /// per-consumer buffer is full; the producer must stop rather than grow it.
    @discardableResult
    public func yield(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        lock.lock()
        guard !finished, outstandingBytes + data.count <= bufferLimit else {
            lock.unlock()
            return false
        }
        outstandingBytes += data.count
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(data)
        return true
    }

    public func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        outstandingBytes = 0
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }

    public func cancel() {
        finish()
    }

    public var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    fileprivate func consumed(_ count: Int) {
        lock.lock()
        outstandingBytes = max(0, outstandingBytes - count)
        lock.unlock()
    }

    fileprivate func makeBaseIterator() -> AsyncStream<Data>.Iterator {
        stream.makeAsyncIterator()
    }
}

public struct BridgeRPCStreamSequence: AsyncSequence, Sendable {
    public typealias Element = Data
    private let channel: BridgeRPCStreamChannel

    init(channel: BridgeRPCStreamChannel) {
        self.channel = channel
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(base: channel.makeBaseIterator(), channel: channel)
    }

    public struct Iterator: AsyncIteratorProtocol {
        private var base: AsyncStream<Data>.Iterator
        private let channel: BridgeRPCStreamChannel

        init(base: AsyncStream<Data>.Iterator, channel: BridgeRPCStreamChannel) {
            self.base = base
            self.channel = channel
        }

        public mutating func next() async -> Data? {
            guard let chunk = await base.next() else { return nil }
            channel.consumed(chunk.count)
            return chunk
        }
    }
}

public struct BridgeRPCStreamGrant: Sendable {
    public let clientID: String
    public let contentType: String
    public let sequence: BridgeRPCStreamSequence
    public let cancel: @Sendable () -> Void
    public let commitToken: BridgeRPCCommitToken

    public init(clientID: String,
                contentType: String,
                sequence: BridgeRPCStreamSequence,
                commitToken: BridgeRPCCommitToken,
                cancel: @escaping @Sendable () -> Void) {
        self.clientID = clientID
        self.contentType = contentType
        self.sequence = sequence
        self.commitToken = commitToken
        self.cancel = cancel
    }
}

/// Host-provided media source. The bridge package ships no fake frames: with
/// no registered source, `/stream` answers 503 stream_unavailable. The real
/// capture/encoder page arrives with a separate package.
public protocol BridgeRPCStreamSource: Sendable {
    var contentType: String { get }
    /// Starts producing into `channel`. Return false when the source is not
    /// ready; the service then answers an explicit unavailable response.
    func openStream(clientID: String, channel: BridgeRPCStreamChannel) async -> Bool
}

// FloeSSH — real SFTP subsystem over the existing Citadel/SwiftNIO SSH
// session (Android port).
//
// This file is transport-only. Stat/read/write/rename use Citadel's public
// SFTP v3 client; bounded directory listing uses a small SFTP v3 decoder
// over a second channel of the same authenticated SSH connection opened with
// a real SSH "sftp" subsystem request. It never runs a shell, launches an
// OpenSSH listing helper, searches for a remote helper program or depends on
// a filesystem path on the server. It never owns task, environment,
// host-profile or credential authority. The caller (C05 SFTP domain)
// supplies the exact path, byte budget and cancellation policy.
//
// The API is additive: `SSHSessionTransport` is unchanged, and only
// `SSHSessionHandle` conforms to `SSHSFTPTransportProviding`. Existing
// PTY/exec/direct-tcpip callers keep their byte-for-byte behavior.
//
// Citadel is pinned at ae8562f895de06ccb86fdb1cbb65fd99c8976e12. Its public
// SFTP client collects the entire directory into one array and does not
// expose the child channel; it is not used for listing. The bounded path
// sends INIT, OPENDIR, one READDIR at a time, stops at maxEntries + 1,
// CLOSEs the directory handle and closes its subsystem channel. Frames and
// the page have explicit byte caps, so a server cannot grow an unbounded
// listing or decoder window.

import Foundation
import Citadel
import FloeCore
import NIOCore

public enum SSHSFTPError: Error, Sendable, LocalizedError, Equatable {
    case notConnected
    case unsupportedByServer
    case invalidPath
    case notFound
    case permissionDenied
    case alreadyExists
    case isDirectory
    case notDirectory
    case fileHandleInvalid
    case connectionLost
    case protocolFailure
    case timeout
    case cancelled
    case transport(String)
    case status(code: UInt32, message: String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "The SSH SFTP channel is not connected."
        case .unsupportedByServer: "The SSH server does not support the SFTP subsystem."
        case .invalidPath: "The remote path is not valid."
        case .notFound: "The remote path does not exist."
        case .permissionDenied: "The SSH account is not allowed to access that remote path."
        case .alreadyExists: "The remote path already exists."
        case .isDirectory: "The remote path is a directory."
        case .notDirectory: "The remote path is not a directory."
        case .fileHandleInvalid: "The remote file handle is no longer valid."
        case .connectionLost: "The SSH/SFTP connection was lost."
        case .protocolFailure: "The SFTP server returned an invalid response."
        case .timeout: "The SFTP operation timed out."
        case .cancelled: "The SFTP operation was cancelled."
        case .transport(let detail): "SFTP transport failed: \(detail)"
        case .status(_, let message): message
        }
    }
}

public struct SSHSFTPAttributes: Sendable, Equatable {
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let size: Int64
    public let modifiedAt: Date?
    public let permissions: UInt32?

    public init(
        isDirectory: Bool,
        isSymbolicLink: Bool,
        size: Int64,
        modifiedAt: Date?,
        permissions: UInt32?
    ) {
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.modifiedAt = modifiedAt
        self.permissions = permissions
    }

    public var isRegularFile: Bool { !isDirectory && !isSymbolicLink }
}

public struct SSHSFTPDirectoryEntry: Sendable, Equatable {
    public let name: String
    public let longName: String?
    public let attributes: SSHSFTPAttributes

    public init(name: String, longName: String?, attributes: SSHSFTPAttributes) {
        self.name = name
        self.longName = longName
        self.attributes = attributes
    }
}

public protocol SSHSFTPReadHandle: Sendable {
    func read(at offset: UInt64, maxBytes: Int) async throws -> Data
    func close() async
}

public protocol SSHSFTPWriteHandle: Sendable {
    func write(_ data: Data, at offset: UInt64) async throws
    func close() async throws
}

/// One SFTP v3 channel owned by a single SSH transport. The caller must
/// close the channel before closing the SSH session; the channel close is
/// awaited by the owning lane.
public protocol SSHSFTPChannel: Sendable {
    var isActive: Bool { get }
    /// Bounded directory read. Implementations must stop at `maxEntries + 1`
    /// entries, close the server handle, and never materialize the whole
    /// remote directory. `maxEntries` is a hard transport bound, not a
    /// post-hoc prefix.
    func listDirectory(at path: String, maxEntries: Int) async throws -> [SSHSFTPDirectoryEntry]
    func stat(path: String) async throws -> SSHSFTPAttributes
    func canonicalPath(_ path: String) async throws -> String
    func openRead(path: String) async throws -> any SSHSFTPReadHandle
    func openWrite(path: String, createNew: Bool) async throws -> any SSHSFTPWriteHandle
    func createDirectory(path: String) async throws
    func removeFile(path: String) async throws
    func removeDirectory(path: String) async throws
    func rename(from: String, to: String) async throws
    func close() async
}

public extension SSHSFTPChannel {
    /// Compatibility convenience for callers that do not need a page bound.
    /// It still uses the bounded implementation; the default ceiling is
    /// deliberately small.
    func listDirectory(at path: String) async throws -> [SSHSFTPDirectoryEntry] {
        try await listDirectory(at: path, maxEntries: 1_000)
    }
}

/// Additive transport seam. `SSHSessionTransport` itself is untouched so
/// all existing fakes/PTY consumers keep compiling; only a real
/// `SSHSessionHandle` conforms and can open the SFTP subsystem.
public protocol SSHSFTPTransportProviding: Sendable {
    func openSFTPChannel() async throws -> any SSHSFTPChannel
}

extension SSHSessionHandle: SSHSFTPTransportProviding {
    public func openSFTPChannel() async throws -> any SSHSFTPChannel {
        guard isConnected else { throw SSHSFTPError.notConnected }
        do {
            let client = try await targetClient.openSFTP()
            return CitadelSFTPChannel(
                client: client,
                listClient: BoundedSFTPSubsystemListClient(sshClient: targetClient)
            )
        } catch let error as SFTPError {
            throw Self.map(error)
        } catch {
            throw SSHSFTPError.transport("SFTP subsystem could not be opened.")
        }
    }

    private static func map(_ error: SFTPError) -> SSHSFTPError {
        switch error {
        case .unsupportedVersion(_):
            return .unsupportedByServer
        case .connectionClosed:
            return .connectionLost
        case .missingResponse:
            return .timeout
        case .fileHandleInvalid:
            return .fileHandleInvalid
        case .errorStatus(let status):
            return CitadelSFTPChannel.map(status)
        case .invalidResponse, .invalidPayload(_), .unknownMessage, .noResponseTarget:
            return .protocolFailure
        }
    }
}

private final class CitadelSFTPChannel: SSHSFTPChannel, @unchecked Sendable {
    private let client: SFTPClient
    private let listClient: BoundedSFTPSubsystemListClient?

    init(client: SFTPClient, listClient: BoundedSFTPSubsystemListClient?) {
        self.client = client
        self.listClient = listClient
    }

    var isActive: Bool { client.isActive }

    func listDirectory(at path: String, maxEntries: Int) async throws -> [SSHSFTPDirectoryEntry] {
        // The pinned Citadel SFTPClient.listDirectory(atPath:) accumulates
        // every READDIR response into one Swift array before returning. No
        // public Citadel API exposes the child channel or a per-entry
        // decoder, so that method cannot be made bounded after the fact.
        // A second channel on the same SSH connection, opened with the real
        // "sftp" subsystem request, runs the bounded SFTP v3 decoder:
        // INIT, OPENDIR, one READDIR at a time, stop at maxEntries + 1,
        // CLOSE the handle, close the channel. No shell or remote helper
        // participates, so protocol-only SFTP servers work as well.
        guard let listClient else {
            throw SSHSFTPError.unsupportedByServer
        }
        return try await listClient.listDirectory(at: path, maxEntries: maxEntries)
    }

    func stat(path: String) async throws -> SSHSFTPAttributes {
        do {
            return Self.attributes(try await client.getAttributes(at: path))
        } catch let error as SFTPError {
            throw Self.map(error)
        } catch {
            throw Self.mapTransport(error)
        }
    }

    func canonicalPath(_ path: String) async throws -> String {
        do {
            return try await client.getRealPath(atPath: path)
        } catch let error as SFTPError {
            throw Self.map(error)
        } catch {
            throw Self.mapTransport(error)
        }
    }

    func openRead(path: String) async throws -> any SSHSFTPReadHandle {
        do {
            let file = try await client.openFile(filePath: path, flags: .read)
            return CitadelSFTPReadHandle(file: file)
        } catch let error as SFTPError {
            throw Self.map(error)
        } catch {
            throw Self.mapTransport(error)
        }
    }

    func openWrite(path: String, createNew: Bool) async throws -> any SSHSFTPWriteHandle {
        do {
            var flags: SFTPOpenFileFlags = [.write, .create]
            if createNew { flags.insert(.forceCreate) }
            let file = try await client.openFile(filePath: path, flags: flags)
            return CitadelSFTPWriteHandle(file: file)
        } catch let error as SFTPError {
            throw Self.map(error)
        } catch {
            throw Self.mapTransport(error)
        }
    }

    func createDirectory(path: String) async throws {
        do {
            try await client.createDirectory(atPath: path)
        } catch let error as SFTPError {
            throw Self.map(error)
        } catch {
            throw Self.mapTransport(error)
        }
    }

    func removeFile(path: String) async throws {
        do {
            try await client.remove(at: path)
        } catch let error as SFTPError {
            throw Self.map(error)
        } catch {
            throw Self.mapTransport(error)
        }
    }

    func removeDirectory(path: String) async throws {
        do {
            try await client.rmdir(at: path)
        } catch let error as SFTPError {
            throw Self.map(error)
        } catch {
            throw Self.mapTransport(error)
        }
    }

    func rename(from: String, to: String) async throws {
        do {
            try await client.rename(at: from, to: to)
        } catch let error as SFTPError {
            throw Self.map(error)
        } catch {
            throw Self.mapTransport(error)
        }
    }

    func close() async {
        try? await client.close()
    }

    private static func attributes(_ value: SFTPFileAttributes) -> SSHSFTPAttributes {
        let mode = value.permissions
        let type = mode.map { $0 & 0xF000 }
        return SSHSFTPAttributes(
            isDirectory: type == 0x4000,
            isSymbolicLink: type == 0xA000,
            size: Int64(clamping: value.size ?? 0),
            modifiedAt: value.accessModificationTime?.modificationTime,
            permissions: mode
        )
    }

    static func map(_ status: SFTPMessage.Status) -> SSHSFTPError {
        let message = String(status.message.prefix(160))
        switch status.errorCode {
        case .noSuchFile:
            return .notFound
        case .permissionDenied:
            return .permissionDenied
        case .failure:
            return .status(code: status.errorCode.rawValue, message: message.isEmpty ? "SFTP operation failed." : message)
        case .badMessage:
            return .protocolFailure
        case .noConnection, .connectionLost:
            return .connectionLost
        case .unsupportedOperation:
            return .unsupportedByServer
        case .ok, .eof:
            return .protocolFailure
        case .unknown(let code):
            return .status(code: code, message: message.isEmpty ? "SFTP server rejected the operation." : message)
        }
    }

    static func map(_ error: SFTPError) -> SSHSFTPError {
        if let converted = error as? SSHSFTPError { return converted }
        switch error {
        case .unsupportedVersion(_): return .unsupportedByServer
        case .connectionClosed: return .connectionLost
        case .missingResponse: return .timeout
        case .fileHandleInvalid: return .fileHandleInvalid
        case .errorStatus(let status): return map(status)
        case .invalidResponse, .invalidPayload(_), .unknownMessage, .noResponseTarget:
            return .protocolFailure
        }
    }

    static func mapTransport(_ error: Error) -> SSHSFTPError {
        if let converted = error as? SSHSFTPError { return converted }
        if error is CancellationError { return .cancelled }
        let text = String(describing: error)
        return .transport(String(text.prefix(200)))
    }
}

private final class CitadelSFTPReadHandle: SSHSFTPReadHandle, @unchecked Sendable {
    private let file: SFTPFile
    private let lock = NSLock()
    private var closed = false

    init(file: SFTPFile) {
        self.file = file
    }

    func read(at offset: UInt64, maxBytes: Int) async throws -> Data {
        let isClosed = lock.withLock { closed }
        guard !isClosed else { throw SSHSFTPError.fileHandleInvalid }
        guard maxBytes > 0 else { return Data() }
        do {
            let buffer = try await file.read(
                from: offset,
                length: UInt32(min(maxBytes, 32 * 1_024))
            )
            return Data(buffer.readableBytesView)
        } catch let error as SFTPError {
            throw CitadelSFTPChannel.map(error)
        } catch {
            throw CitadelSFTPChannel.mapTransport(error)
        }
    }

    func close() async {
        let shouldClose = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        try? await file.close()
    }
}

private final class CitadelSFTPWriteHandle: SSHSFTPWriteHandle, @unchecked Sendable {
    private let file: SFTPFile
    private let lock = NSLock()
    private var closed = false

    init(file: SFTPFile) {
        self.file = file
    }

    func write(_ data: Data, at offset: UInt64) async throws {
        let isClosed = lock.withLock { closed }
        guard !isClosed else { throw SSHSFTPError.fileHandleInvalid }
        do {
            try await file.write(ByteBuffer(bytes: data), at: offset)
        } catch let error as SFTPError {
            throw CitadelSFTPChannel.map(error)
        } catch {
            throw CitadelSFTPChannel.mapTransport(error)
        }
    }

    func close() async throws {
        let shouldClose = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        do {
            try await file.close()
        } catch let error as SFTPError {
            throw CitadelSFTPChannel.map(error)
        } catch {
            throw CitadelSFTPChannel.mapTransport(error)
        }
    }
}

// MARK: - Bounded SFTP subsystem listing

/// The pinned Citadel revision's public `SFTPClient.listDirectory` returns
/// the complete server-side directory as an array and its channel/decoder
/// are internal. This client opens the standard `sftp` SSH subsystem on a
/// second child channel of the same authenticated connection (a real
/// `SSH_MSG_CHANNEL_REQUEST` "subsystem" request) and speaks only the SFTP
/// v3 subset needed for one bounded directory page. It never runs a shell,
/// never launches a remote listing helper and never depends on one, so
/// protocol-only, `internal-sftp` and Windows SFTP servers work
/// the same way.
private final class BoundedSFTPSubsystemListClient: @unchecked Sendable {
    private let sshClient: SSHClient

    init(sshClient: SSHClient) {
        self.sshClient = sshClient
    }

    func listDirectory(
        at path: String,
        maxEntries: Int
    ) async throws -> [SSHSFTPDirectoryEntry] {
        let bounded = max(1, min(maxEntries, 10_000))
        let channel: Channel
        do {
            channel = try await sshClient.openSFTPSubsystemChannel()
        } catch let error as SSHSubsystemError {
            switch error {
            case .subsystemRejected:
                throw SSHSFTPError.unsupportedByServer
            case .timeout:
                throw SSHSFTPError.timeout
            case .connectionClosed:
                throw SSHSFTPError.connectionLost
            case .channelCreationFailed:
                throw SSHSFTPError.transport(
                    "The SSH server could not open an SFTP subsystem channel.")
            }
        } catch let error as SFTPError {
            throw CitadelSFTPChannel.map(error)
        } catch is CancellationError {
            throw SSHSFTPError.cancelled
        } catch {
            throw CitadelSFTPChannel.mapTransport(error)
        }

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(8))
        do {
            try await channel.pipeline.addHandler(
                SFTPByteChannelHandler(continuation: continuation)
            )
        } catch {
            continuation.finish()
            try? await channel.close()
            throw CitadelSFTPChannel.mapTransport(error)
        }

        let transport = NIOSFTPByteTransport(
            channel: channel,
            stream: stream,
            continuation: continuation
        )
        do {
            let entries = try await BoundedSFTPSubsystemListSession(transport: transport)
                .list(path: path, maxEntries: bounded)
            await transport.close()
            return entries
        } catch {
            await transport.close()
            if let ftpError = error as? SSHSFTPError { throw ftpError }
            if error is CancellationError { throw SSHSFTPError.cancelled }
            throw CitadelSFTPChannel.mapTransport(error)
        }
    }
}

/// Byte-level view of one open subsystem channel. The listing session only
/// depends on this seam, so its frame, page, cancellation and timeout
/// behavior is covered by deterministic tests without a real SSH server.
protocol BoundedSFTPByteTransport: Sendable {
    func write(_ data: Data) async throws
    /// Next inbound chunk, or nil once the channel closed.
    func read() async throws -> Data?
    func close() async
}

/// One real `sftp` subsystem child channel. The listing session is the
/// single consumer of `read()` and the single caller of `close()`, so no
/// lock is required; the stream continuation and NIO channel are themselves
/// thread-safe.
private final class NIOSFTPByteTransport: BoundedSFTPByteTransport, @unchecked Sendable {
    private let channel: Channel
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator
    private var closed = false

    init(
        channel: Channel,
        stream: AsyncThrowingStream<Data, Error>,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) {
        self.channel = channel
        self.continuation = continuation
        self.iterator = stream.makeAsyncIterator()
    }

    func write(_ data: Data) async throws {
        try await channel.writeAndFlush(ByteBuffer(bytes: data))
    }

    func read() async throws -> Data? {
        try await iterator.next()
    }

    func close() async {
        guard !closed else { return }
        closed = true
        continuation.finish()
        try? await channel.close()
    }
}

final class SFTPByteChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        // Bound the queue before the async decoder can consume it. A slow
        // consumer must fail closed instead of accumulating peer traffic.
        guard buffer.readableBytes <= 256 * 1024 + 4 else {
            continuation.finish(throwing: SSHSFTPError.protocolFailure)
            context.close(promise: nil)
            return
        }
        switch continuation.yield(Data(buffer.readableBytesView)) {
        case .enqueued: break
        case .dropped:
            continuation.finish(throwing: SSHSFTPError.protocolFailure)
            context.close(promise: nil)
        case .terminated:
            context.close(promise: nil)
        @unknown default:
            continuation.finish(throwing: SSHSFTPError.protocolFailure)
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }
}

/// One bounded SFTP v3 directory page over a real `sftp` subsystem.
///
/// The session owns the protocol cursor: INIT, a single OPENDIR, one
/// READDIR at a time, stop at `maxEntries + 1`, and CLOSE on the success
/// path. Every frame is capped before it is accepted, the received stream
/// and returned page carry explicit byte caps, and each inbound wait has a
/// cancellation-aware timeout. It never requests or buffers a complete
/// directory, and no shell/exec channel participates.
final class BoundedSFTPSubsystemListSession: @unchecked Sendable {
    static let defaultMaximumFrameBytes = 256 * 1_024
    static let defaultMaximumListingBytes = 4 * 1_024 * 1_024
    static let defaultPacketTimeoutNanoseconds: UInt64 = 20_000_000_000

    private let transport: any BoundedSFTPByteTransport
    private let maximumFrameBytes: Int
    private let maximumListingBytes: Int
    private let packetTimeoutNanoseconds: UInt64
    private var buffer = Data()
    private var receivedBytes = 0
    private var nextRequestID: UInt32 = 1

    init(
        transport: any BoundedSFTPByteTransport,
        maximumFrameBytes: Int = BoundedSFTPSubsystemListSession.defaultMaximumFrameBytes,
        maximumListingBytes: Int = BoundedSFTPSubsystemListSession.defaultMaximumListingBytes,
        packetTimeoutNanoseconds: UInt64 = BoundedSFTPSubsystemListSession.defaultPacketTimeoutNanoseconds
    ) {
        self.transport = transport
        self.maximumFrameBytes = max(1, maximumFrameBytes)
        self.maximumListingBytes = max(1, maximumListingBytes)
        self.packetTimeoutNanoseconds = packetTimeoutNanoseconds
    }

    func list(
        path: String,
        maxEntries: Int
    ) async throws -> [SSHSFTPDirectoryEntry] {
        guard !Task.isCancelled else { throw SSHSFTPError.cancelled }
        try await initialize()

        let openID = allocateID()
        try await send(type: 11, requestID: openID, body: Self.string(path))
        let open = try await response(for: openID)
        guard open.type == 102 else {
            throw Self.statusError(open)
        }
        let handle = try Self.readBytes(open.body)

        var entries: [SSHSFTPDirectoryEntry] = []
        let hardLimit = max(1, maxEntries) + 1
        while entries.count < hardLimit {
            guard !Task.isCancelled else { throw SSHSFTPError.cancelled }
            let readID = allocateID()
            try await send(type: 12, requestID: readID, body: Self.bytes(handle))
            let packet = try await response(for: readID)
            if packet.type == 101 {
                if try Self.statusCode(packet) == 1 { break } // SSH_FX_EOF
                throw Self.statusError(packet)
            }
            guard packet.type == 104 else {
                throw SSHSFTPError.protocolFailure
            }
            let parsed = try Self.readName(packet.body)
            for entry in parsed {
                if entries.count >= hardLimit { break }
                entries.append(entry)
            }
            if parsed.isEmpty { break }
        }

        // Real directory-handle close; the subsystem channel close below is
        // not a substitute for releasing the server-side handle.
        let closeID = allocateID()
        try await send(type: 4, requestID: closeID, body: Self.bytes(handle))
        let close = try await response(for: closeID)
        guard close.type == 101, try Self.statusCode(close) == 0 else {
            throw SSHSFTPError.protocolFailure
        }
        guard !Task.isCancelled else { throw SSHSFTPError.cancelled }
        return entries
    }

    private func initialize() async throws {
        try await send(type: 1, requestID: nil, body: Self.uint32(3))
        let version = try await readPacket()
        guard version.type == 2 else {
            throw SSHSFTPError.protocolFailure
        }
        guard let value = Self.readUInt32(version.body), value >= 3 else {
            throw SSHSFTPError.unsupportedByServer
        }
    }

    private func send(
        type: UInt8,
        requestID: UInt32?,
        body: Data
    ) async throws {
        var payload = Data()
        payload.append(type)
        if let requestID {
            payload.append(Self.uint32(requestID))
        }
        payload.append(body)
        var frame = Data()
        frame.append(Self.uint32(UInt32(payload.count)))
        frame.append(payload)
        do {
            try await transport.write(frame)
        } catch is CancellationError {
            throw SSHSFTPError.cancelled
        } catch {
            throw SSHSFTPError.connectionLost
        }
    }

    private func response(for requestID: UInt32) async throws -> (type: UInt8, body: Data) {
        while true {
            let packet = try await readPacket()
            guard packet.body.count >= 4,
                  let id = Self.readUInt32(packet.body),
                  id == requestID else {
                continue
            }
            return (packet.type, Data(packet.body.dropFirst(4)))
        }
    }

    private func readPacket() async throws -> (type: UInt8, body: Data) {
        while true {
            if buffer.count >= 4 {
                guard let length = Self.readUInt32(buffer) else { break }
                guard length >= 1, length <= UInt32(maximumFrameBytes) else {
                    throw SSHSFTPError.protocolFailure
                }
                let total = 4 + Int(length)
                if buffer.count >= total {
                    let type = buffer[buffer.startIndex + 4]
                    let body = buffer.subdata(in: 5..<total)
                    buffer.removeSubrange(0..<total)
                    return (type, body)
                }
            }
            // A declared frame may never exceed maximumFrameBytes, so an
            // incomplete buffer above this bound cannot become a valid
            // frame. This caps the decoder window even if the peer keeps
            // sending bytes.
            if buffer.count > maximumFrameBytes + 4 {
                throw SSHSFTPError.protocolFailure
            }
            guard let chunk = try await readChunk() else {
                if Task.isCancelled { throw SSHSFTPError.cancelled }
                throw SSHSFTPError.connectionLost
            }
            receivedBytes += chunk.count
            guard receivedBytes <= maximumListingBytes else {
                throw SSHSFTPError.protocolFailure
            }
            buffer.append(chunk)
        }
        // Unreachable: the only exit from the loop is a return or a throw.
        throw SSHSFTPError.protocolFailure
    }

    private func readChunk() async throws -> Data? {
        let transport = self.transport
        let timeout = packetTimeoutNanoseconds
        return try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                try await transport.read()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeout)
                throw SSHSFTPError.timeout
            }
            defer { group.cancelAll() }
            guard let chunk = try await group.next() else { return nil }
            return chunk
        }
    }

    private func allocateID() -> UInt32 {
        defer { nextRequestID &+= 1 }
        return nextRequestID
    }

    private static func uint32(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return Data(bytes: &bigEndian, count: 4)
    }

    private static func string(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        var result = uint32(UInt32(bytes.count))
        result.append(bytes)
        return result
    }

    private static func readUInt32(_ data: Data) -> UInt32? {
        guard data.count >= 4 else { return nil }
        return data.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func bytes(_ data: Data) -> Data {
        var result = uint32(UInt32(data.count))
        result.append(data)
        return result
    }

    private static func readBytes(_ data: Data) throws -> Data {
        guard let length = readUInt32(data), data.count >= 4 + Int(length) else {
            throw SSHSFTPError.protocolFailure
        }
        return data.subdata(in: 4..<(4 + Int(length)))
    }

    private static func readString(_ data: Data) throws -> String {
        guard let length = readUInt32(data), data.count >= 4 + Int(length),
              let value = String(data: data.subdata(in: 4..<(4 + Int(length))), encoding: .utf8) else {
            throw SSHSFTPError.protocolFailure
        }
        return value
    }

    private static func readName(_ data: Data) throws -> [SSHSFTPDirectoryEntry] {
        guard let count = readUInt32(data) else {
            throw SSHSFTPError.protocolFailure
        }
        var cursor = 4
        var entries: [SSHSFTPDirectoryEntry] = []
        for _ in 0..<count {
            guard cursor + 4 <= data.count else { throw SSHSFTPError.protocolFailure }
            let nameLength = Int(data[cursor..<cursor + 4].reduce(0) { ($0 << 8) | UInt32($1) })
            cursor += 4
            guard nameLength >= 0, cursor + nameLength <= data.count else {
                throw SSHSFTPError.protocolFailure
            }
            let name = String(data: data[cursor..<cursor + nameLength], encoding: .utf8) ?? ""
            cursor += nameLength
            guard cursor + 4 <= data.count else { throw SSHSFTPError.protocolFailure }
            let longLength = Int(data[cursor..<cursor + 4].reduce(0) { ($0 << 8) | UInt32($1) })
            cursor += 4
            guard cursor + longLength <= data.count else { throw SSHSFTPError.protocolFailure }
            let longName = String(data: data[cursor..<cursor + longLength], encoding: .utf8)
            cursor += longLength
            guard cursor + 4 <= data.count else { throw SSHSFTPError.protocolFailure }
            let flags = data[cursor..<cursor + 4].reduce(0) { ($0 << 8) | UInt32($1) }
            cursor += 4
            var size: UInt64 = 0
            var permissions: UInt32?
            var modifiedAt: Date?
            if flags & 0x1 != 0 {
                guard cursor + 8 <= data.count else { throw SSHSFTPError.protocolFailure }
                size = data[cursor..<cursor + 8].reduce(0) { ($0 << 8) | UInt64($1) }
                cursor += 8
            }
            if flags & 0x2 != 0 {
                guard cursor + 8 <= data.count else { throw SSHSFTPError.protocolFailure }
                cursor += 8
            }
            if flags & 0x4 != 0 {
                guard cursor + 4 <= data.count else { throw SSHSFTPError.protocolFailure }
                permissions = UInt32(data[cursor..<cursor + 4].reduce(0) { ($0 << 8) | UInt32($1) })
                cursor += 4
            }
            if flags & 0x8 != 0 {
                guard cursor + 8 <= data.count else { throw SSHSFTPError.protocolFailure }
                let seconds = UInt32(data[cursor + 4..<cursor + 8].reduce(0) { ($0 << 8) | UInt32($1) })
                cursor += 8
                modifiedAt = Date(timeIntervalSince1970: TimeInterval(seconds))
            }
            if flags & 0x80000000 != 0 {
                guard cursor + 4 <= data.count else { throw SSHSFTPError.protocolFailure }
                let pairs = Int(data[cursor..<cursor + 4].reduce(0) { ($0 << 8) | UInt32($1) })
                cursor += 4
                for _ in 0..<pairs {
                    guard cursor + 4 <= data.count else { throw SSHSFTPError.protocolFailure }
                    let keyLength = Int(data[cursor..<cursor + 4].reduce(0) { ($0 << 8) | UInt32($1) })
                    cursor += 4 + keyLength
                    guard cursor + 4 <= data.count else { throw SSHSFTPError.protocolFailure }
                    let valueLength = Int(data[cursor..<cursor + 4].reduce(0) { ($0 << 8) | UInt32($1) })
                    cursor += 4 + valueLength
                    guard cursor <= data.count else { throw SSHSFTPError.protocolFailure }
                }
            }
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            let modeType = permissions.map { $0 & 0xF000 }
            entries.append(SSHSFTPDirectoryEntry(
                name: name,
                longName: longName,
                attributes: SSHSFTPAttributes(
                    isDirectory: modeType == 0x4000,
                    isSymbolicLink: modeType == 0xA000,
                    size: Int64(clamping: size),
                    modifiedAt: modifiedAt,
                    permissions: permissions
                )
            ))
        }
        return entries
    }

    private static func statusCode(_ packet: (type: UInt8, body: Data)) throws -> UInt32 {
        guard packet.body.count >= 8, let code = readUInt32(packet.body) else {
            throw SSHSFTPError.protocolFailure
        }
        return code
    }

    private static func statusError(_ packet: (type: UInt8, body: Data)) -> SSHSFTPError {
        guard packet.body.count >= 8, let code = readUInt32(packet.body) else {
            return .protocolFailure
        }
        let message = (try? readString(Data(packet.body.dropFirst(4)))) ?? ""
        return SSHSFTPError.status(
            code: code,
            message: message.isEmpty ? "SFTP server rejected the operation." : String(message.prefix(160))
        )
    }
}

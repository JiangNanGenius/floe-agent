// FloeSSH — device-local loopback TCP forwarder over an SSH direct-tcpip
// channel (Android port).
//
// The public donor used Network.framework behind `#if canImport(Network)`.
// Android has no Network.framework, so this port uses the SAME pinned
// SwiftNIO package Citadel already requires (NIOPosix): a real
// ServerBootstrap bound to 127.0.0.1 only, real accepted sockets, real
// bidirectional pumping and an awaited listener/child shutdown.
//
// Contract:
//  * the listener binds 127.0.0.1 with port 0 (OS-assigned); no Wi-Fi or
//    external interface is ever exposed;
//  * each accepted local connection opens its own SSH direct-tcpip channel
//    to the target seen by the SSH server;
//  * counters describe observed bytes/connections, not configured intent;
//  * `close()` closes the listener and every child/channel and awaits the
//    NIO close futures; an unexpected listener death surfaces as
//    `isListening == false`, never as "stopped".

import Foundation
import FloeCore
import NIOCore
import NIOPosix

public final class LoopbackSSHForwarder: @unchecked Sendable {
    public struct Endpoint: Sendable, Hashable {
        public let host: String
        public let port: UInt16
    }

    public struct Snapshot: Sendable, Equatable {
        public let endpoint: Endpoint?
        public let isListening: Bool
        public let acceptedConnections: Int
        public let activeConnections: Int
        public let bytesToRemote: Int64
        public let bytesFromRemote: Int64
        public let lastErrorCode: String?
    }

    private let server: Channel
    private let hub: ConnectionHub
    private let lock = NSLock()
    private var closed = false
    private var listenerClosed = false
    private var acceptedConnections = 0
    private var activeConnections = 0
    private var bytesToRemote: Int64 = 0
    private var bytesFromRemote: Int64 = 0
    private var lastErrorCode: String?

    private init(server: Channel, hub: ConnectionHub) {
        self.server = server
        self.hub = hub
        let owner = self
        hub.onAccepted = { [weak owner] in owner?.noteAccepted() }
        hub.onActiveChanged = { [weak owner] delta in owner?.noteActive(delta) }
        hub.onBytesToRemote = { [weak owner] count in owner?.noteToRemote(count) }
        hub.onBytesFromRemote = { [weak owner] count in owner?.noteFromRemote(count) }
        hub.onError = { [weak owner] code in owner?.noteError(code) }
        server.closeFuture.whenComplete { [weak owner] _ in owner?.noteListenerClosed() }
    }

    public var endpoint: Endpoint? {
        guard let address = server.localAddress, let port = address.port,
              let value = UInt16(exactly: port) else { return nil }
        return Endpoint(host: "127.0.0.1", port: value)
    }

    public var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            endpoint: endpoint,
            isListening: !closed && !listenerClosed && server.isActive,
            acceptedConnections: acceptedConnections,
            activeConnections: activeConnections,
            bytesToRemote: bytesToRemote,
            bytesFromRemote: bytesFromRemote,
            lastErrorCode: lastErrorCode
        )
    }

    public static func start(
        session: any SSHSessionTransport,
        targetHost: String,
        targetPort: Int,
        group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> LoopbackSSHForwarder {
        guard !targetHost.isEmpty, targetHost.utf8.count <= 255,
              (1...65535).contains(targetPort) else {
            throw FloeError.validationFailed("Invalid tunnel target")
        }
        let hub = ConnectionHub(session: session, targetHost: targetHost, targetPort: targetPort)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                hub.accept(channel)
            }
        let server = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return LoopbackSSHForwarder(server: server, hub: hub)
    }

    public func close() async {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()

        server.close(promise: nil)
        do {
            try await server.closeFuture.get()
        } catch {
            noteError("listenerCloseFailed")
        }
        await hub.closeAll()
        noteListenerClosed()
    }

    private func noteAccepted() {
        lock.lock(); acceptedConnections += 1; activeConnections += 1; lock.unlock()
    }

    private func noteActive(_ delta: Int) {
        lock.lock(); activeConnections = max(0, activeConnections + delta); lock.unlock()
    }

    private func noteToRemote(_ count: Int) {
        lock.lock(); bytesToRemote += Int64(count); lock.unlock()
    }

    private func noteFromRemote(_ count: Int) {
        lock.lock(); bytesFromRemote += Int64(count); lock.unlock()
    }

    private func noteError(_ code: String) {
        lock.lock()
        if lastErrorCode == nil { lastErrorCode = String(code.prefix(32)) }
        lock.unlock()
    }

    private func noteListenerClosed() {
        lock.lock(); listenerClosed = true; lock.unlock()
    }
}

/// Owns accepted local channels and their SSH direct-tcpip channels. The
/// class is shared by the listener's child initializer and `close()`, so the
/// close path can really await every owned resource.
private final class ConnectionHub: @unchecked Sendable {
    private let session: any SSHSessionTransport
    private let targetHost: String
    private let targetPort: Int
    private let lock = NSLock()
    private var children: [UUID: Channel] = [:]
    private var channels: [UUID: any SSHSessionByteChannel] = [:]
    private var closed = false

    var onAccepted: (@Sendable () -> Void)?
    var onActiveChanged: (@Sendable (Int) -> Void)?
    var onBytesToRemote: (@Sendable (Int) -> Void)?
    var onBytesFromRemote: (@Sendable (Int) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    init(session: any SSHSessionTransport, targetHost: String, targetPort: Int) {
        self.session = session
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    func accept(_ channel: Channel) -> EventLoopFuture<Void> {
        let id = UUID()
        lock.lock()
        if closed {
            lock.unlock()
            channel.close(promise: nil)
            return channel.eventLoop.makeSucceededVoidFuture()
        }
        children[id] = channel
        lock.unlock()

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        return channel.pipeline.addHandler(LocalInboundHandler(continuation: continuation)).map {
            self.onAccepted?()
            Task {
                await self.run(id: id, channel: channel, local: stream, continuation: continuation)
            }
        }
    }

    func closeAll() async {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let childSnapshot = children
        let channelSnapshot = channels
        children.removeAll()
        channels.removeAll()
        lock.unlock()

        for channel in childSnapshot.values { channel.close(promise: nil) }
        for channel in channelSnapshot.values { await channel.close() }
        await withTaskGroup(of: Void.self) { group in
            for channel in childSnapshot.values {
                group.addTask {
                    try? await channel.closeFuture.get()
                }
            }
            await group.waitForAll()
        }
    }

    private func run(
        id: UUID,
        channel: Channel,
        local: AsyncThrowingStream<Data, Error>,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async {
        do {
            let sshChannel = try await session.openDirectTCPIP(host: targetHost, port: targetPort)
            lock.lock()
            if closed {
                lock.unlock()
                await sshChannel.close()
                channel.close(promise: nil)
                return
            }
            channels[id] = sshChannel
            lock.unlock()

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await self.pumpLocalToSSH(local: local, ssh: sshChannel)
                }
                group.addTask {
                    await self.pumpSSHToLocal(ssh: sshChannel, local: channel)
                }
                await group.next()
                await sshChannel.close()
                channel.close(promise: nil)
                group.cancelAll()
                await group.waitForAll()
            }
        } catch {
            onError?("channelFailed")
            continuation.finish(throwing: error)
            channel.close(promise: nil)
        }

        lock.lock()
        channels.removeValue(forKey: id)
        children.removeValue(forKey: id)
        lock.unlock()
        onActiveChanged?(-1)
    }

    private func pumpLocalToSSH(
        local: AsyncThrowingStream<Data, Error>,
        ssh: any SSHSessionByteChannel
    ) async {
        do {
            for try await data in local {
                guard !data.isEmpty else { continue }
                try await ssh.write(data)
                onBytesToRemote?(data.count)
            }
            await ssh.close()
        } catch {
            onError?("localReadFailed")
            await ssh.close()
        }
    }

    private func pumpSSHToLocal(
        ssh: any SSHSessionByteChannel,
        local: Channel
    ) async {
        do {
            for try await data in ssh.inbound {
                guard !data.isEmpty else { continue }
                try await local.writeAndFlush(ByteBuffer(bytes: data)).get()
                onBytesFromRemote?(data.count)
            }
            local.close(promise: nil)
        } catch {
            onError?("remoteReadFailed")
            local.close(promise: nil)
        }
    }
}

private final class LocalInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        continuation.yield(Data(buffer.readableBytesView))
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

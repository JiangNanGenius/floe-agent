import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOSSH
import FloeToolboxCore
import FloeToolboxRemoteFiles

/// Install on a dedicated authenticated SSH session child. Stderr is never mixed with SFTP.
private final class BoundedSSHFileInput: ChannelInboundHandler,@unchecked Sendable {
    typealias InboundIn = SSHChannelData
    private weak var context: ChannelHandlerContext?
    private var bytes = Data(), stderrBytes = 0
    private var closed = false
    private var pending: (EventLoopPromise<Data>,Int)?
    private var timer: Scheduled<Void>?
    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func handlerRemoved(context: ChannelHandlerContext) { fail(RemoteFileError.connectionClosed); self.context = nil }
    func channelRead(context: ChannelHandlerContext,data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { fail(RemoteFileError.malformedResponse); context.close(promise:nil); return }
        if message.type == .stdErr {
            stderrBytes += buffer.readableBytes
            if stderrBytes > 8192 { fail(RemoteFileError.limit); context.close(promise:nil) }; return
        }
        guard message.type == .channel, bytes.count+buffer.readableBytes <= 2*1024*1024 else { fail(RemoteFileError.limit); context.close(promise:nil); return }
        bytes.append(contentsOf:buffer.readableBytesView); deliver()
    }
    func channelReadComplete(context: ChannelHandlerContext) { if pending != nil { context.read() } }
    func channelInactive(context: ChannelHandlerContext) { fail(RemoteFileError.connectionClosed); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext,error: any Error) { fail(RemoteFileError.connectionClosed); context.close(promise:nil) }
    private func deliver() {
        guard !bytes.isEmpty, let (promise,maximum) = pending else { return }
        pending = nil; timer?.cancel(); timer = nil
        let result = Data(bytes.prefix(maximum)); bytes.removeFirst(result.count); promise.succeed(result)
    }
    private func fail(_ error: any Error) {
        closed = true; timer?.cancel(); timer = nil
        if let (promise,_) = pending { pending = nil; promise.fail(error) }
    }
    func read(maximum: Int,on channel: any Channel) -> EventLoopFuture<Data> {
        channel.eventLoop.preconditionInEventLoop()
        guard pending == nil else { return channel.eventLoop.makeFailedFuture(RemoteFileError.busy) }
        guard !bytes.isEmpty || !closed else { return channel.eventLoop.makeFailedFuture(RemoteFileError.connectionClosed) }
        let promise = channel.eventLoop.makePromise(of:Data.self); pending = (promise,maximum)
        if !bytes.isEmpty { deliver() }
        else {
            timer = channel.eventLoop.scheduleTask(in:.seconds(30)) { [self] in fail(RemoteFileError.connectionClosed); channel.close(promise:nil) }
            context?.read()
        }
        return promise.futureResult
    }
}

public actor SSHRemoteFileByteChannel: RemoteFileByteChannel {
    private let channel: any Channel
    private let input: BoundedSSHFileInput
    private var closed = false,sending = false,reading = false
    private init(channel: any Channel,input: BoundedSSHFileInput) { self.channel = channel; self.input = input }
    /// The opener uses the host's already authenticated session and runs initialize before
    /// issuing the subsystem/exec request. No parent SSH client is owned or closed here.
    public static func open(_ opener: @Sendable (@escaping @Sendable (any Channel) -> EventLoopFuture<Void>) async throws -> any Channel) async throws -> SSHRemoteFileByteChannel {
        let input = BoundedSSHFileInput()
        let channel = try await opener { channel in channel.setOption(ChannelOptions.autoRead,value:false).flatMap { channel.pipeline.addHandler(input) } }
        if Task.isCancelled { try? await channel.close(); throw CancellationError() }
        return SSHRemoteFileByteChannel(channel:channel,input:input)
    }
    public func send(_ bytes: Data) async throws {
        guard !closed, !sending, bytes.count <= 1024*1024 else { throw RemoteFileError.busy }; sending = true; defer { sending = false }
        let channel = channel
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await channel.writeAndFlush(SSHChannelData(type:.channel,data:.byteBuffer(ByteBuffer(bytes:bytes))))
            guard !closed else { throw RemoteFileError.connectionClosed }
        } onCancel: { channel.close(promise:nil) }
    }
    public func receive(maximumBytes: Int) async throws -> Data {
        guard !closed, !reading, (1...1024*1024).contains(maximumBytes) else { throw RemoteFileError.busy }; reading = true; defer { reading = false }
        let channel = channel,input = input
        return try await withTaskCancellationHandler {
            try Task.checkCancellation(); return try await channel.eventLoop.flatSubmit { input.read(maximum:maximumBytes,on:channel) }.get()
        } onCancel: { channel.close(promise:nil) }
    }
    public func close() async { guard !closed else { return }; closed = true; try? await channel.close() }
    deinit { channel.close(promise:nil) }
}

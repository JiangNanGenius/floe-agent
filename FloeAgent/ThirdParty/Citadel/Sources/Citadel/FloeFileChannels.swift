// Compile this additive source inside pinned Citadel ae8562f895de06ccb86fdb1cbb65fd99c8976e12.
// It uses the existing authenticated session; no credentials, host-key policy or reconnect registry.
import Foundation
import NIOCore
import NIOSSH

public enum FloeSSHFileChannelRequest: Sendable {
    case sftp
    case scpUpload(path: String)
    case scpDownload(path: String)
    fileprivate func validate() throws {
        switch self {
        case .sftp: return
        case .scpUpload(let path),.scpDownload(let path):
            guard path.hasPrefix("/"), path.utf8.count <= 32768, !path.utf8.contains(where:{[0,10,13].contains($0)}) else { throw FloeSSHFileChannelError.invalidPath }
        }
    }
    fileprivate var command: String? {
        let direction: String,path: String
        switch self { case .sftp: return nil; case .scpUpload(let value): direction = "-t"; path = value; case .scpDownload(let value): direction = "-f"; path = value }
        return "scp "+direction+" -- '"+path.replacingOccurrences(of:"'",with:"'\\''")+"'"
    }
}
public enum FloeSSHFileChannelError: Error,Sendable { case invalidPath,timedOut,cancelled }
private final class FloeFileChannelOpen: @unchecked Sendable {
    let loop: any EventLoop
    let promise: EventLoopPromise<any Channel>
    var channel: (any Channel)?
    var finished = false
    var timer: Scheduled<Void>?
    init(loop: any EventLoop) { self.loop = loop; promise = loop.makePromise(of:(any Channel).self) }
    func complete(_ result: Result<any Channel,any Error>) {
        loop.preconditionInEventLoop(); guard !finished else { if case .success(let channel) = result { channel.close(promise:nil) }; return }
        finished = true; timer?.cancel(); timer = nil
        if case .failure = result { channel?.close(promise:nil) }
        promise.completeWith(result)
    }
    func cancel() { loop.execute { self.complete(.failure(FloeSSHFileChannelError.cancelled)) } }
}
public extension SSHClient {
    /// Dedicated binary child channel, without a PTY. Cancelling it never closes the terminal.
    func floeOpenFileChannel(_ request: FloeSSHFileChannelRequest,
                            initialize: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>) async throws -> any Channel {
        try request.validate(); let current = session, loop = current.channel.eventLoop
        let state = FloeFileChannelOpen(loop:loop)
        loop.execute {
            guard !state.finished else { return }
            state.timer = loop.scheduleTask(in:.seconds(15)) { state.complete(.failure(FloeSSHFileChannelError.timedOut)) }
            let child = loop.makePromise(of:(any Channel).self)
            current.sshHandler.value.createChannel(child) { channel,_ in
                state.channel = channel
                guard !state.finished else { channel.close(promise:nil); return channel.eventLoop.makeFailedFuture(FloeSSHFileChannelError.cancelled) }
                return initialize(channel)
            }
            child.futureResult.whenComplete { result in
                switch result {
                case .failure(let error): state.complete(.failure(error))
                case .success(let channel):
                    guard !state.finished else { channel.close(promise:nil); return }
                    let opened = channel.eventLoop.makePromise(of:Void.self)
                    if let command = request.command { channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command:command,wantReply:true),promise:opened) }
                    else { channel.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(subsystem:"sftp",wantReply:true),promise:opened) }
                    opened.futureResult.whenComplete { result in state.complete(result.map { channel }) }
                }
            }
        }
        return try await withTaskCancellationHandler { try Task.checkCancellation(); return try await state.promise.futureResult.get() } onCancel: { state.cancel() }
    }
}

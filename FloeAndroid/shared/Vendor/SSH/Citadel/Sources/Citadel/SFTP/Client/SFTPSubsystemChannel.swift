import NIO
import NIOConcurrencyHelpers
@preconcurrency import NIOSSH
import Logging

/// Errors raised while opening a raw SSH subsystem byte channel.
public enum SSHSubsystemError: Error, Sendable {
    /// The server refused the SSH subsystem request (for example, the
    /// `sftp` subsystem is disabled in `sshd_config`).
    case subsystemRejected
    /// No session channel could be created on this SSH connection.
    case channelCreationFailed
    /// The channel open or subsystem reply did not complete in time.
    case timeout
    /// The SSH connection closed before the subsystem was ready.
    case connectionClosed
}

/// Resolves the reply to a single outbound `subsystem` request.
private final class SSHSubsystemReplyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<Void>
    private var settled = false

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            if !settled {
                settled = true
                promise.succeed(())
            }
            return
        }
        if event is ChannelFailureEvent {
            if !settled {
                settled = true
                promise.fail(SSHSubsystemError.subsystemRejected)
            }
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !settled {
            settled = true
            promise.fail(SSHSubsystemError.connectionClosed)
        }
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        if !settled {
            settled = true
            promise.fail(SSHSubsystemError.connectionClosed)
        }
    }
}

extension SSHClient {
    /// Opens a raw byte channel on the standard `sftp` SSH subsystem.
    ///
    /// This sends a real `SSH_MSG_CHANNEL_REQUEST` with the subsystem name
    /// `sftp` (`SSHChannelRequestEvent.SubsystemRequest`) over this
    /// authenticated connection and resolves only after the server accepts
    /// it. It does not use a shell, an `exec` request, a remote helper
    /// program or a remote filesystem path lookup, so protocol-only SFTP
    /// servers (`internal-sftp`, Windows SFTP, appliances) work the same
    /// way as an OpenSSH host with `sftp-server`.
    ///
    /// The returned channel carries unparsed SFTP v3 bytes. The caller owns
    /// the protocol handshake, request framing, response matching, byte
    /// limits, timeouts and closing the channel. No SFTP parser or directory
    /// accumulator is installed here.
    ///
    /// - Parameters:
    ///   - logger: A logger for channel lifecycle diagnostics.
    ///   - timeout: The deadline for creating the session channel and for
    ///     the server's subsystem reply.
    /// - Returns: The active SSH child channel for the `sftp` subsystem.
    /// - Throws: `SSHSubsystemError` when the channel cannot be created or
    ///   the subsystem request is refused, or the underlying NIO error.
    public func openSFTPSubsystemChannel(
        logger: Logger = .init(label: "nl.orlandos.citadel.sftp.subsystem"),
        timeout: TimeAmount = .seconds(15)
    ) async throws -> Channel {
        let channel = try await eventLoop.flatSubmit { [eventLoop, sshHandler = session.sshHandler] () -> EventLoopFuture<Channel> in
            let createChannel = eventLoop.makePromise(of: Channel.self)
            let subsystemReply = eventLoop.makePromise(of: Void.self)
            let replyHandler = SSHSubsystemReplyHandler(promise: subsystemReply)
            let openedChannel = NIOLockedValueBox<Channel?>(nil)

            sshHandler.value.createChannel(createChannel) { channel, _ in
                openedChannel.withLockedValue { $0 = channel }
                return channel.pipeline.addHandlers(
                    SSHChannelDataUnwrapper(),
                    SSHOutboundChannelDataWrapper(),
                    replyHandler
                )
            }

            let timeoutTask = eventLoop.scheduleTask(in: timeout) {
                createChannel.fail(SSHSubsystemError.timeout)
                subsystemReply.fail(SSHSubsystemError.timeout)
                if let channel = openedChannel.withLockedValue({ $0 }) {
                    channel.close(promise: nil)
                }
            }

            return createChannel.futureResult.flatMap { channel -> EventLoopFuture<Channel> in
                let requestSent = eventLoop.makePromise(of: Void.self)
                channel.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.SubsystemRequest(
                        subsystem: "sftp",
                        wantReply: true
                    ),
                    promise: requestSent
                )
                return requestSent.futureResult
                    .flatMap { subsystemReply.futureResult }
                    .map {
                        timeoutTask.cancel()
                        return channel
                    }
                    .flatMapErrorThrowing { error in
                        timeoutTask.cancel()
                        channel.close(promise: nil)
                        throw error
                    }
            }
        }.get()

        logger.debug("SFTP subsystem channel opened")
        return channel
    }
}

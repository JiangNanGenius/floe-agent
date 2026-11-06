// Compile this additive source inside FloeSSH after the qualified Citadel file-channel API.
import Citadel
import NIOCore

public extension SSHSessionHandle {
    func openToolboxFileChannel(_ request: FloeSSHFileChannelRequest,
                               initialize: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>) async throws -> any Channel {
        try await targetClient.floeOpenFileChannel(request,initialize:initialize)
    }
}

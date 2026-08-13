import Foundation
import Citadel
import Crypto
import FloeCore
import FloePersistence
import NIOCore
import NIOSSH

public struct HostKeyChallenge: Sendable, Hashable, Identifiable {
    public var hostID: UUID
    public var address: String
    public var port: Int
    public var keyType: String
    public var fingerprintSHA256: String

    public init(hostID: UUID, address: String, port: Int, keyType: String, fingerprintSHA256: String) {
        self.hostID = hostID
        self.address = address
        self.port = port
        self.keyType = keyType
        self.fingerprintSHA256 = fingerprintSHA256
    }

    public var id: String { "\(address):\(port):\(keyType):\(fingerprintSHA256)" }
}

public enum SSHConnectionError: Error, Sendable, LocalizedError {
    case hostKeyRejected(HostKeyChallenge)
    case hostKeyChanged(expected: String, received: String)
    case invalidCredential
    case invalidHostKey
    case unsupportedKeyType(SSHAuthMethod.SSHKeyType)

    public var errorDescription: String? {
        switch self {
        case .hostKeyRejected: "The SSH host key was not trusted."
        case .hostKeyChanged(let expected, let received):
            "SSH host key changed. Expected \(expected), received \(received)."
        case .invalidCredential: "The SSH credential is missing or malformed."
        case .invalidHostKey: "The SSH server returned a malformed host key."
        case .unsupportedKeyType(let type): "Unsupported SSH private key type: \(type.rawValue)."
        }
    }
}

public typealias SSHCredentialResolver = @Sendable (SecretReference) async throws -> Data
public typealias HostKeyDecisionHandler = @Sendable (HostKeyChallenge) async -> Bool

public protocol SSHConnectionServiceProtocol: Sendable {
    func connect(
        profile: RemoteHostProfile,
        credentialResolver: @escaping SSHCredentialResolver,
        hostKeyDecision: @escaping HostKeyDecisionHandler
    ) async throws -> SSHSessionHandle
}

public final class SSHConnectionService: SSHConnectionServiceProtocol, @unchecked Sendable {
    private let hostStore: RemoteHostStore

    public init(hostStore: RemoteHostStore) {
        self.hostStore = hostStore
    }

    public func connect(
        profile: RemoteHostProfile,
        credentialResolver: @escaping SSHCredentialResolver,
        hostKeyDecision: @escaping HostKeyDecisionHandler
    ) async throws -> SSHSessionHandle {
        try profile.validate()
        try await persist(profile)

        var clients: [SSHClient] = []
        if let first = profile.jumpChain.first {
            let firstSettings = try await settings(
                hostID: profile.id,
                address: first.address,
                port: first.port,
                user: first.user,
                auth: first.auth,
                policy: HostKeyPolicy.trustOnFirstUse,
                credentialResolver: credentialResolver,
                hostKeyDecision: hostKeyDecision
            )
            var client = try await SSHClient.connect(to: firstSettings)
            clients.append(client)

            for hop in profile.jumpChain.dropFirst() {
                let hopSettings = try await self.settings(
                    hostID: profile.id,
                    address: hop.address,
                    port: hop.port,
                    user: hop.user,
                    auth: hop.auth,
                    policy: HostKeyPolicy.trustOnFirstUse,
                    credentialResolver: credentialResolver,
                    hostKeyDecision: hostKeyDecision
                )
                client = try await client.jump(to: hopSettings)
                clients.append(client)
            }

            let targetSettings = try await self.settings(
                hostID: profile.id,
                address: profile.address,
                port: profile.port,
                user: profile.user,
                auth: profile.auth,
                policy: profile.hostKeyPolicy,
                credentialResolver: credentialResolver,
                hostKeyDecision: hostKeyDecision
            )
            let target = try await client.jump(to: targetSettings)
            clients.append(target)
        } else {
            let targetSettings = try await settings(
                hostID: profile.id,
                address: profile.address,
                port: profile.port,
                user: profile.user,
                auth: profile.auth,
                policy: profile.hostKeyPolicy,
                credentialResolver: credentialResolver,
                hostKeyDecision: hostKeyDecision
            )
            clients.append(try await SSHClient.connect(to: targetSettings))
        }

        return SSHSessionHandle(clients: clients)
    }

    private func settings(
        hostID: UUID,
        address: String,
        port: Int,
        user: String,
        auth: SSHAuthMethod,
        policy: HostKeyPolicy,
        credentialResolver: @escaping SSHCredentialResolver,
        hostKeyDecision: @escaping HostKeyDecisionHandler
    ) async throws -> SSHClientSettings {
        let authentication = try await Self.authenticationFactory(
            user: user,
            auth: auth,
            credentialResolver: credentialResolver
        )
        let validator = PersistentHostKeyValidator(
            hostID: hostID,
            address: address,
            port: port,
            policy: policy,
            hostStore: hostStore,
            decision: hostKeyDecision
        )
        return SSHClientSettings(
            host: address,
            port: port,
            authenticationMethod: { authentication.make() },
            hostKeyValidator: .custom(validator)
        )
    }

    private static func authenticationFactory(
        user: String,
        auth: SSHAuthMethod,
        credentialResolver: SSHCredentialResolver
    ) async throws -> AuthenticationFactory {
        switch auth {
        case .password(let reference):
            let data = try await credentialResolver(reference)
            guard let password = String(data: data, encoding: .utf8) else {
                throw SSHConnectionError.invalidCredential
            }
            return AuthenticationFactory {
                .passwordBased(username: user, password: password)
            }

        case .importedKey(let reference, let keyType),
             .deviceGeneratedKey(let reference, let keyType):
            let data = try await credentialResolver(reference)
            switch keyType {
            case .ed25519:
                _ = try Curve25519.Signing.PrivateKey(sshEd25519: data)
                return AuthenticationFactory {
                    .ed25519(
                        username: user,
                        privateKey: try! Curve25519.Signing.PrivateKey(sshEd25519: data)
                    )
                }
            case .ecdsaP256:
                _ = try P256.Signing.PrivateKey(rawRepresentation: data)
                return AuthenticationFactory {
                    .p256(
                        username: user,
                        privateKey: try! P256.Signing.PrivateKey(rawRepresentation: data)
                    )
                }
            case .rsa4096:
                _ = try Insecure.RSA.PrivateKey(sshRsa: data)
                return AuthenticationFactory {
                    .rsa(
                        username: user,
                        privateKey: try! Insecure.RSA.PrivateKey(sshRsa: data)
                    )
                }
            }
        }
    }

    private func persist(_ profile: RemoteHostProfile) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func string<T: Encodable>(_ value: T) throws -> String {
            guard let result = String(data: try encoder.encode(value), encoding: .utf8) else {
                throw FloeError.internalError("Could not encode remote host profile")
            }
            return result
        }
        let policy: String
        switch profile.hostKeyPolicy {
        case .trustOnFirstUse: policy = "trustOnFirstUse"
        case .pinned(let fingerprint): policy = "pinned:\(fingerprint)"
        }
        try await hostStore.saveHost(
            id: profile.id,
            displayName: profile.displayName,
            address: profile.address,
            port: profile.port,
            user: profile.user,
            authJSON: try string(profile.auth),
            jumpChainJSON: try string(profile.jumpChain),
            hostKeyPolicy: policy,
            allowsLegacyAlgorithms: profile.allowsLegacyAlgorithms,
            vncEndpointJSON: try profile.vncEndpoint.map(string)
        )
    }
}

private final class AuthenticationFactory: @unchecked Sendable {
    private let factory: () -> SSHAuthenticationMethod

    init(_ factory: @escaping () -> SSHAuthenticationMethod) {
        self.factory = factory
    }

    func make() -> SSHAuthenticationMethod { factory() }
}

enum SSHHostKeyFingerprint {
    static func parse(openSSH: String) -> (keyType: String, fingerprintSHA256: String)? {
        let parts = openSSH.split(whereSeparator: \Character.isWhitespace)
        guard parts.count >= 2, let keyData = Data(base64Encoded: String(parts[1])) else {
            return nil
        }
        let digest = SHA256.hash(data: keyData)
        let fingerprint = "SHA256:" + Data(digest).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return (String(parts[0]), fingerprint)
    }

    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "SHA256:", with: "", options: [.caseInsensitive, .anchored])
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class PersistentHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let hostID: UUID
    let address: String
    let port: Int
    let policy: HostKeyPolicy
    let hostStore: RemoteHostStore
    let decision: HostKeyDecisionHandler

    init(
        hostID: UUID,
        address: String,
        port: Int,
        policy: HostKeyPolicy,
        hostStore: RemoteHostStore,
        decision: @escaping HostKeyDecisionHandler
    ) {
        self.hostID = hostID
        self.address = address
        self.port = port
        self.policy = policy
        self.hostStore = hostStore
        self.decision = decision
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let openSSH = String(openSSHPublicKey: hostKey)
        guard let parsed = SSHHostKeyFingerprint.parse(openSSH: openSSH) else {
            validationCompletePromise.fail(SSHConnectionError.invalidHostKey)
            return
        }
        let keyType = parsed.keyType
        let fingerprint = parsed.fingerprintSHA256
        let challenge = HostKeyChallenge(
            hostID: hostID,
            address: address,
            port: port,
            keyType: keyType,
            fingerprintSHA256: fingerprint
        )

        Task {
            do {
                switch policy {
                case .pinned(let expected):
                    guard SSHHostKeyFingerprint.normalize(expected) == SSHHostKeyFingerprint.normalize(fingerprint) else {
                        throw SSHConnectionError.hostKeyChanged(expected: expected, received: fingerprint)
                    }
                case .trustOnFirstUse:
                    if let known = try await hostStore.knownHost(address: address, port: port, keyType: keyType) {
                        guard SSHHostKeyFingerprint.normalize(known.fingerprintSHA256) == SSHHostKeyFingerprint.normalize(fingerprint) else {
                            throw SSHConnectionError.hostKeyChanged(
                                expected: known.fingerprintSHA256,
                                received: fingerprint
                            )
                        }
                        try await hostStore.touch(id: known.id)
                    } else {
                        guard await decision(challenge) else {
                            throw SSHConnectionError.hostKeyRejected(challenge)
                        }
                        try await hostStore.trust(KnownHostRecord(
                            hostID: hostID,
                            address: address,
                            port: port,
                            keyType: keyType,
                            fingerprintSHA256: fingerprint
                        ))
                    }
                }
                validationCompletePromise.succeed(())
            } catch {
                validationCompletePromise.fail(error)
            }
        }
    }

}

public final class SSHSessionHandle: @unchecked Sendable {
    private let clients: [SSHClient]
    private var target: SSHClient { clients[clients.count - 1] }

    init(clients: [SSHClient]) {
        precondition(!clients.isEmpty)
        self.clients = clients
    }

    public var isConnected: Bool { target.isConnected }

    public func openPTY(term: String = "xterm-256color", columns: Int = 80, rows: Int = 24) async throws -> PTYSessionHandle {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let control = PTYControl(client: target)
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: columns,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([.ECHO: 1])
        )
        let task = Task {
            do {
                try await target.withPTY(request) { inbound, writer in
                    await control.install(TTYWriterBox(writer))
                    for try await output in inbound {
                        switch output {
                        case .stdout(let buffer), .stderr(let buffer):
                            continuation.yield(Data(buffer.readableBytesView))
                        }
                    }
                }
                continuation.finish()
            } catch {
                await control.fail(error)
                continuation.finish(throwing: error)
            }
        }
        await control.install(task: task)
        return PTYSessionHandle(output: stream, control: control)
    }

    public func openDirectTCPIP(host: String, port: Int) async throws -> SSHByteChannel {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let handler = ByteChannelHandler(continuation: continuation)
        let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let channel = try await target.createDirectTCPIPChannel(
            using: .init(targetHost: host, targetPort: port, originatorAddress: origin)
        ) { channel in
            channel.pipeline.addHandler(handler)
        }
        return SSHByteChannel(channel: channel, stream: stream, continuation: continuation)
    }

    public func close() async {
        for client in clients.reversed() { try? await client.close() }
    }
}

public struct PTYSessionHandle: Sendable {
    public let output: AsyncThrowingStream<Data, Error>
    private let control: PTYControl

    fileprivate init(output: AsyncThrowingStream<Data, Error>, control: PTYControl) {
        self.output = output
        self.control = control
    }

    public func write(_ data: Data) async throws { try await control.write(data) }
    public func resize(columns: Int, rows: Int) async throws {
        try await control.resize(columns: columns, rows: rows)
    }
    public func close() async { await control.close() }
}

private actor PTYControl {
    private let client: SSHClientBox
    private var writer: TTYWriterBox?
    private var task: Task<Void, Never>?
    private var waiters: [CheckedContinuation<TTYWriterBox, Error>] = []
    private var terminalError: Error?

    init(client: SSHClient) { self.client = SSHClientBox(client) }

    func install(_ writer: TTYWriterBox) {
        self.writer = writer
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume(returning: writer) }
    }

    func install(task: Task<Void, Never>) { self.task = task }

    func fail(_ error: Error) {
        terminalError = error
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    func write(_ data: Data) async throws {
        try await readyWriter().write(data)
    }

    func resize(columns: Int, rows: Int) async throws {
        try await readyWriter().resize(columns: columns, rows: rows)
    }

    func close() async {
        task?.cancel()
        await client.close()
    }

    private func readyWriter() async throws -> TTYWriterBox {
        if let writer { return writer }
        if let terminalError { throw terminalError }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
}

private final class TTYWriterBox: @unchecked Sendable {
    private let writer: TTYStdinWriter

    init(_ writer: TTYStdinWriter) { self.writer = writer }

    func write(_ data: Data) async throws {
        try await writer.write(ByteBuffer(bytes: data))
    }

    func resize(columns: Int, rows: Int) async throws {
        try await writer.changeSize(cols: columns, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }
}

private final class SSHClientBox: @unchecked Sendable {
    private let client: SSHClient

    init(_ client: SSHClient) { self.client = client }

    func close() async { try? await client.close() }
}

public final class SSHByteChannel: @unchecked Sendable {
    private let channel: Channel
    public let inbound: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    fileprivate init(
        channel: Channel,
        stream: AsyncThrowingStream<Data, Error>,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) {
        self.channel = channel
        self.inbound = stream
        self.continuation = continuation
    }

    public func write(_ data: Data) async throws {
        try await channel.writeAndFlush(ByteBuffer(bytes: data))
    }

    public func close() async {
        try? await channel.close()
        continuation.finish()
    }
}

private final class ByteChannelHandler: ChannelInboundHandler, @unchecked Sendable {
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

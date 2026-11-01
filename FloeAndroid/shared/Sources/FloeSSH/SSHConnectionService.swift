// FloeSSH — real Citadel/SwiftNIO SSH connection, host-key trust chain and
// PTY/direct-tcpip channel surface (Android port).
//
// Ported from the fixed public donor
// FloeAgent/Sources/FloeSSH/SSHConnectionService.swift @
// a59b4d4005f616c611df67fab7620e9853c525b9, with these reviewed Android
// corrections:
//
//  * A TOFU challenge is surfaced to the caller and the connection is
//    REFUSED until the caller explicitly records the observed key. The
//    validator never trusts silently and never prompts from a transport
//    thread.
//  * A changed host key carries the exact observed challenge (address,
//    port, key type, fingerprint) so the UI can present an explicit
//    replace decision; the default remains rejection.
//  * Jump hops are validated and each hop's key participates in the same
//    stored known-host chain.
//  * A PTY close closes ONLY that PTY channel; it no longer tears down the
//    whole SSH client. This is required for independent PTY ownership and
//    for exec/tunnel channels living beside a terminal.
//  * Legacy algorithms are applied only when the profile explicitly opts in.
//
// The service is transport-only. It owns no task/run/environment authority,
// never shells out to the host `ssh`, and is not registered as a model tool.

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

    public var id: String { "\(hostID.uuidString):\(address):\(port):\(keyType)" }
}

public enum SSHConnectionFailureCategory: String, Codable, Sendable, Hashable {
    case configurationMissing
    case credentialMissing
    case authenticationFailed
    case hostKeyRejected
    case hostKeyChanged
    case networkUnreachable
    case connectionRefused
    case timedOut
    case protocolIncompatible
    case transportFailed
}

public enum SSHConnectionFailureStage: String, Codable, Sendable, Hashable {
    case configuration
    case credentialResolution
    case hostKeyVerification
    case transport
    case authentication
    case protocolHandshake
}

public enum SSHConnectionError: Error, Sendable, LocalizedError, Hashable {
    case sshNotConfigured
    case hostKeyRejected(HostKeyChallenge)
    case hostKeyChanged(expected: String, received: String, challenge: HostKeyChallenge)
    case invalidCredential
    case invalidHostKey
    case unsupportedKeyType(SSHAuthMethod.SSHKeyType)
    case authenticationFailed(user: String, address: String)
    case connectionRefused(address: String, port: Int)
    case hostNotFound(address: String)
    case timedOut(address: String, port: Int)
    case networkUnreachable(address: String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .sshNotConfigured: "This device does not have an SSH connection configured."
        case .hostKeyRejected: "The SSH host key was not trusted."
        case .hostKeyChanged:
            "SSH host key changed. The connection was stopped; the stored key is unchanged."
        case .invalidCredential: "The SSH credential is missing or malformed."
        case .invalidHostKey: "The SSH server returned a malformed host key."
        case .unsupportedKeyType(let type): "Unsupported SSH private key type: \(type.rawValue)."
        case .authenticationFailed(let user, let address):
            "SSH authentication was rejected for \(user)@\(address). Check the saved password/key and whether that login is allowed."
        case .connectionRefused(let address, let port):
            "SSH connection to \(address):\(port) was refused. Confirm that sshd is listening and the firewall allows this port."
        case .hostNotFound(let address): "SSH host name could not be resolved: \(address)."
        case .timedOut(let address, let port):
            "SSH connection to \(address):\(port) timed out. Check reachability, VPN, firewall, and the configured port."
        case .networkUnreachable(let address):
            "SSH host \(address) is unreachable from this device. Check the route, VPN, and address."
        case .transport(let detail): "SSH transport failed: \(detail)"
        }
    }

    public var category: SSHConnectionFailureCategory {
        switch self {
        case .sshNotConfigured: .configurationMissing
        case .invalidCredential: .credentialMissing
        case .authenticationFailed: .authenticationFailed
        case .hostKeyRejected: .hostKeyRejected
        case .hostKeyChanged: .hostKeyChanged
        case .connectionRefused: .connectionRefused
        case .hostNotFound, .networkUnreachable: .networkUnreachable
        case .timedOut: .timedOut
        case .invalidHostKey, .unsupportedKeyType: .protocolIncompatible
        case .transport: .transportFailed
        }
    }

    public var stage: SSHConnectionFailureStage {
        switch self {
        case .sshNotConfigured: .configuration
        case .invalidCredential, .unsupportedKeyType: .credentialResolution
        case .authenticationFailed: .authentication
        case .hostKeyRejected, .hostKeyChanged, .invalidHostKey: .hostKeyVerification
        case .connectionRefused, .hostNotFound, .timedOut, .networkUnreachable: .transport
        case .transport: .protocolHandshake
        }
    }

    public var retryable: Bool {
        switch self {
        case .connectionRefused, .hostNotFound, .timedOut, .networkUnreachable, .transport:
            true
        case .sshNotConfigured, .hostKeyRejected, .hostKeyChanged, .invalidCredential,
             .invalidHostKey, .unsupportedKeyType, .authenticationFailed:
            false
        }
    }

    public var target: String? {
        switch self {
        case .authenticationFailed(_, let address), .networkUnreachable(let address),
             .hostNotFound(let address):
            address
        case .connectionRefused(let address, let port), .timedOut(let address, let port):
            "\(address):\(port)"
        case .hostKeyRejected(let challenge), .hostKeyChanged(_, _, let challenge):
            "\(challenge.address):\(challenge.port)"
        default:
            nil
        }
    }

    /// Machine-readable, secret-free failure summary. Never includes a key,
    /// password or raw NIO buffer.
    public var toolSummary: String {
        var payload: [String: Any] = [
            "status": "connectionFailed",
            "category": category.rawValue,
            "stage": stage.rawValue,
            "retryable": retryable,
            "target": target ?? NSNull(),
            "reason": errorDescription ?? "SSH connection failed",
        ]
        if case .hostKeyRejected(let challenge) = self {
            payload["challenge"] = [
                "address": challenge.address,
                "port": challenge.port,
                "keyType": challenge.keyType,
                "fingerprintSHA256": challenge.fingerprintSHA256,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return errorDescription ?? "SSH connection failed"
        }
        return String(decoding: data, as: UTF8.self)
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

/// Consumer-facing transport seam. FloeAndroidCore depends on this protocol
/// (not on the concrete Citadel service), which keeps the connect path
/// injectable for focused lifecycle tests without a live server.
public protocol SSHTransportConnecting: Sendable {
    func connectTransport(
        profile: RemoteHostProfile,
        credentialResolver: @escaping SSHCredentialResolver,
        hostKeyDecision: @escaping HostKeyDecisionHandler
    ) async throws -> any SSHSessionTransport
}

public final class SSHConnectionService: SSHConnectionServiceProtocol, SSHTransportConnecting, @unchecked Sendable {
    private let hostStore: RemoteHostStore

    public init(hostStore: RemoteHostStore) {
        self.hostStore = hostStore
    }

    public func connect(
        profile: RemoteHostProfile,
        credentialResolver: @escaping SSHCredentialResolver,
        hostKeyDecision: @escaping HostKeyDecisionHandler
    ) async throws -> SSHSessionHandle {
        do {
            return try await connectUnnormalized(
                profile: profile,
                credentialResolver: credentialResolver,
                hostKeyDecision: hostKeyDecision
            )
        } catch let known as SSHConnectionError {
            throw known
        } catch {
            throw Self.normalizedConnectionError(error, profile: profile)
        }
    }

    public func connectTransport(
        profile: RemoteHostProfile,
        credentialResolver: @escaping SSHCredentialResolver,
        hostKeyDecision: @escaping HostKeyDecisionHandler
    ) async throws -> any SSHSessionTransport {
        try await connect(
            profile: profile,
            credentialResolver: credentialResolver,
            hostKeyDecision: hostKeyDecision
        )
    }

    private func connectUnnormalized(
        profile: RemoteHostProfile,
        credentialResolver: @escaping SSHCredentialResolver,
        hostKeyDecision: @escaping HostKeyDecisionHandler
    ) async throws -> SSHSessionHandle {
        try profile.validate()
        guard profile.auth != .none else { throw SSHConnectionError.sshNotConfigured }

        var clients: [SSHClient] = []
        do {
            if let first = profile.jumpChain.first {
                let firstSettings = try await settings(
                    hostID: profile.id,
                    address: first.address,
                    port: first.port,
                    user: first.user,
                    auth: first.auth,
                    policy: .trustOnFirstUse,
                    allowsLegacyAlgorithms: profile.allowsLegacyAlgorithms,
                    credentialResolver: credentialResolver,
                    hostKeyDecision: hostKeyDecision
                )
                var client = try await SSHClient.connect(to: firstSettings)
                clients.append(client)

                for hop in profile.jumpChain.dropFirst() {
                    let hopSettings = try await settings(
                        hostID: profile.id,
                        address: hop.address,
                        port: hop.port,
                        user: hop.user,
                        auth: hop.auth,
                        policy: .trustOnFirstUse,
                        allowsLegacyAlgorithms: profile.allowsLegacyAlgorithms,
                        credentialResolver: credentialResolver,
                        hostKeyDecision: hostKeyDecision
                    )
                    client = try await client.jump(to: hopSettings)
                    clients.append(client)
                }

                let targetSettings = try await settings(
                    hostID: profile.id,
                    address: profile.address,
                    port: profile.port,
                    user: profile.user,
                    auth: profile.auth,
                    policy: profile.hostKeyPolicy,
                    allowsLegacyAlgorithms: profile.allowsLegacyAlgorithms,
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
                    allowsLegacyAlgorithms: profile.allowsLegacyAlgorithms,
                    credentialResolver: credentialResolver,
                    hostKeyDecision: hostKeyDecision
                )
                let client = try await SSHClient.connect(to: targetSettings)
                clients.append(client)
            }
        } catch {
            for client in clients.reversed() {
                try? await client.close()
            }
            throw error
        }

        return SSHSessionHandle(clients: clients)
    }

    /// Converts NIO/Citadel transport errors into stable reasons suitable for
    /// UI/tool output. The classifier never includes credential bytes.
    public static func normalizedConnectionError(
        _ error: Error,
        profile: RemoteHostProfile
    ) -> SSHConnectionError {
        if let known = error as? SSHConnectionError { return known }
        let nsError = error as NSError
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = "\(raw) \(nsError.domain) \(nsError.code)".lowercased()
        if probe.contains("auth") || probe.contains("permission denied") || probe.contains("credential") {
            return .authenticationFailed(user: profile.user, address: profile.address)
        }
        if probe.contains("refused") || nsError.code == 61 {
            return .connectionRefused(address: profile.address, port: profile.port)
        }
        if probe.contains("timed out") || probe.contains("timeout") || nsError.code == 60 {
            return .timedOut(address: profile.address, port: profile.port)
        }
        if probe.contains("no route") || probe.contains("unreachable") || nsError.code == 65 {
            return .networkUnreachable(address: profile.address)
        }
        if probe.contains("name or service") || probe.contains("dns") || probe.contains("not known")
            || nsError.code == 8 {
            return .hostNotFound(address: profile.address)
        }
        let detail = raw.isEmpty
            ? "Unknown connection error [\(nsError.domain):\(nsError.code)]"
            : "\(String(raw.prefix(240))) [\(nsError.domain):\(nsError.code)]"
        return .transport(detail)
    }

    private func settings(
        hostID: UUID,
        address: String,
        port: Int,
        user: String,
        auth: SSHAuthMethod,
        policy: HostKeyPolicy,
        allowsLegacyAlgorithms: Bool,
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
        var settings = SSHClientSettings(
            host: address,
            port: port,
            authenticationMethod: { authentication.make() },
            hostKeyValidator: .custom(validator)
        )
        settings.connectTimeout = .seconds(12)
        if allowsLegacyAlgorithms {
            settings.algorithms = .all
        }
        return settings
    }

    private static func authenticationFactory(
        user: String,
        auth: SSHAuthMethod,
        credentialResolver: SSHCredentialResolver
    ) async throws -> AuthenticationFactory {
        switch auth {
        case .none:
            throw SSHConnectionError.sshNotConfigured
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
}

private final class AuthenticationFactory: @unchecked Sendable {
    private let factory: () -> SSHAuthenticationMethod

    init(_ factory: @escaping () -> SSHAuthenticationMethod) {
        self.factory = factory
    }

    func make() -> SSHAuthenticationMethod { factory() }
}

public enum SSHHostKeyFingerprint {
    public static func parse(openSSH: String) -> (keyType: String, fingerprintSHA256: String)? {
        let parts = openSSH.split(whereSeparator: \Character.isWhitespace)
        guard parts.count >= 2, let keyData = Data(base64Encoded: String(parts[1])) else {
            return nil
        }
        let digest = SHA256.hash(data: keyData)
        let fingerprint = "SHA256:" + Data(digest).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return (String(parts[0]), fingerprint)
    }

    public static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "SHA256:", with: "", options: [.caseInsensitive, .anchored])
            .replacingOccurrences(of: "=", with: "")
    }

    public static func isValid(_ value: String) -> Bool {
        let normalized = normalize(value)
        guard normalized.count == 43 else { return false }
        return normalized.allSatisfy { character in
            character.isLetter || character.isNumber || character == "+" || character == "/"
        }
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
                        throw SSHConnectionError.hostKeyChanged(
                            expected: expected,
                            received: fingerprint,
                            challenge: challenge
                        )
                    }
                case .trustOnFirstUse:
                    if let known = try await hostStore.knownHost(
                        address: address, port: port, keyType: keyType
                    ) {
                        guard SSHHostKeyFingerprint.normalize(known.fingerprintSHA256)
                                == SSHHostKeyFingerprint.normalize(fingerprint) else {
                            throw SSHConnectionError.hostKeyChanged(
                                expected: known.fingerprintSHA256,
                                received: fingerprint,
                                challenge: challenge
                            )
                        }
                        try await hostStore.touch(id: known.id)
                    } else {
                        // Refuse the handshake; the caller records the
                        // challenge and asks the user. Returning true here
                        // would silently trust an unseen key.
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

// MARK: - Session/channel transport seam

public enum SSHExecEvent: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
    case exited(Int32)
}

public protocol SSHSessionPTY: Sendable {
    var output: AsyncThrowingStream<Data, Error> { get }
    func write(_ data: Data) async throws
    func resize(columns: Int, rows: Int) async throws
    func close() async
}

public protocol SSHSessionExec: Sendable {
    var events: AsyncThrowingStream<SSHExecEvent, Error> { get }
    func cancel()
}

public protocol SSHSessionByteChannel: Sendable {
    var inbound: AsyncThrowingStream<Data, Error> { get }
    func write(_ data: Data) async throws
    func close() async
}

public protocol SSHSessionTransport: Sendable {
    var isConnected: Bool { get }
    func openPTY(term: String, columns: Int, rows: Int) async throws -> any SSHSessionPTY
    func openExec(_ command: String) async throws -> any SSHSessionExec
    func openDirectTCPIP(host: String, port: Int) async throws -> any SSHSessionByteChannel
    func close() async
}

extension PTYSessionHandle: SSHSessionPTY {}

public final class SSHSessionHandle: SSHSessionTransport, @unchecked Sendable {
    private let clients: [SSHClient]
    private let closeLock = NSLock()
    private var closed = false

    /// The target (last-hop) client, exposed for exec-channel operations.
    var targetClient: SSHClient { clients[clients.count - 1] }

    init(clients: [SSHClient]) {
        precondition(!clients.isEmpty)
        self.clients = clients
    }

    public var isConnected: Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        return !closed && targetClient.isConnected
    }

    public func openPTY(term: String = "xterm-256color", columns: Int = 80, rows: Int = 24) async throws -> any SSHSessionPTY {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let control = PTYControl()
        let clientBox = SSHPtyClientBox(targetClient)
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: columns,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([.ECHO: 1])
        )
        let task = Task { [clientBox, control] in
            do {
                try await clientBox.client.withPTY(request) { inbound, writer in
                    await control.install(TTYWriterBox(writer))
                    for try await output in inbound {
                        switch output {
                        case .stdout(let buffer), .stderr(let buffer):
                            continuation.yield(Data(buffer.readableBytesView))
                        }
                    }
                }
                await control.pumpEnded(nil)
                continuation.finish()
            } catch {
                await control.pumpEnded(error)
                continuation.finish(throwing: error)
            }
        }
        await control.install(task: task)
        return PTYSessionHandle(output: stream, control: control)
    }

    public func openDirectTCPIP(host: String, port: Int) async throws -> any SSHSessionByteChannel {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let handler = ByteChannelHandler(continuation: continuation)
        let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let channel = try await targetClient.createDirectTCPIPChannel(
            using: .init(targetHost: host, targetPort: port, originatorAddress: origin)
        ) { channel in
            channel.pipeline.addHandler(handler)
        }
        return SSHByteChannel(channel: channel, stream: stream, continuation: continuation)
    }

    public func close() async {
        closeLock.lock()
        guard !closed else { closeLock.unlock(); return }
        closed = true
        closeLock.unlock()
        for client in clients.reversed() {
            try? await client.close()
        }
    }
}

public struct PTYSessionHandle: SSHSessionPTY {
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

/// One PTY's ownership. `close()` cancels only this PTY's channel; the SSH
/// session (and any sibling PTY/exec/tunnel channel) stays live.
private actor PTYControl {
    private var writer: TTYWriterBox?
    private var task: Task<Void, Never>?
    private var waiters: [CheckedContinuation<TTYWriterBox, Error>] = []
    private var terminalError: Error?
    private var closed = false

    init() {}

    func install(_ writer: TTYWriterBox) {
        guard !closed, terminalError == nil else { return }
        self.writer = writer
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume(returning: writer) }
    }

    func install(task: Task<Void, Never>) {
        guard !closed, terminalError == nil else { task.cancel(); return }
        self.task = task
    }

    func pumpEnded(_ error: Error?) {
        if let error, terminalError == nil {
            terminalError = error
        }
        writer = nil
        task = nil
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            if let error = terminalError {
                waiter.resume(throwing: error)
            } else {
                waiter.resume(throwing: SSHExecErrorTransport.ptyClosed)
            }
        }
    }

    func write(_ data: Data) async throws {
        try await readyWriter().write(data)
    }

    func resize(columns: Int, rows: Int) async throws {
        try await readyWriter().resize(columns: columns, rows: rows)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        let running = task
        task = nil
        writer = nil
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: FloeError.cancelled) }
        running?.cancel()
        _ = await running?.value
    }

    private func readyWriter() async throws -> TTYWriterBox {
        if let terminalError { throw terminalError }
        if let writer { return writer }
        guard !closed else { throw FloeError.cancelled }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
}

private enum SSHExecErrorTransport: Error, Sendable {
    case ptyClosed
}

private final class SSHPtyClientBox: @unchecked Sendable {
    let client: SSHClient
    init(_ client: SSHClient) { self.client = client }
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

public final class SSHByteChannel: SSHSessionByteChannel, @unchecked Sendable {
    private let channel: Channel
    public let inbound: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var closed = false

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
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
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

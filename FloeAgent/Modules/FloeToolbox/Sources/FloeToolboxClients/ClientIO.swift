import Foundation
@preconcurrency import Network
import Security
import FloeToolboxCore

public enum ClientError: Error, Equatable, Sendable {
    case invalidConfiguration, closed, busy, timedOut, tooLarge, networkFailure, protocolViolation, authenticationFailed, unsupported
}

/// A once-only completion gate. Late callbacks cannot resume a cancelled operation twice.
final class ClientCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value,any Error>?
    private var continuation: CheckedContinuation<Value,any Error>?
    func finish(_ value: Result<Value,any Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value; let waiting = continuation; continuation = nil; lock.unlock()
        waiting?.resume(with:value)
    }
    var isPending: Bool { lock.lock(); defer { lock.unlock() }; return result == nil }
    func wait(seconds: TimeInterval?) async throws -> Value {
        if let seconds { guard seconds.isFinite, (0.01...300).contains(seconds) else { throw ClientError.invalidConfiguration } }
        let timer: Task<Void,Never>? = seconds.map { seconds in Task {
            do { try await Task.sleep(for:.seconds(seconds)); self.finish(.failure(ClientError.timedOut)) } catch { }
        } }
        defer { timer?.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { waiter in
                lock.lock()
                if let value = result { lock.unlock(); waiter.resume(with:value) }
                else { continuation = waiter; lock.unlock() }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }
}

public struct ClientTLSConfiguration: Sendable {
    /// Public CA certificates explicitly supplied by the host's approved server-trust configuration.
    /// Empty uses system trust. There is no "trust all" mode.
    public let additionalRootCertificates: [Data]
    public init(additionalRootCertificates: [Data] = []) throws {
        guard additionalRootCertificates.count <= 16,
              additionalRootCertificates.allSatisfy({ !$0.isEmpty && $0.count <= 65536 && SecCertificateCreateWithData(nil,$0 as CFData) != nil }) else { throw ClientError.invalidConfiguration }
        self.additionalRootCertificates = additionalRootCertificates
    }
    public func options(serverName: String) throws -> NWProtocolTLS.Options {
        guard !serverName.isEmpty, serverName.utf8.count <= 253, !serverName.contains("\0") else { throw ClientError.invalidConfiguration }
        let options = NWProtocolTLS.Options(), roots = additionalRootCertificates
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions,.TLSv12)
        sec_protocol_options_set_tls_server_name(options.securityProtocolOptions,serverName)
        sec_protocol_options_set_verify_block(options.securityProtocolOptions,{ _,trust,complete in
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            guard SecTrustSetPolicies(reference,SecPolicyCreateSSL(true,serverName as CFString)) == errSecSuccess else { complete(false); return }
            if !roots.isEmpty {
                let certificates = roots.compactMap { SecCertificateCreateWithData(nil,$0 as CFData) }
                guard certificates.count == roots.count,
                      SecTrustSetAnchorCertificates(reference,certificates as CFArray) == errSecSuccess,
                      SecTrustSetAnchorCertificatesOnly(reference,false) == errSecSuccess else { complete(false); return }
            }
            var trustError: CFError?
            let accepted = SecTrustEvaluateWithError(reference,&trustError)
            complete(accepted)
        },DispatchQueue(label:"floe.toolbox.server-trust"))
        return options
    }
}

/// A bounded TCP stream or connected UDP client. UDP readiness is not peer reachability.
/// The host creates this only after resolving and authorizing the connection target.
public actor NetworkSerialConnection: SerialConnection {
    public enum Kind: Sendable { case tcp, udp }
    public nonisolated let kind: Kind
    private let connection: NWConnection
    private let timeout: TimeInterval
    private let readTimeout: TimeInterval?
    private var closed = false
    private var sending = false
    private var receiving = false
    private var inputFinished = false
    private var sendGate: ClientCompletion<Void>?
    private var receiveGate: ClientCompletion<NetworkRead>?
    private struct NetworkRead: Sendable { let bytes: Data; let complete: Bool }
    private init(_ connection: NWConnection, kind: Kind, timeout: TimeInterval, readTimeout: TimeInterval?) {
        self.connection = connection; self.kind = kind; self.timeout = timeout; self.readTimeout = readTimeout
    }
    public static func connect(host: String, port: UInt16, kind: Kind = .tcp, localPort: UInt16? = nil,
                               tls: ClientTLSConfiguration? = nil, timeout: TimeInterval = 30,
                               readTimeout: TimeInterval? = nil, localAddress: String? = nil,
                               applicationProtocols: [NWProtocolOptions] = []) async throws -> NetworkSerialConnection {
        _ = try SerialEndpoint(title:"Connection",transport:kind == .tcp ? .tcp : .udp,host:host,port:Int(port))
        guard timeout.isFinite, (0.01...300).contains(timeout), applicationProtocols.count <= 4,
              kind == .tcp || tls == nil && applicationProtocols.isEmpty,
              let remotePort = NWEndpoint.Port(rawValue:port) else { throw ClientError.invalidConfiguration }
        if let readTimeout { guard readTimeout.isFinite, (0.01...300).contains(readTimeout) else { throw ClientError.invalidConfiguration } }
        let parameters = kind == .tcp ? NWParameters(tls:try tls?.options(serverName:host),tcp:NWProtocolTCP.Options()) : NWParameters.udp
        parameters.defaultProtocolStack.applicationProtocols = applicationProtocols+parameters.defaultProtocolStack.applicationProtocols
        if let localPort {
            guard let bound = NWEndpoint.Port(rawValue:localPort) else { throw ClientError.invalidConfiguration }
            parameters.requiredLocalEndpoint = .hostPort(host:NWEndpoint.Host(localAddress ?? (host.contains(":") ? "::" : "0.0.0.0")),port:bound)
        }
        let connection = NWConnection(host:NWEndpoint.Host(host),port:remotePort,using:parameters)
        let gate = ClientCompletion<Void>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: gate.finish(.success(()))
            case .waiting(let error): if case .tls = error { gate.finish(.failure(ClientError.authenticationFailed)) }
            case .failed,.cancelled: gate.finish(.failure(ClientError.networkFailure))
            default: break
            }
        }
        connection.start(queue:DispatchQueue(label:"floe.toolbox.connection."+UUID().uuidString))
        do {
            try await withTaskCancellationHandler { try await gate.wait(seconds:timeout) }
                onCancel: { connection.cancel() }
            return NetworkSerialConnection(connection,kind:kind,timeout:timeout,readTimeout:readTimeout)
        } catch { connection.cancel(); throw error }
    }
    public func send(_ bytes: Data) async throws {
        guard !closed, !Task.isCancelled else { throw ClientError.closed }
        guard !sending else { throw ClientError.busy }
        guard bytes.count <= (kind == .udp ? 65507 : 1024*1024) else { throw ClientError.tooLarge }
        sending = true; defer { sending = false; sendGate = nil }
        let gate = ClientCompletion<Void>(); sendGate = gate
        connection.send(content:bytes,completion:.contentProcessed { error in gate.finish(error == nil ? .success(()) : .failure(ClientError.networkFailure)) })
        do { try await gate.wait(seconds:timeout); guard !closed else { throw ClientError.closed } }
        catch { close(); throw error }
    }
    public func receive(maximumBytes: Int) async throws -> Data {
        guard !closed, !Task.isCancelled else { throw ClientError.closed }
        guard !receiving else { throw ClientError.busy }
        guard !inputFinished else { throw ClientError.closed }
        guard (1...1024*1024).contains(maximumBytes) else { throw ClientError.tooLarge }
        receiving = true; defer { receiving = false; receiveGate = nil }
        let gate = ClientCompletion<NetworkRead>(); receiveGate = gate
        let callback: @Sendable (Data?,NWConnection.ContentContext?,Bool,NWError?) -> Void = { data,_,complete,error in
            if error != nil { gate.finish(.failure(ClientError.networkFailure)) }
            else { gate.finish(.success(NetworkRead(bytes:data ?? Data(),complete:complete))) }
        }
        if kind == .udp { connection.receiveMessage(completion:callback) }
        else { connection.receive(minimumIncompleteLength:1,maximumLength:maximumBytes,completion:callback) }
        do {
            let result = try await gate.wait(seconds:readTimeout)
            guard !closed else { throw ClientError.closed }
            guard result.bytes.count <= maximumBytes else { throw ClientError.tooLarge }
            if kind == .tcp, result.complete { inputFinished = true }
            if kind == .tcp, result.bytes.isEmpty, result.complete { close(); throw ClientError.closed }
            return result.bytes
        } catch { close(); throw error }
    }
    public func close() {
        guard !closed else { return }; closed = true
        sendGate?.finish(.failure(ClientError.closed)); receiveGate?.finish(.failure(ClientError.closed))
        connection.cancel()
    }
}

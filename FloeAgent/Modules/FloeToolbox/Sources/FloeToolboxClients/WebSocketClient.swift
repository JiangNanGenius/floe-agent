import Foundation
@preconcurrency import Network
import FloeToolboxCore

/// Native RFC6455 framing/masking; preserves text/binary and bounds continuation assembly.
public actor WebSocketClientConnection: SerialMessageConnection {
    private let connection: NWConnection
    private let maximumBytes: Int
    private let timeout: TimeInterval
    private var sending = false, receiving = false, closed = false
    private var sendGate: ClientCompletion<Void>?
    private var readGate: ClientCompletion<Frame>?
    private struct Frame: Sendable { let bytes: Data; let opcode: NWProtocolWebSocket.Opcode; let complete: Bool }
    private init(connection: NWConnection, maximumBytes: Int, timeout: TimeInterval) {
        self.connection = connection; self.maximumBytes = maximumBytes; self.timeout = timeout
    }
    public static func connect(url: URL, headers: [String:String] = [:], protocols: [String] = [],
                               maximumMessageBytes: Int = 1024*1024, timeout: TimeInterval = 30,
                               tls: ClientTLSConfiguration? = nil) async throws -> WebSocketClientConnection {
        try ClientHTTPValidation.url(url,schemes:["ws","wss"]); try ClientHTTPValidation.headers(headers)
        guard (1...1024*1024).contains(maximumMessageBytes), timeout.isFinite, (0.05...300).contains(timeout),
              protocols.count <= 16, protocols.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && $0.utf8.allSatisfy(ClientHTTPValidation.token) }),
              !headers.keys.contains(where:{ $0.lowercased().hasPrefix("sec-websocket-") }) else { throw ClientError.invalidConfiguration }
        let options = NWProtocolWebSocket.Options(.version13)
        options.autoReplyPing = true; options.maximumMessageSize = maximumMessageBytes
        options.setAdditionalHeaders(headers.map { (name:$0.key,value:$0.value) }); options.setSubprotocols(protocols)
        let tlsOptions = url.scheme == "wss" ? try (tls ?? ClientTLSConfiguration()).options(serverName:url.host ?? "") : nil
        let parameters = NWParameters(tls:tlsOptions,tcp:NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(options,at:0)
        let connection = NWConnection(to:.url(url),using:parameters), opened = ClientCompletion<Void>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: opened.finish(.success(()))
            case .failed,.cancelled: opened.finish(.failure(ClientError.networkFailure))
            default: break
            }
        }
        connection.start(queue:DispatchQueue(label:"floe.toolbox.websocket."+UUID().uuidString))
        do {
            try await withTaskCancellationHandler { try await opened.wait(seconds:timeout) } onCancel: { connection.cancel() }
            return WebSocketClientConnection(connection:connection,maximumBytes:maximumMessageBytes,timeout:timeout)
        } catch { connection.cancel(); throw error }
    }
    public func send(_ bytes: Data) async throws { try await sendMessage(.bytes(bytes)) }
    public func sendMessage(_ payload: SerialPayload) async throws {
        guard !closed, !Task.isCancelled else { throw ClientError.closed }
        guard !sending else { throw ClientError.busy }
        guard payload.bytes.count <= maximumBytes else { throw ClientError.tooLarge }
        sending = true; defer { sending = false; sendGate = nil }
        let gate = ClientCompletion<Void>(); sendGate = gate
        let metadata = NWProtocolWebSocket.Metadata(opcode:payload.isText ? .text : .binary)
        let context = NWConnection.ContentContext(identifier:UUID().uuidString,metadata:[metadata])
        connection.send(content:payload.bytes,contentContext:context,isComplete:true,completion:.contentProcessed { error in
            gate.finish(error == nil ? .success(()) : .failure(ClientError.networkFailure))
        })
        do { try await gate.wait(seconds:timeout); guard !closed else { throw ClientError.closed } }
        catch { close(); throw error }
    }
    public func receive(maximumBytes: Int) async throws -> Data { try await receiveMessage(maximumBytes:maximumBytes).bytes }
    public func receiveMessage(maximumBytes: Int) async throws -> SerialPayload {
        guard !closed, !Task.isCancelled else { throw ClientError.closed }
        guard !receiving else { throw ClientError.busy }
        guard (1...self.maximumBytes).contains(maximumBytes) else { throw ClientError.tooLarge }
        receiving = true; defer { receiving = false; readGate = nil }
        var accumulated = Data(), initialOpcode: NWProtocolWebSocket.Opcode?
        do {
            for _ in 0..<1024 {
                let gate = ClientCompletion<Frame>(); readGate = gate
                connection.receiveMessage { bytes,context,complete,error in
                    if error != nil { gate.finish(.failure(ClientError.networkFailure)); return }
                    guard let metadata = context?.protocolMetadata(definition:NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
                        gate.finish(.failure(ClientError.closed)); return
                    }
                    gate.finish(.success(Frame(bytes:bytes ?? Data(),opcode:metadata.opcode,complete:complete)))
                }
                let frame = try await gate.wait(seconds:nil)
                guard !closed else { throw ClientError.closed }
                switch frame.opcode {
                case .close: throw ClientError.closed
                case .ping,.pong: continue
                case .text,.binary:
                    guard initialOpcode == nil else { throw ClientError.protocolViolation }; initialOpcode = frame.opcode
                case .cont: guard initialOpcode != nil else { throw ClientError.protocolViolation }
                @unknown default: throw ClientError.protocolViolation
                }
                guard frame.bytes.count <= maximumBytes-accumulated.count else { throw ClientError.tooLarge }
                accumulated.append(frame.bytes)
                if frame.complete {
                    if initialOpcode == .text {
                        guard let value = String(data:accumulated,encoding:.utf8) else { throw ClientError.protocolViolation }
                        return .text(value)
                    }
                    return .bytes(accumulated)
                }
            }
            throw ClientError.tooLarge
        } catch { close(); throw error }
    }
    public func ping() async throws {
        guard !closed else { throw ClientError.closed }
        let gate = ClientCompletion<Void>(), metadata = NWProtocolWebSocket.Metadata(opcode:.ping)
        metadata.setPongHandler(DispatchQueue(label:"floe.toolbox.websocket.pong")) { error in
            gate.finish(error == nil ? .success(()) : .failure(ClientError.networkFailure))
        }
        connection.send(content:Data(),contentContext:NWConnection.ContentContext(identifier:UUID().uuidString,metadata:[metadata]),isComplete:true,
            completion:.contentProcessed { error in if error != nil { gate.finish(.failure(ClientError.networkFailure)) } })
        do { try await gate.wait(seconds:timeout) } catch { close(); throw error }
    }
    public func close() {
        guard !closed else { return }; closed = true
        sendGate?.finish(.failure(ClientError.closed)); readGate?.finish(.failure(ClientError.closed)); connection.cancel()
    }
}

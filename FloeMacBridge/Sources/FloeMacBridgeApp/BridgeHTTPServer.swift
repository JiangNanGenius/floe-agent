#if os(macOS)
import Foundation
import Network
import FloeMacBridgeProtocol

/// One bounded request per connection; no LAN binding, cookies, CORS, shell
/// URL arguments or bearer credentials. Every RPC carries an Ed25519 proof.
final class BridgeHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.floeagent.bridge.listener")
    private let service: BridgeService
    init(service: BridgeService) throws {
        self.service = service
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: BridgeWire.port)!)
        listener = try NWListener(using: parameters)
    }
    func start(onState: @escaping @Sendable (String?) -> Void) {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onState(nil)
            case .failed: onState("The local connection could not start. Check whether another Floe Bridge is running.")
            default: break
            }
        }
        listener.newConnectionHandler = { [self] connection in
            let state = RequestBuffer()
            connection.start(queue: queue)
            read(connection, state: state)
        }
        listener.start(queue: queue)
    }
    func stop() { listener.cancel() }
    private final class RequestBuffer: @unchecked Sendable { var data = Data() }
    private func read(_ connection: NWConnection, state: RequestBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: BridgeWire.pageBytes) { [self] bytes, _, complete, error in
            if let bytes { state.data.append(bytes) }
            guard state.data.count <= BridgeWire.maximumFrameBytes + 16_384 else { reject(connection); return }
            guard let boundary = state.data.range(of: Data("\r\n\r\n".utf8)) else {
                guard state.data.count < 16_384, !complete, error == nil else { reject(connection); return }
                read(connection, state: state); return
            }
            guard let header = String(data: state.data[..<boundary.lowerBound], encoding: .utf8) else { reject(connection); return }
            let lines = header.components(separatedBy: "\r\n")
            guard lines.first == "POST /rpc HTTP/1.1" else { reject(connection); return }
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { reject(connection); return }
                let key = pair[0].lowercased()
                guard fields[key] == nil else { reject(connection); return }
                fields[key] = pair[1].trimmingCharacters(in: .whitespaces)
            }
            guard fields["origin"] == nil, fields["transfer-encoding"] == nil,
                  fields["host"] == "127.0.0.1:\(BridgeWire.port)",
                  fields["content-type"]?.hasPrefix("application/json") == true,
                  let text = fields["content-length"], let length = Int(text), length > 0, length <= BridgeWire.maximumFrameBytes else { reject(connection); return }
            let body = state.data[boundary.upperBound...]
            if body.count < length {
                guard !complete, error == nil else { reject(connection); return }
                read(connection, state: state); return
            }
            guard body.count == length else { reject(connection); return }
            let requestBytes = Data(body)
            Task {
                do {
                    let request = try BridgeWire.decode(BridgeRequest.self, from: requestBytes)
                    let result = try await service.respond(request)
                    guard result.count <= BridgeWire.maximumFrameBytes else { reject(connection); return }
                    send(connection, code: "200 OK", body: result)
                } catch { reject(connection) }
            }
        }
    }
    private func reject(_ connection: NWConnection) { send(connection, code: "400 Bad Request", body: Data()) }
    private func send(_ connection: NWConnection, code: String, body: Data) {
        var data = Data("HTTP/1.1 \(code)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif

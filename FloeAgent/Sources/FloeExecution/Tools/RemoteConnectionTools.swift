import Foundation
import Crypto
import FloeCore
import FloePersistence
import FloeSSH
import FloeTools

public struct RemoteConnectionOpenTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var kind: RemoteTextConnectionKind?
        public var host: String?
        public var port: Int?
        public var hostID: String?
        public var connectionID: String?
        public var timeout: Double?
    }

    public static let name = "remote.connection.open"
    public static let toolDescription = "Open a run-scoped Telnet or raw TCP connection. Use either a saved hostID+connectionID from ssh.listHosts, or explicit kind+host+port supplied by the user. Explicit connections are temporary, never saved or synced, and automatically close after 30 minutes. This tool accepts no password."
    public static let parametersJSON = #"{"type":"object","properties":{"kind":{"type":"string","enum":["tcp","telnet"]},"host":{"type":"string"},"port":{"type":"integer","minimum":1,"maximum":65535},"hostID":{"type":"string"},"connectionID":{"type":"string"},"timeout":{"type":"number","minimum":1,"maximum":30}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false

    private let service: RawRemoteConnectionService
    private let store: RemoteHostStore

    public init(service: RawRemoteConnectionService, store: RemoteHostStore) {
        self.service = service
        self.store = store
    }

    public func validate(_ args: Arguments) throws {
        let saved = args.hostID != nil || args.connectionID != nil
        if saved {
            guard args.hostID.flatMap(UUID.init(uuidString:)) != nil,
                  args.connectionID.flatMap(UUID.init(uuidString:)) != nil else {
                throw FloeError.validationFailed("Saved connection requires UUID hostID and connectionID")
            }
        } else {
            guard args.kind != nil,
                  args.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  let port = args.port, (1...65535).contains(port) else {
                throw FloeError.validationFailed("Temporary connection requires kind, host and port")
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let target = try await resolve(args)
        let id = try await service.open(
            runID: context.runID, host: target.host, port: target.port,
            kind: target.kind, timeout: min(max(args.timeout ?? 15, 1), 30)
        )
        return Self.output("sessionID=\(id.uuidString) kind=\(target.kind.rawValue) endpoint=\(target.host):\(target.port) persisted=false", 0)
    }

    private func resolve(_ args: Arguments) async throws -> (kind: RemoteTextConnectionKind, host: String, port: Int) {
        guard let hostID = args.hostID.flatMap(UUID.init(uuidString:)),
              let connectionID = args.connectionID.flatMap(UUID.init(uuidString:)) else {
            return (args.kind!, args.host!, args.port!)
        }
        guard let stored = try await store.host(id: hostID),
              let json = stored.auxiliaryConnectionsJSON,
              let connections = try? JSONDecoder().decode([RemoteAuxiliaryConnection].self, from: Data(json.utf8)),
              let connection = connections.first(where: { $0.id == connectionID }),
              let host = connection.host, let port = connection.port,
              let kind = RemoteTextConnectionKind(rawValue: connection.kind.rawValue) else {
            throw FloeError.notFound("Saved TCP/Telnet connection")
        }
        return (kind, host, port)
    }
}

public struct RemoteConnectionExchangeTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var sessionID: String
        public var text: String?
        public var base64: String?
        public var appendNewline: Bool?
        public var waitSeconds: Double?
        public var maxOutputBytes: Int?
    }

    public static let name = "remote.connection.exchange"
    public static let toolDescription = "Send text or base64 bytes to a temporary Telnet/TCP session and read the bounded reply. Omit both payloads to read pending data. Session IDs are returned by remote.connection.open and expire with the run."
    public static let parametersJSON = #"{"type":"object","properties":{"sessionID":{"type":"string"},"text":{"type":"string"},"base64":{"type":"string"},"appendNewline":{"type":"boolean"},"waitSeconds":{"type":"number","minimum":0.05,"maximum":30},"maxOutputBytes":{"type":"integer","minimum":1,"maximum":262144}},"required":["sessionID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .executesRemoteCommand]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
    private let service: RawRemoteConnectionService

    public init(service: RawRemoteConnectionService) { self.service = service }

    public func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.sessionID) != nil else { throw FloeError.validationFailed("sessionID must be a UUID") }
        guard !(args.text != nil && args.base64 != nil) else { throw FloeError.validationFailed("Use text or base64, not both") }
        if let base64 = args.base64, Data(base64Encoded: base64) == nil { throw FloeError.validationFailed("base64 is invalid") }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        var data = args.text.map { Data($0.utf8) } ?? args.base64.flatMap { Data(base64Encoded: $0) }
        if args.appendNewline == true { data?.append(0x0A) }
        let received = try await service.exchange(
            runID: context.runID, sessionID: UUID(uuidString: args.sessionID)!, data: data,
            wait: args.waitSeconds ?? 1, maxBytes: args.maxOutputBytes ?? 65_536
        )
        let text = String(data: received, encoding: .utf8)
        let body = text.map { "encoding=utf8 bytes=\(received.count)\n\($0)" }
            ?? "encoding=base64 bytes=\(received.count)\n\(received.base64EncodedString())"
        return RemoteConnectionOpenTool.output(body, 0)
    }
}

public struct RemoteConnectionCloseTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public var sessionID: String }
    public static let name = "remote.connection.close"
    public static let toolDescription = "Close a temporary Telnet/TCP connection opened in this run."
    public static let parametersJSON = #"{"type":"object","properties":{"sessionID":{"type":"string"}},"required":["sessionID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
    private let service: RawRemoteConnectionService
    public init(service: RawRemoteConnectionService) { self.service = service }
    public func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.sessionID) != nil else { throw FloeError.validationFailed("sessionID must be a UUID") }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        await service.close(runID: context.runID, sessionID: UUID(uuidString: args.sessionID)!)
        return RemoteConnectionOpenTool.output("closed=true", 0)
    }
}

private extension RemoteConnectionOpenTool {
    static func output(_ text: String, _ status: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: status)
    }
}

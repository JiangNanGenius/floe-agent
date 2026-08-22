import Foundation
import Crypto
import FloeCore
import FloeTools
import FloePersistence

public struct SSHListHostsTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public init() {} }
    public static let name = "ssh.listHosts"
    public static let toolDescription = "List paired SSH task machines and their stable host IDs. Use this before selecting a machine for deployment, analysis or host administration. Credentials are never returned."
    public static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    private let store: RemoteHostStore

    public init(store: RemoteHostStore) { self.store = store }
    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let hosts = try await store.hosts().enumerated().map { index, host in
            ["id": host.id.uuidString, "name": host.displayName, "address": host.address,
             "port": String(host.port), "user": host.user, "default": String(index == 0)]
        }
        let data = try JSONSerialization.data(withJSONObject: ["hosts": hosts], options: [.sortedKeys])
        return ToolExecutionOutput(summary: String(decoding: data, as: UTF8.self), fullOutputSHA256: digest(data), exitStatus: 0)
    }
}

public struct SSHUpdateHostTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var hostID: String
        public var displayName: String?
        public var address: String?
        public var port: Int?
        public var user: String?
    }
    public static let name = "ssh.updateHost"
    public static let toolDescription = "Edit the non-secret connection metadata of an existing paired SSH task machine. Use ssh.listHosts first. Authentication secrets and host-key trust remain user-controlled in the native host editor."
    public static let parametersJSON = #"{"type":"object","properties":{"hostID":{"type":"string"},"displayName":{"type":"string"},"address":{"type":"string"},"port":{"type":"integer","minimum":1,"maximum":65535},"user":{"type":"string"}},"required":["hostID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.persistsPersonalData, .networkAccess]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    private let store: RemoteHostStore

    public init(store: RemoteHostStore) { self.store = store }
    public func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.hostID) != nil else { throw FloeError.validationFailed("hostID must be a UUID") }
        if let port = args.port, !(1...65535).contains(port) { throw FloeError.validationFailed("port must be 1-65535") }
        if let address = args.address, address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FloeError.validationFailed("address must not be empty")
        }
        if let user = args.user, user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FloeError.validationFailed("user must not be empty")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let id = UUID(uuidString: args.hostID)!
        guard var host = try await store.host(id: id) else { throw FloeError.validationFailed("paired host not found") }
        if let value = args.displayName { host.displayName = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = args.address { host.address = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = args.port { host.port = value }
        if let value = args.user { host.user = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        try await store.saveHost(host)
        let data = try JSONSerialization.data(withJSONObject: ["updated": true, "hostID": id.uuidString], options: [.sortedKeys])
        return ToolExecutionOutput(summary: String(decoding: data, as: UTF8.self), fullOutputSHA256: digest(data), exitStatus: 0)
    }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

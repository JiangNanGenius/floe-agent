import Foundation
import Crypto
import FloeCore
import FloeTools
import FloePersistence
import FloeSSH

public struct SSHListHostsTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public init() {} }
    public static let name = "ssh.listHosts"
    public static let toolDescription = "List saved remote devices, their stable IDs, roles and SSH/VNC/Telnet/TCP/BLE connection metadata. Use this before selecting or editing a device. Credentials are never returned."
    public static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    private let store: RemoteHostStore

    public init(store: RemoteHostStore) { self.store = store }
    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let traceID = UUID().uuidString
        let startedAt = Date()
        let storedHosts = try await store.hosts()
        let defaultID = storedHosts.first { host in
            guard host.isRemoteExecutionEnvironment ?? true,
                  let auth = try? JSONDecoder().decode(
                    SSHAuthMethod.self,
                    from: Data(host.authJSON.utf8)
                  ) else { return false }
            return auth != .none
        }?.id
        let hosts: [[String: Any]] = storedHosts.map { host in
            let auth = try? JSONDecoder().decode(SSHAuthMethod.self, from: Data(host.authJSON.utf8))
            var endpoints = (try? JSONDecoder().decode(
                [VNCEndpoint].self,
                from: Data((host.vncEndpointsJSON ?? "[]").utf8)
            )) ?? []
            if endpoints.isEmpty, let legacyJSON = host.vncEndpointJSON,
               let legacy = try? JSONDecoder().decode(VNCEndpoint.self, from: Data(legacyJSON.utf8)) {
                endpoints = [legacy]
            }
            let vncConnections: [[String: Any]] = endpoints.map { endpoint in
                ["id": endpoint.id.uuidString,
                 "displayName": endpoint.displayName,
                 "transport": endpoint.transport.rawValue,
                 "host": endpoint.host,
                 "port": endpoint.port,
                 "passwordConfigured": endpoint.passwordRef != nil]
            }
            let auxiliary = (try? JSONSerialization.jsonObject(
                with: Data((host.auxiliaryConnectionsJSON ?? "[]").utf8)
            )) as? [Any] ?? []
            return ["id": host.id.uuidString, "name": host.displayName, "address": host.address,
                    "port": host.port, "user": host.user, "default": host.id == defaultID,
                    "sshEnabled": auth.map { $0 != .none } ?? false,
                    "deviceKind": host.deviceKind ?? "unspecified",
                    "remoteExecutionEnvironment": host.isRemoteExecutionEnvironment ?? true,
                    "vncConnections": vncConnections,
                    "otherConnections": auxiliary]
        }
        FloeLogger(category: .ssh).info(
            "sshHostListFinished trace=\(traceID) count=\(hosts.count) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
        )
        let data = try JSONSerialization.data(withJSONObject: ["hosts": hosts], options: [.sortedKeys])
        return ToolExecutionOutput(summary: String(decoding: data, as: UTF8.self), fullOutputSHA256: digest(data), exitStatus: 0)
    }
}

public struct SSHUpdateHostTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public struct VNCConnection: Decodable, Sendable {
            public var id: String?
            public var displayName: String
            public var transport: VNCTransport
            public var host: String
            public var port: Int
        }

        public struct AuxiliaryConnection: Decodable, Sendable {
            public var id: String?
            public var displayName: String
            public var kind: RemoteAuxiliaryConnectionKind
            public var host: String?
            public var port: Int?
            public var bluetoothPeripheralID: String?
            public var bluetoothServiceUUID: String?
            public var bluetoothWriteCharacteristicUUID: String?
            public var bluetoothNotifyCharacteristicUUID: String?
        }

        public var hostID: String
        public var displayName: String?
        public var address: String?
        public var port: Int?
        public var user: String?
        public var isSSHEnabled: Bool?
        public var deviceKind: RemoteDeviceKind?
        public var isRemoteExecutionEnvironment: Bool?
        public var vncConnections: [VNCConnection]?
        public var auxiliaryConnections: [AuxiliaryConnection]?
    }
    public static let name = "ssh.updateHost"
    public static let toolDescription = "Edit a saved device's non-secret metadata and connection profiles. Use ssh.listHosts first. Device kind is optional descriptive metadata and never overrides configured protocols. You may add direct or SSH-tunnel VNC, Telnet, TCP and BLE serial metadata after configuring a service. Omitted fields are preserved; supplied connection arrays replace that connection group. Never request or place passwords in this tool."
    public static let parametersJSON = #"{"type":"object","properties":{"hostID":{"type":"string"},"displayName":{"type":"string"},"address":{"type":"string"},"port":{"type":"integer","minimum":1,"maximum":65535},"user":{"type":"string"},"isSSHEnabled":{"type":"boolean"},"deviceKind":{"type":"string","enum":["unspecified","linux","mac","windows","nas","router","switchDevice","appliance","other"]},"isRemoteExecutionEnvironment":{"type":"boolean"},"vncConnections":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"displayName":{"type":"string"},"transport":{"type":"string","enum":["direct","sshTunnel"]},"host":{"type":"string"},"port":{"type":"integer","minimum":1,"maximum":65535}},"required":["displayName","transport","host","port"],"additionalProperties":false}},"auxiliaryConnections":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"displayName":{"type":"string"},"kind":{"type":"string","enum":["telnet","tcp","bluetoothSerial"]},"host":{"type":"string"},"port":{"type":"integer","minimum":1,"maximum":65535},"bluetoothPeripheralID":{"type":"string"},"bluetoothServiceUUID":{"type":"string"},"bluetoothWriteCharacteristicUUID":{"type":"string"},"bluetoothNotifyCharacteristicUUID":{"type":"string"}},"required":["displayName","kind"],"additionalProperties":false}}},"required":["hostID"],"additionalProperties":false}"#
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
        for endpoint in args.vncConnections ?? [] {
            if endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(1...65535).contains(endpoint.port) {
                throw FloeError.validationFailed("VNC host and port must be valid")
            }
            if let id = endpoint.id, UUID(uuidString: id) == nil {
                throw FloeError.validationFailed("VNC connection id must be a UUID")
            }
        }
        for connection in args.auxiliaryConnections ?? [] {
            if let id = connection.id, UUID(uuidString: id) == nil {
                throw FloeError.validationFailed("connection id must be a UUID")
            }
            switch connection.kind {
            case .telnet, .tcp:
                guard connection.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      let port = connection.port, (1...65535).contains(port) else {
                    throw FloeError.validationFailed("TCP/Telnet host and port must be valid")
                }
            case .bluetoothSerial:
                guard connection.bluetoothPeripheralID.flatMap(UUID.init(uuidString:)) != nil,
                      connection.bluetoothServiceUUID?.isEmpty == false,
                      connection.bluetoothWriteCharacteristicUUID?.isEmpty == false else {
                    throw FloeError.validationFailed("BLE serial metadata is incomplete")
                }
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let traceID = UUID().uuidString
        let startedAt = Date()
        let id = UUID(uuidString: args.hostID)!
        let changedFields = [args.displayName == nil ? nil : "displayName", args.address == nil ? nil : "address",
                             args.port == nil ? nil : "port", args.user == nil ? nil : "user",
                             args.isSSHEnabled == nil ? nil : "sshEnabled",
                             args.deviceKind == nil ? nil : "deviceKind",
                             args.isRemoteExecutionEnvironment == nil ? nil : "remoteExecutionEnvironment",
                             args.vncConnections == nil ? nil : "vncConnections",
                             args.auxiliaryConnections == nil ? nil : "auxiliaryConnections"].compactMap { $0 }
        FloeLogger(category: .ssh).info(
            "sshHostUpdateStarted trace=\(traceID) host=\(id.uuidString) fields=\(changedFields.joined(separator: ","))"
        )
        guard var host = try await store.host(id: id) else {
            FloeLogger(category: .ssh).warning(
                "sshHostUpdateFailed trace=\(traceID) host=\(id.uuidString) reason=notFound"
            )
            throw FloeError.validationFailed("paired host not found")
        }
        if let value = args.displayName { host.displayName = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = args.address { host.address = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = args.port { host.port = value }
        if let value = args.user { host.user = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if args.isSSHEnabled == false {
            host.authJSON = String(decoding: try JSONEncoder().encode(SSHAuthMethod.none), as: UTF8.self)
            host.isRemoteExecutionEnvironment = false
        } else if args.isSSHEnabled == true {
            guard let current = try? JSONDecoder().decode(
                SSHAuthMethod.self,
                from: Data(host.authJSON.utf8)
            ), current != .none else {
                throw FloeError.validationFailed("Enable SSH in device settings so its credential can be saved securely")
            }
        }
        if let value = args.deviceKind { host.deviceKind = value.rawValue }
        if let value = args.isRemoteExecutionEnvironment { host.isRemoteExecutionEnvironment = value }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let values = args.vncConnections {
            var previous = ((try? JSONDecoder().decode(
                [VNCEndpoint].self,
                from: Data((host.vncEndpointsJSON ?? "[]").utf8)
            )) ?? [])
            if previous.isEmpty,
               let legacyJSON = host.vncEndpointJSON,
               let legacy = try? JSONDecoder().decode(VNCEndpoint.self, from: Data(legacyJSON.utf8)) {
                previous = [legacy]
            }
            let endpoints = values.map { value in
                let id = value.id.flatMap(UUID.init(uuidString:)) ?? UUID()
                return VNCEndpoint(
                    id: id, displayName: value.displayName,
                    transport: value.transport, host: value.host, port: value.port,
                    passwordRef: previous.first(where: { $0.id == id })?.passwordRef
                )
            }
            host.vncEndpointsJSON = String(decoding: try encoder.encode(endpoints), as: UTF8.self)
            host.vncEndpointJSON = try endpoints.first.map {
                String(decoding: try encoder.encode($0), as: UTF8.self)
            }
        }
        if let values = args.auxiliaryConnections {
            let connections = values.map { value in
                RemoteAuxiliaryConnection(
                    id: value.id.flatMap(UUID.init(uuidString:)) ?? UUID(),
                    displayName: value.displayName, kind: value.kind,
                    host: value.host, port: value.port,
                    bluetoothPeripheralID: value.bluetoothPeripheralID.flatMap(UUID.init(uuidString:)),
                    bluetoothServiceUUID: value.bluetoothServiceUUID,
                    bluetoothWriteCharacteristicUUID: value.bluetoothWriteCharacteristicUUID,
                    bluetoothNotifyCharacteristicUUID: value.bluetoothNotifyCharacteristicUUID
                )
            }
            host.auxiliaryConnectionsJSON = String(decoding: try encoder.encode(connections), as: UTF8.self)
        }
        try RemoteHostProfile(stored: host).validate()
        do {
            try await store.saveHost(host)
        } catch {
            let nsError = error as NSError
            FloeLogger(category: .ssh).warning(
                "sshHostUpdateFailed trace=\(traceID) host=\(id.uuidString) domain=\(nsError.domain) code=\(nsError.code) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            throw error
        }
        FloeLogger(category: .ssh).info(
            "sshHostUpdateFinished trace=\(traceID) host=\(id.uuidString) fields=\(changedFields.joined(separator: ",")) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
        )
        var response: [String: Any] = ["updated": true, "hostID": id.uuidString]
        if args.vncConnections != nil {
            let saved = ((try? JSONDecoder().decode(
                [VNCEndpoint].self,
                from: Data((host.vncEndpointsJSON ?? "[]").utf8)
            )) ?? [])
            response["vncConnections"] = saved.map { endpoint in
                ["id": endpoint.id.uuidString,
                 "displayName": endpoint.displayName,
                 "passwordConfigured": endpoint.passwordRef != nil]
            }
            response["credentialUpdated"] = false
            response["credentialNote"] = "This tool preserves existing VNC credentials but cannot create or replace them. Use the device editor for any connection that reports passwordConfigured=false."
        }
        let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        return ToolExecutionOutput(summary: String(decoding: data, as: UTF8.self), fullOutputSHA256: digest(data), exitStatus: 0)
    }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

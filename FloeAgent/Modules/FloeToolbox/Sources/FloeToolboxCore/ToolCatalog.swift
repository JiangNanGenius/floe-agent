import Foundation

public enum ToolboxSpacePage: String, CaseIterable, Sendable { case overview, notes, files, toolbox }
public enum ToolboxGroup: String, CaseIterable, Sendable { case connections, diagnostics, communication, utilities }
public enum ToolboxTool: String, CaseIterable, Sendable, Identifiable {
    case terminal, vnc, browser, ping, traceroute, dns, port, lan, wifi, roaming
    case serialAssistant, http, webSocket, mqtt
    case hash, json, encoding, qr
    public var id: String { rawValue }
    public var group: ToolboxGroup {
        switch self {
        case .terminal, .vnc, .browser: .connections
        case .ping, .traceroute, .dns, .port, .lan, .wifi, .roaming: .diagnostics
        case .serialAssistant, .http, .webSocket, .mqtt: .communication
        default: .utilities
        }
    }
    public var hasAssistant: Bool { self == .terminal || group == .communication }
}

/// Connection and protocol choices inside one serial assistant, not individual home tools.
public enum SerialAssistantConnection: String, Codable, CaseIterable, Sendable {
    case tcp, udp, bluetooth, usb
    public var transport: SerialTransport {
        switch self { case .tcp: .tcp; case .udp: .udp; case .bluetooth: .bluetooth; case .usb: .usb }
    }
}
public enum SerialAssistantProtocol: String, Codable, CaseIterable, Sendable { case raw, modbus }
public enum ModbusFraming: String, Codable, CaseIterable, Sendable { case mbap, rtu }
public struct SerialAssistantConfiguration: Codable, Equatable, Sendable {
    public var connection: SerialAssistantConnection
    public var protocolType: SerialAssistantProtocol
    public var modbusFraming: ModbusFraming?
    public init(connection: SerialAssistantConnection = .tcp, protocolType: SerialAssistantProtocol = .raw,
                modbusFraming: ModbusFraming? = nil) {
        self.connection = connection; self.protocolType = protocolType; self.modbusFraming = modbusFraming
    }
    public func wireProtocol() throws -> SerialProtocol {
        if protocolType == .raw { return .raw }
        guard let modbusFraming else { throw ToolboxError.invalid("select the device's Modbus framing") }
        return modbusFraming == .mbap ? .modbusTCP : .modbusRTU
    }
    /// Bind before creating a session. An active session's endpoint remains immutable.
    public func validate(endpoint: SerialEndpoint) throws {
        try endpoint.validate()
        guard endpoint.transport == connection.transport, endpoint.wireProtocol == (try wireProtocol()) else {
            throw ToolboxError.invalid("serial assistant connection or protocol mismatch")
        }
    }
}
public enum MachineReference: Hashable, Codable, Sendable {
    case builtIn(environmentID: String)
    case systemEnvironment(hostID: UUID)
    case toolboxMachine(hostID: UUID)
    case temporary(connectionID: UUID)
}
public enum ToolboxAvailability: Equatable, Sendable {
    case available, needsConfiguration(String), unsupported(String)
}

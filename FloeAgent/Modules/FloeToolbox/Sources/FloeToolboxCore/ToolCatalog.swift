import Foundation

public enum ToolboxSpacePage: String, CaseIterable, Sendable { case overview, notes, files, toolbox }
public enum ToolboxGroup: String, CaseIterable, Sendable { case instruments, connections, diagnostics, communication, utilities }
public enum ToolboxTool: String, CaseIterable, Sendable, Identifiable {
    case terminal, vnc, browser, ping, traceroute, dns, port, lan, wifi, roaming
    case serialAssistant, http, webSocket, mqtt
    case hash, json, encoding, qr
    case level, motion, compass, ruler, measure, calculator, location
    case photoMeasure, barometer, sound, magnifier, scanner, timer
    public var id: String { rawValue }
    public var group: ToolboxGroup {
        switch self {
        case .level, .motion, .compass, .ruler, .measure, .location, .photoMeasure, .barometer, .sound: .instruments
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
public enum ModbusFraming: String, Codable, CaseIterable, Sendable {
    case mbap, rtu, ascii
    public var wireProtocol: SerialProtocol {
        switch self { case .mbap: .modbusTCP; case .rtu: .modbusRTU; case .ascii: .modbusASCII }
    }
    /// ASCII and RTU are serial-line formats. A TCP/UDP connection carrying
    /// either one is a serial gateway or a transparent byte bridge.
    public var isSerialLine: Bool { self != .mbap }
}
public extension SerialProtocol {
    var modbusFraming: ModbusFraming? {
        switch self {
        case .modbusTCP: .mbap
        case .modbusRTU: .rtu
        case .modbusASCII: .ascii
        default: nil
        }
    }
}
public struct SerialAssistantConfiguration: Codable, Equatable, Sendable {
    public var connection: SerialAssistantConnection
    public var protocolType: SerialAssistantProtocol
    public var modbusFraming: ModbusFraming?
    public init(connection: SerialAssistantConnection = .tcp, protocolType: SerialAssistantProtocol = .raw,
                modbusFraming: ModbusFraming? = nil) {
        self.connection = connection; self.protocolType = protocolType; self.modbusFraming = modbusFraming
    }
    /// Native Modbus TCP uses MBAP. Serial transports use RTU or ASCII; the
    /// same serial formats are valid over a TCP/UDP serial gateway.
    public var availableModbusFramings: [ModbusFraming] {
        switch connection {
        case .bluetooth, .usb: [.rtu, .ascii]
        case .tcp, .udp: [.mbap, .rtu, .ascii]
        }
    }
    public func wireProtocol() throws -> SerialProtocol {
        if protocolType == .raw { return .raw }
        guard let modbusFraming else { throw ToolboxError.invalid("select the device's Modbus framing") }
        guard availableModbusFramings.contains(modbusFraming) else {
            throw ToolboxError.invalid("selected framing does not match the connection")
        }
        return modbusFraming.wireProtocol
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

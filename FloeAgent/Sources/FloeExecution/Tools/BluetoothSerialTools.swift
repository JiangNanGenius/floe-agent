import Foundation
import Crypto
import FloeCore
import FloePersistence
import FloeSSH
import FloeTools

public struct BluetoothSerialScanTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public var durationSeconds: Double? }
    public static let name = "bluetooth.serial.scan"
    public static let toolDescription = "Scan nearby Bluetooth Low Energy peripherals for a serial-style GATT connection. Returns system peripheral IDs and names; it does not pair, save or connect."
    public static let parametersJSON = #"{"type":"object","properties":{"durationSeconds":{"type":"number","minimum":1,"maximum":15}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    private let service: any BluetoothSerialServicing
    public init(service: any BluetoothSerialServicing) { self.service = service }
    public func validate(_ args: Arguments) throws {}
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let peripherals = try await service.scan(duration: min(max(args.durationSeconds ?? 5, 1), 15))
        let data = try JSONEncoder().encode(peripherals)
        return bluetoothOutput(String(decoding: data, as: UTF8.self))
    }
}

public struct BluetoothSerialOpenTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var hostID: String?
        public var connectionID: String?
        public var peripheralID: String?
        public var serviceUUID: String?
        public var writeCharacteristicUUID: String?
        public var notifyCharacteristicUUID: String?
        public var timeoutSeconds: Double?
    }
    public static let name = "bluetooth.serial.open"
    public static let toolDescription = "Open a run-scoped BLE serial session for a user-selected peripheralID or saved connection. Omit service/write/notify UUIDs to discover exact supported UART profiles automatically. If channelSelectionRequired is returned, ask the user to choose a returned channel, then reuse its exact endpoint fields; never guess UUIDs or send probe bytes. Success includes the actual resolved endpoint. Authentication is system-owned, not proof of pairing. Temporary details are never saved or synced; sessions expire after 30 minutes."
    public static let parametersJSON = #"{"type":"object","properties":{"hostID":{"type":"string"},"connectionID":{"type":"string"},"peripheralID":{"type":"string"},"serviceUUID":{"type":"string"},"writeCharacteristicUUID":{"type":"string"},"notifyCharacteristicUUID":{"type":"string"},"timeoutSeconds":{"type":"number","minimum":1,"maximum":30}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
    private let service: any BluetoothSerialServicing
    private let store: RemoteHostStore

    public init(service: any BluetoothSerialServicing, store: RemoteHostStore) {
        self.service = service
        self.store = store
    }

    public func validate(_ args: Arguments) throws {
        let saved = args.hostID != nil || args.connectionID != nil
        if saved {
            guard args.hostID.flatMap(UUID.init(uuidString:)) != nil,
                  args.connectionID.flatMap(UUID.init(uuidString:)) != nil else {
                throw FloeError.validationFailed("Saved BLE connection requires UUID hostID and connectionID")
            }
        } else {
            guard args.peripheralID.flatMap(UUID.init(uuidString:)) != nil else {
                throw FloeError.validationFailed("Temporary BLE serial requires a selected peripheralID")
            }
            try Self.explicitEndpoint(args, peripheralID: UUID(uuidString: args.peripheralID!)!)?.validate()
        }
        if let timeout = args.timeoutSeconds, !timeout.isFinite || !(1...30).contains(timeout) {
            throw FloeError.validationFailed("timeoutSeconds must be finite and between 1 and 30")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try validate(args)
        let selection = try await resolve(args)
        try context.cancellation.throwIfCancelled()
        do {
            let opened = try await BluetoothSerialConnector.open(service: service, runID: context.runID,
                peripheralID: selection.id, endpoint: selection.endpoint, timeout: args.timeoutSeconds ?? 15)
            if context.cancellation.isCancelled {
                await service.close(runID: context.runID, sessionID: opened.sessionID)
                throw FloeError.cancelled
            }
            struct Receipt: Encodable {
                let sessionID: UUID
                let peripheralID: UUID
                let endpoint: BluetoothSerialEndpoint
                let persisted: Bool
            }
            let data = try JSONEncoder().encode(Receipt(sessionID: opened.sessionID,
                peripheralID: selection.id, endpoint: opened.endpoint, persisted: false))
            return bluetoothOutput(String(decoding: data, as: UTF8.self))
        } catch BluetoothSerialError.channelSelectionRequired(let channels) {
            try context.cancellation.throwIfCancelled()
            struct ChoiceReceipt: Encodable {
                let status = "channelSelectionRequired"
                let peripheralID: UUID
                let channels: [BluetoothSerialChannel]
                let persisted = false
            }
            let data = try JSONEncoder().encode(ChoiceReceipt(peripheralID: selection.id, channels: channels))
            return bluetoothOutput(String(decoding: data, as: UTF8.self))
        }
    }

    private static func explicitEndpoint(_ args: Arguments, peripheralID: UUID) throws -> BluetoothSerialEndpoint? {
        guard args.serviceUUID != nil || args.writeCharacteristicUUID != nil || args.notifyCharacteristicUUID != nil else { return nil }
        guard let service = args.serviceUUID, let write = args.writeCharacteristicUUID else {
            throw FloeError.validationFailed("An explicit BLE channel requires both serviceUUID and writeCharacteristicUUID")
        }
        let endpoint = BluetoothSerialEndpoint(peripheralID: peripheralID, serviceUUID: service,
            writeCharacteristicUUID: write, notifyCharacteristicUUID: args.notifyCharacteristicUUID)
        try endpoint.validate()
        return endpoint
    }

    private func resolve(_ args: Arguments) async throws -> (id: UUID, endpoint: BluetoothSerialEndpoint?) {
        if let hostID = args.hostID.flatMap(UUID.init(uuidString:)),
           let connectionID = args.connectionID.flatMap(UUID.init(uuidString:)) {
            guard let stored = try await store.host(id: hostID),
                  let json = stored.auxiliaryConnectionsJSON,
                  let connections = try? JSONDecoder().decode([RemoteAuxiliaryConnection].self, from: Data(json.utf8)),
                  let connection = connections.first(where: { $0.id == connectionID && $0.kind == .bluetoothSerial }),
                  let peripheralID = connection.bluetoothPeripheralID,
                  let serviceUUID = connection.bluetoothServiceUUID,
                  let writeUUID = connection.bluetoothWriteCharacteristicUUID else {
                throw FloeError.notFound("Saved BLE serial connection")
            }
            let endpoint = BluetoothSerialEndpoint(peripheralID: peripheralID, serviceUUID: serviceUUID,
                writeCharacteristicUUID: writeUUID, notifyCharacteristicUUID: connection.bluetoothNotifyCharacteristicUUID)
            try endpoint.validate()
            return (peripheralID, endpoint)
        }
        let id = UUID(uuidString: args.peripheralID!)!
        return (id, try Self.explicitEndpoint(args, peripheralID: id))
    }
}

public struct BluetoothSerialExchangeTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var sessionID: String
        public var text: String?
        public var base64: String?
        public var appendNewline: Bool?
        public var waitSeconds: Double?
        public var maxOutputBytes: Int?
    }
    public static let name = "bluetooth.serial.exchange"
    public static let toolDescription = "Send text or bytes to a BLE GATT serial session and read its bounded notification reply. Omit the payload to read buffered notifications."
    public static let parametersJSON = #"{"type":"object","properties":{"sessionID":{"type":"string"},"text":{"type":"string"},"base64":{"type":"string"},"appendNewline":{"type":"boolean"},"waitSeconds":{"type":"number","minimum":0.05,"maximum":30},"maxOutputBytes":{"type":"integer","minimum":1,"maximum":262144}},"required":["sessionID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .executesRemoteCommand]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
    private let service: any BluetoothSerialServicing
    public init(service: any BluetoothSerialServicing) { self.service = service }
    public func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.sessionID) != nil else { throw FloeError.validationFailed("sessionID must be a UUID") }
        guard !(args.text != nil && args.base64 != nil) else { throw FloeError.validationFailed("Use text or base64, not both") }
        if let base64 = args.base64, Data(base64Encoded: base64) == nil { throw FloeError.validationFailed("base64 is invalid") }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        var data = args.text.map { Data($0.utf8) } ?? args.base64.flatMap { Data(base64Encoded: $0) }
        if args.appendNewline == true { data?.append(0x0A) }
        let result = try await service.exchange(
            runID: context.runID,
            sessionID: UUID(uuidString: args.sessionID)!,
            data: data,
            wait: args.waitSeconds ?? 1,
            maxBytes: args.maxOutputBytes ?? 65_536
        )
        let body = String(data: result, encoding: .utf8).map { "encoding=utf8 bytes=\(result.count)\n\($0)" }
            ?? "encoding=base64 bytes=\(result.count)\n\(result.base64EncodedString())"
        return bluetoothOutput(body)
    }
}

public struct BluetoothSerialCloseTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public var sessionID: String }
    public static let name = "bluetooth.serial.close"
    public static let toolDescription = "Close a temporary BLE serial session opened in this run."
    public static let parametersJSON = #"{"type":"object","properties":{"sessionID":{"type":"string"}},"required":["sessionID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false
    private let service: any BluetoothSerialServicing
    public init(service: any BluetoothSerialServicing) { self.service = service }
    public func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.sessionID) != nil else { throw FloeError.validationFailed("sessionID must be a UUID") }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        await service.close(runID: context.runID, sessionID: UUID(uuidString: args.sessionID)!)
        return bluetoothOutput("closed=true")
    }
}

private func bluetoothOutput(_ text: String) -> ToolExecutionOutput {
    return ToolExecutionOutput(digesting: text, exitStatus: 0)
}

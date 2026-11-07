// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore
import FloeExecution
import FloeToolboxCore
import FloeToolboxClients
import FloeToolboxHost
import FloeToolboxUI
import FloeToolboxWorkbenches

nonisolated enum ToolboxHostConnectionError: Error, LocalizedError {
    case usbHostUnavailable
    var errorDescription: String? { IDELanguageRunText.t("USB 驱动宿主尚未启用，当前不能连接 USB 设备。请选择其他连接方式。", "The USB driver host is not enabled. Choose another connection type.") }
}

nonisolated struct ToolboxConnectionSetup: Sendable {
    var usbVendorID = ""
    var usbProductID = ""
    var usbBaud = "115200"
    var address = ""
    var port = ""
    var useTLS = false
    var serial = SerialAssistantConfiguration()
    var bluetooth: BluetoothSerialEndpoint?
    var mqttVersion = MQTTVersion.v5
    var username = ""
    var password = ""
    var networkTimeoutSeconds: TimeInterval = 30
}

/// Models, the sole receive pump and cancellation belong to this service
/// owner. Closing an inspector or rebuilding its View does not replace it.
@MainActor final class ToolboxConnection: ObservableObject, Identifiable {
    let id: UUID
    let tool: ToolboxTool
    let lease: SessionLease
    let journal: CaptureJournal
    let redactor: CaptureRedactor
    @Published private(set) var active = true
    private(set) var serial: SerialSession?
    private(set) var modbus: ModbusClient?
    private(set) var mqtt: MQTTClient?
    private(set) var http: HTTPDebugSession?
    private(set) var httpModel: HTTPWorkbenchModel?
    private(set) var webSocketModel: WebSocketWorkbenchModel?
    private(set) var mqttModel: MQTTWorkbenchModel?
    private(set) var modbusModel: ModbusWorkbenchModel?
    private(set) var serialModel: SerialPanelModel?
    private var receiver: SerialReceiveService?
    private var transport: (any SerialConnection)?

    private init(tool: ToolboxTool, lease: SessionLease, journal: CaptureJournal, redactor: CaptureRedactor) {
        id = lease.ownerID; self.tool = tool; self.lease = lease; self.journal = journal; self.redactor = redactor
    }
    static func open(tool: ToolboxTool, setup: ToolboxConnectionSetup, environment: AppEnvironment,
                     workbenchModels: Bool = true) async throws -> ToolboxConnection {
        let lease = SessionLease(ownerID: UUID())
        let root = try PersonalContentLibrary.applicationRoot().deletingLastPathComponent().appendingPathComponent("Toolbox", isDirectory: true)
        let repository = ToolboxCaptureStore(database: environment.database, exportRoot: root.appendingPathComponent("Exports"))
        let redactor = CaptureRedactor(knownSecrets: [setup.password, setup.username].filter { !$0.isEmpty }.map { Data($0.utf8) })
        let journal = try await CaptureJournal(ownerID: lease.ownerID, captureID: lease.sessionID,
            repository: repository, limits: CaptureLimits(), redactor: redactor)
        try await repository.describe(captureID: lease.sessionID, ownerID: lease.ownerID, title: tool.rawValue, kind: tool.rawValue)
        let owner = ToolboxConnection(tool: tool, lease: lease, journal: journal, redactor: redactor)
        // The native Connect/Send controls authorize their exact connection.
        // Agent dispatch additionally checks its existing policy/grant before
        // entering this Core seam; neither captured bytes nor arguments can
        // change this immutable target.
        let authorize: SerialAuthorizer = { [weak owner] request in
            await MainActor.run { owner?.active == true && owner?.lease == request.lease }
        }
        let provider = ToolboxCurrentAnalysisProvider(resolve: { [weak environment] in
            guard let environment else { return nil }
            return ToolboxAnalysisProvider.configured(in: environment)
        })
        do {
            switch tool {
            case .http:
                guard let url = URL(string: setup.address), ["https", "http"].contains(url.scheme), url.host != nil else {
                    throw ClientError.invalidConfiguration
                }
                let session = try HTTPDebugSession(lease: lease, targetURL: url, journal: journal, redactor: redactor, authorize: authorize)
                owner.http = session
                owner.httpModel = HTTPWorkbenchModel(session: session, targetURL: url, journal: journal, provider: provider)
            case .webSocket:
                guard let url = URL(string: setup.address) else { throw ClientError.invalidConfiguration }
                let connection = try await WebSocketClientConnection.connect(url: url, timeout: setup.networkTimeoutSeconds)
                owner.transport = connection
                let endpoint = try SerialEndpoint(title: "WebSocket", transport: .webSocket, wireProtocol: .webSocketMessage, host: setup.address)
                let session = try SerialSession(lease: lease, endpoint: endpoint, journal: journal, connection: connection, redactor: redactor, authorize: authorize)
                owner.serial = session
                if workbenchModels { owner.webSocketModel = try WebSocketWorkbenchModel(session: session, journal: journal, provider: provider) }
            case .mqtt:
                guard let port = UInt16(setup.port), port > 0 else { throw ClientError.invalidConfiguration }
                let stream = try await NetworkSerialConnection.connect(host: setup.address, port: port,
                    tls: setup.useTLS ? ClientTLSConfiguration() : nil, timeout: setup.networkTimeoutSeconds)
                owner.transport = stream
                let framed = try MQTTFramedConnection(stream: stream)
                let endpoint = try SerialEndpoint(title: "MQTT", transport: .tcp,
                    wireProtocol: setup.mqttVersion == .v5 ? .mqtt5 : .mqtt311, host: setup.address, port: Int(port))
                let session = try SerialSession(lease: lease, endpoint: endpoint, journal: journal, connection: framed, redactor: redactor, authorize: authorize)
                owner.serial = session
                let client = try MQTTClient(configuration: MQTTConfiguration(version: setup.mqttVersion,
                    clientID: "floe-" + lease.sessionID.uuidString), session: session)
                owner.mqtt = client
                try await client.connect(username: setup.username.isEmpty ? nil : setup.username,
                    password: setup.password.isEmpty ? nil : Data(setup.password.utf8), timeout: min(setup.networkTimeoutSeconds, 15))
                if workbenchModels { owner.mqttModel = MQTTWorkbenchModel(client: client, journal: journal, provider: provider) }
            case .serialAssistant:
                if setup.serial.connection == .usb { throw ToolboxHostConnectionError.usbHostUnavailable }
                let wire = try setup.serial.wireProtocol()
                let endpoint: SerialEndpoint
                let connection: any SerialConnection
                if setup.serial.connection == .bluetooth {
                    guard let bluetooth = setup.bluetooth else { throw ClientError.invalidConfiguration }
                    endpoint = try SerialEndpoint(title: "Bluetooth", transport: .bluetooth, wireProtocol: wire,
                        peripheralID: bluetooth.peripheralID, serviceUUID: bluetooth.serviceUUID,
                        writeCharacteristicUUID: bluetooth.writeCharacteristicUUID, notifyCharacteristicUUID: bluetooth.notifyCharacteristicUUID)
                    connection = try await ToolboxBluetoothBridge.open(service: environment.bluetoothSerialService, runID: lease.ownerID, endpoint: bluetooth)
                } else {
                    guard setup.serial.connection != .usb, let port = UInt16(setup.port), port > 0 else { throw ClientError.unsupported }
                    endpoint = try SerialEndpoint(title: setup.address, transport: setup.serial.connection.transport,
                        wireProtocol: wire, host: setup.address, port: Int(port))
                    connection = try await NetworkSerialConnection.connect(host: setup.address, port: port,
                        kind: setup.serial.connection == .udp ? .udp : .tcp,
                        tls: setup.useTLS ? ClientTLSConfiguration() : nil)
                }
                owner.transport = connection
                try setup.serial.validate(endpoint: endpoint)
                let session = try SerialSession(lease: lease, endpoint: endpoint, journal: journal, connection: connection, redactor: redactor, authorize: authorize)
                owner.serial = session
                if setup.serial.protocolType == .modbus {
                    let client = try ModbusClient(session: session)
                    owner.modbus = client
                    owner.modbusModel = ModbusWorkbenchModel(client: client, journal: journal, provider: provider)
                } else {
                    let model = SerialPanelModel(session: session, journal: journal, provider: provider)
                    owner.serialModel = model
                    let receiver = SerialReceiveService(session: session, updated: { [weak model] in await model?.refresh() })
                    owner.receiver = receiver
                    try await receiver.start()
                }
            default: throw ClientError.unsupported
            }
            try Task.checkCancellation()
            return owner
        } catch { await owner.close(); throw error }
    }
    func invalidate() {
        active = false
        httpModel?.capture.cancelAnalysis()
        webSocketModel?.capture.cancelAnalysis()
        mqttModel?.capture.cancelAnalysis()
        modbusModel?.capture.cancelAnalysis()
    }
    func close() async {
        invalidate()
        await receiver?.close(); receiver = nil
        await mqttModel?.close()
        if mqttModel == nil { await mqtt?.disconnect() }
        await http?.close()
        await serial?.close()
        await transport?.close(); transport = nil
    }
    func frozenHost(runID: UUID) throws -> ToolboxAIHostContext {
        guard active else { throw ToolboxError.staleSession }
        return try ToolboxAIHostContext(runID: runID, lease: lease, journal: journal,
            serial: serial, modbus: modbus, mqtt: mqtt, http: http, redactor: redactor,
            isCurrent: { [weak self] in await MainActor.run { self?.active == true } })
    }
}

nonisolated struct ToolboxCurrentAnalysisProvider: SerialAnalysisProvider {
    let resolve: @MainActor @Sendable () -> ToolboxAnalysisProvider?
    func analyze(_ context: SerialAnalysisContext, question: String) async throws -> SerialAnalysisResult {
        guard let provider = await resolve() else {
            throw FloeError.validationFailed("Configure a text model in Settings.")
        }
        return try await provider.analyze(context, question: question)
    }
}
#endif

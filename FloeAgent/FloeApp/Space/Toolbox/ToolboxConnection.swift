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
import FloeToolboxUSB

nonisolated enum ToolboxConnectionInputIssue: Error, LocalizedError, Equatable, Sendable {
    enum Field: String, Sendable { case address, port, bluetooth }
    case addressRequired, webSocketURLRequired, invalidWebSocketURL, invalidHost, portRequired, invalidPort
    case bluetoothDeviceRequired, invalidBluetoothChannel
    var field: Field {
        switch self {
        case .portRequired, .invalidPort: .port
        case .bluetoothDeviceRequired, .invalidBluetoothChannel: .bluetooth
        default: .address
        }
    }
    var errorDescription: String? {
        switch self {
        case .bluetoothDeviceRequired:
            IDELanguageRunText.t("请选择蓝牙设备。", "Choose a Bluetooth device.")
        case .invalidBluetoothChannel:
            IDELanguageRunText.t("请检查高级通道设置。", "Check the advanced channel settings.")
        case .addressRequired:
            IDELanguageRunText.t("请输入服务器主机名或 IP 地址。", "Enter the server hostname or IP address.")
        case .webSocketURLRequired:
            IDELanguageRunText.t("请输入 WebSocket 地址（ws:// 或 wss://）。", "Enter a WebSocket address starting with ws:// or wss://.")
        case .invalidWebSocketURL:
            IDELanguageRunText.t("请输入完整的 ws:// 或 wss:// 地址；端口须为 1–65535，地址中不能包含用户名、密码或 # 片段。", "Enter a complete ws:// or wss:// address. Ports must be 1–65535; remove any username, password or # fragment.")
        case .invalidHost:
            IDELanguageRunText.t("请输入主机名或 IP 地址，端口请填在下方。", "Enter a hostname or IP address, with its port in the field below.")
        case .portRequired:
            IDELanguageRunText.t("请输入端口（1–65535）。", "Enter a port from 1 to 65535.")
        case .invalidPort:
            IDELanguageRunText.t("端口须为 1–65535 的整数。", "The port must be an integer from 1 to 65535.")
        }
    }
}

nonisolated struct ToolboxConnectionSetup: Sendable {
    var usbBaud = "115200"
    var usbDataBits: UInt8 = 8
    var usbStopBits: UInt8 = 1
    var usbParity: UInt8 = 0
    var usbRequest: ToolboxUSBOpenRequest?
    var address = ""
    var port = ""
    var useTLS = false
    var serial = SerialAssistantConfiguration()
    var bluetooth: BluetoothSerialEndpoint?
    var bluetoothPeripheralID: UUID?
    var mqttVersion = MQTTVersion.v5
    var username = ""
    var password = ""
    var networkTimeoutSeconds: TimeInterval = 30

    /// The form and actual service share field validation. No connection,
    /// journal or persisted capture is created for these input errors.
    func inputIssues(for tool: ToolboxTool) -> [ToolboxConnectionInputIssue] {
        switch tool {
        case .serialAssistant where serial.connection == .bluetooth:
            guard let id = bluetoothPeripheralID ?? bluetooth?.peripheralID else { return [.bluetoothDeviceRequired] }
            if let bluetooth, bluetooth.peripheralID != id || (try? bluetooth.validate()) == nil { return [.invalidBluetoothChannel] }
            return []
        case .webSocket:
            guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [.webSocketURLRequired] }
            guard let url = URL(string: address), let host = url.host,
                  !host.isEmpty, host.utf8.count <= 253, url.fragment == nil,
                  url.port.map({ (1...65535).contains($0) }) ?? true,
                  (try? SerialEndpoint(title: "WebSocket", transport: .webSocket,
                    wireProtocol: .webSocketMessage, host: address)) != nil else { return [.invalidWebSocketURL] }
            return []
        case .mqtt:
            var issues: [ToolboxConnectionInputIssue] = []
            if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.addressRequired)
            } else if (try? SerialEndpoint(title: "MQTT", transport: .tcp, wireProtocol: .mqtt5,
                                           host: address, port: 1)) == nil {
                // Reuse the transport's host grammar; validate the actual port separately.
                issues.append(.invalidHost)
            }
            if port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.portRequired) }
            else if !port.utf8.allSatisfy({ (48...57).contains($0) }) || UInt16(port).map({ $0 > 0 }) != true {
                issues.append(.invalidPort)
            }
            return issues
        default: return []
        }
    }

    func usbSettings() throws -> USBSerialSettings {
        guard let baud = UInt32(usbBaud.trimmingCharacters(in: .whitespacesAndNewlines)),
              let parity = USBSerialSettings.Parity(rawValue: usbParity) else { throw ToolboxUSBFailure.invalidSettings }
        do { return try USBSerialSettings(baud: baud, dataBits: usbDataBits, stopBits: usbStopBits, parity: parity) }
        catch { throw ToolboxUSBFailure.invalidSettings }
    }
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
    private(set) var bluetoothEndpoint: BluetoothSerialEndpoint?
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

    static var includesUSBSerialDriver: Bool {
        if case .bundledUnverified = USBDriverPackage.inspect(in: Bundle.main.bundleURL) { return true }
        return false
    }

    private init(tool: ToolboxTool, lease: SessionLease, journal: CaptureJournal, redactor: CaptureRedactor) {
        id = lease.ownerID; self.tool = tool; self.lease = lease; self.journal = journal; self.redactor = redactor
    }
    static func open(tool: ToolboxTool, setup: ToolboxConnectionSetup, environment: AppEnvironment,
                     workbenchModels: Bool = true,
                     onUSBFailure: (@MainActor @Sendable (ToolboxUSBFailure) -> Void)? = nil,
                     onBluetoothFailure: (@MainActor @Sendable (any Error) -> Void)? = nil) async throws -> ToolboxConnection {
        // USB serial is deferred from this candidate until its distribution
        // permission is granted and the driver is included in an App build.
        if tool == .serialAssistant, setup.serial.connection == .usb {
            guard includesUSBSerialDriver else {
                throw ClientError.unsupported
            }
        }
        if let issue = setup.inputIssues(for: tool).first { throw issue }
        if tool == .serialAssistant, setup.serial.connection == .usb {
            guard let request = setup.usbRequest else { throw ToolboxUSBFailure.chooseDevice }
            try request.validate()
        }
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
                let wire = try setup.serial.wireProtocol()
                let endpoint: SerialEndpoint
                let connection: any SerialConnection
                if setup.serial.connection == .usb {
                    guard let request = setup.usbRequest else { throw ToolboxUSBFailure.chooseDevice }
                    let usb = try await request.open()
                    let adapter = ToolboxUSBTransport(connection: usb, failed: { [weak owner] failure in
                        await MainActor.run {
                            guard let owner, owner.active else { return }
                            owner.invalidate(); onUSBFailure?(failure)
                        }
                        await owner?.close()
                    })
                    owner.transport = adapter // Own immediately, including later DB/session failure.
                    connection = adapter
                    endpoint = try SerialEndpoint(title: request.title, transport: .usb, wireProtocol: wire,
                        usbVendorID: request.device.vendorID, usbProductID: request.device.productID)
                    try await repository.describe(captureID: lease.sessionID, ownerID: lease.ownerID,
                        title: request.title, kind: tool.rawValue)
                    try await journal.append([CaptureEvent(bytes: Data(), direction: .observation, notes: [request.captureDescription])])
                } else if setup.serial.connection == .bluetooth {
                    guard let peripheralID = setup.bluetoothPeripheralID ?? setup.bluetooth?.peripheralID else { throw ToolboxConnectionInputIssue.bluetoothDeviceRequired }
                    let opened = try await ToolboxBluetoothBridge.openResolved(service: environment.bluetoothSerialService,
                        runID: lease.ownerID, peripheralID: peripheralID, endpoint: setup.bluetooth,
                        onFailure: { [weak owner] error in
                            await MainActor.run {
                                guard let owner, owner.active else { return }
                                owner.invalidate(); onBluetoothFailure?(error)
                            }
                        })
                    owner.transport = opened.connection // Own before any later endpoint/session failure.
                    let bluetooth = opened.endpoint
                    owner.bluetoothEndpoint = bluetooth
                    endpoint = try SerialEndpoint(title: "Bluetooth", transport: .bluetooth, wireProtocol: wire,
                        peripheralID: bluetooth.peripheralID, serviceUUID: bluetooth.serviceUUID,
                        writeCharacteristicUUID: bluetooth.writeCharacteristicUUID, notifyCharacteristicUUID: bluetooth.notifyCharacteristicUUID)
                    connection = opened.connection
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
                let session = try SerialSession(lease: lease, endpoint: endpoint, journal: journal, connection: connection, redactor: redactor,
                    maximumExchangeBytes: setup.serial.connection == .usb ? 65_536 : 256 * 1024, authorize: authorize)
                owner.serial = session
                if setup.serial.protocolType == .modbus {
                    let client = try ModbusClient(session: session)
                    owner.modbus = client
                    if workbenchModels { owner.modbusModel = ModbusWorkbenchModel(client: client, journal: journal, provider: provider) }
                } else if workbenchModels {
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
        serialModel?.invalidate()
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

// SPDX-License-Identifier: MPL-2.0
// A user-initiated communication workbench owns one explicitly admitted
// session at a time. This is not an Agent task and cannot grant an Agent or
// a background caller access to the network; the shared clients keep their
// existing lease/authorization/journal boundary.
import Foundation
import FloeToolboxCore
import FloeToolboxClients
import FloeToolboxWorkbenches
import FloeToolboxUI

/// One explicit communication target chosen by the person using the window.
public enum MacCommunicationRequest: Sendable, Equatable {
    case http(URL)
    case webSocket(URL)
    case mqtt(host: String, port: UInt16, tls: Bool, version: MQTTVersion, username: String?, password: String?)
    case serial(host: String, port: UInt16, tls: Bool, configuration: SerialAssistantConfiguration)

    public var tool: ToolboxTool {
        switch self {
        case .http: .http
        case .webSocket: .webSocket
        case .mqtt: .mqtt
        case .serial: .serialAssistant
        }
    }
}

/// Field-level input problems shared by the form and the owner. No journal,
/// connection or persisted capture is created while one of these remains.
public enum MacCommunicationInputIssue: Error, Equatable, Sendable {
    case addressRequired, invalidHost, portRequired, invalidPort
    case webSocketURLRequired, invalidWebSocketURL
    case httpURLRequired, invalidHTTPURL
    case invalidSerialConfiguration

    public var field: MacCommunicationField {
        switch self {
        case .portRequired, .invalidPort: .port
        default: .address
        }
    }
}

public enum MacCommunicationField: String, Sendable { case address, port }

public enum MacCommunicationValidation {
    /// The same shared endpoint grammar the iOS form uses; the Mac surface
    /// must not invent a looser one.
    public static func issues(for request: MacCommunicationRequest) -> [MacCommunicationInputIssue] {
        switch request {
        case .http(let url):
            guard !url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [.httpURLRequired] }
            guard ["https", "http"].contains(url.scheme), url.host != nil else { return [.invalidHTTPURL] }
            return []
        case .webSocket(let url):
            guard !url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [.webSocketURLRequired] }
            guard (try? SerialEndpoint(title: "WebSocket", transport: .webSocket,
                wireProtocol: .webSocketMessage, host: url.absoluteString)) != nil else { return [.invalidWebSocketURL] }
            return []
        case .mqtt(let host, let port, _, _, _, _):
            var issues: [MacCommunicationInputIssue] = []
            if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.addressRequired) }
            else if (try? SerialEndpoint(title: "MQTT", transport: .tcp, wireProtocol: .mqtt5,
                                          host: host, port: 1)) == nil {
                issues.append(.invalidHost)
            }
            if port == 0 { issues.append(.invalidPort) }
            return issues
        case .serial(let host, let port, _, let configuration):
            var issues: [MacCommunicationInputIssue] = []
            if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.addressRequired) }
            if port == 0 { issues.append(.invalidPort) }
            if issues.isEmpty, (try? configuration.wireProtocol()) == nil { issues.append(.invalidSerialConfiguration) }
            if issues.isEmpty, (try? SerialEndpoint(title: host, transport: configuration.connection.transport,
                    wireProtocol: .raw, host: host, port: Int(port))) == nil { issues.append(.invalidHost) }
            return issues
        }
    }
}

/// Mirrors the manual diagnostics gate: one open/closed admission bound to an
/// exact request lease. Late authorizations fail closed after cancel.
final class MacCommunicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    let request: MacCommunicationRequest
    let lease: SessionLease
    init(request: MacCommunicationRequest, lease: SessionLease) { self.request = request; self.lease = lease }
    func close() { lock.withLock { open = false } }
    func isOpen() -> Bool { lock.withLock { open } }
    func allows(_ proposed: SessionLease) -> Bool { isOpen() && proposed == lease }
}

/// Everything one admitted request created. The shared workbench views read
/// the published models; teardown follows the iOS ToolboxConnection order.
@MainActor
public final class MacCommunicationSession {
    public let tool: ToolboxTool
    public let lease: SessionLease
    public let endpointSummary: String
    public private(set) var httpModel: HTTPWorkbenchModel?
    public private(set) var webSocketModel: WebSocketWorkbenchModel?
    public private(set) var mqttModel: MQTTWorkbenchModel?
    public private(set) var serialModel: SerialPanelModel?
    public private(set) var modbusModel: ModbusWorkbenchModel?

    private var http: HTTPDebugSession?
    private var transport: (any SerialConnection)?
    private var serial: SerialSession?
    private var mqtt: MQTTClient?
    private var receiver: SerialReceiveService?
    private let closeHook: (@Sendable () async -> Void)?

    init(tool: ToolboxTool, lease: SessionLease, endpointSummary: String, closeHook: (@Sendable () async -> Void)? = nil) {
        self.tool = tool; self.lease = lease; self.endpointSummary = endpointSummary; self.closeHook = closeHook
    }

    /// Component-test fixture: no network resources, only the close hook.
    static func fixture(tool: ToolboxTool, endpointSummary: String,
                        closeHook: (@Sendable () async -> Void)? = nil) -> MacCommunicationSession {
        MacCommunicationSession(tool: tool, lease: SessionLease(ownerID: UUID()),
                                endpointSummary: endpointSummary, closeHook: closeHook)
    }

    fileprivate func installHTTP(session: HTTPDebugSession, model: HTTPWorkbenchModel) {
        http = session; httpModel = model
    }
    fileprivate func installWebSocket(connection: any SerialConnection, session: SerialSession, model: WebSocketWorkbenchModel) {
        transport = connection; serial = session; webSocketModel = model
    }
    fileprivate func installMQTT(connection: any SerialConnection, session: SerialSession, client: MQTTClient, model: MQTTWorkbenchModel) {
        transport = connection; serial = session; mqtt = client; mqttModel = model
    }
    fileprivate func installSerial(connection: any SerialConnection, session: SerialSession,
                                   panel: SerialPanelModel?, modbus: ModbusWorkbenchModel?, receiver: SerialReceiveService?) {
        transport = connection; serial = session; serialModel = panel; modbusModel = modbus; self.receiver = receiver
    }

    /// Teardown order mirrors the production ToolboxConnection owner:
    /// cancel in-flight analysis, stop the receive pump, disconnect MQTT,
    /// then close the HTTP session, serial session and raw transport.
    public func close() async {
        httpModel?.capture.cancelAnalysis()
        webSocketModel?.capture.cancelAnalysis()
        mqttModel?.capture.cancelAnalysis()
        modbusModel?.capture.cancelAnalysis()
        serialModel?.invalidate()
        await receiver?.close(); receiver = nil
        await mqttModel?.close()
        if mqttModel == nil { await mqtt?.disconnect() }
        await http?.close()
        await serial?.close()
        await transport?.close(); transport = nil
        if let closeHook { await closeHook() }
    }
}

/// Owns exactly one explicitly started communication session and its
/// teardown. Admission closes on app termination preparation and reopens if
/// the user cancels the termination, matching the other toolbox owners.
/// Open and close work stays tracked until it has actually returned, so
/// `drain` cannot report completion while a transport close or a late
/// session from a cancelled open is still in flight.
@MainActor
@Observable
public final class MacCommunicationOwner {
    public private(set) var session: MacCommunicationSession?
    public private(set) var connecting = false
    /// A close or cancelled-open teardown is still running; new admissions
    /// stay blocked and `drain` keeps waiting until it finishes.
    public private(set) var closing = false
    /// The localized reason the last start failed, for inline display.
    public private(set) var failure: String?
    private let storageRoot: URL
    private let timeout: TimeInterval
    private var closed = false
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var activeGate: MacCommunicationGate?
    private var opener: (MacCommunicationRequest, SessionLease, CaptureJournal, CaptureRedactor, @escaping SerialAuthorizer) async throws -> MacCommunicationSession

    public init(storageRoot: URL, networkTimeout: TimeInterval = 30) {
        self.storageRoot = storageRoot
        self.timeout = networkTimeout
        self.opener = { request, lease, journal, redactor, authorize in
            try await MacCommunicationSession.open(request: request, lease: lease, journal: journal,
                                                   redactor: redactor, authorize: authorize, timeout: networkTimeout)
        }
    }

    init(storageRoot: URL, networkTimeout: TimeInterval = 30,
         opener: @escaping (MacCommunicationRequest, SessionLease, CaptureJournal, CaptureRedactor, @escaping SerialAuthorizer) async throws -> MacCommunicationSession) {
        self.storageRoot = storageRoot
        self.timeout = networkTimeout
        self.opener = opener
    }

    @discardableResult
    public func start(_ request: MacCommunicationRequest, locale: Locale = .current) async -> Bool {
        guard !closed, session == nil, openTask == nil, closeTask == nil,
              MacCommunicationValidation.issues(for: request).isEmpty else { return false }
        let lease = SessionLease(ownerID: UUID())
        let gate = MacCommunicationGate(request: request, lease: lease)
        let redactor = MacCommunicationOwner.redactor(for: request)
        let journal: CaptureJournal
        do {
            let root = storageRoot.appendingPathComponent("\(request.tool.rawValue)-\(lease.sessionID.uuidString)", isDirectory: true)
            let repository = try FileCaptureRepository(root: root)
            journal = try await CaptureJournal(ownerID: lease.ownerID, captureID: lease.sessionID,
                                               repository: repository, limits: CaptureLimits(), redactor: redactor)
        } catch {
            failure = MacCommunicationOwner.message(for: error, locale: locale)
            return false
        }
        let opener = self.opener
        activeGate = gate
        connecting = true; failure = nil
        // The task body owns publication and the close of any late session;
        // it clears `openTask` only after that close has returned, so `drain`
        // keeps waiting for the whole lifecycle.
        let task = Task { [weak self] in
            let result: Result<MacCommunicationSession, any Error>
            do {
                let opened = try await opener(request, lease, journal, redactor) { proposal in
                    // The shared clients call this from their own receiver and
                    // sender tasks, where Task cancellation is not visible; the
                    // explicit gate is the only revocation signal.
                    guard gate.isOpen() else { throw ToolboxError.staleSession }
                    return gate.allows(proposal.lease)
                }
                result = .success(opened)
            } catch { result = .failure(error) }
            guard let self else { return }
            activeGate = nil
            if Task.isCancelled || !gate.isOpen() {
                // Cancelled or revoked admission: a session the opener still
                // produced must never become visible; close it under a
                // tracked task so `drain` waits for the teardown to return.
                if case .success(let late) = result {
                    connecting = false
                    closing = true
                    closeTask = Task { [weak self] in
                        await late.close()
                        guard let self else { return }
                        closing = false; closeTask = nil; openTask = nil
                    }
                    return
                }
                connecting = false; openTask = nil
                return
            }
            connecting = false; openTask = nil
            switch result {
            case .success(let value): session = value
            case .failure(let error): failure = MacCommunicationOwner.message(for: error, locale: locale)
            }
        }
        openTask = task
        return true
    }

    /// Cancel the admitted session or an in-flight connect. The gate closes
    /// first so no late authorization passes while teardown runs. The close
    /// itself stays tracked until it has actually returned.
    public func cancel() {
        activeGate?.close()
        if openTask != nil { openTask?.cancel(); return }
        guard let current = session else { return }
        session = nil
        closing = true
        closeTask = Task { [weak self] in
            await current.close()
            guard let self else { return }
            closing = false; closeTask = nil
        }
    }

    public func closeAdmissions() { closed = true; cancel() }
    public func resumeAfterCancelledTermination() { closed = false }

    public func drain(timeout: TimeInterval = 5) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(max(0, timeout))
        while session != nil || openTask != nil || closeTask != nil {
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return true
    }

    static func redactor(for request: MacCommunicationRequest) -> CaptureRedactor {
        switch request {
        case .mqtt(_, _, _, _, let username, let password):
            return CaptureRedactor(knownSecrets: [password ?? "", username ?? ""].filter { !$0.isEmpty }.map { Data($0.utf8) })
        default:
            return CaptureRedactor()
        }
    }

    static func message(for error: any Error, locale: Locale) -> String {
        let text: String
        switch error {
        case ToolboxError.denied:
            text = MacToolboxText.t("此操作未获授权。", "This operation was not authorized.", locale)
        case ToolboxError.staleSession:
            text = MacToolboxText.t("连接已失效。", "The connection is no longer active.", locale)
        case let issue as MacCommunicationInputIssue:
            text = MacToolboxText.t("请检查地址或端口。", "Check the address or port.", locale)
            _ = issue
        case ClientError.invalidConfiguration:
            text = MacToolboxText.t("地址或配置无效。", "The address or configuration is invalid.", locale)
        case ClientError.authenticationFailed:
            text = MacToolboxText.t("TLS 验证失败。", "TLS verification failed.", locale)
        case is CancellationError:
            text = MacToolboxText.t("已取消。", "Cancelled.", locale)
        default:
            text = MacToolboxText.t("未能完成连接，请检查目标、网络连接及系统权限后重试。",
                                    "Could not connect. Check the target, network and system permissions, then try again.", locale)
        }
        return text
    }
}

extension MacCommunicationSession {
    /// Opens the real shared clients for one admitted request. This is the
    /// Mac equivalent of the iOS ToolboxConnection.open seam; endpoint
    /// choices stay immutable once the session exists.
    static func open(request: MacCommunicationRequest, lease: SessionLease, journal: CaptureJournal,
                     redactor: CaptureRedactor, authorize: @escaping SerialAuthorizer,
                     timeout: TimeInterval) async throws -> MacCommunicationSession {
        switch request {
        case .http(let url):
            let target = url.absoluteString
            let session = try HTTPDebugSession(lease: lease, targetURL: url, journal: journal, redactor: redactor, authorize: authorize)
            let owner = MacCommunicationSession(tool: .http, lease: lease, endpointSummary: session.endpoint.host ?? target)
            owner.installHTTP(session: session, model: HTTPWorkbenchModel(session: session, targetURL: url, journal: journal, provider: nil))
            return owner
        case .webSocket(let url):
            let connection = try await WebSocketClientConnection.connect(url: url, timeout: timeout)
            let endpoint = try SerialEndpoint(title: "WebSocket", transport: .webSocket,
                                              wireProtocol: .webSocketMessage, host: url.absoluteString)
            let session = try SerialSession(lease: lease, endpoint: endpoint, journal: journal,
                                            connection: connection, redactor: redactor, authorize: authorize)
            let owner = MacCommunicationSession(tool: .webSocket, lease: lease, endpointSummary: url.absoluteString)
            owner.installWebSocket(connection: connection, session: session,
                                   model: try WebSocketWorkbenchModel(session: session, journal: journal, provider: nil))
            return owner
        case .mqtt(let host, let port, let tls, let version, let username, let password):
            let stream = try await NetworkSerialConnection.connect(host: host, port: port,
                tls: tls ? ClientTLSConfiguration() : nil, timeout: timeout)
            let endpoint = try SerialEndpoint(title: "MQTT", transport: .tcp,
                wireProtocol: version == .v5 ? .mqtt5 : .mqtt311, host: host, port: Int(port))
            let session = try SerialSession(lease: lease, endpoint: endpoint, journal: journal,
                                            connection: stream, redactor: redactor, authorize: authorize)
            let client = try MQTTClient(configuration: MQTTConfiguration(
                version: version, clientID: "floe-" + lease.sessionID.uuidString), session: session)
            do {
                try await client.connect(username: username, password: password.map { Data($0.utf8) },
                                         timeout: min(timeout, 15))
            } catch {
                await session.close(); await stream.close()
                throw error
            }
            let owner = MacCommunicationSession(tool: .mqtt, lease: lease, endpointSummary: "\(host):\(port)")
            owner.installMQTT(connection: stream, session: session, client: client,
                              model: MQTTWorkbenchModel(client: client, journal: journal, provider: nil))
            return owner
        case .serial(let host, let port, let tls, let configuration):
            let wire = try configuration.wireProtocol()
            let endpoint = try SerialEndpoint(title: host, transport: configuration.connection.transport,
                                              wireProtocol: wire, host: host, port: Int(port))
            try configuration.validate(endpoint: endpoint)
            let connection = try await NetworkSerialConnection.connect(host: host, port: port,
                kind: configuration.connection == .udp ? .udp : .tcp,
                tls: tls ? ClientTLSConfiguration() : nil, timeout: timeout)
            let session = try SerialSession(lease: lease, endpoint: endpoint, journal: journal,
                                            connection: connection, redactor: redactor, authorize: authorize)
            let owner = MacCommunicationSession(tool: .serialAssistant, lease: lease, endpointSummary: "\(host):\(port)")
            if configuration.protocolType == .modbus {
                let client = try ModbusClient(session: session)
                owner.installSerial(connection: connection, session: session, panel: nil,
                                    modbus: ModbusWorkbenchModel(client: client, journal: journal, provider: nil), receiver: nil)
            } else {
                let panel = SerialPanelModel(session: session, journal: journal, provider: nil)
                let pump = SerialReceiveService(session: session, updated: { [weak panel] in await panel?.refresh() })
                owner.installSerial(connection: connection, session: session, panel: panel, modbus: nil, receiver: pump)
                try await pump.start()
            }
            return owner
        }
    }
}

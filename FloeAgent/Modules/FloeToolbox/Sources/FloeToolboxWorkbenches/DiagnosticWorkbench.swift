import Foundation
import SwiftUI
import FloeToolboxCore
import FloeToolboxDiagnostics

public struct DiagnosticDisplayRow: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let value: String
    public var status: DiagnosticDisplayStatus?
    public var ipInformation: TracerouteIPInformation?
    public init(id: UUID = UUID(), title: String, value: String, status: DiagnosticDisplayStatus? = nil,
                ipInformation: TracerouteIPInformation? = nil) {
        self.id = id; self.title = title; self.value = value; self.status = status; self.ipInformation = ipInformation
    }
}
public enum DiagnosticDisplayStatus: Sendable { case timeout, unreachable, open, noConnection }
/// The App supplies its existing authorized service. A protocol also lets
/// focused tests deliver genuine typed responses in a controlled order.
public protocol DiagnosticWorkbenchService: Sendable {
    func ping(target: String, count: Int, timeoutSeconds: Int) async throws -> [PingObservation]
    func traceroute(target: String, maximumHops: Int, timeoutSeconds: Int) async throws -> [TraceHop]
    func traceroute(target: String, maximumHops: Int, timeoutSeconds: Int, requestID: UUID,
                    onObservation: TracerouteObserver?) async throws -> [TraceHop]
    func dns(name: String, type: DNSRecordType, timeout: Double) async throws -> [DNSRecord]
    func ports(target: String, ports: [UInt16], timeout: Double) async throws -> [PortObservation]
    func discover(type: String, seconds: Double) async throws -> [BonjourService]
    func lanScan(types: [String], seconds: Double, onEvent: (@Sendable (LANDiscoveryEvent) -> Void)?) async throws -> LANScanReport
    func stop() async
}
public extension DiagnosticWorkbenchService {
    // Legacy final-only adapters stay source-compatible but cannot pretend to
    // stream by replaying an array after completion.
    func traceroute(target: String, maximumHops: Int, timeoutSeconds: Int, requestID: UUID,
                    onObservation: TracerouteObserver?) async throws -> [TraceHop] {
        throw DiagnosticError.system("Traceroute streaming service is not configured")
    }
    // Existing non-LAN adapters do not gain an invented discovery fallback.
    func lanScan(types: [String], seconds: Double, onEvent: (@Sendable (LANDiscoveryEvent) -> Void)?) async throws -> LANScanReport {
        throw DiagnosticError.system("LAN discovery service is not configured")
    }
}
extension DiagnosticService: DiagnosticWorkbenchService {}

public struct DiagnosticRequestSnapshot: Sendable {
    public let id: UUID
    public let tool: ToolboxTool
    public let target: String
    public let ports: String
    public let recordType: DNSRecordType
    public let serviceType: String
    public let lanConfiguration: LANWorkbenchConfiguration?
    public init(id: UUID, tool: ToolboxTool, target: String, ports: String, recordType: DNSRecordType, serviceType: String, lanConfiguration: LANWorkbenchConfiguration? = nil) {
        self.id = id; self.tool = tool; self.target = target; self.ports = ports
        self.recordType = recordType; self.serviceType = serviceType; self.lanConfiguration = lanConfiguration
    }
    public var description: String {
        switch tool {
        case .dns: String(describing:recordType).uppercased() + " · " + target
        case .port: target + " · " + ports
        case .lan: lanConfiguration?.summary(in: .current) ?? serviceType
        case .wifi: "Wi-Fi"
        default: target
        }
    }
}
public enum DiagnosticRequestState: Sendable { case running, completed, failed, cancelled }
@MainActor public final class DiagnosticWorkbenchModel: ObservableObject {
    @Published public var target = ""
    @Published public var ports = "22, 80, 443"
    @Published public var serviceType = "_http._tcp"
    @Published public var lanConfiguration = LANWorkbenchConfiguration()
    @Published public private(set) var lanServices: [LANDiscoveredService] = []
    @Published public private(set) var lanReport: LANScanReport?
    @Published public var recordType = DNSRecordType.a
    @Published public private(set) var running = false
    @Published public private(set) var stopping = false
    @Published public private(set) var ipInformationRetryable = false
    @Published public private(set) var failed = false
    @Published public private(set) var cancelled = false
    @Published public private(set) var request: DiagnosticRequestSnapshot?
    @Published public private(set) var failure: DiagnosticError?
    @Published public private(set) var rows: [DiagnosticDisplayRow] = []
    public let tool: ToolboxTool
    private let service: any DiagnosticWorkbenchService
    private let mayReadWiFiIdentity: Bool
    private let onRequestState: (@MainActor @Sendable (DiagnosticRequestSnapshot, DiagnosticRequestState) -> Void)?
    private var operation: Task<Void,Never>?
    private var generation = UUID()
    private var closed = false
    private var stopDrain: Task<Void, Never>?
    private var stopGeneration = UUID()
    private let ipInformation: TracerouteIPInformationProvider?
    private var traceHops: [TraceHop] = []
    private var traceRowIDs: [Int: UUID] = [:]
    private var traceAddresses: [Int: String] = [:]
    private var ipGeneration = UUID()
    private var ipQueue: [String] = []
    private var ipFinished: Set<String> = []
    private var ipTasks: [String: Task<Void, Never>] = [:]
    public init(tool: ToolboxTool,service: any DiagnosticWorkbenchService,mayReadWiFiIdentity: Bool = false,
                onRequestState: (@MainActor @Sendable (DiagnosticRequestSnapshot, DiagnosticRequestState) -> Void)? = nil,
                ipInformation: TracerouteIPInformationProvider? = nil) throws {
        guard [.ping,.traceroute,.dns,.port,.lan,.wifi].contains(tool) else { throw DiagnosticError.invalid("diagnostic view") }
        self.tool = tool; self.service = service; self.mayReadWiFiIdentity = mayReadWiFiIdentity
        self.onRequestState = onRequestState; self.ipInformation = ipInformation
    }
    @discardableResult public func run() -> Task<Void,Never>? {
        guard !closed, !running, !stopping else { return nil }
        let frozen = DiagnosticRequestSnapshot(id:UUID(),tool:tool,target:target.trimmingCharacters(in:.whitespacesAndNewlines),
            ports:ports,recordType:recordType,serviceType:serviceType,lanConfiguration:tool == .lan ? lanConfiguration : nil)
        // Rows belong only to this request, including its validation/failure
        // path. Previous successes are never implicitly reused as current data.
        invalidateIPInformation()
        traceHops = []; traceRowIDs = [:]; traceAddresses = [:]
        generation = frozen.id; request = frozen; rows = []; failure = nil
        lanServices = []; lanReport = nil
        cancelled = false; failed = false; running = true
        onRequestState?(frozen, .running)
        let run = frozen.id, target = frozen.target, ports = frozen.ports, type = frozen.recordType
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let results: [DiagnosticDisplayRow]
                var outcome = DiagnosticRequestState.completed
                switch tool {
                case .ping:
                    results = try await service.ping(target:target,count:4,timeoutSeconds:1).map { value in
                        switch value.status {
                        case .reply(let ms): return DiagnosticDisplayRow(title:"\(value.sequence+1) · \(value.address)",value:String(format:"%.2f ms",ms))
                        case .timeout: return DiagnosticDisplayRow(title:"\(value.sequence+1) · \(value.address)",value:"",status:.timeout)
                        case .unreachable: return DiagnosticDisplayRow(title:"\(value.sequence+1) · \(value.address)",value:"",status:.unreachable)
                        }
                    }
                case .traceroute:
                    let finalHops = try await service.traceroute(target: target, maximumHops: 30, timeoutSeconds: 1,
                        requestID: run, onObservation: { [weak self] event in
                            await self?.acceptTrace(event, run: run)
                        })
                    guard generation == run else { return }
                    guard finalHops == traceHops else {
                        throw DiagnosticError.system("Traceroute observations did not match the final report")
                    }
                    // The observed rows already carry their stable identities
                    // and optional enrichment. Never replace them with a final map.
                    results = rows
                case .dns:
                    let records = try await service.dns(name:target,type:type,timeout:5)
                    guard !records.isEmpty else { throw DiagnosticError.dnsNoRecords(target,type) }
                    results = records.map { DiagnosticDisplayRow(title:$0.name,value:$0.text) }
                case .port:
                    let values = ports.split(separator:",",omittingEmptySubsequences:false)
                    let parsed = values.compactMap { UInt16($0.trimmingCharacters(in:.whitespaces)) }
                    guard values.count == parsed.count else { throw DiagnosticError.invalid("ports") }
                    results = try await service.ports(target:target,ports:parsed,timeout:2).map { DiagnosticDisplayRow(title:String($0.port),value:"",status:$0.status == .open ? .open : .noConnection) }
                case .lan:
                    guard let configuration = frozen.lanConfiguration, configuration.isValid else { throw DiagnosticError.invalid("LAN scope") }
                    let report = try await service.lanScan(types:configuration.requestedTypes,seconds:configuration.browseSeconds,onEvent:{ [weak self] event in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == run, self.running else { return }
                            self.acceptLAN(event)
                        }
                    })
                    guard generation == run, !Task.isCancelled else { throw CancellationError() }
                    lanReport = report; lanServices = report.services
                    switch report.status {
                    case .foundDevices, .noDevices: break
                    case .permissionUncertain, .noWiFiPath, .outOfScopeOnly: failed = true; outcome = .failed
                    }
                    results = []
                case .wifi:
                    let identity = try await WiFiObservationService.current(mayReadIdentity:mayReadWiFiIdentity)
                    results = [DiagnosticDisplayRow(title:"SSID",value:identity.ssid ?? "—"),DiagnosticDisplayRow(title:"BSSID",value:identity.bssid ?? "—"),DiagnosticDisplayRow(title:"RSSI",value:identity.signalDBM.map { "\($0) dBm" } ?? "—")]
                default: throw DiagnosticError.invalid("diagnostic")
                }
                guard generation == run else { return }
                guard !Task.isCancelled else {
                    if tool != .traceroute { rows = [] }
                    lanServices = []; lanReport = nil; running = false; operation = nil; cancelled = true
                    onRequestState?(frozen, .cancelled); return
                }
                rows = results; running = false; operation = nil
                onRequestState?(frozen, outcome)
            } catch {
                guard generation == run else { return }
                if tool != .traceroute { rows = [] }
                lanServices = []; lanReport = nil; running = false; operation = nil
                if error is CancellationError || Task.isCancelled || (error as? DiagnosticError) == .stopped {
                    cancelled = true; failed = false; failure = nil
                } else {
                    failure = (error as? DiagnosticError) ?? .system(String(reflecting:error)); failed = true
                }
                onRequestState?(frozen, cancelled ? .cancelled : .failed)
            }
        }
        return operation
    }
    public func cancel() {
        let wasRunning = running
        generation = UUID()
        invalidateIPInformation()
        let previous = operation
        previous?.cancel(); operation = nil; running = false
        if wasRunning {
            if tool != .traceroute { rows = [] }
            lanServices = []; lanReport = nil; failure = nil; failed = false; cancelled = true
            if let request { onRequestState?(request, .cancelled) }
        }
        if tool == .traceroute, let previous, stopDrain == nil {
            // UI cancellation is immediate; Start is briefly gated until this
            // exact worker has acknowledged and closed its own descriptor.
            stopping = true
            let stop = UUID(); stopGeneration = stop
            stopDrain = Task { [weak self] in
                await previous.value
                guard let self, self.stopGeneration == stop else { return }
                self.stopping = false; self.stopDrain = nil
            }
        }
    }
    public func waitUntilStopped() async { await stopDrain?.value }

    /// Display data only. Closing a workbench never preserves a service,
    /// permission, active worker or lease inside this value.
    public struct RetainedTraceroute: Sendable {
        public let request: DiagnosticRequestSnapshot
        public let inputTarget: String
        public let rows: [DiagnosticDisplayRow]
        public let hops: [TraceHop]
        public let cancelled: Bool
        public let failed: Bool
        public let failure: DiagnosticError?
        public func removingIPInformation() -> Self {
            let cleared = rows.map { row in var value = row; value.ipInformation = nil; return value }
            return .init(request: request, inputTarget: inputTarget, rows: cleared, hops: hops,
                         cancelled: cancelled, failed: failed, failure: failure)
        }
    }
    public var retainedTraceroute: RetainedTraceroute? {
        guard tool == .traceroute, let request else { return nil }
        return .init(request: request, inputTarget: target, rows: rows, hops: traceHops,
                     cancelled: cancelled, failed: failed, failure: failure)
    }
    /// A fresh App-owned service must independently authorize the next Start.
    /// Restoring these old results never starts probing or an IP lookup.
    public func restoreTraceroute(_ retained: RetainedTraceroute) {
        guard !closed, tool == .traceroute, request == nil, !running, !stopping,
              retained.request.tool == .traceroute, retained.hops.count <= 30,
              retained.hops.count == retained.rows.count else { return }
        request = retained.request; target = retained.inputTarget; rows = retained.rows
        traceHops = retained.hops; cancelled = retained.cancelled
        failed = retained.failed; failure = retained.failure
        for (hop, row) in zip(traceHops, rows) {
            traceRowIDs[hop.ttl] = row.id
            if let address = hop.address { traceAddresses[hop.ttl] = address }
        }
    }

    private func acceptTrace(_ event: TracerouteObservation, run: UUID) {
        guard generation == run, request?.id == run, event.requestID == run, running else { return }
        guard case .hop(let hop) = event.value else { return }
        guard (1...30).contains(hop.ttl), hop.ttl == traceHops.count + 1,
              hop.milliseconds.count <= 2, hop.milliseconds.allSatisfy({ $0.isFinite && $0 >= 0 }),
              hop.address.map(Self.isNumericIPv4) ?? true else { return }
        if let last = traceHops.last, last.status == .reached || last.status == .unreachable { return }
        switch hop.status {
        case .reached, .intermediate: guard hop.address != nil, !hop.milliseconds.isEmpty else { return }
        case .timeout: guard hop.address == nil, hop.milliseconds.isEmpty else { return }
        case .unreachable: guard hop.milliseconds.isEmpty else { return }
        }
        traceHops.append(hop)
        let id = UUID(); traceRowIDs[hop.ttl] = id
        let status: DiagnosticDisplayStatus?
        switch hop.status { case .timeout: status = .timeout; case .unreachable: status = .unreachable; default: status = nil }
        rows.append(.init(id: id, title: "\(hop.ttl) · \(hop.address ?? "*")",
            value: hop.milliseconds.map { String(format: "%.2f ms", $0) }.joined(separator: " · "), status: status))
        if let address = hop.address {
            traceAddresses[hop.ttl] = address
            enqueueIP(address)
        }
    }
    private static func isNumericIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.utf8.count <= 3 && part.utf8.allSatisfy { (48...57).contains($0) }
                && UInt8(part) != nil
        }
    }
    private func invalidateIPInformation() {
        ipGeneration = UUID()
        for task in ipTasks.values { task.cancel() }
        ipTasks = [:]; ipQueue = []; ipFinished = []; ipInformationRetryable = false
    }
    /// Call after the database service changes its dataset. This cancels old
    /// lookups and invalidates displayed enrichment without touching hops.
    public func refreshIPInformation() {
        invalidateIPInformation()
        for index in rows.indices { rows[index].ipInformation = nil }
        guard !closed, tool == .traceroute, !cancelled, request != nil else { return }
        for address in Set(traceAddresses.values).sorted() { enqueueIP(address) }
    }
    private func enqueueIP(_ address: String) {
        guard ipInformation != nil, !ipFinished.contains(address), ipTasks[address] == nil,
              !ipQueue.contains(address), ipQueue.count < 30 else { return }
        ipQueue.append(address); pumpIP()
    }
    private func pumpIP() {
        guard let provider = ipInformation else { return }
        while ipTasks.count < 4, !ipQueue.isEmpty {
            let address = ipQueue.removeFirst(), run = generation, epoch = ipGeneration
            ipTasks[address] = Task { [weak self] in
                let information: TracerouteIPInformation?
                let succeeded: Bool
                let busy: Bool
                do { information = try await provider.information(for: address); succeeded = true; busy = false }
                catch DiagnosticError.busy { information = nil; succeeded = false; busy = true }
                catch { information = nil; succeeded = false; busy = false }
                guard let self, self.generation == run, self.ipGeneration == epoch, !Task.isCancelled else { return }
                self.ipTasks[address] = nil
                if busy {
                    // Normal saturation waits for a real permit release. Only
                    // bounded-queue overload reaches here; retain retry input.
                    self.ipInformationRetryable = true
                    if !self.ipQueue.contains(address) { self.ipQueue.append(address) }
                    return
                }
                if succeeded { self.ipFinished.insert(address) }
                if let information, information.address == address {
                    for (ttl, expectedAddress) in self.traceAddresses where expectedAddress == address {
                        guard let id = self.traceRowIDs[ttl], let index = self.rows.firstIndex(where: { $0.id == id }) else { continue }
                        self.rows[index].ipInformation = information
                    }
                }
                self.pumpIP()
            }
        }
    }
    public var manualTarget: String? { Self.normalizedTarget(target) }
    static func normalizedTarget(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 253,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,58,91,93,95,37].contains($0) }) else { return nil }
        return value
    }
    private func acceptLAN(_ event: LANDiscoveryEvent) {
        let service: LANDiscoveredService
        switch event { case .serviceFound(let value), .serviceResolved(let value): service = value; case .note: return }
        if let index = lanServices.firstIndex(where: { $0.key == service.key }) { lanServices[index] = service }
        else if lanServices.count < 256 { lanServices.append(service) }
    }
    public func close() async { closed = true; cancel(); await service.stop(); await waitUntilStopped() }
}
public struct DiagnosticWorkbenchView: View {
    @ObservedObject private var model: DiagnosticWorkbenchModel
    @Environment(\.locale) private var locale
    private let history: AnyView?
    private let onUseEndpoint: ((ToolboxTool, String, UInt16?) -> Void)?
    private let onOpenSettings: (() -> Void)?
    private let ipInformationSettings: AnyView?
    @State private var showsIPInformationSettings = false
    public init(model: DiagnosticWorkbenchModel, history: AnyView? = nil,
                onUseEndpoint: ((ToolboxTool, String, UInt16?) -> Void)? = nil, onOpenSettings: (() -> Void)? = nil,
                ipInformationSettings: AnyView? = nil) {
        self.model = model; self.history = history; self.onUseEndpoint = onUseEndpoint; self.onOpenSettings = onOpenSettings
        self.ipInformationSettings = ipInformationSettings
    }
    private var title: String {
        switch model.tool {
        case .ping: "Ping"
        case .traceroute: workbenchText("路由跟踪","Traceroute",locale)
        case .dns: workbenchText("DNS 查询","DNS lookup",locale)
        case .port: workbenchText("端口检测","Port probe",locale)
        case .lan: workbenchText("局域网发现","LAN discovery",locale)
        default: workbenchText("Wi-Fi 信息","Wi-Fi information",locale)
        }
    }
    private func display(_ row: DiagnosticDisplayRow) -> String {
        switch row.status {
        case .timeout: return workbenchText("超时","Timeout",locale)
        case .unreachable: return workbenchText("无法到达","Unreachable",locale)
        case .open: return workbenchText("可连接","Open",locale)
        case .noConnection: return workbenchText("未连接","No connection",locale)
        case nil: return row.value
        }
    }
    public var body: some View {
        Form {
            if model.tool == .lan {
                LANDiscoveryWorkbenchSections(model: model, onUseEndpoint: onUseEndpoint, onOpenSettings: onOpenSettings)
            } else {
            Section {
                if ![ToolboxTool.lan,.wifi].contains(model.tool) { TextField(workbenchText("地址或主机名","Address or hostname",locale),text:$model.target).autocorrectionDisabled().disabled(model.running) }
                if model.tool == .port { TextField(workbenchText("端口，以逗号分隔","Comma-separated ports",locale),text:$model.ports).disabled(model.running) }
                if model.tool == .dns { Picker(workbenchText("记录类型","Record type",locale),selection:$model.recordType) { ForEach(DNSRecordType.allCases,id:\.rawValue) { Text(String(describing:$0).uppercased()).tag($0) } }.disabled(model.running) }
                HStack {
                    Button(workbenchText("开始","Start",locale)) { model.run() }.disabled(model.running || model.stopping)
                    if model.running { ProgressView().controlSize(.small); Button(workbenchText("停止","Stop",locale)) { model.cancel() } }
                    if model.stopping { ProgressView().controlSize(.small); Text(workbenchText("正在停止…", "Stopping…", locale)).foregroundStyle(.secondary) }
                }
            }
            }
            if let error = model.failure {
                Section {
                    Text(failureMessage(error)).foregroundStyle(.secondary)
                    if let detail = failureDetail(error) {
                        DisclosureGroup(workbenchText("详情","Details",locale)) { Text(detail).font(.caption).textSelection(.enabled) }
                    }
                }
            }
            if model.tool != .lan {
            Section(workbenchText("结果","Results",locale)) {
                if let request = model.request {
                    LabeledContent(workbenchText("本次检测","This check",locale),value:request.description)
                }
                if model.cancelled { Text(workbenchText("本次检测已停止。","This check was stopped.",locale)).foregroundStyle(.secondary) }
                if model.tool == .traceroute, model.request != nil, !model.running, !model.stopping, !model.failed, !model.cancelled {
                    Text(workbenchText("检测完成。", "Check complete.", locale)).foregroundStyle(.secondary)
                }
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(row.title) { Text(display(row)).textSelection(.enabled) }
                        if let information = row.ipInformation {
                            Text([information.region,
                                  information.autonomousSystemNumber.map { "AS\($0)" },
                                  information.organization].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            DisclosureGroup(workbenchText("来源", "Source", locale)) {
                                Text(information.source).font(.caption).textSelection(.enabled)
                                Text(information.datasetVersion).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if model.ipInformationRetryable {
                    Button(workbenchText("重试 IP 信息", "Retry IP information", locale)) { model.refreshIPInformation() }
                }
                if model.tool == .wifi { Text(workbenchText("未取得的信息显示为 —。","Unavailable information is shown as —.",locale)).font(.caption).foregroundStyle(.secondary) }
            }
            }
            if let history { history }
            if ipInformationSettings != nil {
                Section {
                    Button(workbenchText("IP 信息库", "IP information database", locale)) { showsIPInformationSettings = true }
                }
            }
        }.navigationTitle(title)
        .sheet(isPresented: $showsIPInformationSettings) {
            if let ipInformationSettings { ipInformationSettings }
        }
    }
    private func failureMessage(_ error: DiagnosticError) -> String {
        switch error {
        case .dnsNameNotFound(let name): workbenchText("DNS 中未找到这个名称：\(name)","DNS did not find this name: \(name)",locale)
        case .dnsNoRecords(let name,let type): workbenchText("未找到 \(name) 的 \(String(describing:type).uppercased()) 记录。","No \(String(describing:type).uppercased()) records were found for \(name).",locale)
        case .timedOut: workbenchText("检测超时，可以重试。","The check timed out. Try again.",locale)
        case .invalid: workbenchText("输入不完整或格式有误，请检查后重试。","Check the input and try again.",locale)
        case .denied: workbenchText("当前任务未获准执行这项检测。","This task is not allowed to run this check.",locale)
        case .busy: workbenchText("已有检测正在运行，请稍后重试。","A check is already running. Try again shortly.",locale)
        case .stopped: workbenchText("本次检测已停止。","This check was stopped.",locale)
        case .dnsService: workbenchText("DNS 查询未完成，可以重试或查看详情。","DNS lookup did not finish. Retry or view details.",locale)
        case .system: workbenchText("检测未完成，可以重试或查看详情。","The check did not finish. Retry or view details.",locale)
        }
    }
    private func failureDetail(_ error: DiagnosticError) -> String? {
        switch error {
        case .system(let message), .invalid(let message): message
        case .dnsService(let code): "DNS-SD: \(code)"
        default: nil
        }
    }
}

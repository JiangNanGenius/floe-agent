import Foundation
import SwiftUI
import FloeToolboxCore
import FloeToolboxDiagnostics

public struct DiagnosticDisplayRow: Identifiable,Sendable { public let id = UUID(); public let title: String; public let value: String; public var status: DiagnosticDisplayStatus? = nil }
public enum DiagnosticDisplayStatus: Sendable { case timeout, unreachable, open, noConnection }
/// The App supplies its existing authorized service. A protocol also lets
/// focused tests deliver genuine typed responses in a controlled order.
public protocol DiagnosticWorkbenchService: Sendable {
    func ping(target: String, count: Int, timeoutSeconds: Int) async throws -> [PingObservation]
    func traceroute(target: String, maximumHops: Int, timeoutSeconds: Int) async throws -> [TraceHop]
    func dns(name: String, type: DNSRecordType, timeout: Double) async throws -> [DNSRecord]
    func ports(target: String, ports: [UInt16], timeout: Double) async throws -> [PortObservation]
    func discover(type: String, seconds: Double) async throws -> [BonjourService]
    func stop() async
}
extension DiagnosticService: DiagnosticWorkbenchService {}

public struct DiagnosticRequestSnapshot: Sendable {
    public let id: UUID
    public let tool: ToolboxTool
    public let target: String
    public let ports: String
    public let recordType: DNSRecordType
    public let serviceType: String
    public var description: String {
        switch tool {
        case .dns: String(describing:recordType).uppercased() + " · " + target
        case .port: target + " · " + ports
        case .lan: serviceType
        case .wifi: "Wi-Fi"
        default: target
        }
    }
}
@MainActor public final class DiagnosticWorkbenchModel: ObservableObject {
    @Published public var target = ""
    @Published public var ports = "22, 80, 443"
    @Published public var serviceType = "_http._tcp"
    @Published public var recordType = DNSRecordType.a
    @Published public private(set) var running = false
    @Published public private(set) var failed = false
    @Published public private(set) var cancelled = false
    @Published public private(set) var request: DiagnosticRequestSnapshot?
    @Published public private(set) var failure: DiagnosticError?
    @Published public private(set) var rows: [DiagnosticDisplayRow] = []
    public let tool: ToolboxTool
    private let service: any DiagnosticWorkbenchService
    private let mayReadWiFiIdentity: Bool
    private var operation: Task<Void,Never>?
    private var generation = UUID()
    public init(tool: ToolboxTool,service: any DiagnosticWorkbenchService,mayReadWiFiIdentity: Bool = false) throws {
        guard [.ping,.traceroute,.dns,.port,.lan,.wifi].contains(tool) else { throw DiagnosticError.invalid("diagnostic view") }
        self.tool = tool; self.service = service; self.mayReadWiFiIdentity = mayReadWiFiIdentity
    }
    @discardableResult public func run() -> Task<Void,Never>? {
        guard !running else { return nil }
        let frozen = DiagnosticRequestSnapshot(id:UUID(),tool:tool,target:target.trimmingCharacters(in:.whitespacesAndNewlines),
            ports:ports,recordType:recordType,serviceType:serviceType)
        // Rows belong only to this request, including its validation/failure
        // path. Previous successes are never implicitly reused as current data.
        generation = frozen.id; request = frozen; rows = []; failure = nil
        cancelled = false; failed = false; running = true
        let run = frozen.id, target = frozen.target, ports = frozen.ports, type = frozen.recordType, discoveryType = frozen.serviceType
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let results: [DiagnosticDisplayRow]
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
                    results = try await service.traceroute(target:target,maximumHops:30,timeoutSeconds:1).map { DiagnosticDisplayRow(title:"\($0.ttl) · \($0.address ?? "*")",value:$0.milliseconds.map { String(format:"%.2f ms",$0) }.joined(separator:" · ")) }
                case .dns:
                    let records = try await service.dns(name:target,type:type,timeout:5)
                    guard !records.isEmpty else { throw DiagnosticError.dnsNoRecords(target,type) }
                    results = records.map { DiagnosticDisplayRow(title:$0.name,value:$0.text) }
                case .port:
                    let values = ports.split(separator:",",omittingEmptySubsequences:false)
                    let parsed = values.compactMap { UInt16($0.trimmingCharacters(in:.whitespaces)) }
                    guard values.count == parsed.count else { throw DiagnosticError.invalid("ports") }
                    results = try await service.ports(target:target,ports:parsed,timeout:2).map { DiagnosticDisplayRow(title:String($0.port),value:"",status:$0.status == .open ? .open : .noConnection) }
                case .lan: results = try await service.discover(type:discoveryType,seconds:3).map { DiagnosticDisplayRow(title:$0.name,value:$0.type+" · "+$0.domain) }
                case .wifi:
                    let identity = try await WiFiObservationService.current(mayReadIdentity:mayReadWiFiIdentity)
                    results = [DiagnosticDisplayRow(title:"SSID",value:identity.ssid ?? "—"),DiagnosticDisplayRow(title:"BSSID",value:identity.bssid ?? "—"),DiagnosticDisplayRow(title:"RSSI",value:identity.signalDBM.map { "\($0) dBm" } ?? "—")]
                default: throw DiagnosticError.invalid("diagnostic")
                }
                guard generation == run else { return }
                guard !Task.isCancelled else { rows = []; running = false; operation = nil; cancelled = true; return }
                rows = results; running = false; operation = nil
            } catch {
                guard generation == run else { return }
                rows = []; running = false; operation = nil
                if error is CancellationError || Task.isCancelled || (error as? DiagnosticError) == .stopped {
                    cancelled = true; failed = false; failure = nil
                } else {
                    failure = (error as? DiagnosticError) ?? .system(String(reflecting:error)); failed = true
                }
            }
        }
        return operation
    }
    public func cancel() {
        let wasRunning = running
        generation = UUID(); operation?.cancel(); operation = nil; running = false
        if wasRunning { rows = []; failure = nil; failed = false; cancelled = true }
    }
    public func close() async { cancel(); await service.stop() }
}
public struct DiagnosticWorkbenchView: View {
    @ObservedObject private var model: DiagnosticWorkbenchModel
    @Environment(\.locale) private var locale
    public init(model: DiagnosticWorkbenchModel) { self.model = model }
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
            Section {
                if ![ToolboxTool.lan,.wifi].contains(model.tool) { TextField(workbenchText("地址或主机名","Address or hostname",locale),text:$model.target).autocorrectionDisabled().disabled(model.running) }
                if model.tool == .port { TextField(workbenchText("端口，以逗号分隔","Comma-separated ports",locale),text:$model.ports).disabled(model.running) }
                if model.tool == .dns { Picker(workbenchText("记录类型","Record type",locale),selection:$model.recordType) { ForEach(DNSRecordType.allCases,id:\.rawValue) { Text(String(describing:$0).uppercased()).tag($0) } }.disabled(model.running) }
                if model.tool == .lan { TextField(workbenchText("服务类型","Service type",locale),text:$model.serviceType).autocorrectionDisabled().disabled(model.running) }
                HStack {
                    Button(workbenchText("开始","Start",locale)) { model.run() }.disabled(model.running)
                    if model.running { ProgressView().controlSize(.small); Button(workbenchText("停止","Stop",locale)) { model.cancel() } }
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
            Section(workbenchText("结果","Results",locale)) {
                if let request = model.request {
                    LabeledContent(workbenchText("本次检测","This check",locale),value:request.description)
                }
                if model.cancelled { Text(workbenchText("本次检测已停止。","This check was stopped.",locale)).foregroundStyle(.secondary) }
                ForEach(model.rows) { row in LabeledContent(row.title) { Text(display(row)).textSelection(.enabled) } }
                if model.tool == .wifi { Text(workbenchText("未取得的信息显示为 —。","Unavailable information is shown as —.",locale)).font(.caption).foregroundStyle(.secondary) }
            }
        }.navigationTitle(title)
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

import Foundation
import SwiftUI
import FloeToolboxCore
import FloeToolboxDiagnostics

public struct DiagnosticDisplayRow: Identifiable,Sendable { public let id = UUID(); public let title: String; public let value: String; public var status: DiagnosticDisplayStatus? = nil }
public enum DiagnosticDisplayStatus: Sendable { case timeout, unreachable, open, noConnection }
@MainActor public final class DiagnosticWorkbenchModel: ObservableObject {
    @Published public var target = ""
    @Published public var ports = "22, 80, 443"
    @Published public var serviceType = "_http._tcp"
    @Published public var recordType = DNSRecordType.a
    @Published public private(set) var running = false
    @Published public private(set) var failed = false
    @Published public private(set) var rows: [DiagnosticDisplayRow] = []
    public let tool: ToolboxTool
    private let service: DiagnosticService
    private let mayReadWiFiIdentity: Bool
    private var operation: Task<Void,Never>?
    private var generation = UUID()
    public init(tool: ToolboxTool,service: DiagnosticService,mayReadWiFiIdentity: Bool = false) throws {
        guard [.ping,.traceroute,.dns,.port,.lan,.wifi].contains(tool) else { throw DiagnosticError.invalid("diagnostic view") }
        self.tool = tool; self.service = service; self.mayReadWiFiIdentity = mayReadWiFiIdentity
    }
    public func run() {
        guard !running else { return }; running = true; failed = false; let run = UUID(); generation = run
        let target = target.trimmingCharacters(in:.whitespacesAndNewlines), ports = ports, type = recordType, discoveryType = serviceType
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let results: [DiagnosticDisplayRow]
                switch tool {
                case .ping:
                    results = try await service.ping(target:target).map { value in
                        switch value.status {
                        case .reply(let ms): return DiagnosticDisplayRow(title:"\(value.sequence+1) · \(value.address)",value:String(format:"%.2f ms",ms))
                        case .timeout: return DiagnosticDisplayRow(title:"\(value.sequence+1) · \(value.address)",value:"",status:.timeout)
                        case .unreachable: return DiagnosticDisplayRow(title:"\(value.sequence+1) · \(value.address)",value:"",status:.unreachable)
                        }
                    }
                case .traceroute:
                    results = try await service.traceroute(target:target).map { DiagnosticDisplayRow(title:"\($0.ttl) · \($0.address ?? "*")",value:$0.milliseconds.map { String(format:"%.2f ms",$0) }.joined(separator:" · ")) }
                case .dns: results = try await service.dns(name:target,type:type).map { DiagnosticDisplayRow(title:$0.name,value:$0.text) }
                case .port:
                    let values = ports.split(separator:",",omittingEmptySubsequences:false)
                    let parsed = values.compactMap { UInt16($0.trimmingCharacters(in:.whitespaces)) }
                    guard values.count == parsed.count else { throw DiagnosticError.invalid("ports") }
                    results = try await service.ports(target:target,ports:parsed).map { DiagnosticDisplayRow(title:String($0.port),value:"",status:$0.status == .open ? .open : .noConnection) }
                case .lan: results = try await service.discover(type:discoveryType).map { DiagnosticDisplayRow(title:$0.name,value:$0.type+" · "+$0.domain) }
                case .wifi:
                    let identity = try await WiFiObservationService.current(mayReadIdentity:mayReadWiFiIdentity)
                    results = [DiagnosticDisplayRow(title:"SSID",value:identity.ssid ?? "—"),DiagnosticDisplayRow(title:"BSSID",value:identity.bssid ?? "—"),DiagnosticDisplayRow(title:"RSSI",value:identity.signalDBM.map { "\($0) dBm" } ?? "—")]
                default: throw DiagnosticError.invalid("diagnostic")
                }
                guard generation == run, !Task.isCancelled else { return }; rows = results; running = false; operation = nil
            } catch { guard generation == run else { return }; failed = !(error is CancellationError); running = false; operation = nil }
        }
    }
    public func cancel() { generation = UUID(); operation?.cancel(); operation = nil; running = false }
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
            if model.failed { Section { Text(workbenchText("未完成检测，请检查地址、网络或权限后重试。","The check did not finish. Check the address, network or permissions, then retry.",locale)).foregroundStyle(.secondary) } }
            Section(workbenchText("结果","Results",locale)) {
                ForEach(model.rows) { row in LabeledContent(row.title) { Text(display(row)).textSelection(.enabled) } }
                if model.tool == .wifi { Text(workbenchText("未取得的信息显示为 —。","Unavailable information is shown as —.",locale)).font(.caption).foregroundStyle(.secondary) }
            }
        }.navigationTitle(title)
    }
}

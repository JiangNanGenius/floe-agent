import Foundation
import SwiftUI
import FloeToolboxCore

extension ToolboxSpacePage {
    func title(in locale: Locale) -> String {
        func text(_ zh: String,_ en: String) -> String { locale.language.languageCode?.identifier == "zh" ? zh : en }
        return switch self { case .overview: text("概览","Overview"); case .notes: text("手记","Notes"); case .files: text("文件","Files"); case .toolbox: text("工具箱","Toolbox") } }
}
extension ToolboxGroup {
    func title(in locale: Locale) -> String {
        func text(_ zh: String,_ en: String) -> String { locale.language.languageCode?.identifier == "zh" ? zh : en }
        return switch self { case .connections: text("终端与远程","Terminal and remote"); case .diagnostics: text("网络诊断","Network diagnostics"); case .communication: text("通信工具","Communication tools"); case .utilities: text("实用工具","Utilities") } }
}
extension ToolboxTool {
    public func title(in locale: Locale) -> String {
        func text(_ zh: String,_ en: String) -> String { locale.language.languageCode?.identifier == "zh" ? zh : en }
        return switch self {
        case .terminal: text("终端","Terminal"); case .vnc: text("VNC 远程桌面","VNC desktop"); case .browser: text("浏览器","Browser")
        case .ping: "Ping"; case .traceroute: text("路由跟踪","Traceroute"); case .dns: text("DNS 查询","DNS lookup")
        case .port: text("端口检测","Port probe"); case .lan: text("局域网发现","LAN discovery"); case .wifi: text("Wi-Fi 信息","Wi-Fi information")
        case .roaming: text("漫游追踪","Roaming trace")
        case .serialAssistant: text("串口助手","Serial assistant")
        case .http: "HTTP / API"; case .webSocket: "WebSocket"; case .mqtt: "MQTT"
        case .hash: text("文件校验","File checksum"); case .json: text("JSON 格式化","JSON formatter"); case .encoding: text("文本编码","Text encoding")
        case .qr: text("二维码","QR code")
        }
    }
    public var symbol: String {
        switch self {
        case .terminal: "terminal"; case .vnc: "desktopcomputer"; case .browser: "globe"; case .ping: "waveform.path.ecg"
        case .traceroute: "point.3.connected.trianglepath.dotted"; case .dns: "list.bullet.rectangle"; case .port: "network"
        case .lan: "dot.radiowaves.left.and.right"; case .wifi: "wifi"; case .roaming: "wifi.circle"
        case .serialAssistant: "cable.connector"; case .http: "curlybraces"; case .webSocket: "arrow.left.arrow.right"; case .mqtt: "point.3.filled.connected.trianglepath.dotted"
        case .hash: "checkmark.document"; case .json: "curlybraces.square"; case .encoding: "textformat.abc"
        case .qr: "qrcode"
        }
    }
}

public struct SerialAssistantSetupView: View {
    @Environment(\.locale) private var toolboxLocale
    private func text(_ zh: String,_ en: String) -> String { toolboxLocale.language.languageCode?.identifier == "zh" ? zh : en }
    @Binding private var configuration: SerialAssistantConfiguration
    private let connected: Bool
    public init(configuration: Binding<SerialAssistantConfiguration>, connected: Bool) {
        _configuration = configuration; self.connected = connected
    }
    public var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Picker(text("连接方式","Connection"),selection:$configuration.connection) {
                Text("TCP").tag(SerialAssistantConnection.tcp)
                Text("UDP").tag(SerialAssistantConnection.udp)
                Text(text("蓝牙","Bluetooth")).tag(SerialAssistantConnection.bluetooth)
                Text("USB").tag(SerialAssistantConnection.usb)
            }.pickerStyle(.segmented)
            Picker(text("协议类型","Protocol"),selection:$configuration.protocolType) {
                Text(text("通用收发","Raw data")).tag(SerialAssistantProtocol.raw)
                Text("Modbus").tag(SerialAssistantProtocol.modbus)
            }
            if configuration.protocolType == .modbus {
                Picker(text("数据封装","Framing"),selection:$configuration.modbusFraming) {
                    Text(text("按设备说明选择","Choose for your device")).tag(Optional<ModbusFraming>.none)
                    Text("MBAP").tag(Optional(ModbusFraming.mbap))
                    Text("RTU / CRC").tag(Optional(ModbusFraming.rtu))
                }
            }
            if connected { Text(text("断开连接后可更改设置。","Disconnect to change these settings.")).font(.caption).foregroundStyle(.secondary) }
        }.disabled(connected)
    }
}

/// Mount inside the existing Space feature; does not replace the App's outer split view.
public struct ToolboxSpaceNavigation: View {
    @Environment(\.locale) private var toolboxLocale
    private func text(_ zh: String,_ en: String) -> String { toolboxLocale.language.languageCode?.identifier == "zh" ? zh : en }
    @Binding private var selection: ToolboxSpacePage
    public init(selection: Binding<ToolboxSpacePage>) { _selection = selection }
    public var body: some View {
        Picker(text("空间页面","Space page"),selection:$selection) {
            ForEach(ToolboxSpacePage.allCases,id:\.self) { page in Text(page.title(in:toolboxLocale)).tag(page) }
        }.pickerStyle(.segmented)
    }
}

public struct ToolboxHomeView: View {
    @Environment(\.locale) private var toolboxLocale
    private func text(_ zh: String,_ en: String) -> String { toolboxLocale.language.languageCode?.identifier == "zh" ? zh : en }
    private let availability: [ToolboxTool: ToolboxAvailability]
    private let onOpen: (ToolboxTool) -> Void
    public init(availability: [ToolboxTool: ToolboxAvailability], onOpen: @escaping (ToolboxTool) -> Void) {
        self.availability = availability; self.onOpen = onOpen
    }
    public var body: some View {
        List {
            ForEach(ToolboxGroup.allCases,id:\.self) { group in
                Section(group.title(in:toolboxLocale)) {
                    ForEach(ToolboxTool.allCases.filter { $0.group == group && availability[$0] != nil }) { tool in
                        Button { onOpen(tool) } label: {
                            HStack(spacing:12) {
                                Image(systemName:tool.symbol).foregroundStyle(.tint).frame(width:26)
                                VStack(alignment:.leading,spacing:3) {
                                    Text(tool.title(in:toolboxLocale)).foregroundStyle(.primary)
                                    if case let .needsConfiguration(reason) = availability[tool] { Text(reason).font(.caption).foregroundStyle(.secondary) }
                                    if case let .unsupported(reason) = availability[tool] { Text(reason).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if tool.hasAssistant { Image(systemName:"sparkles").foregroundStyle(.secondary).accessibilityLabel(text("支持 AI 助手","AI assistant available")) }
                                Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.frame(minHeight:44)
                        }.disabled(isUnsupported(tool))
                    }
                }
            }
        }.navigationTitle(text("工具箱","Toolbox"))
    }
    private func isUnsupported(_ tool: ToolboxTool) -> Bool { if case .unsupported = availability[tool] { true } else { false } }
}

@MainActor
public final class SerialPanelModel: ObservableObject {
    private var locale = Locale.current
    public func updateLocale(_ locale: Locale) { self.locale = locale }
    private func text(_ zh: String,_ en: String) -> String { locale.language.languageCode?.identifier == "zh" ? zh : en }
    @Published public var input = ""
    @Published public var question = ""
    @Published public var hexadecimal = false
    @Published public private(set) var records: [CaptureRecord] = []
    @Published public private(set) var droppedRecords: UInt64 = 0
    @Published public private(set) var analysis: SerialAnalysisResult?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var busy = false
    public let session: SerialSession
    private let journal: CaptureJournal
    private let provider: (any SerialAnalysisProvider)?
    public init(session: SerialSession, journal: CaptureJournal, provider: (any SerialAnalysisProvider)?) {
        self.session = session; self.journal = journal; self.provider = provider
    }
    public func refresh() async { let state = await journal.snapshot(); records = state.records; droppedRecords = state.droppedRecords }
    public func send() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let bytes = hexadecimal ? try Data(hex:input) : Data(input.utf8)
            try await session.send(bytes,expected:session.lease); errorMessage = nil; await refresh()
        } catch { present(error) }
    }
    public func analyze() async {
        guard !busy else { return }
        guard let provider else { errorMessage = text("请先在设置中配置 AI 模型。","Configure an AI model in Settings first."); return }
        busy = true; defer { busy = false }
        do { analysis = try await session.analyze(question:question,expected:session.lease,provider:provider); errorMessage = nil }
        catch { present(error) }
    }
    public func saveSnapshot() async -> URL? {
        do { let url = try await journal.saveSnapshot(); errorMessage = nil; return url }
        catch { present(error); return nil }
    }
    public func export() async -> Data? {
        do { return try await journal.exportJSONLines() } catch { present(error); return nil }
    }
    private func present(_ error: Error) {
        switch error {
        case ToolboxError.denied: errorMessage = text("此操作未获授权。","This operation was not authorized.")
        case ToolboxError.staleSession: errorMessage = text("连接已失效，请重新连接。","The connection is no longer active. Reconnect to continue.")
        case ToolboxError.revisionConflict: errorMessage = text("记录已在其他位置更新，请重新载入。","The capture changed elsewhere. Reload it before continuing.")
        default: errorMessage = text("操作未完成，请检查连接或输入后重试。","The operation did not finish. Check the connection and input, then retry.")
        }
    }
}

/// Host owns the model/session. Reconstructing or dismissing this surface does not close its connection.
public struct SerialClientPanel: View {
    @Environment(\.locale) private var toolboxLocale
    private func text(_ zh: String,_ en: String) -> String { toolboxLocale.language.languageCode?.identifier == "zh" ? zh : en }
    @ObservedObject private var model: SerialPanelModel
    @State private var assistantVisible = true
    private let onSaved: (URL) -> Void
    private let onExport: (Data) -> Void
    public init(model: SerialPanelModel, onSaved: @escaping (URL) -> Void, onExport: @escaping (Data) -> Void) {
        self.model = model; self.onSaved = onSaved; self.onExport = onExport
    }
    public var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(model.session.endpoint.title).font(.headline)
                Spacer()
                Button(text("AI 助手","AI assistant"),systemImage:"sparkles") { assistantVisible.toggle() }
            }
            if model.droppedRecords > 0 { Text(text("部分较早记录已按滚动上限移除。","Older records were removed by the rolling limit.")).font(.caption).foregroundStyle(.secondary) }
            List(model.records) { record in
                VStack(alignment:.leading,spacing:4) {
                    HStack {
                        Text(record.direction.rawValue.uppercased()).font(.caption.monospaced())
                        Text(record.timestamp?.formatted(date:.omitted,time:.standard) ?? text("无时间戳","No timestamp")).font(.caption).foregroundStyle(.secondary)
                        Spacer(); Text("\(record.bytes.count) B").font(.caption.monospacedDigit())
                    }
                    Text(record.redacted ? text("已省略敏感数据","Sensitive payload omitted") : Data(record.bytes.prefix(256)).hex).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                    if record.bytes.count > 256 { Text(text("显示前 256 字节","Showing the first 256 bytes")).font(.caption2).foregroundStyle(.secondary) }
                }.padding(.vertical,4)
            }
            Toggle(text("HEX 模式","HEX mode"),isOn:$model.hexadecimal)
            TextField(text("发送内容","Payload"),text:$model.input,axis:.vertical).textFieldStyle(.roundedBorder)
            HStack {
                Button(text("发送","Send")) { Task { await model.send() } }.disabled(model.busy)
                Button(text("保存快照","Save snapshot")) { Task { if let file = await model.saveSnapshot() { onSaved(file) } } }
                Button(text("导出记录","Export capture")) { Task { if let bytes = await model.export() { onExport(bytes) } } }
            }
            if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
        }.padding().task { await model.refresh() }
        .inspector(isPresented:$assistantVisible) {
            VStack(alignment:.leading,spacing:14) {
                Label(text("AI 助手","AI assistant"),systemImage:"sparkles").font(.headline)
                Text(model.session.endpoint.title).font(.caption).foregroundStyle(.secondary)
                if let analysis = model.analysis {
                    ForEach(Array(analysis.facts.enumerated()),id:\.offset) { _, fact in Text(fact).textSelection(.enabled) }
                    if !analysis.inferences.isEmpty {
                        Text(text("可能原因","Possible causes")).font(.subheadline)
                        ForEach(Array(analysis.inferences.enumerated()),id:\.offset) { _, inference in Text(inference).foregroundStyle(.secondary) }
                    }
                }
                Spacer()
                TextField(text("分析当前数据","Analyze current data"),text:$model.question,axis:.vertical).textFieldStyle(.roundedBorder)
                Button(text("分析","Analyze")) { Task { await model.analyze() } }.disabled(model.busy)
                Text(text("授权范围内诊断与收发，写入沿用现有审批。","Diagnostics and exchange stay within your authorization; writes use existing approval.")).font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
    }
}

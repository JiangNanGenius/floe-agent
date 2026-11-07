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
    private let allowsUSB: Bool
    public init(configuration: Binding<SerialAssistantConfiguration>, connected: Bool, allowsUSB: Bool = false) {
        _configuration = configuration; self.connected = connected; self.allowsUSB = allowsUSB
    }
    public var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Picker(text("连接方式","Connection"),selection:$configuration.connection) {
                Text("TCP").tag(SerialAssistantConnection.tcp)
                Text("UDP").tag(SerialAssistantConnection.udp)
                Text(text("蓝牙","Bluetooth")).tag(SerialAssistantConnection.bluetooth)
                if allowsUSB { Text("USB").tag(SerialAssistantConnection.usb) }
            }.pickerStyle(.segmented)
                .accessibilityIdentifier("toolbox.serial.transport")
            Picker(text("协议类型","Protocol"),selection:$configuration.protocolType) {
                Text(text("通用收发","Raw data")).tag(SerialAssistantProtocol.raw)
                Text("Modbus").tag(SerialAssistantProtocol.modbus)
            }
            .accessibilityIdentifier("toolbox.serial.protocol")
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private func text(_ zh: String,_ en: String) -> String { toolboxLocale.language.languageCode?.identifier == "zh" ? zh : en }
    private let availability: [ToolboxTool: ToolboxAvailability]
    private let onOpen: (ToolboxTool) -> Void
    public init(availability: [ToolboxTool: ToolboxAvailability], onOpen: @escaping (ToolboxTool) -> Void) {
        self.availability = availability; self.onOpen = onOpen
    }
    public var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 700 && !dynamicTypeSize.isAccessibilitySize
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    featuredShelf(wide: wide, width: geometry.size.width)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(text("全部工具", "All tools")).font(.title2.bold())
                        ForEach(ToolboxGroup.allCases, id: \.self) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.title(in: toolboxLocale))
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24), count: wide ? 2 : 1),
                                          alignment: .leading, spacing: 0) {
                                    ForEach(ToolboxTool.allCases.filter { $0.group == group && availability[$0] != nil }) { tool in
                                        directoryRow(tool)
                                    }
                                }
                            }
                        }
                    }.accessibilityIdentifier("toolbox.directory")
                }
                .padding(16)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }.navigationTitle(text("工具箱", "Toolbox"))
    }

    private var featured: [ToolboxTool] {
        [.roaming, .http, .serialAssistant, .lan].filter { availability[$0] != nil && !isUnsupported($0) }
    }

    private func featuredShelf(wide: Bool, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("快捷工具", "Quick tools")).font(.title2.bold())
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(featured) { tool in
                        Button { onOpen(tool) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: tool.symbol)
                                    .font(.title).foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                                Text(tool.title(in: toolboxLocale))
                                    .font(.title3.weight(.semibold)).foregroundStyle(.primary)
                                Text(summary(tool)).font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Label(text("打开", "Open"), systemImage: "arrow.right")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                            }
                            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                            .padding(16)
                            .background(.background, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .frame(width: wide ? 300 : max(220, width - 68))
                        .accessibilityIdentifier("toolbox.featured.\(tool.rawValue)")
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        }.accessibilityIdentifier("toolbox.featured")
    }

    private func directoryRow(_ tool: ToolboxTool) -> some View {
        VStack(spacing: 0) {
            Button { onOpen(tool) } label: {
                HStack(spacing: 12) {
                    Image(systemName: tool.symbol).foregroundStyle(.tint).frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tool.title(in: toolboxLocale)).font(.body).foregroundStyle(.primary)
                        Text(statusOrSummary(tool)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if tool.hasAssistant {
                        Image(systemName: "sparkles").foregroundStyle(.secondary)
                            .accessibilityLabel(text("支持 AI 助手", "AI assistant available"))
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isUnsupported(tool))
            .accessibilityIdentifier("toolbox.tool.\(tool.rawValue)")
            Divider()
        }
    }

    private func statusOrSummary(_ tool: ToolboxTool) -> String {
        switch availability[tool] {
        case .needsConfiguration(let reason), .unsupported(let reason): reason
        default: summary(tool)
        }
    }

    private func summary(_ tool: ToolboxTool) -> String {
        switch tool {
        case .terminal: text("运行命令，查看输出", "Run commands and inspect output")
        case .vnc: text("连接并操作远程桌面", "Connect to a remote desktop")
        case .browser: text("浏览网页与本地服务", "Browse websites and local services")
        case .ping: text("检查连接延迟与丢包", "Check latency and packet loss")
        case .traceroute: text("查看到目标的网络路径", "Inspect the route to a target")
        case .dns: text("查询域名解析记录", "Look up domain records")
        case .port: text("检查主机的开放端口", "Check a host's open ports")
        case .lan: text("发现当前网络的设备", "Discover devices on your network")
        case .wifi: text("查看当前无线网络", "Inspect the current wireless network")
        case .roaming: text("记录移动时的连接变化", "Record connection changes as you move")
        case .serialAssistant: text("连接设备并收发数据", "Connect to devices and exchange data")
        case .http: text("发送请求并检查响应", "Send requests and inspect responses")
        case .webSocket: text("持续收发双向消息", "Exchange messages over a live connection")
        case .mqtt: text("订阅主题与发布消息", "Subscribe to topics and publish messages")
        case .hash: text("验证文件摘要与完整性", "Verify file checksums and integrity")
        case .json: text("格式化与检查 JSON", "Format and validate JSON")
        case .encoding: text("转换文本编码", "Convert text encodings")
        case .qr: text("识别与生成二维码", "Read and generate QR codes")
        }
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
    @Published public var displayHexadecimal = true
    @Published public var lineEnding = SerialLineEnding.none
    @Published public var clearAfterSending = false
    @Published public private(set) var active = true
    @Published private var hiddenThroughSequence: UInt64?
    @Published public private(set) var records: [CaptureRecord] = []
    @Published public private(set) var droppedRecords: UInt64 = 0
    @Published public private(set) var analysis: SerialAnalysisResult?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var busy = false
    public let session: SerialSession
    private let journal: CaptureJournal
    private let provider: (any SerialAnalysisProvider)?
    private var generation = UUID()
    public init(session: SerialSession, journal: CaptureJournal, provider: (any SerialAnalysisProvider)?) {
        self.session = session; self.journal = journal; self.provider = provider
    }
    public var visibleRecords: [CaptureRecord] {
        guard let hiddenThroughSequence else { return records }
        return records.filter { $0.sequence > hiddenThroughSequence }
    }
    public func clearDisplay() { hiddenThroughSequence = records.map(\.sequence).max() }
    public func invalidate() { active = false; generation = UUID(); busy = false }
    public func refresh() async {
        let expected = generation, state = await journal.snapshot()
        guard active, generation == expected else { return }
        records = state.records; droppedRecords = state.droppedRecords
    }
    public func send() async {
        guard active, !busy else { return }
        let expected = generation, frozenInput = input
        busy = true; defer { if expected == generation { busy = false } }
        do {
            let bytes = try SerialPayloadEncoding.encode(frozenInput, hexadecimal: hexadecimal, lineEnding: lineEnding)
            try await session.send(bytes,expected:session.lease)
            guard active, expected == generation, !Task.isCancelled else { return }
            if clearAfterSending, input == frozenInput { input = "" }
            errorMessage = nil; await refresh()
        } catch { if active, expected == generation { present(error) } }
    }
    public func analyze() async {
        guard active, !busy else { return }
        guard let provider else { errorMessage = text("请先在设置中配置 AI 模型。","Configure an AI model in Settings first."); return }
        let expected = generation
        busy = true; defer { if expected == generation { busy = false } }
        do {
            let result = try await session.analyze(question:question,expected:session.lease,provider:provider)
            guard active, expected == generation, !Task.isCancelled else { return }
            analysis = result; errorMessage = nil
        } catch { if active, expected == generation { present(error) } }
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
        case ToolboxError.invalid: errorMessage = text("发送内容格式有误，请检查 HEX 字节。","Invalid payload. Check the HEX bytes.")
        case ToolboxError.limit: errorMessage = text("发送内容过长或连接忙，请缩短后重试。","The payload is too large or the connection is busy. Shorten it and retry.")
        case ToolboxError.denied: errorMessage = text("此操作未获授权。","This operation was not authorized.")
        case ToolboxError.staleSession: errorMessage = text("连接已失效，请重新连接。","The connection is no longer active. Reconnect to continue.")
        case ToolboxError.revisionConflict: errorMessage = text("记录已在其他位置更新，请重新载入。","The capture changed elsewhere. Reload it before continuing.")
        default: errorMessage = text("操作未完成，请检查连接或输入后重试。","The operation did not finish. Check the connection and input, then retry.")
        }
    }
}

public enum SerialLineEnding: String, CaseIterable, Sendable {
    case none, lf, crlf, cr
    public var bytes: Data {
        switch self { case .none: Data(); case .lf: Data([10]); case .crlf: Data([13, 10]); case .cr: Data([13]) }
    }
}
public enum SerialPayloadEncoding {
    /// Text uses UTF-8. HEX uses exact bytes and ignores text-only line endings.
    public static func encode(_ input: String, hexadecimal: Bool, lineEnding: SerialLineEnding) throws -> Data {
        guard input.utf8.count <= 1024 * 1024 else { throw ToolboxError.limit("serial input") }
        var bytes = hexadecimal ? try Data(hex: input) : Data(input.utf8)
        if !hexadecimal { bytes.append(lineEnding.bytes) }
        guard !bytes.isEmpty, bytes.count <= 256 * 1024 else { throw ToolboxError.limit("serial payload") }
        return bytes
    }
}

/// Host owns the model/session. Reconstructing or dismissing this surface does not close its connection.
public struct SerialClientPanel: View {
    @Environment(\.locale) private var toolboxLocale
    private func text(_ zh: String,_ en: String) -> String { toolboxLocale.language.languageCode?.identifier == "zh" ? zh : en }
    @ObservedObject private var model: SerialPanelModel
    @State private var assistantVisible = false
    private let onSaved: (URL) -> Void
    private let onExport: (Data) -> Void
    public init(model: SerialPanelModel, onSaved: @escaping (URL) -> Void, onExport: @escaping (Data) -> Void) {
        self.model = model; self.onSaved = onSaved; self.onExport = onExport
    }
    public var body: some View {
        VStack(alignment:.leading,spacing:12) {
            ViewThatFits(in: .horizontal) {
                HStack { Text(text("收发记录","Receive and send log")).font(.headline); Spacer(); logControls }
                VStack(alignment: .leading, spacing: 8) { Text(text("收发记录","Receive and send log")).font(.headline); HStack { logControls } }
            }
            if model.droppedRecords > 0 { Text(text("部分较早记录已按滚动上限移除。","Older records were removed by the rolling limit.")).font(.caption).foregroundStyle(.secondary) }
            List(model.visibleRecords) { record in
                VStack(alignment:.leading,spacing:4) {
                    HStack {
                        Text(record.direction == .sent ? "TX →" : record.direction == .received ? "RX ←" : text("事件","Event")).font(.caption.monospaced())
                            .foregroundStyle(record.direction == .sent ? Color.blue : Color.secondary)
                        Text(record.timestamp?.formatted(date:.omitted,time:.standard) ?? text("无时间戳","No timestamp")).font(.caption).foregroundStyle(.secondary)
                        Spacer(); Text("\(record.bytes.count) B").font(.caption.monospacedDigit())
                    }
                    Text(record.redacted ? text("已省略敏感数据","Sensitive payload omitted") : display(record.bytes)).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                    if record.bytes.count > 256 { Text(text("显示前 256 字节","Showing the first 256 bytes")).font(.caption2).foregroundStyle(.secondary) }
                }.padding(.vertical,4)
            }.accessibilityIdentifier("toolbox.serial.log")
            ViewThatFits(in: .horizontal) {
                HStack { sendFormat; lineEnding; Spacer(); clearAfterSending }
                VStack(alignment: .leading) { HStack { sendFormat; lineEnding }; clearAfterSending }
            }
            TextField(model.hexadecimal ? "01 03 00 00" : text("发送内容","Payload"),text:$model.input,axis:.vertical)
                .lineLimit(1...5).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("toolbox.serial.payload")
            HStack {
                Button(text("发送","Send"),systemImage:"paperplane") { Task { await model.send() } }
                    .disabled(model.busy || !model.active || (model.input.isEmpty && (model.hexadecimal || model.lineEnding == .none)))
                    .accessibilityIdentifier("toolbox.serial.send")
                Button(text("保存快照","Save snapshot")) { Task { if let file = await model.saveSnapshot() { onSaved(file) } } }
                Button(text("导出记录","Export capture")) { Task { if let bytes = await model.export() { onExport(bytes) } } }
            }
            if let error = model.errorMessage { Text(error).font(.callout).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
        }.padding().task { await model.refresh() }
        .onChange(of: toolboxLocale, initial: true) { _, value in model.updateLocale(value) }
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
    private func display(_ bytes: Data) -> String {
        let prefix = Data(bytes.prefix(256))
        return model.displayHexadecimal ? prefix.hex : String(decoding: prefix, as: UTF8.self)
    }
    @ViewBuilder private var logControls: some View {
        Picker(text("显示格式","Display format"),selection:$model.displayHexadecimal) {
            Text("HEX").tag(true); Text(text("文本","Text")).tag(false)
        }.pickerStyle(.segmented).frame(width: 150).accessibilityIdentifier("toolbox.serial.displayFormat")
        Button(text("清屏","Clear display"),systemImage:"eraser") { model.clearDisplay() }
            .disabled(model.visibleRecords.isEmpty).accessibilityIdentifier("toolbox.serial.clearDisplay")
        Button(text("AI 助手","AI assistant"),systemImage:"sparkles") { assistantVisible.toggle() }
    }
    private var sendFormat: some View {
        Picker(text("发送格式","Send format"),selection:$model.hexadecimal) {
            Text(text("文本","Text")).tag(false); Text("HEX").tag(true)
        }.pickerStyle(.segmented).frame(width: 150).accessibilityIdentifier("toolbox.serial.sendFormat")
    }
    @ViewBuilder private var lineEnding: some View {
        if !model.hexadecimal {
            Picker(text("换行","Line ending"),selection:$model.lineEnding) {
                Text(text("不换行","None")).tag(SerialLineEnding.none)
                Text("LF").tag(SerialLineEnding.lf); Text("CRLF").tag(SerialLineEnding.crlf); Text("CR").tag(SerialLineEnding.cr)
            }.accessibilityIdentifier("toolbox.serial.lineEnding")
        }
    }
    private var clearAfterSending: some View {
        Toggle(text("发送后清空","Clear after sending"),isOn:$model.clearAfterSending).fixedSize()
    }
}

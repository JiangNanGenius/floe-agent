import SwiftUI
import FloeToolboxCore
import FloeToolboxClients

func workbenchText(_ zh: String,_ en: String,_ locale: Locale) -> String { locale.language.languageCode?.identifier == "zh" ? zh : en }
public struct CaptureWorkbenchPanel: View {
    @ObservedObject private var model: CaptureWorkbenchModel
    @Environment(\.locale) private var locale
    private let onSave: (URL) -> Void
    private let onExport: (Data) -> Void
    public init(model: CaptureWorkbenchModel,onSave: @escaping (URL)->Void,onExport: @escaping (Data)->Void) { self.model = model; self.onSave = onSave; self.onExport = onExport }
    public var body: some View {
        VStack(alignment:.leading,spacing:12) {
            if model.dropped > 0 { Text(workbenchText("较早记录已移至历史或按上限移除。","Earlier records are in history or were removed by the rolling limit.",locale)).font(.caption).foregroundStyle(.secondary) }
            List(model.records) { record in
                VStack(alignment:.leading,spacing:5) {
                    HStack {
                        Image(systemName:record.direction == .sent ? "arrow.up.right" : record.direction == .received ? "arrow.down.left" : "info.circle")
                        Text(record.timestamp?.formatted(date:.omitted,time:.standard) ?? "—").foregroundStyle(.secondary)
                        Spacer(); Text("\(record.originalByteCount) B").monospacedDigit()
                    }.font(.caption)
                    Text(record.redacted ? workbenchText("敏感数据已省略","Sensitive data omitted",locale) : Data(record.bytes.prefix(256)).hex).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                    if let note = record.notes.first { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }.padding(.vertical,4)
            }.frame(minHeight:180)
            ViewThatFits(in:.horizontal) {
                HStack { captureActions }
                VStack(alignment:.leading) { captureActions }
            }
            if model.saveFailed { Text(workbenchText("保存或导出失败，请重试。","Saving or exporting failed. Try again.",locale)).foregroundStyle(.secondary) }
        }.task { await model.refresh() }
    }
    @ViewBuilder private var captureActions: some View {
        Button(workbenchText("保存快照","Save snapshot",locale),systemImage:"square.and.arrow.down") { Task { if let file = await model.save() { onSave(file) } } }
        Button(workbenchText("导出记录","Export capture",locale),systemImage:"square.and.arrow.up") { Task { if let bytes = await model.export() { onExport(bytes) } } }
    }
}
struct AssistantContent: View {
    @ObservedObject var model: CaptureWorkbenchModel
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Label(workbenchText("AI 助手","AI assistant",locale),systemImage:"sparkles").font(.headline)
            ScrollView {
                VStack(alignment:.leading,spacing:10) {
                    if let analysis = model.analysis {
                        ForEach(Array(analysis.facts.enumerated()),id:\.offset) { _,value in Text(value).textSelection(.enabled) }
                        if !analysis.inferences.isEmpty { Text(workbenchText("可能原因","Possible causes",locale)).font(.headline) }
                        ForEach(Array(analysis.inferences.enumerated()),id:\.offset) { _,value in Text(value).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            if model.analysisTimedOut {
                Text(workbenchText("分析超时，可以重试。","Analysis timed out. Try again.",locale)).font(.callout).foregroundStyle(.secondary)
            } else if model.analysisCancelled {
                Text(workbenchText("已停止分析。","Analysis stopped.",locale)).font(.callout).foregroundStyle(.secondary)
            } else if model.failed {
                Text(workbenchText("分析未完成，请检查模型设置或重试。","Analysis did not finish. Check model settings or retry.",locale)).font(.callout).foregroundStyle(.secondary)
            }
            TextField(workbenchText("分析当前记录","Analyze this capture",locale),text:$model.question,axis:.vertical).textFieldStyle(.roundedBorder)
            if model.analyzing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(workbenchText("正在分析当前记录…","Analyzing this capture…",locale)).font(.callout)
                    Spacer()
                    Button(workbenchText("停止","Stop",locale)) { model.cancelAnalysis() }
                        .accessibilityIdentifier("toolbox.analysis.cancel")
                }.accessibilityIdentifier("toolbox.analysis.progress")
            } else {
                Button(workbenchText("分析","Analyze",locale)) {
                    Task { await model.analyze(defaultQuestion:workbenchText("请分析当前通信记录，区分事实与可能原因。","Analyze this communication capture, separating facts from possible causes.",locale)) }
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("toolbox.analysis.start")
            }
        }.padding()
    }
}
public struct HTTPWorkbenchView: View {
    @ObservedObject private var model: HTTPWorkbenchModel
    @State private var assistant = false
    @Environment(\.locale) private var locale
    private let onSave: (URL)->Void; private let onExport: (Data)->Void
    public init(model: HTTPWorkbenchModel,onSave: @escaping (URL)->Void,onExport: @escaping (Data)->Void) { self.model = model; self.onSave = onSave; self.onExport = onExport }
    public var body: some View {
        Form {
            Section {
                Picker(workbenchText("方法","Method",locale),selection:$model.method) { ForEach(["GET","POST","PUT","PATCH","DELETE","HEAD","OPTIONS"],id:\.self) { Text($0).tag($0) } }
                TextField("URL",text:$model.url).textContentType(.URL).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                Button { Task { await model.send() } } label: { Label(workbenchText("发送请求","Send request",locale),systemImage:"arrow.up.right") }.disabled(model.busy)
            }.disabled(model.busy)
            Section(workbenchText("请求头","Headers",locale)) { TextEditor(text:$model.headers).font(.system(.body,design:.monospaced)).frame(minHeight:80) }
            Section(workbenchText("请求体","Body",locale)) { TextEditor(text:$model.body).font(.system(.body,design:.monospaced)).frame(minHeight:120) }
            if let reply = model.reply {
                Section(workbenchText("响应","Response",locale)) {
                    LabeledContent(workbenchText("状态","Status",locale),value:String(reply.status))
                    if reply.truncated { Text(workbenchText("响应超过上限，已保留部分内容。","Response limit reached. A partial response was kept.",locale)).foregroundStyle(.secondary) }
                    if reply.bytes.count > 32768 { Text(workbenchText("此处仅预览前 32 KiB。","Previewing the first 32 KiB.",locale)).font(.caption).foregroundStyle(.secondary) }
                    Text(String(decoding:reply.bytes.prefix(32768),as:UTF8.self)).font(.system(.body,design:.monospaced)).textSelection(.enabled)
                }
            }
            if model.failed { Section { Text(workbenchText("请求未完成，请检查地址、输入或连接。","Request did not finish. Check the address, input or connection.",locale)).foregroundStyle(.secondary) } }
            Section(workbenchText("收发记录","Capture",locale)) { CaptureWorkbenchPanel(model:model.capture,onSave:onSave,onExport:onExport) }
        }.navigationTitle("HTTP / API")
        .toolbar { Button(workbenchText("AI 助手","AI assistant",locale),systemImage:"sparkles") { assistant.toggle() } }
        .inspector(isPresented:$assistant) { AssistantContent(model:model.capture) }
    }
}
public struct WebSocketWorkbenchView: View {
    @ObservedObject private var model: WebSocketWorkbenchModel
    @State private var assistant = false
    @Environment(\.locale) private var locale
    private let onSave: (URL)->Void; private let onExport: (Data)->Void
    public init(model: WebSocketWorkbenchModel,onSave: @escaping (URL)->Void,onExport: @escaping (Data)->Void) { self.model = model; self.onSave = onSave; self.onExport = onExport }
    public var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Toggle(workbenchText("二进制 / HEX","Binary / HEX",locale),isOn:$model.binary)
            TextEditor(text:$model.input).font(.system(.body,design:.monospaced)).frame(minHeight:100,maxHeight:180)
            HStack {
                Button(workbenchText("发送","Send",locale)) { Task { await model.send() } }.buttonStyle(.borderedProminent).disabled(model.sending)
                Button(workbenchText("接收","Receive",locale)) { Task { await model.receive() } }.disabled(model.receiving)
                if model.receiving { ProgressView().controlSize(.small) }
            }
            if model.failed { Text(workbenchText("操作未完成，请检查输入或重新连接。","Operation did not finish. Check the input or reconnect.",locale)).foregroundStyle(.secondary) }
            CaptureWorkbenchPanel(model:model.capture,onSave:onSave,onExport:onExport)
        }.padding().navigationTitle("WebSocket")
        .toolbar { Button(workbenchText("AI 助手","AI assistant",locale),systemImage:"sparkles") { assistant.toggle() } }
        .inspector(isPresented:$assistant) { AssistantContent(model:model.capture) }
    }
}
public struct MQTTWorkbenchView: View {
    @ObservedObject private var model: MQTTWorkbenchModel
    @State private var assistant = false
    @Environment(\.locale) private var locale
    private let onSave: (URL)->Void; private let onExport: (Data)->Void
    public init(model: MQTTWorkbenchModel,onSave: @escaping (URL)->Void,onExport: @escaping (Data)->Void) { self.model = model; self.onSave = onSave; self.onExport = onExport }
    public var body: some View {
        Form {
            Section(workbenchText("订阅","Subscribe",locale)) {
                TextField(workbenchText("主题过滤器","Topic filter",locale),text:$model.filter).autocorrectionDisabled()
                HStack {
                    Button(workbenchText("订阅","Subscribe",locale)) { Task { await model.subscribe() } }
                    Button(workbenchText("取消订阅","Unsubscribe",locale)) { Task { await model.unsubscribe() } }
                }.disabled(model.busy)
            }
            Section(workbenchText("发布","Publish",locale)) {
                TextField(workbenchText("主题","Topic",locale),text:$model.topic).autocorrectionDisabled()
                Picker("QoS",selection:$model.qos) { Text("0").tag(MQTTQoS.atMostOnce); Text("1").tag(MQTTQoS.atLeastOnce); Text("2").tag(MQTTQoS.exactlyOnce) }
                Toggle("Retain",isOn:$model.retained)
                Toggle(workbenchText("二进制 / HEX","Binary / HEX",locale),isOn:$model.binary)
                TextEditor(text:$model.payload).font(.system(.body,design:.monospaced)).frame(minHeight:100)
                Button(workbenchText("发布","Publish",locale)) { Task { await model.publish() } }.disabled(model.busy)
            }
            if model.failed { Section { Text(workbenchText("操作未完成，请检查连接、主题和消息。","Operation did not finish. Check the connection, topic and message.",locale)).foregroundStyle(.secondary) } }
            Section(workbenchText("消息","Messages",locale)) {
                Button(workbenchText("更新消息","Refresh messages",locale)) { Task { await model.refresh() } }
                ForEach(Array(model.messages.enumerated()),id:\.offset) { _,message in
                    VStack(alignment:.leading,spacing:4) { Text(message.topic).font(.headline); Text(String(decoding:message.payload.prefix(2048),as:UTF8.self)).font(.system(.caption,design:.monospaced)).textSelection(.enabled) }
                }
            }
            Section(workbenchText("收发记录","Capture",locale)) { CaptureWorkbenchPanel(model:model.capture,onSave:onSave,onExport:onExport) }
        }.navigationTitle("MQTT")
        .toolbar { Button(workbenchText("AI 助手","AI assistant",locale),systemImage:"sparkles") { assistant.toggle() } }
        .inspector(isPresented:$assistant) { AssistantContent(model:model.capture) }
    }
}

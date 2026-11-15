import Foundation
import SwiftUI
import FloeToolboxCore
import FloeToolboxClients

public enum ModbusWorkbenchIssue: Equatable, Sendable {
    case invalidInput
    case busy
    case timedOut
    case closed
    case protocolViolation
    case tooLarge
    case unsupported
    case exception(UInt8)
    case other(String)
}
public struct ModbusReadBackResult: Equatable, Sendable {
    public let expected: [UInt16]
    public let actual: [UInt16]
    public let matches: Bool
    public let report: ProtocolReport?
}
public struct ModbusManualFrame: Equatable, Sendable {
    public let source: ModbusFraming
    public let isResponse: Bool
    public let isWrite: Bool
    public let report: ProtocolReport
    public let frames: [ModbusFraming: Data]
    public let sourceBytes: Data
}

/// A single explicit Modbus operation, request preview, optional write
/// read-back and a user-entered frame conversion path. It never scans units
/// or addresses and never writes without the visible button action.
@MainActor public final class ModbusWorkbenchModel: ObservableObject {
    @Published public var draft = ModbusOperationDraft() { didSet { schedulePreview() } }
    @Published public private(set) var requestPreview: Data?
    @Published public private(set) var previewFrames: [ModbusFraming: Data] = [:]
    @Published public private(set) var previewIssue: ModbusWorkbenchIssue?
    @Published public private(set) var busy = false
    @Published public private(set) var result: ModbusExchangeResult?
    @Published public private(set) var issue: ModbusWorkbenchIssue?
    @Published public private(set) var readBack: ModbusReadBackResult?
    @Published public private(set) var readBackIssue: ModbusWorkbenchIssue?
    @Published public private(set) var lastAddress: UInt16 = 0
    @Published public private(set) var lastQuantity: UInt16 = 0
    @Published public var manualInput = "" { didSet { invalidateManual() } }
    @Published public var manualFraming: ModbusFraming = .rtu { didSet { invalidateManual() } }
    /// nil infers the direction. Some packed coil responses are also valid read requests.
    @Published public var manualAsResponse: Bool? { didSet { invalidateManual() } }
    @Published public private(set) var manual: ModbusManualFrame?
    @Published public private(set) var manualIssue: ModbusWorkbenchIssue?
    @Published public private(set) var manualSending = false
    @Published public private(set) var manualResult: ModbusExchangeResult?
    public let capture: CaptureWorkbenchModel
    public let framing: ModbusFraming
    public let transport: SerialTransport
    public let endpointSummary: String
    private let client: ModbusClient
    private var previewTask: Task<Void,Never>?

    public init(client: ModbusClient,journal: CaptureJournal,provider: (any SerialAnalysisProvider)? = nil) {
        self.client = client
        framing = client.framing
        let endpoint = client.session.endpoint
        transport = endpoint.transport
        if let host = endpoint.host {
            endpointSummary = endpoint.port.map { "\(host):\($0)" } ?? host
        } else { endpointSummary = endpoint.title }
        if let provider {
            let session = client.session
            capture = CaptureWorkbenchModel(journal:journal,analyze:{ question in
                try await session.analyze(question:question,expected:session.lease,provider:provider)
            })
        } else { capture = CaptureWorkbenchModel(journal:journal) }
    }

    public var addressDescription: String? {
        guard let resolved = try? draft.resolve() else { return nil }
        return "PDU \(resolved.address) · \(ModbusAddressText.reference(table:resolved.table,zeroBased:resolved.address))"
    }
    public var writeCount: Int? {
        guard draft.kind.isWrite, let resolved = try? draft.resolve() else { return nil }
        return resolved.expectedValues.count
    }
    public var writeSummary: String? {
        guard let resolved = try? draft.resolve(), resolved.kind.isWrite else { return nil }
        let values = resolved.expectedValues.map(String.init).joined(separator:", ")
        return "FC\(resolved.kind.rawValue) · unit \(resolved.unit) · address \(resolved.address) · \(values)"
    }
    public var isBroadcast: Bool {
        guard framing.isSerialLine, let resolved = try? draft.resolve(), resolved.kind.isWrite else { return false }
        return resolved.unit == 0
    }

    public func refreshPreview() async {
        previewTask?.cancel(); previewTask = nil
        await loadPreview(draft)
    }
    private func schedulePreview() {
        previewTask?.cancel()
        requestPreview = nil; previewFrames = [:]; previewIssue = nil
        let draft = self.draft
        previewTask = Task { [weak self] in await self?.loadPreview(draft) }
    }
    private func loadPreview(_ draft: ModbusOperationDraft) async {
        do {
            let resolved = try draft.resolve()
            let frames = await client.previewFrames(unit:resolved.unit,address:resolved.address,operation:resolved.operation)
            guard !Task.isCancelled, self.draft == draft else { return }
            previewFrames = frames
            requestPreview = frames[framing]
            previewIssue = requestPreview == nil ? .invalidInput : nil
        } catch {
            guard !Task.isCancelled, self.draft == draft else { return }
            previewFrames = [:]
            requestPreview = nil
            previewIssue = Self.issue(error)
        }
    }
    public func execute(_ reviewed: ModbusOperationDraft? = nil) async {
        guard !busy else { issue = .busy; return }
        let draft = reviewed ?? self.draft
        guard self.draft == draft else { issue = .invalidInput; return }
        let resolved: ModbusResolvedOperation
        do { resolved = try draft.resolve() } catch { issue = Self.issue(error); return }
        busy = true; issue = nil; result = nil; readBack = nil; readBackIssue = nil
        lastAddress = resolved.address; lastQuantity = resolved.quantity
        defer { busy = false }
        do {
            let exchange = try await client.exchange(unit:resolved.unit,address:resolved.address,operation:resolved.operation)
            result = exchange
            guard let report = exchange.report else {
                if exchange.broadcast { await capture.refresh(); return }
                throw ClientError.protocolViolation
            }
            if let code = report.fields["exceptionCode"].flatMap(UInt8.init) {
                issue = .exception(code); await capture.refresh(); return
            }
            if draft.readBack, let operation = resolved.readBack, !exchange.broadcast,
               !resolved.expectedValues.isEmpty {
                do {
                    let verify = try await client.exchange(unit:resolved.unit,address:resolved.address,operation:operation)
                    if let code = verify.report?.fields["exceptionCode"].flatMap(UInt8.init) { readBackIssue = .exception(code) }
                    if let comparison = Self.compare(expected:resolved.expectedValues,report:verify.report,
                                                     quantity:resolved.quantity,kind:resolved.kind) {
                        readBack = comparison
                    } else if readBackIssue == nil { readBackIssue = .protocolViolation }
                } catch { readBackIssue = Self.issue(error) }
            }
            await capture.refresh()
        } catch {
            issue = Self.issue(error)
            await capture.refresh()
        }
    }
    private func invalidateManual() {
        manual = nil; manualIssue = nil; manualResult = nil
    }
    public func convertManual() {
        let source = manualFraming
        do {
            let bytes = try Self.manualBytes(manualInput,framing:source)
            let frame = try ModbusCodec.decodeFrame(bytes,framing:source)
            let report = try manualAsResponse.map { try ModbusCodec.decode(bytes, framing:source, response:$0) }
                ?? ModbusCodec.decodeAuto(bytes,framing:source)
            var frames: [ModbusFraming: Data] = [:]
            for target in ModbusFraming.allCases {
                frames[target] = try? ModbusCodec.convert(bytes,from:source,to:target)
            }
            let cannotSend = manualAsResponse == true || report.fields["direction"] == "response" ||
                report.fields["direction"] == "requestOrResponse" || ModbusOperationKind(rawValue:frame.function) == nil
            manual = ModbusManualFrame(source:source,isResponse:cannotSend,
                isWrite:![1,2,3,4].contains(frame.function),report:report,frames:frames,sourceBytes:bytes)
            manualIssue = nil
        } catch {
            manual = nil
            manualIssue = Self.issue(error)
        }
    }
    public func fillManualFromCurrent() {
        guard let data = previewFrames[framing] else { return }
        manualFraming = framing
        manualAsResponse = false
        manualInput = framing == .ascii ? String(decoding:data,as:UTF8.self) : data.hex
        convertManual()
    }
    public func sendManual(_ reviewed: ModbusManualFrame? = nil) async {
        guard let manual, reviewed == nil || reviewed == manual, !manual.isResponse, let frame = manual.frames[framing] else {
            manualIssue = .invalidInput; return
        }
        guard !manualSending else { return }
        manualSending = true; manualIssue = nil; manualResult = nil
        defer { manualSending = false }
        do {
            let exchange = try await client.exchangeFrame(frame)
            if self.manual == manual {
                manualResult = exchange
                if let code = exchange.report?.fields["exceptionCode"].flatMap(UInt8.init) { manualIssue = .exception(code) }
            }
            await capture.refresh()
        } catch {
            if self.manual == manual { manualIssue = Self.issue(error) }
            await capture.refresh()
        }
    }
    public func frameText(_ data: Data, framing: ModbusFraming) -> String {
        framing == .ascii ? Self.asciiText(data) : data.hex
    }
    public func close() async {
        previewTask?.cancel(); previewTask = nil
        capture.cancelAnalysis(); await client.session.close()
    }
    deinit { previewTask?.cancel() }

    private static func compare(expected: [UInt16],report: ProtocolReport?,quantity: UInt16,
                                kind: ModbusOperationKind) -> ModbusReadBackResult? {
        guard let report else { return nil }
        let actual: [UInt16]
        if kind.table.isBit {
            guard let hex = report.fields["packedCoilsHex"], let data = try? Data(hex:hex),
                  let bits = try? ModbusCodec.unpackCoils(data,count:Int(quantity)) else { return nil }
            actual = bits.map { $0 ? 1 : 0 }
        } else {
            guard let text = report.fields["registerValues"] else { return nil }
            actual = text.split(separator:",").compactMap { UInt16($0) }
        }
        return ModbusReadBackResult(expected:expected,actual:actual,matches:actual == expected,report:report)
    }
    private static func manualBytes(_ text: String,framing: ModbusFraming) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClientError.invalidConfiguration }
        if trimmed.hasPrefix(":") {
            return Data((trimmed + "\r\n").utf8)
        }
        return try Data(hex:trimmed)
    }
    private static func asciiText(_ data: Data) -> String {
        String(decoding:data,as:UTF8.self)
            .replacingOccurrences(of:"\r",with:"\\r")
            .replacingOccurrences(of:"\n",with:"\\n")
    }
    static func issue(_ error: Error) -> ModbusWorkbenchIssue {
        if let value = error as? ClientError {
            switch value {
            case .invalidConfiguration: return .invalidInput
            case .busy: return .busy
            case .timedOut: return .timedOut
            case .closed: return .closed
            case .tooLarge: return .tooLarge
            case .protocolViolation: return .protocolViolation
            case .unsupported: return .unsupported
            case .networkFailure: return .closed
            case .authenticationFailed: return .other("TLS authentication failed")
            }
        }
        if let value = error as? ToolboxError {
            switch value {
            case .invalid: return .invalidInput
            case .truncated,.limit: return .protocolViolation
            case .unsupported: return .unsupported
            case .denied: return .other("Denied by the current connection authorization")
            case .staleSession: return .closed
            case .revisionConflict,.corruptStore: return .other("Capture storage error")
            }
        }
        if error is CancellationError { return .other("Cancelled") }
        return .other(String(describing:error))
    }
}

public struct ModbusWorkbenchView: View {
    @ObservedObject private var model: ModbusWorkbenchModel
    @State private var pendingWrite: PendingWrite?
    @Environment(\.locale) private var locale
    private let onSave: (URL)->Void
    private let onExport: (Data)->Void
    private enum PendingWrite {
        case operation(ModbusOperationDraft)
        case manual(ModbusManualFrame)
    }
    public init(model: ModbusWorkbenchModel,onSave: @escaping (URL)->Void,onExport: @escaping (Data)->Void) {
        self.model = model; self.onSave = onSave; self.onExport = onExport
    }
    public var body: some View {
        Form {
            connectionSection
            operationSection
            previewSection
            resultSection
            if let issue = model.issue { Section { issueView(issue) } }
            manualSection
            Section(workbenchText("收发记录","Capture",locale)) {
                CaptureWorkbenchPanel(model:model.capture,onSave:onSave,onExport:onExport)
            }
        }
        .navigationTitle("Modbus")
        .task { await model.refreshPreview() }
        .confirmationDialog(workbenchText("确认写入","Confirm write",locale),isPresented:Binding(
            get:{ pendingWrite != nil },set:{ if !$0 { pendingWrite = nil } }),titleVisibility:.visible,
            presenting:pendingWrite) { action in
            Button(writeDialogConfirm,role:.destructive) {
                switch action {
                case .operation(let reviewed): Task { await model.execute(reviewed) }
                case .manual(let reviewed): Task { await model.sendManual(reviewed) }
                }
            }.accessibilityIdentifier("toolbox.modbus.confirmWrite")
            Button(workbenchText("取消","Cancel",locale),role:.cancel) {}
        } message: { Text(writeDialogMessage($0)) }
    }

    @ViewBuilder private var connectionSection: some View {
        Section {
            LabeledContent(workbenchText("连接","Connection",locale),value:model.endpointSummary)
            LabeledContent(workbenchText("数据封装","Framing",locale),value:framingName(model.framing))
            Text(framingGuidance).font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var operationSection: some View {
        Section(workbenchText("操作","Operation",locale)) {
            Picker(workbenchText("功能","Function",locale),selection:$model.draft.kind) {
                ForEach(ModbusOperationKind.allCases) { kind in Text(operationName(kind)).tag(kind) }
            }.accessibilityIdentifier("toolbox.modbus.operation")
            TextField(workbenchText("单元地址","Unit ID",locale),text:$model.draft.unitText)
                .accessibilityIdentifier("toolbox.modbus.unit")
            TextField(workbenchText("数据地址（0 起，或 40001 等参考号）","Data address (zero-based, or a 40001-style reference)",locale),
                      text:$model.draft.addressText)
                .accessibilityIdentifier("toolbox.modbus.address")
            if let hint = model.addressDescription {
                Text(hint).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("toolbox.modbus.addressHint")
            }
            if model.draft.kind.isWrite {
                switch model.draft.kind {
                case .writeSingleCoil:
                    Toggle(workbenchText("线圈值","Coil value",locale),isOn:$model.draft.coilOn)
                        .accessibilityIdentifier("toolbox.modbus.coil")
                case .writeSingleRegister:
                    TextField(workbenchText("寄存器值（十进制或 0x…）","Register value (decimal or 0x…)",locale),
                              text:$model.draft.valuesText)
                        .accessibilityIdentifier("toolbox.modbus.values")
                case .writeMultipleCoils:
                    TextField(workbenchText("线圈值（0/1，逗号分隔）","Coil values (0/1, comma-separated)",locale),
                              text:$model.draft.valuesText,axis:.vertical)
                        .accessibilityIdentifier("toolbox.modbus.values")
                case .writeMultipleRegisters:
                    TextField(workbenchText("寄存器值（逗号分隔，十进制或 0x…）","Register values (comma-separated, decimal or 0x…)",locale),
                              text:$model.draft.valuesText,axis:.vertical)
                        .accessibilityIdentifier("toolbox.modbus.values")
                default: EmptyView()
                }
                if let count = model.writeCount {
                    Text(workbenchText("写入数量：\(count)","Quantity to write: \(count)",locale))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(workbenchText("写入后读回校验","Read back after writing",locale),isOn:$model.draft.readBack)
                    .disabled(model.isBroadcast)
                    .accessibilityIdentifier("toolbox.modbus.readback")
                if model.isBroadcast {
                    Text(workbenchText("广播写入：所有串口设备都会收到，设备不回复，无法读回。",
                                       "Broadcast write: every serial device receives it, no device replies and no read-back is possible.",locale))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                TextField(workbenchText("数量","Quantity",locale),text:$model.draft.quantityText)
                    .accessibilityIdentifier("toolbox.modbus.quantity")
            }
            Button {
                let reviewed = model.draft
                if reviewed.kind.isWrite { pendingWrite = .operation(reviewed) }
                else { Task { await model.execute(reviewed) } }
            } label: {
                Label(model.draft.kind.isWrite ? workbenchText("写入","Write",locale) : workbenchText("读取","Read",locale),
                      systemImage:model.draft.kind.isWrite ? "arrow.up.doc" : "arrow.down.doc")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || model.requestPreview == nil)
            .accessibilityIdentifier("toolbox.modbus.execute")
            if model.busy { ProgressView().controlSize(.small) }
        }.disabled(model.busy)
    }
    @ViewBuilder private var previewSection: some View {
        if !model.previewFrames.isEmpty {
            Section(workbenchText("请求预览","Request preview",locale)) {
                ForEach(ModbusFraming.allCases,id:\.self) { framing in
                    if let data = model.previewFrames[framing] {
                        LabeledContent(framingName(framing)) {
                            Text(model.frameText(data,framing:framing))
                                .font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                        }
                    }
                }
            }
        } else if let issue = model.previewIssue, issue != .invalidInput {
            Section { issueView(issue) }
        }
    }
    @ViewBuilder private var resultSection: some View {
        if let result = model.result {
            Section(workbenchText("结果","Result",locale)) {
                if result.broadcast {
                    Text(workbenchText("广播已发送，不等待设备回复。","Broadcast sent. No device reply is expected.",locale))
                }
                if let report = result.report {
                    if let code = report.fields["exceptionCode"].flatMap(UInt8.init) {
                        exceptionView(code).accessibilityIdentifier("toolbox.modbus.exception")
                    }
                    if let values = report.fields["registerValues"] {
                        ForEach(Array(values.split(separator:",").enumerated()),id:\.offset) { index,value in
                            LabeledContent(String(Int(model.lastAddress)+index)) {
                                Text(value).monospacedDigit().textSelection(.enabled)
                            }
                        }
                    }
                    if let hex = report.fields["packedCoilsHex"], let data = try? Data(hex:hex),
                       let bits = try? ModbusCodec.unpackCoils(data,count:Int(model.lastQuantity)) {
                        ForEach(Array(bits.enumerated()),id:\.offset) { index,value in
                            LabeledContent(String(Int(model.lastAddress)+index)) {
                                Text(value ? "1 · ON" : "0 · OFF").monospacedDigit()
                            }
                        }
                    }
                    if result.writeEchoVerified {
                        Label(workbenchText("写入回显一致","Write echo matches the request",locale),systemImage:"checkmark.circle")
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("toolbox.modbus.echo")
                    }
                    if let response = result.response {
                        LabeledContent(workbenchText("响应帧","Response frame",locale)) {
                            Text(model.frameText(response,framing:result.framing))
                                .font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                                .accessibilityIdentifier("toolbox.modbus.responseFrame")
                        }
                    }
                    DisclosureGroup(workbenchText("协议详情","Protocol details",locale)) {
                        ForEach(report.fields.keys.sorted(),id:\.self) { key in
                            LabeledContent(key) { Text(report.fields[key] ?? "").textSelection(.enabled) }
                        }
                        ForEach(Array(report.warnings.enumerated()),id:\.offset) { _,warning in
                            Text(warning).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let readBack = model.readBack {
                    readBackView(readBack).accessibilityIdentifier("toolbox.modbus.readbackResult")
                }
                if let issue = model.readBackIssue { issueView(issue) }
            }
        }
    }
    @ViewBuilder private var manualSection: some View {
        Section(workbenchText("帧转换与手动收发","Frame conversion and manual send",locale)) {
            Picker(workbenchText("输入封装","Input framing",locale),selection:$model.manualFraming) {
                ForEach(ModbusFraming.allCases,id:\.self) { framing in Text(framingName(framing)).tag(framing) }
            }.accessibilityIdentifier("toolbox.modbus.manual.source")
            Picker(workbenchText("帧方向","Frame direction",locale),selection:$model.manualAsResponse) {
                Text(workbenchText("自动识别","Automatic",locale)).tag(nil as Bool?)
                Text(workbenchText("请求","Request",locale)).tag(Optional(false))
                Text(workbenchText("响应","Response",locale)).tag(Optional(true))
            }.accessibilityIdentifier("toolbox.modbus.manual.direction")
            TextEditor(text:$model.manualInput)
                .font(.system(.body,design:.monospaced))
                .frame(minHeight:80)
                .accessibilityIdentifier("toolbox.modbus.manual.input")
            Text(workbenchText("输入 HEX，或粘贴以：开头、以 CRLF 结尾的 ASCII 帧。",
                               "Enter HEX, or paste an ASCII frame that starts with : and ends with CRLF.",locale))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(workbenchText("解析并转换","Parse and convert",locale)) { model.convertManual() }
                    .accessibilityIdentifier("toolbox.modbus.manual.convert")
                Button(workbenchText("填入当前请求","Use current request",locale)) { model.fillManualFromCurrent() }
            }
            if let manual = model.manual {
                ForEach(ModbusFraming.allCases,id:\.self) { framing in
                    if let data = manual.frames[framing] {
                        LabeledContent(framingName(framing)) {
                            Text(model.frameText(data,framing:framing))
                                .font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                        }
                    }
                }
                Text("\(manual.report.name) · \(manual.report.summary)")
                    .font(.caption).foregroundStyle(.secondary)
                if manual.isResponse {
                    Text(manual.report.fields["direction"] == "requestOrResponse"
                         ? workbenchText("这个帧也符合响应格式。如要发起读取，请选择请求并重新解析。","This frame also fits a response. Select Request and parse again to issue a read.",locale)
                         : workbenchText("此帧仅供解析。","This frame is available for inspection.",locale))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button {
                        if manual.isWrite { pendingWrite = .manual(manual) }
                        else { Task { await model.sendManual(manual) } }
                    } label: {
                        Label(workbenchText("以当前连接封装发送","Send with this connection's framing",locale),
                              systemImage:"paperplane")
                    }
                    .disabled(model.manualSending || model.busy || manual.frames[model.framing] == nil)
                    .accessibilityIdentifier("toolbox.modbus.manual.send")
                }
                if model.manualSending { ProgressView().controlSize(.small) }
            }
            if let issue = model.manualIssue { issueView(issue) }
            if let result = model.manualResult {
                if let response = result.response {
                    LabeledContent(workbenchText("手动响应帧","Manual response frame",locale)) {
                        Text(model.frameText(response,framing:result.framing))
                            .font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                    }
                }
                if result.broadcast {
                    Text(workbenchText("广播已发送，不等待设备回复。","Broadcast sent. No device reply is expected.",locale))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var writeDialogConfirm: String { workbenchText("发送写入","Send write",locale) }
    private func writeDialogMessage(_ action: PendingWrite) -> String {
        switch action {
        case .manual(let manual):
            return "\(model.endpointSummary) · \(manual.frames[model.framing]?.hex ?? "")"
        case .operation(let draft):
            guard let operation = try? draft.resolve() else { return "" }
            let values = operation.expectedValues.map(String.init).joined(separator:", ")
            return "\(model.endpointSummary) · FC\(operation.kind.rawValue) · \(workbenchText("单元","Unit",locale)) \(operation.unit) · \(workbenchText("地址","Address",locale)) \(operation.address) · \(values)"
        }
    }
    private var framingGuidance: String {
        switch model.framing {
        case .mbap:
            if model.transport == .udp {
                return workbenchText("此连接通过 UDP 发送 MBAP 数据报，请核对设备说明。",
                                     "This connection sends MBAP datagrams over UDP. Check the device documentation.",locale)
            }
            return workbenchText("MBAP：原生 Modbus TCP；单元标识可寻址网关后的串口设备。",
                                 "MBAP: native Modbus TCP; the unit identifier can address a serial device behind a gateway.",locale)
        case .rtu:
            return model.framing.isSerialLine
                ? workbenchText("RTU：串口 CRC 帧。TCP/UDP 连接表示串口网关或透传。",
                                "RTU: serial CRC frame. A TCP/UDP connection means a serial gateway or byte passthrough.",locale)
                : ""
        case .ascii:
            return workbenchText("ASCII：串口 LRC 帧。TCP/UDP 连接表示串口网关或透传。",
                                 "ASCII: serial LRC frame. A TCP/UDP connection means a serial gateway or byte passthrough.",locale)
        }
    }
    private func operationName(_ kind: ModbusOperationKind) -> String {
        switch kind {
        case .readCoils: workbenchText("01 读取线圈 · 0x","01 Read coils · 0x",locale)
        case .readDiscreteInputs: workbenchText("02 读取离散输入 · 1x","02 Read discrete inputs · 1x",locale)
        case .readHoldingRegisters: workbenchText("03 读取保持寄存器 · 4x","03 Read holding registers · 4x",locale)
        case .readInputRegisters: workbenchText("04 读取输入寄存器 · 3x","04 Read input registers · 3x",locale)
        case .writeSingleCoil: workbenchText("05 写单个线圈 · 0x","05 Write single coil · 0x",locale)
        case .writeSingleRegister: workbenchText("06 写单个保持寄存器 · 4x","06 Write single register · 4x",locale)
        case .writeMultipleCoils: workbenchText("0F 写多个线圈 · 0x","0F Write multiple coils · 0x",locale)
        case .writeMultipleRegisters: workbenchText("10 写多个保持寄存器 · 4x","10 Write multiple registers · 4x",locale)
        }
    }
    private func framingName(_ framing: ModbusFraming) -> String {
        switch framing { case .mbap: "MBAP"; case .rtu: "RTU (CRC)"; case .ascii: "ASCII (LRC)" }
    }
    @ViewBuilder private func readBackView(_ readBack: ModbusReadBackResult) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Label(readBack.matches ? workbenchText("回读一致","Read-back matches",locale)
                                   : workbenchText("回读不一致","Read-back differs",locale),
                  systemImage:readBack.matches ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(readBack.matches ? .green : .orange)
            Text("\(workbenchText("期望","Expected",locale)): \(readBack.expected.map(String.init).joined(separator:", "))")
                .font(.caption.monospaced()).textSelection(.enabled)
            Text("\(workbenchText("实际","Actual",locale)): \(readBack.actual.map(String.init).joined(separator:", "))")
                .font(.caption.monospaced()).textSelection(.enabled)
        }
    }
    @ViewBuilder private func exceptionView(_ code: UInt8) -> some View {
        let name = ModbusCodec.exceptionName(code)
        Label("\(workbenchText("设备异常","Device exception",locale)) 0x\(String(format:"%02X",Int(code)))\(name.map { _ in " · \(exceptionText(code))" } ?? "")",
              systemImage:"exclamationmark.octagon")
            .foregroundStyle(.red)
    }
    private func exceptionText(_ code: UInt8) -> String {
        switch code {
        case 0x01: workbenchText("非法功能","Illegal function",locale)
        case 0x02: workbenchText("非法数据地址","Illegal data address",locale)
        case 0x03: workbenchText("非法数据值","Illegal data value",locale)
        case 0x04: workbenchText("从站设备故障","Server device failure",locale)
        case 0x05: workbenchText("确认","Acknowledge",locale)
        case 0x06: workbenchText("从站设备忙","Server device busy",locale)
        case 0x08: workbenchText("存储奇偶校验错误","Memory parity error",locale)
        case 0x0a: workbenchText("网关路径不可用","Gateway path unavailable",locale)
        case 0x0b: workbenchText("网关目标设备无响应","Gateway target device failed to respond",locale)
        default: workbenchText("未知异常","Unknown exception",locale)
        }
    }
    @ViewBuilder private func issueView(_ issue: ModbusWorkbenchIssue) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Label(issueText(issue),systemImage:"exclamationmark.triangle")
                .foregroundStyle(.orange)
            if case .other(let detail) = issue, !detail.isEmpty {
                Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
    private func issueText(_ issue: ModbusWorkbenchIssue) -> String {
        switch issue {
        case .invalidInput:
            workbenchText("请检查单元地址、数据地址、数量、数值或帧格式。",
                          "Check the unit ID, data address, quantity, values or frame format.",locale)
        case .busy:
            workbenchText("上一个操作仍在进行。","Another operation is still running.",locale)
        case .timedOut:
            workbenchText("等待设备响应超时。请检查链路、单元地址和串口参数。",
                          "Timed out waiting for the device. Check the link, unit ID and serial settings.",locale)
        case .closed:
            workbenchText("连接已关闭或设备断开。","The connection was closed or the device disconnected.",locale)
        case .protocolViolation:
            workbenchText("收到的帧与请求不匹配（单元、事务、写回显、长度或校验）。",
                          "The received frame did not match the request (unit, transaction, write echo, length or checksum).",locale)
        case .tooLarge:
            workbenchText("响应超过上限。","The response exceeded the limit.",locale)
        case .unsupported:
            workbenchText("当前连接或功能不支持该操作。","The current connection or function does not support this operation.",locale)
        case .exception(let code):
            "\(workbenchText("设备异常","Device exception",locale)) 0x\(String(format:"%02X",Int(code))) · \(exceptionText(code))"
        case .other(let detail):
            detail.isEmpty ? workbenchText("操作未完成。","The operation did not finish.",locale) : detail
        }
    }
}

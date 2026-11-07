import Foundation
import SwiftUI
import FloeToolboxCore
import FloeToolboxClients

@MainActor public final class ModbusWorkbenchModel: ObservableObject {
    @Published public var unit = "1"
    @Published public var address = "0"
    @Published public var quantity = "10"
    @Published public var values = "0"
    @Published public var coil = false
    @Published public var function: UInt8 = 3
    @Published public private(set) var busy = false
    @Published public private(set) var failed = false
    @Published public private(set) var result: ModbusExchangeResult?
    public private(set) var resultAddress: UInt16 = 0
    public let capture: CaptureWorkbenchModel
    private let client: ModbusClient
    public init(client: ModbusClient,journal: CaptureJournal,provider: (any SerialAnalysisProvider)? = nil) {
        self.client = client
        if let provider { let session = client.session; capture = CaptureWorkbenchModel(journal:journal,analyze:{ question in try await session.analyze(question:question,expected:session.lease,provider:provider) }) }
        else { capture = CaptureWorkbenchModel(journal:journal) }
    }
    public func execute() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            guard let unit = UInt8(unit),let address = UInt16(address) else { throw ClientError.invalidConfiguration }
            let operation: ModbusOperation
            if function <= 4 { guard let count = UInt16(quantity) else { throw ClientError.invalidConfiguration }; operation = .read(function:function,quantity:count) }
            else if function == 5 { operation = .singleCoil(coil) }
            else {
                let items = values.split(separator:",",omittingEmptySubsequences:false), parsed = items.compactMap { UInt16($0.trimmingCharacters(in:.whitespaces)) }
                guard items.count == parsed.count, !parsed.isEmpty else { throw ClientError.invalidConfiguration }
                if function == 6 { guard parsed.count == 1 else { throw ClientError.invalidConfiguration }; operation = .singleRegister(parsed[0]) }
                else if function == 15 { guard parsed.allSatisfy({$0 <= 1}) else { throw ClientError.invalidConfiguration }; operation = .coils(parsed.map {$0 == 1}) }
                else if function == 16 { operation = .registers(parsed) }
                else { throw ClientError.invalidConfiguration }
            }
            result = try await client.exchange(unit:unit,address:address,operation:operation); resultAddress = address; failed = false; await capture.refresh()
        } catch { failed = true; await capture.refresh() }
    }
    public func close() async { capture.cancelAnalysis(); await client.session.close() }
}
public struct ModbusWorkbenchView: View {
    @ObservedObject private var model: ModbusWorkbenchModel
    @State private var assistant = false
    @Environment(\.locale) private var locale
    private let onSave: (URL)->Void; private let onExport: (Data)->Void
    public init(model: ModbusWorkbenchModel,onSave: @escaping (URL)->Void,onExport: @escaping (Data)->Void) { self.model = model; self.onSave = onSave; self.onExport = onExport }
    public var body: some View {
        Form {
            Section {
                TextField(workbenchText("设备地址","Unit ID",locale),text:$model.unit)
                Picker(workbenchText("操作","Operation",locale),selection:$model.function) {
                    Text(workbenchText("01 读取线圈","01 Read coils",locale)).tag(UInt8(1))
                    Text(workbenchText("02 读取离散输入","02 Read discrete inputs",locale)).tag(UInt8(2))
                    Text(workbenchText("03 读取保持寄存器","03 Read holding registers",locale)).tag(UInt8(3))
                    Text(workbenchText("04 读取输入寄存器","04 Read input registers",locale)).tag(UInt8(4))
                    Text(workbenchText("05 写入单个线圈","05 Write single coil",locale)).tag(UInt8(5))
                    Text(workbenchText("06 写入单个寄存器","06 Write single register",locale)).tag(UInt8(6))
                    Text(workbenchText("15 写入多个线圈","15 Write multiple coils",locale)).tag(UInt8(15))
                    Text(workbenchText("16 写入多个寄存器","16 Write multiple registers",locale)).tag(UInt8(16))
                }
                TextField(workbenchText("起始地址（从 0 开始）","Start address (zero-based)",locale),text:$model.address)
                if model.function <= 4 { TextField(workbenchText("数量","Quantity",locale),text:$model.quantity) }
                else if model.function == 5 { Toggle(workbenchText("线圈值","Coil value",locale),isOn:$model.coil) }
                else { TextField(workbenchText("数值，以逗号分隔","Comma-separated values",locale),text:$model.values,axis:.vertical) }
                Button(model.function <= 4 ? workbenchText("读取","Read",locale) : workbenchText("写入","Write",locale)) { Task { await model.execute() } }
            }.disabled(model.busy)
            if model.busy { ProgressView() }
            if let result = model.result {
                Section(workbenchText("结果","Result",locale)) {
                    if result.broadcast { Text(workbenchText("广播已发送，不等待设备回复。","Broadcast sent. No device reply is expected.",locale)) }
                    if let report = result.report {
                        if let values = report.fields["registerValues"] {
                            ForEach(Array(values.split(separator:",").enumerated()),id:\.offset) { index,value in LabeledContent(String(Int(model.resultAddress)+index)) { Text(value).monospacedDigit().textSelection(.enabled) } }
                        }
                        if let code = report.fields["exceptionCode"] { LabeledContent(workbenchText("异常码","Exception code",locale),value:code) }
                        DisclosureGroup(workbenchText("协议详情","Protocol details",locale)) {
                            ForEach(report.fields.keys.sorted(),id:\.self) { key in LabeledContent(key) { Text(report.fields[key] ?? "").textSelection(.enabled) } }
                        }
                    }
                }
            }
            if model.failed { Section { Text(workbenchText("操作未完成，请检查参数或重新连接。","Operation did not finish. Check the parameters or reconnect.",locale)).foregroundStyle(.secondary) } }
            Section(workbenchText("收发记录","Capture",locale)) { CaptureWorkbenchPanel(model:model.capture,onSave:onSave,onExport:onExport) }
        }.navigationTitle("Modbus")
        .toolbar { Button(workbenchText("AI 助手","AI assistant",locale),systemImage:"sparkles") { assistant.toggle() } }
        .inspector(isPresented:$assistant) { AssistantContent(model:model.capture) }
    }
}

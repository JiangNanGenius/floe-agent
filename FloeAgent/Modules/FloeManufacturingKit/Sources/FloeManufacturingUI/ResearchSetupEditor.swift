// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeManufacturingCore

/// Explicit advanced configuration surface for uncommon typed fields and
/// owner-scoped vendor extensions. Normal setup uses native controls.
struct ResearchSetupEditor<Value:Codable>:View {
    @Environment(\.dismiss) private var dismiss
    @State private var text:String
    @State private var error = ""
    let validate:(Value)throws->Void
    let apply:(Value)->Void
    init(value:Value,validate:@escaping(Value)throws->Void,apply:@escaping(Value)->Void) {
        self.validate = validate;self.apply = apply
        do {
            let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
            let data = try encoder.encode(value)
            _text = State(initialValue:data.count <= 2_000_000 ? String(decoding:data,as:UTF8.self) : "")
            _error = State(initialValue:data.count <= 2_000_000 ? "" : L("配置较大，请通过文件导入编辑结果。","Large setup: edit the exported file and import it."))
        } catch { _text = State(initialValue:"");_error = State(initialValue:error.localizedDescription) }
    }
    var body:some View {
        NavigationStack {
            VStack(alignment:.leading) {
                Text(L("完整设置包含轴链、工位、同步、预算和低频字段。厂商扩展保存在各对象的参数记录中。","The complete setup includes axis chains, stations, synchronization, budgets and uncommon fields. Keep vendor extensions in each owner's parameter record.")).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                TextEditor(text:$text).font(.system(.caption,design:.monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never).padding(8)
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding() }
            }
            .navigationTitle(L("完整配置","Complete setup"))
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(L("取消","Cancel")) { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button(L("校验并应用","Validate and apply")) {
                    do {
                        guard text.utf8.count <= 2_000_000 else { throw ManufacturingError.invalid("configuration editor byte budget; import a file instead") }
                        let value = try JSONDecoder().decode(Value.self,from:Data(text.utf8))
                        try validate(value);apply(value);dismiss()
                    } catch { self.error = error.localizedDescription }
                }.disabled(text.isEmpty) }
            }
        }
    }
}
#endif

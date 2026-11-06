// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeManufacturingCore
import FloeManufacturingParameters

struct ParameterEditor: View {
    let study: ManufacturingStudy
    let directory: URL
    let apply: (ManufacturingStudy)->Void
    private let catalog = ManufacturingParameterCatalog.standard
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ManufacturingParameterSet
    @State private var owner: ManufacturingParameterScope
    @State private var drafts: [ManufacturingParameterScope:ManufacturingParameterSet] = [:]
    @State private var query = ""
    @State private var includeRare = true
    @State private var group = ""
    @State private var filter = "all"
    @State private var problem = ""
    @State private var notice = ""
    @State private var importing = false
    @State private var exportItem: ExportItem?
    @State private var path: [String] = []
    init(study:ManufacturingStudy,directory:URL,scope:ManufacturingParameterScope = .study,apply:@escaping(ManufacturingStudy)->Void) {
        self.study = study; self.directory = directory; self.apply = apply
        _draft = State(initialValue:study.parameterSnapshot(scope:scope))
        _owner = State(initialValue:scope)
    }
    private var matches: [ManufacturingParameterDescriptor] {
        let named = Set(catalog.search(query:query,includeRare:includeRare).map(\.id))
        return catalog.parameters.filter {
            study.includesParameter($0,scope:owner) && (includeRare || !$0.rare) && (named.contains($0.id) || (!query.isEmpty && $0.binding?.localizedCaseInsensitiveContains(query) == true)) &&
            (group.isEmpty || $0.groupID == group) &&
            (filter == "all" || (filter == "preview" ? isActive($0) : !isActive($0)))
        }
    }
    var body: some View {
        NavigationStack(path:$path) {
            List {
                Section {
                    Picker(L("参数归属","Parameter owner"),selection:$owner) {
                        Text(L("工件与机床","Workpiece and machine")).tag(ManufacturingParameterScope.study)
                        ForEach(study.cam?.tools ?? []) { tool in Text(L("刀具 · ","Tool · ")+tool.name).tag(ManufacturingParameterScope.tool(tool.id)) }
                        ForEach(study.cam?.operations ?? []) { op in Text(L("工序 · ","Operation · ")+op.name).tag(ManufacturingParameterScope.operation(op.id)) }
                    }.accessibilityIdentifier("parameters.owner")
                    Picker(L("分组","Group"),selection:$group) {
                        Text(L("全部分组","All groups")).tag("")
                        ForEach(catalog.groups) { Text(L($0.nameZH,$0.nameEN)).tag($0.id) }
                    }
                    Picker(L("用途","Use"),selection:$filter) {
                        Text(L("全部","All")).tag("all")
                        Text(L("用于预览","Preview")).tag("preview")
                        Text(L("其他配置","Configuration")).tag("stored")
                    }.pickerStyle(.segmented)
                    Toggle(L("包含低频参数","Include rare parameters"),isOn:$includeRare).accessibilityIdentifier("parameters.rare")
                    Text(L("\(matches.count) 项 · 已填写 \(draft.values.count) 项","\(matches.count) parameters · \(draft.values.count) entered")).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("parameters.count")
                } footer: {
                    Text(L("仅保存的配置不会改变当前去料预览。未填写的切削速度、转速等不自动推荐。","Stored configuration does not change the current stock preview. Unset cutting speeds and spindle speeds are not automatically recommended."))
                }
                if !notice.isEmpty { Section { Text(notice).accessibilityIdentifier("parameters.notice") } }
                if !problem.isEmpty { Section { Text(problem).foregroundStyle(.orange).textSelection(.enabled).accessibilityIdentifier("parameters.error") } }
                ForEach(catalog.groups) { section in
                    let descriptors = matches.filter { $0.groupID == section.id }
                    if !descriptors.isEmpty {
                        Section(L(section.nameZH,section.nameEN)) {
                            ForEach(descriptors,id:\.id) { descriptor in
                                NavigationLink(value:descriptor.id) { row(descriptor) }.accessibilityIdentifier(descriptor.binding.map { "parameter.binding."+$0 } ?? "parameter."+descriptor.id)
                            }
                        }
                    }
                }
                let unknown = draft.values.keys.filter { catalog.lookup($0) == nil }.sorted()
                if !unknown.isEmpty {
                    Section(L("扩展配置","Extension configuration")) {
                        Text(L("未识别的扩展字段会完整保留。","Unrecognized extension fields are preserved in full.")).font(.caption).foregroundStyle(.secondary)
                        ForEach(unknown,id:\.self) { id in
                            VStack(alignment:.leading) { Text(id).font(.caption.monospaced()); Text(parameterText(draft.value(id))).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        }
                    }
                }
                if matches.isEmpty { ContentUnavailableView.search(text:query) }
            }
            .navigationTitle(L("制造参数","Manufacturing parameters"))
            .navigationDestination(for:String.self) { id in
                if let descriptor = catalog.lookup(id) {
                    ParameterValueEditor(descriptor:descriptor,current:draft.value(id),active:isActive(descriptor)) { value in
                        if let value { draft.set(id,value) } else { draft.remove(id) }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .searchable(text:$query,placement:.navigationBarDrawer(displayMode:.always),prompt:L("名称、用途或参数编号","Name, purpose or parameter ID"))
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(L("取消","Cancel")) { dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button(L("应用","Apply")) {
                        do {
                            var pending = drafts; pending[owner] = draft
                            var edited = study
                            // Apply only edited owners, retaining all others and unknown metadata.
                            if let settings = pending.removeValue(forKey:.study) { edited = try edited.applyingParameters(settings) }
                            for scope in pending.keys.sorted(by:{ String(describing:$0)<String(describing:$1) }) {
                                edited = try edited.applyingParameters(pending[scope]!,scope:scope)
                            }
                            apply(edited); dismiss()
                        }
                        catch { problem = error.localizedDescription }
                    }.accessibilityIdentifier("parameters.apply")
                }
                ToolbarItem(placement:.bottomBar) {
                    Menu {
                        Button(L("保存并导出预设","Save and export preset"),systemImage:"square.and.arrow.up") { savePreset() }.accessibilityIdentifier("parameters.savePreset")
                        Button(L("读取已保存预设","Read saved preset"),systemImage:"arrow.clockwise") { loadPreset(presetURL) }.accessibilityIdentifier("parameters.reopenPreset")
                        Button(L("导入预设","Import preset"),systemImage:"folder") { importing = true }
                    } label: { Label(L("参数预设","Parameter presets"),systemImage:"slider.horizontal.3") }.accessibilityIdentifier("parameters.menu")
                }
            }
            .fileImporter(isPresented:$importing,allowedContentTypes:[.json]) { result in
                switch result { case .success(let url): loadPreset(url); case .failure(let error): problem = error.localizedDescription }
            }
            .sheet(item:$exportItem) { ShareFile(url:$0.url) }
        }.onChange(of:owner) { previous,next in
            drafts[previous] = draft; draft = drafts[next] ?? study.parameterSnapshot(scope:next)
            path = []; group = ""; problem = ""; notice = ""
        }.presentationDetents([.large])
    }
    private func isActive(_ descriptor:ManufacturingParameterDescriptor) -> Bool {
        study.parameterIsActive(descriptor,scope:owner)
    }
    private func row(_ descriptor:ManufacturingParameterDescriptor) -> some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {
                Text(L(descriptor.nameZH,descriptor.nameEN))
                Spacer()
                Text(parameterUnit(descriptor.unit)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(parameterText(draft.value(descriptor.id))).lineLimit(1)
                Spacer()
                if descriptor.rare { Text(L("低频","Rare")) }
                Text(parameterSupport(descriptor,active:isActive(descriptor)))
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical,3)
    }
    private var ownerName:String {
        switch owner {
        case .study: return L("工件与机床","Workpiece and machine")
        case .tool(let id): return study.cam?.tools.first { $0.id == id }?.name ?? id
        case .operation(let id): return study.cam?.operations.first { $0.id == id }?.name ?? id
        }
    }
    private var presetURL:URL {
        let name:String
        switch owner {
        case .study: name = "parameters.json"
        case .tool(let id): name = "parameters-tool-"+id+".json"
        case .operation(let id): name = "parameters-operation-"+id+".json"
        }
        return directory.appendingPathComponent(name)
    }
    private func savePreset() {
        do {
            let preset = ManufacturingParameterPreset(name:study.name+" · "+ownerName,values:draft.values)
            let data = try ManufacturingStudy.encoder.encode(preset)
            guard data.count <= 1_000_000 else { throw ManufacturingError.invalid("preset budget") }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let url = presetURL
            try data.write(to:url,options:.atomic)
            notice = L("预设已保存；应用后才会更新当前工件。","Preset saved; Apply updates the current workpiece.")
            exportItem = .init(url:url)
        } catch { problem = error.localizedDescription }
    }
    private func loadPreset(_ url:URL) {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 1_000_000 else { throw ManufacturingError.invalid("preset budget") }
            let preset = try JSONDecoder().decode(ManufacturingParameterPreset.self,from:Data(contentsOf:url))
            let merged = draft.merged(with:preset)
            let issues = merged.validate(catalog:catalog).filter { $0.code != .unknownParameter }
            guard issues.isEmpty else { throw ManufacturingError.invalid(issues.prefix(3).map(\.message).joined(separator:"; ")) }
            draft = merged; problem = ""; notice = L("预设已读取；未涉及的配置已保留。","Preset loaded; other settings retained.")
        } catch { problem = error.localizedDescription }
    }
}

private struct ParameterValueEditor: View {
    let descriptor: ManufacturingParameterDescriptor
    let active: Bool
    let original: ManufacturingParameterValue?
    let apply: (ManufacturingParameterValue?)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var presence: String
    @State private var text: String
    @State private var boolean: Bool
    @State private var error = ""
    private var inactiveReason: String {
        if descriptor.binding?.hasPrefix("turningCutting.") == true {
            return L("当前未启用车削切削速度，此值仅保存。","Turning cutting speeds are disabled; this value is stored only.")
        }
        if descriptor.binding?.hasPrefix("millingAssembly.") == true {
            return L("当前未设置动力刀具总成，此值仅保存。","No live-tool assembly is configured; this value is stored only.")
        }
        return L("当前选择的工具或工序未使用此参数，设置会保留。","The selected tool or operation does not use this parameter; its setting is retained.")
    }
    init(descriptor:ManufacturingParameterDescriptor,current:ManufacturingParameterValue?,active:Bool,apply:@escaping(ManufacturingParameterValue?)->Void) {
        self.descriptor = descriptor; self.active = active; self.original = current; self.apply = apply
        _presence = State(initialValue:current == nil ? "unset" : current!.isNull ? "null" : "value")
        _text = State(initialValue:parameterEditText(current))
        _boolean = State(initialValue:current?.boolValue ?? false)
    }
    var body: some View {
        Form {
            Section {
                Label(parameterSupport(descriptor,active:active),systemImage:active ? "checkmark.circle" : "info.circle")
                Text(L(descriptor.helpZH,descriptor.helpEN)).font(.callout)
                Text(L(descriptor.supportReasonZH,descriptor.supportReasonEN)).font(.caption).foregroundStyle(.secondary)
                if descriptor.support == .previewUsed && !active {
                    Text(inactiveReason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                if descriptor.support == .fixed {
                    LabeledContent(L("固定值","Fixed value"),value:parameterText(descriptor.defaultValue))
                } else {
                    if !active {
                        Picker(L("数值状态","Value state"),selection:$presence) {
                            Text(L("未设置","Unset")).tag("unset")
                            Text(L("填写","Value")).tag("value")
                            Text(L("空值","Null")).tag("null")
                        }.pickerStyle(.segmented).accessibilityIdentifier("parameter.presence")
                    }
                    if presence == "value" { valueInput }
                    if !parameterUnit(descriptor.unit).isEmpty { LabeledContent(L("单位","Unit"),value:parameterUnit(descriptor.unit)) }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.orange).font(.caption).accessibilityIdentifier("parameter.error") }
            }
            Section {
                DisclosureGroup(L("来源与参数说明","Sources and parameter details")) {
                    Text(descriptor.id).font(.caption.monospaced())
                    ForEach(descriptor.sourceRefs,id:\.self) { Text($0).font(.caption).textSelection(.enabled) }
                    if let minimum = descriptor.minimum { LabeledContent(L("下限","Minimum"),value:String(minimum)) }
                    if let maximum = descriptor.maximum { LabeledContent(L("上限","Maximum"),value:String(maximum)) }
                }
            }
        }
        .navigationTitle(L(descriptor.nameZH,descriptor.nameEN))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement:.confirmationAction) {
                Button(L("保存此项","Save field")) { save() }.disabled(descriptor.support == .fixed).accessibilityIdentifier("parameter.apply")
            }
        }
    }
    @ViewBuilder private var valueInput: some View {
        switch descriptor.kind {
        case .boolean:
            Toggle(L("启用","Enabled"),isOn:$boolean).accessibilityIdentifier("parameter.value")
        case .choice:
            Picker(L("选项","Option"),selection:$text) {
                Text(L("请选择","Choose")).tag("")
                ForEach(descriptor.choices ?? [],id:\.self) { Text($0).tag($0) }
            }.accessibilityIdentifier("parameter.value")
        case .array,.object:
            TextEditor(text:$text).font(.body.monospaced()).frame(minHeight:180).accessibilityIdentifier("parameter.value")
        default:
            TextField(L("填写数值","Enter value"),text:$text)
                .keyboardType(descriptor.kind == .string ? .default : .numbersAndPunctuation)
                .autocorrectionDisabled().accessibilityIdentifier("parameter.value")
        }
    }
    private func save() {
        do {
            guard descriptor.support != .fixed else { return }
            if presence == "unset" { apply(nil); dismiss(); return }
            var value: ManufacturingParameterValue
            if presence == "null" { value = .null }
            else {
                switch descriptor.kind {
                case .number:
                    guard let d = Double(text.replacingOccurrences(of:",",with:".")), d.isFinite else { throw ManufacturingError.invalid(L("请填写有限数值","Enter a finite number")) }; value = .number(d)
                case .integer:
                    guard let i = Int64(text) else { throw ManufacturingError.invalid(L("请填写整数","Enter an integer")) }; value = .integer(i)
                case .boolean: value = .boolean(boolean)
                case .string,.choice: value = .string(text)
                case .array,.object:
                    guard text.utf8.count <= 64_000 else { throw ManufacturingError.invalid("field budget") }
                    if let original, text == parameterEditText(original) { value = original }
                    else { value = try .fromRawJSON(Data(text.utf8)) }
                }
            }
            var set = ManufacturingParameterSet(); set.set(descriptor.id,value)
            let issues = set.validate(catalog:.standard).filter { $0.code != .unknownParameter }
            guard issues.isEmpty else { throw ManufacturingError.invalid(issues.map(\.message).joined(separator:"; ")) }
            apply(value); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

func parameterSupport(_ descriptor:ManufacturingParameterDescriptor,active:Bool) -> String {
    switch descriptor.support {
    case .previewUsed: return active ? L("用于预览","Used in preview") : L("仅保存","Stored only")
    case .configurationOnly: return L("仅保存","Stored only")
    case .fixed: return L("固定值","Fixed")
    case .notAvailable: return L("尚未支持 · 仅保存","Unavailable · stored only")
    }
}
func parameterUnit(_ unit:ManufacturingParameterUnit) -> String {
    switch unit {
    case .none: return ""
    case .mm: return "mm"
    case .mm3: return "mm³"
    case .mmPerMinute: return "mm/min"
    case .mmPerTooth: return "mm/"+L("齿","tooth")
    case .mmPerRevolution: return "mm/"+L("转","rev")
    case .revPerMinute: return "rpm"
    case .mPerMinute: return "m/min"
    case .degrees: return "°"
    case .seconds: return "s"
    case .percent: return "%"
    case .ratio: return L("比例","ratio")
    case .litresPerMinute: return "L/min"
    case .celsius: return "°C"
    }
}
func parameterText(_ value:ManufacturingParameterValue?) -> String {
    guard let value else { return L("未设置","Unset") }
    switch value {
    case .null: return L("空值","Null")
    case .boolean(let b): return b ? L("是","Yes") : L("否","No")
    default: return parameterEditText(value)
    }
}
private func parameterEditText(_ value:ManufacturingParameterValue?) -> String {
    guard let value else { return "" }
    switch value {
    case .number(let d): return String(d)
    case .integer(let i): return String(i)
    case .string(let s): return s
    case .boolean(let b): return b ? "true" : "false"
    case .null: return "null"
    case .array,.object:
        func raw(_ value:ManufacturingParameterValue) -> Any {
            switch value {
            case .number(let v): return v
            case .integer(let v): return v
            case .boolean(let v): return v
            case .string(let v): return v
            case .null: return NSNull()
            case .array(let v): return v.map(raw)
            case .object(let v): return v.mapValues(raw)
            }
        }
        return (try? String(decoding:JSONSerialization.data(withJSONObject:raw(value),options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)) ?? ""
    }
}
#endif

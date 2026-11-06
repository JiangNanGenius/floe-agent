// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeManufacturingCore

struct CAMEditor: View {
    let directory:URL
    let apply:(ManufacturingStudy)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft:ManufacturingStudy
    @State private var importing = false
    @State private var scale = 1.0
    @State private var problem = ""
    @State private var parameters:ParameterOwner?
    private enum Route:Hashable { case tool(String),operation(String) }
    private struct ParameterOwner:Identifiable { let id = UUID(); let scope:ManufacturingParameterScope }
    init(study:ManufacturingStudy,directory:URL,apply:@escaping(ManufacturingStudy)->Void) {
        var value = study
        if value.cam == nil { value.cam = .init(tools:[.researchExample()],operations:[]) }
        _draft = State(initialValue:value); self.directory = directory; self.apply = apply
    }
    var body:some View {
        NavigationStack {
            List {
                Section {
                    Text(L("刀具库与工序按本工件保存。工序依列表顺序共用剩余材料。","Tools and operations belong to this workpiece. Operations share the remaining stock in list order.")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("刀具库","Tool library")) {
                    ForEach(draft.cam?.tools ?? []) { tool in
                        NavigationLink(value:Route.tool(tool.id)) {
                            VStack(alignment:.leading,spacing:4) {
                                Text(tool.name)
                                Text(toolKind(tool.kind)+String(format:" · Ø%.2f mm · %.2f mm",tool.diameterMM,tool.cuttingLengthMM)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("cam.tool."+tool.id)
                    }.onDelete(perform:deleteTools)
                    Menu {
                        ForEach(["flatEndMill","ballNose","drill"],id:\.self) { kind in
                            Button(toolKind(kind)) { draft.cam?.tools.append(.researchExample(kind:kind)) }
                        }
                    } label: { Label(L("添加刀具","Add tool"),systemImage:"plus") }.disabled((draft.cam?.tools.count ?? 0) >= 8).accessibilityIdentifier("cam.addTool")
                }
                Section(L("执行顺序","Operation order")) {
                    ForEach(draft.cam?.operations ?? []) { op in
                        NavigationLink(value:Route.operation(op.id)) {
                            HStack {
                                Image(systemName:op.enabled ? "checkmark.circle.fill":"circle").foregroundStyle(op.enabled ? Color.accentColor:.secondary)
                                VStack(alignment:.leading,spacing:4) { Text(op.name); Text(strategyName(op.strategy)+" · "+(draft.cam?.tools.first { $0.id == op.toolID }?.name ?? op.toolID)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.accessibilityIdentifier("cam.operation."+op.id)
                        .swipeActions(edge:.leading) { Button(L("复制","Duplicate")) { duplicate(op) }.tint(.teal) }
                    }.onMove { from,to in draft.cam?.operations.move(fromOffsets:from,toOffset:to) }
                    .onDelete { indices in draft.cam?.operations.remove(atOffsets:indices) }
                    Menu {
                        ForEach(["face","pocket","contour","drill","surfaceRaster","swarf"],id:\.self) { strategy in
                            Button(strategyName(strategy)) { addOperation(strategy) }
                        }
                    } label: { Label(L("添加工序","Add operation"),systemImage:"plus") }.disabled((draft.cam?.operations.count ?? 0) >= 12 || (draft.cam?.tools.isEmpty ?? true)).accessibilityIdentifier("cam.addOperation")
                }
                Section(L("曲面参考模型","Surface reference model")) {
                    if let mesh = draft.cam?.partMesh {
                        LabeledContent(L("三角形","Triangles"),value:"\(mesh.triangles.count)")
                        Button(L("移除参考网格","Remove reference mesh"),role:.destructive) { draft.cam?.partMesh = nil }
                    }
                    Picker(L("文件长度单位","File length unit"),selection:$scale) { Text("mm").tag(1.0); Text("inch").tag(25.4); Text("m").tag(1000.0) }
                    Button(L("导入 STL / OBJ","Import STL / OBJ"),systemImage:"folder") { importing = true }.accessibilityIdentifier("cam.importMesh")
                    Text(L("保留模型坐标。文件不含可靠单位时按上方选择换算。OBJ 需已三角化。","Model coordinates are preserved. The selected unit controls conversion. OBJ faces must be triangulated.")).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(L("移除 CAM 工序与刀具库","Remove CAM operations and library"),role:.destructive) {
                        var edited = draft; edited.cam = nil
                        do { try edited.validate(requireOperations:false); apply(edited); dismiss() } catch { problem = error.localizedDescription }
                    }
                }
                if !problem.isEmpty { Section { Text(problem).foregroundStyle(.orange).font(.caption).textSelection(.enabled).accessibilityIdentifier("cam.error") } }
            }
            .navigationTitle(L("刀具与工序","Tools and operations"))
            .navigationDestination(for:Route.self) { route in
                switch route {
                case .tool(let id):
                    if let index = draft.cam?.tools.firstIndex(where:{ $0.id == id }) {
                        CAMToolEditor(tool:toolBinding(index)) { parameters = .init(scope:.tool(id)) }
                    }
                case .operation(let id):
                    if let index = draft.cam?.operations.firstIndex(where:{ $0.id == id }) {
                        CAMOperationEditor(operation:operationBinding(index),tools:draft.cam?.tools ?? []) { parameters = .init(scope:.operation(id)) }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button(L("取消","Cancel")) { dismiss() } }
                ToolbarItem(placement:.primaryAction) { EditButton().accessibilityIdentifier("cam.reorder") }
                ToolbarItem(placement:.confirmationAction) { Button(L("应用","Apply")) {
                    do {
                        var edited = draft
                        if edited.cam?.tools.isEmpty == true && edited.cam?.operations.isEmpty == true { edited.cam = nil }
                        try edited.validate(requireOperations:false); apply(edited); dismiss()
                    } catch { problem = error.localizedDescription }
                }.accessibilityIdentifier("cam.apply") }
            }
            .fileImporter(isPresented:$importing,allowedContentTypes:[.data]) { result in
                do { try importMesh(result.get()) } catch { problem = error.localizedDescription }
            }
            .sheet(item:$parameters) { owner in
                ParameterEditor(study:draft,directory:directory,scope:owner.scope) { draft = $0 }
            }
        }.presentationDetents([.large])
    }
    private func toolBinding(_ index:Int) -> Binding<ManufacturingCAM.Tool> {
        Binding(get:{ draft.cam!.tools[index] },set:{ draft.cam?.tools[index] = $0 })
    }
    private func operationBinding(_ index:Int) -> Binding<ManufacturingCAM.Operation> {
        Binding(get:{ draft.cam!.operations[index] },set:{ draft.cam?.operations[index] = $0 })
    }
    private func deleteTools(_ indices:IndexSet) {
        let referenced = Set(draft.cam?.operations.map(\.toolID) ?? [])
        if indices.contains(where:{ referenced.contains(draft.cam!.tools[$0].id) }) { problem = L("请先更换使用此刀具的工序。","Reassign operations before removing their tool."); return }
        draft.cam?.tools.remove(atOffsets:indices)
    }
    private func duplicate(_ op:ManufacturingCAM.Operation) {
        guard (draft.cam?.operations.count ?? 0) < 12 else { return }
        var copy = op; copy.id = UUID().uuidString.lowercased(); copy.name += L(" 副本"," copy")
        let index = (draft.cam?.operations.firstIndex { $0.id == op.id } ?? -1)+1
        draft.cam?.operations.insert(copy,at:index)
    }
    private func addOperation(_ strategy:String) {
        guard let tools = draft.cam?.tools, let first = tools.first else { return }
        let tool = tools.first { strategy == "drill" ? $0.kind == "drill" : $0.kind != "drill" } ?? first
        var op = ManufacturingCAM.Operation(name:strategyName(strategy),strategy:strategy,toolID:tool.id)
        op.frame.originMM = [0,0,draft.stock.zMaxMM]
        if strategy == "drill" { op.holesUVMM = [[0,0]] }
        draft.cam?.operations.append(op)
    }
    private func importMesh(_ url:URL) throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 32_000_000 else { throw ManufacturingError.invalid("mesh file budget") }
        let imported = try ManufacturingMeshImport.read(Data(contentsOf:url),extension:url.pathExtension,scaleToMM:scale)
        draft.cam?.partMesh = imported.mesh
        draft.source = .init(documentID:"mesh:"+url.lastPathComponent,revision:draft.source.revision+1,contentSHA256:ManufacturingStudy.digest(Data((imported.contentSHA256+";scaleToMM=\(scale)").utf8)))
        problem = ""
    }
}

func strategyName(_ kind:String) -> String {
    switch kind {
    case "face": L("面铣","Facing")
    case "pocket": L("圆形型腔","Circular pocket")
    case "contour": L("轮廓","Contour")
    case "drill": L("孔加工","Hole machining")
    case "surfaceRaster": L("曲面栅格","Surface raster")
    case "swarf": L("侧刃五轴","Five-axis swarf")
    default: kind
    }
}
func toolKind(_ kind:String) -> String {
    switch kind { case "flatEndMill": L("平底铣刀","Flat end mill"); case "ballNose": L("球头铣刀","Ball nose"); case "drill": L("钻头","Drill"); default:kind }
}
#endif

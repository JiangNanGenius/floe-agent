// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeManufacturingCore
import FloeEngineeringCore
import UniformTypeIdentifiers

public struct EngineeringWorkbenchView:View {
    @Environment(\.dismiss) private var dismiss
    @State private var model:EngineeringWorkbenchModel
    @State private var importing = false
    @State private var exported:URL?
    @State private var tab = 0
    @State private var setupSheet:SetupSheet?
    @State private var hasSavedResult = false
    @FocusState private var nameFocused:Bool
    @State private var nameInputSourceID = UUID()
    @State private var editingInputSources:Set<UUID> = []
    private enum SetupSheet:String,Identifiable { case complete;var id:String { rawValue } }
    private let initialFile:URL?
    private let embedded:Bool
    @State private var didLoadInitialFile = false
    @State private var lastInitialFile:URL?
    public init(directory:URL,initialFile:URL? = nil,embedded:Bool = false,sessions:ManufacturingResearchSessions? = nil) { self.initialFile = initialFile;self.embedded = embedded;_model = State(initialValue:sessions?.engineering() ?? EngineeringWorkbenchModel(directory:directory)) }
    public var body:some View {
        Group {
            if embedded { workbenchContent }
            else { NavigationStack { workbenchContent } }
        }
    }
    private var workbenchContent:some View {
        Group {
            VStack(spacing:0) {
                if hasSavedResult && model.artifact == nil {
                    HStack {
                        Label(L("已有保存结果","Saved results available"),systemImage:"archivebox")
                        Spacer()
                        Button(L("打开已保存结果","Open saved results")) { model.reopen();tab = 1;refreshSavedResultPresence() }
                            .buttonStyle(.bordered).accessibilityIdentifier("engineering.savedResult.open")
                    }.font(.callout).padding(.horizontal,16).padding(.vertical,8).disabled(model.busy)
                }
                GeometryReader { geometry in
                    if geometry.size.width >= 1_000 { wideContent(width:geometry.size.width) }
                    else { compactContent }
                    #if DEBUG
                    if EngineeringLayoutObservation.enabled {
                        EngineeringLayoutObservation(phase:"workspace",geometrySize:geometry.size,
                            geometryFrame:geometry.frame(in:.global),geometryInsets:geometry.safeAreaInsets,
                            nameFocused:nameFocused,editingInputCount:editingInputSources.count,
                            busy:model.busy,hasArtifact:model.artifact != nil,embedded:embedded,tab:tab)
                            .frame(width:0,height:0).accessibilityHidden(true)
                    }
                    #endif
                }.accessibilityIdentifier("engineering.workspace")
                if model.busy { ProgressView(L("正在求解","Solving")).padding() }
                if !model.notice.isEmpty { Text(model.notice).font(.callout).padding(8) }
            }
            #if DEBUG
            .background {
                if EngineeringLayoutObservation.enabled {
                    GeometryReader { geometry in
                        EngineeringLayoutObservation(phase:"root",geometrySize:geometry.size,
                            geometryFrame:geometry.frame(in:.global),geometryInsets:geometry.safeAreaInsets,
                            nameFocused:nameFocused,editingInputCount:editingInputSources.count,
                            busy:model.busy,hasArtifact:model.artifact != nil,embedded:embedded,tab:tab)
                            .frame(width:0,height:0).accessibilityHidden(true)
                    }
                }
            }
            #endif
            .navigationTitle(L("材料与工程分析","Materials and engineering analysis"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.confirmationAction) { Button(L("完成","Done")) { dismiss() }.accessibilityIdentifier("engineering.done") }
                ToolbarItemGroup(placement:.primaryAction) {
                    if model.busy { Button(L("取消","Cancel")) { model.cancel() } }
                    else { Button(L("计算","Calculate")) { model.calculate();tab = 1 }.accessibilityIdentifier("engineering.solve") }
                    Menu {
                        Button(L("加载配置或结果","Load setup or result")) { importing = true }
                        Button(L("完整配置","Complete setup")) { setupSheet = .complete }
                        Button(L("保存结果","Save result")) { model.save();refreshSavedResultPresence() }.disabled(model.artifact == nil)
                        Button(L("重新打开","Reopen")) { model.reopen();refreshSavedResultPresence() }
                        Button(L("导出配置","Export setup")) { export(input:true) }
                        Button(L("导出结果","Export result")) { export(input:false) }.disabled(model.artifact == nil)
                    } label: { Image(systemName:"ellipsis.circle").frame(width:44,height:44) }.disabled(model.busy).accessibilityIdentifier("engineering.file")
                }
            }
            .fileImporter(isPresented:$importing,allowedContentTypes:[.json,.data]) { result in
                switch result { case .success(let url):model.load(url);case .failure(let error):model.report(error) }
            }
            .sheet(item:$setupSheet) { _ in
                ResearchSetupEditor(value:model.project,validate:{ try $0.validate() }) { value in model.invalidate();model.project = value }
            }
            .task(id:initialFile) {
                if !didLoadInitialFile || lastInitialFile != initialFile {
                    didLoadInitialFile = true;lastInitialFile = initialFile
                    if let initialFile { model.load(initialFile) }
                }
                refreshSavedResultPresence()
            }
        }
        // This workbench's real fields own its keyboard region; an input in
        // a covered CAD/library page must not shorten a read-only result view.
        .ignoresSafeArea(.keyboard,edges:nameFocused || !editingInputSources.isEmpty ? [] : .bottom)
        .onPreferenceChange(EngineeringInputSourcesKey.self) { sources in
            if editingInputSources != sources { editingInputSources = sources }
        }
        // The parent service owns accepted calculations; disappearing is not Cancel.
    }
    private func refreshSavedResultPresence() {
        let values = try? model.directory.appendingPathComponent("latest.floeanalysis").resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        hasSavedResult = values?.isRegularFile == true && values?.isSymbolicLink != true && (values?.fileSize ?? 0) > 0
    }
    private var compactContent:some View {
        VStack(spacing:0) {
            Picker(L("分析页面","Analysis page"),selection:$tab) { Text(L("设置","Setup")).tag(0);Text(L("结果","Results")).tag(1) }
                .pickerStyle(.segmented).padding().accessibilityIdentifier("engineering.pages")
            if tab == 0 { settings } else { results }
        }
    }
    private func wideContent(width:CGFloat)->some View {
        HStack(spacing:0) {
            VStack(spacing:0) {
                Text(L("设置","Setup")).font(.headline).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,20).padding(.vertical,12)
                settings
            }.frame(width:min(420,width*0.38))
            Divider()
            VStack(spacing:0) {
                Text(L("结果","Results")).font(.headline).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,20).padding(.vertical,12)
                results
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
    private var settings:some View {
        Form {
            Section(L("分析","Analysis")) {
                TextField(L("名称","Name"),text:Binding(get:{ model.project.name },set:{ value in
                    guard value != model.project.name else { return }
                    model.invalidate();model.project.name = value
                }))
                    .focused($nameFocused)
                    .preference(key:EngineeringInputSourcesKey.self,value:nameFocused ? [nameInputSourceID] : [])
                    .accessibilityIdentifier("engineering.name")
                LabeledContent(L("分析类型","Analysis type")) {
                    Text(analysisTitle).accessibilityIdentifier("engineering.analysis.kind")
                }
                HStack {
                    // Keep the two example actions independent inside this Form row.
                    Button { model.select(thermal:false) } label: {
                        Text(L("静力示例","Static example")).frame(minHeight:44).contentShape(.rect)
                    }.buttonStyle(.borderless).accessibilityIdentifier("engineering.example.static")
                    Spacer()
                    Button { model.select(thermal:true) } label: {
                        Text(L("导热示例","Thermal example")).frame(minHeight:44).contentShape(.rect)
                    }.buttonStyle(.borderless).accessibilityIdentifier("engineering.example.thermal")
                }
            }
            materialFields
            switch model.project.analysis {
            case .structural(let input):
                Section(L("体网格","Volume mesh")) { meshSummary(nodes:input.meshNodes.count,elements:input.meshElements.count) }
                structuralLoads(input)
            case .thermal(let input):
                Section(L("体网格","Volume mesh")) { meshSummary(nodes:input.meshNodes.count,elements:input.meshElements.count) }
                thermalLoads(input)
            }
            numerics
            Section {
                Text(L("导入带四面体体网格的配置可分析自己的工件。表面 STL 不会自动变成体网格。","Import a setup with a tetrahedral volume mesh to analyze your own part. A surface STL is not automatically converted into a volume mesh.")).font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(model.busy).accessibilityIdentifier("engineering.settings")
    }
    private var analysisTitle:String {
        switch model.project.analysis {
        case .structural:L("线弹性静力","Linear static")
        case .thermal:L("稳态导热","Steady conduction")
        }
    }
    private var material:EngineeringMaterial {
        switch model.project.analysis { case .structural(let input):input.material;case .thermal(let input):input.material }
    }
    private func editMaterial(_ edit:(inout EngineeringMaterial)->Void) {
        switch model.project.analysis {
        case .structural:model.editStructural { edit(&$0.material) }
        case .thermal:model.editThermal { edit(&$0.material) }
        }
    }
    private var materialFields:some View {
        Section(L("材料 · 各向同性","Material · isotropic")) {
            Picker(L("示例材料","Example material"),selection:Binding(get:{ material.id },set:{ id in
                if let value = MaterialLibrary.record(id) { editMaterial { $0 = value } }
            })) { ForEach(MaterialLibrary.all,id:\.id) { Text($0.name).tag($0.id) } }
            scalar(L("弹性模量 · MPa","Elastic modulus · MPa"),value:material.elasticModulusMPa) { value in editMaterial { $0.elasticModulusMPa = value } }
            scalar(L("泊松比","Poisson ratio"),value:material.poissonRatio) { value in editMaterial { $0.poissonRatio = value } }
            if let yield = material.yieldStrengthMPa { scalar(L("屈服强度 · MPa","Yield strength · MPa"),value:yield) { value in editMaterial { $0.yieldStrengthMPa = value } } }
            if let k = material.thermalConductivityWPerMMK { scalar(L("导热系数 · W/(mm·K)","Conductivity · W/(mm·K)"),value:k) { value in editMaterial { $0.thermalConductivityWPerMMK = value } } }
            DisclosureGroup(L("材料来源","Material source")) { Text(material.provenance).font(.caption).textSelection(.enabled) }
        }
    }
    @ViewBuilder private func structuralLoads(_ input:StructuralRequest)->some View {
        Section(L("节点力 · N","Nodal forces · N")) {
            ForEach(input.concentratedLoads.indices,id:\.self) { i in
                Text(String(format:L("节点 %d","Node %d"),input.concentratedLoads[i].node)).font(.caption)
                EngineeringVectorField(value:input.concentratedLoads[i].components) { value in model.editStructural { $0.concentratedLoads[i].components = value } }
            }
            Button(L("添加节点力","Add nodal force")) { model.editStructural { $0.concentratedLoads.append(.init(node:0,components:.zero)) } }
        }
        Section(L("位移约束 · mm","Displacement constraints · mm")) {
            ForEach(input.displacementBCs.indices,id:\.self) { i in
                DisclosureGroup(String(format:L("节点 %d","Node %d"),input.displacementBCs[i].node)) {
                    ForEach(0..<3,id:\.self) { c in
                        Toggle(["X","Y","Z"][c],isOn:Binding(get:{ input.displacementBCs[i].constrained[c] },set:{ value in model.editStructural { $0.displacementBCs[i].constrained[c] = value } }))
                        scalar(L("给定位移","Prescribed displacement"),value:input.displacementBCs[i].prescribedMM[c]) { value in model.editStructural { $0.displacementBCs[i].prescribedMM[c] = value } }
                    }
                }
            }
            Text(L("集中力、体力、压力及任意节点约束均可通过完整配置导入和保存。","Concentrated forces, body forces, pressure and arbitrary nodal constraints can be imported and saved in the complete setup.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func thermalLoads(_ input:ThermalRequest)->some View {
        Section(L("温度边界 · °C","Temperature boundaries · °C")) {
            ForEach(input.fixedTemperatures.indices,id:\.self) { i in
                scalar(String(format:L("节点 %d","Node %d"),input.fixedTemperatures[i].node),value:input.fixedTemperatures[i].temperatureCelsius) { value in model.editThermal { $0.fixedTemperatures[i].temperatureCelsius = value } }
            }
        }
        Section(L("热源与热流","Heat sources and flux")) {
            ForEach(input.sources.indices,id:\.self) { i in
                scalar(String(format:L("单元 %d · W/mm³","Element %d · W/mm³"),input.sources[i].element),value:input.sources[i].powerPerVolume) { value in model.editThermal { $0.sources[i].powerPerVolume = value } }
            }
            ForEach(input.faceFluxes.indices,id:\.self) { i in
                scalar(String(format:L("面 %d · W/mm²","Face %d · W/mm²"),input.faceFluxes[i].face),value:input.faceFluxes[i].fluxWPerMM2) { value in model.editThermal { $0.faceFluxes[i].fluxWPerMM2 = value } }
            }
            Text(L("导热系数使用 W/(mm·K)；从 W/(m·K) 输入时需除以1000。","Conductivity uses W/(mm·K); divide W/(m·K) values by 1000 at input.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var numerics:some View {
        let tolerance:EngineeringTolerance,budget:EngineeringBudget
        switch model.project.analysis { case .structural(let v):tolerance = v.tolerance;budget = v.budget;case .thermal(let v):tolerance = v.tolerance;budget = v.budget }
        return DisclosureGroup(L("公差与资源预算","Tolerances and resource budgets")) {
            scalar(L("相对残差","Relative residual"),value:tolerance.relativeResidual) { value in editNumerics { $0.relativeResidual = value } budget:{ _ in } }
            scalar(L("绝对残差下限","Absolute residual floor"),value:tolerance.absoluteResidualFloor) { value in editNumerics { $0.absoluteResidualFloor = value } budget:{ _ in } }
            scalar(L("时间预算 · s","Time budget · s"),value:budget.maxWallSeconds) { value in editNumerics { _ in } budget:{ $0.maxWallSeconds = value } }
            scalar(L("内存预算 · MB","Memory budget · MB"),value:Double(budget.maxEstimatedBytes)/1e6) { value in
                if value.isFinite && value >= 0 && value <= 1000 { editNumerics { _ in } budget:{ $0.maxEstimatedBytes = Int(value*1e6) } }
            }
        }
    }
    private func editNumerics(_ tolerance:(inout EngineeringTolerance)->Void,budget:(inout EngineeringBudget)->Void) {
        switch model.project.analysis {
        case .structural:model.editStructural { tolerance(&$0.tolerance);budget(&$0.budget) }
        case .thermal:model.editThermal { tolerance(&$0.tolerance);budget(&$0.budget) }
        }
    }
    private var results:some View {
        List {
            if let artifact = model.artifact {
                switch artifact.result {
                case .structural(let result):
                    Section(L("静力结果","Static results")) {
                        quantity(L("最大位移","Maximum displacement"),result.nodalDisplacementMM.map(\.magnitude).max() ?? 0,"mm")
                        quantity(L("最大等效应力","Maximum von Mises stress"),result.maxVonMisesMPa ?? 0,"MPa")
                        if let fos = result.minFactorOfSafety { quantity(L("最小屈服比","Minimum yield ratio"),fos,"") }
                        quantity(L("相对残差","Relative residual"),result.relativeResidual,"")
                        Text(L("位移、反力、单元应变与应力均保存在完整结果中。","Displacements, reactions, element strains and stresses are retained in the complete result.")).font(.caption).foregroundStyle(.secondary)
                    }
                case .thermal(let result):
                    Section(L("导热结果","Conduction results")) {
                        quantity(L("最低温度","Minimum temperature"),result.minTemperatureCelsius,"°C")
                        quantity(L("最高温度","Maximum temperature"),result.maxTemperatureCelsius,"°C")
                        quantity(L("能量平衡残差","Energy balance residual"),result.energyBalanceResidualW,"W")
                        quantity(L("相对残差","Relative residual"),result.relativeResidual,"")
                    }
                }
                DisclosureGroup(L("适用范围与未覆盖分析","Scope and uncovered analyses")) {
                    ForEach(artifact.unsupportedDomains,id:\.self) { Text($0).font(.caption) }
                }
            } else { ContentUnavailableView(L("尚无分析结果","No analysis results yet"),systemImage:"function",description:Text(L("设置材料、载荷与边界条件后求解。","Set the material, loads and boundary conditions, then solve."))) }
            if let exported { ShareLink(item:exported) { Label(L("分享导出文件","Share exported file"),systemImage:"square.and.arrow.up") } }
            if !model.diagnostic.isEmpty { DisclosureGroup(L("问题详情","Problem details")) { Text(model.diagnostic).font(.caption).textSelection(.enabled) } }
        }.accessibilityIdentifier("engineering.results")
    }
    private func meshSummary(nodes:Int,elements:Int)->some View { LabeledContent(L("节点 / 四面体","Nodes / tetrahedra"),value:"\(nodes) / \(elements)") }
    private func scalar(_ title:String,value:Double,set:@escaping @MainActor @Sendable (Double)->Void)->some View {
        HStack { Text(title);Spacer();EngineeringNumberInput(title:title,number:value,update:set).multilineTextAlignment(.trailing).frame(maxWidth:140) }.frame(minHeight:44)
    }
    private func quantity(_ title:String,_ value:Double,_ unit:String)->some View { LabeledContent(title,value:String(format:"%.6g %@",value,unit)) }
    private func export(input:Bool) { do { exported = try model.export(input:input);tab = 1 } catch { model.report(error) } }
}

private struct EngineeringInputSourcesKey:PreferenceKey {
    static let defaultValue:Set<UUID> = []
    static func reduce(value:inout Set<UUID>,nextValue:()->Set<UUID>) { value.formUnion(nextValue()) }
}

/// Each mounted numeric input, including repeated scalar labels and vector
/// components, has its own stable focus owner. IDs are never made in body.
private struct EngineeringNumberInput:View {
    var title:String
    var number:Double
    var update:@MainActor @Sendable (Double)->Void
    var rounded = false
    @State private var inputSourceID = UUID()
    @FocusState private var isEditing:Bool
    @ViewBuilder var body:some View {
        if rounded { field.textFieldStyle(.roundedBorder) } else { field }
    }
    private var field:some View {
        TextField(title,value:Binding(get:{ number },set:{ value in
            guard value != number else { return }
            update(value)
        }),format:.number)
            .keyboardType(.numbersAndPunctuation).focused($isEditing)
            .preference(key:EngineeringInputSourcesKey.self,value:isEditing ? [inputSourceID] : [])
            .accessibilityLabel(title)
    }
}

private struct EngineeringVectorField:View {
    var value:Vector3
    var update:@MainActor @Sendable (Vector3)->Void
    var body:some View {
        HStack {
            field("X",value.x) { update(.init($0,value.y,value.z)) }
            field("Y",value.y) { update(.init(value.x,$0,value.z)) }
            field("Z",value.z) { update(.init(value.x,value.y,$0)) }
        }.frame(minHeight:44)
    }
    private func field(_ title:String,_ number:Double,_ set:@escaping @MainActor @Sendable (Double)->Void)->some View {
        EngineeringNumberInput(title:title,number:number,update:set,rounded:true)
    }
}
#endif

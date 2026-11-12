// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeBiologyCore
import FloeBiologyEngine
import FloeBiologySamples

@MainActor public struct BiologyWorkbench:View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var model:BiologyWorkbenchModel
    private let observesServiceChanges:Bool
    private struct AssetEditorContext {let asset:BiologyAsset;let recordIndex:Int}
    @State private var assetEditorContext:AssetEditorContext?
    private let onAI:BiologyAIHandler?
    private let onInsertInNotes:BiologyNotesHandler?
    private let executionOwner:(@MainActor @Sendable (UUID,UUID) async throws -> BiologyExecutionOwner)?
    private let makeTools:(@MainActor @Sendable (UUID) async throws -> BiologyToolSession)?
    private let onRunAnalysis:BiologyNativeAnalysisHandler?
    private let onImportFile:BiologyNativeFileImportHandler?
    private let onAuthorizeFile:BiologyNativeFileAuthorizationHandler?
    private let scientificEnvironmentID:String?
    /// Host-shared persistent assistant presentation (e.g. the App's studio
    /// file assistant). When supplied it replaces the isolated one-shot sheet.
    private let assistantContent:(@MainActor (BiologyAIContext) -> AnyView)?
    private let prepareAssistant:(@MainActor (BiologyAIContext) async throws -> Void)?
    private let onPresentAssistant:(@MainActor (BiologyAIContext) async throws -> Void)?
    @State private var sheet:Panel?
    @State private var renaming:BiologyAsset?
    @State private var transforming:BiologyStructureTransformRequest?
    @State private var assistantContext:BiologyAIContext?
    @State private var showingAnalysis=false
    private enum AnalysisInput:Hashable{case extra,cutoff,threshold,timeEnd,step}
    @FocusState private var analysisInput:AnalysisInput?
    @State private var importing=false
    @State private var exporting=false
    @State private var exportDocument=BiologyFileDocument(data:Data())
    @State private var exportName="Biology.json"
    @State private var nativeExport:BiologyNativeFileExport?
    @State private var recordIndex=0
    @State private var selectedAtoms:[Int]=[]
    @State private var structureModel=1
    @State private var chain=""
    @State private var channel=0
    @State private var slice=0
    @State private var frame=0
    @State private var threshold=""
    @State private var selectedMethod=""
    @State private var environment="native.local"
    @State private var translationFrame=1
    @State private var geneticCode=1
    @State private var cutoff=4.0
    @State private var timeEnd=30.0
    @State private var step=0.1
    @State private var extraOptions=""
    @State private var showResult=false
    private enum Panel:String,Identifiable {case sequence,annotation,network,blankSequence,blankNetwork,history,notes,assistant,rename,tools;var id:String{rawValue}}
    public init(service:BiologyService,projectID:UUID,onAI:BiologyAIHandler? = nil,onInsertInNotes:BiologyNotesHandler? = nil,executionOwner:(@MainActor @Sendable (UUID,UUID) async throws -> BiologyExecutionOwner)? = nil,makeTools:(@MainActor @Sendable (UUID) async throws -> BiologyToolSession)? = nil,onRunAnalysis:BiologyNativeAnalysisHandler? = nil,onImportFile:BiologyNativeFileImportHandler? = nil,onAuthorizeFile:BiologyNativeFileAuthorizationHandler? = nil,scientificEnvironmentID:String? = nil,assistantContent:(@MainActor (BiologyAIContext) -> AnyView)? = nil,prepareAssistant:(@MainActor (BiologyAIContext) async throws -> Void)? = nil,onPresentAssistant:(@MainActor (BiologyAIContext) async throws -> Void)? = nil) {
        _model=State(initialValue:BiologyWorkbenchModel(service:service,projectID:projectID));self.observesServiceChanges=true;self.onAI=onAI;self.onInsertInNotes=onInsertInNotes;self.executionOwner=executionOwner;self.makeTools=makeTools;self.onRunAnalysis=onRunAnalysis;self.onImportFile=onImportFile;self.onAuthorizeFile=onAuthorizeFile;self.scientificEnvironmentID=scientificEnvironmentID;self.assistantContent=assistantContent;self.prepareAssistant=prepareAssistant;self.onPresentAssistant=onPresentAssistant
    }
    /// A host-owned presentation reuses the same observable model its native
    /// project/session refreshes. Standalone callers retain the original init.
    public init(model:BiologyWorkbenchModel,onAI:BiologyAIHandler? = nil,onInsertInNotes:BiologyNotesHandler? = nil,executionOwner:(@MainActor @Sendable (UUID,UUID) async throws -> BiologyExecutionOwner)? = nil,makeTools:(@MainActor @Sendable (UUID) async throws -> BiologyToolSession)? = nil,onRunAnalysis:BiologyNativeAnalysisHandler? = nil,onImportFile:BiologyNativeFileImportHandler? = nil,onAuthorizeFile:BiologyNativeFileAuthorizationHandler? = nil,scientificEnvironmentID:String? = nil,assistantContent:(@MainActor (BiologyAIContext) -> AnyView)? = nil,prepareAssistant:(@MainActor (BiologyAIContext) async throws -> Void)? = nil,onPresentAssistant:(@MainActor (BiologyAIContext) async throws -> Void)? = nil) {
        _model=State(initialValue:model);self.observesServiceChanges=false;self.onAI=onAI;self.onInsertInNotes=onInsertInNotes;self.executionOwner=executionOwner;self.makeTools=makeTools;self.onRunAnalysis=onRunAnalysis;self.onImportFile=onImportFile;self.onAuthorizeFile=onAuthorizeFile;self.scientificEnvironmentID=scientificEnvironmentID;self.assistantContent=assistantContent;self.prepareAssistant=prepareAssistant;self.onPresentAssistant=onPresentAssistant
    }
    public var body:some View {
        GeometryReader { geometry in
            HStack(spacing:0) {
                if geometry.size.width>850 {materials.frame(width:244);Divider()}
                VStack(spacing:0) {
                    header(compact:geometry.size.width<=850)
                    Divider()
                    if showResult,let run=model.run {BiologyResultView(run:run,source:model.runSource)}
                    else {workspace}
                    if !model.activeRuns.isEmpty || model.run != nil {Divider();jobBar}
                }.frame(maxWidth:.infinity,maxHeight:.infinity).background(BiologyStyle.background)
            }
        }
        .navigationTitle(model.project?.title ?? biologyText("Biology","生物"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {toolbar}
        .inspector(isPresented:$showingAnalysis){properties.inspectorColumnWidth(min:280,ideal:320,max:360).presentationDetents([.large])}
        .sheet(item:$sheet,onDismiss:{assetEditorContext=nil}){panel in panelView(panel).presentationSizing(.page).presentationCornerRadius(24).presentationDragIndicator(.visible)}
        .sheet(item:$renaming){asset in BiologyAssetRenameSheet(model:model,asset:asset).presentationSizing(.page).presentationCornerRadius(24).presentationDragIndicator(.visible)}
        .sheet(item:$transforming){request in BiologyStructureTransformSheet(model:model,request:request).presentationSizing(.page).presentationCornerRadius(24).presentationDragIndicator(.visible)}
        .sheet(item:$assistantContext){context in
            if let assistantContent {
                BiologySharedAssistantPresentation(context:context,prepare:prepareAssistant,content:assistantContent)
                    .id(context.id)
            }
        }
        .sheet(item:$nativeExport){item in BiologyNativeExportPicker(export:item){nativeExport=nil;Task{await model.service.finishNativeExport(item)}}}
        .alert(biologyText("Biology","生物"),isPresented:Binding(get:{model.notice != nil},set:{if !$0{model.notice=nil}})){Button(biologyText("OK","好")){model.notice=nil}}message:{Text(model.notice ?? "")}
        .fileImporter(isPresented:$importing,allowedContentTypes:[.data],allowsMultipleSelection:true){result in Task{await importFiles(result)}}
        .fileExporter(isPresented:$exporting,document:exportDocument,contentType:.data,defaultFilename:exportName){result in if case .failure(let error)=result{model.error=error.localizedDescription}}
        .safeAreaInset(edge:.bottom) {
            if let error=model.error {
                DisclosureGroup(biologyText("Unable to finish · details","操作未完成 · 详情")) {
                    Text(error).font(.caption).textSelection(.enabled)
                    Button(biologyText("Dismiss","关闭")){model.error=nil}.buttonStyle(BiologyControlButtonStyle())
                }.padding(10).background(.regularMaterial)
            }
        }
        .task {
            guard observesServiceChanges else {configureSelection();applyStoredSelection();return}
            do {let changes=try await model.service.changes(model.projectID)
                for await _ in changes {if Task.isCancelled{return};let previous=model.project?.selections;await model.refresh();configureSelection();if previous != model.project?.selections{applyStoredSelection()}}
            }catch{model.error=error.localizedDescription}
        }
        .onChange(of:model.project?.revision){_,_ in configureSelection()}
        .onChange(of:model.selectedID){_,_ in
            recordIndex=0;selectedAtoms=[];channel=0;slice=0;frame=0;chain="";selectedMethod=""
            if !model.hasPinnedResultForSelection {model.selectedRunID=nil;showResult=false}
            Task{
                if let a=model.selected,model.project?.activeAssetID != a.id {
                    do{_=try await model.service.select(model.projectID,assetID:a.id,selection:model.project?.selections?[a.id.uuidString] ?? .object([:]),expectedAssetRevision:a.revision)}catch{model.error=error.localizedDescription}
                }
                await model.refresh();configureSelection();applyStoredSelection()
            }
        }
        .onChange(of:offeredMethods){_,_ in configureSelection()}
    }
    private func header(compact:Bool)->some View {
        HStack {
            if compact {
                Menu {
                    Section(biologyText("Research materials","研究资料")) {
                        ForEach(model.project?.assets ?? []) {a in
                            Button {model.selectedID=a.id}label:{Label(a.title,systemImage:BiologyLabels.icon(a.kind))}
                                .accessibilityIdentifier(a.kind == .externalDataset ? "biology.assetFormat."+a.originalFormat:"biology.asset."+a.kind.rawValue)
                        }
                    }
                    if let runs=model.project?.runs,!runs.isEmpty {
                        Section(biologyText("Analysis history","分析历史")) {
                            ForEach(runs.reversed()){run in historyEntry(run)}
                        }
                    }
                }label:{Image(systemName:"sidebar.left").frame(width:44,height:44)}
                    .buttonStyle(BiologyControlButtonStyle(compact:true))
                    .accessibilityLabel(biologyText("Research materials","研究资料")).accessibilityIdentifier("biology.materials")
            }
            if let a=model.selected {
                VStack(alignment:.leading,spacing:3) {
                    Text(a.title).font(.headline).lineLimit(2)
                    Label(BiologyLabels.kind(a.kind)+" · "+biologyText("Saved","已保存"),systemImage:"checkmark.circle").font(.caption).foregroundStyle(.secondary)
                }
            } else {Text(biologyText("Create from +, import or open an example","从加号新建、导入或打开示例")).foregroundStyle(.secondary)}
            Spacer()
            if model.busy {ProgressView().controlSize(.small)}
            if model.run != nil {
                Picker(biologyText("View","视图"),selection:Binding(get:{showResult},set:{value in if value {if let run=model.run{showRun(run.id)}}else{showResult=false}})) {
                    Text(biologyText("Data","数据")).tag(false);Text(biologyText("Result","结果")).tag(true)
                }.pickerStyle(.segmented).frame(width:150).accessibilityIdentifier("biology.viewMode")
            }
        }.frame(minHeight:44).padding(.horizontal,12).padding(.vertical,2).background(BiologyStyle.canvas)
    }
    private var materials:some View {
        List(selection:$model.selectedID) {
            Section(biologyText("Research materials","研究资料")) {
                ForEach(model.project?.assets ?? []){a in
                    Label{VStack(alignment:.leading,spacing:3){Text(a.title).lineLimit(2);Text(BiologyLabels.kind(a.kind)).font(.caption).foregroundStyle(.secondary)}}icon:{Image(systemName:BiologyLabels.icon(a.kind))}
                        .tag(a.id).frame(minHeight:44).accessibilityIdentifier(a.kind == .externalDataset ? "biology.assetFormat."+a.originalFormat:"biology.asset."+a.kind.rawValue)
                        .contextMenu {
                            Button(biologyText("Rename","重命名"),systemImage:"pencil"){renaming=a}.accessibilityIdentifier("biology.renameAsset")
                            Button(biologyText("Delete","删除"),systemImage:"trash",role:.destructive){Task{await deleteAsset(a)}}.accessibilityIdentifier("biology.deleteAsset")
                        }
                }
            }
            if let runs=model.project?.runs,!runs.isEmpty {
                Section(biologyText("Analysis history","分析历史")) {
                    ForEach(runs.reversed()){r in
                        historyEntry(r)
                    }
                }
            }
        }.listStyle(.sidebar)
    }
    private func showRun(_ id:UUID) {if model.selectRun(id){showResult=true}}
    private func historyEntry(_ run:BiologyRun)->some View {
        Button {showRun(run.id)} label:{
            Label(BiologyLabels.method(run.method),systemImage:run.status == .succeeded ? "checkmark.circle":run.isActive ? "hourglass":"exclamationmark.circle")
        }.frame(minHeight:44).accessibilityIdentifier("biology.run."+run.id.uuidString)
    }
    @ViewBuilder private var workspace:some View {
        if let a=model.selected {
            switch a.payload {
            case .sequence(let records):BiologySequenceView(records:records,recordIndex:$recordIndex,selectedRange:sequenceRange)
            case .proteinStructure(let s):BiologyRibbonView(asset:a,structure:s,selectedAtoms:$selectedAtoms,modelNumber:$structureModel,chain:$chain)
            case .microscopyImage(let image):BiologyMicroscopyView(image:image,result:model.run?.assetRevision==a.revision ? model.run?.result:nil,channel:$channel,slice:$slice,frame:$frame,selectedRegion:storedSelection?["region"]?.array?.compactMap{$0.number.map(Int.init)})
            case .expressionMatrix(let matrix):BiologyMatrixView(matrix:matrix,selection:storedSelection)
            case .biochemicalNetwork(let network):ScrollView{BiologyNetworkView(network:network,result:model.run?.assetRevision==a.revision ? model.run?.result:nil)}
            case .externalDataset:
                if ["newick","nwk","tree"].contains(a.originalFormat) {BiologyTreeView(data:a.originalData,selection:model.project?.selections?[a.id.uuidString]).id(a.id)}
                else if a.fileReference==nil,["mrc","map","ccp4"].contains(a.originalFormat) {BiologyDensityView(data:a.originalData,selection:model.project?.selections?[a.id.uuidString]).id(a.id)}
                else if ["tif","tiff"].contains(a.originalFormat) {BiologyLargeImageView(model:model,asset:a,executionOwner:executionOwner,onRunAnalysis:onRunAnalysis,scientificEnvironmentID:scientificEnvironmentID).id(a.id)}
                else {ContentUnavailableView(biologyText("Original dataset saved","原始数据已保存"),systemImage:"doc.badge.gearshape",description:Text(biologyText("Choose a configured scientific importer in Analysis.","请在分析中选择已配置的科学数据读取方法。")))}
            }
        } else {ContentUnavailableView(biologyText("Start with a dataset","从一份数据开始"),systemImage:"square.and.arrow.down",description:Text(biologyText("Create a sequence or network from +, import a file, or choose an offline example.","从加号菜单新建序列或网络，导入文件，或选择离线示例。")))}
    }
    private var storedSelection:JSONValue? {model.selectedID.flatMap{model.project?.selections?[$0.uuidString]}}
    private var sequenceRange:Range<Int>? {
        guard Int(storedSelection?["record"]?.number ?? 0)==recordIndex,let a=storedSelection?["start"]?.number,let b=storedSelection?["end"]?.number,a<b else {return nil};return Int(a)..<Int(b)
    }
    @ToolbarContentBuilder private var toolbar:some ToolbarContent {
        ToolbarItemGroup(placement:.topBarTrailing) {
            Menu {
                Section(biologyText("New","新建")) {
                    Button(biologyText("New sequence","新建序列"),systemImage:"text.alignleft"){sheet = .blankSequence}.accessibilityIdentifier("biology.newSequence")
                    Button(biologyText("New reaction network","新建反应网络"),systemImage:"point.3.filled.connected.trianglepath.dotted"){sheet = .blankNetwork}.accessibilityIdentifier("biology.newNetwork")
                }
                Button(biologyText("Import files","导入文件"),systemImage:"square.and.arrow.down"){importing=true}
                Section(biologyText("Offline examples","离线示例")) {
                    ForEach([BiologySampleID.sequenceComparison,.ubiquitinPDB,.ubiquitinMMCIF,.microscopy,.expressionCounts,.reactionNetwork,.phylogeneticTree,.densityVolume]){s in
                        Button(BiologyWorkbenchModel.sampleTitle(s)){Task{await model.addSample(s)}}
                    }
                }
            }label:{Label(biologyText("Add data","添加数据"),systemImage:"plus").frame(minWidth:44,minHeight:44)}.accessibilityIdentifier("biology.add")
            if horizontalSizeClass == .regular {
                Button {Task{await model.undoEdit()}}label:{Image(systemName:"arrow.uturn.backward").frame(width:44,height:44)}.disabled(!model.canUndo || model.busy).accessibilityLabel(biologyText("Undo","撤销")).accessibilityIdentifier("biology.undo")
                Button {Task{await model.redoEdit()}}label:{Image(systemName:"arrow.uturn.forward").frame(width:44,height:44)}.disabled(!model.canRedo || model.busy).accessibilityLabel(biologyText("Redo","重做")).accessibilityIdentifier("biology.redo")
            }
            Button {showingAnalysis.toggle()}label:{Label(biologyText("Analysis","分析"),systemImage:"slider.horizontal.3").frame(minWidth:44,minHeight:44)}.accessibilityIdentifier("biology.analysis")
            Menu {
                if let a=model.selected {
                    Button(biologyText("Export original","导出原件")){Task{await exportAsset(a,format:"original")}}
                    Button(biologyText("Export current data","导出当前数据")){Task{await exportAsset(a,format:derivedFormat(a))}}
                }
                if let r=model.run,r.result != nil {
                    Button(biologyText("Export result table","导出结果表格")){exportDocument = .init(data:Data(r.result!.csv().utf8));exportName="Biology-result.csv";exporting=true}
                    Button(biologyText("Export result text","导出结果文本")){exportDocument = .init(data:Data(r.result!.text.utf8));exportName="Biology-result.txt";exporting=true}.disabled(r.result!.text.isEmpty)
                    if BiologyService.derivableMethods.contains(r.method) {
                        Button(biologyText("Save result as dataset","结果另存为数据")){Task{await model.perform {
                            let created=try await model.service.deriveAsset(model.projectID,runID:r.id);model.selectedID=created.id;showResult=false
                        }}}
                    }
                }
                Button(biologyText("Export project","导出项目")){Task{do{exportDocument = .init(data:try await model.service.exportProject(model.projectID));exportName=(model.project?.title ?? "Biology")+".biology.json";exporting=true}catch{model.error=error.localizedDescription}}}
                if let onInsertInNotes {
                    Button(biologyText("Insert in Notes","插入手记")){Task{await model.perform{try await onInsertInNotes(model.projectID,model.selectedID,model.run?.id)}}}
                }
            }label:{Label(biologyText("Export","导出"),systemImage:"square.and.arrow.up").frame(minWidth:44,minHeight:44)}.accessibilityIdentifier("biology.export")
            Menu {
                if horizontalSizeClass != .regular {
                    Button(biologyText("Undo","撤销"),systemImage:"arrow.uturn.backward"){Task{await model.undoEdit()}}.disabled(!model.canUndo || model.busy).accessibilityIdentifier("biology.undo")
                    Button(biologyText("Redo","重做"),systemImage:"arrow.uturn.forward"){Task{await model.redoEdit()}}.disabled(!model.canRedo || model.busy).accessibilityIdentifier("biology.redo")
                }
                if let a=model.selected {
                    if a.fileReference != nil,let onAuthorizeFile {
                        Button(biologyText("Use in task environment","用于任务计算环境"),systemImage:"externaldrive.badge.plus") {
                            Task{await model.perform {
                                let created=try await onAuthorizeFile(model.projectID,a.id,a.revision)
                                model.selectedID=created.id;model.selectedRunID=nil;showResult=false
                            }}
                        }.accessibilityIdentifier("biology.authorizeFile")
                    }
                    Section(biologyText("Edit data","编辑数据")) {
                        if case .sequence = a.payload {
                            Button(biologyText("Edit sequence","编辑序列"),systemImage:"pencil"){assetEditorContext=AssetEditorContext(asset:a,recordIndex:recordIndex);sheet = .sequence}.accessibilityIdentifier("biology.editSequence")
                            Button(biologyText("Add annotation","添加注释"),systemImage:"tag"){assetEditorContext=AssetEditorContext(asset:a,recordIndex:recordIndex);sheet = .annotation}.accessibilityIdentifier("biology.addAnnotation")
                        }
                        if case .biochemicalNetwork = a.payload {
                            Button(biologyText("Edit network","编辑网络"),systemImage:"pencil"){assetEditorContext=AssetEditorContext(asset:a,recordIndex:recordIndex);sheet = .network}.accessibilityIdentifier("biology.editNetwork")
                        }
                        if case .proteinStructure(let structure) = a.payload {
                            Button(biologyText("Move or rotate structure","移动或旋转结构"),systemImage:"move.3d") {
                                let atoms=structure.atoms.filter{$0.model==structureModel && (chain.isEmpty || $0.chain==chain)}
                                let visible=Set(atoms.map(\.id))
                                transforming=BiologyStructureTransformRequest(asset:a,visibleAtomIDs:atoms.map(\.id),selectedAtomIDs:selectedAtoms.filter{visible.contains($0)})
                            }.accessibilityIdentifier("biology.transformStructure")
                        }
                        Button(biologyText("Rename dataset","重命名数据"),systemImage:"pencil"){renaming=a}
                        Button(biologyText("Delete dataset","删除数据"),systemImage:"trash",role:.destructive){Task{await deleteAsset(a)}}.accessibilityIdentifier("biology.deleteSelectedAsset")
                    }
                }
                Button(biologyText("Research notes","研究记录"),systemImage:"note.text"){sheet = .notes}
                Button(biologyText("Version history","历史版本"),systemImage:"clock.arrow.circlepath"){sheet = .history}
                Button(biologyText("Rename project","重命名项目"),systemImage:"pencil"){sheet = .rename}
                Button(biologyText("Ask AI","询问 AI"),systemImage:"bubble.left.and.bubble.right"){
                    if let onPresentAssistant {
                        let context=BiologyAIContext(projectID:model.projectID,assetID:model.selectedID,assetRevision:model.selected?.revision,selectedRunID:model.run?.id)
                        Task {do {try await onPresentAssistant(context)} catch {model.notice=error.localizedDescription}}
                    }
                    else if assistantContent != nil {assistantContext=BiologyAIContext(projectID:model.projectID,assetID:model.selectedID,assetRevision:model.selected?.revision,selectedRunID:model.run?.id)}
                    else {sheet = .assistant}
                }
                Button(biologyText("Automation tools","自动化工具"),systemImage:"terminal"){sheet = .tools}.accessibilityIdentifier("biology.tools")
            }label:{Label(biologyText("More","更多"),systemImage:"ellipsis.circle").frame(minWidth:44,minHeight:44)}.accessibilityIdentifier("biology.more")
        }
    }
    private var properties:some View {
        VStack(spacing:0) {
            HStack {
                Text(biologyText("Analysis","分析")).font(.title3.weight(.semibold))
                Spacer()
                Button{analysisInput=nil;showingAnalysis=false}label:{Image(systemName:"xmark").frame(width:44,height:44)}
                    .buttonStyle(BiologyControlButtonStyle(compact:true)).accessibilityLabel(biologyText("Done","完成")).accessibilityIdentifier("biology.closeAnalysis")
            }.padding(.horizontal,12).padding(.vertical,6)
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    if let a=model.selected {
                        Label(a.title,systemImage:BiologyLabels.icon(a.kind)).font(.subheadline.weight(.medium)).lineLimit(1).padding(.vertical,4)
                        BiologyChoiceField(title:biologyText("Method","方法"),selection:$selectedMethod,value:BiologyLabels.method(selectedMethod),identifier:"biology.methodField",compact:true){ForEach(offeredMethods[environment] ?? [],id:\.self){Text(BiologyLabels.method($0)).tag($0)}}
                        BiologyChoiceField(title:biologyText("Execution location","执行位置"),selection:$environment,value:environmentTitle(environment),identifier:"biology.environmentField",compact:true){ForEach(offeredMethods.keys.sorted(),id:\.self){Text(environmentTitle($0)).tag($0)}}
                        Divider()
                        analysisParameters(a)
                        DisclosureGroup(biologyText("Additional parameters","更多参数")) {
                            VStack(alignment:.leading,spacing:12){
                                TextEditor(text:$extraOptions).focused($analysisInput,equals:.extra).font(.system(.callout,design:.monospaced)).frame(minHeight:140).autocorrectionDisabled().textInputAutocapitalization(.never).biologyInputSurface()
                                Text(biologyText("Optional parameter object for the selected method.","可填写当前方法支持的参数对象。")).font(.caption).foregroundStyle(.secondary)
                            }.padding(.top,12)
                        }.font(.subheadline)
                        if !a.warnings.isEmpty {
                            Divider()
                            BiologyInspectorSection(title:biologyText("Dataset notes","数据说明"),symbol:"info.circle") {ForEach(Array(a.warnings.enumerated()),id:\.offset){_,text in Text(text).font(.subheadline).foregroundStyle(.secondary)}}
                        }
                        if !a.provenance.isEmpty {
                            DisclosureGroup(biologyText("Source","来源")){ForEach(a.provenance.keys.sorted(),id:\.self){key in LabeledContent(key,value:a.provenance[key]!).font(.caption).textSelection(.enabled).padding(.vertical,4)}}
                        }
                    }
                }.padding(12).frame(maxWidth:720,alignment:.leading).frame(maxWidth:.infinity)
            }.scrollDismissesKeyboard(.interactively).frame(maxHeight:.infinity)
            VStack(spacing:0){
                Divider()
                Button{analysisInput=nil;Task{await startAnalysis()}}label:{
                    HStack(spacing:10){if model.busy{ProgressView().tint(.white)}else{Image(systemName:"play.fill")};Text(biologyText("Run analysis","运行分析"))}.frame(maxWidth:.infinity,minHeight:44)
                }.buttonStyle(BiologyPrimaryButtonStyle()).disabled(model.selected==nil || selectedMethod.isEmpty || model.busy).accessibilityIdentifier("biology.run").padding(12)
            }.background(BiologyStyle.canvas)
        }.frame(maxWidth:.infinity,maxHeight:.infinity).background(BiologyStyle.background)
        // A trailing inspector can retain the previous keyboard's bottom inset
        // after rotation. Reserve keyboard space only while one of its own
        // inputs is focused; real input still uses native keyboard avoidance.
        .ignoresSafeArea(.keyboard,edges:analysisInput==nil ? .bottom:[])
        .toolbar{ToolbarItemGroup(placement:.keyboard){Spacer();Button(biologyText("Finish editing","完成输入")){analysisInput=nil}.accessibilityIdentifier("biology.finishAnalysisEditing")}}
        .onAppear{configureSelection()}
        .onDisappear{analysisInput=nil}
        .onChange(of:environment){_,_ in if !(offeredMethods[environment] ?? []).contains(selectedMethod){selectedMethod=offeredMethods[environment]?.first ?? ""}}
    }
    private var offeredMethods:[String:[String]] {
        var values=model.methods
        if onRunAnalysis != nil,let scientificEnvironmentID,let selected=model.selected {
            let candidates=BiologyService.optionalScientificMethods(for:selected)
            if !candidates.isEmpty {values[scientificEnvironmentID]=Array(Set((values[scientificEnvironmentID] ?? [])+candidates)).sorted()}
        }
        return values
    }
    private func environmentTitle(_ id:String)->String {
        if id=="native.local"{return biologyText("This device","此设备")}
        if id==scientificEnvironmentID{return biologyText("Task environment · checked on Run","任务环境 · 运行时检查")}
        let index=offeredMethods.keys.filter{$0 != "native.local"}.sorted().firstIndex(of:id).map{$0+1} ?? 1
        return biologyText("Compute environment ","计算环境 ")+String(index)
    }
    private func supports(_ parameter:String)->Bool {BiologyMethodCatalog.schema(selectedMethod)["properties"]?.object?[parameter] != nil}
    @ViewBuilder private func analysisParameters(_ a:BiologyAsset)->some View {
        switch a.payload {
        case .sequence(let records):
            BiologyInspectorSection(title:biologyText("Input and parameters","输入与参数"),symbol:"text.alignleft") {
                BiologyChoiceField(title:biologyText("Record","记录"),selection:$recordIndex,value:records.indices.contains(recordIndex) ? records[recordIndex].name:"",identifier:"biology.analysisRecord",compact:true){ForEach(Array(records.enumerated()),id:\.element.id){i,record in Text(record.name).tag(i)}}
                if supports("frame"){BiologyChoiceField(title:biologyText("Reading frame","阅读框"),selection:$translationFrame,value:String(translationFrame),identifier:"biology.readingFrameField",compact:true){ForEach([-3,-2,-1,1,2,3],id:\.self){Text(String($0)).tag($0)}}}
                if supports("code"){BiologyChoiceField(title:biologyText("Genetic code","遗传密码表"),selection:$geneticCode,value:geneticCode==1 ? biologyText("Standard","标准"):biologyText("Vertebrate mitochondrial","脊椎动物线粒体"),identifier:"biology.geneticCodeField",compact:true){Text(biologyText("Standard","标准")).tag(1);Text(biologyText("Vertebrate mitochondrial","脊椎动物线粒体")).tag(2)}}
            }
        case .proteinStructure(let structure):
            VStack(alignment:.leading,spacing:10) {
                HStack(alignment:.top,spacing:12){
                    BiologyChoiceField(title:biologyText("Model","模型"),selection:$structureModel,value:String(structureModel),identifier:"biology.modelField",compact:true){ForEach(Array(Set(structure.atoms.map(\.model))).sorted(),id:\.self){Text(String($0)).tag($0)}}
                    BiologyChoiceField(title:biologyText("Chain","链"),selection:$chain,value:chain.isEmpty ? biologyText("All","全部"):chain,identifier:"biology.chainField",compact:true){Text(biologyText("All chains","所有链")).tag("");ForEach(Array(Set(structure.atoms.map(\.chain))).sorted(),id:\.self){Text($0.isEmpty ? "∅":$0).tag($0)}}
                }
                if supports("cutoff"){TextField("Å",value:$cutoff,format:.number).focused($analysisInput,equals:.cutoff).biologyNamedInput(biologyText("Contact cutoff · Å","接触阈值 · Å"))}
                if selectedMethod=="structure.distance"{BiologyViewFootnote(text:biologyText("Select two atoms in the viewport.","请在视图中选择两个原子。"),symbol:"ruler")}
            }
        case .microscopyImage:
            if supports("threshold"){
                BiologyInspectorSection(title:biologyText("Segmentation","图像分割"),symbol:"viewfinder"){
                    TextField(biologyText("Automatic","自动"),text:$threshold).focused($analysisInput,equals:.threshold).keyboardType(.decimalPad).accessibilityIdentifier("biology.threshold").biologyNamedInput(biologyText("Threshold · blank for automatic","阈值 · 留空自动选择"))
                }
            }
        case .biochemicalNetwork:
            if supports("timeEnd") || supports("step"){
                BiologyInspectorSection(title:biologyText("Time course","时间过程"),symbol:"waveform.path"){
                    if supports("timeEnd"){TextField("",value:$timeEnd,format:.number).focused($analysisInput,equals:.timeEnd).biologyNamedInput(biologyText("End time","结束时间"))}
                    if supports("step"){TextField("",value:$step,format:.number).focused($analysisInput,equals:.step).biologyNamedInput(biologyText("Maximum step","最大步长"))}
                }
            }
        default:EmptyView()
        }
    }
    private var jobBar:some View {
        HStack {
            if let run=model.run {
                if run.isActive {ProgressView().controlSize(.small)}
                Image(systemName:run.status == .succeeded ? "checkmark.circle":"clock")
                Text(BiologyLabels.method(run.method)).font(.subheadline).lineLimit(1)
                Text(runStatus(run.status)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if run.isActive {
                    Button(role:.destructive) {Task{await model.perform{try await model.service.cancel(model.projectID,runID:run.id)}}}label:{Text(biologyText("Stop","停止")).frame(minWidth:44,minHeight:44).contentShape(Rectangle())}.buttonStyle(BiologyControlButtonStyle()).accessibilityIdentifier("biology.stop")
                } else {
                    Button {if let run=model.run{showRun(run.id)}}label:{Text(biologyText("View result","查看结果")).frame(minWidth:44,minHeight:44).contentShape(Rectangle())}.buttonStyle(BiologyControlButtonStyle()).accessibilityIdentifier("biology.showResult")
                }
            }
        }.frame(minHeight:44).padding(.horizontal).accessibilityElement(children:.contain)
    }
    private func runStatus(_ status:BiologyRunStatus)->String {
        switch status {
        case .queued:biologyText("Queued","等待中")
        case .running:biologyText("Running","运行中")
        case .cancelling:biologyText("Stopping","停止中")
        case .succeeded:biologyText("Completed","已完成")
        case .failed:biologyText("Failed","未完成")
        case .cancelled:biologyText("Stopped","已停止")
        case .interrupted:biologyText("Interrupted","已中断")
        }
    }
    private func configureSelection() {
        if case .proteinStructure(let s)=model.selected?.payload {
            if !s.atoms.contains(where:{$0.model==structureModel}){structureModel=s.atoms.first?.model ?? 1}
            if !chain.isEmpty,!s.atoms.contains(where:{$0.chain==chain}){chain=""}
            selectedAtoms=selectedAtoms.filter{id in s.atoms.contains{$0.id==id}}
        }
        if case .microscopyImage(let image)=model.selected?.payload {channel=min(channel,image.channels-1);slice=min(slice,image.slices-1);frame=min(frame,image.frames-1)}
        if case .sequence(let records)=model.selected?.payload {recordIndex=min(recordIndex,records.count-1)}
        if !offeredMethods.keys.contains(environment){environment=offeredMethods.keys.sorted().first ?? "native.local"}
        if !(offeredMethods[environment] ?? []).contains(selectedMethod) {
            let preferred:[BiologyAssetKind:String]=[.sequence:"sequence.stats",.proteinStructure:"structure.geometry",.microscopyImage:"image.segment",.expressionMatrix:"matrix.qc",.biochemicalNetwork:"network.simulate"]
            let list=offeredMethods[environment] ?? []
            selectedMethod=model.selected.flatMap{preferred[$0.kind]}.flatMap{list.contains($0) ? $0:nil} ?? list.first ?? ""
        }
    }
    private func applyStoredSelection() {
        guard let a=model.selected,let selection=model.project?.selections?[a.id.uuidString] else{return}
        if case .sequence(let records)=a.payload {recordIndex=min(max(0,Int(selection["record"]?.number ?? 0)),records.count-1)}
        if case .proteinStructure = a.payload {
            if let m=selection["model"]?.number{structureModel=Int(m)}
            if let c=selection["chain"]?.string{chain=c}
            if let ids=selection["atomIDs"]?.array{selectedAtoms=ids.compactMap{ $0.number.map(Int.init) }}
        }
        if case .microscopyImage = a.payload {channel=Int(selection["channel"]?.number ?? 0);slice=Int(selection["slice"]?.number ?? 0);frame=Int(selection["frame"]?.number ?? 0)}
    }
    private func startAnalysis() async {
        do {
            var options:[String:JSONValue]=[:]
            if let a=model.selected {
                switch a.payload {
                case .sequence:options=["record":.number(Double(recordIndex)),"query":.number(Double(recordIndex==0 ? 1:0)),"frame":.number(Double(translationFrame)),"code":.number(Double(geneticCode))]
                case .proteinStructure(let s):
                    let index=s.atoms.map(\.model).reduce(into:[Int]()){if !$0.contains($1){$0.append($1)}}.firstIndex(of:structureModel) ?? 0
                    options=["model":.number(Double(selectedMethod.hasPrefix("struct.") ? index:structureModel)),"cutoff":.number(cutoff)]
                    if !chain.isEmpty {options["chain"] = .string(chain)}
                    let visible=s.atoms.filter{$0.model==structureModel && (chain.isEmpty || $0.chain==chain)}
                    if selectedAtoms.count==2,let i=visible.firstIndex(where:{$0.id==selectedAtoms[0]}),let j=visible.firstIndex(where:{$0.id==selectedAtoms[1]}) {options["atomA"] = .number(Double(i));options["atomB"] = .number(Double(j))}
                case .microscopyImage:
                    options=["channel":.number(Double(channel)),"slice":.number(Double(slice)),"frame":.number(Double(frame))]
                    if !threshold.isEmpty {guard let value=Double(threshold),value.isFinite else {throw BiologyError.invalid(biologyText("Enter a valid threshold.","请输入有效阈值。"))};options["threshold"] = .number(value)}
                case .biochemicalNetwork:options=["timeEnd":.number(timeEnd),"step":.number(step)]
                default:break
                }
            }
            let fields=BiologyMethodCatalog.schema(selectedMethod)["properties"]?.object ?? [:]
            options=options.filter{fields[$0.key] != nil}
            if !extraOptions.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                let extra=try JSONDecoder().decode(JSONValue.self,from:Data(extraOptions.utf8))
                guard let object=extra.object else {throw BiologyError.invalid(biologyText("Additional parameters must be an object.","更多参数需要是对象。"))}
                options.merge(object){_,new in new}
            }
            if let onRunAnalysis,let selected=model.selected {
                model.busy=true;defer{model.busy=false}
                let intent=BiologyNativeAnalysisIntent(projectID:model.projectID,assetID:selected.id,
                    assetRevision:selected.revision,method:selectedMethod,options:.object(options),environmentID:environment)
                let run=try await onRunAnalysis(intent)
                await model.refresh()
                guard model.selectedID==selected.id,
                      model.project?.runs.contains(where:{$0.id==run.id && $0.assetID==selected.id && $0.assetRevision==selected.revision})==true else{return}
                model.selectedRunID=run.id;model.error=nil;showResult=true
                return
            }
            let owner:BiologyExecutionOwner?
            if environment != "native.local",let a=model.selected {
                guard let executionOwner else {throw BiologyError.unavailable(biologyText("This host must connect the selected compute environment.","当前宿主需要接通所选计算环境。"))}
                owner=try await executionOwner(model.projectID,a.id)
            }else{owner=nil}
            await model.start(method:selectedMethod,options:.object(options),environmentID:environment,owner:owner)
        }catch{model.error=error.localizedDescription}
    }
    @ViewBuilder private func panelView(_ panel:Panel)->some View {
        switch panel {
        case .sequence:if let edit=assetEditorContext {BiologySequenceEditor(model:model,asset:edit.asset,recordIndex:edit.recordIndex)}
        case .annotation:if let edit=assetEditorContext {BiologyAnnotationEditor(model:model,asset:edit.asset,recordIndex:edit.recordIndex)}
        case .network:if let edit=assetEditorContext,case .biochemicalNetwork(let n)=edit.asset.payload {BiologyNetworkEditor(model:model,asset:edit.asset,network:n)}
        case .blankSequence:BiologyBlankAssetSheet(model:model,kind:.sequence)
        case .blankNetwork:BiologyBlankAssetSheet(model:model,kind:.biochemicalNetwork)
        case .history:BiologyHistorySheet(model:model)
        case .notes:BiologyTextSheet(model:model,rename:false)
        case .rename:BiologyTextSheet(model:model,rename:true)
        case .assistant:BiologyAssistantSheet(model:model,handler:onAI)
        case .tools:BiologyToolConsole(projectID:model.projectID,makeTools:makeTools)
        }
    }
    private func deleteAsset(_ a:BiologyAsset) async {
        await model.perform {
            _=try await model.service.update(model.projectID,operation:"asset.delete",assetID:a.id,expectedRevision:a.revision,parameters:.object([:]))
            model.clearUndo(for:a.id)
        }
    }
    private func derivedFormat(_ a:BiologyAsset)->String {
        switch a.kind {
        case .sequence:"fasta"
        case .proteinStructure:"pdb"
        case .microscopyImage:"image.json"
        case .expressionMatrix:"csv"
        case .biochemicalNetwork:"network.json"
        case .externalDataset:"original"
        }
    }
    private func exportAsset(_ a:BiologyAsset,format:String) async {
        do{
            if format=="original",a.fileReference != nil {nativeExport=try await model.service.nativeOriginalExport(model.projectID,assetID:a.id);return}
            exportDocument = .init(data:try await model.service.exportAsset(model.projectID,assetID:a.id,format:format));exportName=a.title+"."+(format=="original" ? a.originalFormat:format);exporting=true
        }
        catch{model.error=error.localizedDescription}
    }
    private func importFiles(_ result:Result<[URL],Error>) async {
        do {
            for url in try result.get() {
                let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
                let values=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
                guard values.isRegularFile==true,values.isSymbolicLink != true,let size=values.fileSize else {throw BiologyError.invalid(biologyText("Choose a regular data file.","请选择普通数据文件。"))}
                if let onImportFile {
                    let imported=try await onImportFile(model.projectID,url)
                    switch imported {
                    case .asset(let projectID,let assetID):
                        guard projectID==model.projectID else{throw BiologyError.invalid(biologyText("The imported dataset belongs to a different project.","导入的数据不属于当前项目。"))}
                        model.selectedID=assetID;model.selectedRunID=nil;showResult=false
                    case .project:
                        model.notice=biologyText("Project imported. Open it from the project list.","项目已导入，可从项目列表打开。")
                    }
                    continue
                }
                if url.lastPathComponent.lowercased().hasSuffix(".biology.json") {
                    guard size<=BiologyProjectStore.maximumProjectBytes else {throw BiologyError.invalid(biologyText("This project is too large to import.","这个项目超过导入大小限制。"))}
                    let data=try Data(contentsOf:url)
                    _=try await model.service.importProject(data);model.notice=biologyText("Project imported. Open it from the project list.","项目已导入，可从项目列表打开。")
                }else if size>BiologyImporter.maximumInputBytes {
                    let asset=try await model.service.importURL(model.projectID,trustedSourceURL:url);model.selectedID=asset.id;continue
                }else{await model.importData(title:url.deletingPathExtension().lastPathComponent,format:url.pathExtension,data:try Data(contentsOf:url))}
            }
            await model.refresh()
        }catch{model.error=error.localizedDescription}
    }
}
struct BiologyTextSheet:View {
    let model:BiologyWorkbenchModel
    let rename:Bool
    @Environment(\.dismiss) private var dismiss
    @State private var text=""
    @State private var revision:UInt64=0
    @State private var error:String?
    @State private var loaded=false
    @State private var saving=false
    @FocusState private var focused:Bool
    var body:some View {
        NavigationStack {
            Group {
                if rename {
                    Form{TextField(biologyText("Project name","项目名称"),text:$text).focused($focused).disabled(!loaded || saving).biologyNamedInput(biologyText("Project name","项目名称"))}
                } else {
                    VStack(alignment:.leading,spacing:20){
                        BiologyPanelHeader(title:model.project?.title ?? biologyText("Project notes","项目记录"),detail:biologyText("Research notes","研究记录"),symbol:"note.text")
                        TextEditor(text:$text).font(.body).focused($focused).disabled(!loaded || saving).scrollContentBackground(.hidden).biologyInputSurface().accessibilityIdentifier("biology.notesDraft")
                    }.padding(20).frame(maxWidth:960,maxHeight:.infinity).frame(maxWidth:.infinity)
                }
            }.background(BiologyStyle.background)
            .overlay{if !loaded{ProgressView()}}
            .safeAreaInset(edge:.bottom){if let error{Text(error).font(.subheadline).foregroundStyle(.red).padding(20)}}
            .navigationTitle(rename ? biologyText("Rename project","重命名项目"):biologyText("Research notes","研究记录")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction){Button(biologyText("Cancel","取消")){dismiss()}.disabled(saving)}
                ToolbarItem(placement:.confirmationAction){Button(biologyText("Save","保存")){Task{await save()}}.disabled(!loaded || saving).accessibilityIdentifier("biology.saveNotes")}
            }
            .interactiveDismissDisabled(saving)
            .task {
                guard !loaded else{return}
                do{let p=try await model.service.project(model.projectID);revision=p.revision;text=rename ? p.title:p.notes;loaded=true}
                catch{self.error=error.localizedDescription}
            }
        }
    }
    private func save() async {
        guard loaded,!saving else{return}
        focused=false;saving=true;defer{saving=false}
        let draft=text,expected=revision
        do {
            if rename {try await model.service.rename(model.projectID,title:draft,expectedRevision:expected)}
            else {try await model.service.saveNotes(model.projectID,text:draft,expectedRevision:expected)}
            await model.refresh();dismiss()
        }catch{self.error=error.localizedDescription}
    }
}
struct BiologyHistorySheet:View {
    let model:BiologyWorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var revisions:[UInt64]=[]
    @State private var error:String?
    var body:some View {
        NavigationStack {
            List {
                if !model.activeRuns.isEmpty {Text(biologyText("Stop active calculations before restoring a version.","恢复版本前请先停止正在运行的计算。"))}
                ForEach(revisions,id:\.self){revision in
                    Button(biologyText("Restore version ","恢复版本 ")+String(revision)){Task{
                        do{_=try await model.service.restore(model.projectID,revision:revision,expectedRevision:model.project?.revision ?? 0);await model.refresh();dismiss()}
                        catch{self.error=error.localizedDescription}
                    }}.disabled(!model.activeRuns.isEmpty)
                }
                if let error {Text(error).foregroundStyle(.red)}
            }.buttonStyle(BiologyControlButtonStyle(expands:true)).navigationTitle(biologyText("Version history","历史版本")).navigationBarTitleDisplayMode(.inline).toolbar{ToolbarItem(placement:.confirmationAction){Button(biologyText("Done","完成")){dismiss()}}}
            .task {do{revisions=try await model.service.history(model.projectID)}catch{self.error=error.localizedDescription}}
        }
    }
}
struct BiologyAssistantSheet:View {
    let model:BiologyWorkbenchModel
    let handler:BiologyAIHandler?
    @Environment(\.dismiss) private var dismiss
    @State private var prompt=""
    @State private var reply=""
    @State private var busy=false
    var body:some View {
        NavigationStack {
            Form {
                if handler==nil {Text(biologyText("Connect a model to ask questions about this dataset.","连接模型后，可围绕这份数据提问。")).foregroundStyle(.secondary)}
                TextField(biologyText("Ask about the selected dataset","询问选中的数据"),text:$prompt,axis:.vertical).biologyNamedInput(biologyText("Question","问题"))
                Button(biologyText("Send","发送")){Task{
                    guard let handler else{return};busy=true;defer{busy=false}
                    let context=BiologyAIContext(projectID:model.projectID,assetID:model.selectedID,assetRevision:model.selected?.revision,selectedRunID:model.run?.id)
                    do{reply=try await handler(prompt,context)}catch{reply=error.localizedDescription}
                }}.buttonStyle(BiologyPrimaryButtonStyle()).disabled(handler==nil || busy || prompt.isEmpty)
                if busy{ProgressView()}
                if !reply.isEmpty{Text(reply).textSelection(.enabled)}
            }.buttonStyle(BiologyControlButtonStyle(expands:true)).navigationTitle(biologyText("Research assistant","研究助手")).navigationBarTitleDisplayMode(.inline).toolbar{ToolbarItem(placement:.confirmationAction){Button(biologyText("Done","完成")){dismiss()}}}
        }
    }
}
struct BiologyBlankAssetSheet:View {
    let model:BiologyWorkbenchModel
    let kind:BiologyAssetKind
    @Environment(\.dismiss) private var dismiss
    @State private var title=""
    @State private var recordName=""
    @State private var sequence=""
    @State private var annotate=false
    @State private var annotationName=""
    @State private var error:String?
    @State private var saving=false
    var body:some View {
        NavigationStack {
            Form {
                TextField(biologyText("Dataset name","数据名称"),text:$title).biologyNamedInput(biologyText("Dataset name","数据名称")).accessibilityIdentifier("biology.blankTitle")
                if kind == .sequence {
                    TextField(biologyText("Record name","记录名称"),text:$recordName).biologyNamedInput(biologyText("Record name","记录名称"))
                    // The blank board is an uncommitted editing draft: nothing is
                    // created until the user enters a valid sequence.
                    TextEditor(text:$sequence).font(.system(.body,design:.monospaced)).frame(minHeight:180).biologyInputSurface().autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityIdentifier("biology.blankSequence")
                    Text(biologyText("Enter a valid A–Z sequence to create this dataset.","请输入有效的 A–Z 序列后创建。")).font(.caption).foregroundStyle(.secondary)
                    Toggle(biologyText("Add opening annotation","添加起始注释"),isOn:$annotate)
                    if annotate {
                        TextField(biologyText("Feature name","注释名称"),text:$annotationName).biologyNamedInput(biologyText("Feature name","注释名称"))
                        Text(biologyText("The opening annotation spans the full new sequence on the forward strand.","起始注释覆盖整条新序列的正向链。")).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(biologyText("Creates one starter species; edit amounts, reactions and units after saving.","先创建一个起始物种，保存后可编辑初始量、反应与单位。")).font(.caption).foregroundStyle(.secondary)
                }
                if let error {Text(error).foregroundStyle(.red)}
            }.buttonStyle(BiologyControlButtonStyle(expands:true)).navigationTitle(kind == .sequence ? biologyText("New sequence","新建序列"):biologyText("New reaction network","新建反应网络")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction){Button(biologyText("Cancel","取消")){dismiss()}.disabled(saving)}
                ToolbarItem(placement:.confirmationAction){Button(biologyText("Create","创建")){Task{await save()}}.disabled(saving).accessibilityIdentifier("biology.createBlank")}
            }
            .interactiveDismissDisabled(saving)
        }
    }
    private func save() async {
        guard !saving else {return}
        saving=true;defer{saving=false}
        do {
            let name=title.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !name.isEmpty else {throw BiologyError.invalid(biologyText("Enter a dataset name.","请输入数据名称。"))}
            guard let revision=model.project?.revision else {throw BiologyError.invalid(biologyText("The project is still loading.","项目仍在加载。"))}
            var parameters:[String:JSONValue]=["title":.string(name),"kind":.string(kind == .sequence ? "sequence" : "biochemicalNetwork")]
            if kind == .sequence {
                let record=recordName.trimmingCharacters(in:.whitespacesAndNewlines)
                parameters["recordName"] = .string(record.isEmpty ? name : record)
                let symbols=sequence.uppercased().filter{!$0.isWhitespace && !$0.isNewline}
                guard !symbols.isEmpty else {throw BiologyError.invalid(biologyText("Enter a sequence.","请输入序列。"))}
                parameters["sequence"] = .string(symbols)
                if annotate {
                    let feature=annotationName.trimmingCharacters(in:.whitespacesAndNewlines)
                    guard !feature.isEmpty else {throw BiologyError.invalid(biologyText("Enter a feature name.","请输入注释名称。"))}
                    parameters["annotation"] = .object(["name":.string(feature),"start":.number(0),"end":.number(Double(symbols.count)),"strand":.number(1)])
                }
            }
            let created=try await model.service.update(model.projectID,operation:"asset.create",assetID:nil,expectedRevision:revision,parameters:.object(parameters))
            await model.refresh()
            if let id=created["assetID"]?.string.flatMap(UUID.init(uuidString:)) {model.selectedID=id}
            dismiss()
        }catch{self.error=error.localizedDescription}
    }
}
struct BiologyAssetRenameSheet:View {
    let model:BiologyWorkbenchModel
    let asset:BiologyAsset
    @Environment(\.dismiss) private var dismiss
    @State private var title=""
    @State private var error:String?
    @State private var saving=false
    var body:some View {
        NavigationStack {
            Form {
                TextField(biologyText("Dataset name","数据名称"),text:$title).biologyNamedInput(biologyText("Dataset name","数据名称")).accessibilityIdentifier("biology.renameTitle")
                if let error {Text(error).foregroundStyle(.red)}
            }.buttonStyle(BiologyControlButtonStyle(expands:true)).navigationTitle(biologyText("Rename dataset","重命名数据")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction){Button(biologyText("Cancel","取消")){dismiss()}.disabled(saving)}
                ToolbarItem(placement:.confirmationAction){Button(biologyText("Save","保存")){Task{await save()}}.disabled(saving).accessibilityIdentifier("biology.saveRename")}
            }
            .interactiveDismissDisabled(saving)
            .task {if title.isEmpty {title=asset.title}}
        }
    }
    private func save() async {
        guard !saving else {return}
        saving=true;defer{saving=false}
        do {
            let name=title.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !name.isEmpty else {throw BiologyError.invalid(biologyText("Enter a dataset name.","请输入数据名称。"))}
            _=try await model.service.update(model.projectID,operation:"asset.rename",assetID:asset.id,expectedRevision:asset.revision,parameters:.object(["title":.string(name)]))
            await model.refresh();dismiss()
        }catch{self.error=error.localizedDescription}
    }
}
/// Preparation belongs to the sheet's cancellable lifetime. A view builder
/// must never start selection writes or present a composer before they finish.
@MainActor private struct BiologySharedAssistantPresentation:View {
    let context:BiologyAIContext
    let prepare:(@MainActor (BiologyAIContext) async throws -> Void)?
    let content:@MainActor (BiologyAIContext) -> AnyView
    @Environment(\.dismiss) private var dismiss
    @State private var ready=false
    @State private var error:String?
    @State private var attempt=0

    var body:some View {
        NavigationStack {
            Group {
                if ready {content(context)}
                else if let error {
                    VStack(spacing:16) {
                        ContentUnavailableView(biologyText("Unable to open assistant","无法打开助手"),systemImage:"exclamationmark.bubble",description:Text(biologyText("Try again, or close and select the current dataset.","请重试，或关闭后重新选择当前数据。")))
                        Button(biologyText("Try again","重试")){attempt += 1}
                        DisclosureGroup(biologyText("Details","详情")){Text(error).font(.caption).textSelection(.enabled)}
                    }.padding()
                } else {ProgressView(biologyText("Opening assistant…","正在打开助手…"))}
            }
            .navigationTitle(biologyText("AI assistant","AI 助手"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {ToolbarItem(placement:.confirmationAction){Button(biologyText("Done","完成")){dismiss()}}}
        }
        .task(id:attempt) {
            ready=false;error=nil
            do {
                try await prepare?(context)
                try Task.checkCancellation()
                ready=true
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else {return}
                self.error=error.localizedDescription
            }
        }
    }
}
#endif

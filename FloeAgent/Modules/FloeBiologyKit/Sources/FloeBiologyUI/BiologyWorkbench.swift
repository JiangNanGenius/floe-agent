// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeBiologyCore
import FloeBiologyEngine
import FloeBiologySamples

@MainActor public struct BiologyWorkbench:View {
    @State private var model:BiologyWorkbenchModel
    private let onAI:BiologyAIHandler?
    private let onInsertInNotes:BiologyNotesHandler?
    private let executionOwner:(@MainActor @Sendable (UUID,UUID) async throws -> BiologyExecutionOwner)?
    @State private var sheet:Panel?
    @State private var importing=false
    @State private var exporting=false
    @State private var exportDocument=BiologyFileDocument(data:Data())
    @State private var exportName="Biology.json"
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
    private enum Panel:String,Identifiable {case properties,sequence,annotation,network,history,notes,assistant,rename;var id:String{rawValue}}
    public init(service:BiologyService,projectID:UUID,onAI:BiologyAIHandler? = nil,onInsertInNotes:BiologyNotesHandler? = nil,executionOwner:(@MainActor @Sendable (UUID,UUID) async throws -> BiologyExecutionOwner)? = nil) {
        _model=State(initialValue:BiologyWorkbenchModel(service:service,projectID:projectID));self.onAI=onAI;self.onInsertInNotes=onInsertInNotes;self.executionOwner=executionOwner
    }
    public var body:some View {
        GeometryReader { geometry in
            HStack(spacing:0) {
                if geometry.size.width>850 {materials.frame(width:220);Divider()}
                VStack(spacing:0) {
                    header(compact:geometry.size.width<=850)
                    Divider()
                    if showResult,let run=model.run {BiologyResultView(run:run,source:model.selected)}
                    else {workspace}
                    if !model.activeRuns.isEmpty || model.run != nil {Divider();jobBar}
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                if geometry.size.width>1150 {Divider();properties.frame(width:300)}
            }
        }
        .navigationTitle(model.project?.title ?? biologyText("Biology","生物"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {toolbar}
        .sheet(item:$sheet){panel in panelView(panel)}
        .fileImporter(isPresented:$importing,allowedContentTypes:[.data],allowsMultipleSelection:true){result in Task{await importFiles(result)}}
        .fileExporter(isPresented:$exporting,document:exportDocument,contentType:.data,defaultFilename:exportName){result in if case .failure(let error)=result{model.error=error.localizedDescription}}
        .safeAreaInset(edge:.bottom) {
            if let error=model.error {
                DisclosureGroup(biologyText("Unable to finish · details","操作未完成 · 详情")) {
                    Text(error).font(.caption).textSelection(.enabled)
                    Button(biologyText("Dismiss","关闭")){model.error=nil}
                }.padding(10).background(.regularMaterial)
            }
        }
        .task {
            await model.refresh();configureSelection()
            while !Task.isCancelled {
                do{try await Task.sleep(for:.milliseconds(500))}catch{return}
                if !model.activeRuns.isEmpty {await model.refresh()}
            }
        }
        .onChange(of:model.selectedID){_,_ in
            recordIndex=0;selectedAtoms=[];channel=0;slice=0;frame=0;chain="";selectedMethod="";model.selectedRunID=nil;showResult=false
            Task{await model.refresh();configureSelection()}
        }
        .onChange(of:model.methods){_,_ in configureSelection()}
    }
    private func header(compact:Bool)->some View {
        HStack {
            if compact {
                Menu {
                    ForEach(model.project?.assets ?? []) {a in
                        Button {model.selectedID=a.id}label:{Label(a.title,systemImage:BiologyLabels.icon(a.kind))}
                            .accessibilityIdentifier("biology.asset."+a.kind.rawValue)
                    }
                }label:{Image(systemName:"sidebar.left").frame(width:44,height:44)}
                    .accessibilityLabel(biologyText("Research materials","研究资料")).accessibilityIdentifier("biology.materials")
            }
            if let a=model.selected {
                VStack(alignment:.leading,spacing:3) {
                    Text(a.title).font(.headline).lineLimit(2)
                    Text(BiologyLabels.kind(a.kind)+" · "+biologyText("Saved","已保存")).font(.caption).foregroundStyle(.secondary)
                }
            } else {Text(biologyText("Import data or open an example","导入数据或打开示例")).foregroundStyle(.secondary)}
            Spacer()
            if model.busy {ProgressView().controlSize(.small)}
            if model.run != nil {
                Picker(biologyText("View","视图"),selection:$showResult) {
                    Text(biologyText("Data","数据")).tag(false);Text(biologyText("Result","结果")).tag(true)
                }.pickerStyle(.segmented).frame(width:150).accessibilityIdentifier("biology.viewMode")
            }
        }.padding(.horizontal).padding(.vertical,10)
    }
    private var materials:some View {
        List(selection:$model.selectedID) {
            Section(biologyText("Research materials","研究资料")) {
                ForEach(model.project?.assets ?? []){a in
                    Label{VStack(alignment:.leading,spacing:3){Text(a.title).lineLimit(2);Text(BiologyLabels.kind(a.kind)).font(.caption).foregroundStyle(.secondary)}}icon:{Image(systemName:BiologyLabels.icon(a.kind))}
                        .tag(a.id).frame(minHeight:44).accessibilityIdentifier("biology.asset."+a.kind.rawValue)
                }
            }
            if let runs=model.project?.runs,!runs.isEmpty {
                Section(biologyText("Analysis history","分析历史")) {
                    ForEach(runs.reversed()){r in
                        Button {model.selectedRunID=r.id;showResult=true} label:{
                            Label(BiologyLabels.method(r.method),systemImage:r.status == .succeeded ? "checkmark.circle":r.isActive ? "hourglass":"exclamationmark.circle")
                        }.frame(minHeight:44)
                    }
                }
            }
        }.listStyle(.sidebar)
    }
    @ViewBuilder private var workspace:some View {
        if let a=model.selected {
            switch a.payload {
            case .sequence(let records):BiologySequenceView(records:records,recordIndex:$recordIndex)
            case .proteinStructure(let s):BiologyStructureView(structure:s,selectedAtoms:$selectedAtoms,modelNumber:$structureModel,chain:$chain)
            case .microscopyImage(let image):BiologyMicroscopyView(image:image,result:model.run?.result,channel:$channel,slice:$slice,frame:$frame)
            case .expressionMatrix(let matrix):BiologyMatrixView(matrix:matrix)
            case .biochemicalNetwork(let network):ScrollView{BiologyNetworkView(network:network,result:model.run?.result)}
            case .externalDataset:
                ContentUnavailableView(biologyText("Original dataset saved","原始数据已保存"),systemImage:"doc.badge.gearshape",description:Text(biologyText("Choose a configured scientific importer in Analysis.","请在分析中选择已配置的科学数据读取方法。")))
            }
        } else {ContentUnavailableView(biologyText("Start with a dataset","从一份数据开始"),systemImage:"square.and.arrow.down",description:Text(biologyText("Import a file, or choose an offline example from +.","导入文件，或从加号菜单选择离线示例。")))}
    }
    @ToolbarContentBuilder private var toolbar:some ToolbarContent {
        ToolbarItemGroup(placement:.topBarTrailing) {
            Menu {
                Button(biologyText("Import files","导入文件"),systemImage:"square.and.arrow.down"){importing=true}
                Section(biologyText("Offline examples","离线示例")) {
                    ForEach([BiologySampleID.sequenceComparison,.ubiquitinPDB,.ubiquitinMMCIF,.microscopy,.expressionCounts,.reactionNetwork]){s in
                        Button(BiologyWorkbenchModel.sampleTitle(s)){Task{await model.addSample(s)}}
                    }
                }
            }label:{Label(biologyText("Add data","添加数据"),systemImage:"plus")}.accessibilityIdentifier("biology.add")
            Button {Task{await model.undoEdit()}}label:{Image(systemName:"arrow.uturn.backward")}.disabled(!model.canUndo || model.busy).accessibilityLabel(biologyText("Undo","撤销")).accessibilityIdentifier("biology.undo")
            Button {Task{await model.redoEdit()}}label:{Image(systemName:"arrow.uturn.forward")}.disabled(!model.canRedo || model.busy).accessibilityLabel(biologyText("Redo","重做")).accessibilityIdentifier("biology.redo")
            Button {sheet = .properties}label:{Label(biologyText("Analysis","分析"),systemImage:"slider.horizontal.3")}.accessibilityIdentifier("biology.analysis")
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
            }label:{Label(biologyText("Export","导出"),systemImage:"square.and.arrow.up")}.accessibilityIdentifier("biology.export")
            Menu {
                Button(biologyText("Research notes","研究记录"),systemImage:"note.text"){sheet = .notes}
                Button(biologyText("Version history","历史版本"),systemImage:"clock.arrow.circlepath"){sheet = .history}
                Button(biologyText("Rename project","重命名项目"),systemImage:"pencil"){sheet = .rename}
                Button(biologyText("Ask AI","询问 AI"),systemImage:"bubble.left.and.bubble.right"){sheet = .assistant}
            }label:{Label(biologyText("More","更多"),systemImage:"ellipsis.circle")}.accessibilityIdentifier("biology.more")
        }
    }
    private var properties:some View {
        Form {
            if let a=model.selected {
                Section(BiologyLabels.kind(a.kind)) {
                    if case .sequence = a.payload {
                        Button(biologyText("Edit sequence","编辑序列"),systemImage:"pencil"){sheet = .sequence}.accessibilityIdentifier("biology.editSequence")
                        Button(biologyText("Add annotation","添加注释"),systemImage:"tag"){sheet = .annotation}
                        Picker(biologyText("Reading frame","阅读框"),selection:$translationFrame){ForEach([-3,-2,-1,1,2,3],id:\.self){Text(String($0)).tag($0)}}
                        Picker(biologyText("Genetic code","遗传密码表"),selection:$geneticCode) {Text(biologyText("Standard","标准")).tag(1);Text(biologyText("Vertebrate mitochondrial","脊椎动物线粒体")).tag(2)}
                    }
                    if case .proteinStructure(let s)=a.payload {
                        Picker(biologyText("Model","模型"),selection:$structureModel){ForEach(Array(Set(s.atoms.map(\.model))).sorted(),id:\.self){Text(String($0)).tag($0)}}
                        Picker(biologyText("Chain","链"),selection:$chain) {Text(biologyText("All chains","所有链")).tag("");ForEach(Array(Set(s.atoms.map(\.chain))).sorted(),id:\.self){Text($0.isEmpty ? "∅":$0).tag($0)}}
                        TextField(biologyText("Contact cutoff · Å","接触阈值 · Å"),value:$cutoff,format:.number)
                        Text(biologyText("Tap two atoms in the viewport to measure their distance.","可在视图中轻点两个原子，测量它们的距离。")).font(.caption).foregroundStyle(.secondary)
                    }
                    if case .microscopyImage = a.payload {
                        TextField(biologyText("Threshold · blank for Otsu","阈值 · 留空自动选择"),text:$threshold).keyboardType(.decimalPad).accessibilityIdentifier("biology.threshold")
                    }
                    if case .biochemicalNetwork = a.payload {
                        Button(biologyText("Edit network","编辑网络"),systemImage:"pencil"){sheet = .network}.accessibilityIdentifier("biology.editNetwork")
                        TextField(biologyText("End time","结束时间"),value:$timeEnd,format:.number)
                        TextField(biologyText("Maximum step","最大步长"),value:$step,format:.number)
                    }
                }
                Section(biologyText("Analysis","分析")) {
                    Picker(biologyText("Execution location","执行位置"),selection:$environment){ForEach(model.methods.keys.sorted(),id:\.self){Text($0=="native.local" ? biologyText("This device","此设备"):$0).tag($0)}}
                    Picker(biologyText("Method","方法"),selection:$selectedMethod){ForEach(model.methods[environment] ?? [],id:\.self){Text(BiologyLabels.method($0)).tag($0)}}
                    Button(biologyText("Run analysis","运行分析"),systemImage:"play.fill"){Task{await startAnalysis()}}
                        .buttonStyle(.borderedProminent).disabled(model.selected==nil || selectedMethod.isEmpty || model.busy).frame(minHeight:44).accessibilityIdentifier("biology.run")
                    DisclosureGroup(biologyText("Additional parameters","更多参数")) {
                        TextEditor(text:$extraOptions).font(.system(.caption,design:.monospaced)).frame(height:100).autocorrectionDisabled()
                        Text(biologyText("Optional parameter object for the selected method.","可填写当前方法支持的参数对象。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !a.warnings.isEmpty {Section(biologyText("Dataset notes","数据说明")){ForEach(Array(a.warnings.enumerated()),id:\.offset){_,s in Text(s).font(.caption)}}}
                if !a.provenance.isEmpty {DisclosureGroup(biologyText("Source","来源")){ForEach(a.provenance.keys.sorted(),id:\.self){k in LabeledContent(k,value:a.provenance[k]!).font(.caption).textSelection(.enabled)}}}
            }
        }.onAppear{configureSelection()}
        .onChange(of:environment){_,_ in if !(model.methods[environment] ?? []).contains(selectedMethod){selectedMethod=model.methods[environment]?.first ?? ""}}
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
                    Button {Task{await model.perform{try await model.service.cancel(model.projectID,runID:run.id)}}}label:{Text(biologyText("Stop","停止")).frame(minWidth:44,minHeight:44).contentShape(Rectangle())}.accessibilityIdentifier("biology.stop")
                } else {
                    Button {showResult=true}label:{Text(biologyText("View result","查看结果")).frame(minWidth:44,minHeight:44).contentShape(Rectangle())}.accessibilityIdentifier("biology.showResult")
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
        if case .proteinStructure(let s)=model.selected?.payload {structureModel=s.atoms.first?.model ?? 1}
        if !model.methods.keys.contains(environment){environment=model.methods.keys.sorted().first ?? "native.local"}
        if !(model.methods[environment] ?? []).contains(selectedMethod) {
            let preferred:[BiologyAssetKind:String]=[.sequence:"sequence.stats",.proteinStructure:"structure.geometry",.microscopyImage:"image.segment",.expressionMatrix:"matrix.qc",.biochemicalNetwork:"network.simulate"]
            let list=model.methods[environment] ?? []
            selectedMethod=model.selected.flatMap{preferred[$0.kind]}.flatMap{list.contains($0) ? $0:nil} ?? list.first ?? ""
        }
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
            if !extraOptions.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                let extra=try JSONDecoder().decode(JSONValue.self,from:Data(extraOptions.utf8))
                guard let object=extra.object else {throw BiologyError.invalid(biologyText("Additional parameters must be an object.","更多参数需要是对象。"))}
                options.merge(object){_,new in new}
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
        case .properties:NavigationStack{properties.navigationTitle(biologyText("Analysis","分析")).toolbar{ToolbarItem(placement:.confirmationAction){Button(biologyText("Done","完成")){sheet=nil}.accessibilityIdentifier("biology.closeAnalysis")}}}
        case .sequence:if let a=model.selected {BiologySequenceEditor(model:model,asset:a,recordIndex:recordIndex)}
        case .annotation:if let a=model.selected {BiologyAnnotationEditor(model:model,asset:a,recordIndex:recordIndex)}
        case .network:if let a=model.selected,case .biochemicalNetwork(let n)=a.payload {BiologyNetworkEditor(model:model,asset:a,network:n)}
        case .history:BiologyHistorySheet(model:model)
        case .notes:BiologyTextSheet(model:model,rename:false)
        case .rename:BiologyTextSheet(model:model,rename:true)
        case .assistant:BiologyAssistantSheet(model:model,handler:onAI)
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
        do{exportDocument = .init(data:try await model.service.exportAsset(model.projectID,assetID:a.id,format:format));exportName=a.title+"."+(format=="original" ? a.originalFormat:format);exporting=true}
        catch{model.error=error.localizedDescription}
    }
    private func importFiles(_ result:Result<[URL],Error>) async {
        do {
            for url in try result.get() {
                let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
                let values=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
                guard values.isRegularFile==true,values.isSymbolicLink != true,let size=values.fileSize,size<=BiologyImporter.maximumInputBytes else {throw BiologyError.invalid(biologyText("Choose a regular file up to 16 MiB, or use a configured compute environment.","请选择不超过 16 MiB 的普通文件，或使用已配置的计算环境。"))}
                let data=try Data(contentsOf:url)
                if url.lastPathComponent.hasSuffix(".biology.json") {
                    _=try await model.service.importProject(data);model.notice=biologyText("Project imported. Open it from the project list.","项目已导入，可从项目列表打开。")
                }else{await model.importData(title:url.deletingPathExtension().lastPathComponent,format:url.pathExtension,data:data)}
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
            Form {
                if rename {TextField(biologyText("Project name","项目名称"),text:$text).focused($focused).disabled(!loaded || saving)}
                else {TextEditor(text:$text).focused($focused).disabled(!loaded || saving).frame(minHeight:320).accessibilityIdentifier("biology.notesDraft")}
                if !loaded || saving {ProgressView()}
                if let error {Text(error).foregroundStyle(.red)}
            }.navigationTitle(rename ? biologyText("Rename project","重命名项目"):biologyText("Research notes","研究记录"))
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
            }.navigationTitle(biologyText("Version history","历史版本")).toolbar{ToolbarItem(placement:.confirmationAction){Button(biologyText("Done","完成")){dismiss()}}}
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
                if handler==nil {Text(biologyText("This qualification host has no connected model. The component accepts Floe's existing model and task services.","此验证宿主未连接模型。组件可接入 Floe 现有模型与任务服务。")).foregroundStyle(.secondary)}
                TextField(biologyText("Ask about the selected dataset","询问选中的数据"),text:$prompt,axis:.vertical)
                Button(biologyText("Send","发送")){Task{
                    guard let handler else{return};busy=true;defer{busy=false}
                    let context=BiologyAIContext(projectID:model.projectID,assetID:model.selectedID,assetRevision:model.selected?.revision,selectedRunID:model.run?.id)
                    do{reply=try await handler(prompt,context)}catch{reply=error.localizedDescription}
                }}.disabled(handler==nil || busy || prompt.isEmpty)
                if busy{ProgressView()}
                if !reply.isEmpty{Text(reply).textSelection(.enabled)}
            }.navigationTitle(biologyText("Research assistant","研究助手")).toolbar{ToolbarItem(placement:.confirmationAction){Button(biologyText("Done","完成")){dismiss()}}}
        }
    }
}
#endif

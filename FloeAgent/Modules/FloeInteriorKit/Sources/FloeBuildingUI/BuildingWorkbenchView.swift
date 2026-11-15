// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import UniformTypeIdentifiers
import FloeBuildingRecords
import FloeBuildingSystems
import FloeBuildingWorkspace

enum BuildingSection: String, CaseIterable, Identifiable {
    case project, model, furniture, sources, bill, cabinet, smartHome, radio, lighting, hvac, deliverables
    var id: Self { self }
    func title(locale:Locale) -> String {
        switch self {
        case .project: BuildingCopy.text("工程与房间", "Project & rooms",locale:locale)
        case .model: BuildingCopy.text("平面与模型", "Plan & model",locale:locale)
        case .furniture: BuildingCopy.text("家具与材料", "Furniture & materials",locale:locale)
        case .deliverables: BuildingCopy.text("图纸与交付", "Sheets & delivery",locale:locale)
        case .sources: BuildingCopy.text("项目资料", "Project files",locale:locale)
        case .bill: BuildingCopy.text("料单校对", "Bill review",locale:locale)
        case .cabinet: BuildingCopy.text("柜体与图纸", "Cabinets & sheets",locale:locale)
        case .smartHome: BuildingCopy.text("智能家居", "Smart home",locale:locale)
        case .radio: BuildingCopy.text("无线规划", "Wireless planning",locale:locale)
        case .lighting: BuildingCopy.text("灯光分析", "Lighting analysis",locale:locale)
        case .hvac: BuildingCopy.text("暖通分析", "HVAC analysis",locale:locale)
        }
    }
    var icon: String {
        switch self {
        case .project: "building.2"; case .sources: "tray.full"; case .bill: "list.clipboard"
        case .model: "square.3.layers.3d"; case .furniture: "sofa"; case .deliverables: "doc.richtext"
        case .cabinet: "cabinet"; case .smartHome: "point.3.connected.trianglepath.dotted"
        case .radio: "wifi"; case .lighting: "lightbulb"; case .hvac: "fan"
        }
    }
}

/// Owns this project's navigation and toolbar. Present directly as the project
/// surface: do not wrap in another NavigationStack or FloeCADHostChrome, which
/// own a different CAD document and would duplicate navigation/save controls.
/// The App supplies the directory after its existing access checks.
public struct BuildingWorkbenchView<ModelContent:View, FurnitureContent:View, DeliveryContent:View>:BuildingLocalizedView {
    @Environment(\.locale) var buildingLocale
    @State private var session:BuildingWorkspaceSession
    @State private var importing=false
    @State private var importingPhotometry=false
    private let modelContent:ModelContent
    private let furnitureContent:FurnitureContent
    private let deliveryContent:DeliveryContent
    private let integrated:Bool
    public init(workspace:BuildingWorkspaceService,actions:BuildingWorkbenchProjectActions,
                @ViewBuilder model:()->ModelContent,@ViewBuilder furniture:()->FurnitureContent,
                @ViewBuilder delivery:()->DeliveryContent){
        _session=State(initialValue:BuildingWorkspaceSession(service:workspace,projectActions:actions))
        modelContent=model();furnitureContent=furniture();deliveryContent=delivery();integrated=true
    }
    private var sections:[BuildingSection]{
        BuildingSection.allCases.filter{integrated || ![.model,.furniture,.deliverables].contains($0)}
    }
    public var body:some View {
        @Bindable var model=session
        NavigationSplitView {
            List(sections,selection:$model.section){item in
                NavigationLink(value:item){Label(item.title(locale:buildingLocale),systemImage:item.icon)}
                    .tag(item).accessibilityIdentifier("building.section."+item.rawValue)
            }.navigationTitle(buildingText("建筑设计","Building design"))
            .safeAreaInset(edge:.bottom){
                VStack(spacing:5){
                    Text(integrated ? buildingText("独立建筑工程","Independent building project"):buildingText("独立组件 · 预研发","Independent component · Preview"))
                    if session.editors.dirtyCount>0 {Text(buildingText("\(session.editors.dirtyCount) 个方案未保存","\(session.editors.dirtyCount) unsaved designs"))}
                }.font(.caption).foregroundStyle(.secondary).padding()
            }
        } detail: {
            Group {
                if session.snapshot==nil {
                    ContentUnavailableView {
                        Label(buildingText("正在打开工程","Opening project"),systemImage:"building.2")
                    } description:{Text(buildingText("读取工程资料和保存的方案。","Reading project files and saved designs."))}
                    actions:{Button(buildingText("重试","Retry")){session.reload()}.disabled(session.operationBusy)}
                } else {
                    switch session.section ?? .project {
                    case .project:ProjectRoomsPanel(session:session)
                    case .sources:ProjectSourcesPanel(session:session)
                    case .bill:BuildingBOMPanel(session:session)
                    case .model:modelContent.disabled(session.operationBusy)
                    case .furniture:furnitureContent.disabled(session.operationBusy)
                    case .deliverables:deliveryContent.disabled(session.operationBusy)
                    default:
                        if session.editorsReady {designPanel}
                        else {ContentUnavailableView {
                            Label(buildingText("方案尚未载入","Designs not loaded"),systemImage:"exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                        } description:{Text(buildingText("项目资料仍可查看；请检查提示后重试。","Project files remain available. Review the message and retry."))}
                        actions:{Button(buildingText("重试载入","Retry loading")){session.reload()}.disabled(session.operationBusy)}}
                    }
                }
            }.navigationTitle((session.section ?? .project).title(locale:buildingLocale))
            .buildingInlineTitle()
            .toolbar {
                ToolbarItemGroup(placement:.primaryAction){
                    if session.operationBusy {ProgressView();if session.busy{Text(session.activity).font(.caption)}}
                    if session.canCancel {Button(buildingText("取消计算","Cancel calculation")){session.cancel()}}
                    else if session.projectActions?.projectOperationBusy()==true,let cancel=session.projectActions?.cancelProjectOperation {
                        Button(buildingText("取消操作","Cancel operation"),action:cancel)
                    }
                    if session.activeKind != nil,session.editorsReady {
                        Button{session.undo()}label:{Label(buildingText("撤销","Undo"),systemImage:"arrow.uturn.backward")}
                            .keyboardShortcut("z",modifiers:.command).disabled(session.operationBusy || (!session.canUndo && !session.activeNumberPending)).accessibilityIdentifier("building.undo")
                        Button{session.redo()}label:{Label(buildingText("重做","Redo"),systemImage:"arrow.uturn.forward")}
                            .keyboardShortcut("z",modifiers:[.command,.shift]).disabled(session.operationBusy || !session.canRedo || session.activeNumberPending).accessibilityIdentifier("building.redo")
                    }
                    if session.editorsReady,(integrated || session.activeKind != nil) {
                        Button{if integrated{session.saveProject()}else{session.saveDesign()}}label:{
                            Label(integrated ? buildingText("保存工程","Save project"):(session.activeDirty ? buildingText("保存修改","Save changes"):buildingText("保存方案","Save design")),systemImage:"square.and.arrow.down")
                        }.keyboardShortcut("s",modifiers:.command).disabled(session.operationBusy).accessibilityIdentifier("building.design.save")
                    }
                    if session.projectActions?.close != nil {
                        Button{session.requestClose()}label:{Label(buildingText("关闭工程","Close project"),systemImage:"xmark")}
                            .disabled(session.operationBusy).accessibilityIdentifier("building.close")
                    }
                    Menu{
                        Button(buildingText("项目资料","Project files")){importingPhotometry=false;importing=true}
                        if let choose=session.projectActions?.requestFurnitureImport {
                            Button(buildingText("OBJ 家具模型包","OBJ furniture package")){choose()}
                        }
                        if session.activeKind == .lighting {
                            Button(buildingText("灯具配光（IES）","Luminaire photometry (IES)")){importingPhotometry=true;importing=true}
                        }
                    }label:{Label(buildingText("导入","Import"),systemImage:"tray.and.arrow.down")}
                    .accessibilityIdentifier("building.import").disabled(session.operationBusy || session.snapshot==nil)
                    Menu{
                        if session.activeKind != nil,session.editorsReady {
                            Button{session.exportCurrent()}label:{Label(buildingText("导出参数 JSON","Export parameters as JSON"),systemImage:"square.and.arrow.up")}
                        }
                        Button{session.requestReopen()}label:{Label(buildingText("重新打开","Reopen"),systemImage:"arrow.clockwise")}
                            .accessibilityIdentifier("building.reopen")
                    }label:{Label(buildingText("更多","More"),systemImage:"ellipsis.circle")}
                    .accessibilityIdentifier("building.more").disabled(session.operationBusy)
                    if let assistant=session.projectActions?.requestAssistant {
                        Button(action:assistant){Label(buildingText("AI 助手","AI assistant"),systemImage:"sparkles")}
                            .accessibilityIdentifier("building.assistant").disabled(session.operationBusy)
                    }
                }
            }
            .safeAreaInset(edge:.bottom){feedback}
        }
        .task{session.locale=buildingLocale;session.reload()}
        .onChange(of:buildingLocale){_,locale in session.locale=locale}
        .onChange(of:session.projectActions?.metadataRevision() ?? -1,initial:true){_,revision in
            session.syncExternalMetadata(revision:revision)
        }
        .confirmationDialog(buildingText("有尚未保存的修改","Unsaved changes"),isPresented:$model.reopenConfirmation,titleVisibility:.visible){
            Button(session.closingProject ? buildingText("保存并关闭","Save and close"):buildingText("保存修改并重新打开","Save changes and reopen")){session.saveAllAndReopen()}
                .disabled(session.hasFormDrafts).accessibilityIdentifier("building.reopen.save")
            Button(session.closingProject ? buildingText("放弃修改并关闭","Discard changes and close"):buildingText("放弃修改并重新打开","Discard changes and reopen"),role:.destructive){session.reopenDiscarding()}
                .accessibilityIdentifier("building.reopen.discard")
            Button(buildingText("取消","Cancel"),role:.cancel){}.accessibilityIdentifier("building.reopen.cancel")
        }message:{
            Text(session.hasFormDrafts
                 ? buildingText("还有未提交的表单输入。可先取消并完成输入，或明确放弃。","Some form input is unsubmitted. Cancel to finish it, or explicitly discard it.")
                 : session.closingProject
                    ? buildingText("关闭前可保存整个工程，或放弃工作副本的修改。","Save the whole project before closing, or discard changes in the working copy.")
                    : buildingText("切换工作台会保留草稿；重新打开会读取已保存版本。","Switching workbenches keeps drafts. Reopening reads saved versions."))
        }
        .fileImporter(isPresented:$importing,allowedContentTypes:importingPhotometry ? [.data]:[.item]){result in
            switch result{
            case .success(let url):if importingPhotometry{session.importIES(url)}else{session.importFile(url)}
            case .failure(let error):if (error as NSError).code != NSUserCancelledError{session.error=buildingError(error)}
            }
        }
        .fileExporter(isPresented:Binding(get:{session.exportDocument != nil},set:{if !$0{session.exportDocument=nil}}),document:session.exportDocument,contentType:.data,defaultFilename:session.exportFilename){result in
            switch result{
            case .success:session.notice=buildingText("文件已导出。","File exported.")
            case .failure(let error):if (error as NSError).code != NSUserCancelledError{session.error=buildingError(error)}
            }
        }
    }
    @ViewBuilder private var designPanel:some View {
        switch session.section {
        case .cabinet:CabinetWorkbenchPanel(session:session)
        case .smartHome:SmartHomeWorkbenchPanel(session:session)
        case .radio:RadioWorkbenchPanel(session:session)
        case .lighting:LightingWorkbenchPanel(session:session)
        case .hvac:HVACWorkbenchPanel(session:session)
        default:EmptyView()
        }
    }
    @ViewBuilder private var feedback:some View {
        if session.error != nil || session.notice != nil {
            VStack(alignment:.leading,spacing:6){
                HStack(alignment:.top){
                    VStack(alignment:.leading,spacing:4){
                        if let error=session.error {Text(error).foregroundStyle(.red).accessibilityIdentifier("building.error")}
                        if let notice=session.notice {Text(notice).accessibilityIdentifier("building.notice")}
                    }
                    Spacer()
                    Button{session.error=nil;session.notice=nil;session.errorDetails=nil}label:{Image(systemName:"xmark.circle").frame(minWidth:44,minHeight:44)}.accessibilityLabel(buildingText("关闭提示","Dismiss message"))
                }
                if let details=session.errorDetails {DisclosureGroup(buildingText("详细信息","Details")){Text(details).font(.caption).textSelection(.enabled)}}
            }.font(.callout).padding().frame(maxWidth:.infinity,alignment:.leading).background(.regularMaterial)
        }
    }
}

public extension BuildingWorkbenchView where ModelContent == EmptyView,FurnitureContent == EmptyView,DeliveryContent == EmptyView {
    init(projectDirectory:URL){
        _session=State(initialValue:BuildingWorkspaceSession(directory:projectDirectory))
        modelContent=EmptyView();furnitureContent=EmptyView();deliveryContent=EmptyView();integrated=false
    }
}

private extension View {
    @ViewBuilder func buildingInlineTitle()->some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

private struct ProjectRoomsPanel:BuildingLocalizedView {
    @Environment(\.locale) var buildingLocale
    let session:BuildingWorkspaceSession
    var body:some View {
        @Bindable var state=session
        Form {
            Section(buildingText("当前工程","Current project")){
                if let snapshot=session.snapshot {
                    LabeledContent(buildingText("名称","Name"),value:snapshot.project.name)
                    LabeledContent(buildingText("已保存版本","Saved revision"),value:String(snapshot.project.revision))
                    Text(buildingText("资料、来源和料单保存在此工程内。参数草稿切换页面保留，保存后可重开。","Files, provenance and bills are stored in this project. Parameter drafts survive page switches; save to reopen them later.")).foregroundStyle(.secondary)
                }
            }
            Section(buildingText("房间","Rooms")){
                HStack{
                    TextField(buildingText("房间名称","Room name"),text:$state.roomDraftName).accessibilityIdentifier("building.room.name")
                    Button(buildingText("添加房间","Add room")){session.createRoom(session.roomDraftName)}
                        .disabled(session.roomDraftName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityIdentifier("building.room.add")
                }
                ForEach(session.snapshot?.rooms ?? []){room in
                    if session.renamingRoomID==room.id {
                        HStack{
                            TextField(buildingText("新名称","New name"),text:$state.renameText).accessibilityIdentifier("building.room.renameText")
                            Button(buildingText("保存名称","Save name")){session.rename(room,to:session.renameText)}.accessibilityIdentifier("building.room.renameSave").disabled(session.renameText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                            Button(buildingText("取消","Cancel")){session.renamingRoomID=nil;session.renameText=""}
                        }.buttonStyle(.borderless)
                    } else {
                        HStack{
                            Button{session.selectedRoomID=room.id}label:{Label(room.name,systemImage:session.selectedRoomID==room.id ? "checkmark.circle.fill":"door.left.hand.open")}
                            Spacer()
                            if session.selectedRoomID==room.id {
                                Button(buildingText("改名","Rename")){session.renameText=room.name;session.renamingRoomID=room.id}
                                    .accessibilityIdentifier("building.room.renameSelected")
                            }
                        }.buttonStyle(.borderless)
                    }
                }
            }
            Section(buildingText("组件范围","Component scope")){
                Text(buildingText("当前提供资料与料单流程、柜体组合页规划、智能家居连接检查，以及无线、灯光和暖通初算。","This stage provides file and bill workflows, cabinet sheet planning, smart-home checks and preliminary wireless, lighting and HVAC calculations."))
                Text(buildingText("完整 CAD、正式工程图、专业仿真和主 App 入口分别验证。","Full CAD, final drawings, professional simulation and the main App entrypoint are verified separately.")).foregroundStyle(.secondary)
            }
        }.disabled(session.operationBusy)
    }
}

private struct ProjectSourcesPanel:BuildingLocalizedView {
    @Environment(\.locale) var buildingLocale
    let session:BuildingWorkspaceSession
    var body:some View {
        @Bindable var state=session
        List {
            Section {
                HStack{
                    TextField(buildingText("查找工程资料","Search project records"),text:$state.sourceQuery)
                    Button(buildingText("查找","Search")){session.search()}.disabled(session.sourceQuery.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
                Picker(buildingText("房间筛选","Room filter"),selection:$state.sourceRoomFilter){
                    Text(buildingText("全部房间","All rooms")).tag(RoomID?.none)
                    ForEach(session.snapshot?.rooms ?? []){room in Text(room.name).tag(Optional(room.id))}
                }.onChange(of:session.sourceRoomFilter){_,_ in session.sourceRevision=nil;session.sourcePage(reset:true)}
                Text(buildingText("CSV 可生成料单草稿；其他文件先保留原件。","CSV can create bill drafts; other files are retained as originals.")).font(.callout).foregroundStyle(.secondary)
            }
            if !session.searchHits.isEmpty {
                Section(buildingText("工程检索结果","Project search results")){
                    ForEach(session.searchHits){hit in
                        if case .source(let id)=hit.reference {Button(hit.title){session.chooseSource(id)}}
                        else{VStack(alignment:.leading){Text(hit.title);Text(hit.detail).font(.caption).foregroundStyle(.secondary)}}
                    }
                }
            }
            Section(buildingText("资料","Files")){
                if session.sourceRows.isEmpty {Text(buildingText("当前筛选下没有已载入资料。","No loaded files match this filter.")).foregroundStyle(.secondary)}
                ForEach(session.sourceRows.filter{$0.kind != .other || !$0.title.hasPrefix("floe-component:")}){source in
                    Button{session.chooseSource(source.id)}label:{
                        HStack{Label(source.title,systemImage:source.kind == .photo ? "photo":"doc");Spacer();if session.selectedSourceID==source.id{Image(systemName:"checkmark")}}
                    }
                }
                if session.sourceNextOffset != nil {Button(buildingText("载入更多","Load more")){session.sourcePage()}}
                if session.sourceRequiresFilter{Text(buildingText("还有更多资料，请缩小房间筛选后继续查找。","More files exist. Narrow the room filter to continue.")).foregroundStyle(.orange)}
                Button(buildingText("刷新资料","Refresh files")){session.sourcePage(reset:true)}
            }
            if let source=session.sourceDetail {
                Section(buildingText("所选资料","Selected file")){
                    LabeledContent(buildingText("原文件","Original"),value:source.latestOriginalName)
                    LabeledContent(buildingText("原件版本","Source version"),value:String(source.latestVersionNumber))
                    Menu(buildingText("关联房间","Assign rooms")){
                        ForEach(session.snapshot?.rooms ?? []){room in
                            Button{session.associate(source,roomID:room.id)}label:{
                                if source.roomIDs.contains(room.id){Label(room.name,systemImage:"checkmark")}else{Text(room.name)}
                            }
                        }
                    }
                    Text((session.snapshot?.rooms ?? []).filter{source.roomIDs.contains($0.id)}.map(\.name).joined(separator:" · ")).font(.caption)
                    Button(buildingText("导出原件","Export original")){session.exportSource(source)}
                    if source.kind == .table {Button(buildingText("生成／重试料单草稿","Create or retry bill draft")){session.retryCSV(source)}}
                }
            }
        }.disabled(session.operationBusy)
        .task(id:session.busy ? nil:session.sourceLoadKey){
            if !session.busy{session.sourcePage(reset:true,automatic:true)}
        }
    }
}

private struct BuildingBOMPanel:BuildingLocalizedView {
    @Environment(\.locale) var buildingLocale
    let session:BuildingWorkspaceSession
    var body:some View {
        @Bindable var state=session
        List {
            Section(buildingText("目标料单","Target bill")){
                Picker(buildingText("采用到","Adopt into"),selection:Binding(get:{session.selectedTargetID},set:{session.selectTarget($0)})){
                    Text(buildingText("请选择料单","Choose a bill")).tag(BOMTargetID?.none)
                    ForEach(session.snapshot?.targets ?? []){target in Text(target.name).tag(Optional(target.id))}
                }.accessibilityIdentifier("building.bom.target")
                HStack{
                    TextField(buildingText("新料单名称","New bill name"),text:$state.targetDraftName).accessibilityIdentifier("building.bom.targetName")
                    Button(buildingText("创建料单","Create bill")){session.createTarget()}.disabled(session.targetDraftName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityIdentifier("building.bom.createTarget")
                }
                Text(buildingText("先核对来源、型号、数量、单位与房间，再采用选中的行。设备与通道分别计数。","Review source, model, quantity, unit and room, then adopt selected rows. Devices and channels are counted separately.")).foregroundStyle(.secondary)
                Button(buildingText("导入示例料单","Import sample bill")){
                    let room=session.selectedRoomID.flatMap{id in session.snapshot?.rooms.first{$0.id==id}?.name} ?? ""
                    let quoted="\""+room.replacingOccurrences(of:"\"",with:"\"\"")+"\""
                    let csv="品牌,型号,数量,单位,房间,角色,通道数\r\nSynthetic,DEMO-AP,2,台,\(quoted),设计,1\r\nSynthetic,DEMO-RELAY,1,台,\(quoted),设计,4\r\n"
                    session.importCSV(Data(csv.utf8),name:"synthetic-smart-home.csv")
                }.accessibilityIdentifier("building.bom.sample")
            }
            Section(buildingText("已保存草稿","Saved drafts")){
                ForEach(session.snapshot?.drafts ?? []){draft in Button{session.openDraft(draft.id)}label:{
                    VStack(alignment:.leading){
                        Text(session.snapshot?.sources.first(where:{$0.latestVersionID==draft.sourceVersionID})?.title ?? buildingText("较早资料","Earlier source"))
                        HStack{Text(draft.createdAt.formatted(date:.abbreviated,time:.shortened));Text("\(draft.rowCount) "+buildingText("行","rows"));Text("\(draft.readyCount) "+buildingText("可采用","ready"))}.font(.caption).foregroundStyle(.secondary)
                    }
                }}
                if session.snapshot?.draftsHaveMore==true{Text(buildingText("当前列出最近100份草稿。","Showing the latest 100 drafts.")).font(.caption)}
            }
            if let draft=session.review {
                Section(buildingText("当前校对","Current review")){
                    ForEach(draft.rows){row in
                        Toggle(isOn:Binding(get:{session.selectedDraftRows.contains(row.id)},set:{selected in if selected{session.selectedDraftRows.insert(row.id)}else{session.selectedDraftRows.remove(row.id)}})){
                            VStack(alignment:.leading,spacing:5){
                                Text([row.brand,row.model].compactMap{$0}.joined(separator:" · ")).font(.headline)
                                Text("\(row.rawQuantity) \(row.rawUnit ?? "?") · \(row.roomName ?? "?")")
                                Text(buildingText("原文件第 \(row.lineNumber) 行","Source line \(row.lineNumber)")).font(.caption).foregroundStyle(.secondary)
                                if row.state == .needsReview{Text(buildingText("有待核对项，请先查看下方提示。","Review the issues below before selecting.")).font(.caption).foregroundStyle(.orange)}
                                if row.state == .blocked{Text(buildingText("不可用，请修正原表后重试。","Unusable. Correct the source table and retry.")).font(.caption).foregroundStyle(.red)}
                            }
                        }.disabled(row.state == .blocked).accessibilityIdentifier("building.bom.row."+row.id.rawValue.uuidString)
                    }
                    ForEach(draft.issues){issue in Text(issue.message).font(.caption).foregroundStyle(.orange)}
                    if draft.rows.contains(where:{$0.state != .ready}) {
                        Text(buildingText("待核对行可查看来源和提示后逐条勾选；不可用行请修正原表后重试。","Review source and issues before selecting warning rows; correct unusable rows in the source table and retry.")).font(.callout)
                    }
                    Button(buildingText("采用所选行","Adopt selected rows")){session.applyReview()}
                        .disabled(session.selectedTargetID==nil || session.selectedDraftRows.isEmpty || (draft.targetID != nil && draft.targetID != session.selectedTargetID))
                        .accessibilityIdentifier("building.bom.apply")
                    if let bound=draft.targetID,bound != session.selectedTargetID {Text(buildingText("此旧草稿已绑定其他料单，请选择对应目标。","This saved draft is bound to another bill. Select its target.")).foregroundStyle(.orange)}
                }
            }
            Section(buildingText("已采用料单","Adopted bill")){
                if session.selectedTargetID==nil {Text(buildingText("选择目标料单后查看已采用项目。","Choose a target bill to view adopted items."))}
                else {
                    Picker(buildingText("房间筛选","Room filter"),selection:$state.billRoomFilter){
                        Text(buildingText("全部房间","All rooms")).tag(RoomID?.none)
                        ForEach(session.snapshot?.rooms ?? []){room in Text(room.name).tag(Optional(room.id))}
                    }.onChange(of:session.billRoomFilter){_,_ in session.billFilterChanged()}
                    Picker(buildingText("用途筛选","Role filter"),selection:$state.billRoleFilter){
                        Text(buildingText("全部用途","All roles")).tag(BOMRole?.none)
                        ForEach(BOMRole.allCases,id:\.self){role in Text(roleTitle(role)).tag(Optional(role))}
                    }.onChange(of:session.billRoleFilter){_,_ in session.billFilterChanged()}
                    if session.billRows.isEmpty{Text(buildingText("此筛选下尚无已采用项目。","No adopted items match these filters.")).foregroundStyle(.secondary)}
                }
                ForEach(session.billRows){item in
                    LabeledContent(item.rawModel ?? buildingText("待确认型号","Model needed"),value:"\(item.quantity) \(item.rawUnit ?? "?")")
                }
                if session.billNextOffset != nil{Button(buildingText("载入更多项目","Load more items")){session.billPage()}}
                if session.billRequiresFilter{Text(buildingText("还有更多项目，请按房间或角色缩小范围。","More items exist. Narrow by room or role.")).foregroundStyle(.orange)}
                if session.selectedTargetID != nil{Button(buildingText("刷新料单","Refresh bill")){session.billPage(reset:true)}}
            }
        }.disabled(session.operationBusy)
        .task(id:session.busy ? nil:session.billLoadKey){if !session.busy{session.billPage(reset:true,automatic:true)}}
    }
    private func roleTitle(_ role:BOMRole)->String{switch role {
        case .designRequirement:buildingText("设计需求","Design requirement")
        case .quotation:buildingText("报价","Quotation")
        case .ordered:buildingText("已订购","Ordered")
        case .received:buildingText("已到货","Received")
        case .installed:buildingText("已安装","Installed")
        case .spare:buildingText("备用","Spare")
        case .kitComponent:buildingText("套装组成","Kit component")
        case .sourceNote:buildingText("来源备注","Source note")
    }}
}

// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import Observation
import UniformTypeIdentifiers
import FloeBuildingWorkspace
import FloeBuildingRecords
import FloeBuildingSystems
import FloeBuildingAnalysis
import FloeInteriorCore

@MainActor @Observable
final class BuildingWorkspaceSession {
    let service:BuildingWorkspaceService
    let projectActions:BuildingWorkbenchProjectActions?
    let editors=BuildingWorkbenchEditors()
    let numberInputs=BuildingNumberInputs()
    var locale=Locale.current {didSet{numberInputs.locale=locale}}
    func text(_ zh:String,_ en:String)->String {BuildingCopy.text(zh,en,locale:locale)}
    func errorMessage(_ error:Error)->String {BuildingCopy.errorMessage(error,locale:locale)}
    var snapshot:BuildingWorkspaceSnapshot? {
        didSet {if let project=snapshot?.project{projectActions?.recordsChanged(project.id,project.revision)}}
    }
    var editorsReady=false
    var section:BuildingSection? {
        didSet {
            guard !suppressSectionPersistence, let section else { return }
            UserDefaults.standard.set(section.rawValue, forKey: sectionStorageKey)
        }
    }
    var selectedRoomID:RoomID? {
        didSet {projectActions?.roomSelectionChanged(selectedRoomID)}
    }
    var selectedSourceID:SourceID?
    var selectedTargetID:BOMTargetID?
    var selectedDeviceID:UUID?
    var firstPortID:UUID?
    var secondPortID:UUID?
    var sceneNameDraft=""
    var sceneTriggerDraft=""
    var sceneActionDraft=""
    var sceneEquipmentIDs:Set<UUID>=[]
    var roomDraftName=""
    var renamingRoomID:RoomID?
    var renameText=""
    var targetDraftName=""
    var cabinetNoteDraft=""
    var panelErrors:[BuildingComponentKind:String]=[:]
    var sourceRoomFilter:RoomID?
    var billRoomFilter:RoomID?
    var billRoleFilter:BOMRole?
    var sourceQuery=""
    var searchHits:[RecordSearchHit]=[]
    var sourceRows:[SourceRecord]=[]
    var sourceNextOffset:Int?
    var sourceRequiresFilter=false
    var sourceRevision:Int?
    var sourceAttemptKey:String?
    var billRows:[BOMItem]=[]
    var billNextOffset:Int?
    var billRequiresFilter=false
    var billRevision:Int?
    var billAttemptKey:String?
    var sourceLoadKey:String{String(snapshot?.project.revision ?? -1)+":"+(sourceRoomFilter?.rawValue.uuidString ?? "all")}
    var billLoadKey:String{[String(snapshot?.project.revision ?? -1),selectedTargetID?.rawValue.uuidString ?? "none",billRoomFilter?.rawValue.uuidString ?? "all",billRoleFilter?.rawValue ?? "all"].joined(separator:":")}
    var sourceDetail:SourceRecord?
    var review:BOMDraft?
    var selectedDraftRows:Set<BOMDraftRowID>=[]
    var busy=false
    var operationBusy:Bool {busy || projectActions?.projectOperationBusy()==true}
    var activity=""
    var error:String?
    var errorDetails:String?
    var notice:String?
    var reopenConfirmation=false
    var closingProject=false
    var exportDocument:BuildingFileDocument?
    var exportFilename="design.json"
    private var operationID:UUID?
    private var operationTask:Task<Void,Never>?
    private var cancelCalculation:(()->Void)?
    private var cancelledOperations:Set<UUID>=[]
    private var wantedMetadataRevision:Int?
    private let sectionStorageKey:String
    private var suppressSectionPersistence = true
    init(directory:URL){
        let service=BuildingWorkspaceService(projectDirectory:directory)
        self.service=service;projectActions=nil
        sectionStorageKey = "floe.building.workspace.section." + directory.standardizedFileURL.path
        section = .project
        suppressSectionPersistence = false
    }
    init(service:BuildingWorkspaceService,projectActions:BuildingWorkbenchProjectActions,
         initialSection:BuildingSection = .model, integrated:Bool = true){
        self.service=service;self.projectActions=projectActions
        sectionStorageKey = "floe.building.workspace.section." + service.directoryURL.standardizedFileURL.path
        let saved=UserDefaults.standard.string(forKey:sectionStorageKey).flatMap(BuildingSection.init(rawValue:))
        if integrated, let saved, Self.availableSections(integrated:true).contains(saved) {
            section = saved
        } else {
            section = integrated ? initialSection : .project
        }
        suppressSectionPersistence = false
    }

    private static func availableSections(integrated:Bool)->[BuildingSection] {
        BuildingSection.allCases.filter{integrated || ![.model,.furniture,.deliverables].contains($0)}
    }
    var canCancel:Bool{cancelCalculation != nil}
    var activeKind:BuildingComponentKind? {
        switch section {
        case .cabinet:.cabinet;case .smartHome:.smartHome;case .radio:.radio;case .lighting:.lighting;case .hvac:.hvac
        default:nil
        }
    }
    var activeNumberPending:Bool{activeKind.map{numberInputs.hasPending(prefix:$0.rawValue)} ?? false}
    var activeDirty:Bool {
        if activeNumberPending || (activeKind == .lighting && editors.lightingPreviewOutput != nil){return true}
        return switch activeKind {
        case .cabinet:editors.cabinet.isDirty;case .smartHome:editors.smartHome.isDirty;case .radio:editors.radio.isDirty
        case .lighting:editors.lighting.isDirty;case .hvac:editors.hvac.isDirty;case nil:false
        }
    }
    var canUndo:Bool {
        switch activeKind {
        case .cabinet:editors.cabinet.canUndo;case .smartHome:editors.smartHome.canUndo;case .radio:editors.radio.canUndo
        case .lighting:editors.lighting.canUndo;case .hvac:editors.hvac.canUndo;case nil:false
        }
    }
    var canRedo:Bool {
        switch activeKind {
        case .cabinet:editors.cabinet.canRedo;case .smartHome:editors.smartHome.canRedo;case .radio:editors.radio.canRedo
        case .lighting:editors.lighting.canRedo;case .hvac:editors.hvac.canRedo;case nil:false
        }
    }
    func undo(){guard !busy else{return};if let kind=activeKind,numberInputs.discardPending(prefix:kind.rawValue){return};switch activeKind {
        case .cabinet:editors.cabinet.undo();case .smartHome:editors.smartHome.undo();case .radio:editors.radio.undo()
        case .lighting:editors.lighting.undo();case .hvac:editors.hvac.undo();case nil:break
    }}
    func redo(){guard !busy else{return};switch activeKind {
        case .cabinet:editors.cabinet.redo();case .smartHome:editors.smartHome.redo();case .radio:editors.radio.redo()
        case .lighting:editors.lighting.redo();case .hvac:editors.hvac.redo();case nil:break
    }}
    private func launch(_ label:String,clearFeedback:Bool=true,_ work:@escaping @MainActor () async throws -> Void) {
        guard !busy else{return}
        let token=UUID();operationID=token;busy=true;activity=label
        if clearFeedback{error=nil;errorDetails=nil;notice=nil}
        operationTask=Task {
            defer {
                if operationID==token {busy=false;activity="";cancelCalculation=nil;operationID=nil;operationTask=nil}
                cancelledOperations.remove(token)
                refreshExternalMetadataIfNeeded()
            }
            do{try await work()}
            catch {
                guard !cancelledOperations.contains(token) else{return}
                if let intake=error as? BuildingWorkspaceIntakeError {
                    await accept(intake.archived.snapshot)
                    selectedSourceID=intake.archived.source.id;sourceDetail=intake.archived.source;section = .sources
                    self.error=self.text("原件已保留，料单尚未生成。请检查表格内容后重试。","Original retained; no bill draft was created. Check the table and retry.")
                    errorDetails=intake.underlying.localizedDescription
                } else {
                    self.error=self.errorMessage(error);errorDetails=error.localizedDescription
                }
            }
        }
    }
    private func accept(_ value:BuildingWorkspaceSnapshot) async {
        var next=value
        if let selectedTargetID,value.targets.contains(where:{$0.id==selectedTargetID}),value.selectedTargetID != selectedTargetID {
            if let retained=try? await service.snapshot(targetID:selectedTargetID){next=retained}
        }
        snapshot=next;selectedTargetID=next.selectedTargetID
        if let selectedRoomID,!next.rooms.contains(where:{$0.id==selectedRoomID}){self.selectedRoomID=nil}
        if let sourceRoomFilter,!next.rooms.contains(where:{$0.id==sourceRoomFilter}){self.sourceRoomFilter=nil}
        if let billRoomFilter,!next.rooms.contains(where:{$0.id==billRoomFilter}){self.billRoomFilter=nil}
        if sourceRevision != next.project.revision {sourceRows=[];sourceNextOffset=nil;sourceRevision=nil}
        if billRevision != next.project.revision {billRows=[];billNextOffset=nil;billRevision=nil}
    }
    func syncExternalMetadata(revision:Int){
        guard revision>=0,revision != snapshot?.project.revision else{return}
        wantedMetadataRevision=revision;refreshExternalMetadataIfNeeded()
    }
    private func refreshExternalMetadataIfNeeded(){
        guard !busy,snapshot != nil,let wanted=wantedMetadataRevision else{return}
        wantedMetadataRevision=nil
        guard wanted != snapshot?.project.revision else{return}
        launch(self.text("更新工程资料…","Refreshing project files…"),clearFeedback:false){
            await self.accept(try await self.service.snapshot(targetID:self.selectedTargetID))
        }
    }
    func reload(){
        guard snapshot==nil || !editorsReady else{return}
        launch(self.text("打开工程…","Opening project…")){try await self.load()}
    }
    private func load() async throws {
        do {
            let loaded=try await service.loadProject(targetID:selectedTargetID)
            try editors.restore(loaded)
            await accept(loaded.snapshot);editorsReady=true;review=nil;selectedDraftRows=[];numberInputs.clear()
            roomDraftName="";renamingRoomID=nil;renameText="";targetDraftName="";cabinetNoteDraft="";sceneNameDraft="";sceneTriggerDraft="";sceneActionDraft="";sceneEquipmentIDs=[];panelErrors=[:]
        } catch {
            if snapshot==nil,let metadata=try? await service.snapshot(){snapshot=metadata}
            throw error
        }
    }
    func createRoom(_ name:String){
        guard let project=snapshot?.project else{return}
        launch(self.text("添加房间…","Adding room…")){
            let result=try await self.service.createRoomIdentified(name:name,projectID:project.id,expectedRevision:project.revision)
            await self.accept(result.snapshot);self.selectedRoomID=result.room.id;self.roomDraftName=""
            self.notice=self.text("房间已保存。","Room saved.")
        }
    }
    func rename(_ room:RoomRecord,to name:String){
        guard let project=snapshot?.project else{return}
        launch(self.text("保存房间名称…","Saving room name…")){
            await self.accept(try await self.service.renameRoom(room.id,name:name,projectID:project.id,expectedRevision:project.revision))
            self.renamingRoomID=nil;self.renameText="";self.selectedRoomID=room.id
            self.notice=self.text("房间名称已保存，关联资料保留。","Room renamed; linked files retained.")
        }
    }
    func associate(_ source:SourceRecord,roomID:RoomID){
        guard let project=snapshot?.project else{return}
        launch(self.text("保存资料关联…","Saving file links…")){
            let fresh=try await self.service.sourceRecord(source.id,projectID:project.id)
            var selection=Set(fresh.roomIDs);if !selection.insert(roomID).inserted{selection.remove(roomID)}
            await self.accept(try await self.service.associateSource(source.id,roomIDs:selection,projectID:project.id,expectedRevision:project.revision))
            self.sourceDetail=try await self.service.sourceRecord(source.id,projectID:project.id)
            try await self.loadSources(reset:true)
        }
    }
    func selectTarget(_ id:BOMTargetID?){
        launch(self.text("读取料单…","Loading bill…")){
            let loaded=try await self.service.snapshot(targetID:id)
            self.snapshot=loaded
            self.selectedTargetID=loaded.selectedTargetID;self.billRows=[];self.billRevision=nil;self.billAttemptKey=nil
        }
    }
    func createTarget(){
        guard let project=snapshot?.project else{return};let name=targetDraftName
        launch(self.text("创建料单…","Creating bill…")){
            let value=try await self.service.createBOMTarget(name:name,projectID:project.id,expectedRevision:project.revision)
            self.selectedTargetID=value.selectedTargetID;self.snapshot=value;self.targetDraftName=""
        }
    }
    private func acceptDraft(_ result:BuildingWorkspaceDraft) async {
        if let bound=result.draft.targetID{selectedTargetID=bound}
        await accept(result.snapshot);review=result.draft;selectedSourceID=result.sourceID
        selectedDraftRows=Set(result.draft.rows.filter{$0.state == .ready}.map(\.id));section = .bill
    }
    func importCSV(_ data:Data,name:String){
        guard let project=snapshot?.project else{return};let target=selectedTargetID
        launch(self.text("归档并校对料单…","Archiving and reviewing bill…")){
            await self.acceptDraft(try await self.service.intakeCSV(data,originalName:name,projectID:project.id,expectedRevision:project.revision,replayKey:"ui/"+UUID().uuidString,targetID:target))
        }
    }
    func openDraft(_ id:BOMDraftID){
        guard let project=snapshot?.project else{return}
        launch(self.text("读取草稿…","Loading draft…")){
            let draft=try await self.service.draft(id,projectID:project.id)
            self.review=draft;self.selectedDraftRows=Set(draft.rows.filter{$0.state == .ready}.map(\.id))
            if let target=draft.targetID{self.selectedTargetID=target;self.snapshot=try await self.service.snapshot(targetID:target)}
        }
    }
    func applyReview(){
        guard let draft=review,let target=selectedTargetID,let project=snapshot?.project,!selectedDraftRows.isEmpty else{return}
        let selected=selectedDraftRows
        launch(self.text("采用所选料单行…","Adopting selected bill rows…")){
            self.snapshot=try await self.service.applyDraft(draft.id,targetID:target,projectID:project.id,expectedRevision:project.revision,selectedRowIDs:selected)
            self.billRows=[];self.billRevision=nil;self.billAttemptKey=nil
            self.notice=self.text("所选行已采用；原件与草稿保留。","Selected rows adopted; original and draft retained.")
        }
    }
    func retryCSV(_ source:SourceRecord){
        guard let project=snapshot?.project else{return};let target=selectedTargetID
        launch(self.text("重试料单提取…","Retrying bill extraction…")){
            await self.acceptDraft(try await self.service.reviewCSVSource(source.latestVersionID,projectID:project.id,expectedRevision:project.revision,targetID:target))
        }
    }
    private var hasUnsavedProject:Bool{editors.dirtyCount>0 || numberInputs.hasPending || hasFormDrafts || projectActions?.hasUnpublishedChanges()==true}
    func requestReopen(){guard !busy else{return};closingProject=false;commitLightingPreview();if hasUnsavedProject{reopenConfirmation=true}else{reopenDiscarding()}}
    func requestClose(){guard !busy,projectActions?.close != nil else{return};closingProject=true;commitLightingPreview();if hasUnsavedProject{reopenConfirmation=true}else{reopenDiscarding()}}
    func reopen(){requestReopen()}
    func reopenDiscarding(){
        let closing=closingProject
        launch(closing ? self.text("关闭工程…","Closing project…"):self.text("重新打开工程…","Reopening project…")){
            defer{self.projectActions?.departureEnded()}
            let proceed=try await self.projectActions?.beforeDeparture(closing) ?? true
            guard proceed else{return}
            try await self.service.close()
            if closing {try await self.projectActions?.close?();return}
            let outcome=try await self.projectActions?.reopen() ?? .reloadWorkspace
            if outcome == .replacedWorkspace {self.editorsReady=false;self.snapshot=nil;return}
            try await self.load()
            self.notice=self.text("已从保存版本重新打开。","Reopened from the saved version.")
        }
    }
    var hasFormDrafts:Bool{!sceneNameDraft.isEmpty || !sceneTriggerDraft.isEmpty || !sceneActionDraft.isEmpty || !cabinetNoteDraft.isEmpty || !roomDraftName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || renamingRoomID != nil || !targetDraftName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
    func saveAllAndReopen(){
        guard numberInputs.commitAll(),!hasFormDrafts else{error=self.text("请先完成数值、房间或料单名称输入，修改仍保留。","Complete numeric, room or bill-name input first; edits are retained.");return}
        launch(self.text("保存修改并重新打开…","Saving changes and reopening…")){
            var saved=0
            do {
                defer{self.projectActions?.departureEnded()}
                let proceed=try await self.projectActions?.beforeDeparture(self.closingProject) ?? true
                guard proceed else{return}
                if self.projectActions != nil {try await self.checkpointProject()}
                else {for kind in BuildingComponentKind.allCases where self.isDirty(kind) {try await self.save(kind);saved += 1}}
                try await self.service.close()
                if self.closingProject {try await self.projectActions?.close?();return}
                let outcome=try await self.projectActions?.reopen() ?? .reloadWorkspace
                if outcome == .replacedWorkspace {self.editorsReady=false;self.snapshot=nil;return}
                try await self.load()
                self.notice=self.text("修改已保存并重新打开。","Changes saved and project reopened.")
            } catch {
                self.notice=self.projectActions != nil
                    ? self.text("工程尚未完整保存；工作副本和本地修改仍保留。","The project checkpoint is incomplete; the working copy and local edits are retained.")
                    : self.text("已保存 \(saved) 项；其余本地修改仍保留。","Saved \(saved) designs; remaining local edits are retained.")
                throw error
            }
        }
    }
    private func isDirty(_ kind:BuildingComponentKind)->Bool{switch kind {
        case .cabinet:editors.cabinet.isDirty;case .smartHome:editors.smartHome.isDirty;case .radio:editors.radio.isDirty
        case .lighting:editors.lighting.isDirty;case .hvac:editors.hvac.isDirty
    }}
    private func needsSave(_ kind:BuildingComponentKind)->Bool{switch kind {
        case .cabinet:editors.cabinet.needsSave;case .smartHome:editors.smartHome.needsSave;case .radio:editors.radio.needsSave
        case .lighting:editors.lighting.needsSave;case .hvac:editors.hvac.needsSave
    }}
    private func checkpointInput() throws -> BuildingWorkbenchCheckpoint {
        guard let project=snapshot?.project else{throw BuildingWorkspaceError.wrongProject}
        let cabinet=editors.cabinet.value
        return .init(projectID:project.id,recordsRevision:project.revision,selectedRoomID:selectedRoomID,
                     cabinetRecipe:cabinet.recipe,cabinetNotes:cabinet.manualNotes,
                     cabinetDimensionPresentation:cabinet.dimensionPresentation)
    }
    private func checkpointProject() async throws {
        guard let actions=projectActions else{return}
        for kind in BuildingComponentKind.allCases where needsSave(kind){try await save(kind)}
        try await actions.checkpoint(checkpointInput())
    }
    func saveProject(){
        guard projectActions != nil,editorsReady else{return};commitLightingPreview()
        guard numberInputs.commitAll(),!hasFormDrafts else{
            error=self.text("请先完成数值或表单输入，修改仍保留。","Complete numeric or form input first; edits are retained.");return
        }
        launch(self.text("保存工程…","Saving project…")){
            try await self.checkpointProject()
            self.notice=self.text("整个工程已保存。","The whole project is saved.")
        }
    }
    func applyCabinet(){
        guard let actions=projectActions,editorsReady,numberInputs.commit(prefix:"cabinet") else{return}
        launch(self.text("更新柜体模型…","Updating cabinet model…")){
            let capture=try self.checkpointInput()
            try await actions.applyCabinet(capture)
            self.notice=self.text("柜体模型已更新；保存工程以保留这次修改。","Cabinet model updated. Save the project to retain this change.")
        }
    }
    func saveDesign(_ kind:BuildingComponentKind?=nil){
        guard let kind=kind ?? activeKind,editorsReady else{return}
        guard numberInputs.commit(prefix:kind.rawValue) else{error=self.text("仍有未完成的数值输入，请先修正。","Some numeric input is incomplete. Correct it first.");return}
        launch(self.text("保存方案…","Saving design…")){try await self.save(kind);self.notice=self.text("方案已保存。","Design saved.")}
    }
    private func save(_ kind:BuildingComponentKind) async throws {
        if kind == .lighting{commitLightingPreview()}
        switch kind {
        case .cabinet:try editors.cabinet.value.recipe.validate();try await saveEditor(editors.cabinet,kind:kind)
        case .smartHome:_=try currentSmartHomePlan().encoded();try await saveEditor(editors.smartHome,kind:kind,prepare:{value in
            var plan=value;plan.roomIDs=self.snapshot?.rooms.map{$0.id.rawValue} ?? [];return plan
        })
        case .radio:try await saveEditor(editors.radio,kind:kind)
        case .lighting:try editors.lighting.value.profile?.validate();try await saveEditor(editors.lighting,kind:kind)
        case .hvac:try await saveEditor(editors.hvac,kind:kind)
        }
    }
    private func saveEditor<Value>(_ editor:BuildingDesignEditor<Value>,kind:BuildingComponentKind,prepare:(Value)->Value = {$0}) async throws {
        guard let project=snapshot?.project,let capture=editor.beginSave() else{return}
        do {
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            let bytes=try encoder.encode(prepare(capture.value))
            let result=try await service.saveComponentVersioned(kind,payload:bytes,projectID:project.id,expectedRevision:project.revision,expectedBase:editor.base)
            if editor.saved(capture,base:result.base){await accept(result.snapshot)}
        } catch {editor.failed(capture);throw error}
    }
    func exportCurrent(){
        do {
            guard let kind=activeKind else{return}
            if kind == .lighting{commitLightingPreview()}
            guard numberInputs.commit(prefix:kind.rawValue) else{error=self.text("请先完成数值输入，草稿仍保留。","Complete numeric input first; the draft is retained.");return}
            let data:Data
            switch kind {
            case .cabinet:data=try editors.cabinet.encoded();case .smartHome:data=try editors.smartHome.encoded()
            case .radio:data=try editors.radio.encoded();case .lighting:data=try editors.lighting.encoded();case .hvac:data=try editors.hvac.encoded()
            }
            exportFilename=kind.rawValue+"-design.json";exportDocument = .init(data:data)
        } catch {self.error=self.errorMessage(error)}
    }
    func exportSource(_ source:SourceRecord){
        guard let project=snapshot?.project else{return}
        launch(self.text("读取原件…","Reading original…")){
            let content=try await self.service.sourceContent(source.latestVersionID,projectID:project.id)
            self.exportFilename=content.version.originalName;self.exportDocument = .init(data:content.data)
        }
    }
    func sourcePage(reset:Bool=false,automatic:Bool=false){
        guard !busy else{return}
        if automatic,sourceAttemptKey==sourceLoadKey{return}
        sourceAttemptKey=sourceLoadKey
        launch(self.text("读取资料…","Loading files…"),clearFeedback:!automatic){try await self.loadSources(reset:reset)}
    }
    func billPage(reset:Bool=false,automatic:Bool=false){
        guard !busy,let project=snapshot?.project,let target=selectedTargetID else{return}
        if automatic,billAttemptKey==billLoadKey{return}
        billAttemptKey=billLoadKey
        let offset=reset ? 0:billNextOffset ?? 0
        let room=billRoomFilter,role=billRoleFilter
        launch(self.text("读取料单项目…","Loading bill items…"),clearFeedback:!automatic){
            let page=try await self.service.bomPage(projectID:project.id,targetID:target,role:role,roomID:room,offset:offset)
            if !reset,let revision=self.billRevision,revision != page.revision {
                self.billRevision=nil;self.billRows=[];self.billNextOffset=nil
                self.notice=self.text("料单已有更新，请刷新后继续。","The bill changed. Refresh to continue.");return
            }
            self.billRows=reset ? page.items:self.billRows+page.items;self.billNextOffset=page.nextOffset
            self.billRequiresFilter=page.requiresFilter;self.billRevision=page.revision
        }
    }
    func billFilterChanged(){billRows=[];billNextOffset=nil;billRevision=nil;billAttemptKey=nil;billPage(reset:true)}
    private func loadSources(reset:Bool) async throws {
        guard let project=snapshot?.project else{return}
        let offset=reset ? 0:sourceNextOffset ?? 0
        let page=try await service.sourcePage(projectID:project.id,roomID:sourceRoomFilter,offset:offset)
        if !reset,let sourceRevision,page.revision != sourceRevision {
            sourceRows=[];sourceNextOffset=nil;self.sourceRevision=nil
            notice=self.text("资料已有更新，请刷新后继续。","Files changed. Refresh to continue.");return
        }
        sourceRows=reset ? page.items:sourceRows+page.items
        sourceNextOffset=page.nextOffset;sourceRequiresFilter=page.requiresFilter;sourceRevision=page.revision
    }
    func chooseSource(_ id:SourceID){
        guard let project=snapshot?.project else{return}
        launch(self.text("读取资料详情…","Loading file details…")){
            self.sourceDetail=try await self.service.sourceRecord(id,projectID:project.id);self.selectedSourceID=id
        }
    }
    func search(){
        guard let project=snapshot?.project else{return};let query=sourceQuery
        launch(self.text("查找工程资料…","Searching project…")){
            let result=try await self.service.execute(.search(query:query,limit:50,offset:0),projectID:project.id)
            if case .searchHits(let hits)=result{self.searchHits=hits}
        }
    }
    func archiveData(_ data:Data,name:String,mediaType:String){
        guard let project=snapshot?.project else{return}
        launch(self.text("保存原件…","Saving original…")){
            let result=try await self.service.importDataIdentified(.init(kind:.document,title:name,originalName:name,mediaType:mediaType,data:data),projectID:project.id,expectedRevision:project.revision)
            await self.accept(result.snapshot);self.selectedSourceID=result.source.id;self.sourceDetail=result.source
            self.notice=self.text("原件已归档。","Original archived.")
        }
    }
    func importFile(_ url:URL){
        guard let project=snapshot?.project else{return};let target=selectedTargetID
        launch(self.text("导入资料…","Importing files…")){
            let data=try await Task.detached {
                let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
                let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
                let bytes=try handle.read(upToCount:64*1024*1024+1) ?? Data()
                guard bytes.count<=64*1024*1024 else{throw CocoaError(.fileReadTooLarge)}
                return bytes
            }.value
            let name=url.lastPathComponent
            if url.pathExtension.lowercased()=="csv" {
                await self.acceptDraft(try await self.service.intakeCSV(data,originalName:name,projectID:project.id,expectedRevision:project.revision,replayKey:"file/"+UUID().uuidString,targetID:target))
            } else {
                let type=UTType(filenameExtension:url.pathExtension)
                let result=try await self.service.importDataIdentified(.init(kind:type?.conforms(to:.image)==true ? .photo:.document,
                    title:name,originalName:name,mediaType:type?.preferredMIMEType ?? "application/octet-stream",data:data),projectID:project.id,expectedRevision:project.revision)
                await self.accept(result.snapshot);self.selectedSourceID=result.source.id;self.sourceDetail=result.source;self.section = .sources
                self.notice=self.text("原件已保存，可关联房间；尚未提取内容。","Original saved. Assign rooms; content extraction is pending.")
            }
        }
    }
    func currentSmartHomePlan()->SmartHomePlan {
        var plan=editors.smartHome.value;plan.roomIDs=snapshot?.rooms.map{$0.id.rawValue} ?? [];return plan
    }
    func commitLightingPreview(){
        if let output=editors.lightingPreviewOutput {
            var value=editors.lighting.value;value.output=output;editors.lighting.value=value;editors.lightingPreviewOutput=nil
        }
    }
    func importIES(_ url:URL){
        guard let project=snapshot?.project else{return}
        launch(self.text("读取配光并归档…","Reading and archiving photometry…")){
            let loaded=try await Task.detached {
                let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
                let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
                let data=try handle.read(upToCount:4*1024*1024+1) ?? Data()
                guard data.count<=4*1024*1024,let text=String(data:data,encoding:.utf8) else{throw CocoaError(.fileReadCorruptFile)}
                return (data,try IESPhotometryParser.parse(text))
            }.value
            let result=try await self.service.importDataIdentified(.init(kind:.document,title:url.lastPathComponent,
                originalName:url.lastPathComponent,mediaType:"application/vnd.ies",data:loaded.0),projectID:project.id,expectedRevision:project.revision)
            await self.accept(result.snapshot)
            var value=self.editors.lighting.value;value.profile=loaded.1;value.profileName=url.lastPathComponent
            self.editors.lighting.value=value;self.selectedSourceID=result.source.id;self.sourceDetail=result.source
            self.notice=self.text("配光已载入，原件已归档；方案参数待保存。","Photometry loaded and original archived; save the design parameters when ready.")
        }
    }
    func calculateRadio(){
        guard numberInputs.commit(prefix:"radio") else{return}
        var input=editors.radio.value;input.projectRevision=snapshot?.project.revision ?? 0
        let request=input
        launch(self.text("估算无线覆盖…","Estimating wireless coverage…")){
            let job=Task.detached{try RadioQuickEstimator.estimate(request,maximumCells:10_000,maximumWallChecks:1_000_000,cancelled:{Task.isCancelled})}
            self.cancelCalculation={job.cancel()}
            let result=try await job.value
            guard !Task.isCancelled,!self.cancelledOperations.contains(self.operationID ?? UUID()) else{return}
            self.editors.radioResult=result;self.editors.radioInput=request
        }
    }
    func calculateLighting(){
        commitLightingPreview()
        guard numberInputs.commit(prefix:"lighting") else{return}
        do {
            let input=try editors.lighting.value.request(revision:snapshot?.project.revision ?? 0)
            launch(self.text("计算直射照度…","Calculating direct illuminance…")){
                let job=Task.detached{try DirectLightingSolver.solve(input,maximumCells:10_000,maximumRayChecks:1_000_000,cancelled:{Task.isCancelled})}
                self.cancelCalculation={job.cancel()}
                let result=try await job.value
                guard !self.cancelledOperations.contains(self.operationID ?? UUID()) else{return}
                self.editors.lightingResult=result;self.editors.lightingInput=input
            }
        } catch {self.error=self.errorMessage(error)}
    }
    func calculateHVAC(){guard numberInputs.commit(prefix:"hvac") else{return};do {
        var input=editors.hvac.value;input.projectRevision=snapshot?.project.revision ?? 0
        editors.hvacResult=try HVACDesignLoadCalculator.calculate(input)
    } catch {self.error=self.errorMessage(error)}}
    func cancel(){guard let id=operationID,let cancelCalculation else{return};cancelledOperations.insert(id);cancelCalculation();notice=self.text("已取消计算，原有结果保留。","Calculation cancelled; previous results retained.")}
}

struct BuildingFileDocument:FileDocument {
    static let readableContentTypes:[UTType]=[.data,.json]
    var data:Data
    init(data:Data){self.data=data}
    init(configuration:ReadConfiguration) throws {
        guard let data=configuration.file.regularFileContents else{throw CocoaError(.fileReadCorruptFile)}
        self.data=data
    }
    func fileWrapper(configuration:WriteConfiguration) throws -> FileWrapper {FileWrapper(regularFileWithContents:data)}
}
enum BuildingCopy {
    static func text(_ zh:String,_ en:String,locale:Locale = .current)->String {
        locale.language.languageCode?.identifier=="zh" ? zh:en
    }
}

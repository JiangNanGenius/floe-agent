// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBuildingRecords
import FloeBuildingSystems
import FloeInteriorCore

public struct BuildingWorkspaceSnapshot:Sendable {
    public var project:ProjectRecord
    public var rooms:[RoomRecord]
    public var sources:[SourceRecord]
    public var targets:[BOMTarget]
    public var drafts:[BOMDraftSummary]
    public var items:[BOMItem]
    public var selectedTargetID:BOMTargetID?
    public var sourcesHaveMore:Bool
    public var draftsHaveMore:Bool
    public var itemsHaveMore:Bool
}
public struct BuildingWorkspaceDraft:Sendable {
    public var snapshot:BuildingWorkspaceSnapshot
    public var draft:BOMDraft
    public var sourceID:SourceID? = nil
}
public enum BuildingRecordsCreationPolicy:Equatable,Sendable {
    case createIfMissing
    case requireExisting
}

/// The component's project service, shared by native UI and typed assistant
/// adapters. The app must supply its existing project/task access grant before
/// calling it. Model arguments never contain a storage root or SQL command.
public actor BuildingWorkspaceService {
    private let projectDirectory:URL
    private var store:ProjectRecordsStore?
    private var permanentlyClosed=false
    private let recordsLimits:RecordsLimits
    private let creationPolicy:BuildingRecordsCreationPolicy
    public init(projectDirectory:URL,recordsLimits:RecordsLimits = .init(),creationPolicy:BuildingRecordsCreationPolicy = .createIfMissing) {
        self.projectDirectory=projectDirectory;self.recordsLimits=recordsLimits;self.creationPolicy=creationPolicy
    }

    private func records() throws -> ProjectRecordsStore {
        guard !permanentlyClosed else{throw BuildingWorkspaceError.closed}
        if let store{return store}
        let opened:ProjectRecordsStore
        do{opened=try ProjectRecordsStore.openProject(at:projectDirectory,limits:recordsLimits)}
        catch BuildingRecordsError.projectNotFound {
            guard creationPolicy == .createIfMissing else{throw BuildingRecordsError.projectNotFound}
            opened=try ProjectRecordsStore.createProject(at:projectDirectory,name:"室内工程 / Interior project",limits:recordsLimits)
        }
        store=opened;return opened
    }
    public func snapshot(targetID:BOMTargetID?=nil) throws -> BuildingWorkspaceSnapshot {
        let r=try records()
        for _ in 0..<3 {
            let project=try r.currentProject(),targets=try r.bomTargets()
            if let targetID,!targets.contains(where:{$0.id==targetID}) {throw BuildingRecordsError.bomTargetNotFound(targetID)}
            let selected=targetID ?? (targets.count==1 ? targets[0].id:nil)
            let sources=try r.sources(limit:101),drafts=try r.bomDraftSummaries(limit:101)
            let items=try selected.map{try r.bomItems(targetID:$0,limit:201)} ?? []
            let value=BuildingWorkspaceSnapshot(project:project,rooms:try r.rooms(),sources:Array(sources.prefix(100)),
                targets:targets,drafts:Array(drafts.prefix(100)),items:Array(items.prefix(200)),selectedTargetID:selected,
                sourcesHaveMore:sources.count>100,draftsHaveMore:drafts.count>100,itemsHaveMore:items.count>200)
            if try r.currentRevision()==project.revision{return value}
        }
        throw BuildingWorkspaceError.concurrentSnapshot
    }
    private func bind(_ projectID:ProjectID)throws -> ProjectRecordsStore {
        let r=try records()
        guard r.projectID==projectID else{throw BuildingWorkspaceError.wrongProject}
        return r
    }
    public func createRoom(name:String,projectID:ProjectID,expectedRevision:Int) throws -> BuildingWorkspaceSnapshot {
        try createRoomIdentified(name:name,projectID:projectID,expectedRevision:expectedRevision).snapshot
    }
    public func createRoomIdentified(name:String,projectID:ProjectID,expectedRevision:Int) throws -> BuildingWorkspaceRoomMutation {
        let r=try bind(projectID)
        let result=try r.createRoom(.init(name:name,kind:.other),expectedRevision:expectedRevision)
        return .init(snapshot:try snapshot(),room:result.value)
    }
    public func renameRoom(_ roomID:RoomID,name:String,projectID:ProjectID,expectedRevision:Int) throws -> BuildingWorkspaceSnapshot {
        let r=try bind(projectID)
        _=try r.renameRoom(roomID,to:name,expectedRevision:expectedRevision)
        return try snapshot()
    }
    public func importData(_ request:SourceImportRequest,projectID:ProjectID,expectedRevision:Int) throws -> BuildingWorkspaceSnapshot {
        try importDataIdentified(request,projectID:projectID,expectedRevision:expectedRevision).snapshot
    }
    public func importDataIdentified(_ request:SourceImportRequest,projectID:ProjectID,expectedRevision:Int) throws -> BuildingWorkspaceSourceImport {
        let result=try bind(projectID).importSource(request,expectedRevision:expectedRevision)
        return .init(snapshot:try snapshot(),source:result.value.source,version:result.value.version)
    }
    public func sourceRecord(_ id:SourceID,projectID:ProjectID) throws -> SourceRecord {try bind(projectID).source(id)}
    public func createBOMTarget(name:String,projectID:ProjectID,expectedRevision:Int) throws -> BuildingWorkspaceSnapshot {
        let result=try bind(projectID).createBOMTarget(name:name,expectedRevision:expectedRevision)
        return try snapshot(targetID:result.value.id)
    }
    public func intakeCSV(_ data:Data,originalName:String,projectID:ProjectID,expectedRevision:Int,
                          replayKey:String,targetID:BOMTargetID?=nil) throws -> BuildingWorkspaceDraft {
        let archived=try importDataIdentified(.init(kind:.table,title:originalName,originalName:originalName,
            mediaType:"text/csv",data:data,idempotencyKey:replayKey),projectID:projectID,expectedRevision:expectedRevision)
        do {return try reviewCSVSource(archived.version.id,projectID:projectID,expectedRevision:archived.snapshot.project.revision,targetID:targetID)}
        catch {throw BuildingWorkspaceIntakeError(archived:archived,underlying:error)}
    }
    public func reviewCSVSource(_ versionID:SourceVersionID,projectID:ProjectID,expectedRevision:Int,
                                targetID:BOMTargetID?=nil) throws -> BuildingWorkspaceDraft {
        let r=try bind(projectID),content=try r.sourceVersionContent(versionID)
        let draft=try r.importBOMDraft(csv:content.data,sourceVersionID:versionID,targetID:targetID,expectedRevision:expectedRevision)
        return .init(snapshot:try snapshot(targetID:targetID),draft:draft.value,sourceID:content.version.sourceID)
    }
    public func sourceContent(_ versionID:SourceVersionID,projectID:ProjectID) throws -> SourceVersionContent {
        try bind(projectID).sourceVersionContent(versionID)
    }
    public func associateSource(_ sourceID:SourceID,roomIDs:Set<RoomID>,projectID:ProjectID,expectedRevision:Int) throws -> BuildingWorkspaceSnapshot {
        _=try bind(projectID).setSourceRooms(sourceID,roomIDs:roomIDs,expectedRevision:expectedRevision)
        return try snapshot()
    }
    public func importCSV(_ data:Data,originalName:String,projectID:ProjectID,expectedRevision:Int,
                          replayKey:String) throws -> BuildingWorkspaceDraft {
        let r=try bind(projectID)
        let source=try r.importSource(.init(kind:.table,title:originalName,originalName:originalName,
            mediaType:"text/csv",data:data,idempotencyKey:replayKey),expectedRevision:expectedRevision)
        let targetID:BOMTargetID
        if let target=try r.bomTargets().first(where:{$0.name=="智能家居 / Smart home"}) {targetID=target.id}
        else {targetID=try r.createBOMTarget(name:"智能家居 / Smart home",expectedRevision:r.currentRevision()).value.id}
        let draft=try r.importBOMDraft(csv:data,sourceVersionID:source.value.version.id,
            targetID:targetID,expectedRevision:r.currentRevision())
        return .init(snapshot:try snapshot(targetID:targetID),draft:draft.value,sourceID:source.value.source.id)
    }
    public func draft(_ id:BOMDraftID,projectID:ProjectID) throws -> BOMDraft {try bind(projectID).bomDraft(id)}
    public func applyDraft(_ id:BOMDraftID,targetID:BOMTargetID,projectID:ProjectID,expectedRevision:Int,
                           selectedRowIDs:Set<BOMDraftRowID>?=nil) throws -> BuildingWorkspaceSnapshot {
        _=try bind(projectID).applyBOMDraft(id,to:targetID,selectedRowIDs:selectedRowIDs,expectedRevision:expectedRevision)
        return try snapshot(targetID:targetID)
    }
    public func saveComponent(_ kind:BuildingComponentKind,payload:Data,projectID:ProjectID,expectedRevision:Int) throws -> BuildingWorkspaceSnapshot {
        try writeComponent(kind,payload:payload,projectID:projectID,expectedRevision:expectedRevision,expectedBase:nil).snapshot
    }
    public func saveComponentVersioned(_ kind:BuildingComponentKind,payload:Data,projectID:ProjectID,
                                       expectedRevision:Int,expectedBase:BuildingComponentBase) throws -> BuildingWorkspaceComponentSave {
        try writeComponent(kind,payload:payload,projectID:projectID,expectedRevision:expectedRevision,expectedBase:expectedBase)
    }
    private func componentSource(_ kind:BuildingComponentKind,in r:ProjectRecordsStore) throws -> SourceRecord? {
        let sources=try r.sources(kind:.other,limit:500)
        if let found=sources.first(where:{$0.title==kind.title && $0.latestOriginalName==kind.filename}) {return found}
        guard sources.count<500 else{throw BuildingWorkspaceError.componentBudget}
        return nil
    }
    private func writeComponent(_ kind:BuildingComponentKind,payload:Data,projectID:ProjectID,
                                expectedRevision:Int,expectedBase:BuildingComponentBase?) throws -> BuildingWorkspaceComponentSave {
        let r=try bind(projectID)
        guard payload.count<=8*1024*1024 else{throw BuildingWorkspaceError.componentBudget}
        let source=try componentSource(kind,in:r)
        let current:BuildingComponentBase=source.map{.version($0.latestVersionID)} ?? .absent
        if let expectedBase,expectedBase != current {throw BuildingWorkspaceError.componentChanged}
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let data=try encoder.encode(BuildingComponentDocument(projectID:projectID,kind:kind,payload:payload))
        let committed:SourceVersionID
        if let source {
            committed=try r.addSourceVersion(source.id,data:data,originalName:kind.filename,mediaType:"application/json",expectedRevision:expectedRevision).value.id
        } else {
            committed=try r.importSource(.init(kind:.other,title:kind.title,originalName:kind.filename,mediaType:"application/json",data:data),expectedRevision:expectedRevision).value.version.id
        }
        return .init(snapshot:try snapshot(),base:.version(committed))
    }
    public func componentState(_ kind:BuildingComponentKind,projectID:ProjectID) throws -> BuildingComponentSnapshot {
        let r=try bind(projectID)
        guard let source=try componentSource(kind,in:r) else{return .init(payload:nil,base:.absent)}
        let content=try r.sourceVersionContent(source.latestVersionID)
        guard content.data.count<=12*1024*1024 else{throw BuildingWorkspaceError.componentBudget}
        let document=try JSONDecoder().decode(BuildingComponentDocument.self,from:content.data)
        guard document.schemaVersion==1,document.kind==kind,document.projectID==projectID,document.payload.count<=8*1024*1024 else {
            throw BuildingWorkspaceError.wrongProject
        }
        return .init(payload:document.payload,base:.version(content.version.id))
    }
    public func component(_ kind:BuildingComponentKind,projectID:ProjectID) throws -> Data? {
        try componentState(kind,projectID:projectID).payload
    }
    public func loadProject(targetID:BOMTargetID?=nil) throws -> BuildingWorkspaceLoadedProject {
        let r=try records()
        for _ in 0..<3 {
            let initial=try snapshot(targetID:targetID)
            var components:[BuildingComponentKind:BuildingComponentSnapshot]=[:]
            for kind in BuildingComponentKind.allCases {components[kind]=try componentState(kind,projectID:initial.project.id)}
            if try r.currentRevision()==initial.project.revision{return .init(snapshot:initial,components:components)}
        }
        throw BuildingWorkspaceError.concurrentSnapshot
    }
    public func sourcePage(projectID:ProjectID,roomID:RoomID?=nil,kind:SourceKind?=nil,
                           pageSize:Int=50,offset:Int=0) throws -> BuildingWorkspacePage<SourceRecord> {
        let r=try bind(projectID)
        try validatePage(pageSize:pageSize,offset:offset)
        if let roomID{_=try r.room(roomID)}
        for _ in 0..<3 {
            let revision=try r.currentRevision()
            let values=try r.sources(roomID:roomID,kind:kind,limit:pageSize+1,offset:offset)
            if try r.currentRevision()==revision{return page(values,pageSize:pageSize,offset:offset,revision:revision)}
        }
        throw BuildingWorkspaceError.concurrentSnapshot
    }
    public func bomPage(projectID:ProjectID,targetID:BOMTargetID,role:BOMRole?=nil,roomID:RoomID?=nil,
                        pageSize:Int=50,offset:Int=0) throws -> BuildingWorkspacePage<BOMItem> {
        let r=try bind(projectID)
        try validatePage(pageSize:pageSize,offset:offset)
        if let roomID{_=try r.room(roomID)}
        for _ in 0..<3 {
            let revision=try r.currentRevision()
            let values=try r.bomItems(targetID:targetID,role:role,roomID:roomID,limit:pageSize+1,offset:offset)
            if try r.currentRevision()==revision{return page(values,pageSize:pageSize,offset:offset,revision:revision)}
        }
        throw BuildingWorkspaceError.concurrentSnapshot
    }
    private func validatePage(pageSize:Int,offset:Int) throws {
        guard (1...100).contains(pageSize),(0...recordsLimits.maxSearchOffset).contains(offset) else {
            throw BuildingRecordsError.invalidValue(field:"page",reason:"use page size1...100 and a supported offset")
        }
    }
    private func page<Value:Sendable>(_ values:[Value],pageSize:Int,offset:Int,revision:Int) -> BuildingWorkspacePage<Value> {
        let hasMore=values.count>pageSize,next=offset+pageSize
        let capped=next>recordsLimits.maxSearchOffset
        return .init(items:Array(values.prefix(pageSize)),nextOffset:hasMore && !capped ? next:nil,
                     requiresFilter:hasMore && capped,revision:revision)
    }
    public func execute(_ command:BuildingWorkspaceCommand,projectID:ProjectID,expectedRevision:Int?=nil) throws -> BuildingWorkspaceCommandResult {
        let r=try bind(projectID)
        switch command {
        case .search(let query,let limit,let offset):
            return .searchHits(try r.search(query,limit:limit,offset:offset))
        case .observations(let roomID):
            return .observations(try r.observations(roomID:roomID))
        case .recordObservations(let drafts):
            guard let expectedRevision else{throw BuildingWorkspaceError.revisionRequired}
            return .recorded(try r.recordObservations(drafts,expectedRevision:expectedRevision))
        case .adoptObservation(let id):
            guard let expectedRevision else{throw BuildingWorkspaceError.revisionRequired}
            return .adopted(try r.adoptObservation(id,expectedRevision:expectedRevision))
        }
    }
    public func close() throws {try store?.close();store=nil}
    /// End the project mount. Unlike a temporary connection close used by
    /// reopen, late callbacks cannot recreate this mount's removed directory.
    public func finish() throws {permanentlyClosed=true;try store?.close();store=nil}

    /// Capture from this project's same actor-owned records connection. The
    /// destination is supplied by the project repository, never by model tool
    /// arguments. This writes a verified, quiescent snapshot for publication.
    public func captureRecordsSnapshot(to destination:URL,projectID:ProjectID,expectedRevision:Int,
                                       limits:ProjectRecordsSnapshotLimits = .init(),
                                       isCancelled:@escaping @Sendable ()->Bool = {false},
                                       progress:(@Sendable (ProjectRecordsSnapshotProgress)->Void)?=nil) throws -> ProjectRecordsSnapshot {
        try bind(projectID).captureSnapshot(to:destination,expectedRevision:expectedRevision,
                                            limits:limits,isCancelled:isCancelled,progress:progress)
    }
}

public enum BuildingWorkspaceError:Error,Equatable,Sendable {case wrongProject,concurrentSnapshot,componentBudget,revisionRequired,componentChanged,closed}

public struct BuildingWorkspaceActionDescriptor:Codable,Equatable,Sendable {
    public var name:String
    public var changesProject:Bool
    public var requiredScope:String
}
public enum BuildingWorkspaceActionCatalog {
    /// Component actions, not registration in the production App tool catalog.
    public static let actions:[BuildingWorkspaceActionDescriptor]=[
        .init(name:"building.records.search",changesProject:false,requiredScope:"bound project read"),
        .init(name:"building.records.observations.read",changesProject:false,requiredScope:"bound project read"),
        .init(name:"building.records.observations.record",changesProject:true,requiredScope:"bound project edit and current revision"),
        .init(name:"building.records.observations.adopt",changesProject:true,requiredScope:"bound project edit and current revision"),
        .init(name:"building.records.overview",changesProject:false,requiredScope:"bound project read"),
        .init(name:"building.records.sources.read",changesProject:false,requiredScope:"bound project read"),
        .init(name:"building.records.sources.import",changesProject:true,requiredScope:"bound project edit and current revision"),
        .init(name:"building.records.sources.assignRooms",changesProject:true,requiredScope:"bound project edit and current revision"),
        .init(name:"building.records.rooms.rename",changesProject:true,requiredScope:"bound project edit and current revision"),
        .init(name:"building.records.bom.importCSV",changesProject:true,requiredScope:"bound project edit and current revision"),
        .init(name:"building.records.bom.apply",changesProject:true,requiredScope:"bound project edit and current revision")
    ]
}

// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import Observation
import FloeCAD
import FloeInteriorCore
import FloeBuildingRecords
import FloeBuildingWorkspace
import FloeBuildingUI
import FloeBuildingAssets
import FloeBuildingProject
import FloeBuildingCAD

public enum BuildingEditorProjectError: Error {
    case closed, busy, missingIdentity, changedDuringCapture, projectMismatch, missingResource
    case staleBuilding
    case importSourceUnavailable
    case roomNameConflict(RoomID),missingRoomReference(RoomID)
}

extension BuildingEditorProjectError: LocalizedError {
    public var errorDescription: String? {
        let zh = Locale.current.language.languageCode?.identifier == "zh"
        func text(_ chinese: String, _ english: String) -> String { zh ? chinese : english }
        switch self {
        case .closed: return text("工程已关闭，请重新打开后继续。", "The project is closed. Reopen it to continue.")
        case .busy: return text("工程正在保存或操作，请稍后重试。", "The project is busy. Retry in a moment.")
        case .missingIdentity: return text("工程的原生文件缺少可核验身份，请恢复备份后重试。", "The project's native file has no verifiable identity. Restore a backup and retry.")
        case .changedDuringCapture: return text("文件在保存过程中发生变化，请重试。", "The files changed while being saved. Retry.")
        case .projectMismatch: return text("工程身份不一致，请关闭后重新打开。", "The project identity does not match. Close and reopen it.")
        case .missingResource: return text("工程的固定资源缺失，请从备份恢复。", "A pinned project resource is missing. Restore it from a backup.")
        case .staleBuilding: return text("建筑模型已被其他操作修改，请刷新后重试。", "The building model changed in another operation. Refresh and retry.")
        case .importSourceUnavailable: return text("无法复制所选 CAD 图形。请先保存文件，并确认它可以读取。", "The selected CAD drawing could not be copied. Save it first and confirm the file is readable.")
        case .roomNameConflict: return text("房间名称有两种修改。请在“关联房间资料”中选择采用哪一边。", "Both room names changed. Choose one in Link room records.")
        case .missingRoomReference: return text("关联的房间已不存在。请在“关联房间资料”中重新关联或解除关联。", "A linked room is missing. Relink or unlink it in Link room records.")
        }
    }
}

/// A project mount over the existing native CAD and records services. Callers
/// resolve access with their existing host services before supplying these
/// directories; model-authored arguments never choose a storage root.
@MainActor @Observable
public final class BuildingEditorProjectSession {
    public let projectDirectory: URL
    public let assetLibrary: FurnitureAssetLibrary
    /// The Space record that owns this package, when one exists. The assistant
    /// mount and tool readback use this identity; CAD-entry projects keep nil.
    public let spaceRecordID: UUID?
    var encodeDWG: (@MainActor (Data) async throws -> Data)?
    var encodeIFC: (@MainActor (Data) async throws -> Data)?
    var publishIndependentCopy: (@MainActor (BuildingProjectCopyReceipt, URL) async throws -> Void)?
    let repository: BuildingProjectRepository
    private(set) var workingCopy: BuildingProjectWorkingCopy
    private(set) var workspace: BuildingWorkspaceService
    private(set) var cad: FloeBuildingCADSession
    var state: BuildingEditorProjectState
    private(set) var published: BuildingProjectGeneration?
    private(set) var recordsRevision: Int
    var busy=false
    private(set) var closed=false
    private(set) var mountID=UUID()
    public private(set) var publicationWarning:String?
    var stateChanged=false
    private var cancellation: BuildingProjectCancellation?
    var furniture: BuildingFurnitureWorkspace?
    var deliveries:BuildingDeliveryWorkspace?
    private(set) var roomOptions:[RoomRecord]=[]
    private(set) var nativeRoomOptions:[BuildingNativeRoomOption]=[]
    private var selectedRecordsRoomID:RoomID?
    /// In-memory wall edit history. Native CAD undo covers geometry, while the
    /// paired finish snapshot keeps face edits and geometry in one undo step.
    var wallUndoRecords:[BuildingWallHistoryEntry]=[]
    var wallRedoRecords:[BuildingWallHistoryEntry]=[]
    var lastObservedWallChangeCount:Int?
    var canUndoWallChange:Bool { !wallUndoRecords.isEmpty }
    var canRedoWallChange:Bool { !wallRedoRecords.isEmpty }
    func clearWallHistory() {
        wallUndoRecords.removeAll();wallRedoRecords.removeAll();lastObservedWallChangeCount=nil
    }

    public var projectID: ProjectID {state.projectID}
    public var nativeDocument: FloeCADDocument {cad.document}
    public var hasUnpublishedChanges: Bool {
        guard !closed else{return false}
        return published == nil || cad.document.hasUnsavedChanges || cad.document.hasUnfinishedBuildingDraftingInput || stateChanged
            || cad.document.modelSHA256 != published?.identity.cadModelSHA256
            || recordsRevision != published?.identity.recordsRevision
    }

    private init(repository:BuildingProjectRepository,workingCopy:BuildingProjectWorkingCopy,
                 workspace:BuildingWorkspaceService,cad:FloeBuildingCADSession,
                 library:FurnitureAssetLibrary,state:BuildingEditorProjectState,
                 published:BuildingProjectGeneration?,recordsRevision:Int,spaceRecordID:UUID?){
        self.repository=repository;projectDirectory=repository.rootURL;self.workingCopy=workingCopy
        self.workspace=workspace;self.cad=cad;assetLibrary=library;self.state=state
        self.published=published;self.recordsRevision=recordsRevision;self.spaceRecordID=spaceRecordID
    }

    public static func create(at directory:URL,name:String,assetLibraryDirectory:URL,
                              projectID:ProjectID? = nil,spaceRecordID:UUID? = nil) async throws -> BuildingEditorProjectSession {
        try await create(at:directory,name:name,assetLibraryDirectory:assetLibraryDirectory,
                         repositoryConfiguration:.default,importingNativeDocument:nil,
                         initialProjectID:projectID,spaceRecordID:spaceRecordID)
    }

    /// Create a project whose first native document is a verified copy of an
    /// already-saved `.floecad` package. The source package is only read; the
    /// project owns the copy and every later edit, save and undo. A document
    /// still being edited must be saved by its current owner first.
    public static func create(at directory:URL,name:String,assetLibraryDirectory:URL,
                              importingNativeDocument source:URL,
                              projectID:ProjectID? = nil,spaceRecordID:UUID? = nil) async throws -> BuildingEditorProjectSession {
        try await create(at:directory,name:name,assetLibraryDirectory:assetLibraryDirectory,
                         repositoryConfiguration:.default,importingNativeDocument:source,
                         initialProjectID:projectID,spaceRecordID:spaceRecordID)
    }

    static func create(at directory:URL,name:String,assetLibraryDirectory:URL,
                       repositoryConfiguration:BuildingProjectConfiguration) async throws -> BuildingEditorProjectSession {
        try await create(at:directory,name:name,assetLibraryDirectory:assetLibraryDirectory,
                         repositoryConfiguration:repositoryConfiguration,importingNativeDocument:nil,
                         initialProjectID:nil,spaceRecordID:nil)
    }

    static func create(at directory:URL,name:String,assetLibraryDirectory:URL,
                       repositoryConfiguration:BuildingProjectConfiguration,
                       importingNativeDocument source:URL?,
                       initialProjectID:ProjectID? = nil,
                       spaceRecordID:UUID? = nil) async throws -> BuildingEditorProjectSession {
        // Refuse an unreadable source before any project directory or working
        // copy exists. The verified start identity also fences the copy below.
        let importIdentity:(revision:Int,contentSHA256:String,modelSHA256:String)?
        if let source { importIdentity = try await verifiedNativeImportSource(source) }
        else { importIdentity = nil }
        let repository=try await Task.detached{try BuildingProjectRepository.create(at:directory,configuration:repositoryConfiguration)}.value
        let copy=try await Task.detached{try repository.createWorkingCopy(initialProjectName:name,
            initialProjectID:initialProjectID)}.value
        let workspace=BuildingWorkspaceService(projectDirectory:copy.recordsDirectoryURL,creationPolicy:.requireExisting)
        var opened:FloeBuildingCADSession?
        do {
            let metadata=try await workspace.snapshot()
            let documentURL=copy.cadDirectoryURL.appendingPathComponent("Document.floecad",isDirectory:true)
            let cad:FloeBuildingCADSession
            if let source,let importIdentity {
                try await importNativeDocumentPackage(from:source,expected:importIdentity,to:documentURL)
                cad=try await FloeBuildingCADSession.open(at:documentURL)
            } else {
                cad=try await FloeBuildingCADSession.create(at:documentURL,name:name)
            }
            opened=cad
            let session=BuildingEditorProjectSession(repository:repository,workingCopy:copy,workspace:workspace,cad:cad,
                library:FurnitureAssetLibrary(rootURL:assetLibraryDirectory),state:.init(projectID:metadata.project.id),
                published:nil,recordsRevision:metadata.project.revision,spaceRecordID:spaceRecordID)
            try await session.checkpoint();session.prepareFurnitureWorkspace();return session
        }
        catch {
            // A failed first publication retains its working project and journal.
            // It never turns an existing directory into a new empty project.
            try? await workspace.finish();opened?.close();throw error
        }
    }

    /// The source must already be a saved, readable `.floecad` package with a
    /// committed model identity. An unsaved in-memory edit has no bytes here,
    /// so the current owner must save before a project imports the drawing.
    private static func verifiedNativeImportSource(_ source:URL) async throws
        -> (revision:Int,contentSHA256:String,modelSHA256:String) {
        let sourceURL=source.standardizedFileURL
        guard let values=try? sourceURL.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]),
              values.isDirectory==true,values.isSymbolicLink != true,
              let identity=await FloeCADDocument.storedIdentity(at:sourceURL),
              let model=identity.modelSHA256,!model.isEmpty else {
            throw BuildingEditorProjectError.importSourceUnavailable
        }
        return (identity.revision,identity.contentSHA256,model)
    }

    /// Copy one saved native package into the new working copy and verify the
    /// copied bytes against the identity read before the project was created.
    /// The source is never opened for writing.
    public static func importNativeDocumentPackage(from source:URL,
            expected:(revision:Int,contentSHA256:String,modelSHA256:String),to destination:URL) async throws {
        let sourceURL=source.standardizedFileURL
        guard !FileManager.default.fileExists(atPath:destination.path) else {
            throw BuildingEditorProjectError.projectMismatch
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".cad-import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try Task.checkCancellation()
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: sourceURL, to: staging)
            try validateNativePackageTree(staging)
        }.value
        guard let copied=await FloeCADDocument.storedIdentity(at:staging),
                  copied.revision==expected.revision,
                  copied.contentSHA256==expected.contentSHA256,
                  copied.modelSHA256==expected.modelSHA256 else {
            throw BuildingEditorProjectError.changedDuringCapture
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    nonisolated private static func validateNativePackageTree(_ staging: URL) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let root = try staging.resourceValues(forKeys: keys)
        guard root.isDirectory == true, root.isSymbolicLink != true else { throw BuildingEditorProjectError.importSourceUnavailable }
        var enumerationError: Error?
        guard let entries = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw BuildingEditorProjectError.importSourceUnavailable
        }
        for case let item as URL in entries {
            let type = try item.resourceValues(forKeys: keys)
            guard type.isSymbolicLink != true, type.isDirectory == true || type.isRegularFile == true else {
                throw BuildingEditorProjectError.importSourceUnavailable
            }
        }
        if let enumerationError { throw enumerationError }
    }

    public static func open(at directory:URL,assetLibraryDirectory:URL,
                            choice:BuildingEditorOpenChoice = .published,
                            spaceRecordID:UUID? = nil) async throws -> BuildingEditorProjectSession {
        let repository=try await Task.detached{try BuildingProjectRepository.open(at:directory)}.value
        // Opening a project never publishes an unfinished staging generation.
        // A working copy is restored only by an explicit caller/user choice.
        _=try await Task.detached{try repository.recover(.reportOnly)}.value
        let generation:BuildingProjectGeneration?
        var copy:BuildingProjectWorkingCopy
        switch choice {
        case .published:
            guard let current=try await Task.detached(operation:{try repository.currentGeneration()}).value else {
                throw BuildingProjectError.noPublishedGeneration
            }
            generation=current
            copy=try await Task.detached{try repository.createWorkingCopy(from:current.generationID)}.value
        case .workingCopy(let identifier):
            let candidate=try await Task.detached{try repository.openWorkingCopy(identifier)}.value
            if let base=candidate.baseGenerationID {
                generation=try await Task.detached{try repository.generation(base)}.value
            } else {generation=nil}
            if let pending=candidate.metadata.pendingCommitID {
                copy=try await Task.detached{try repository.cancelWorkingCopySave(candidate,commitID:pending)}.value
            } else {copy=candidate}
        }
        let workspace=BuildingWorkspaceService(projectDirectory:copy.recordsDirectoryURL,creationPolicy:.requireExisting)
        var opened:FloeBuildingCADSession?
        do {
            let metadata=try await workspace.snapshot()
            let file=try copy.editorStateURL.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard file.isRegularFile==true,file.isSymbolicLink != true,let bytes=file.fileSize,
                  bytes<=BuildingEditorProjectState.maximumBytes else{throw BuildingProjectStateError.budget}
            let data=try Data(contentsOf:copy.editorStateURL)
            let state=try BuildingEditorProjectState.decode(data,projectID:metadata.project.id)
            let cad=try await FloeBuildingCADSession.open(at:copy.cadDirectoryURL.appendingPathComponent("Document.floecad"))
            opened=cad
            try cad.installManifest(state.native)
            guard let stored=await FloeCADDocument.storedIdentity(at:cad.document.url),
                  let modelHash = stored.modelSHA256, !modelHash.isEmpty else{throw BuildingEditorProjectError.missingIdentity}
            if case .published=choice {
                guard let generation,stored.modelSHA256==generation.identity.cadModelSHA256,
                      stored.contentSHA256==generation.identity.cadContentSHA256,
                      stored.revision==generation.identity.cadRevision else{throw BuildingEditorProjectError.missingIdentity}
            }
            let session=BuildingEditorProjectSession(repository:repository,workingCopy:copy,workspace:workspace,cad:cad,
                library:FurnitureAssetLibrary(rootURL:assetLibraryDirectory),state:state,
                published:generation,recordsRevision:metadata.project.revision,
                spaceRecordID:spaceRecordID)
            try await session.verifyPinnedResources()
            if case .workingCopy=choice {session.stateChanged=true}
            session.prepareFurnitureWorkspace()
            return session
        } catch {try? await workspace.finish();opened?.close();throw error}
    }

    func noteRecordsRevision(projectID:ProjectID,revision:Int) {
        guard !closed,projectID==state.projectID else{return}
        recordsRevision=max(recordsRevision,revision)
    }

    func selectFurnitureRoom(_ roomID:RoomID?) {
        selectedRecordsRoomID=roomID
        guard let furniture else{return}
        let link=state.roomLinks.first{$0.recordsRoomID==roomID}
        furniture.roomID=link?.nativeRoomID
        if let model=try? cad.building(),let space=model.elements.first(where:{$0.id==link?.nativeRoomID}),
           let storey=model.storeys.first(where:{$0.id==space.storeyID}) {
            furniture.floorElevationMM=storey.elevationMM
        } else {furniture.floorElevationMM=0}
    }

    func refreshRoomOptions() async throws {
        try requireOpen()
        let mount=mountID
        let value=try await workspace.snapshot()
        guard !closed,mount==mountID else{throw BuildingEditorProjectError.closed}
        guard value.project.id==projectID else{throw BuildingEditorProjectError.projectMismatch}
        roomOptions=value.rooms;recordsRevision=value.project.revision
        if let building=try cad.building() {
            nativeRoomOptions=building.elements.filter{$0.kind == .space}.map { element in
                .init(id:element.id,name:element.name,storeyID:element.storeyID,
                    storeyName:building.storeys.first{$0.id==element.storeyID}?.name ?? "")
            }
        } else {nativeRoomOptions=[]}
        selectFurnitureRoom(selectedRecordsRoomID)
    }

    func linkRoom(recordsRoomID:RoomID,nativeRoomID:UUID) async throws {
        try requireOpen();guard !busy else{throw BuildingEditorProjectError.busy}
        busy=true;defer{busy=false}
        try await refreshRoomOptions()
        guard roomOptions.contains(where:{$0.id==recordsRoomID}),
              let native=nativeRoomOptions.first(where:{$0.id==nativeRoomID}),
              !state.roomLinks.contains(where:{$0.nativeRoomID==nativeRoomID && $0.recordsRoomID != recordsRoomID}) else {
            throw BuildingEditorProjectError.projectMismatch
        }
        state.roomLinks.removeAll{$0.recordsRoomID==recordsRoomID}
        state.roomLinks.append(.init(recordsRoomID:recordsRoomID,nativeRoomID:nativeRoomID,lastSyncedName:native.name))
        try retainNativeReferences();selectFurnitureRoom(selectedRecordsRoomID)
    }

    func unlinkRoom(_ roomID:RoomID) throws {
        try requireOpen();guard !busy else{throw BuildingEditorProjectError.busy}
        state.roomLinks.removeAll{$0.recordsRoomID==roomID}
        try retainNativeReferences();selectFurnitureRoom(selectedRecordsRoomID)
    }

    /// A deliberate initial-room action over an existing room record. Further
    /// arbitrary shapes and storeys use the native building workbench.
    func createInitialRoom(recordsRoomID:RoomID,widthMM:Double,depthMM:Double,heightMM:Double,wallThicknessMM:Double) async throws {
        try requireOpen();guard !busy,try cad.building()==nil else{throw BuildingEditorProjectError.busy}
        guard [widthMM,depthMM,heightMM,wallThicknessMM].allSatisfy({$0.isFinite && $0>0 && $0<=1_000_000}) else {
            throw BuildingProjectStateError.budget
        }
        busy=true;defer{busy=false}
        try await refreshRoomOptions()
        guard let record=roomOptions.first(where:{$0.id==recordsRoomID}) else{throw BuildingEditorProjectError.projectMismatch}
        let storeyID=UUID(),nativeRoomID=UUID()
        let spec=FloeBuildingCADSpec(id:UUID(),name:cad.document.name,storeys:[
            .init(id:storeyID,name:record.storey ?? "L1",elevationMM:0,heightMM:heightMM,rooms:[
                .init(id:nativeRoomID,name:record.name,minimum:[0,0],maximum:[widthMM,depthMM],
                    heightMM:heightMM,wallThicknessMM:wallThicknessMM)
            ])
        ])
        _=try await cad.createBuilding(spec)
        state.roomLinks.removeAll{$0.recordsRoomID==recordsRoomID}
        state.roomLinks.append(.init(recordsRoomID:recordsRoomID,nativeRoomID:nativeRoomID,lastSyncedName:record.name))
        try retainNativeReferences();try await refreshRoomOptions()
    }

    func useNativeRoomName(_ roomID:RoomID) async throws {
        try requireOpen();guard !busy else{throw BuildingEditorProjectError.busy}
        busy=true;defer{busy=false}
        try await refreshRoomOptions()
        guard let link=state.roomLinks.first(where:{$0.recordsRoomID==roomID}),
              let native=nativeRoomOptions.first(where:{$0.id==link.nativeRoomID}) else {
            throw BuildingEditorProjectError.projectMismatch
        }
        let changed=try await workspace.renameRoom(roomID,name:native.name,projectID:projectID,expectedRevision:recordsRevision)
        recordsRevision=changed.project.revision;roomOptions=changed.rooms
        if let index=state.roomLinks.firstIndex(where:{$0.recordsRoomID==roomID}) {state.roomLinks[index].lastSyncedName=native.name}
        try retainNativeReferences()
    }

    func useRecordedRoomName(_ roomID:RoomID) async throws {
        try requireOpen();guard !busy else{throw BuildingEditorProjectError.busy}
        busy=true;defer{busy=false}
        try await refreshRoomOptions()
        guard let link=state.roomLinks.first(where:{$0.recordsRoomID==roomID}),
              let record=roomOptions.first(where:{$0.id==roomID}),var model=try cad.building(),
              let index=model.elements.firstIndex(where:{$0.id==link.nativeRoomID && $0.kind == .space}) else {
            throw BuildingEditorProjectError.missingRoomReference(roomID)
        }
        let expected=cad.document.buildingChangeCount
        model.elements[index].name=record.name
        _=try await cad.applyBuilding(model,expectedChangeCount:expected)
        if let linkIndex=state.roomLinks.firstIndex(where:{$0.recordsRoomID==roomID}) {state.roomLinks[linkIndex].lastSyncedName=record.name}
        try retainNativeReferences();try await refreshRoomOptions()
    }

    /// Reconcile names by stable links and a common baseline. A one-sided
    /// rename propagates at the project checkpoint; conflicting edits preserve
    /// both values until the user chooses a side in the room-link sheet.
    private func reconcileRoomNames(from metadata:BuildingWorkspaceSnapshot) async throws -> Int {
        guard !state.roomLinks.isEmpty else{return metadata.project.revision}
        guard var model=try cad.building() else {
            throw BuildingEditorProjectError.missingRoomReference(state.roomLinks[0].recordsRoomID)
        }
        let expectedChangeCount=cad.document.buildingChangeCount
        var recordsToRename:[(RoomID,String)]=[]
        var resolved:[RoomID:String]=[:]
        var changedModel=false
        for link in state.roomLinks {
            guard let record=metadata.rooms.first(where:{$0.id==link.recordsRoomID}),
                  let index=model.elements.firstIndex(where:{$0.id==link.nativeRoomID && $0.kind == .space}) else {
                throw BuildingEditorProjectError.missingRoomReference(link.recordsRoomID)
            }
            let nativeName=model.elements[index].name
            if record.name != nativeName {
                let recordChanged=record.name != link.lastSyncedName,nativeChanged=nativeName != link.lastSyncedName
                if recordChanged && nativeChanged {throw BuildingEditorProjectError.roomNameConflict(link.recordsRoomID)}
                if recordChanged {model.elements[index].name=record.name;changedModel=true;resolved[record.id]=record.name}
                else {recordsToRename.append((record.id,nativeName));resolved[record.id]=nativeName}
            } else {resolved[record.id]=record.name}
        }
        var revision=metadata.project.revision
        for (room,name) in recordsToRename {
            let updated=try await workspace.renameRoom(room,name:name,projectID:projectID,expectedRevision:revision)
            revision=updated.project.revision;recordsRevision=revision
        }
        if changedModel {_=try await cad.applyBuilding(model,expectedChangeCount:expectedChangeCount)}
        for index in state.roomLinks.indices {
            if let name=resolved[state.roomLinks[index].recordsRoomID],state.roomLinks[index].lastSyncedName != name {
                state.roomLinks[index].lastSyncedName=name;stateChanged=true
            }
        }
        return revision
    }

    private func requireOpen() throws {if closed{throw BuildingEditorProjectError.closed}}

    func refreshBuildingReferences() throws {
        var manifest=cad.manifest
        guard let model=try cad.building() else {manifest.building=nil;try cad.installManifest(manifest);return}
        let valid=Set(model.elements.map(\.id)),previous=manifest.building?.rooms ?? []
        let rooms=model.elements.filter{$0.kind == .space}.map { element in
            let old=previous.first{$0.roomID==element.id}
            return FloeBuildingCADRoomBinding(roomID:element.id,name:element.name,storeyID:element.storeyID,
                wallIDs:old?.wallIDs.filter{valid.contains($0)} ?? [],
                openingIDs:old?.openingIDs.filter{valid.contains($0)} ?? [])
        }
        manifest.building = .init(buildingID:model.id,name:model.name,storeyIDs:model.storeys.map(\.id),
            elementIDs:model.elements.map(\.id),rooms:rooms,nativeIdentity:try cad.currentIdentity())
        try cad.installManifest(manifest)
    }

    private func verifyPinnedResources() async throws {
        let pins=state.assetPins,root=workingCopy.assetResourcesDirectoryURL,cancel=cancellation
        let task=Task.detached {
            for pin in pins {
                try Task.checkCancellation()
                if cancel?.isCancelled==true {throw CancellationError()}
                let offline=try FurnitureAssetOfflineCopy(rootURL:root.appendingPathComponent(pin.manifestSHA256,isDirectory:true))
                guard offline.pin==pin else{throw BuildingEditorProjectError.missingResource}
                _=try offline.verify()
            }
        }
        try await withTaskCancellationHandler {try await task.value} onCancel:{task.cancel()}
    }

    /// Publish a captured CAD/Records/resource generation. Subsequent edits
    /// remain in the same working mount and are not acknowledged by this save.
    public func checkpoint(expectedRecordsRevision:Int?=nil) async throws {
        try requireOpen();guard !busy,furniture?.busy != true else{throw BuildingEditorProjectError.busy}
        busy=true;publicationWarning=nil;let cancel=BuildingProjectCancellation();cancellation=cancel
        defer{busy=false;cancellation=nil}
        let nativeDraftingCheckpoint = try cad.document.beginBuildingDraftingCheckpoint()
        defer { nativeDraftingCheckpoint?.finish() }
        let commit=BuildingCommitID(),prior=workingCopy.baseGenerationID
        let repository=self.repository
        let originalCopy=workingCopy
        workingCopy=try await Task.detached{try repository.beginWorkingCopySave(originalCopy,expectedBaseGenerationID:prior,commitID:commit)}.value
        let captureRoot=workingCopy.directoryURL.appendingPathComponent(".checkpoint-"+commit.rawValue,isDirectory:true)
        var capturedState:BuildingEditorProjectState?
        var committedResult:BuildingProjectCommitResult?
        do {
            try FileManager.default.createDirectory(at:captureRoot,withIntermediateDirectories:false)
            let starting=try await workspace.snapshot()
            if let expectedRecordsRevision,starting.project.revision != expectedRecordsRevision {
                throw BuildingWorkspaceError.concurrentSnapshot
            }
            recordsRevision=max(recordsRevision,starting.project.revision)
            let capturedRecordsRevision=try await reconcileRoomNames(from:starting)
            let identity=try await cad.save()
            try refreshBuildingReferences()
            state.native=cad.manifest
            let capture=state;capturedState=capture
            let bytes=try capture.encoded()
            try bytes.write(to:workingCopy.editorStateURL,options:.atomic)
            let current=try await workspace.snapshot()
            guard current.project.id==state.projectID else{throw BuildingEditorProjectError.projectMismatch}
            if current.project.revision != capturedRecordsRevision {
                throw BuildingWorkspaceError.concurrentSnapshot
            }
            let records=try await workspace.captureRecordsSnapshot(to:captureRoot.appendingPathComponent("Records",isDirectory:true),
                projectID:current.project.id,expectedRevision:current.project.revision,isCancelled:{cancel.isCancelled})
            let sourceCAD=workingCopy.cadDirectoryURL
            let frozenCAD=captureRoot.appendingPathComponent("CAD",isDirectory:true)
            _=try await Task.detached{try BuildingProjectRepository.captureDirectorySnapshot(source:sourceCAD,to:frozenCAD,cancellation:cancel)}.value
            guard let verified=await FloeCADDocument.storedIdentity(at:frozenCAD.appendingPathComponent("Document.floecad")),
                  verified.revision==identity.revision,verified.contentSHA256==identity.contentSHA256,
                  verified.modelSHA256==identity.modelSHA256 else{throw BuildingEditorProjectError.changedDuringCapture}
            try await verifyPinnedResources()
            let sourceResources=workingCopy.assetResourcesDirectoryURL
            let frozenResources=captureRoot.appendingPathComponent("Resources",isDirectory:true)
            _=try await Task.detached{try BuildingProjectRepository.captureDirectorySnapshot(source:sourceResources,to:frozenResources,cancellation:cancel)}.value
            let stored=try BuildingStoredIdentity(cadRevision:identity.revision,cadContentSHA256:identity.contentSHA256,
                cadModelSHA256:identity.modelSHA256,recordsProjectID:records.projectID,recordsRevision:records.revision)
            let request=BuildingProjectCommitRequest(commitID:commit,expectedGeneration:prior.map{.generation($0)} ?? .emptyProject,
                identity:stored,recordsSnapshot:records,cadDirectoryURL:frozenCAD,
                assetResourcesDirectoryURL:frozenResources,editorState:bytes)
            let result=try await Task.detached{try repository.publish(request,cancellation:cancel)}.value
            committedResult=result
            // Publication is the durable success point; acknowledge the exact
            // captured identities, never later in-memory edits.
            published=result.generation
            stateChanged = state != capture
            let copy=workingCopy
            workingCopy=try await Task.detached{try repository.acknowledgeWorkingCopySave(copy,
                publishedGenerationID:result.manifest.generationID,expectedBaseGenerationID:prior,commitID:commit)}.value
            try? FileManager.default.removeItem(at:captureRoot)
        } catch {
            let copy=workingCopy
            if let reconciled=try? await Task.detached(operation:{try repository.cancelWorkingCopySave(copy,commitID:commit)}).value {
                workingCopy=reconciled
            }
            // A failure after the manifest's durable publication is a pending
            // acknowledgement, not a failed save. Use the exact returned
            // receipt, or independently read the same commit back. Never
            // report another writer's generation as this save.
            let verified=try? await Task.detached(operation:{try repository.currentGeneration()}).value
            let durable=committedResult?.generation ?? ((verified?.record.commitID==commit) ? verified:nil)
            if let durable {
                published=durable
                stateChanged=capturedState.map{state != $0} ?? true
                publicationWarning=error.localizedDescription
                return
            }
            // Preserve the input snapshot and journal for an explicit retry or
            // recovery. A new save never deletes the user's failed checkpoint.
            throw error
        }
    }

    public func cancelOwnedSave() {cancellation?.cancel()}

    func retainNativeReferences() throws {
        try requireOpen();state.native=cad.manifest;stateChanged=true
        try state.encoded().write(to:workingCopy.editorStateURL,options:.atomic)
    }

    private func prepareFurnitureWorkspace() {
        furniture=BuildingFurnitureWorkspace(library:assetLibrary,resourcesDirectory:workingCopy.assetResourcesDirectoryURL) { [weak self] url,input,pin in
            guard let self else{throw BuildingEditorProjectError.closed}
            try await self.placeFurniture(url:url,input:input,pin:pin)
        }
        deliveries=BuildingDeliveryWorkspace(directory:workingCopy.cadDirectoryURL.appendingPathComponent("Deliverables",isDirectory:true),
            generate:{[weak self] id in
                guard let self else{throw BuildingEditorProjectError.closed}
                try await self.makeSheets(cabinetID:id)
            },export:{[weak self] id in
                guard let self else{throw BuildingEditorProjectError.closed}
                return try await self.exportCabinet(cabinetID:id)
            },pages:{[weak self] in
                guard let self else{throw BuildingEditorProjectError.closed}
                return try self.projectDrawingPages()
            },exportProject:{[weak self] id in
                guard let self else{throw BuildingEditorProjectError.closed}
                return try await self.exportProject(pageID:id)
            })
    }

    private func placeFurniture(url:URL,input:FurniturePlacementInput,pin:FurnitureAssetPin) async throws {
        try requireOpen();guard !busy else{throw BuildingEditorProjectError.busy}
        busy=true;defer{busy=false}
        let directory=workingCopy.assetResourcesDirectoryURL.appendingPathComponent(pin.manifestSHA256,isDirectory:true)
        let offline=try FurnitureAssetOfflineCopy(rootURL:directory)
        guard offline.pin==pin,try offline.mainFileURL().standardizedFileURL==url.standardizedFileURL else {
            throw BuildingEditorProjectError.missingResource
        }
        if let existing=state.assetPins.first(where:{$0.assetID==pin.assetID && $0.version==pin.version}),existing != pin {
            throw BuildingEditorProjectError.missingResource
        }
        let files=Dictionary(uniqueKeysWithValues:offline.manifest.dependencies.filter{input.dependencySHA256[$0.sourceRelativePath] != nil}.map{
            ($0.sourceRelativePath,offline.rootURL.appendingPathComponent($0.relativePath))
        })
        let resources=FloeBuildingCADFurnitureResources(rootURL:offline.rootURL.appendingPathComponent("files",isDirectory:true),dependencyFiles:files)
        _=try await cad.importFurniture(assetURL:url,resources:resources,input:input,maximumSizingErrorMM:0.05)
        if !state.assetPins.contains(where:{$0.assetID==pin.assetID && $0.version==pin.version}) {state.assetPins.append(pin)}
        try retainNativeReferences()
    }

    public func applyCabinet(_ request:BuildingWorkbenchCheckpoint) async throws {
        try requireOpen();guard !busy,furniture?.busy != true else{throw BuildingEditorProjectError.busy}
        guard request.projectID==projectID else{throw BuildingEditorProjectError.projectMismatch}
        busy=true;defer{busy=false}
        let current=try await workspace.snapshot()
        guard current.project.revision==request.recordsRevision else{throw BuildingWorkspaceError.concurrentSnapshot}
        var changed=false
        if let binding=cad.manifest.cabinet(id:request.cabinetRecipe.id) {
            let built=try CabinetBuilder.build(request.cabinetRecipe)
            if built.geometryFingerprint != binding.geometryFingerprint || built.scheduleFingerprint != binding.scheduleFingerprint {
                _=try await cad.updateCabinet(recipe:request.cabinetRecipe,binding:binding,refreshSheet:false)
                changed=true
            }
        } else {_=try await cad.createCabinet(request.cabinetRecipe);changed=true}
        if let cabinet=cad.manifest.cabinet(id:request.cabinetRecipe.id),let sheet=cad.manifest.sheet(cabinetID:cabinet.cabinetID) {
            let roles=Set((sheet.detailSheets ?? []).map(\.role))
            let missingDetails = !Set(FloeBuildingCADDetailSheet.Role.allCases.map(\.rawValue)).isSubset(of:roles)
            let staleDetails=(sheet.detailSheets ?? []).contains{$0.sourceCabinetUpdatedAtIdentity?.modelSHA256 != cabinet.updatedAtIdentity.modelSHA256}
            let mixedProject=sheet.documentScope=="project" && (!cad.manifest.furniture.isEmpty || cad.manifest.cabinets.count>1)
            if changed || missingDetails || staleDetails || mixedProject || sheet.manualNotes != request.cabinetNotes {
                _=try await cad.refreshCombinationSheet(cabinet:cabinet,sheet:sheet,manualNotes:request.cabinetNotes)
            }
        }
        try retainNativeReferences()
    }

    func checkpoint(_ request:BuildingWorkbenchCheckpoint) async throws {
        guard request.projectID==projectID else{throw BuildingEditorProjectError.projectMismatch}
        // Saving the default cabinet form does not place unsolicited geometry.
        if cad.manifest.cabinet(id:request.cabinetRecipe.id) != nil {
            try await applyCabinet(request)
        }
        try await checkpoint(expectedRecordsRevision:request.recordsRevision)
    }

    public func makeSheets(cabinetID:UUID) async throws {
        try requireOpen();guard !busy,furniture?.busy != true else{throw BuildingEditorProjectError.busy}
        guard let cabinet=cad.manifest.cabinet(id:cabinetID) else{throw BuildingEditorProjectError.projectMismatch}
        busy=true;defer{busy=false}
        let payload=try await workspace.component(.cabinet,projectID:projectID)
        let design=try payload.map{try JSONDecoder().decode(BuildingCabinetDesign.self,from:$0)}
        let notes=design?.recipe.id==cabinetID ? design?.manualNotes:nil
        if let old=cad.manifest.sheet(cabinetID:cabinetID) {
            _=try await cad.refreshCombinationSheet(cabinet:cabinet,sheet:old,manualNotes:notes)
        } else {_=try await cad.makeCombinationSheet(cabinet:cabinet,options:.init(manualNotes:notes ?? []))}
        try retainNativeReferences()
    }

    public func exportCabinet(cabinetID:UUID) async throws -> (URL,FloeBuildingCADDeliveryReceipt) {
        try requireOpen();guard !busy,furniture?.busy != true else{throw BuildingEditorProjectError.busy}
        guard let cabinet=cad.manifest.cabinet(id:cabinetID),let sheet=cad.manifest.sheet(cabinetID:cabinetID) else {
            throw BuildingEditorProjectError.projectMismatch
        }
        busy=true;defer{busy=false}
        let parent=workingCopy.cadDirectoryURL.appendingPathComponent("Deliverables",isDirectory:true)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        let destination=parent.appendingPathComponent(UUID().uuidString.lowercased(),isDirectory:true)
        let receipt=try await cad.exportCabinetDetailSet(cabinet:cabinet,sheet:sheet,to:destination)
        try retainNativeReferences()
        return (destination,receipt)
    }

    public func projectDrawingPages() throws -> [BuildingEditorDrawingPageOption] {
        try requireOpen()
        let reply=CADDrawingService(document:cad.document).handle(action:"pages",args:[:])
        guard reply["ok"] as? Bool==true,let rows=reply["pages"] as? [[String:Any]] else {
            throw FloeBuildingCADError.invalidNativeState(reply["message"] as? String ?? "Drawing pages could not be read.")
        }
        return try rows.map { row in
            guard let value=row["id"] as? String,let id=UUID(uuidString:value) else{throw BuildingEditorProjectError.missingIdentity}
            return .init(id:id,title:row["name"] as? String ?? row["title"] as? String ?? "")
        }
    }

    /// Nil requests only the complete native 3D project. A selected page adds
    /// that page's vector files and editable sheet-space native 2D project;
    /// it never claims that one page represents every floor/profession.
    public func exportProject(pageID:UUID?=nil) async throws -> (URL,FloeBuildingCADDeliveryReceipt) {
        try requireOpen();guard !busy,furniture?.busy != true else{throw BuildingEditorProjectError.busy}
        busy=true;defer{busy=false}
        let parent=workingCopy.cadDirectoryURL.appendingPathComponent("Deliverables",isDirectory:true)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        let destination=parent.appendingPathComponent(UUID().uuidString.lowercased(),isDirectory:true)
        let options=FloeBuildingCADDetailExportOptions(formats:pageID==nil ? []:["pdf","svg","dxf"],
            includeNative2D:pageID != nil,includeNative3D:true,projectPageID:pageID)
        let receipt=try await cad.exportProjectDeliverables(to:destination,options:options)
        try retainNativeReferences();return (destination,receipt)
    }

    public var recordActions:[BuildingWorkspaceActionDescriptor] {BuildingWorkspaceActionCatalog.actions}
    public func createRoomRecord(name:String,expectedRevision:Int) async throws -> RoomID {
        try requireOpen();guard !busy else{throw BuildingEditorProjectError.busy}
        busy=true;defer{busy=false}
        let result=try await workspace.createRoomIdentified(name:name,projectID:projectID,expectedRevision:expectedRevision)
        recordsRevision=result.snapshot.project.revision;return result.room.id
    }
    public func importSource(_ request:SourceImportRequest,expectedRevision:Int) async throws -> BuildingWorkspaceSourceImport {
        try requireOpen();guard !busy else{throw BuildingEditorProjectError.busy}
        busy=true;defer{busy=false}
        let result=try await workspace.importDataIdentified(request,projectID:projectID,expectedRevision:expectedRevision)
        recordsRevision=result.snapshot.project.revision;return result
    }
    public func intakeCSV(_ data:Data,originalName:String,expectedRevision:Int,targetID:BOMTargetID?=nil,idempotencyKey:String?=nil) async throws -> BuildingWorkspaceDraft {
        try requireOpen();guard !busy else{throw BuildingEditorProjectError.busy}
        busy=true;defer{busy=false}
        do {
            let result=try await workspace.intakeCSV(data,originalName:originalName,projectID:projectID,
                expectedRevision:expectedRevision,replayKey:idempotencyKey ?? ("editor/"+UUID().uuidString.lowercased()),targetID:targetID)
            recordsRevision=result.snapshot.project.revision;return result
        } catch {
            if let archived=error as? BuildingWorkspaceIntakeError {recordsRevision=archived.archived.snapshot.project.revision}
            throw error
        }
    }
    public func recordsSnapshot() async throws -> BuildingWorkspaceSnapshot {
        try requireOpen()
        let mount=mountID
        let value=try await workspace.snapshot()
        guard !closed,mount==mountID else{throw BuildingEditorProjectError.closed}
        guard value.project.id==projectID else{throw BuildingEditorProjectError.projectMismatch}
        recordsRevision=max(recordsRevision,value.project.revision);return value
    }
    public func sourceContent(_ versionID:SourceVersionID) async throws -> SourceVersionContent {
        try requireOpen();let mount=mountID
        let content=try await workspace.sourceContent(versionID,projectID:projectID)
        guard !closed,mount==mountID else{throw BuildingEditorProjectError.closed}
        return content
    }

    public func assistantContext() -> BuildingEditorToolContext {
        BuildingEditorToolContext(owner:self,spaceRecordID:spaceRecordID)
    }
    public func executeRecordCommand(_ command:BuildingWorkspaceCommand,expectedRevision:Int?=nil) async throws -> BuildingWorkspaceCommandResult {
        try requireOpen();guard !busy else{throw BuildingEditorProjectError.busy}
        busy=true;defer{busy=false}
        let result=try await workspace.execute(command,projectID:projectID,expectedRevision:expectedRevision)
        let current=try await workspace.snapshot();recordsRevision=current.project.revision
        return result
    }

    func settleOwnedWorkForDeparture() async throws {
        await furniture?.waitForIdle()
        await deliveries?.waitForIdle()
        guard !busy else{throw BuildingEditorProjectError.busy}
    }

    /// Reopen swaps the mount only after a fully verified replacement exists.
    /// The feature rebuilds its child UI using mountID; old callbacks are fenced
    /// by finish(), and cannot open a discarded records directory again.
    func reopenSavedMount() async throws {
        try requireOpen();guard !busy,furniture?.busy != true else{throw BuildingEditorProjectError.busy}
        busy=true;defer{busy=false}
        clearWallHistory()
        let fresh=try await Self.open(at:projectDirectory,assetLibraryDirectory:assetLibrary.rootURL,
            spaceRecordID:spaceRecordID)
        let previous=workingCopy
        await furniture?.stop()
        await deliveries?.stop()
        var diagnostics:[String]=[]
        var recordsRetired=true
        do {try await workspace.finish()}catch {recordsRetired=false;diagnostics.append(error.localizedDescription)}
        cad.close()
        await fresh.furniture?.stop()
        await fresh.deliveries?.stop()
        workingCopy=fresh.workingCopy;workspace=fresh.workspace;cad=fresh.cad;state=fresh.state
        published=fresh.published;recordsRevision=fresh.recordsRevision;stateChanged=false
        mountID=UUID();prepareFurnitureWorkspace()
        let repository=self.repository
        if recordsRetired {
            do {try await Task.detached{try repository.discardWorkingCopy(previous)}.value}
            catch {diagnostics.append(error.localizedDescription)}
        }
        publicationWarning=diagnostics.isEmpty ? nil:diagnostics.joined(separator:"\n")
    }

    /// The host fences its existing assistant/tasks before calling this. Drain
    /// owned asset work and permanently retire Records before discarding files.
    public func close(discardWorkingCopy:Bool=true) async throws {
        try requireOpen();guard !busy else{throw BuildingEditorProjectError.busy}
        busy=true;defer{busy=false}
        clearWallHistory()
        await furniture?.stop()
        await deliveries?.stop()
        var diagnostics:[String]=[]
        var recordsRetired=true
        do {try await workspace.finish()}catch {recordsRetired=false;diagnostics.append(error.localizedDescription)}
        cad.close()
        closed=true
        if discardWorkingCopy,recordsRetired {
            let copy=workingCopy,repository=self.repository
            do {try await Task.detached{try repository.discardWorkingCopy(copy)}.value}
            catch {diagnostics.append(error.localizedDescription)}
        }
        // A retired mount is closed even when cleanup fails. Keep its working
        // files for recovery; do not report an open editor after closing CAD.
        if !diagnostics.isEmpty {publicationWarning=diagnostics.joined(separator:"\n")}
    }
}
#endif

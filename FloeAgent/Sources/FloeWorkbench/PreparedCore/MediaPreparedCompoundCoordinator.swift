// SPDX-License-Identifier: MPL-2.0
import Foundation

struct MediaPreparedCompoundCoordinatorScope:Sendable {
    let root:MediaPreparedCoordinator
    let documentID:UUID
    let clipID:UUID
}
struct MediaPreparedCompoundScopedRun:Sendable {
    var handle:MediaPreparedInstruction
    var rootHandle:MediaPreparedInstruction
    var owned:Set<MediaPreparedObjectRef>
    var finished=false
}

extension MediaPreparedCoordinator {
    func compoundProject(scope:MediaPreparedCompoundCoordinatorScope,id:UUID,reload:Bool) async throws -> MediaProject {
        guard id == scope.documentID else { throw MediaPreparedCoreError.invalidOperation("compound scope belongs to another original") }
        var project=try await scope.root.loadProjectSnapshot(id:id,reload:reload)
        let source=try MediaPreparedCompounds.source(clipID:scope.clipID,in:project.prepared!)
        project.prepared=source;project.canvas=source.canvas;project.name=source.name;project.sourceAssetID=source.sourceAssetID
        // This is a read projection, never persisted as another project. Undo
        // still calls the original root and its exact stored groups.
        project.preparedJournal?.entries.removeAll{$0.compoundScopeID != scope.clipID}
        return project
    }
    func beginCompound(scope:MediaPreparedCompoundCoordinatorScope,documentID:UUID,targets:Set<MediaPreparedObjectRef>,actor:MediaPreparedActorKind,groupID:UUID) async throws -> MediaPreparedInstruction {
        guard documentID == scope.documentID,compoundRuns[groupID] == nil else { throw MediaPreparedCoreError.invalidOperation("invalid compound instruction identity") }
        let document=try await compoundProject(scope:scope,id:documentID,reload:false).prepared!
        for ref in targets {
            guard let state=MediaPreparedEngine.currentState(of:ref,in:document) else { throw MediaPreparedCoreError.unknownObject(ref) }
            if actor == .model { switch state {
            case .layer(let layer):if layer.isLocked { throw MediaPreparedCoreError.lockedObject(ref) }
            case .track(let track):if track.isLocked { throw MediaPreparedCoreError.lockedObject(ref) }
            case .clip(let trackID,_):if document.trackGraph.track(trackID)?.isLocked != false { throw MediaPreparedCoreError.lockedObject(ref) }
            default:break
            } }
        }
        var rootTargets:Set<MediaPreparedObjectRef>=[.init(kind:.clip,id:scope.clipID)]
        rootTargets.formUnion(targets.filter{$0.kind == .asset})
        let rootHandle=try await scope.root.beginInstruction(documentID:documentID,targets:rootTargets,actor:actor,groupID:groupID,inputAssetIDs:Set(document.assets.map(\.id)))
        let handle=MediaPreparedInstruction(id:groupID,documentID:documentID,actor:actor,targets:targets,startedAt:rootHandle.startedAt)
        compoundRuns[groupID] = .init(handle:handle,rootHandle:rootHandle,owned:targets)
        return handle
    }
    func applyCompound(scope:MediaPreparedCompoundCoordinatorScope,operations:[MediaPreparedOperation],instruction:MediaPreparedInstruction) async throws -> MediaPreparedCommit {
        try Task.checkCancellation()
        guard var run=compoundRuns[instruction.id],run.handle == instruction,!run.finished else { throw MediaPreparedCoreError.unknownInstruction(instruction.id) }
        let root=try await scope.root.loadDocument(id:scope.documentID)
        var inner=try MediaPreparedCompounds.source(clipID:scope.clipID,in:root)
        let mutation=try MediaPreparedEngine.apply(operations,to:&inner)
        for change in mutation.changes where change.before != nil {
            guard run.owned.contains(change.ref) else { throw MediaPreparedCoreError.objectNotOwned(change.ref) }
        }
        guard let anchor=root.trackGraph.clip(id:scope.clipID)?.clip else { throw MediaPreparedCoreError.documentChanged }
        let operation=MediaPreparedOperation(action:.editCompound(clipID:scope.clipID,expectedRevision:anchor.revision,operations:operations))
        let commit=try await scope.root.apply([operation],instruction:run.rootHandle)
        run.owned.formUnion(mutation.changes.filter{$0.before == nil}.map(\.ref));compoundRuns[instruction.id]=run
        return .init(groupID:commit.groupID,documentID:commit.documentID,revision:commit.revision,touched:mutation.changes.map(\.ref),created:mutation.changes.filter{$0.before == nil}.map(\.ref),deleted:mutation.changes.filter{$0.after == nil}.map(\.ref),operationCount:operations.count)
    }
    func stopCompound(scope:MediaPreparedCompoundCoordinatorScope,instruction:MediaPreparedInstruction) async throws {
        guard var run=compoundRuns[instruction.id],run.handle == instruction else { throw MediaPreparedCoreError.unknownInstruction(instruction.id) }
        try await scope.root.stop(run.rootHandle);run.finished=true;compoundRuns[instruction.id]=run
        if compoundRuns.count>64 { for id in compoundRuns.keys where id != instruction.id && compoundRuns[id]?.finished == true { compoundRuns.removeValue(forKey:id) } }
    }
    func userCompound(scope:MediaPreparedCompoundCoordinatorScope,operations:[MediaPreparedOperation],documentID:UUID,groupID:UUID,actor:MediaPreparedActorKind) async throws -> MediaPreparedCommit {
        var inner=try await compoundProject(scope:scope,id:documentID,reload:false).prepared!
        let mutation=try MediaPreparedEngine.apply(operations,to:&inner)
        let targets=Set(mutation.changes.filter{$0.before != nil}.map(\.ref))
        let handle=try await beginCompound(scope:scope,documentID:documentID,targets:targets,actor:actor,groupID:groupID)
        do { let commit=try await applyCompound(scope:scope,operations:operations,instruction:handle);try await stopCompound(scope:scope,instruction:handle);return commit }
        catch { try? await stopCompound(scope:scope,instruction:handle);throw error }
    }
    func undoCompound(scope:MediaPreparedCompoundCoordinatorScope,groupID:UUID,documentID:UUID,redo:Bool) async throws -> MediaPreparedCommit {
        guard documentID == scope.documentID else { throw MediaPreparedCoreError.invalidOperation("compound scope belongs to another original") }
        let project=try await scope.root.loadProjectSnapshot(id:documentID)
        guard project.preparedJournal?.entry(groupID)?.compoundScopeID == scope.clipID else { throw MediaPreparedCoreError.unknownGroup(groupID) }
        return try await (redo ? scope.root.redoGroup(groupID,in:documentID) : scope.root.undoGroup(groupID,in:documentID))
    }
}

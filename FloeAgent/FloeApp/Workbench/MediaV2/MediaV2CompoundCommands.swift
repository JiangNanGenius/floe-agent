// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeWorkbench

struct MediaV2CompoundReceipt:Codable {
    var compoundID:UUID?
    var status:String
    var source:MediaPreparedDocument?
    var clipIDs:[UUID]
    var actions:[String]
}
struct MediaV2CompoundRoute:Identifiable {
    let id:UUID
    let name:String
    let session:MediaV2Session
}

extension MediaV2Session {
    var compoundSelectedIDs:Set<UUID> { selectedClipIDs.isEmpty ? Set(selectedClipID.map{[$0]} ?? []):selectedClipIDs }
    func toggleCompoundSelection(_ clip:MediaPreparedClip,in track:MediaPreparedTrack) {
        if selectedClipIDs.isEmpty,let selectedClipID { selectedClipIDs.insert(selectedClipID) }
        if selectedClipIDs.contains(clip.id) { selectedClipIDs.remove(clip.id) } else { selectedClipIDs.insert(clip.id) }
        selectedTrackID=track.id;selectedClipID=clip.id
    }
    func duplicateTimelineClip(_ clip:MediaPreparedClip,in track:MediaPreparedTrack) {
        if clip.compound != nil { do { submit(try MediaPreparedCompounds.duplicateOperations(clipID:clip.id,in:document).map(\.action)) } catch { diagnostic=error.localizedDescription };return }
        var next=clip;next.id=UUID();next.revision=0
        if let range=try? Self.range(start:clip.timelineRange.endSeconds,duration:clip.timelineRange.durationSeconds) { next.timelineRange=range;submit([.insertClip(trackID:track.id,clip:next,index:nil)]) }
    }
    func deleteTimelineClip(_ clip:MediaPreparedClip,in track:MediaPreparedTrack) {
        if clip.compound != nil { do { submit(try MediaPreparedCompounds.deleteOperations(clipID:clip.id,in:document).map(\.action)) } catch { diagnostic=error.localizedDescription };return }
        submit([.removeClip(trackID:track.id,clipID:clip.id,expectedRevision:clip.revision)])
    }
    func openCompound(_ clipID:UUID) async throws {
        guard compoundScopeID == nil,let compound=document.trackGraph.clip(id:clipID)?.clip.compound else { throw MediaV2CommandError.missingSelection }
        let child=try await compoundSession(clipID)
        compoundEditorRoute = .init(id:clipID,name:compound.name,session:child)
    }
    func compoundSession(_ clipID:UUID,preview:Bool=true) async throws -> MediaV2Session {
        guard compoundScopeID == nil else { throw MediaPreparedCoreError.invalidOperation(WorkbenchText.t("本轮支持一层复合片段。","One editable compound level is supported.")) }
        let scoped=try await coordinator.scopedToCompound(clipID,in:id)
        let projection=try await scoped.loadProjectSnapshot(id:id)
        let child=MediaV2Session(project:projection,root:root,store:store,coordinator:scoped)
        child.compoundScopeID=clipID;child.compoundCanonicalCoordinator=coordinator
        child.onCommit=onCommit
        if preview { child.refreshPreview() }
        return child
    }
    /// Typed scope routing is still inside the same original's admitted task.
    /// It is not a project picker, new authority or image-objectIDs alias.
    func performScopedCompoundTool(_ tool:String,input:MediaV2ToolInput,actor:MediaPreparedActorKind,authority:MediaV2ProviderAuthority?) async throws -> MediaV2ToolReceipt {
        guard let scope=input.compoundID,compoundScopeID == nil,input.expectedRevision == document.revision else { throw MediaPreparedCoreError.documentChanged }
        let child=try await compoundSession(scope,preview:false)
        var forwarded=input;forwarded.compoundID=nil
        let receipt=try await child.performTool(tool,input:forwarded,actor:actor,providerAuthority:authority)
        try await reload();return receipt
    }
    func performCompoundTool(input:MediaV2ToolInput,actor:MediaPreparedActorKind) async throws -> MediaV2ToolReceipt {
        guard project.kind == .video,compoundScopeID == nil,input.objectIDs == nil,input.points == nil,
              !saving,!processingTool,!rendering else { throw MediaV2CommandError.invalidInput }
        let action=input.property ?? "create",base=document.revision
        guard actor != .model || input.expectedRevision == base else { throw MediaPreparedCoreError.documentChanged }
        if action == "inspect" {
            let target=input.objectID.flatMap{document.trackGraph.clip(id:$0)?.clip.compound}
            let source=try target.map{try MediaPreparedCompounds.source(clipID:$0.anchorClipID,in:document)}
            let status=try target.map{try MediaPreparedCompounds.isProxyCurrent(clipID:$0.anchorClipID,in:document) ? "ready":"needsUpdate"} ?? "original"
            return .init(documentID:id,revision:base,toolID:"video.nest",groupID:nil,selectionOnly:true,compound:.init(compoundID:target?.anchorClipID,status:status,source:source,clipIDs:document.trackGraph.tracks.flatMap(\.clips).filter{$0.compound != nil}.map(\.id),actions:["create","inspect","refresh","expand","restoreMutedCopy"]))
        }
        if action == "expand" || action == "restoreMutedCopy" {
            guard let clipID=input.objectID else { throw MediaV2CommandError.missingSelection }
            let ops=try MediaPreparedCompounds.expansionOperations(clipID:clipID,mode:action == "expand" ? .replace:.restoreMutedCopy,in:document)
            let commit=try await apply(ops,expectedRevision:base,actor:actor)
            return .init(documentID:id,revision:document.revision,toolID:"video.nest",groupID:commit.groupID,selectionOnly:false,compound:.init(compoundID:action == "expand" ? nil:clipID,status:action,source:nil,clipIDs:[],actions:["inspect"]))
        }
        guard action == "create" || action == "refresh" else { throw MediaV2CommandError.invalidInput }
        let frozen=document,selection:MediaPreparedCompoundSelection?,source:MediaPreparedDocument,anchorID:UUID?
        if action == "create" {
            let ids=Set(input.clipIDs ?? (actor == .user ? Array(compoundSelectedIDs):[]))
            guard !ids.isEmpty else { throw MediaV2CommandError.missingSelection }
            let picked=try MediaPreparedCompounds.selection(clipIDs:ids,in:frozen);selection=picked;source=picked.source;anchorID=nil
        } else {
            guard let id=input.objectID,let anchor=frozen.trackGraph.clip(id:id)?.clip,anchor.compound != nil else { throw MediaV2CommandError.missingSelection }
            selection=nil;source=try MediaPreparedCompounds.source(clipID:id,in:frozen);anchorID=id
        }
        let urls=try resolvedAssets(),cancel=PreparedVideoCancellation()
        processingTool=true;stopPlayback();providerStatus=WorkbenchText.t("正在更新复合片段…","Updating compound clip…")
        let worker=Task { @MainActor in
            let proxy=try await MediaPreparedCompoundProxyJobs.shared.render(source:source,assetURLs:urls,rootURL:root,minimumDurationSeconds:anchorID.map{id in max(frozen.trackGraph.clip(id:id)?.clip.sourceRange.endSeconds ?? 0,frozen.trackGraph.tracks.flatMap(\.clips).filter{$0.compoundAudioOwnerID == id}.map{$0.sourceRange.endSeconds}.max() ?? 0)} ?? 0,cancellation:cancel,progress:{ [weak self] value in
                Task { @MainActor in guard !cancel.isCancelled,self?.processingTool == true else { return };self?.providerStatus=WorkbenchText.t("正在更新复合片段","Updating compound clip")+" · \(Int(value*100))%" }
            })
            do {
                try cancel.check();try Task.checkCancellation();try await reload()
                guard document.revision == base else { throw MediaPreparedCoreError.documentChanged }
                let operations:[MediaPreparedOperation]
                if let selection { operations=try MediaPreparedCompounds.creationOperations(selection:selection,proxy:proxy,name:input.text?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false ? input.text!:WorkbenchText.t("复合片段","Compound clip"),in:document) }
                else { operations=try MediaPreparedCompounds.replacementProxyOperations(clipID:anchorID!,proxy:proxy,in:document) }
                let commit=try await apply(operations,expectedRevision:base,actor:actor)
                let anchor=anchorID ?? document.trackGraph.tracks.flatMap(\.clips).first{$0.compound?.proxy.video.id == proxy.video.id}?.id
                selectedClipID=anchor;selectedClipIDs=Set(anchor.map{[$0]} ?? [])
                return MediaV2ToolReceipt(documentID:id,revision:document.revision,toolID:"video.nest",groupID:commit.groupID,selectionOnly:false,compound:.init(compoundID:anchor,status:"ready",source:nil,clipIDs:[],actions:["inspect","refresh","expand","restoreMutedCopy"]))
            } catch {
                // Reload the authoritative original before deleting this
                // candidate: a successful CAS followed by a late UI failure
                // must never delete bytes now referenced by the project.
                if let current=try? await coordinator.loadDocument(id:id) { try? MediaPreparedCompoundProxyRenderer.discardUncommitted(proxy,rootURL:root,retaining:current) }
                throw error
            }
        }
        cancelToolWork={cancel.cancel();worker.cancel()}
        defer { processingTool=false;providerStatus=nil;cancelToolWork=nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel:{cancel.cancel();worker.cancel()}
    }
}
#endif

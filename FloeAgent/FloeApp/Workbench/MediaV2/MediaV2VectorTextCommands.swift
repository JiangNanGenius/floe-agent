// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeWorkbench

extension MediaV2Session {
    func applyEditablePathText(_ content:ImageTextContent,to layer:MediaPreparedLayer,revision:Int64,actor:MediaPreparedActorKind) async throws -> MediaPreparedCommit {
        guard !saving,!processingTool,document.revision==revision,document.layer(layer.id)?.revision==layer.revision,!layer.isLocked,layer.contentKind == .text,let layout=content.pathLayout else { throw MediaPreparedCoreError.documentChanged }
        processingTool=true
        let worker=Task { @MainActor in
            let validation=Task.detached(priority:.userInitiated) { _ = try MediaNativeTextGeometry.outline(content,canvas:layout.referenceCanvas) }
            try await withTaskCancellationHandler { try await validation.value } onCancel: { validation.cancel() }
            try Task.checkCancellation()
            return try await apply([.init(action:.replaceLayerContent(id:layer.id,expectedRevision:layer.revision,content:.text(content)))],expectedRevision:revision,actor:actor)
        }
        cancelToolWork={worker.cancel()}
        defer { processingTool=false;cancelToolWork=nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    func performVectorTextTool(_ tool:String,input:MediaV2ToolInput,actor:MediaPreparedActorKind,fencedSelection:Bool) async throws -> MediaV2ToolReceipt {
        guard project.kind == .image,!processingTool,!saving,!canvasLayoutInProgress else { throw MediaV2CommandError.unavailable }
        let frozen=document
        let target=input.objectID ?? (fencedSelection ? selectedLayerID:nil)
        let ids=input.objectIDs ?? (actor == .user ? document.layers.filter{selectedLayerSet.contains($0.id)}.map(\.id):[])
        let sourceID:UUID?
        if tool == "image.path-text",let supplied=input.property {
            guard let value=UUID(uuidString:supplied) else { throw MediaV2CommandError.invalidInput };sourceID=value
        } else { sourceID=nil }
        processingTool=true
        let worker=Task { @MainActor in
            let preparation=Task.detached(priority:.userInitiated) {
                switch tool {
                case "image.boolean":
                    guard let operation=MediaVectorBooleanOperation(rawValue:input.property ?? "union") else { throw MediaV2CommandError.invalidInput }
                    return try MediaNativeVectorEdits.boolean(ids,in:frozen,operation:operation,primaryID:input.objectID)
                case "image.outline":
                    guard let target else { throw MediaV2CommandError.missingSelection }
                    return try MediaNativeVectorEdits.outline(target,in:frozen)
                default:
                    guard let target else { throw MediaV2CommandError.missingSelection }
                    return try MediaNativeVectorEdits.pathText(target,in:frozen,pathSourceID:sourceID,text:input.text,startOffset:input.number,normalOffset:input.secondary,isReversed:input.flag)
                }
            }
            let proposal=try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
            try Task.checkCancellation()
            guard document.revision==proposal.documentRevision else { throw MediaPreparedCoreError.documentChanged }
            let commit=try await apply(proposal.actions.map{.init(action:$0)},expectedRevision:proposal.documentRevision,actor:actor)
            selectedLayerIDs=proposal.selectedLayerID.map { Set([$0]) } ?? [];selectedLayerID=proposal.selectedLayerID
            return MediaV2ToolReceipt(documentID:id,revision:document.revision,toolID:tool,groupID:commit.groupID,selectionOnly:false)
        }
        cancelToolWork={worker.cancel()}
        defer { processingTool=false;cancelToolWork=nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
#endif

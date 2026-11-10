// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreGraphics
import FloeWorkbench

extension MediaV2Session {
    func renderedLayerImage(_ layer:MediaPreparedLayer,revision:Int64,maxEdge:Int? = nil) async throws -> CGImage {
        guard document.revision==revision,let canvas=document.canvas,!layer.isLocked,layer.parentID==nil,layer.contentKind != .group else{throw MediaV2CommandError.missingSelection}
        // A pixel edit renders one canonical layer. Merge has a separate,
        // intentionally stricter multi-layer selection contract.
        let frozen=document,assets=try resolvedAssets()
        let image=try await imageRenderer.renderPrepared(frozen,canvas:.init(width:canvas.width,height:canvas.height),resolveAsset:{assets[$0]},previewMaxEdge:maxEdge,includeLayerIDs:[layer.id],applyCanvasAdjustment:false)
        try Task.checkCancellation();guard document.revision==revision else{throw MediaPreparedCoreError.documentChanged};return image
    }
    func commitOutpaintMargins(_ image:CGImage,layout:MediaOutpaintLayout,revision:Int64,actor:MediaPreparedActorKind) async throws -> MediaPreparedCommit {
        try Task.checkCancellation()
        guard document.revision==revision,document.canvas?.width==layout.sourceWidth,document.canvas?.height==layout.sourceHeight,image.width==layout.width,image.height==layout.height else { throw MediaPreparedCoreError.documentChanged }
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Assets"),withIntermediateDirectories:true)
        let writer=MediaV2PNGStageWriter(),scope=MediaV2ImportScope(token:nil)
        defer { withExtendedLifetime(scope) {};Task { await writer.close() } }
        let source=try await writer.write(image:image,root:root)
        let (staged,asset)=try await MediaV2ImportIO.stage(source,root:root,token:nil,ephemeralSource:true)
        scope.add(staged);try scope.validate()
        let margins=MediaPreparedLayer(name:WorkbenchText.t("AI 扩展边缘", "AI expanded margins"),content:.raster(.init(source:.asset(asset.id))))
        var actions=try MediaCanvasLayout.actions(document,width:layout.width,height:layout.height,mode:.extendCanvas(anchor:layout.effectiveAnchor))
        actions += [.insertAsset(asset),.insertLayer(layer:margins,parentID:nil,index:0)]
        return try await apply(actions.map{.init(action:$0)},expectedRevision:revision,actor:actor,didCommit:{scope.didCommit()})
    }
    /// Output files and canonical object mutations form one existing CAS edit.
    /// Source assets remain available to undo/redo; fresh failed files are owned
    /// by the existing import scope and removed only before a durable commit.
    func commitRenderedImage(_ image:CGImage,replacing layer:MediaPreparedLayer,revision:Int64,actor:MediaPreparedActorKind) async throws -> MediaPreparedCommit {
        try Task.checkCancellation();guard document.revision==revision,document.layer(layer.id)?.revision==layer.revision else{throw MediaPreparedCoreError.documentChanged}
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Assets"),withIntermediateDirectories:true)
        let writer=MediaV2PNGStageWriter(),scope=MediaV2ImportScope(token:nil)
        defer{withExtendedLifetime(scope){};Task{await writer.close()}}
        // The writer actor alone owns its temporary descriptor and lifetime.
        // Only a Sendable URL crosses back for the verified importer to copy.
        let source=try await writer.write(image:image,root:root)
        let (staged,asset)=try await MediaV2ImportIO.stage(source,root:root,token:nil,ephemeralSource:true)
        scope.add(staged);try scope.validate()
        var actions:[MediaPreparedAction]=[.insertAsset(asset),.replaceLayerContent(id:layer.id,expectedRevision:layer.revision,content:.raster(.init(source:.asset(asset.id))))]
        var next=layer.revision+1
        if layer.canvasSpace != nil{actions.append(.setLayerCanvasSpace(id:layer.id,expectedRevision:next,space:nil));next+=1}
        if layer.transform != .init(){actions.append(.updateLayerTransform(id:layer.id,expectedRevision:next,transform:.init()));next+=1}
        if !layer.adjustment.isIdentity{actions.append(.updateLayerAdjustment(id:layer.id,expectedRevision:next,adjustment:.init()));next+=1}
        if layer.mask != nil{actions.append(.setLayerMask(id:layer.id,expectedRevision:next,mask:nil));next+=1}
        if layer.clip != nil{actions.append(.setLayerClip(id:layer.id,expectedRevision:next,clip:nil));next+=1}
        if layer.opacity != 1{actions.append(.updateLayerFlags(id:layer.id,expectedRevision:next,name:nil,isVisible:nil,isLocked:nil,opacity:1))}
        return try await apply(actions.map{.init(action:$0)},expectedRevision:revision,actor:actor,didCommit:{scope.didCommit()})
    }
}
/// Encoding and filesystem writes execute on this actor, never MainActor.
/// The temporary object is constructed, used and destroyed by this one owner;
/// it is not transferred into a detached task or exposed to the caller.
private actor MediaV2PNGStageWriter {
    private var temporary:MediaV2ImportTemporaryFile?
    func write(image:CGImage,root:URL) throws -> URL {
        try Task.checkCancellation()
        let file=try MediaV2ImportTemporaryFile(root:root,fileExtension:"png")
        temporary=file
        guard let png=WorkbenchPNG.encode(image) else{throw MediaV2CommandError.invalidInput}
        try Task.checkCancellation();try file.write(png)
        return file.url
    }
    func close(){temporary=nil}
}
#endif

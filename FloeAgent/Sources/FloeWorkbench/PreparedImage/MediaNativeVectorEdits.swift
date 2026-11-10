// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import FloeCore

public struct MediaNativeVectorEdit:Sendable {
    public let documentRevision:Int64
    public let actions:[MediaPreparedAction]
    public let selectedLayerID:UUID?
    public let isEmptyResult:Bool
}
/// Typed plans contain the real source object generations. The App additionally
/// admits them using documentRevision through its existing CAS/ownership path.
public enum MediaNativeVectorEdits {
    public static func boolean(_ ids:[UUID],in document:MediaPreparedDocument,operation:MediaVectorBooleanOperation,primaryID:UUID?=nil) throws -> MediaNativeVectorEdit {
        guard (2...16).contains(ids.count),Set(ids).count==ids.count else { throw MediaPreparedCoreError.invalidOperation("Select vector shapes") }
        if let primaryID,!ids.contains(primaryID) { throw MediaPreparedCoreError.invalidOperation("Choose the primary shape from the selected shapes") }
        let actual: [UUID]
        if let primaryID { actual=[primaryID]+ids.filter{$0 != primaryID} } else { actual=ids }
        let packed=try MediaNativeVectorGeometry.boolean(actual,in:document,operation:operation)
        guard let firstID=actual.first,let primary=document.layer(firstID),let position=document.layers.firstIndex(where:{$0.id==firstID}) else { throw MediaPreparedCoreError.invalidOperation("missing primary shape") }
        let outputIndex=document.layers[..<position].filter{!actual.contains($0.id)}.count
        var actions:[MediaPreparedAction]=[]
        for id in actual { guard let layer=document.layer(id) else { throw MediaPreparedCoreError.unknownObject(.init(kind:.layer,id:id)) };actions.append(.removeLayer(id:id,expectedRevision:layer.revision)) }
        var selected:UUID?
        if let packed {
            var layer=MediaPreparedLayer(name:primary.name,isVisible:primary.isVisible,opacity:primary.opacity,content:.vectorPaths(packed.path));layer.canvasSpace=packed.canvasSpace
            actions.append(.insertLayer(layer:layer,parentID:nil,index:outputIndex));selected=layer.id
        }
        return .init(documentRevision:document.revision,actions:actions,selectedLayerID:selected,isEmptyResult:packed==nil)
    }
    public static func outline(_ id:UUID,in document:MediaPreparedDocument) throws -> MediaNativeVectorEdit {
        guard let layer=document.layer(id) else { throw MediaPreparedCoreError.unknownObject(.init(kind:.layer,id:id)) }
        let packed=try MediaNativeTextGeometry.outlineLayer(layer,in:document)
        let actions=replacing(layer,content:.vectorPaths(packed.path),space:packed.canvasSpace)
        return .init(documentRevision:document.revision,actions:actions,selectedLayerID:id,isEmptyResult:false)
    }
    public static func pathText(_ id:UUID,in document:MediaPreparedDocument,pathSourceID:UUID?,text replacement:String?=nil,startOffset:Double?=nil,normalOffset:Double?=nil,isReversed:Bool?=nil) throws -> MediaNativeVectorEdit {
        guard let layer=document.layer(id),!layer.isLocked,layer.parentID==nil,layer.mask==nil,layer.clip==nil,layer.adjustment.isIdentity,case .text(var text)=layer.content,let canvas=document.canvas else { throw MediaPreparedCoreError.invalidOperation("Select an independent editable text layer") }
        var layout:MediaTextPathLayout
        if let pathSourceID {
            guard let source=document.layer(pathSourceID),let packed=try MediaNativeVectorGeometry.packed(try MediaNativeVectorGeometry.placedPath(source,in:document),canvas:canvas,fill:nil) else { throw MediaPreparedCoreError.invalidOperation("Choose a real path in this document") }
            layout = .init(path:packed.path,referenceCanvas:canvas,pathToCanvas:packed.canvasSpace.transform,sourceLayerID:source.id)
        } else if let previous=text.pathLayout { layout=previous }
        else { throw MediaPreparedCoreError.invalidOperation("Choose a path for the text") }
        if let startOffset { layout.startOffset=startOffset }
        if let normalOffset { layout.normalOffset=normalOffset }
        if let isReversed { layout.isReversed=isReversed }
        if let replacement { text.text=replacement }
        text.pathLayout=layout
        let reusedSnapshot=pathSourceID==nil
        _ = try MediaNativeTextGeometry.outline(text,canvas:reusedSnapshot ? (layer.canvasSpace?.referenceCanvas ?? canvas):canvas)
        return .init(documentRevision:document.revision,actions:replacing(layer,content:.text(text),space:reusedSnapshot ? layer.canvasSpace:nil,resetTransform:!reusedSnapshot),selectedLayerID:id,isEmptyResult:false)
    }
    private static func replacing(_ layer:MediaPreparedLayer,content:MediaPreparedLayerContent,space:MediaLayerCanvasSpace?,resetTransform:Bool=true) -> [MediaPreparedAction] {
        var result:[MediaPreparedAction]=[.replaceLayerContent(id:layer.id,expectedRevision:layer.revision,content:content)],revision=layer.revision+1
        if resetTransform,layer.transform != .init() { result.append(.updateLayerTransform(id:layer.id,expectedRevision:revision,transform:.init()));revision+=1 }
        if layer.canvasSpace != space { result.append(.setLayerCanvasSpace(id:layer.id,expectedRevision:revision,space:space)) }
        return result
    }
}

// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
import CoreImage
@testable import FloeWorkbench

@Suite("M11 M12 native canvas layout transactions",.serialized)
struct MediaCanvasLayoutTests {
    private struct Fixture {
        let root:URL
        let store:MediaProjectStore
        let coordinator:MediaPreparedCoordinator
        let id:UUID
        let source:URL
        let groupID:UUID
    }
    private func fixture(singleRaster:Bool=false) async throws -> Fixture {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("canvas-layout-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var bytes=[UInt8](repeating:255,count:64*48*4)
        for y in 0..<48 { for x in 0..<64 { let i=(y*64+x)*4;bytes[i]=x<32 ? 240:20;bytes[i+1]=y<24 ? 180:40;bytes[i+2]=x<32 ? 20:240 } }
        let provider=try #require(CGDataProvider(data:Data(bytes) as CFData)),space=try #require(CGColorSpace(name:CGColorSpace.sRGB))
        let image=try #require(CGImage(width:64,height:48,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:256,space:space,bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let source=root.appendingPathComponent("source.png");try #require(WorkbenchPNG.encode(image)).write(to:source)
        let project=MediaProject(kind:.image,name:"Canvas",canvas:.init(width:64,height:48)),store=MediaProjectStore(directory:root.appendingPathComponent("Projects")),coordinator=MediaPreparedCoordinator(store:store)
        try await store.save(project);_ = try await coordinator.upgradeDocument(id:project.id)
        let asset=MediaAssetReference(kind:.image,relativePath:"source.png",originalName:"Source")
        if singleRaster {
            let photo=MediaPreparedLayer(name:"Photo",content:.raster(.init(source:.asset(asset.id))))
            _ = try await coordinator.applyUserOperations([.init(action:.insertAsset(asset)),.init(action:.insertLayer(layer:photo,parentID:nil,index:nil))],to:project.id)
            return .init(root:root,store:store,coordinator:coordinator,id:project.id,source:source,groupID:photo.id)
        }
        let group=MediaPreparedLayer(name:"Group",transform:.init(centerX:0.55,centerY:0.45,scale:0.65,rotationDegrees:17),content:.group(.init(isIsolated:true)))
        let mask=ImageSelection(shapes:[.init(kind:.ellipse,points:[.init(x:0.1,y:0.1),.init(x:0.9,y:0.9)])])
        let child=MediaPreparedLayer(name:"Masked child",content:.raster(.init(source:.asset(asset.id))),mask:.init(vector:mask))
        let photo=MediaPreparedLayer(name:"Photo",transform:.init(centerX:0.25,centerY:0.7,scale:0.45,rotationDegrees:-11),content:.raster(.init(source:.asset(asset.id))))
        let text=MediaPreparedLayer(name:"Text",transform:.init(centerX:0.65,centerY:0.8,scale:1),content:.text(.init(text:"AB",fontSize:9,colorHex:"#FFFFFF")))
        _ = try await coordinator.applyUserOperations([.init(action:.insertAsset(asset)),.init(action:.insertLayer(layer:group,parentID:nil,index:nil)),.init(action:.insertLayer(layer:child,parentID:group.id,index:nil)),.init(action:.insertLayer(layer:photo,parentID:nil,index:nil)),.init(action:.insertLayer(layer:text,parentID:nil,index:nil))],to:project.id)
        return .init(root:root,store:store,coordinator:coordinator,id:project.id,source:source,groupID:group.id)
    }
    private func render(_ f:Fixture) async throws -> CGImage {
        let project=try #require(try await f.store.loadProject(id:f.id)),canvas=try #require(project.canvas),source=f.source
        return try await WorkbenchImageRenderer().render(project:project,canvas:.init(width:canvas.width,height:canvas.height),resolveAsset:{_ in source})
    }
    private func record(_ name:String,_ image:CGImage) throws {
        guard let path=ProcessInfo.processInfo.environment["FLOE_MEDIA_EXECUTION_EVIDENCE_DIR"] else { return }
        let root=URL(fileURLWithPath:path,isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try #require(WorkbenchPNG.encode(image)).write(to:root.appendingPathComponent(name),options:.atomic)
    }
    @Test func canvasExpansionKeepsActualSubtreesMasksTextAndOriginalPixelLocations() async throws {
        let f=try await fixture();defer { try? FileManager.default.removeItem(at:f.root) }
        let source=try Data(contentsOf:f.source),before=try await render(f),old=try await f.coordinator.loadDocument(id:f.id)
        let actions=try MediaCanvasLayout.actions(old,width:128,height:96,mode:.extendCanvas(anchor:.init(x:0,y:0)))
        _ = try await f.coordinator.applyUserOperations(actions.map{.init(action:$0)},to:f.id)
        let after=try await render(f),current=try await f.coordinator.loadDocument(id:f.id)
        #expect(after.width==128 && after.height==96 && current.layers.map(\.id)==old.layers.map(\.id))
        #expect(current.layers.map(\.content)==old.layers.map(\.content) && current.layers.map(\.mask)==old.layers.map(\.mask))
        let expected=CIImage(cgImage:before).transformed(by:.init(translationX:0,y:48))
        let oracle=try #require(CIContext().createCGImage(expected,from:.init(x:0,y:0,width:128,height:96)))
        let a=try MediaNativeSelection.rgba(after).pixels,b=try MediaNativeSelection.rgba(oracle).pixels
        #expect(zip(a,b).allSatisfy{abs(Int($0)-Int($1))<=2})
        #expect(try Data(contentsOf:f.source)==source)
        try record("M12-original.png",before);try record("M12-top-left-expanded.png",after)
    }
    @Test func nonSquareImageResizeScalesGeometryInsteadOfExpandingMargins() async throws {
        let f=try await fixture(singleRaster:true);defer { try? FileManager.default.removeItem(at:f.root) }
        let before=try await render(f),document=try await f.coordinator.loadDocument(id:f.id)
        _ = try await f.coordinator.applyUserOperations(MediaCanvasLayout.actions(document,width:128,height:72,mode:.scaleImage).map{.init(action:$0)},to:f.id)
        let resized=try await render(f)
        let expected=CIImage(cgImage:before).transformed(by:.init(scaleX:2,y:1.5)),oracle=try #require(CIContext().createCGImage(expected,from:.init(x:0,y:0,width:128,height:72)))
        let a=try MediaNativeSelection.rgba(resized).pixels,b=try MediaNativeSelection.rgba(oracle).pixels
        let mean=Double(zip(a,b).reduce(0){$0+abs(Int($1.0)-Int($1.1))})/Double(a.count)
        #expect(mean<1.5)
        let saved=try #require(try await f.store.loadProject(id:f.id))
        #expect(saved.canvas?.width==128 && saved.prepared?.canvas?.height==72)
        #expect(saved.prepared?.layers.allSatisfy{$0.contentKind != .raster || $0.name == "Photo" || $0.name == "Masked child"} == true)
        try record("M11-nonsquare-resize.png",resized)
    }
    @Test func compoundNonSquareResizeRetainsEditableGraphAndActualScaledVisualBounds() async throws {
        let f=try await fixture();defer { try? FileManager.default.removeItem(at:f.root) }
        func bounds(_ image:CGImage) throws -> [Int] {
            let pixels=try MediaNativeSelection.rgba(image).pixels
            let visible=(0..<image.width*image.height).filter{pixels[$0*4+3]>127}
            return [visible.map{$0%image.width}.min()!,visible.map{$0/image.width}.min()!,visible.map{$0%image.width}.max()!,visible.map{$0/image.width}.max()!]
        }
        let before=try await render(f),old=try await f.coordinator.loadDocument(id:f.id),source=try Data(contentsOf:f.source)
        _ = try await f.coordinator.applyUserOperations(MediaCanvasLayout.actions(old,width:128,height:72,mode:.scaleImage).map{.init(action:$0)},to:f.id)
        let image=try await render(f),after=try await f.coordinator.loadDocument(id:f.id),a=try bounds(before),b=try bounds(image)
        #expect(abs(b[0]-a[0]*2)<=2 && abs(b[2]-a[2]*2)<=2)
        #expect(abs(Double(b[1])-Double(a[1])*1.5)<=2 && abs(Double(b[3])-Double(a[3])*1.5)<=2)
        #expect(after.layers.map(\.content)==old.layers.map(\.content) && after.layers.map(\.parentID)==old.layers.map(\.parentID) && after.layers.map(\.mask)==old.layers.map(\.mask))
        #expect(try Data(contentsOf:f.source)==source)
        try record("M11-editable-compound-resize.png",image)
    }
    @Test func layoutHistoryKeepsLocksSurvivesReopenAndRejectsStaleCanvasGenerations() async throws {
        let f=try await fixture();defer { try? FileManager.default.removeItem(at:f.root) }
        let first=try await f.coordinator.loadDocument(id:f.id),group=try #require(first.layer(f.groupID))
        _ = try await f.coordinator.applyUserOperations([.init(action:.updateLayerFlags(id:group.id,expectedRevision:group.revision,name:nil,isVisible:nil,isLocked:true,opacity:nil))],to:f.id)
        let original=try await f.coordinator.loadDocument(id:f.id)
        let edit=try await f.coordinator.applyUserOperations(MediaCanvasLayout.actions(original,width:96,height:80,mode:.extendCanvas(anchor:.init(x:0.5,y:0.5))).map{.init(action:$0)},to:f.id)
        let reopened=try await MediaPreparedCoordinator(store:MediaProjectStore(directory:URL(fileURLWithPath:f.store.storeRootPath,isDirectory:true))).loadDocument(id:f.id)
        #expect(reopened.layer(group.id)?.isLocked==true && reopened.canvasRevision==1)
        _ = try await f.coordinator.undoGroup(edit.groupID,in:f.id)
        let undone=try await f.coordinator.loadDocument(id:f.id)
        #expect(undone.canvas==original.canvas && undone.layers.map(\.canvasSpace)==original.layers.map(\.canvasSpace) && undone.layer(group.id)?.isLocked==true)
        _ = try await f.coordinator.redoGroup(edit.groupID,in:f.id)
        let redone=try await f.coordinator.loadDocument(id:f.id)
        #expect(redone.canvas==reopened.canvas && (redone.canvasRevision ?? 0)>1)
        let bytes=try Data(contentsOf:f.store.projectURL(id:f.id))
        do { _ = try await f.coordinator.applyUserOperations([.init(action:.layoutCanvas(expectedRevision:0,canvas:.init(width:70,height:50),mode:.scaleImage))],to:f.id);Issue.record("Stale layout accepted") }
        catch MediaPreparedCoreError.staleObject(let ref) { #expect(ref.kind == .canvas) }
        #expect(try Data(contentsOf:f.store.projectURL(id:f.id))==bytes)
        var unjournaled=try #require(try await f.store.loadProject(id:f.id))
        unjournaled.canvas?.width+=1
        var changed=try #require(unjournaled.prepared)
        changed.canvas=unjournaled.canvas;changed.canvasRevision=(changed.canvasRevision ?? 0)+1
        unjournaled.revision+=1;changed.revision=unjournaled.revision;unjournaled.prepared=changed
        do { _ = try await f.store.save(unjournaled,expectedRevision:unjournaled.revision-1);Issue.record("Unjournaled mirrored canvas write accepted") } catch {}
        #expect(try Data(contentsOf:f.store.projectURL(id:f.id))==bytes)
    }
    @Test func oldOptionalMetadataDecodesAndModelCannotUseLayoutToUnlockContent() async throws {
        let f=try await fixture();defer { try? FileManager.default.removeItem(at:f.root) }
        let original=try await f.coordinator.loadDocument(id:f.id),data=try JSONEncoder().encode(original),decoded=try JSONDecoder().decode(MediaPreparedDocument.self,from:data)
        #expect(decoded.canvasRevision==nil && decoded.layers.allSatisfy{$0.canvasSpace==nil})
        let layer=try #require(original.layer(f.groupID))
        _ = try await f.coordinator.applyUserOperations([.init(action:.updateLayerFlags(id:layer.id,expectedRevision:layer.revision,name:nil,isVisible:nil,isLocked:true,opacity:nil))],to:f.id)
        let locked=try await f.coordinator.loadDocument(id:f.id)
        do {
            var operations=try MediaCanvasLayout.actions(locked,width:80,height:60,mode:.scaleImage).map{MediaPreparedOperation(action:$0)}
            operations.append(.init(action:.updateLayerFlags(id:layer.id,expectedRevision:locked.layer(layer.id)!.revision,name:nil,isVisible:nil,isLocked:false,opacity:nil)))
            _ = try await f.coordinator.applyUserOperations(operations,to:f.id,actor:.model);Issue.record("Model unlocked a locked layer")
        } catch MediaPreparedCoreError.lockedObject(let ref) { #expect(ref.kind == .layer && ref.id == layer.id) }
        #expect(try await f.coordinator.loadDocument(id:f.id)==locked)
    }
    @Test func currentCanvasSelectionAndSamplePointsKeepCoverageAfterExpansionOrResize() throws {
        let old=MediaCanvas(width:64,height:48),next=MediaCanvas(width:128,height:96)
        let alpha=Data((0..<64*48).map { index -> UInt8 in let x=index%64,y=index/64;return x>=10 && x<30 && y>=6 && y<24 && !(x>=15 && x<20 && y>=10 && y<15) ? 255:0 })
        let selected=ImageSelection(bitmap:try .init(width:64,height:48,alpha:alpha))
        let rebased=try #require(try MediaCanvasLayout.remapSelection(selected,from:old,to:next,mode:.extendCanvas(anchor:.init(x:0.5,y:0.5))))
        let expanded=try #require(rebased.bitmap)
        #expect(expanded.alpha[32*128+44]>240 && expanded.alpha[36*128+49]<10 && expanded.alpha[0]==0)
        let resized=try #require(try MediaCanvasLayout.remapSelection(selected,from:old,to:.init(width:128,height:72),mode:.scaleImage)?.bitmap)
        #expect(resized.alpha[12*128+24]>220 && resized.alpha[18*128+34]<10)
        let point=try #require(try MediaCanvasLayout.remapPoint(.init(x:0.25,y:0.25),from:old,to:next,mode:.extendCanvas(anchor:.init(x:0.5,y:0.5))))
        #expect(point.x==0.375 && point.y==0.375)
        #expect(try MediaCanvasLayout.remapPoint(.init(x:1,y:1),from:old,to:.init(width:16,height:12),mode:.extendCanvas(anchor:.init(x:0,y:0)))==nil)
    }
    @Test func displayedChildDragRemainsTheRequestedMovementThroughRotatedGroupAndCanvasMapping() async throws {
        let f=try await fixture();defer { try? FileManager.default.removeItem(at:f.root) }
        let first=try await f.coordinator.loadDocument(id:f.id)
        _ = try await f.coordinator.applyUserOperations(MediaCanvasLayout.actions(first,width:128,height:96,mode:.extendCanvas(anchor:.init(x:0,y:0))).map{.init(action:$0)},to:f.id)
        func groupImage() async throws -> CGImage {
            let doc=try await f.coordinator.loadDocument(id:f.id),source=f.source
            return try await WorkbenchImageRenderer().renderPrepared(doc,canvas:.init(width:128,height:96),resolveAsset:{_ in source},includeLayerIDs:[f.groupID])
        }
        func centroid(_ image:CGImage) throws -> (Double,Double) {
            let pixels=try MediaNativeSelection.rgba(image).pixels;var weight=0.0,x=0.0,y=0.0
            for index in 0..<image.width*image.height { let a=Double(pixels[index*4+3]);weight+=a;x+=a*Double(index%image.width);y+=a*Double(index/image.width) }
            return (x/weight,y/weight)
        }
        let before=try await groupImage(),document=try await f.coordinator.loadDocument(id:f.id),child=try #require(document.layers.first{$0.parentID == f.groupID})
        let space=try MediaCanvasLayout.movedSpace(child,in:document,delta:.init(x:0.05,y:0.03))
        _ = try await f.coordinator.applyUserOperations([.init(action:.setLayerCanvasSpace(id:child.id,expectedRevision:child.revision,space:space))],to:f.id)
        let after=try await groupImage(),a=try centroid(before),b=try centroid(after)
        #expect(abs((b.0-a.0)-6.4)<0.5 && abs((b.1-a.1)-2.88)<0.5)
        try record("M12-transformed-child-drag.png",after)
    }

    @Test func alignmentUsesTheDisplayedCanvasAfterAnAnchoredExpansion() async throws {
        let f=try await fixture(singleRaster:true);defer { try? FileManager.default.removeItem(at:f.root) }
        let old=try await f.coordinator.loadDocument(id:f.id)
        _ = try await f.coordinator.applyUserOperations(MediaCanvasLayout.actions(old,width:128,height:96,mode:.extendCanvas(anchor:.init(x:0,y:0))).map{.init(action:$0)},to:f.id)
        let expanded=try await f.coordinator.loadDocument(id:f.id),photo=try #require(expanded.layers.first)
        let space=try MediaCanvasLayout.alignedSpace(photo,in:expanded,axis:"center")
        _ = try await f.coordinator.applyUserOperations([.init(action:.setLayerCanvasSpace(id:photo.id,expectedRevision:photo.revision,space:space))],to:f.id)
        let image=try await render(f),pixels=try MediaNativeSelection.rgba(image).pixels
        var total=0.0,x=0.0,y=0.0
        for index in 0..<128*96 { let a=Double(pixels[index*4+3]);total+=a;x+=a*(Double(index%128)+0.5);y+=a*(Double(index/128)+0.5) }
        #expect(abs(x/total-64)<0.25 && abs(y/total-48)<0.25)
        try record("M12-centered-after-expand.png",image)
    }

}

// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
@testable import FloeWorkbench

private struct FeatherFixture {
    let root: URL, source: URL, id: UUID, layer: UUID
    let store: MediaProjectStore, coordinator: MediaPreparedCoordinator
    init(masked: Bool, transform: ImageLayerTransform = .init()) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        source = root.appendingPathComponent("subject.png")
        var raw = [UInt8](repeating:0,count:80*64*4)
        for y in 0..<64 { for x in 0..<80 where masked || x < 40 {
            let i = (y*80+x)*4
            raw[i+(x < 25 ? 1 : 0)] = 255; raw[i+3] = 255
        }}
        let provider = try #require(CGDataProvider(data:Data(raw) as CFData))
        let color = try #require(CGColorSpace(name:CGColorSpace.sRGB))
        let image = try #require(CGImage(width:80,height:64,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:320,
            space:color,bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,
            decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        try #require(WorkbenchPNG.encode(image)).write(to:source)
        let project = MediaProject(kind:.image,name:"Feather",canvas:.init(width:80,height:64))
        id = project.id; store = MediaProjectStore(directory:root.appendingPathComponent("Projects"))
        coordinator = MediaPreparedCoordinator(store:store)
        try await store.save(project); _ = try await coordinator.upgradeDocument(id:id)
        let asset = MediaAssetReference(kind:.image,relativePath:"subject.png",originalName:"Subject")
        let selection = ImageSelection(shapes:[.init(kind:.rectangle,operation:.replace,points:[.init(x:0,y:0),.init(x:0.5,y:1)])])
        let item = MediaPreparedLayer(name:"Subject",transform:transform,content:.raster(.init(source:.asset(asset.id))),
                                     mask:masked ? .init(vector:selection) : nil)
        layer = item.id
        _ = try await coordinator.applyUserOperations([.init(action:.insertAsset(asset)),
            .init(action:.insertLayer(layer:item,parentID:nil,index:nil))],to:id)
    }
    func pixels(_ doc: MediaPreparedDocument) async throws -> [UInt8] {
        let url = source
        let image = try await WorkbenchImageRenderer().renderPrepared(doc,canvas:.init(width:80,height:64),resolveAsset:{ _ in url })
        var raw = [UInt8](repeating:0,count:80*64*4)
        try raw.withUnsafeMutableBytes { bytes in
            let ctx = try #require(CGContext(data:bytes.baseAddress,width:80,height:64,bitsPerComponent:8,bytesPerRow:320,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image,in:CGRect(x:0,y:0,width:80,height:64))
        }
        return raw
    }
    func slice(_ bytes:[UInt8],_ x:Int,_ y:Int) -> [UInt8] { Array(bytes[(y*80+x)*4..<(y*80+x+1)*4]) }
}

@Test func localFeatherChangesOnlyTouchedAlphaOrMaskAndRoundTripsOneUndo() async throws {
    for masked in [false,true] {
        let f = try await FeatherFixture(masked:masked); defer { try? FileManager.default.removeItem(at:f.root) }
        let original = try await f.coordinator.loadDocument(id:f.id), layer = try #require(original.layer(f.layer))
        let before = try await f.pixels(original)
        let path: [ImageFreehandStroke.Point] = [.init(x:0.30,y:0.5),.init(x:0.64,y:0.5)]
        let mask = try MediaNativeFeatherBrush.appending(to:layer,document:original,points:path,diameter:18,strength:0.8,selection:nil)
        #expect(mask.featherStrokes?.last?.editsMask == masked)
        #expect(mask.vector == layer.mask?.vector)
        var draft = original
        draft.layers[try #require(draft.layers.firstIndex { $0.id == f.layer })].mask = mask
        let preview = try await f.pixels(draft)
        let first = f.slice(preview,39,32), second = f.slice(preview,40,32)
        #expect(first[3] > 0 && first[3] < 255)
        #expect(second[3] > 0 && second[3] < 255)
        #expect(first[0] == first[3] && first[1] == 0)
        for (x,y) in [(15,32),(24,32),(25,32),(39,11),(40,11),(74,41)] {
            #expect(f.slice(preview,x,y) == f.slice(before,x,y))
        }
        let commit = try await f.coordinator.applyUserOperations([.init(action:.setLayerMask(id:layer.id,expectedRevision:layer.revision,mask:mask))],to:f.id)
        let saved = try await MediaPreparedCoordinator(store:MediaProjectStore(directory:URL(fileURLWithPath:f.store.storeRootPath))).loadDocument(id:f.id)
        #expect(saved.layer(f.layer)?.content == layer.content)
        #expect(try await f.pixels(saved) == preview)
        _ = try await f.coordinator.undoGroup(commit.groupID,in:f.id)
        #expect(try await f.pixels(f.coordinator.loadDocument(id:f.id)) == before)
        _ = try await f.coordinator.redoGroup(commit.groupID,in:f.id)
        #expect(try await f.pixels(f.coordinator.loadDocument(id:f.id)) == preview)
    }
}

@Test func localFeatherFollowsLayerPlacementAndSelectionFence() async throws {
    let f = try await FeatherFixture(masked:true,transform:.init(centerX:0.65,centerY:0.5))
    defer { try? FileManager.default.removeItem(at:f.root) }
    var doc = try await f.coordinator.loadDocument(id:f.id)
    let before = try await f.pixels(doc), i = try #require(doc.layers.firstIndex { $0.id == f.layer })
    let selection = ImageSelection(shapes:[.init(kind:.rectangle,operation:.replace,points:[.init(x:0.65,y:0),.init(x:1,y:1)])])
    doc.layers[i].mask = try MediaNativeFeatherBrush.appending(to:doc.layers[i],document:doc,
        points:[.init(x:0.65,y:0.5)],diameter:20,strength:1,selection:selection)
    let after = try await f.pixels(doc)
    #expect(f.slice(after,50,32) == f.slice(before,50,32))
    #expect(f.slice(after,52,32)[3] > f.slice(before,52,32)[3])
    #expect(f.slice(after,52,8) == f.slice(before,52,8))
    doc.layers[i].isLocked = true
    #expect(throws:MediaPreparedCoreError.self) { try MediaNativeFeatherBrush.appending(to:doc.layers[i],document:doc,points:[.init(x:0.3,y:0.1)],diameter:10,strength:1,selection:nil) }
}

@Test func featherStrengthAndDiameterChangeTheCoveredEdgeWithoutEnablingADisabledMask() async throws {
    let f = try await FeatherFixture(masked:false)
    defer { try? FileManager.default.removeItem(at:f.root) }
    var doc = try await f.coordinator.loadDocument(id:f.id)
    let index = try #require(doc.layers.firstIndex { $0.id == f.layer })
    let disabled = MediaPreparedLayerMask(vector:ImageSelection(shapes:[]),isEnabled:false)
    doc.layers[index].mask = disabled
    let baseline = try await f.pixels(doc), layer = doc.layers[index]
    func applied(_ diameter: Double,_ strength:Double) async throws -> [UInt8] {
        var draft = doc
        draft.layers[index].mask = try MediaNativeFeatherBrush.appending(to:layer,document:doc,points:[.init(x:0.5,y:0.5)],
            diameter:diameter,strength:strength,selection:nil)
        #expect(draft.layers[index].mask?.isEnabled == false)
        #expect(draft.layers[index].mask?.featherStrokes?.first?.editsMask == false)
        return try await f.pixels(draft)
    }
    let weak = try await applied(18,0.25), strong = try await applied(18,1), thin = try await applied(4,1)
    #expect(f.slice(strong,40,32)[3] > f.slice(weak,40,32)[3])
    #expect(f.slice(weak,40,32)[3] > f.slice(baseline,40,32)[3])
    #expect(f.slice(thin,40,37) == f.slice(baseline,40,37))
    #expect(f.slice(strong,40,37)[3] > f.slice(baseline,40,37)[3])
}

@Test func imageCanvasColumnsPersistAndPencilNavigationKeepsFingerAndPointerOwnership() throws {
    let name = "ImageRail-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName:name))
    defer { defaults.removePersistentDomain(forName:name) }
    let key = MediaImageCanvasControls.columnsKey
    #expect(MediaImageCanvasControls.columns(defaults.object(forKey:key) as? Int) == 1)
    defaults.set(2,forKey:key)
    #expect(MediaImageCanvasControls.columns(UserDefaults(suiteName:name)?.integer(forKey:key)) == 2)
    defaults.set(1,forKey:key)
    #expect(MediaImageCanvasControls.columns(UserDefaults(suiteName:name)?.integer(forKey:key)) == 1)
    #expect(!MediaImageCanvasControls.deliberateFingerDrag(distance:4,multipleContacts:false))
    #expect(!MediaImageCanvasControls.deliberateFingerDrag(distance:60,multipleContacts:true))
    #expect(MediaImageCanvasControls.deliberateFingerDrag(distance:60,multipleContacts:false))
    #expect(MediaImageCanvasControls.pencilEditing(after:.pencil,current:false,fingerDrawing:false))
    #expect(MediaImageCanvasControls.pencilEditing(after:.finger,current:true,fingerDrawing:false))
    #expect(!MediaImageCanvasControls.pencilEditing(after:.finger,current:true,fingerDrawing:true))
    #expect(!MediaImageCanvasControls.pencilEditing(after:.pointer,current:true,fingerDrawing:false))
    #expect(!MediaImageCanvasControls.fingerEditsCanvas(editsCanvas:true,stroke:false,pencilEditing:true,fingerDrawing:false))
    #expect(MediaImageCanvasControls.fingerEditsCanvas(editsCanvas:true,stroke:true,pencilEditing:true,fingerDrawing:true))
    #expect(MediaImageCanvasControls.fingerEditsCanvas(editsCanvas:true,stroke:false,pencilEditing:false,fingerDrawing:false))
    let descriptor = try MediaPreparedBundledCatalog.load().descriptor(id:"image.feather-brush")
    #expect(descriptor.category == "retouch" && descriptor.existingCommand == "setLayerMask")
}

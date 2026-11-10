// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreGraphics
import Testing
import FloeCore
import FloeWorkbench
@testable import FloeApp

@Suite("M13 M14 original-image and native control boundaries", .serialized)
@MainActor struct MediaImageWarpAppTests {
    private struct Fixture {
        let root: URL
        let store: MediaProjectStore
        let session: MediaV2Session
        let layerID: UUID
        let assetID: UUID
        let source: URL
    }
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0,count: image.width*image.height*4)
        let worked = bytes.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,
                space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy);context.draw(image,in: .init(x: 0,y: 0,width: image.width,height: image.height));return true
        }
        #expect(worked);return bytes
    }
    private func raster(width: Int = 128,height: Int = 96,white: Bool = false) throws -> CGImage {
        var bytes = [UInt8](repeating: 0,count: width*height*4)
        for y in height/4..<height*3/4 { for x in width/4..<width*3/4 {
            let i = (y*width+x)*4;bytes[i] = 255;bytes[i+1] = white ? 255:0;bytes[i+2] = white ? 255:0;bytes[i+3] = 255
        } }
        return try #require(CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,
            space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent))
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("m13-m14-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"),withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Assets/original.png"), sourceData = try #require(WorkbenchPNG.encode(raster()))
        try sourceData.write(to: source)
        let asset = MediaAssetReference(kind: .image,relativePath: "Assets/original.png",originalName: "Original",byteCount: Int64(sourceData.count),contentHash: FloeDigest.sha256Hex(sourceData))
        let project = MediaProject(kind: .image,name: "Image transform fixture",canvas: .init(width: 128,height: 96))
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects")), coordinator = MediaPreparedCoordinator(store: store)
        try await store.save(project);_ = try await coordinator.upgradeDocument(id: project.id)
        let layer = MediaPreparedLayer(name: "Source",content: .raster(.init(source: .asset(asset.id))))
        _ = try await coordinator.applyUserOperations([.init(action: .insertAsset(asset)),.init(action: .insertLayer(layer: layer,parentID: nil,index: nil))],to: project.id)
        let session = try await MediaV2Session.open(projectID: project.id,root: root,store: store)
        session.select(try #require(session.document.layer(layer.id)))
        session.tool = "image.perspective"
        return .init(root: root,store: store,session: session,layerID: layer.id,assetID: asset.id,source: source)
    }
    private func inspect(_ f: Fixture, tool: String = "image.perspective") async throws -> MediaImageWarpGeometry {
        var input = MediaV2ToolInput();input.objectID = f.layerID;input.expectedRevision = f.session.document.revision;input.property = "inspect"
        input.selectionFence = try StudioMediaObservation.media(f.session).selectionFence
        let before = try Data(contentsOf: f.store.projectURL(id: f.session.id))
        let result = try await f.session.performTool(tool,input: input)
        #expect(result.selectionOnly && result.groupID == nil && result.imageWarp?.applied == false)
        #expect(try Data(contentsOf: f.store.projectURL(id: f.session.id)) == before)
        return try #require(result.imageWarp?.source)
    }
    private func applyInput(_ f: Fixture, geometry: MediaImageWarpGeometry) throws -> MediaV2ToolInput {
        var input = MediaV2ToolInput();input.objectID = f.layerID;input.expectedRevision = f.session.document.revision
        input.selectionFence = try StudioMediaObservation.media(f.session).selectionFence
        input.text = geometry.pixelSHA256;input.property = "apply"
        input.points = geometry.sourceQuad.points.map { .init(x: $0.x+0.18,y: $0.y+0.12) }
        return input
    }
    @Test func actualToolInspectsTightSourceThenSavesReopensAndUndoRestoresOriginal() async throws {
        let f = try await fixture();defer { f.session.discardImageWarpDraft();f.session.stopPlayback();try? FileManager.default.removeItem(at: f.root) }
        let original = try Data(contentsOf: f.source),geometry = try await inspect(f)
        #expect(geometry.contentBounds.width < geometry.width && geometry.contentBounds.height < geometry.height)
        let result = try await f.session.performTool("image.perspective",input: applyInput(f,geometry: geometry))
        let group = try #require(result.groupID), content = try #require(f.session.document.layer(f.layerID))
        #expect(!result.selectionOnly && result.imageWarp?.applied == true)
        guard case .raster(let raster) = content.content,case .asset(let newAssetID) = raster.source else { Issue.record("No real raster product");return }
        #expect(newAssetID != f.assetID && f.session.document.asset(f.assetID) != nil)
        #expect(try Data(contentsOf: f.source) == original)
        let reopened = try await MediaPreparedCoordinator(store: MediaProjectStore(directory: f.root.appendingPathComponent("Projects"))).loadDocument(id: f.session.id)
        #expect(reopened.layer(f.layerID)?.content == content.content)
        _ = try await f.session.coordinator.undoGroup(group,in: f.session.id);try await f.session.reload()
        #expect(f.session.document.layer(f.layerID)?.content == .raster(.init(source: .asset(f.assetID))))
        #expect(try Data(contentsOf: f.source) == original)
        _ = try await f.session.coordinator.redoGroup(group,in: f.session.id);try await f.session.reload()
        #expect(f.session.document.layer(f.layerID)?.content == content.content)
    }
    @Test func lateSelectionAndSourceChangesRefuseWithoutSaving() async throws {
        let f = try await fixture();defer { f.session.discardImageWarpDraft();f.session.stopPlayback();try? FileManager.default.removeItem(at: f.root) }
        let geometry = try await inspect(f),input = try applyInput(f,geometry: geometry)
        let projectBefore = try Data(contentsOf: f.store.projectURL(id: f.session.id))
        f.session.selection = .init(shapes: [.init(kind: .rectangle,points: [.init(x: 0.2,y: 0.2),.init(x: 0.6,y: 0.6)])])
        do { _ = try await f.session.performTool("image.distort",input: input);Issue.record("Changed selection accepted") } catch MediaPreparedCoreError.documentChanged {}
        #expect(try Data(contentsOf: f.store.projectURL(id: f.session.id)) == projectBefore)
        f.session.selection = nil
        var pixels = try #require(WorkbenchPNG.encode(raster(white: true)));pixels.append(0)
        try pixels.write(to: f.source)
        do { _ = try await f.session.performTool("image.distort",input: input);Issue.record("Changed source accepted") } catch MediaPreparedCoreError.documentChanged {}
        #expect(try Data(contentsOf: f.store.projectURL(id: f.session.id)) == projectBefore)
        #expect(!f.session.processingTool)
    }
    @Test func realDraftCancelDoesNotCommitAndSelectionMappingCanFollowUndo() async throws {
        let f = try await fixture();defer { f.session.discardImageWarpDraft();f.session.stopPlayback();try? FileManager.default.removeItem(at: f.root) }
        let before = try Data(contentsOf: f.store.projectURL(id: f.session.id))
        try await f.session.prepareImageWarpDraft()
        let draft = try #require(f.session.imageWarpDraft)
        draft.beginDrag();draft.moveCorner(0,to: .init(x: 0.2,y: 0.15));draft.endDrag()
        #expect(draft.isDirty && draft.canUndo)
        draft.undo();#expect(!draft.isDirty && draft.canRedo)
        draft.redo();#expect(draft.isDirty)
        f.session.discardImageWarpDraft()
        #expect(f.session.imageWarpDraft == nil)
        #expect(try Data(contentsOf: f.store.projectURL(id: f.session.id)) == before)
        let selected = ImageSelection(shapes: [.init(kind: .rectangle,points: [.init(x: 0.3,y: 0.3),.init(x: 0.5,y: 0.5)])])
        f.session.selection = selected
        let geometry = try await inspect(f,tool: "image.distort"),input = try applyInput(f,geometry: geometry)
        let result = try await f.session.performTool("image.distort",input: input)
        let moved = try #require(f.session.selection),group = try #require(result.groupID)
        #expect(moved != selected && moved.bitmap != nil)
        _ = try await f.session.coordinator.undoGroup(group,in: f.session.id);try await f.session.reload();f.session.restoreImageWarpSelection(groupID: group,redo: false)
        #expect(f.session.selection == selected)
        _ = try await f.session.coordinator.redoGroup(group,in: f.session.id);try await f.session.reload();f.session.restoreImageWarpSelection(groupID: group,redo: true)
        #expect(f.session.selection == moved)
    }
    @Test func actualNativeHandleHitRegionsPassThroughNavigationAndUseSampleNudges() throws {
        let view = MediaV2WarpHandleView(frame: .init(x: 0,y: 0,width: 800,height: 600))
        view.points = [.init(x: 0.2,y: 0.2),.init(x: 0.8,y: 0.2),.init(x: 0.8,y: 0.8),.init(x: 0.2,y: 0.8)]
        view.canvasPixels = .init(width: 1600,height: 1200);view.displayScale = 2;view.layoutIfNeeded()
        #expect(view.hitTest(.init(x: 160,y: 120),with: nil) === view)
        #expect(view.hitTest(.init(x: 400,y: 300),with: nil) === view)
        #expect(view.hitTest(.init(x: 40,y: 40),with: nil) == nil)
        #expect(view.hitTest(.init(x: 172,y: 120),with: nil) == nil)
        var point: CGPoint?
        view.onChange = { index,value in #expect(index == 0);point = value }
        view.nudge(0,dx: 10,dy: -10)
        #expect(abs(try #require(point).x-0.20625) < 0.000_001)
        #expect(abs(try #require(point).y-(0.2-10.0/1200)) < 0.000_001)
    }
    @Test func realFullStackPreviewReplacesOriginalLayerAndMapsReducedCanvasOnce() async throws {
        let f = try await fixture();defer { f.session.stopPlayback();try? FileManager.default.removeItem(at: f.root) }
        let bottom = MediaPreparedLayer(name: "Bottom",content: .raster(.init(source: .solidColor("#0000FF"))))
        let top = MediaPreparedLayer(name: "Above",content: .raster(.init(source: .solidColor("#00FF0080"))))
        _ = try await f.session.coordinator.applyUserOperations([.init(action: .insertLayer(layer: bottom,parentID: nil,index: 0)),.init(action: .insertLayer(layer: top,parentID: nil,index: nil))],to: f.session.id)
        try await f.session.reload()
        let reduced = try raster(width: 32,height: 24,white: true)
        let geometry = try MediaNativeImageWarp.geometry(reduced)
        let shifted = try MediaImageWarpQuad(points: geometry.sourceQuad.points.map { .init(x: $0.x+0.25,y: $0.y) })
        let override = try MediaNativeImageWarp.apply(reduced,mode: .perspective,destination: shifted).image
        let assets = try f.session.resolvedAssets()
        let image = try await f.session.imageRenderer.renderPrepared(f.session.document,canvas: .init(width: 128,height: 96),resolveAsset: { assets[$0] },
            rasterOverrides: [f.layerID: override],outputMaxEdge: 64)
        #expect(image.width == 64 && image.height == 48)
        let bytes = try pixels(image),outside = (24*64+20)*4,center = (24*64+48)*4
        #expect(Int(bytes[outside+2]) > Int(bytes[outside])+80 && bytes[outside+1] > 50)
        #expect(bytes[center] > 80 && bytes[center+1] > 180 && bytes[center+2] > 80)
        do { _ = try await f.session.imageRenderer.renderPrepared(f.session.document,canvas: .init(width: 128,height: 96),resolveAsset: { assets[$0] },rasterOverrides: [UUID(): override]);Issue.record("Unknown override silently ignored") }
        catch WorkbenchImageError.unsupportedSource(_) {}
    }
}
#endif

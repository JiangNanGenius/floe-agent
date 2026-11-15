// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
import CoreImage
@testable import FloeWorkbench

@Suite("M01-M05 and M22 native coverage masks")
struct MediaNativeSelectionTests {
    func fixture() throws -> CGImage {
        let w=32,h=24
        var bytes=Data(count:w*h*4)
        bytes.withUnsafeMutableBytes{buffer in let pixels=buffer.bindMemory(to:UInt8.self);for y in 0..<h{for x in 0..<w{let i=(y*w+x)*4;pixels[i]=(x<8 || (x>=24 && y<8)) ? 255:0;pixels[i+1]=0;pixels[i+2]=pixels[i]==0 ? 255:0;pixels[i+3]=255}}}
        let provider=try #require(CGDataProvider(data:bytes as CFData))
        return try #require(CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    }
    @Test func wandRetainsConnectedPixelsAndDisjointColorRegionsExactly() throws {
        let image=try fixture(),seed=ImageFreehandStroke.Point(x:0.1,y:0.5)
        let connected=try MediaNativeSelection.wand(image:image,point:seed,tolerance:0),all=try MediaNativeSelection.wand(image:image,point:seed,tolerance:0,contiguous:false)
        #expect(connected.alpha.filter{$0>0}.count==8*24)
        #expect(all.alpha.filter{$0>0}.count==8*24+8*8)
        #expect(connected.alpha[4*32+28]==0 && all.alpha[4*32+28]==255)
        #expect(throws:MediaPreparedCoreError.self){try MediaNativeSelection.wand(image:image,point:seed,tolerance:2)}
    }
    @Test func bitmapSelectionRefinementAndSubtractionKeepActualHolesAndPersist() throws {
        let mask=try ImageSelectionBitmap(width:32,height:24,alpha:Data((0..<32*24).map{let x=$0%32,y=$0/32;return x>=8 && x<24 && y>=6 && y<18 ? UInt8(255):UInt8(0)}))
        let selection=ImageSelection(bitmap:mask)
        let expanded=try MediaNativeSelection.refine(selection,width:32,height:24,mode:.expand,amount:2)
        let contracted=try MediaNativeSelection.refine(selection,width:32,height:24,mode:.expand,amount:-2)
        #expect(expanded.alpha.filter{$0>127}.count>mask.alpha.filter{$0>127}.count)
        #expect(contracted.alpha.filter{$0>127}.count<mask.alpha.filter{$0>127}.count)
        for mode in [MediaNativeSelection.Refinement.refine,.smooth]{let result=try MediaNativeSelection.refine(selection,width:32,height:24,mode:mode,amount:2);#expect(result.alpha.count==32*24 && result.alpha.contains{$0>0})}
        let ring=try MediaNativeSelection.combine(contracted,with:selection,operation:.subtract)
        #expect(ring.bitmap!.alpha[12*32+16]==0)
        let inverted=try MediaNativeSelection.flattened(.init(inverted:true,bitmap:mask),width:32,height:24)
        #expect(inverted.alpha[12*32+16]==0 && inverted.alpha[0]==255)
        let reopened=try JSONDecoder().decode(ImageSelection.self,from:JSONEncoder().encode(ring))
        #expect(reopened==ring)
        #expect(throws:MediaPreparedCoreError.self){try ImageSelectionBitmap(width:2049,height:1,alpha:Data(count:2049))}
    }
    @Test func subjectAdapterAndBackgroundMaskUseRealCoverageWithoutRectangularSubstitution() async throws {
        struct ControlledSubject:MediaSubjectMasking{
            func foregroundMask(_ image:CGImage) async throws -> ImageSelectionBitmap {
                try ImageSelectionBitmap(width:image.width,height:image.height,alpha:Data((0..<image.width*image.height).map{let x=$0%image.width,y=$0/image.width;return (x-16)*(x-16)+(y-12)*(y-12)<36 ? UInt8(255):UInt8(0)}))
            }
        }
        let image=try fixture(),mask=try await ControlledSubject().foregroundMask(image)
        let selection=ImageSelection(bitmap:mask),reopened=try JSONDecoder().decode(ImageSelection.self,from:JSONEncoder().encode(selection))
        #expect(reopened.bitmap!.alpha[12*32+16]==255 && reopened.bitmap!.alpha[0]==0)
        let ci=try #require(ImageSelectionRasterizer.maskImage(for:reopened,canvas:.init(width:32,height:24)))
        let transparent=CIImage(color:.clear).cropped(to:ci.extent)
        let output=CIImage(cgImage:image).applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:transparent,kCIInputMaskImageKey:ci])
        let cg=try #require(CIContext().createCGImage(output,from:ci.extent)),pixels=try MediaNativeSelection.rgba(cg).pixels
        #expect(pixels[3]==0 && pixels[(12*32+16)*4+3]==255)
    }
    /// The active selection's feather is real coverage, not a label: it
    /// spreads beyond the vector edge, softens the edge itself, and returns to
    /// a hard edge when cleared. The bounded overlay path must show the same
    /// effect at preview resolution.
    @Test func featheredVectorSelectionRendersSoftEdgesAndClearsAtZero() throws {
        let canvas = CGSize(width: 32, height: 24)
        let shape = ImageSelectionShape(kind: .rectangle,
            points: [.init(x: 0.25, y: 0.25), .init(x: 0.75, y: 0.75)])
        let hard = ImageSelection(shapes: [shape], feather: 0)
        let feathered = ImageSelection(shapes: [shape], feather: 4.0 / 24.0)
        func coverage(_ selection: ImageSelection, edge: Int = 2048) throws -> ([UInt8], Int, Int) {
            let image = try #require(ImageSelectionRasterizer.maskImage(for: selection, canvas: canvas))
            let rendered = try #require(CIContext(options: [.cacheIntermediates: false])
                .createCGImage(image, from: CGRect(origin: .zero, size: canvas)))
            let raster = try MediaNativeSelection.rgba(rendered)
            return (raster.pixels, raster.width, raster.height)
        }
        let (hardPixels, width, _) = try coverage(hard)
        let (featherPixels, _, _) = try coverage(feathered)
        func alpha(_ x: Int, _ y: Int, _ pixels: [UInt8]) -> UInt8 { pixels[(y * width + x) * 4 + 3] }
        #expect(alpha(16, 12, hardPixels) == 255)
        #expect(alpha(16, 12, featherPixels) > 200, "the centre stays mostly selected")
        #expect(alpha(7, 12, hardPixels) == 0)
        #expect(alpha(7, 12, featherPixels) > 0)
        #expect(alpha(8, 12, featherPixels) < alpha(8, 12, hardPixels))
        #expect(alpha(23, 12, featherPixels) < alpha(23, 12, hardPixels))
        #expect(alpha(24, 12, hardPixels) == 0)
        #expect(alpha(24, 12, featherPixels) > 0)
        #expect(alpha(7, 12, featherPixels) < alpha(16, 12, featherPixels))

        let cleared = ImageSelection(shapes: [shape], feather: 0)
        let (clearedPixels, _, _) = try coverage(cleared)
        #expect(alpha(7, 12, clearedPixels) == 0)
        #expect(alpha(8, 12, clearedPixels) == 255)
        #expect(alpha(23, 12, clearedPixels) == 255)
        #expect(alpha(24, 12, clearedPixels) == 0)

        let preview = try MediaNativeSelection.flattened(feathered, width: 64, height: 48, maxEdge: 32)
        #expect(preview.width == 32 && preview.height == 24)
        #expect(preview.alpha.contains { $0 > 0 && $0 < 255 }, "preview keeps the soft edge")
        #expect(throws: MediaPreparedCoreError.self) {
            _ = try MediaNativeSelection.flattened(feathered, width: 64, height: 48, maxEdge: 0)
        }
    }

    /// A layer mask created from a feathered selection is a real document
    /// edit: it survives undo, redo and reopening with the same feather.
    @Test func featheredLayerMaskPersistsThroughUndoRedoAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-feather-mask-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MediaProjectStore(directory: root)
        let project = MediaProject(kind: .image, name: "Feather mask", canvas: .init(width: 64, height: 48))
        try await store.save(project)
        let coordinator = MediaPreparedCoordinator(store: store)
        _ = try await coordinator.upgradeDocument(id: project.id)
        let layer = MediaPreparedLayer(name: "Base", content: .strokes(.init()))
        _ = try await coordinator.applyUserOperations(
            [.init(action: .insertLayer(layer: layer, parentID: nil, index: nil))], to: project.id)
        var document = try await coordinator.loadDocument(id: project.id)
        let revision = try #require(document.layer(layer.id)?.revision)
        let selection = ImageSelection(shapes: [
            .init(kind: .ellipse, points: [.init(x: 0.2, y: 0.2), .init(x: 0.8, y: 0.7)])
        ], feather: 6.0 / 48.0)
        let commit = try await coordinator.applyUserOperations([
            .init(action: .setLayerMask(id: layer.id, expectedRevision: revision,
                mask: .init(vector: selection)))
        ], to: project.id)
        document = try await coordinator.loadDocument(id: project.id)
        #expect(document.layer(layer.id)?.mask?.vector == selection)
        #expect(abs((document.layer(layer.id)?.mask?.vector?.feather ?? 0) - 6.0 / 48.0) < 0.000001)

        _ = try await coordinator.undoGroup(commit.groupID, in: project.id)
        document = try await coordinator.loadDocument(id: project.id)
        #expect(document.layer(layer.id)?.mask == nil)
        _ = try await coordinator.redoGroup(commit.groupID, in: project.id)
        document = try await coordinator.loadDocument(id: project.id)
        #expect(document.layer(layer.id)?.mask?.vector == selection)

        let reopenedCoordinator = MediaPreparedCoordinator(store: MediaProjectStore(directory: root))
        let reopened = try await reopenedCoordinator.loadDocument(id: project.id)
        #expect(reopened.layer(layer.id)?.mask?.vector == selection)
        try MediaPreparedIntegrity.validateEnvelope(try #require(try await store.loadProject(id: project.id)))
    }

}

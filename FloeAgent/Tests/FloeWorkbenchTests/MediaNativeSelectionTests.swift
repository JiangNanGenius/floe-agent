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


    // MARK: Stroke coverage fences (brush / eraser)

    private struct RenderedPixels {
        let bytes: [UInt8]
        let width: Int
        func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let index = (y * width + x) * 4
            return (Int(bytes[index]), Int(bytes[index + 1]),
                    Int(bytes[index + 2]), Int(bytes[index + 3]))
        }
    }

    /// Colour-managed Core Image output shifts channel values by a few
    /// counts; assert the dominant channel rather than exact 255/0.
    private func isRed(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
        p.r >= 200 && p.g <= 80 && p.b <= 80 && p.a >= 250
    }
    private func isBlue(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
        p.b >= 200 && p.r <= 80 && p.g <= 80
    }
    private func isGreen(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
        p.g >= 200 && p.r <= 80 && p.b <= 80
    }
    private func isWhite(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
        p.r >= 200 && p.g >= 200 && p.b >= 200
    }

    private func rectangleSelection(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                                    feather: Double = 0, inverted: Bool = false) -> ImageSelection {
        ImageSelection(shapes: [.init(kind: .rectangle,
            points: [.init(x: x0, y: y0), .init(x: x1, y: y1)])],
            feather: feather, inverted: inverted)
    }

    private func rendered(_ project: MediaProject) async throws -> RenderedPixels {
        let canvas = try #require(project.canvas)
        let image = try await WorkbenchImageRenderer().render(
            project: project, canvas: CGSize(width: canvas.width, height: canvas.height),
            resolveAsset: { _ in nil })
        let raster = try MediaNativeSelection.rgba(image)
        return RenderedPixels(bytes: raster.pixels, width: raster.width)
    }

    private func preparedProject(_ layers: [MediaPreparedLayer],
                                 name: String) async throws -> (MediaProject, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-stroke-\(UUID())")
        let store = MediaProjectStore(directory: root)
        let project = MediaProject(kind: .image, name: name,
                                   canvas: .init(width: 64, height: 48))
        try await store.save(project)
        let coordinator = MediaPreparedCoordinator(store: store)
        _ = try await coordinator.upgradeDocument(id: project.id)
        _ = try await coordinator.applyUserOperations(
            layers.map { .init(action: .insertLayer(layer: $0, parentID: nil, index: nil)) },
            to: project.id)
        let loaded = try #require(try await store.loadProject(id: project.id))
        return (loaded, root)
    }

    private func preparedBrushStrokes(_ project: MediaProject) -> [ImageFreehandStroke] {
        guard case .strokes(let content)? = project.prepared?.layers.first?.content else { return [] }
        return content.strokes
    }

    private func preparedMaskStrokes(_ project: MediaProject) -> [ImageMaskStroke] {
        project.prepared?.layers.last?.mask?.strokes ?? []
    }

    private func assertSameSamples(_ a: RenderedPixels, _ b: RenderedPixels) {
        for (x, y) in [(6, 24), (12, 24), (32, 24), (32, 16), (32, 8), (56, 24)] {
            #expect(a.pixel(x, y) == b.pixel(x, y), "pixel \(x),\(y) must survive reopen")
        }
    }

    /// A non-empty fence that cannot be rasterized is an explicit render
    /// error (the caller keeps the previous frame); it must never silently
    /// become an unclipped full-canvas stroke or whole-canvas erase.
    @Test func unrenderableStrokeFenceFailsClosedInsteadOfChangingEveryPixel() async throws {
        let renderer = WorkbenchImageRenderer()
        let fence = rectangleSelection(0.25, 0.25, 0.75, 0.75)
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        await #expect(throws: WorkbenchImageError.self) {
            _ = try await renderer.clip(fence, image: image, canvas: .zero)
        }
        let eraser = ImageLayerMask(strokes: [ImageMaskStroke(
            points: [.init(x: 0.1, y: 0.5), .init(x: 0.9, y: 0.5)],
            width: 4, hardness: 0, clip: fence)])
        await #expect(throws: WorkbenchImageError.self) {
            _ = try await renderer.applyMask(eraser, to: image, canvas: .zero)
        }
        // Deselected/empty strokes remain a legitimate unclipped paint.
        let unclipped = try await renderer.clip(nil, image: image, canvas: .zero)
        #expect(unclipped.extent.width == 8 && unclipped.extent.height == 8)
    }

    /// The command path validates a region snapshot exactly like a stroke
    /// clip, while still accepting the real trail-less region form produced
    /// by cut/restore. A rejected region never partially applies.
    @Test func regionMaskValidationChecksTheSelectionItselfInTheCommandPath() throws {
        let region = rectangleSelection(0.25, 0.25, 0.75, 0.75)
        let valid = ImageMaskStroke(points: [], width: 0, restore: false, region: region)
        let layer = ImageLayer(kind: .freehand, name: "Paint",
            freehand: .init(strokes: [ImageFreehandStroke(
                points: [.init(x: 0.1, y: 0.5), .init(x: 0.9, y: 0.5)],
                width: 4, colorHex: "#000000")]))
        var project = MediaProject(kind: .image, name: "Region validation",
            canvas: .init(width: 64, height: 48), imageLayers: [layer])
        try MediaTransactions.apply(.addLayerMaskStroke(id: layer.id, stroke: valid), to: &project)
        #expect(project.imageLayers[0].mask?.strokes == [valid])

        let invalidRegion = ImageSelection(shapes: [
            .init(kind: .rectangle, points: [.init(x: 0.2, y: 0.2)])])
        let invalid = ImageMaskStroke(points: [], width: 0, restore: false,
                                      region: invalidRegion)
        #expect(throws: MediaCommandError.self) {
            try MediaTransactions.apply(.addLayerMaskStroke(id: layer.id, stroke: invalid), to: &project)
        }
        #expect(project.imageLayers[0].mask?.strokes == [valid],
                "a rejected region must not partially apply")
    }

    /// Both entry points must use one policy: brush captures the selection as
    /// a per-stroke clip, and an eraser stays a trail with no whole-region
    /// operation even when a selection exists.
    @Test func sharedStrokeFencePolicyCapturesClipAndKeepsEraserATrail() {
        let fence = rectangleSelection(0.2, 0.2, 0.8, 0.8, feather: 0.05)
        let points = [ImageFreehandStroke.Point(x: 0.1, y: 0.5),
                      ImageFreehandStroke.Point(x: 0.9, y: 0.5)]
        let brush = MediaNativeStrokeFence.brush(points: points, width: 12,
            colorHex: "#112233", hardness: 0.2, opacity: 0.7, selection: fence)
        #expect(brush.clip == fence)
        let eraser = MediaNativeStrokeFence.eraser(points: points, width: 12,
            hardness: 0.2, restore: true, selection: fence)
        #expect(eraser.clip == fence)
        #expect(eraser.region == nil)
        #expect(eraser.restore)
        #expect(MediaNativeStrokeFence.clip(for: nil) == nil)
        #expect(MediaNativeStrokeFence.clip(for: ImageSelection()) == nil)
    }

    /// A hard selection is a per-stroke fence, not a layer mask: the trail
    /// paints only inside the marching ants, an earlier stroke outside the
    /// selection keeps its pixels and the layer below is untouched.
    @Test func hardSelectionClipsBrushCoverageWithoutRewritingPriorStrokesOrLayers() async throws {
        let fence = rectangleSelection(0.25, 0.1, 0.75, 0.9)
        let prior = ImageFreehandStroke(points: [.init(x: 0.1, y: 0.2), .init(x: 0.1, y: 0.8)],
                                        width: 6, colorHex: "#00FF00", hardness: 0, opacity: 1)
        let clipped = ImageFreehandStroke(points: [.init(x: 0.05, y: 0.5), .init(x: 0.95, y: 0.5)],
                                          width: 6, colorHex: "#FF0000", hardness: 0, opacity: 1,
                                          clip: fence)
        let base = ImageLayer(kind: .fill, name: "Base", fillColorHex: "#0000FF")
        let paint = ImageLayer(kind: .freehand, name: "Paint",
                               freehand: .init(strokes: [prior, clipped]))
        let project = MediaProject(kind: .image, name: "Hard selection",
                                   canvas: .init(width: 64, height: 48),
                                   imageLayers: [base, paint])
        let pixels = try await rendered(project)
        #expect(isBlue(pixels.pixel(12, 24)),
                "the trail outside the selection keeps the lower layer")
        #expect(isRed(pixels.pixel(32, 24)),
                "the brush paints inside the selection")
        #expect(isBlue(pixels.pixel(56, 24)), "the right side outside the selection is untouched")
        #expect(isBlue(pixels.pixel(32, 8)), "only the trail changes, not the whole selected region")
        #expect(isGreen(pixels.pixel(6, 24)),
                "an earlier stroke outside the selection keeps its pixels")
    }

    /// Inverted, bitmap and pressure strokes all use the same captured fence;
    /// none of them can paint outside the actual selection snapshot.
    @Test func invertedBitmapAndPressureFencesClipRealBrushCoverage() async throws {
        let base = ImageLayer(kind: .fill, name: "Base", fillColorHex: "#0000FF")
        func paint(_ stroke: ImageFreehandStroke) -> ImageLayer {
            ImageLayer(kind: .freehand, name: "Paint", freehand: .init(strokes: [stroke]))
        }
        let inverseStroke = ImageFreehandStroke(
            points: [.init(x: 0.05, y: 0.5), .init(x: 0.95, y: 0.5)],
            width: 6, colorHex: "#FF0000", hardness: 0, opacity: 1,
            clip: rectangleSelection(0.25, 0.1, 0.75, 0.9, inverted: true))
        let inverse = try await rendered(MediaProject(kind: .image, name: "Inverse",
            canvas: .init(width: 64, height: 48), imageLayers: [base, paint(inverseStroke)]))
        #expect(isRed(inverse.pixel(8, 24)),
                "an inverted fence keeps the outside part of the trail")
        #expect(isBlue(inverse.pixel(32, 24)),
                "an inverted fence hides the inside part of the trail")

        let bitmap = try ImageSelectionBitmap(width: 32, height: 24,
            alpha: Data((0..<32 * 24).map { $0 % 32 < 16 ? UInt8(255) : UInt8(0) }))
        let bitmapStroke = ImageFreehandStroke(
            points: [.init(x: 0.05, y: 0.5), .init(x: 0.95, y: 0.5)],
            width: 6, colorHex: "#FF0000", hardness: 0, opacity: 1,
            clip: ImageSelection(bitmap: bitmap))
        let bitmapPixels = try await rendered(MediaProject(kind: .image, name: "Bitmap",
            canvas: .init(width: 64, height: 48), imageLayers: [base, paint(bitmapStroke)]))
        #expect(isRed(bitmapPixels.pixel(8, 24)), "the bitmap selects the left half")
        #expect(isBlue(bitmapPixels.pixel(56, 24)), "the bitmap excludes the right half")

        let pressureStroke = ImageFreehandStroke(
            points: [.init(x: 0.1, y: 0.5, pressure: 1), .init(x: 0.9, y: 0.5, pressure: 1)],
            width: 6, colorHex: "#FFCC00", hardness: 0, opacity: 1,
            clip: rectangleSelection(0.4, 0.1, 0.6, 0.9))
        let pressure = try await rendered(MediaProject(kind: .image, name: "Pressure",
            canvas: .init(width: 64, height: 48), imageLayers: [base, paint(pressureStroke)]))
        let pressureInside = pressure.pixel(32, 24)
        #expect(pressureInside.r >= 200 && pressureInside.b <= 80,
                "a measured-pressure stroke is clipped by the same fence")
        #expect(isBlue(pressure.pixel(8, 24)),
                "the pressure stroke paints nothing outside the fence")
    }

    /// Feather is real coverage on the brush edge; the prepared document keeps
    /// the per-stroke snapshot and the same pixels after a full save/reopen.
    @Test func featheredSelectionSoftensClippedBrushEdgeAndSurvivesReopen() async throws {
        let fence = rectangleSelection(0.3, 0.1, 0.7, 0.9, feather: 6.0 / 48.0)
        let stroke = ImageFreehandStroke(
            points: [.init(x: 0.05, y: 0.5), .init(x: 0.95, y: 0.5)],
            width: 6, colorHex: "#FF0000", hardness: 0, opacity: 1, clip: fence)
        let (project, root) = try await preparedProject(
            [MediaPreparedLayer(name: "Paint", content: .strokes(.init(strokes: [stroke])))],
            name: "Feather brush")
        defer { try? FileManager.default.removeItem(at: root) }
        let pixels = try await rendered(project)
        #expect(pixels.pixel(32, 24).a >= 240, "the centre stays fully painted")
        let edge = pixels.pixel(16, 24).a
        #expect(edge > 8 && edge < 248, "feather creates real partial coverage outside the edge")
        #expect(pixels.pixel(21, 24).a > edge, "coverage rises toward the selected centre")
        #expect(pixels.pixel(6, 24).a <= 24, "far outside the feather the stroke disappears")
        #expect(pixels.pixel(58, 24).a <= 24)
        #expect(pixels.pixel(32, 8).a <= 2, "the soft edge never fills the whole region")

        let reopened = try #require(try await MediaProjectStore(directory: root)
            .loadProject(id: project.id))
        #expect(preparedBrushStrokes(reopened).first?.clip == fence)
        assertSameSamples(pixels, try await rendered(reopened))
    }

    /// The eraser remains a drag: inside the selection only the trail erases,
    /// outside it nothing changes, and an older mask stroke keeps its result.
    @Test func eraserDragClipsToSelectionInsteadOfErasingTheWholeRegion() async throws {
        let fence = rectangleSelection(0.4, 0.25, 0.6, 0.75)
        let prior = ImageMaskStroke(points: [.init(x: 0.1, y: 0.2), .init(x: 0.1, y: 0.8)],
                                    width: 4, hardness: 0, restore: false)
        let drag = ImageMaskStroke(points: [.init(x: 0.2, y: 0.5), .init(x: 0.8, y: 0.5)],
                                   width: 8, hardness: 0, restore: false, clip: fence)
        let base = MediaPreparedLayer(name: "Base",
            content: .raster(.init(source: .solidColor("#0000FF"))))
        let top = MediaPreparedLayer(name: "Top",
            content: .raster(.init(source: .solidColor("#FFFFFF"))),
            mask: .init(strokes: [prior, drag]))
        let (project, root) = try await preparedProject([base, top], name: "Eraser drag")
        defer { try? FileManager.default.removeItem(at: root) }
        let pixels = try await rendered(project)
        #expect(isBlue(pixels.pixel(32, 24)),
                "inside the selection the drag erases the layer")
        #expect(isWhite(pixels.pixel(32, 16)),
                "the selected region is not erased as a whole block")
        #expect(isWhite(pixels.pixel(12, 24)),
                "the trail outside the selection changes nothing")
        #expect(isWhite(pixels.pixel(56, 24)))
        #expect(isBlue(pixels.pixel(6, 12)),
                "an earlier mask stroke stays in effect and is not rewritten")
        #expect(isWhite(pixels.pixel(20, 24)),
                "the part of the drag before the selection is visible")

        let reopened = try #require(try await MediaProjectStore(directory: root)
            .loadProject(id: project.id))
        #expect(preparedMaskStrokes(reopened).last?.clip == fence)
        assertSameSamples(pixels, try await rendered(reopened))
    }

    /// Existing files store a real whole-block cut as `region` with no trail.
    /// That meaning and the exact decoded bytes keep working; the new `clip`
    /// field is absent from old JSON and does not change it.
    @Test func oldRegionMasksKeepWholeBlockCutSemanticsAndDecodeWithoutClip() async throws {
        let region = rectangleSelection(0.25, 0.25, 0.75, 0.75)
        let oldMaskJSON = """
        {"points":[{"x":0.05,"y":0.05},{"x":0.06,"y":0.06}],"width":24,"restore":false,\
        "region":{"shapes":[{"kind":"rectangle","operation":"replace","points":[{"x":0.25,"y":0.25},{"x":0.75,"y":0.75}]}],"feather":0,"inverted":false}}
        """
        let decoded = try JSONDecoder().decode(ImageMaskStroke.self, from: Data(oldMaskJSON.utf8))
        #expect(decoded.clip == nil)
        #expect(decoded.region == region)

        let oldBrushJSON = """
        {"points":[{"x":0.2,"y":0.5},{"x":0.8,"y":0.5}],"width":6,"colorHex":"#FF0000"}
        """
        let oldBrush = try JSONDecoder().decode(ImageFreehandStroke.self, from: Data(oldBrushJSON.utf8))
        #expect(oldBrush.clip == nil)

        let base = ImageLayer(kind: .fill, name: "Base", fillColorHex: "#0000FF")
        let top = ImageLayer(kind: .fill, name: "Top",
                             mask: .init(strokes: [decoded]), fillColorHex: "#FFFFFF")
        let project = MediaProject(kind: .image, name: "Old region",
                                   canvas: .init(width: 64, height: 48),
                                   imageLayers: [base, top])
        let pixels = try await rendered(project)
        #expect(isBlue(pixels.pixel(32, 24)) && isBlue(pixels.pixel(32, 16)),
                "a region stroke erases the whole selection, not just a trail")
        #expect(isWhite(pixels.pixel(8, 24)),
                "outside the region the layer is untouched")

        // The current cut command writes the same region form, and upgrading
        // such a project remains a valid prepared document with unchanged
        // whole-block pixels.
        var cut = MediaProject(kind: .image, name: "Cut", canvas: .init(width: 64, height: 48),
                               imageLayers: [base, ImageLayer(kind: .fill, name: "Top",
                                                              fillColorHex: "#FFFFFF")],
                               imageSelection: region)
        try MediaTransactions.apply(.cutSelection(layerID: cut.imageLayers[1].id), to: &cut)
        #expect(cut.imageLayers[1].mask?.strokes.first?.region == region)
        let upgraded = try MediaPreparedUpgrade.upgrade(cut)
        try MediaPreparedIntegrity.validateEnvelope(upgraded)
        let upgradedPixels = try await rendered(upgraded)
        #expect(isBlue(upgradedPixels.pixel(32, 24)) && isWhite(upgradedPixels.pixel(8, 24)),
                "the real cut keeps its whole-block meaning in the prepared path")
    }

    /// The legacy v1 render path persists the captured fences and renders the
    /// same pixels after a store reopen.
    @Test func legacyClippedBrushAndEraserPersistThroughSaveReopen() async throws {
        let fence = rectangleSelection(0.25, 0.1, 0.75, 0.9)
        let brush = ImageFreehandStroke(
            points: [.init(x: 0.05, y: 0.5), .init(x: 0.95, y: 0.5)],
            width: 6, colorHex: "#FF0000", hardness: 0, opacity: 1, clip: fence)
        let eraser = ImageMaskStroke(points: [.init(x: 0.2, y: 0.3), .init(x: 0.8, y: 0.3)],
                                     width: 6, hardness: 0, restore: false, clip: fence)
        let base = ImageLayer(kind: .fill, name: "Base", fillColorHex: "#0000FF")
        let paint = ImageLayer(kind: .freehand, name: "Paint", freehand: .init(strokes: [brush]))
        let top = ImageLayer(kind: .fill, name: "Top",
                             mask: .init(strokes: [eraser]), fillColorHex: "#FFFFFF")
        let project = MediaProject(kind: .image, name: "Legacy reopen",
                                   canvas: .init(width: 64, height: 48),
                                   imageLayers: [base, paint, top])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-legacy-stroke-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try await MediaProjectStore(directory: root).save(project)
        let before = try await rendered(project)
        let reopened = try #require(try await MediaProjectStore(directory: root)
            .loadProject(id: project.id))
        #expect(reopened.imageLayers[1].freehand?.strokes.first?.clip == fence)
        #expect(reopened.imageLayers[2].mask?.strokes.first?.clip == fence)
        assertSameSamples(before, try await rendered(reopened))
    }

}

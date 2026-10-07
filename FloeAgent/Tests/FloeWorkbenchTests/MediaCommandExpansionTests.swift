// FloeWorkbench — Build265 media command expansion tests.
//
// Covers: selection/mask/duplicate/flip commands, rendered-edge alignment in
// pixel space (non-square canvas), render-preserving raster merge, tool JSON
// coding for new image/video commands and dynamic capabilities.

#if canImport(CoreImage)
import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FloeCore
@testable import FloeWorkbench

@Suite("Build265 media command expansion")
struct MediaCommandExpansionTests {
    private func solidPNG(width: Int, height: Int, color: (CGFloat, CGFloat, CGFloat, CGFloat),
                          at url: URL) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: color.3))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &bytes, width: image.width, height: image.height,
                            bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let row = image.height - 1 - y
        let offset = (row * image.width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }

    // MARK: LayerLayout

    @Test("rotated natural bounds are computed in pixel space (2000x1000 canvas)")
    func rotatedBoundsPixelParity() {
        // A 400x100 layer rotated 90deg must occupy roughly 100x400 pixels,
        // regardless of the non-square canvas.
        let box = LayerLayout.renderedBoundsPixels(
            naturalWidth: 400, naturalHeight: 100,
            canvasSize: (2000, 1000),
            transform: ImageLayerTransform(centerX: 0.5, centerY: 0.5, scale: 1, rotationDegrees: 90))
        #expect(abs(box.width - 100) < 2, "rotated width should be ~100 px, got \(box.width)")
        #expect(abs(box.height - 400) < 2, "rotated height should be ~400 px, got \(box.height)")
        // Centered on the canvas center.
        #expect(abs(box.centerX - 1000) < 2)
        #expect(abs(box.centerY - 500) < 2)
    }

    @Test("alignment uses rendered edges, not centers")
    func edgeAlignmentUsesBounds() {
        let canvas = (width: 2000.0, height: 1000.0)
        let entries = [
            LayerLayoutEntry(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                             naturalWidth: 400, naturalHeight: 100,
                             transform: .init(centerX: 0.2, centerY: 0.5, scale: 1)),
            LayerLayoutEntry(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                             naturalWidth: 200, naturalHeight: 600,
                             transform: .init(centerX: 0.8, centerY: 0.5, scale: 1))
        ]
        let deltas = LayerLayout.alignmentDeltas(entries, alignment: .left, canvasSize: canvas)
        // After applying deltas, both rendered left edges coincide.
        var boxes: [UUID: LayerLayoutBox] = [:]
        for entry in entries {
            var t = entry.transform
            if let d = deltas[entry.id] { t.centerX += d.dx; t.centerY += d.dy }
            boxes[entry.id] = LayerLayout.renderedBoundsPixels(
                naturalWidth: entry.naturalWidth, naturalHeight: entry.naturalHeight,
                canvasSize: canvas, transform: t)
        }
        #expect(abs(boxes[entries[0].id]!.minX - boxes[entries[1].id]!.minX) < 1)
    }

    // MARK: Commands

    private func twoLayerProject() -> MediaProject {
        var project = MediaProject(kind: .image, name: "P", canvas: MediaCanvas(width: 200, height: 200))
        let a = ImageLayer(kind: .freehand, name: "A",
                           transform: .init(centerX: 0.3, centerY: 0.3),
                           freehand: ImageFreehandContent(strokes: [
                            ImageFreehandStroke(points: [.init(x: 0.2, y: 0.2), .init(x: 0.4, y: 0.4)],
                                                width: 4, colorHex: "#FF0000")
                           ]))
        let b = ImageLayer(kind: .freehand, name: "B",
                           transform: .init(centerX: 0.7, centerY: 0.7),
                           freehand: ImageFreehandContent(strokes: [
                            ImageFreehandStroke(points: [.init(x: 0.6, y: 0.6), .init(x: 0.8, y: 0.8)],
                                                width: 4, colorHex: "#00FF00")
                           ]))
        try? MediaTransactions.apply(.addImageLayer(a), to: &project)
        try? MediaTransactions.apply(.addImageLayer(b), to: &project)
        return project
    }

    @Test("selection commands are undoable and mask strokes accumulate")
    func selectionAndMaskCommands() throws {
        var project = twoLayerProject()
        let id = project.imageLayers[0].id
        let selection = ImageSelection(shapes: [
            ImageSelectionShape(kind: .lasso, points: [.init(x: 0.1, y: 0.1), .init(x: 0.5, y: 0.1), .init(x: 0.5, y: 0.5)])
        ])
        let revBefore = project.revision
        try MediaTransactions.apply(.setImageSelection(selection), to: &project)
        #expect(project.imageSelection?.shapes.count == 1)
        #expect(project.revision == revBefore + 1)
        let stroke = ImageMaskStroke(points: [.init(x: 0.2, y: 0.5), .init(x: 0.8, y: 0.5)],
                                     width: 12, restore: false)
        try MediaTransactions.apply(.addLayerMaskStroke(id: id, stroke: stroke), to: &project)
        try MediaTransactions.apply(.addLayerMaskStroke(id: id, stroke: stroke), to: &project)
        #expect(project.imageLayers.first { $0.id == id }?.mask?.strokes.count == 2,
                "the new stroke must be appended even when a mask already exists")
        try MediaTransactions.apply(.clearLayerMask(id: id), to: &project)
        #expect(project.imageLayers.first { $0.id == id }?.mask == nil)
        #expect(MediaTransactions.undo(&project))
        #expect(project.imageLayers.first { $0.id == id }?.mask?.strokes.count == 2,
                "undo restores the cleared mask")
        // Two stroke additions are each their own transaction.
        #expect(MediaTransactions.undo(&project))
        #expect(project.imageLayers.first { $0.id == id }?.mask?.strokes.count == 1)
        #expect(MediaTransactions.undo(&project))
        #expect(project.imageSelection != nil)
        #expect(MediaTransactions.undo(&project))
        #expect(project.imageSelection == nil, "selection edits are undoable")
    }

    @Test("duplicate and flip commands behave correctly")
    func duplicateAndFlip() throws {
        var project = twoLayerProject()
        let id = project.imageLayers[0].id
        let countBefore = project.imageLayers.count
        try MediaTransactions.apply(.duplicateLayer(id: id, name: "A copy"), to: &project)
        #expect(project.imageLayers.count == countBefore + 1)
        let copy = project.imageLayers[1]
        #expect(copy.id != id)
        #expect(copy.name == "A copy")
        try MediaTransactions.apply(.flipLayer(id: copy.id, horizontal: true), to: &project)
        #expect(project.imageLayers.first { $0.id == copy.id }?.transform.flipX == true)
        // Locked layer refuses mask/flip/align.
        try MediaTransactions.apply(.updateLayer(id: copy.id, transform: nil, opacity: nil,
                                                  isHidden: nil, isLocked: true, adjustment: nil,
                                                  text: nil, crop: .unchanged), to: &project)
        #expect(throws: (any Error).self) {
            try MediaTransactions.apply(.flipLayer(id: copy.id, horizontal: false), to: &project)
        }
        #expect(throws: (any Error).self) {
            try MediaTransactions.apply(.addLayerMaskStroke(id: copy.id, stroke: ImageMaskStroke(
                points: [.init(x: 0, y: 0), .init(x: 1, y: 1)], width: 10)), to: &project)
        }
    }

    @Test("merge requires a registered raster asset and replaces the layers")
    func mergeRequiresRaster() throws {
        var project = twoLayerProject()
        let ids = project.imageLayers.map(\.id)
        // Without an asset the merge is rejected.
        #expect(throws: (any Error).self) {
            try MediaTransactions.apply(
                .mergeLayers(ids: ids, name: "M",
                             raster: MergedLayerRaster(assetID: UUID(), width: 200, height: 200)),
                to: &project)
        }
    }

    @Test("render merge then command merge is render-preserving and undoable")
    func rasterMergeRoundTrip() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("base.png")
        try solidPNG(width: 200, height: 200, color: (1, 1, 1, 1), at: url)
        var project = twoLayerProject()
        let baseAsset = MediaAssetReference(kind: .image, relativePath: "base.png", originalName: "base.png")
        try MediaTransactions.apply(.addAsset(baseAsset), to: &project)
        let resolve: @Sendable (UUID) -> URL? = { _ in url }
        let renderer = WorkbenchImageRenderer()
        let before = try await renderer.render(project: project, canvas: CGSize(width: 200, height: 200),
                                         resolveAsset: resolve)
        let ids = Set(project.imageLayers.map(\.id))
        let mergedCG = try await renderer.renderMerge(project: project, layerIDs: ids,
                                                canvas: CGSize(width: 200, height: 200),
                                                resolveAsset: resolve)
        guard let png = WorkbenchPNG.encode(mergedCG) else { throw CocoaError(.fileWriteUnknown) }
        let mergedURL = root.appendingPathComponent("merged.png")
        try png.write(to: mergedURL, options: .atomic)
        let rasterAsset = MediaAssetReference(
            kind: .image, relativePath: "merged.png", originalName: "merged.png",
            byteCount: Int64(png.count))
        let raster = MergedLayerRaster(assetID: rasterAsset.id, width: mergedCG.width, height: mergedCG.height)
        try MediaTransactions.apply(.addAsset(rasterAsset), to: &project)
        let idList = Array(ids)
        let countBeforeMerge = project.imageLayers.count
        try MediaTransactions.apply(.mergeLayers(ids: idList, name: "Merged", raster: raster), to: &project)
        #expect(project.imageLayers.count == countBeforeMerge - 1) // two ink layers -> one raster
        #expect(project.imageLayers.contains { $0.name == "Merged" })
        let after = try await renderer.render(project: project, canvas: CGSize(width: 200, height: 200),
                                        resolveAsset: { id in
            id == baseAsset.id ? url : (id == rasterAsset.id ? mergedURL : nil)
        })
        // The merged ink pixels must remain visible (the strokes are colored).
        var coloredBefore = 0; var coloredAfter = 0
        for y in stride(from: 0, to: 200, by: 4) {
            for x in stride(from: 0, to: 200, by: 4) {
                let pb = pixel(before, x: x, y: y)
                let pa = pixel(after, x: x, y: y)
                if pb.r > 150 || pb.g > 150 { coloredBefore += 1 }
                if pa.r > 150 || pa.g > 150 { coloredAfter += 1 }
            }
        }
        #expect(coloredAfter > 0)
        #expect(Double(coloredAfter) > Double(coloredBefore) * 0.8,
                "merge must preserve the rendered ink (before=\(coloredBefore) after=\(coloredAfter))")
        // Undo restores the two original ink layers.
        #expect(MediaTransactions.undo(&project))
        #expect(project.imageLayers.count == 2)
    }

    // MARK: Tool JSON coding

    private func decode(_ json: [String: Any]) throws -> MediaEditCommand {
        try MediaProjectCommandCoding.command(json.mapValues { AnyFixture.value($0) })
    }

    @Test("new image and video commands decode from JSON")
    func commandCoding() throws {
        if case .duplicateLayer(let id, let name) = try decode([
            "type": "duplicate_layer", "id": UUID().uuidString, "name": "Copy"
        ]) {
            #expect(name == "Copy")
        } else { Issue.record("expected duplicate_layer") }

        if case .setImageSelection(let selection) = try decode([
            "type": "set_selection",
            "selection": ["shapes": [["kind": "ellipse", "operation": "add",
                                      "points": [["x": 0.1, "y": 0.1], ["x": 0.9, "y": 0.9]]]],
                          "feather": 0.1, "inverted": false]
        ]) {
            #expect(selection?.shapes.first?.kind == .ellipse)
            #expect(selection?.shapes.first?.operation == .add)
            #expect(selection?.feather == 0.1)
        } else { Issue.record("expected set_selection") }

        if case .addLayerMaskStroke(let _, let stroke) = try decode([
            "type": "add_mask_stroke", "id": UUID().uuidString,
            "points": [["x": 0.0, "y": 0.0], ["x": 1.0, "y": 1.0]],
            "width": 18, "hardness": 0.5, "restore": true
        ]) {
            #expect(stroke.restore == true)
            #expect(stroke.hardness == 0.5)
        } else { Issue.record("expected add_mask_stroke") }

        let clipID = UUID()
        if case .duplicateClip(let id) = try decode(["type": "duplicate_clip", "id": clipID.uuidString]) {
            #expect(id == clipID)
        } else { Issue.record("expected duplicate_clip") }

        if case .setCover(let time) = try decode(["type": "set_cover", "time": 3.5]) {
            #expect(time == 3.5)
        } else { Issue.record("expected set_cover") }

        if case .shiftCaptions(let offset) = try decode(["type": "shift_captions", "by_seconds": -0.5]) {
            #expect(offset == -0.5)
        } else { Issue.record("expected shift_captions") }

        if case .setCaptionStyle(let style) = try decode([
            "type": "set_caption_style", "font_size": 40, "alignment": "center",
            "respects_safe_area": true, "position_y": 0.82
        ]) {
            #expect(style.alignment == .center)
            #expect(style.respectsSafeArea == true)
            #expect(style.positionY == 0.82)
        } else { Issue.record("expected set_caption_style") }

        if case .alignLayers(_, let alignment, _) = try decode([
            "type": "align_layers",
            "ids": [UUID().uuidString, UUID().uuidString],
            "alignment": "centerX"
        ]) {
            #expect(alignment == .centerX)
        } else { Issue.record("expected align_layers") }
    }

    @Test("unknown command names are rejected")
    func unknownCommandRejected() {
        #expect(throws: (any Error).self) {
            _ = try decode(["type": "definitely_not_a_command"])
        }
    }

    // MARK: Gesture-to-selection mapping (CUA regression)

    @Test("rectangle/ellipse marquee uses the drag START, not the current point")
    func marqueeUsesStartPoint() {
        let start = ImageFreehandStroke.Point(x: 0.1, y: 0.1)
        let current = ImageFreehandStroke.Point(x: 0.9, y: 0.7)
        let shape = ImageSelectionGesture.shape(kind: .rectangle, operation: .replace,
                                                start: start, current: current, lassoPoints: [])
        #expect(shape?.points.first == start, "rectangle must anchor at the finger's start point")
        #expect(shape?.points.last == current)
    }

    @Test("lasso accumulates enough samples to commit and respects spacing/cap")
    func lassoAccumulation() {
        var points: [ImageFreehandStroke.Point] = []
        points = ImageSelectionGesture.accumulateLasso(points, candidate: .init(x: 0.2, y: 0.2))
        #expect(points.count == 1)
        // A too-close candidate is ignored (bounded spacing).
        points = ImageSelectionGesture.accumulateLasso(points, candidate: .init(x: 0.2001, y: 0.2))
        #expect(points.count == 1)
        points = ImageSelectionGesture.accumulateLasso(points, candidate: .init(x: 0.4, y: 0.2))
        points = ImageSelectionGesture.accumulateLasso(points, candidate: .init(x: 0.4, y: 0.5))
        #expect(points.count == 3, "a lasso must be able to reach the 3-point minimum")
        // Cap is enforced.
        var capped: [ImageFreehandStroke.Point] = []
        for index in 0..<600 {
            capped = ImageSelectionGesture.accumulateLasso(
                capped, candidate: .init(x: Double(index) * 0.01, y: 0),
                minimumSpacing: 0.001, maximumPoints: 64)
        }
        #expect(capped.count == 64)
        // Committed lasso keeps >= 3 distinct points.
        let shape = ImageSelectionGesture.shape(kind: .lasso, operation: .replace,
                                                start: points[0], current: .init(x: 0.6, y: 0.5),
                                                lassoPoints: points)
        #expect((shape?.points.count ?? 0) >= 3)
    }

    // MARK: Ink stroke builder (CUA ended-sample regression)

    @Test("a stroke commits the final touch location, not the second-to-last sample")
    func inkEndSampleIncluded() {
        var builder = InkStrokeBuilder()
        builder.begin(.init(x: 0.10, y: 0.10))
        builder.move(.init(x: 0.20, y: 0.20))
        builder.end(.init(x: 0.30, y: 0.30))
        let points = builder.committedPoints()
        #expect(points?.count == 3)
        #expect(points?.last?.x == 0.30 && points?.last?.y == 0.30,
                "the lifted touch location must be committed")
        #expect(builder.isActive == false)
    }

    @Test("a tap commits a small dot; a cancelled touch discards everything")
    func inkTapAndCancelSemantics() {
        var tap = InkStrokeBuilder()
        tap.begin(.init(x: 0.5, y: 0.5))
        tap.end(.init(x: 0.5, y: 0.5))
        let dot = tap.committedPoints()
        #expect(dot?.count == 2)
        #expect(dot?.first?.x != dot?.last?.x, "tap dot is nudged so the round cap renders")
        var cancelled = InkStrokeBuilder()
        cancelled.begin(.init(x: 0.1, y: 0.1))
        cancelled.move(.init(x: 0.2, y: 0.2))
        cancelled.cancel()
        #expect(cancelled.committedPoints() == nil)
        #expect(cancelled.isActive == false)
    }

    @Test("coalesced samples append in order and spacing filters dense input")
    func inkSampleAccumulation() {
        var builder = InkStrokeBuilder()
        builder.begin(.init(x: 0.0, y: 0.0))
        for index in 1...20 {
            builder.move(.init(x: Double(index) * 0.01, y: 0))
        }
        builder.end(.init(x: 0.21, y: 0))
        #expect(builder.committedPoints()?.count == 22)
        var spaced = InkStrokeBuilder()
        spaced.begin(.init(x: 0.0, y: 0.0))
        spaced.move(.init(x: 0.0001, y: 0), minimumSpacing: 0.005)
        #expect(spaced.committedPoints()?.count == 2, "too-close sample filtered (dot fallback)")
    }

    @Test("move/scale/rotate preserve non-destructive mirroring")    func transformPreservesFlips() {
        let flipped = ImageLayerTransform(centerX: 0.5, centerY: 0.5, scale: 2,
                                          rotationDegrees: 45, flipX: true, flipY: true)
        let moved = flipped.movedBy(dx: 0.1, dy: -0.05)
        #expect(moved.flipX == true && moved.flipY == true)
        #expect(abs(moved.centerX - 0.6) < 0.0001)
        #expect(abs(moved.centerY - 0.45) < 0.0001)
        #expect(moved.scale == 2 && moved.rotationDegrees == 45)
        #expect(flipped.scaled(by: 2).flipX == true)
        #expect(flipped.rotated(byDegrees: -90).flipY == true)
        // Clamping still applies at the edges.
        #expect(flipped.movedBy(dx: 5, dy: -5).centerX == 1)
        #expect(flipped.movedBy(dx: 5, dy: -5).centerY == 0)
    }

    @Test("a known stroke renders at the matching pixels on a 960x540 canvas")
    func strokeRenderingCoordinates() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = MediaProject(kind: .image, name: "Ink",
                                   canvas: MediaCanvas(width: 960, height: 540))
        let stroke = ImageFreehandStroke(
            points: [.init(x: 0.25, y: 0.5), .init(x: 0.75, y: 0.5)],
            width: 8, colorHex: "#FF0000")
        let layer = ImageLayer(kind: .freehand, name: "Ink",
                               freehand: ImageFreehandContent(strokes: [stroke]))
        try MediaTransactions.apply(.addImageLayer(layer), to: &project)
        let renderer = WorkbenchImageRenderer()
        let image = try await renderer.render(project: project,
                                              canvas: CGSize(width: 960, height: 540),
                                              resolveAsset: { _ in nil })
        // The horizontal stroke at normalized y=0.5 must paint the middle row
        // across x=240..720 and leave the top region untouched.
        func sample(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            pixel(image, x: x, y: y)
        }
        var hits = 0
        for x in stride(from: 250, to: 710, by: 40) where sample(x, 270).r > 150 { hits += 1 }
        #expect(hits >= 10, "stroke must render across the expected middle row (hits=\(hits))")
        #expect(sample(480, 100).a < 40, "no ink above the stroke line")
        #expect(sample(100, 270).a < 40, "no ink left of the stroke start")
    }

    @Test("present-but-invalid optional command fields propagate instead of silently no-op")
    func strictOptionalFields() {
        // A malformed adjustment on update_layer must throw, not be ignored.
        #expect(throws: (any Error).self) {
            _ = try decode(["type": "update_layer", "id": UUID().uuidString,
                            "adjustment": "not-an-object"])
        }
        // A malformed text value must throw.
        #expect(throws: (any Error).self) {
            _ = try decode(["type": "update_layer", "id": UUID().uuidString,
                            "text": ["font_size": 12]])  // missing required 'text'
        }
        // A malformed transform must throw.
        #expect(throws: (any Error).self) {
            _ = try decode(["type": "update_layer", "id": UUID().uuidString,
                            "transform": ["center_x": "nope"]])
        }
        // Absent optional fields remain a no-op.
        if case .updateLayer = try! decode(["type": "update_layer", "id": UUID().uuidString]) {
            // ok
        } else {
            Issue.record("expected update_layer")
        }
    }

    // MARK: Enrichment sequencing (review regression)

    private actor EnrichmentRecorder: MediaCommandEnrichmentHost {
        struct MeasureCall: Sendable { var layerIDs: [UUID]; var layerCount: Int }
        var measures: [MeasureCall] = []
        var renders: [Int] = []
        var discarded: [UUID] = []

        func measureLayers(project: MediaProject, layerIDs: [UUID]) async throws -> [LayerNaturalSize] {
            measures.append(MeasureCall(layerIDs: layerIDs, layerCount: project.imageLayers.count))
            return layerIDs.map { LayerNaturalSize(layerID: $0, width: 40, height: 20) }
        }
        func renderMergeAsset(project: MediaProject, layerIDs: [UUID], name: String?) async throws -> MergePreparation {
            renders.append(project.imageLayers.count)
            let asset = MediaAssetReference(kind: .image, relativePath: "staged-\(UUID().uuidString).png",
                                            originalName: "staged.png")
            return MergePreparation(asset: asset,
                                    raster: MergedLayerRaster(assetID: asset.id, width: 200, height: 200))
        }
        func discardStagedAsset(_ asset: MediaAssetReference) async {
            discarded.append(asset.id)
        }
    }

    @Test("enrichment measures/renders against the evolving batch draft, not the original")
    func enrichmentSequencing() async throws {
        let recorder = EnrichmentRecorder()
        var project = MediaProject(kind: .image, name: "P", canvas: MediaCanvas(width: 200, height: 200))
        let a = ImageLayer(kind: .freehand, name: "A",
                           freehand: ImageFreehandContent(strokes: [
                            ImageFreehandStroke(points: [.init(x: 0.1, y: 0.1), .init(x: 0.2, y: 0.2)],
                                                width: 4, colorHex: "#FF0000")]))
        try MediaTransactions.apply(.addImageLayer(a), to: &project)
        let newLayer = ImageLayer(kind: .freehand, name: "B",
                                  freehand: ImageFreehandContent(strokes: [
                                   ImageFreehandStroke(points: [.init(x: 0.5, y: 0.5), .init(x: 0.6, y: 0.6)],
                                                       width: 4, colorHex: "#00FF00")]))
        // Batch: add a layer, then align both, then merge both. Enrichment must
        // see 2 layers for align/merge, not the original 1.
        let commands: [MediaEditCommand] = [
            .addImageLayer(newLayer),
            .alignLayers(ids: [a.id, newLayer.id], alignment: .centerX, naturalSizes: []),
            .mergeLayers(ids: [a.id, newLayer.id], name: "M",
                         raster: MergedLayerRaster(assetID: UUID(), width: 0, height: 0))
        ]
        let enriched = try await MediaCommandEnrichment.enrich(commands, project: project, host: recorder)
        #expect(enriched.count == 4, "add + align + addAsset + merge")
        let measures = await recorder.measures
        #expect(measures.count == 1)
        #expect(measures.first?.layerCount == 2, "align must measure the draft after add_image_layer")
        let renders = await recorder.renders
        #expect(renders == [2], "merge must render the draft containing the new layer")
        let discarded = await recorder.discarded
        #expect(discarded.isEmpty)
        // The enriched asset must be discoverable for rejected-proposal cleanup.
        #expect(MediaCommandEnrichment.stagedAssets(in: enriched).count == 1)
    }

    @Test("an invalid later command discards the staged merge asset (no leaked writes)")
    func enrichmentFailureCleansStagedAssets() async {
        let recorder = EnrichmentRecorder()
        var project = MediaProject(kind: .image, name: "P", canvas: MediaCanvas(width: 200, height: 200))
        let a = ImageLayer(kind: .freehand, name: "A",
                           freehand: ImageFreehandContent(strokes: [
                            ImageFreehandStroke(points: [.init(x: 0.1, y: 0.1), .init(x: 0.2, y: 0.2)],
                                                width: 4, colorHex: "#FF0000")]))
        try? MediaTransactions.apply(.addImageLayer(a), to: &project)
        let commands: [MediaEditCommand] = [
            .mergeLayers(ids: [a.id, UUID()], name: "M",
                         raster: MergedLayerRaster(assetID: UUID(), width: 0, height: 0)),
            .flipLayer(id: a.id, horizontal: true) // merge fails first (missing layer)
        ]
        var threw = false
        do {
            _ = try await MediaCommandEnrichment.enrich(commands, project: project, host: recorder)
        } catch {
            threw = true
        }
        #expect(threw)
        let discarded = await recorder.discarded
        #expect(discarded.count == 1, "the staged raster from the failed merge must be discarded")
    }

    @Test("dynamic capabilities report reflects project kind and workflow")
    func capabilitiesReport() {
        let image = MediaProject(kind: .image, name: "I", canvas: MediaCanvas(width: 100, height: 100))
        let imageCaps = MediaProjectSummaries.capabilities(image)
        #expect(imageCaps.contains("image_commands"))
        #expect(imageCaps.contains("align_layers"))
        #expect(imageCaps.contains("merge_layers"))
        #expect(imageCaps.contains("grant"))
        let video = MediaProject(kind: .video, name: "V")
        let videoCaps = MediaProjectSummaries.capabilities(video)
        #expect(videoCaps.contains("video_commands"))
        #expect(videoCaps.contains("set_cover"))
        #expect(videoCaps.contains("export_presets"))
        #expect(videoCaps.contains("canvas_ready: false"))
    }

    @Test("video export preset yields explicit geometry and rejects mismatches")
    func exportPreset() throws {
        let project = MediaProject(kind: .video, name: "V",
                                   canvas: MediaCanvas(width: 1080, height: 1920, frameRate: 30))
        let args = MediaExportArguments(kind: "video", fileName: "out", format: nil,
                                        width: nil, height: nil, quality: nil,
                                        preserveTransparency: nil, stripMetadata: nil,
                                        codec: "h264", frameRate: nil, preset: "portrait1080p")
        let options = try args.videoOptions(project: project)
        #expect(options.width == 1080 && options.height == 1920)
        #expect(options.frameRate == 30)
        let mismatch = MediaExportArguments(kind: "video", fileName: "out", format: nil,
                                            width: 1280, height: nil, quality: nil,
                                            preserveTransparency: nil, stripMetadata: nil,
                                            codec: "h264", frameRate: nil, preset: "portrait1080p")
        #expect(throws: (any Error).self) { _ = try mismatch.videoOptions(project: project) }
    }

    @Test("selection fill/cut/copy validate and apply through the model")
    func selectionFillCutCopy() throws {
        var project = MediaProject(kind: .image, name: "P", canvas: MediaCanvas(width: 200, height: 200))
        let layer = ImageLayer(kind: .freehand, name: "A",
                               freehand: ImageFreehandContent(strokes: [
                                ImageFreehandStroke(points: [.init(x: 0.2, y: 0.2), .init(x: 0.4, y: 0.4)],
                                                    width: 6, colorHex: "#FF0000")]))
        try MediaTransactions.apply(.addImageLayer(layer), to: &project)
        let rect = ImageSelectionShape(kind: .rectangle,
                                       points: [.init(x: 0.1, y: 0.1), .init(x: 0.5, y: 0.5)])
        let selection = ImageSelection(shapes: [rect])
        try MediaTransactions.apply(.setImageSelection(selection), to: &project)

        // Fill: adds a `.fill` layer masked by the selection.
        try MediaTransactions.apply(.fillSelection(colorHex: "#00FF00", opacity: 0.6, name: nil),
                                    to: &project)
        let fill = try #require(project.imageLayers.last)
        #expect(fill.kind == .fill)
        #expect(fill.fillColorHex == "#00FF00")
        #expect(fill.opacity == 0.6)
        #expect(fill.selectionMask == selection)

        // Fill validation.
        #expect(throws: (any Error).self) {
            try MediaTransactions.apply(.fillSelection(colorHex: "red", opacity: 1, name: nil),
                                        to: &project)
        }
        #expect(throws: (any Error).self) {
            try MediaTransactions.apply(.fillSelection(colorHex: "#00FF00", opacity: 2, name: nil),
                                        to: &project)
        }

        // Cut: one region mask stroke keeping the complete selection snapshot.
        try MediaTransactions.apply(.cutSelection(layerID: layer.id), to: &project)
        let cut = try #require(project.imageLayers.first(where: { $0.id == layer.id }))
        #expect(cut.mask?.strokes.count == 1)
        #expect(cut.mask?.strokes.first?.region == selection)
        #expect(cut.mask?.strokes.first?.restore == false)

        // Copy: raster asset must be registered with a matching hash and
        // full-canvas dimensions.
        let assetID = UUID()
        let badRaster = MergedLayerRaster(assetID: assetID, width: 10, height: 10)
        #expect(throws: (any Error).self) {
            try MediaTransactions.apply(.copySelection(sourceLayerID: layer.id, name: nil,
                                                       raster: badRaster), to: &project)
        }
        let rasterData = Data("copy-png".utf8)
        let hash = FloeDigest.sha256Hex(rasterData)
        let asset = MediaAssetReference(id: assetID, kind: .image, relativePath: "Workbench/Assets/c.png",
                                        originalName: "c.png", byteCount: Int64(rasterData.count),
                                        contentHash: hash)
        try MediaTransactions.apply(.addAsset(asset), to: &project)
        let raster = MergedLayerRaster(assetID: assetID, width: 200, height: 200, contentHash: hash)
        try MediaTransactions.apply(.copySelection(sourceLayerID: layer.id, name: "Copy", raster: raster),
                                    to: &project)
        let copiedIndex = project.imageLayers.firstIndex(where: { $0.name == "Copy" })
        #expect(copiedIndex != nil)
        #expect(project.imageLayers[try #require(copiedIndex)].assetID == assetID)

        // Undo removes the copied layer; cut stroke undo restores pixels.
        #expect(MediaTransactions.undo(&project))
        #expect(project.imageLayers.contains(where: { $0.name == "Copy" }) == false)
    }

    @Test("selection is required for fill/cut/copy")
    func selectionRequired() throws {
        var project = MediaProject(kind: .image, name: "P", canvas: MediaCanvas(width: 100, height: 100))
        let layer = ImageLayer(kind: .freehand, name: "A",
                               freehand: ImageFreehandContent(strokes: [
                                ImageFreehandStroke(points: [.init(x: 0.2, y: 0.2), .init(x: 0.3, y: 0.3)],
                                                    width: 4, colorHex: "#FF0000")]))
        try MediaTransactions.apply(.addImageLayer(layer), to: &project)
        #expect(throws: (any Error).self) {
            try MediaTransactions.apply(.fillSelection(colorHex: "#00FF00", opacity: 1, name: nil),
                                        to: &project)
        }
        #expect(throws: (any Error).self) {
            try MediaTransactions.apply(.cutSelection(layerID: layer.id), to: &project)
        }
        #expect(throws: (any Error).self) {
            try MediaTransactions.apply(.copySelection(sourceLayerID: layer.id, name: nil,
                                                       raster: MergedLayerRaster(assetID: UUID(),
                                                                                  width: 100, height: 100)),
                                        to: &project)
        }
    }
}

// Tiny JSON -> AnyCodableValue bridge for tests.
private enum AnyFixture {
    static func value(_ any: Any) -> AnyCodableValue {
        switch any {
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .boolean(n.boolValue) }
            return .number(n.doubleValue)
        case let d as [String: Any]: return .object(d.mapValues { value($0) })
        case let arr as [Any]: return .array(arr.map { value($0) })
        default: return .null
        }
    }
}
#endif

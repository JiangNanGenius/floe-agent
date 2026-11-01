// SPDX-License-Identifier: MPL-2.0
//
// C03 image closure — source-authored tests (NOT RUN in this source lane).
//
// These tests exercise the shared command engine and the strict verified-raster
// boundary without a device or a platform renderer. The fake host below
// returns a real PNG-header file under a temporary project root; no test
// claims that a device codec produced it.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloeAndroidWorkbench

final class C03MediaLayerTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testFillSelectionIsARealFillLayerAndUndoRestoresIt() async throws {
        var project = makeProject()
        project.imageSelection = fullSelection()
        let before = project.memento()
        let planned = try await C03LayerOperationPlanner.plan(
            .fillSelection(colorHex: "#FF3B30", opacity: 0.8, name: "Fill"),
            project: project,
            host: FakeLayerRasterHost(project: project))
        XCTAssertEqual(planned.commands.count, 1)
        try C03LayerOperationPlanner.apply(planned, to: &project)
        XCTAssertEqual(project.imageLayers.count, 1)
        XCTAssertEqual(project.imageLayers[0].kind, .fill)
        XCTAssertEqual(project.imageLayers[0].fillColorHex, "#FF3B30")
        XCTAssertEqual(project.imageLayers[0].selectionMask, fullSelection())
        XCTAssertEqual(project.imageLayers[0].opacity, 0.8, accuracy: 0.0001)
        XCTAssertEqual(project.revision, 1)
        var undone = project
        XCTAssertTrue(MediaTransactions.undo(&undone))
        // Undo advances the revision but restores the editable state exactly.
        XCTAssertEqual(undone.imageLayers, before.imageLayers)
        XCTAssertEqual(undone.assets, before.assets)
        XCTAssertEqual(undone.imageSelection, before.imageSelection)
    }

    func testCutSelectionIsOneReversibleRegionMaskStroke() async throws {
        var project = makeProject()
        project.imageSelection = fullSelection()
        let layer = ImageLayer(kind: .fill, name: "Base", fillColorHex: "#000000",
                               selectionMask: fullSelection())
        try MediaTransactions.apply(.addImageLayer(layer), to: &project)
        var beforeCut = project
        let planned = try await C03LayerOperationPlanner.plan(
            .cutSelection(layerID: layer.id),
            project: project,
            host: FakeLayerRasterHost(project: project))
        XCTAssertEqual(planned.commands.count, 1)
        try C03LayerOperationPlanner.apply(planned, to: &project)
        let mask = try XCTUnwrap(project.imageLayers[0].mask)
        XCTAssertEqual(mask.strokes.count, 1)
        XCTAssertNotNil(mask.strokes[0].region)
        XCTAssertEqual(mask.strokes[0].points.count, 0)
        // A later ordinary mask edit must validate against the accumulated
        // region stroke instead of failing on its intentionally empty points.
        let later = ImageMaskStroke(
            points: [.init(x: 0.1, y: 0.1), .init(x: 0.2, y: 0.2)],
            width: 12)
        try MediaTransactions.apply(
            .addLayerMaskStroke(id: layer.id, stroke: later), to: &project)
        XCTAssertEqual(project.imageLayers[0].mask?.strokes.count, 2)
        var undone = project
        XCTAssertTrue(MediaTransactions.undo(&undone))
        XCTAssertEqual(undone.imageLayers, beforeCut.imageLayers)
    }

    func testCopyAndMergeUseOnlyRendererStagedAssetsAndCommitAtomically() async throws {
        var project = makeProject()
        project.imageSelection = fullSelection()
        let bottom = ImageLayer(kind: .fill, name: "Bottom", fillColorHex: "#000000",
                                selectionMask: fullSelection())
        let top = ImageLayer(kind: .fill, name: "Top", fillColorHex: "#FFFFFF",
                             selectionMask: fullSelection())
        try MediaTransactions.apply(
            [.addImageLayer(bottom), .addImageLayer(top)], to: &project)
        let host = FakeLayerRasterHost(project: project)
        let copy = try await C03LayerOperationPlanner.plan(
            .copySelection(sourceLayerID: top.id, name: "Copy"), project: project, host: host)
        XCTAssertEqual(copy.commands.count, 2)
        XCTAssertTrue(copy.commands[0].isAddAsset)
        XCTAssertTrue(copy.commands[1].isCopySelection)
        XCTAssertEqual(copy.stagedAssets.count, 1)
        var copied = project
        try C03LayerOperationPlanner.apply(copy, to: &copied)
        XCTAssertEqual(copied.assets.count, project.assets.count + 1)
        XCTAssertEqual(copied.imageLayers.count, project.imageLayers.count + 1)

        let merge = try await C03LayerOperationPlanner.plan(
            .mergeLayers(ids: [bottom.id, top.id], name: "Merged"),
            project: project,
            host: host)
        XCTAssertEqual(merge.commands.count, 2)
        XCTAssertTrue(merge.commands[0].isAddAsset)
        XCTAssertTrue(merge.commands[1].isMergeLayers)
        var merged = project
        try C03LayerOperationPlanner.apply(merge, to: &merged)
        XCTAssertEqual(merged.imageLayers.count, 1)
        XCTAssertEqual(merged.imageLayers[0].kind, .image)
        XCTAssertEqual(merged.assets.count, project.assets.count + 1)
    }

    func testRasterVerifierAcceptsOnlyFullCanvasOwnedPngBytes() throws {
        let root = makeRoot()
        let data = pngHeader(width: 64, height: 48)
        let assetID = UUID()
        let relative = "Workbench/Assets/\(assetID)-merged.png"
        let target = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        let hash = FloeDigest.sha256Hex(data)
        let project = makeProject(canvas: MediaCanvas(width: 64, height: 48))
        let good = MergePreparation(
            asset: MediaAssetReference(
                id: assetID, kind: .image, relativePath: relative,
                originalName: "merged.png", byteCount: Int64(data.count), contentHash: hash),
            raster: MergedLayerRaster(assetID: assetID, width: 64, height: 48, contentHash: hash))
        let verified = try C03LayerRasterVerifier.verify(good, project: project, root: root)
        XCTAssertEqual(verified.width, 64)
        XCTAssertEqual(verified.height, 48)
        XCTAssertEqual(verified.sha256, hash)

        let traversal = MergePreparation(
            asset: MediaAssetReference(
                id: assetID, kind: .image, relativePath: "../outside.png",
                originalName: "outside.png", byteCount: Int64(data.count), contentHash: hash),
            raster: MergedLayerRaster(assetID: assetID, width: 64, height: 48, contentHash: hash))
        XCTAssertThrowsError(
            try C03LayerRasterVerifier.verify(traversal, project: project, root: root))

        let wrongHash = MergePreparation(
            asset: MediaAssetReference(
                id: assetID, kind: .image, relativePath: relative,
                originalName: "merged.png", byteCount: Int64(data.count),
                contentHash: String(repeating: "0", count: 64)),
            raster: MergedLayerRaster(assetID: assetID, width: 64, height: 48, contentHash: hash))
        XCTAssertThrowsError(
            try C03LayerRasterVerifier.verify(wrongHash, project: project, root: root))

        let wrongDimensions = MergePreparation(
            asset: MediaAssetReference(
                id: assetID, kind: .image, relativePath: relative,
                originalName: "merged.png", byteCount: Int64(data.count), contentHash: hash),
            raster: MergedLayerRaster(assetID: assetID, width: 32, height: 24, contentHash: hash))
        XCTAssertThrowsError(
            try C03LayerRasterVerifier.verify(wrongDimensions, project: project, root: root))
    }

    private func makeProject(canvas: MediaCanvas = MediaCanvas(width: 8, height: 8)) -> MediaProject {
        MediaProject(kind: .image, name: "C03 test", canvas: canvas)
    }

    private func makeRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("c03-layer-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func fullSelection() -> ImageSelection {
        ImageSelection(shapes: [
            ImageSelectionShape(
                kind: .rectangle,
                operation: .replace,
                points: [.init(x: 0, y: 0), .init(x: 1, y: 1)]),
        ])
    }

    private func pngHeader(width: Int, height: Int) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var length = UInt32(13).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append("IHDR".data(using: .ascii)!)
        var w = UInt32(width).bigEndian
        var h = UInt32(height).bigEndian
        data.append(Data(bytes: &w, count: 4))
        data.append(Data(bytes: &h, count: 4))
        data.append(contentsOf: [8, 6, 0, 0, 0])
        data.append(contentsOf: [0, 0, 0, 0])
        return data
    }
}

private final class FakeLayerRasterHost: MediaCommandEnrichmentHost, @unchecked Sendable {
    private let project: MediaProject

    init(project: MediaProject) { self.project = project }

    func measureLayers(project: MediaProject, layerIDs: [UUID]) async throws -> [LayerNaturalSize] {
        try layerIDs.map { id in
            guard project.imageLayers.contains(where: { $0.id == id }) else {
                throw FloeError.notFound("layer \(id)")
            }
            return LayerNaturalSize(layerID: id, width: 8, height: 8)
        }
    }

    func renderMergeAsset(project: MediaProject, layerIDs: [UUID], name: String?) async throws -> MergePreparation {
        try preparation(suffix: "merge", project: project)
    }

    func renderCopySelectionAsset(project: MediaProject, sourceLayerID: UUID) async throws -> MergePreparation {
        try preparation(suffix: "copy", project: project)
    }

    private func preparation(suffix: String, project: MediaProject) throws -> MergePreparation {
        guard let canvas = project.canvas else { throw FloeError.validationFailed("no canvas") }
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let hash = FloeDigest.sha256Hex(data)
        let assetID = UUID()
        let asset = MediaAssetReference(
            id: assetID,
            kind: .image,
            relativePath: "Workbench/Assets/\(assetID)-\(suffix).png",
            originalName: "\(suffix).png",
            byteCount: Int64(data.count),
            contentHash: hash)
        return MergePreparation(
            asset: asset,
            raster: MergedLayerRaster(
                assetID: assetID, width: canvas.width, height: canvas.height, contentHash: hash))
    }
}

private extension MediaEditCommand {
    var isAddAsset: Bool {
        if case .addAsset(_) = self { return true }
        return false
    }
    var isCopySelection: Bool {
        if case .copySelection(_, _, _) = self { return true }
        return false
    }
    var isMergeLayers: Bool {
        if case .mergeLayers(_, _, _) = self { return true }
        return false
    }
}

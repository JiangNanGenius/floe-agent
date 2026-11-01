//
//  CADViewOverlayTests.swift
//  FloeCADKitTests
//
//  X22 — section cut and measurement guides share one persisted authority and
//  the same view state reaches Edit, Present, screenshots and export.
//
//  Real inputs: production `FloeCADDocument`, `sceneSnapshot()`,
//  `CADPresentationSceneBuilder`, `CADPresentationEntityBuilder` (real
//  RealityKit stage), the actual offscreen Metal `captureViewportPNG`, the real
//  exchange coverage receipt and the real animation export entry point. The
//  pure model/clip tests are separate so a failure names the exact layer.
//

import XCTest
import CoreGraphics
import ImageIO
import simd

#if canImport(UIKit) && canImport(RealityKit)
import RealityKit
import SwiftUI
import UIKit
@testable import FloeCAD

// MARK: - Pure values

@MainActor
final class CADViewOverlayValueTests: XCTestCase {

    func testSectionFrameSanitizesAndFlipReversesKeptSide() {
        let view = CADSectionView(origin: SIMD3(10, 20, 30),
                                  xAxis: SIMD3(1, 0, 0),
                                  yAxis: SIMD3(0, 0, -1))
        let clean = try? XCTUnwrap(view.sanitized)
        guard let clean else { return XCTFail("valid section refused") }
        XCTAssertEqual(simd_length(clean.normal), 1, accuracy: 1e-9)
        XCTAssertEqual(simd_dot(clean.normal, clean.xAxisVector), 0, accuracy: 1e-9)
        XCTAssertEqual(simd_dot(clean.xAxisVector, clean.yAxisVector), 0, accuracy: 1e-9)
        var flipped = view
        flipped.flipped = true
        XCTAssertEqual(simd_dot(flipped.sanitized!.keepNormal, clean.keepNormal),
                       -1, accuracy: 1e-9)
        var degenerate = view
        degenerate.yAxis = view.xAxis
        XCTAssertNil(degenerate.sanitized,
                     "a degenerate frame is refused, never silently rotated")
    }

    func testMeasurementValidationAndBoundedOverlay() {
        let annotation = CADMeasurementAnnotation(start: SIMD3(0, 0, 0),
                                                  end: SIMD3(30, 40, 0))
        XCTAssertEqual(annotation.lengthMM, 50, accuracy: 1e-9)
        XCTAssertNil(CADMeasurementAnnotation(start: SIMD3(4, 4, 4),
                                              end: SIMD3(4, 4, 4)).sanitized)
        XCTAssertNil(CADMeasurementAnnotation(start: SIMD3(.nan, 0, 0),
                                              end: SIMD3(1, 0, 0)).sanitized)

        var overlay = CADViewOverlayState(section: CADSectionView(
            origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, -1)),
            measurements: [annotation, annotation])
        XCTAssertEqual(overlay.sanitized.measurements.count, 1,
                       "duplicate annotation ids are dropped")
        overlay.showsMeasurements = false
        XCTAssertTrue(overlay.visibleMeasurements.isEmpty)
        XCTAssertTrue(overlay.hasViewOnlyContent,
                      "hidden guides remain authored content")
        let many = (0..<(CADMeasurementAnnotation.maximumCount + 3)).map { index in
            CADMeasurementAnnotation(start: SIMD3(Double(index), 0, 0),
                                     end: SIMD3(Double(index) + 10, 0, 0))
        }
        XCTAssertEqual(CADViewOverlayState(measurements: many).sanitized
                        .measurements.count,
                       CADMeasurementAnnotation.maximumCount)
    }

    func testOldOverlayPayloadDecodesWithHistoricalDefaults() throws {
        let empty = try JSONDecoder().decode(
            CADViewOverlayState.self, from: Data("{}".utf8))
        XCTAssertNil(empty.section)
        XCTAssertTrue(empty.measurements.isEmpty)
        XCTAssertTrue(empty.showsMeasurements)
        XCTAssertFalse(empty.hasVisibleContent)

        let sparseSection = try JSONDecoder().decode(
            CADSectionView.self,
            from: Data(#"{"origin":[1,2,3],"xAxis":[1,0,0],"yAxis":[0,0,-1]}"#.utf8))
        XCTAssertTrue(sparseSection.enabled)
        XCTAssertFalse(sparseSection.flipped)
        XCTAssertEqual(sparseSection.schemaVersion,
                       CADSectionView.currentSchemaVersion)
    }

    func testOutputContractNeverClaimsExchangeCarriesViewState() {
        XCTAssertTrue(CADViewOverlayOutput.screenshot.carriesSectionCut)
        XCTAssertTrue(CADViewOverlayOutput.video.carriesMeasurementGuides)
        XCTAssertTrue(CADViewOverlayOutput.pngSequence.carriesSectionCut)
        for output in [CADViewOverlayOutput.step, .iges, .glb, .usdz,
                       .obj, .stl, .threeMF] {
            XCTAssertFalse(output.carriesSectionCut)
            XCTAssertFalse(output.carriesMeasurementGuides)
        }
        let overlay = CADViewOverlayState(
            section: CADSectionView(origin: .zero,
                                    xAxis: SIMD3(1, 0, 0),
                                    yAxis: SIMD3(0, 0, -1)),
            measurements: [CADMeasurementAnnotation(start: .zero,
                                                    end: SIMD3(10, 0, 0))])
        let notice = CADViewOverlayOutput.viewOnlyNotice(for: .step,
                                                         overlay: overlay)
        XCTAssertTrue(notice?.contains("STEP") == true)
        XCTAssertTrue(notice?.contains("not included") == true)
        XCTAssertNil(CADViewOverlayOutput.viewOnlyNotice(
            for: .glb, overlay: .empty))
        XCTAssertNil(CADViewOverlayOutput.viewOnlyNotice(
            for: .screenshot, overlay: overlay))
    }

    func testMeshClipKeepsOnlyTheKeptHalfAndSplitsCutTriangles() {
        let cube = Self.cubeMesh()
        let plane = CADSectionClipPlane(origin: SIMD3(1, 0, 0),
                                        normal: SIMD3(1, 0, 0))
        let clipped = CADSectionMeshClip.clip(
            positions: cube.positions, normals: cube.normals,
            uvs: cube.uvs, authoredUVs: cube.uvs,
            indices: cube.indices, plane: plane)
        let value = try? XCTUnwrap(clipped)
        guard let value else { return XCTFail("cube was not clipped") }
        XCTAssertFalse(value.isFullyClipped)
        XCTAssertEqual(value.removedTriangleCount, 2,
                       "only the -X face is entirely on the cut side")
        XCTAssertEqual(value.indices.count % 3, 0)
        XCTAssertEqual(value.normals.count, value.positions.count)
        XCTAssertEqual(value.uvs?.count, value.positions.count)
        XCTAssertEqual(value.authoredUVs?.count, value.positions.count)
        for index in value.indices {
            XCTAssertLessThan(Int(index), value.positions.count)
            XCTAssertGreaterThanOrEqual(value.positions[Int(index)].x, 0.999_9)
        }
        XCTAssertEqual(CADSectionMeshClip.clip(
            positions: cube.positions, normals: cube.normals,
            uvs: cube.uvs, authoredUVs: cube.uvs,
            indices: cube.indices, plane: plane), value,
            "the clip is deterministic")

        XCTAssertNil(CADSectionMeshClip.clip(
            positions: cube.positions, normals: cube.normals,
            uvs: cube.uvs, indices: cube.indices,
            plane: CADSectionClipPlane(origin: SIMD3(-1, 0, 0),
                                       normal: SIMD3(1, 0, 0))),
            "an untouched mesh keeps its original resource")
        XCTAssertEqual(CADSectionMeshClip.clip(
            positions: cube.positions, normals: cube.normals,
            uvs: cube.uvs, indices: cube.indices,
            plane: CADSectionClipPlane(origin: SIMD3(3, 0, 0),
                                       normal: SIMD3(1, 0, 0)))?.isFullyClipped,
            true)
    }

    func testGuideSegmentsAreClippedLikeTheViewport() {
        let plane = CADSectionClipPlane(origin: SIMD3(1, 0, 0),
                                        normal: SIMD3(1, 0, 0))
        let kept = CADSectionMeshClip.clipSegment(
            SIMD3(0, 1, 1), SIMD3(2, 1, 1), plane: plane)
        XCTAssertNotNil(kept)
        XCTAssertEqual(Double(kept!.0.x), 1, accuracy: 1e-6)
        XCTAssertEqual(Double(kept!.1.x), 2, accuracy: 1e-6)
        XCTAssertNil(CADSectionMeshClip.clipSegment(
            SIMD3(0, 1, 1), SIMD3(0.5, 1, 1), plane: plane))
    }

    func testClipOutcomeDistinguishesUnchangedRemovedInvalidAndCancelled() {
        let cube = Self.cubeMesh()
        let unchanged = CADSectionMeshClip.outcome(
            positions: cube.positions, normals: cube.normals, uvs: cube.uvs,
            authoredUVs: cube.uvs, indices: cube.indices,
            plane: CADSectionClipPlane(origin: SIMD3(-1, 0, 0),
                                       normal: SIMD3(1, 0, 0)))
        XCTAssertEqual(unchanged, .unchanged,
                       "an all-kept mesh keeps its original resource")

        let removed = CADSectionMeshClip.outcome(
            positions: cube.positions, normals: cube.normals, uvs: cube.uvs,
            authoredUVs: cube.uvs, indices: cube.indices,
            plane: CADSectionClipPlane(origin: SIMD3(3, 0, 0),
                                       normal: SIMD3(1, 0, 0)))
        guard case .clipped(let fully) = removed else {
            return XCTFail("a fully cut-away mesh is a clipped result, not unchanged")
        }
        XCTAssertTrue(fully.isFullyClipped)
        XCTAssertTrue(fully.indices.isEmpty)

        XCTAssertEqual(CADSectionMeshClip.outcome(
            positions: cube.positions, normals: cube.normals, uvs: cube.uvs,
            indices: cube.indices,
            plane: CADSectionClipPlane(origin: .zero, normal: .zero)),
            .invalid(.invalidPlane),
            "an invalid plane is never reported as unchanged")
        XCTAssertEqual(CADSectionMeshClip.outcome(
            positions: cube.positions, normals: cube.normals, uvs: cube.uvs,
            indices: [UInt32(999)],
            plane: CADSectionClipPlane(origin: SIMD3(1, 0, 0),
                                       normal: SIMD3(1, 0, 0))),
            .invalid(.invalidIndices),
            "corrupt indices are reported, never silently dropped")

        var checks = 0
        XCTAssertEqual(CADSectionMeshClip.outcome(
            positions: cube.positions, normals: cube.normals, uvs: cube.uvs,
            indices: cube.indices,
            plane: CADSectionClipPlane(origin: SIMD3(1, 0, 0),
                                       normal: SIMD3(1, 0, 0)),
            shouldCancel: { checks += 1; return true }),
            .cancelled)
        XCTAssertGreaterThan(checks, 0)
    }

    func testClipCompactsAndPreservesGroupUVs() throws {
        let cube = Self.cubeMesh()
        // One authoritative face group: four vertices, six indices.
        let groupIndices = Array(cube.indices.prefix(6))
        let groupUVs = cube.uvs.map { SIMD2($0.x * 3, $0.y * 5) }
        let outcome = CADSectionMeshClip.outcome(
            positions: cube.positions, normals: cube.normals,
            uvs: groupUVs, authoredUVs: cube.uvs,
            indices: groupIndices,
            plane: CADSectionClipPlane(origin: SIMD3(1, 0, 0),
                                       normal: SIMD3(1, 0, 0)))
        guard case .clipped(let value) = outcome else {
            return XCTFail("the face group must be clipped, not unchanged")
        }
        XCTAssertLessThan(value.positions.count, cube.positions.count,
                          "a face group must not copy the whole body vertex array")
        XCTAssertEqual(value.normals.count, value.positions.count)
        XCTAssertEqual(value.uvs?.count, value.positions.count)
        XCTAssertEqual(value.authoredUVs?.count, value.positions.count)
        let groupUVCount = try XCTUnwrap(value.uvs).count
        XCTAssertEqual(groupUVCount, value.positions.count,
                       "the face material's own UV set follows the cut vertices")
        for index in value.indices {
            XCTAssertLessThan(Int(index), value.positions.count)
            XCTAssertGreaterThanOrEqual(value.positions[Int(index)].x, 0.999_9)
        }
    }

    func testRasterAndExchangePreWriteContracts() {
        let section = CADSectionView(origin: SIMD3(20, 0, 0),
                                     xAxis: SIMD3(0, 1, 0),
                                     yAxis: SIMD3(0, 0, 1))
        let measurement = CADMeasurementAnnotation(
            start: SIMD3(5, 15, 0), end: SIMD3(35, 15, 0))
        let overlay = CADViewOverlayState(section: section,
                                          measurements: [measurement])
        for output in [CADViewOverlayOutput.screenshot, .video, .pngSequence] {
            let notice = CADViewOverlayOutput.numericTextNotice(
                for: output, overlay: overlay)
            XCTAssertNotNil(notice)
            XCTAssertTrue(notice?.contains("not drawn") == true)
        }
        XCTAssertNil(CADViewOverlayOutput.numericTextNotice(
            for: .screenshot, overlay: .empty),
            "an ordinary capture gets no numeric-text warning")
        XCTAssertNil(CADViewOverlayOutput.numericTextNotice(
            for: .screenshot,
            overlay: CADViewOverlayState(section: section, measurements: [])),
            "a section-only capture has no numeric value to omit")
        for output in [CADViewOverlayOutput.step, .iges, .glb, .usdz,
                       .obj, .stl, .threeMF] {
            let notice = CADViewOverlayOutput.viewOnlyNotice(
                for: output, overlay: overlay)
            XCTAssertNotNil(notice)
            XCTAssertTrue(notice?.contains("not included") == true)
        }
        XCTAssertNil(CADViewOverlayOutput.viewOnlyNotice(
            for: .stl, overlay: .empty))
    }

    func testBodyLocalPlaneUsesTheActualTransform() {
        let transform = simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0), SIMD4(10, 0, 0, 1)))
        let plane = CADSectionMeshClip.plane(
            originMM: SIMD3(10_500, 0, 0), normalMM: SIMD3(1, 0, 0),
            transform: transform)
        XCTAssertNotNil(plane)
        XCTAssertEqual(Double(plane!.origin.x), 0.5, accuracy: 1e-5)
        XCTAssertEqual(Double(plane!.normal.x), 1, accuracy: 1e-5)
    }

    static func cubeMesh() -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>],
                               uvs: [SIMD2<Float>], indices: [UInt32]) {
        let corners = [
            SIMD3<Float>(0, 0, 0), SIMD3<Float>(2, 0, 0),
            SIMD3<Float>(2, 2, 0), SIMD3<Float>(0, 2, 0),
            SIMD3<Float>(0, 0, 2), SIMD3<Float>(2, 0, 2),
            SIMD3<Float>(2, 2, 2), SIMD3<Float>(0, 2, 2),
        ]
        let faces: [(Int, Int, Int, Int, SIMD3<Float>)] = [
            (0, 3, 2, 1, SIMD3(0, 0, -1)),
            (4, 5, 6, 7, SIMD3(0, 0, 1)),
            (0, 4, 7, 3, SIMD3(-1, 0, 0)),
            (1, 2, 6, 5, SIMD3(1, 0, 0)),
            (0, 1, 5, 4, SIMD3(0, -1, 0)),
            (3, 7, 6, 2, SIMD3(0, 1, 0)),
        ]
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        for (a, b, c, d, normal) in faces {
            let base = UInt32(positions.count)
            for (index, corner) in [a, b, c, d].enumerated() {
                positions.append(corners[corner])
                normals.append(normal)
                uvs.append(SIMD2(Float(index % 2), Float(index / 2)))
            }
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return (positions, normals, uvs, indices)
    }
}

// MARK: - Document authority

@MainActor
final class CADViewOverlayDocumentTests: XCTestCase {

    func testOverlayPersistsReopensAndRoundTripsOldSettings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADViewOverlay-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await makeBoxDocument(in: root)

        XCTAssertEqual(document.viewOverlayState, .empty,
                       "an ordinary model has no overlay")
        let section = CADSectionView(origin: SIMD3(20, 0, 0),
                                     xAxis: SIMD3(0, 1, 0),
                                     yAxis: SIMD3(0, 0, 1))
        XCTAssertTrue(document.setSectionView(section))
        let annotation = try document.addMeasurementAnnotation(
            from: SIMD3(5, 15, 0), to: SIMD3(35, 15, 0))
        XCTAssertEqual(document.viewOverlayState.measurements.count, 1)

        // The snapshot is the shared Presentation input, not a UI cache.
        let snapshot = document.sceneSnapshot()
        XCTAssertEqual(snapshot.viewOverlay.activeSection?.origin,
                       [20.0, 0, 0])
        XCTAssertEqual(snapshot.viewOverlay.visibleMeasurements.count, 1)
        XCTAssertEqual(snapshot.viewOverlay.visibleMeasurements.first?.id,
                       annotation.id)

        // Save/reopen keeps the exact authored values; the camera/env fields
        // are untouched and still decode.
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        let url = document.url
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        XCTAssertEqual(reopened.viewOverlayState.section?.origin, [20.0, 0, 0])
        XCTAssertEqual(reopened.viewOverlayState.measurements.count, 1)
        XCTAssertTrue(reopened.viewOverlayState.showsMeasurements)
        XCTAssertEqual(reopened.sceneSnapshot().viewOverlay,
                       reopened.viewOverlayState)
    }

    func testOldSettingsWithoutOverlayDecodeAndEncodeAdditively() throws {
        let legacy = CADSceneSettings(
            camera: CADSceneSettings.Camera(
                azimuthRadians: 0.4, elevationRadians: 0.2, distance: 300,
                targetX: 1, targetY: 2, targetZ: 3, fovYDegrees: 40,
                isOrthographic: true),
            showsGrid: false)
        let legacyData = try JSONEncoder().encode(legacy)
        XCTAssertEqual(CADViewOverlayCodec.decode(legacyData), .empty)

        let overlay = CADViewOverlayState(
            section: CADSectionView(origin: .zero,
                                    xAxis: SIMD3(1, 0, 0),
                                    yAxis: SIMD3(0, 0, -1)))
        let updated = try XCTUnwrap(
            CADViewOverlayCodec.settingsData(legacyData, applying: overlay))
        let decoded = try JSONDecoder().decode(CADSceneSettings.self, from: updated)
        XCTAssertEqual(decoded.camera?.isOrthographic, true)
        XCTAssertEqual(decoded.camera?.distance, 300)
        XCTAssertEqual(decoded.showsGrid, false)
        XCTAssertNotNil(decoded.viewOverlay?.section)
        XCTAssertEqual(decoded.schemaVersion, CADSceneSettings.currentSchemaVersion)

        // Clearing the overlay removes the key again; the historical fields
        // remain exactly representable.
        let cleared = try XCTUnwrap(
            CADViewOverlayCodec.settingsData(updated, applying: .empty))
        let clearedSettings = try JSONDecoder().decode(CADSceneSettings.self,
                                                       from: cleared)
        XCTAssertNil(clearedSettings.viewOverlay)
        XCTAssertEqual(clearedSettings.camera?.distance, 300)
    }

    func testUndoAndGeometryEditKeepOverlayIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADViewOverlayUndo-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await makeBoxDocument(in: root)
        let empty = document.viewOverlayState
        let section = CADSectionView(origin: SIMD3(20, 0, 0),
                                     xAxis: SIMD3(0, 1, 0),
                                     yAxis: SIMD3(0, 0, 1))
        XCTAssertTrue(document.setSectionView(section))
        let withSection = document.viewOverlayState
        XCTAssertNotEqual(withSection, empty)

        document.session.undo()
        XCTAssertEqual(document.viewOverlayState, empty,
                       "the section edit is one ordinary undo step")
        document.session.redo()
        XCTAssertEqual(document.viewOverlayState, withSection)

        let body = try XCTUnwrap(document.session.document.bodies.first)
        let beforeHidden = body.isHidden
        document.session.perform(SetItemVisibilityCommand(
            item: .body(body.id), isHidden: true))
        XCTAssertTrue(document.viewOverlayState.activeSection != nil,
                      "an edit does not create or move the section")
        document.session.undo()
        XCTAssertEqual(document.session.document.body(with: body.id)?.isHidden,
                       beforeHidden)
        XCTAssertEqual(document.viewOverlayState, withSection,
                       "cancel/undo leaves the overlay byte-identical")
    }

    func testSectionCancelRemovesOnlyTheCutNotGeometryOrGuides() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADViewOverlayCancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await makeBoxDocument(in: root)
        defer { document.close() }
        let bodyCount = document.summary().bodyCount
        let positionsBefore = document.session.document.bodies.map(\.render.positions)
        XCTAssertTrue(document.setSectionView(CADSectionView(
            origin: SIMD3(20, 0, 0), xAxis: SIMD3(0, 1, 0),
            yAxis: SIMD3(0, 0, 1))))
        _ = try document.addMeasurementAnnotation(
            from: SIMD3(5, 15, 0), to: SIMD3(35, 15, 0))

        // The native Section Off badge routes through the same live state the
        // editor uses; cancel must remove only the cut.
        let model = document.viewModel()
        XCTAssertNotNil(model.sectionState)
        model.endSection()
        XCTAssertNil(document.viewOverlayState.section,
                     "Section Off removes the persisted cut")
        XCTAssertEqual(document.viewOverlayState.measurements.count, 1,
                       "saved measurements are independent of the section")
        XCTAssertEqual(document.summary().bodyCount, bodyCount)
        XCTAssertEqual(document.session.document.bodies.map(\.render.positions),
                       positionsBefore,
                       "cancelling the section never edits geometry")
    }

    func testExchangeReceiptStatesViewOnlyOmission() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADViewOverlayExchange-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await makeBoxDocument(in: root)
        defer { document.close() }
        XCTAssertTrue(document.setSectionView(CADSectionView(
            origin: SIMD3(20, 0, 0), xAxis: SIMD3(0, 1, 0),
            yAxis: SIMD3(0, 0, 1))))
        _ = try document.addMeasurementAnnotation(
            from: SIMD3(5, 15, 0), to: SIMD3(35, 15, 0))

        for format in ["glb", "step"] {
            let coverage = try document.exchangeCoverage(
                format: format, selection: CADExchangeSelection()).get()
            XCTAssertTrue(coverage.notes.contains {
                $0.localizedCaseInsensitiveContains(format)
                    && $0.contains("not included")
            }, "\(format) receipt must state the view-only omission: \(coverage.notes)")
        }
        document.clearMeasurementAnnotations()
        document.removeSectionView()
        let clean = try document.exchangeCoverage(
            format: "glb", selection: CADExchangeSelection()).get()
        XCTAssertFalse(clean.notes.contains { $0.contains("not included") },
                       "an ordinary model gets no gratuitous omission note")
    }

    func testPartAnimationExportRefusesSectionInsteadOfMovingTheCut() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADViewOverlayAnimation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await makeBoxDocument(in: root)
        defer { document.close() }
        XCTAssertTrue(document.setSectionView(CADSectionView(
            origin: SIMD3(20, 0, 0), xAxis: SIMD3(0, 1, 0),
            yAxis: SIMD3(0, 0, 1))))

        let instanceID = UUID()
        var clip = CADAnimationClip(name: "Part move", duration: 2)
        clip.tracks = [CADAnimationTrack(target: .instance(instanceID), keyframes: [
            CADAnimationKeyframe(time: 0, instance: CADAnimationInstanceValue()),
            CADAnimationKeyframe(time: 2, instance: CADAnimationInstanceValue(
                translationMM: SIMD3(10, 0, 0))),
        ])]
        let animation = CADAnimationDocument(clips: [clip])
        document.session.perform(SetAnimationDataCommand(
            before: document.session.document.animationData,
            after: try JSONEncoder().encode(animation)))
        XCTAssertEqual(document.animationLoadState().activeClip?.instanceTracks.count, 1)

        XCTAssertThrowsError(try document.startAnimationExport(
            to: root.appendingPathComponent("part.mp4"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Part animation"),
                          error.localizedDescription)
        }
    }

    func testSceneServiceWritesTheExistingSceneSettingsAndUndo() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADViewOverlayService-\(UUID())")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await makeBoxDocument(in: root)
        defer { document.close() }
        let service = CADViewOverlayService(document: document)
        let geometryBefore = document.session.document.bodies.map(\.render.positions)

        let read = service.handle(action: "get", args: [:])
        XCTAssertEqual(read["ok"] as? Bool, true)
        XCTAssertEqual((read["view_overlay"] as? [String: Any])?["section_authored"] as? Bool,
                       false)

        let set = service.handle(action: "setSection", args: [
            "origin": [20.0, 0.0, 0.0],
            "normal": [1.0, 0.0, 0.0],
            "enabled": true,
        ])
        XCTAssertEqual(set["ok"] as? Bool, true, "\(set)")
        XCTAssertEqual(set["mutated"] as? Bool, true)
        XCTAssertTrue(document.viewOverlayState.activeSection != nil)
        XCTAssertEqual(document.session.document.bodies.map(\.render.positions),
                       geometryBefore, "a view overlay never edits geometry")

        let added = service.handle(action: "addMeasurement", args: [
            "start": [5.0, 15.0, 0.0], "end": [35.0, 15.0, 0.0],
        ])
        XCTAssertEqual(added["ok"] as? Bool, true, "\(added)")
        XCTAssertEqual(added["mutated"] as? Bool, true)
        XCTAssertEqual(document.viewOverlayState.measurements.count, 1)
        let measurement = try XCTUnwrap(document.viewOverlayState.measurements.first)
        XCTAssertEqual(measurement.lengthMM, 30, accuracy: 1e-9)

        let undoMeasurement = service.handle(action: "undo", args: [:])
        XCTAssertEqual(undoMeasurement["ok"] as? Bool, true, "\(undoMeasurement)")
        XCTAssertTrue(document.viewOverlayState.measurements.isEmpty)
        XCTAssertTrue(document.viewOverlayState.activeSection != nil)
        let undoSection = service.handle(action: "undo", args: [:])
        XCTAssertEqual(undoSection["ok"] as? Bool, true, "\(undoSection)")
        XCTAssertNil(document.viewOverlayState.section)
        let redo = service.handle(action: "redo", args: [:])
        XCTAssertEqual(redo["ok"] as? Bool, true)
        XCTAssertTrue(document.viewOverlayState.activeSection != nil)
    }

    func testSceneServiceRefusesClosedDocumentAndStaleRevision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADViewOverlayClosed-\(UUID())")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await makeBoxDocument(in: root)
        let service = CADViewOverlayService(document: document)
        let stale = service.handle(action: "setSection", args: [
            "origin": [20.0, 0.0, 0.0], "normal": [1.0, 0.0, 0.0],
            "revision": -1,
        ])
        XCTAssertEqual(stale["ok"] as? Bool, false)
        XCTAssertEqual(stale["error"] as? String, "revision_mismatch")
        XCTAssertNil(document.viewOverlayState.section)

        document.close()
        let closed = service.handle(action: "setSection", args: [
            "origin": [20.0, 0.0, 0.0], "normal": [1.0, 0.0, 0.0],
        ])
        XCTAssertEqual(closed["ok"] as? Bool, false)
        XCTAssertEqual(closed["error"] as? String, "document_closed")
        XCTAssertFalse(document.setSectionView(CADSectionView(
            origin: SIMD3(20, 0, 0), xAxis: SIMD3(0, 1, 0),
            yAxis: SIMD3(0, 0, 1))),
            "the document API refuses a closed owner as well")
    }

    func testSceneServiceRefusesReadOnlyDocument() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADViewOverlayReadOnly-\(UUID())")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("opaque.floecad")
        try await CADAssociativeFormatFixture.basicPackage(at: url)
        try CADAssociativeFormatFixture.makeOpaque(url, kind: .definitionKind)
        let document = try await FloeCADDocument.open(at: url)
        defer { document.close() }
        XCTAssertTrue(document.isReadOnly)
        let service = CADViewOverlayService(document: document)
        XCTAssertEqual(service.handle(action: "get", args: [:])["ok"] as? Bool, true)
        let changeCount = document.liveChangeCount
        for (action, args) in [
            ("setSection", ["origin": [20.0, 0.0, 0.0],
                            "normal": [1.0, 0.0, 0.0]] as [String: Any]),
            ("addMeasurement", ["start": [0.0, 0.0, 0.0],
                                "end": [10.0, 0.0, 0.0]] as [String: Any]),
            ("clearMeasurements", [:] as [String: Any]),
            ("undo", [:] as [String: Any]),
        ] {
            let reply = service.handle(action: action, args: args)
            XCTAssertEqual(reply["ok"] as? Bool, false, "\(action): \(reply)")
            XCTAssertEqual(reply["error"] as? String, "read_only",
                           "\(action): \(reply)")
            XCTAssertEqual(reply["mutated"] as? Bool, false)
        }
        XCTAssertEqual(document.liveChangeCount, changeCount)
    }

    func testSceneServiceValidatesEveryRevisionPinStrictlyBeforeMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADViewOverlayPin-\(UUID())")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await makeBoxDocument(in: root)
        defer { document.close() }
        let service = CADViewOverlayService(document: document)
        let initialRevision = document.revision
        let initialChangeCount = document.liveChangeCount
        let sectionArgs: [String: Any] = [
            "origin": [20.0, 0.0, 0.0], "normal": [1.0, 0.0, 0.0],
        ]

        // Fractional, boolean and non-integral string pins are refused before
        // any command runs. NSNumber(initial + 0.5) used to be truncated onto
        // the real revision by `int64Value` and accepted.
        let fractional = Double(initialRevision) + 0.5
        let badPins: [(String, Any)] = [
            ("revision", fractional),
            ("expected_revision", fractional),
            ("revision", true),
            ("expected_revision", false),
            ("revision", "\(initialRevision).5"),
            ("expected_revision", "\(initialRevision).0"),
        ]
        for (key, pin) in badPins {
            var args = sectionArgs
            args[key] = pin
            let reply = service.handle(action: "setSection", args: args)
            XCTAssertEqual(reply["ok"] as? Bool, false, "\(key)=\(pin): \(reply)")
            XCTAssertEqual(reply["error"] as? String, "bad_revision",
                           "\(key)=\(pin): \(reply)")
            XCTAssertNil(document.viewOverlayState.section)
            XCTAssertEqual(document.liveChangeCount, initialChangeCount)
        }

        // Two individually valid pins that contradict each other are refused,
        // including the order where the first one matches the real revision.
        let contradiction = [(initialRevision, initialRevision + 1),
                             (initialRevision + 1, initialRevision)]
        for pair in contradiction {
            var args = sectionArgs
            args["revision"] = pair.0
            args["expected_revision"] = pair.1
            let reply = service.handle(action: "setSection", args: args)
            XCTAssertEqual(reply["ok"] as? Bool, false, "\(pair): \(reply)")
            XCTAssertEqual(reply["error"] as? String, "revision_mismatch",
                           "\(pair): \(reply)")
            XCTAssertNil(document.viewOverlayState.section)
            XCTAssertEqual(document.liveChangeCount, initialChangeCount)
        }

        // The same real revision is still accepted as a plain integer.
        var good = sectionArgs
        good["revision"] = initialRevision
        let set = service.handle(action: "setSection", args: good)
        XCTAssertEqual(set["ok"] as? Bool, true, "\(set)")
        XCTAssertEqual(set["mutated"] as? Bool, true)
        XCTAssertNotNil(document.viewOverlayState.section)

        // Commit that real change, then pin the saved revision. Both an
        // integer and an exact integer string remain compatible.
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let stableRevision = document.revision
        let shown = service.handle(action: "setMeasurementsVisible", args: [
            "visible": false, "expected_revision": "\(stableRevision)",
        ])
        XCTAssertEqual(shown["ok"] as? Bool, true, "\(shown)")
        XCTAssertEqual(shown["mutated"] as? Bool, true)
        XCTAssertFalse(document.viewOverlayState.showsMeasurements)

        let undone = service.handle(action: "undo", args: [
            "revision": stableRevision,
        ])
        XCTAssertEqual(undone["ok"] as? Bool, true, "\(undone)")
        XCTAssertTrue(document.viewOverlayState.showsMeasurements)

        // On the stable state, a stale/fractional/boolean pin is refused
        // without changing the overlay or consuming an undo step.
        let stableChangeCount = document.liveChangeCount
        let canUndo = document.session.undoStack.canUndo
        let overlay = document.viewOverlayState
        let stablePins: [(String, Any, String)] = [
            ("revision", stableRevision + 1, "revision_mismatch"),
            ("revision", Double(stableRevision) + 0.5, "bad_revision"),
            ("expected_revision", true, "bad_revision"),
        ]
        for (key, pin, code) in stablePins {
            var args: [String: Any] = ["visible": false]
            args[key] = pin
            let reply = service.handle(action: "setMeasurementsVisible", args: args)
            XCTAssertEqual(reply["ok"] as? Bool, false, "\(key)=\(pin): \(reply)")
            XCTAssertEqual(reply["error"] as? String, code, "\(key)=\(pin): \(reply)")
        }
        XCTAssertEqual(document.viewOverlayState, overlay)
        XCTAssertEqual(document.liveChangeCount, stableChangeCount)
        XCTAssertEqual(document.session.undoStack.canUndo, canUndo)
    }

    func testSaveMeasurementAnnotationReportsTheRealCommit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADViewOverlayMeasure-\(UUID())")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await makeBoxDocument(in: root)
        defer { document.close() }
        let model = document.viewModel()

        // The real measure input the pill reads: two picked world points.
        model.measurePoints = [SIMD3(5, 15, 0), SIMD3(35, 15, 0)]
        let result = try XCTUnwrap(model.measureResult)
        XCTAssertEqual(result.distance, 30, accuracy: 1e-9)

        XCTAssertTrue(model.saveMeasurementAnnotation())
        let committed = document.viewOverlayState
        XCTAssertEqual(committed.measurements.count, 1)
        XCTAssertEqual(try XCTUnwrap(committed.measurements.first).lengthMM,
                       30, accuracy: 1e-9)
        XCTAssertTrue(committed.showsMeasurements)
        XCTAssertTrue(model.measurePoints.isEmpty,
                      "a committed save replaces the transient pick pair")
        XCTAssertEqual(model.viewOverlay, committed,
                       "the live mirror is the committed document bytes")
        XCTAssertEqual(model.notice, FloeCADStrings.text(
            "cad.measure.saved", "Measurement saved to this document."))

        // The guide is one ordinary undo step, not a second store.
        document.session.undo()
        XCTAssertTrue(document.viewOverlayState.measurements.isEmpty)
        model.reloadViewOverlayFromDocument()
        XCTAssertEqual(model.viewOverlay, document.viewOverlayState)
    }

    func testSaveMeasurementAnnotationKeepsInputAndMirrorWhenSessionRefuses() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADViewOverlayBlocked-\(UUID())")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("opaque.floecad")
        try await CADAssociativeFormatFixture.basicPackage(at: url)
        try CADAssociativeFormatFixture.makeOpaque(url, kind: .definitionKind)
        let document = try await FloeCADDocument.open(at: url)
        defer { document.close() }
        XCTAssertTrue(document.isReadOnly)
        let block = try XCTUnwrap(document.session.writeBlock)
        XCTAssertEqual(block.code, "read_only")
        let model = document.viewModel()

        model.measurePoints = [SIMD3(5, 5, 0), SIMD3(35, 5, 0)]
        let beforeSettings = document.session.document.sceneSettingsData
        let beforeChangeCount = document.liveChangeCount
        let beforeCanUndo = document.session.undoStack.canUndo

        XCTAssertFalse(model.saveMeasurementAnnotation(),
                       "a refused session write must never report a saved measurement")
        XCTAssertEqual(model.measurePoints.count, 2,
                       "the transient pick pair stays retryable after a refusal")
        XCTAssertEqual(document.session.document.sceneSettingsData, beforeSettings,
                       "a refused save writes no sceneSettings bytes")
        XCTAssertEqual(document.liveChangeCount, beforeChangeCount)
        XCTAssertEqual(document.session.undoStack.canUndo, beforeCanUndo,
                       "a refused save pushes no history step")
        XCTAssertTrue(model.viewOverlay.measurements.isEmpty)
        XCTAssertEqual(model.viewOverlay, document.viewOverlayState,
                       "the live mirror follows the authoritative bytes, not the "
                           + "refused overlay")
        XCTAssertEqual(model.notice, FloeCADStrings.text(
            "cad.overlay.error.readOnly",
            "This document is read-only; its section and annotations can't be changed."),
            "the notice states the real refusal instead of claiming a save")
    }

    private func makeBoxDocument(in root: URL) async throws -> FloeCADDocument {
        let document = try await FloeCADDocument.create(
            at: root.appendingPathComponent("box.floecad"), name: "Box")
        func run(_ object: [String: Any]) throws -> [String: Any] {
            let result = document.executeJSON(
                try JSONSerialization.data(withJSONObject: object))
            XCTAssertTrue(result.isOK, result.message ?? "")
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
        }
        let sketch = try run(["op": "sketch.create", "args": ["name": "Base"]])
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try run(["op": "sketch.addEntities", "args": [
            "sketchID": sketchID,
            "entities": [["kind": "rect", "min": [0, 0], "max": [40, 20]]],
        ]])
        _ = try run(["op": "feature.extrude", "args": [
            "sketchID": sketchID, "seedPoint": [20, 10], "distance": 10,
        ]])
        XCTAssertEqual(document.summary().bodyCount, 1)
        return document
    }
}

// MARK: - Shared presentation scene + real stage

@MainActor
final class CADViewOverlayPresentationTests: XCTestCase {

    func testSceneAndStageCarryTheSectionCutAndGuides() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADViewOverlayStage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await makeBoxDocument(in: root)
        defer { document.close() }

        let fullScene = CADPresentationSceneBuilder.build(
            snapshot: document.sceneSnapshot(),
            documentKey: document.url.standardizedFileURL.path)
        XCTAssertNil(fullScene.section)
        XCTAssertTrue(fullScene.measurementGuides.isEmpty)
        let fullResult = try await CADPresentationEntityBuilder(
            cache: CADPresentationResourceCache()).build(scene: fullScene)
        let fullBounds = try XCTUnwrap(bodyBounds(in: fullResult))
        XCTAssertLessThan(fullBounds.min.x, 1,
                          "baseline stage starts near x = 0")

        XCTAssertTrue(document.setSectionView(CADSectionView(
            origin: SIMD3(20, 0, 0), xAxis: SIMD3(0, 1, 0),
            yAxis: SIMD3(0, 0, 1))))
        _ = try document.addMeasurementAnnotation(
            from: SIMD3(5, 15, 0), to: SIMD3(35, 15, 0))
        let sectionedScene = CADPresentationSceneBuilder.build(
            snapshot: document.sceneSnapshot(),
            documentKey: document.url.standardizedFileURL.path)
        XCTAssertNotNil(sectionedScene.section)
        XCTAssertEqual(sectionedScene.measurementGuides.count, 1)
        let guide = try XCTUnwrap(sectionedScene.measurementGuides.first)
        XCTAssertGreaterThanOrEqual(Double(guide.start.x), 0.0199,
                                    "the guide is clipped to the kept half")
        XCTAssertEqual(Double(guide.end.x), 0.035, accuracy: 1e-6)
        XCTAssertNotEqual(fullScene.buildKey, sectionedScene.buildKey,
                          "the section is part of the stage identity")

        let sectionedResult = try await CADPresentationEntityBuilder(
            cache: CADPresentationResourceCache()).build(scene: sectionedScene)
        let sectionedBounds = try XCTUnwrap(bodyBounds(in: sectionedResult))
        // `bodyBounds` reads the RealityKit stage in presentation metres while
        // the persisted plane is authored at 20 mm. Convert the SAME intended
        // thresholds (19.9 mm / 39.9 mm) instead of comparing units: this is
        // not a relaxed cut and production geometry scaling is unchanged.
        XCTAssertGreaterThanOrEqual(sectionedBounds.min.x, 0.0199,
                                    "the real presented mesh starts at the 20 mm cut (metres)")
        XCTAssertGreaterThan(sectionedBounds.max.x, 0.0399)
        XCTAssertEqual(sectionedBounds.min.x, 0.02, accuracy: 1e-4,
                       "the presented cut is the authored 20 mm plane")
        XCTAssertEqual(sectionedBounds.max.x, 0.04, accuracy: 1e-4,
                       "the kept half still reaches the authored 40 mm face")
        let guides = sectionedResult.stage.children.filter {
            $0.name.hasPrefix("CADPresentationMeasurementGuide")
        }
        XCTAssertGreaterThanOrEqual(guides.count, 1,
                                   "the guide is real stage geometry, not a UI badge")
    }

    func testInvalidSectionIsReportedInsteadOfDrawingTheBodyUncut() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADViewOverlayInvalidStage-\(UUID())")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await makeBoxDocument(in: root)
        defer { document.close() }
        var scene = CADPresentationSceneBuilder.build(
            snapshot: document.sceneSnapshot(),
            documentKey: document.url.standardizedFileURL.path)
        scene.section = CADPresentationSection(
            origin: .zero, keepNormal: .zero, sizeMM: 8, flipped: false)
        let result = try await CADPresentationEntityBuilder(
            cache: CADPresentationResourceCache()).build(scene: scene)
        XCTAssertTrue(result.bodyEntities.isEmpty,
                      "an unusable active section must not fall back to the full mesh")
        XCTAssertTrue(result.issues.contains {
            $0.kind == .sectionInvalid
        }, "the invalid plane is reported: \(result.issues)")
    }

    func testSectionKeepsFaceGroupEntitiesAndTheirUVs() async throws {
        let cube = CADViewOverlayValueTests.cubeMesh()
        let groupIndices = Array(cube.indices.prefix(6))
        let groupUVs = cube.uvs.map { SIMD2($0.x * 3, $0.y * 5) }
        let mesh = CADPresentationMesh(
            positions: cube.positions, normals: cube.normals,
            indices: cube.indices, uvs: cube.uvs, authoredUVs: cube.uvs,
            meshRevision: 1, boundsMin: SIMD3(0, 0, 0),
            boundsMax: SIMD3(2, 2, 2))
        let body = CADPresentationBody(
            id: UUID(), name: "Face group",
            transform: matrix_identity_float4x4, mesh: mesh,
            material: .neutral, faceMaterials: [],
            faceGroups: [CADPresentationFaceGroup(
                faceIndex: 3, indices: groupIndices,
                material: .neutral, uvs: groupUVs)],
            unresolvedFaceCount: 0, analyticBRep: false)
        let scene = CADPresentationScene(
            schemaVersion: CADPresentationScene.currentSchemaVersion,
            documentKey: "test://face-group", documentRevision: 1,
            changeCount: 1, contentSHA256: String(repeating: "0", count: 64),
            bodies: [body], images: [],
            environment: CADPresentationEnvironment(
                kind: .studio, lightIntensity: 1,
                lightDirectionModel: SIMD3(0.35, 0.55, 0.75),
                backgroundColor: SIMD3(0.1, 0.1, 0.1),
                floorVisible: false, floorColor: SIMD3(1, 1, 1),
                floorSizeMM: 2_000, shadowsEnabled: false),
            issues: [], bounds: CADPresentationBounds(
                min: SIMD3(0, 0, 0), max: SIMD3(2, 2, 2)),
            materialCount: 0,
            section: CADPresentationSection(
                origin: SIMD3(1_000, 0, 0), keepNormal: SIMD3(1, 0, 0),
                sizeMM: 8, flipped: false),
            measurementGuides: [])
        let result = try await CADPresentationEntityBuilder(
            cache: CADPresentationResourceCache()).build(scene: scene)
        let nodes = try XCTUnwrap(result.bodyEntities[body.id])
        XCTAssertEqual(nodes.entities.count, 2,
                       "the body base and its one authoritative face group both draw")
        let faceEntity = try XCTUnwrap(nodes.faceEntities[3])
        XCTAssertTrue(faceEntity.name.contains("3"))
        XCTAssertTrue(nodes.faceTriangles.isEmpty,
                      "clipped triangle ordinals are not offered as a face target")
        let bounds = try XCTUnwrap(bodyBounds(in: result))
        XCTAssertGreaterThanOrEqual(bounds.min.x, 0.999_9,
                                    "the face group is drawn through the same cut")
    }

    private func bodyBounds(in result: CADPresentationBuildResult)
    -> BoundingBox? {
        var minPoint = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxPoint = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var any = false
        for nodes in result.bodyEntities.values {
            for entity in nodes.entities {
                let bounds = entity.visualBounds(relativeTo: result.stage)
                minPoint = simd_min(minPoint, bounds.min)
                maxPoint = simd_max(maxPoint, bounds.max)
                any = true
            }
        }
        return any ? BoundingBox(min: minPoint, max: maxPoint) : nil
    }

    private func makeBoxDocument(in root: URL) async throws -> FloeCADDocument {
        let document = try await FloeCADDocument.create(
            at: root.appendingPathComponent("box.floecad"), name: "Box")
        func run(_ object: [String: Any]) throws -> [String: Any] {
            let result = document.executeJSON(
                try JSONSerialization.data(withJSONObject: object))
            XCTAssertTrue(result.isOK, result.message ?? "")
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
        }
        let sketch = try run(["op": "sketch.create", "args": ["name": "Base"]])
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try run(["op": "sketch.addEntities", "args": [
            "sketchID": sketchID,
            "entities": [["kind": "rect", "min": [0, 0], "max": [40, 20]]],
        ]])
        _ = try run(["op": "feature.extrude", "args": [
            "sketchID": sketchID, "seedPoint": [20, 10], "distance": 10,
        ]])
        XCTAssertEqual(document.summary().bodyCount, 1)
        return document
    }
}

// MARK: - Actual offscreen pixels

@MainActor
final class CADViewOverlayCaptureTests: XCTestCase {

    func testEditCapturePixelsContainSectionAndGuides() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADViewOverlayCapture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await makeBoxDocument(in: root)
        defer { document.close() }
        let camera = CADSavedCamera(
            name: "X22", projection: .perspective,
            targetMM: SIMD3(20, 5, -10), distanceMM: 140,
            azimuthRadians: 0.65, elevationRadians: 0.32,
            fovYDegrees: 40, frameAspect: 4.0 / 3.0)

        let baseline = try document.captureViewportPNG(
            width: 512, height: 384, camera: camera)
        retainPNG(baseline.pngData, name: "X22 engineering baseline")
        XCTAssertFalse(baseline.sectionCutIncluded)
        XCTAssertEqual(baseline.measurementGuideCount, 0)
        let baselinePixels = try XCTUnwrap(rgbaPixels(baseline.pngData))

        // Active cut: the same saved camera frames both images, so a large
        // pixel change is the cut itself, not a camera refit.
        XCTAssertTrue(document.setSectionView(CADSectionView(
            origin: SIMD3(20, 0, 0), xAxis: SIMD3(0, 1, 0),
            yAxis: SIMD3(0, 0, 1))))
        let sectionCapture = try document.captureViewportPNG(
            width: 512, height: 384, camera: camera)
        retainPNG(sectionCapture.pngData, name: "X22 engineering section")
        XCTAssertTrue(sectionCapture.sectionCutIncluded)
        XCTAssertTrue(sectionCapture.note.contains("section cut"))
        let sectionPixels = try XCTUnwrap(rgbaPixels(sectionCapture.pngData))
        let sectionDiff = differingPixels(baselinePixels, sectionPixels)
        XCTAssertGreaterThan(sectionDiff, 200,
                             "the real renderer must clip the kept half")

        // Saved guide: visible in the same pixels, and hidden on request.
        let annotation = try document.addMeasurementAnnotation(
            from: SIMD3(5, 15, 0), to: SIMD3(35, 15, 0))
        XCTAssertNotNil(annotation.sanitized)
        let guideCapture = try document.captureViewportPNG(
            width: 512, height: 384, camera: camera)
        retainPNG(guideCapture.pngData, name: "X22 engineering section with guide")
        XCTAssertEqual(guideCapture.measurementGuideCount, 1)
        XCTAssertEqual(guideCapture.measurementLengthsMM.count, 1)
        XCTAssertEqual(guideCapture.measurementLengthsMM.first ?? 0, 30,
                       accuracy: 1e-6)
        XCTAssertTrue(guideCapture.note.contains("measurement guide"))
        let guidePixels = try XCTUnwrap(rgbaPixels(guideCapture.pngData))
        XCTAssertGreaterThan(differingPixels(sectionPixels, guidePixels), 5,
                             "the saved guide must be in the pixels")

        XCTAssertTrue(document.setMeasurementGuidesVisible(false))
        let hiddenCapture = try document.captureViewportPNG(
            width: 512, height: 384, camera: camera)
        retainPNG(hiddenCapture.pngData, name: "X22 engineering guide hidden")
        XCTAssertEqual(hiddenCapture.measurementGuideCount, 0)
        let hiddenPixels = try XCTUnwrap(rgbaPixels(hiddenCapture.pngData))
        XCTAssertEqual(differingPixels(sectionPixels, hiddenPixels), 0,
                       "hiding the layer returns the exact section pixels")

        // Reopen: the same persisted state produces the same cut again.
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        let url = document.url
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        XCTAssertTrue(reopened.viewOverlayState.activeSection != nil)
        XCTAssertEqual(reopened.viewOverlayState.measurements.count, 1)
        XCTAssertFalse(reopened.viewOverlayState.showsMeasurements)
        let reopenedCapture = try reopened.captureViewportPNG(
            width: 512, height: 384, camera: camera)
        retainPNG(reopenedCapture.pngData, name: "X22 engineering reopened section")
        XCTAssertTrue(reopenedCapture.sectionCutIncluded)
        XCTAssertEqual(reopenedCapture.measurementGuideCount, 0)
        XCTAssertTrue(reopenedCapture.measurementLengthsMM.isEmpty)
    }

    private func retainPNG(_ png: Data, name: String) {
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func rgbaPixels(_ png: Data) -> (width: Int, height: Int,
                                             bytes: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0,
                                           width: width, height: height))
            return true
        }
        return ok ? (width, height, bytes) : nil
    }

    /// Count pixels whose colour moved by more than a small antialiasing
    /// tolerance. This is a real pixel comparison, not a PNG digest check.
    private func differingPixels(_ a: (width: Int, height: Int, bytes: [UInt8]),
                                 _ b: (width: Int, height: Int, bytes: [UInt8]))
    -> Int {
        guard a.width == b.width, a.height == b.height,
              a.bytes.count == b.bytes.count else { return Int.max }
        var count = 0
        var index = 0
        while index + 3 < a.bytes.count {
            if abs(Int(a.bytes[index]) - Int(b.bytes[index])) > 12
                || abs(Int(a.bytes[index + 1]) - Int(b.bytes[index + 1])) > 12
                || abs(Int(a.bytes[index + 2]) - Int(b.bytes[index + 2])) > 12 {
                count += 1
            }
            index += 4
        }
        return count
    }

    private func makeBoxDocument(in root: URL) async throws -> FloeCADDocument {
        let document = try await FloeCADDocument.create(
            at: root.appendingPathComponent("box.floecad"), name: "Box")
        func run(_ object: [String: Any]) throws -> [String: Any] {
            let result = document.executeJSON(
                try JSONSerialization.data(withJSONObject: object))
            XCTAssertTrue(result.isOK, result.message ?? "")
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
        }
        let sketch = try run(["op": "sketch.create", "args": ["name": "Base"]])
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try run(["op": "sketch.addEntities", "args": [
            "sketchID": sketchID,
            "entities": [["kind": "rect", "min": [0, 0], "max": [40, 20]]],
        ]])
        _ = try run(["op": "feature.extrude", "args": [
            "sketchID": sketchID, "seedPoint": [20, 10], "distance": 10,
        ]])
        XCTAssertEqual(document.summary().bodyCount, 1)
        return document
    }
}

// MARK: - Actual Present stage capture fence

@MainActor
final class CADViewOverlayPresentCaptureTests: XCTestCase {
    private var documents: [FloeCADDocument] = []
    private var stores: [CADPresentationSceneStore] = []
    private var handles: [CADPresentationHandle] = []
    private var windows: [UIWindow] = []
    private var hostings: [UIHostingController<AnyView>] = []
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADViewOverlayPresent-\(UUID())")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for hosting in hostings { hosting.rootView = AnyView(EmptyView()) }
        for window in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        for store in stores { store.stopObserving() }
        for handle in handles { handle.controller?.release() }
        for document in documents {
            CADPresentationCaptureRegistry.shared.unregister(document)
            document.close()
        }
        if let root { try? FileManager.default.removeItem(at: root) }
        hostings = []; windows = []; stores = []; handles = []; documents = []
    }

    private func makeDocument() async throws -> FloeCADDocument {
        let url = root.appendingPathComponent("overlay-present.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Overlay Present")
        documents.append(document)
        func run(_ object: [String: Any]) throws -> [String: Any] {
            let result = document.executeJSON(
                try JSONSerialization.data(withJSONObject: object))
            XCTAssertTrue(result.isOK, result.message ?? "")
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: result.payload)
                    as? [String: Any])
        }
        let sketch = try run(["op": "sketch.create", "args": ["name": "Base"]])
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try run(["op": "sketch.addEntities", "args": [
            "sketchID": sketchID,
            "entities": [["kind": "rect", "min": [0, 0], "max": [40, 20]]],
        ]])
        _ = try run(["op": "feature.extrude", "args": [
            "sketchID": sketchID, "seedPoint": [20, 10], "distance": 10,
        ]])
        return document
    }

    private func mount(_ document: FloeCADDocument) async throws
    -> (CADPresentationHandle, CADPresentationSceneStore,
        UIWindow, UIHostingController<AnyView>) {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: {
            $0.activationState == .foregroundActive
        }) else {
            throw XCTSkip("Present stage fixture requires the App-hosted UIKit "
                          + "target with a foreground window scene; no render is faked.")
        }
        let store = CADPresentationSceneStore(document: document)
        let handle = CADPresentationHandle()
        stores.append(store)
        handles.append(handle)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 512, height: 512)
        let hosting = UIHostingController(rootView: AnyView(
            CADPresentationPresentationPane(document: document, handle: handle,
                                            store: store, onEdit: {})
                .frame(width: 512, height: 512)
                .id(ObjectIdentifier(document))))
        window.rootViewController = hosting
        windows.append(window)
        hostings.append(hosting)
        window.makeKeyAndVisible()
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if CADPresentationCaptureRegistry.shared.isActive(for: document),
               let active = CADPresentationCaptureRegistry.shared
                .activeHandle(for: document),
               active.controller?.isStageReady == true {
                return (handle, store, window, hosting)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Present never installed its first stage; no pixels were faked.")
        throw CADPresentationError.renderingUnavailable
    }

    func testImmediateOverlayCaptureWaitsForTheExactInstalledStage() async throws {
        let document = try await makeDocument()
        let mounted = try await mount(document)
        let service = CADPresentationSnapshotService()
        let baseline = try await service.capture(
            handle: mounted.0, document: document, targetWidth: 256)
        let baselineImage = XCTAttachment(data: baseline.pngData,
                                          uniformTypeIdentifier: "public.png")
        baselineImage.name = "X22 Present baseline"
        baselineImage.lifetime = .keepAlways
        add(baselineImage)
        XCTAssertFalse(baseline.sectionCutIncluded)
        XCTAssertEqual(baseline.measurementGuideCount, 0)

        XCTAssertTrue(document.setSectionView(CADSectionView(
            origin: SIMD3(20, 0, 0), xAxis: SIMD3(0, 1, 0),
            yAxis: SIMD3(0, 0, 1))))
        // Exactly the production overlay-sheet hook; NO sleep is added.
        mounted.1.refresh(force: true)
        let expected = CADPresentationSceneBuilder.build(
            snapshot: document.sceneSnapshot(),
            documentKey: document.url.standardizedFileURL.path)

        let snapshot = try await service.capture(
            handle: mounted.0, document: document, targetWidth: 256)
        let sectionImage = XCTAttachment(data: snapshot.pngData,
                                         uniformTypeIdentifier: "public.png")
        sectionImage.name = "X22 Present immediate section"
        sectionImage.lifetime = .keepAlways
        add(sectionImage)
        XCTAssertTrue(snapshot.sectionCutIncluded)
        XCTAssertEqual(snapshot.sceneBuildKey, expected.buildKey)
        XCTAssertEqual(snapshot.measurementGuideCount, 0)
        XCTAssertNotEqual(snapshot.pngData, baseline.pngData,
                          "the awaited stage, not the previous pixels, must be captured")
        XCTAssertEqual(snapshot.revision, document.revision)
        XCTAssertEqual(snapshot.changeCount, document.liveChangeCount)

        let controller = try XCTUnwrap(mounted.0.controller)
        XCTAssertEqual(controller.installedBuildKey, expected.buildKey)
        let exact = await controller.awaitStage(buildKey: expected.buildKey)
        XCTAssertTrue(exact)
        let staleKey = expected.buildKey + "|superseded"
        let refused = await controller.awaitStage(buildKey: staleKey)
        XCTAssertFalse(refused,
                       "a capture for a superseded scene must be refused, not relabelled")
        do {
            _ = try await controller.snapshotImage(
                targetWidth: 128, expectedBuildKey: staleKey)
            XCTFail("snapshotImage must refuse a stage key it did not install")
        } catch let error as CADPresentationError {
            guard case .snapshotStale = error else {
                return XCTFail("unexpected snapshot error: \(error)")
            }
        }
    }

    /// The exact window the R2 installed-key-only fast path got wrong: the
    /// previous stage is STILL mounted when a new scene is requested, so a
    /// waiter or expected-key snapshot for the old identity must refuse
    /// immediately. No test sleep may let the new build install first — that
    /// would hide the race this exercises.
    func testSupersededStageIsRefusedWhileItIsStillInstalled() async throws {
        let document = try await makeDocument()
        let mounted = try await mount(document)
        let controller = try XCTUnwrap(mounted.0.controller)
        let firstScene = try XCTUnwrap(mounted.1.scene)
        let firstKey = firstScene.buildKey
        XCTAssertEqual(controller.installedBuildKey, firstKey)
        XCTAssertEqual(controller.requestedBuildKey, firstKey)
        XCTAssertTrue(controller.isStageReady)

        // A real document change produces the next scene exactly as closing
        // the Overlays sheet does in Present.
        XCTAssertTrue(document.setSectionView(CADSectionView(
            origin: SIMD3(20, 0, 0), xAxis: SIMD3(0, 1, 0),
            yAxis: SIMD3(0, 0, 1))))
        mounted.1.refresh(force: true)
        let nextScene = try XCTUnwrap(mounted.1.scene)
        XCTAssertNotEqual(nextScene.buildKey, firstKey)
        // Apply the real scene value directly, then read the acceptance
        // state synchronously: the OLD stage is deliberately still installed
        // here because the new build has not been allowed to run.
        controller.apply(nextScene)

        XCTAssertEqual(controller.installedBuildKey, firstKey,
                       "the previous stage must still be mounted at this instant")
        XCTAssertEqual(controller.requestedBuildKey, nextScene.buildKey,
                       "the real scene value is the current request before its build")
        XCTAssertFalse(controller.isStageCurrent(buildKey: firstKey),
                       "the installed-but-superseded stage is not the current scene")
        XCTAssertFalse(controller.isStageReady)

        // This call is the R2 fast path's exact failure: the old stage is
        // installed, so an installed-key-only check returns true without even
        // yielding to the new build. It must refuse instead.
        let refused = await controller.awaitStage(buildKey: firstKey)
        XCTAssertFalse(refused,
                       "awaitStage must refuse a superseded identity even while "
                           + "its stage is still the installed one")

        // An expected-key snapshot for the still-visible old stage must be
        // refused before the new build can install; an installed-key-only
        // guard would return the previous scene's pixels here.
        do {
            _ = try await controller.snapshotImage(
                targetWidth: 128, expectedBuildKey: firstKey)
            XCTFail("the still-installed superseded stage must not satisfy a snapshot")
        } catch let error as CADPresentationError {
            guard case .snapshotStale = error else {
                return XCTFail("unexpected snapshot error: \(error)")
            }
        }
        XCTAssertEqual(controller.installedBuildKey, firstKey,
                       "the refusal happened while the old stage was installed")

        // The store refresh has already scheduled a SwiftUI update carrying
        // this same nextScene. It re-delivers B while this waiter is live; a
        // duplicate request must not cancel B's build or resolve the waiter
        // false (the native152 signature). No sleep is used here.
        let installed = await controller.awaitStage(buildKey: nextScene.buildKey)
        XCTAssertTrue(installed, "the requested scene must still install normally")
        XCTAssertEqual(controller.installedBuildKey, nextScene.buildKey)
        XCTAssertTrue(controller.isStageReady)

        // A pending SwiftUI body can still deliver the pre-refresh scene value
        // after B installed. That value is an older document generation, so it
        // must be ignored instead of tearing the current stage down.
        controller.apply(firstScene)
        XCTAssertEqual(controller.requestedBuildKey, nextScene.buildKey,
                       "an obsolete scene cannot become the requested owner")
        XCTAssertEqual(controller.installedBuildKey, nextScene.buildKey)
        XCTAssertTrue(controller.isStageReady,
                      "the requested scene remains ready after the stale update")
    }
}
#endif

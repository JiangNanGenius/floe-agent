import Foundation
import XCTest
import UIKit
import simd
@testable import FloeCAD

/// Real editor/input delivery -> Session -> OCCT -> datum/support/child solid.
/// These are component interactions, not a claim about injected App touches.
@MainActor
final class CADAssociativeSketchDragTests: XCTestCase {
    private var documents: [FloeCADDocument] = []
    private var directories: [URL] = []
    private var revision: UInt64 = 0

    override func tearDown() async throws {
        for document in documents { document.close() }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        documents = []; directories = []
    }

    private struct Fixture {
        var document: FloeCADDocument
        var model: EditorViewModel
        var source: Sketch
        var sourceBody: BodyID
        var datum: ConstructionPlaneID
        var supported: SketchID
        var childBody: BodyID
    }

    private func fixture(circle: Bool = false, dimensioned: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CADSketchDrag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("Drag.floecad"), name: "Drag")
        documents.append(document)
        let entity = UUID()
        var sketch = Sketch(name: "Source", plane: .ground, entities: circle
            ? [.circle(id: entity, center: SIMD2(15, 15), radius: 5)]
            : [.rect(id: entity, min: .zero, max: SIMD2(40, 30))])
        if dimensioned {
            sketch.rectangleSizingAnchors[entity] = .center
            sketch.dimensions = [
                SketchDimension(kind: .horizontal, refs: [.init(entityID: entity, role: .endpointA), .init(entityID: entity, role: .endpointB)], value: 40),
                SketchDimension(kind: .vertical, refs: [.init(entityID: entity, role: .endpointA), .init(entityID: entity, role: .endpointB)], value: 30)
            ]
        }
        let sourceBody = BodyID()
        let source = extrusion(sketch, body: sourceBody, distance: 10)
        document.session.recordAndRebuild([source], extra: [AddSketchCommand(sketch: sketch)], title: "Source")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        let body = try XCTUnwrap(document.session.document.body(with: sourceBody))
        let face = try XCTUnwrap(OCCTKernel.faceInfo(try XCTUnwrap(body.brep)).first { $0.normal.y > 0.99 })
        let name = try XCTUnwrap(document.session.lastKernelNames[sourceBody]?[face.index])
        let frame = try PlaneAttachmentFrame.make(faceCentroid: face.centroid, faceNormal: face.normal,
                                                  referenceXAxis: SIMD3(1, 0, 0), anchorPoint: face.centroid)
        let definition = OffsetPlaneDefinition(source: FaceRef(
            body: BodyRef(producer: source.id, bodyID: sourceBody), creator: name.creator,
            role: .extrudeEndCap, signature: try XCTUnwrap(face.signature), elementName: name),
            sourceVersion: GeometryVersionRef(bodyID: sourceBody, writer: source.id),
            distance: Expr(value: 5), attachment: frame)
        let plane = try definition.resolvedPlane(face: SourceFaceGeometry(bodyID: sourceBody,
            centroid: face.centroid, normal: face.normal), bodyTransform: body.transform)
        let datum = ConstructionPlane(plane: plane, size: 100, definition: .offset(definition))
        let supported = Sketch(name: "Child", plane: plane,
            entities: [.rect(id: UUID(), min: SIMD2(-2, -1), max: SIMD2(2, 1))],
            support: PlaneRef(source: .construction(datum.id)))
        let childBody = BodyID()
        XCTAssertTrue(document.session.performAssociativeTransaction([
            AddConstructionPlaneCommand(plane: datum), AddSketchCommand(sketch: supported),
            AppendFeatureCommand(node: extrusion(supported, body: childBody, distance: 3))
        ], title: "Associated child"))
        let saved = await document.save()
        XCTAssertNil(saved.error)
        let model = document.viewModel()
        model.mode = .sketching(sketch.id, tool: nil)
        return Fixture(document: document, model: model, source: sketch, sourceBody: sourceBody,
                       datum: datum.id, supported: supported.id, childBody: childBody)
    }

    private func extrusion(_ sketch: Sketch, body: BodyID, distance: Double) -> FeatureNode {
        FeatureNode(name: sketch.name, kind: .extrude(profile: ProfileRef(sketchID: sketch.id,
            entityIDs: sketch.entities.map(\.id), holeEntityIDs: [], seedPoint: .zero),
            plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: distance),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []), extraProfiles: []),
            outputBodyIDs: [body])
    }
    private func ray(_ point: SIMD2<Double>, plane: SketchPlane = .ground) -> Ray {
        Ray(origin: SIMD3<Float>(plane.toWorld(point) + plane.normal * 100),
            direction: SIMD3<Float>(-plane.normal))
    }
    private func source(_ f: Fixture) throws -> Sketch {
        try XCTUnwrap(f.document.session.document.sketches.first { $0.id == f.source.id })
    }
    private func datum(_ f: Fixture) throws -> ConstructionPlane {
        try XCTUnwrap(f.document.session.document.planes.first { $0.id == f.datum })
    }
    private func volume(_ f: Fixture, body id: BodyID) throws -> Double {
        let body = try XCTUnwrap(f.document.session.document.body(with: id))
        return OCCTKernel.volume(try XCTUnwrap(body.brep)) * pow(body.transform.scale, 3)
    }
    private func exactTopCenterX(_ f: Fixture, body id: BodyID) throws -> Double {
        let body = try XCTUnwrap(f.document.session.document.body(with: id))
        let face = try XCTUnwrap(OCCTKernel.faceInfo(try XCTUnwrap(body.brep)).first { $0.normal.y > 0.99 })
        return body.transform.applying(to: face.centroid).x
    }
    private func begin(_ f: Fixture, at point: SIMD2<Double>) throws -> EditorViewModel.SketchDragGestureID {
        XCTAssertTrue(f.model.beginSketchStroke(ray: ray(point)))
        return try XCTUnwrap(f.model.currentSketchDragGestureID)
    }
    private func move(_ f: Fixture, to point: SIMD2<Double>, id: EditorViewModel.SketchDragGestureID) {
        f.model.updateSketchStroke(ray: ray(point), gestureID: id)
    }
    private func end(_ f: Fixture, at point: SIMD2<Double>, id: EditorViewModel.SketchDragGestureID) {
        f.model.endSketchStroke(ray: ray(point), gestureID: id)
    }

    func testActualEntityDragCommitsSourceDatumSupportAndBodiesAsOneUndo() async throws {
        let f = try await fixture()
        let beforePlane = try datum(f)
        let count = f.document.session.undoStack.undoCommands.count
        let oldVolume = try volume(f, body: f.sourceBody)
        let id = try begin(f, at: SIMD2(40, 30))
        move(f, to: SIMD2(45, 32), id: id)
        move(f, to: SIMD2(50, 35), id: id)
        XCTAssertNotEqual(try source(f).entities, f.source.entities)
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, count)
        XCTAssertEqual(try volume(f, body: f.sourceBody), oldVolume, accuracy: 1e-5)
        XCTAssertEqual(try datum(f), beforePlane)
        end(f, at: SIMD2(50, 35), id: id)
        XCTAssertNil(f.model.errorMessage)
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, count + 1)
        XCTAssertEqual(try volume(f, body: f.sourceBody), 17500, accuracy: 1e-3)
        XCTAssertEqual(try datum(f).plane.origin.x, 25, accuracy: 1e-4)
        let child = try XCTUnwrap(f.document.session.document.sketches.first { $0.id == f.supported })
        XCTAssertEqual(child.plane, try datum(f).plane)
        XCTAssertEqual(child.support, PlaneRef(source: .construction(f.datum)))
        XCTAssertEqual(try volume(f, body: f.childBody), 24, accuracy: 1e-4)
        f.model.undo()
        XCTAssertEqual(try source(f), f.source)
        XCTAssertEqual(try datum(f), beforePlane)
        XCTAssertEqual(try volume(f, body: f.sourceBody), oldVolume, accuracy: 1e-5)
        f.model.redo()
        XCTAssertEqual(try volume(f, body: f.sourceBody), 17500, accuracy: 1e-3)
        XCTAssertEqual(try datum(f).plane.origin.x, 25, accuracy: 1e-4)
    }

    func testActualSolverCenterDragKeepsDimensionIntentAndSingleUndo() async throws {
        let f = try await fixture(dimensioned: true)
        let count = f.document.session.undoStack.undoCommands.count
        let id = try begin(f, at: SIMD2(20, 15))
        move(f, to: SIMD2(25, 15), id: id)
        end(f, at: SIMD2(25, 15), id: id)
        XCTAssertNil(f.model.errorMessage)
        XCTAssertNotEqual(try source(f).entities, f.source.entities)
        XCTAssertEqual(try source(f).dimensions, f.source.dimensions)
        XCTAssertEqual(try datum(f).plane.origin.x, 25, accuracy: 1e-3)
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, count + 1)
        f.model.undo()
        XCTAssertEqual(try source(f), f.source)
    }

    func testInvalidCollapsedProfileReleasePreservesBaselineAndRedo() async throws {
        let f = try await fixture()
        let sentinel = ConstructionPlane(plane: .worldXY, size: 10)
        f.document.session.perform(AddConstructionPlaneCommand(plane: sentinel))
        f.document.session.undo()
        _ = await f.document.save()
        let undo = f.document.session.undoStack.undoCommands.count
        let redo = f.document.session.undoStack.redoCommands.count
        let plane = try datum(f)
        let bytes = try CADAssociativeFormatFixture.bytes(f.document.url)
        let id = try begin(f, at: SIMD2(40, 30))
        move(f, to: SIMD2(0, 30), id: id)
        XCTAssertTrue(f.document.session.isSketchPreviewActive)
        let blockedSave = await f.document.save()
        XCTAssertNotNil(blockedSave.error)
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(f.document.url), bytes)
        end(f, at: SIMD2(0, 30), id: id)
        XCTAssertNotNil(f.model.errorMessage)
        XCTAssertEqual(try source(f), f.source)
        XCTAssertEqual(try datum(f), plane)
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, undo)
        XCTAssertEqual(f.document.session.undoStack.redoCommands.count, redo)
        XCTAssertFalse(f.document.session.isSketchPreviewActive)
        XCTAssertEqual(try volume(f, body: f.sourceBody), 12000, accuracy: 1e-4)
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(f.document.url), bytes)
    }

    func testUndoCancelsGestureAndLateCallbacksCannotOverwriteNextOwnerOrOutsideEdit() async throws {
        let f = try await fixture()
        let originalUndo = f.document.session.undoStack.undoCommands.count
        let old = try begin(f, at: SIMD2(40, 30))
        move(f, to: SIMD2(50, 35), id: old)
        f.model.undo()
        XCTAssertEqual(try source(f), f.source)
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, originalUndo)
        let next = try begin(f, at: SIMD2(40, 30))
        move(f, to: SIMD2(45, 32), id: next)
        let preview = try source(f)
        move(f, to: SIMD2(80, 80), id: old)
        end(f, at: SIMD2(80, 80), id: old)
        XCTAssertFalse(f.model.cancelSketchDragGesture(old))
        XCTAssertEqual(try source(f), preview)
        end(f, at: SIMD2(45, 32), id: next)
        f.model.undo()
        let sentinel = ConstructionPlane(plane: .worldXY, size: 11)
        f.document.session.perform(AddConstructionPlaneCommand(plane: sentinel))
        move(f, to: SIMD2(80, 80), id: next)
        end(f, at: SIMD2(80, 80), id: next)
        XCTAssertEqual(try source(f), f.source)
        XCTAssertTrue(f.document.session.document.planes.contains { $0.id == sentinel.id })
    }

    func testCopyAndRectangleDecompositionCancelRestoreOriginalIDsAndDimensions() async throws {
        let f = try await fixture(dimensioned: true)
        f.model.selectedSketchEntityIDs = Set(f.source.entities.map(\.id))
        f.model.sketchTransformActive = true
        f.model.sketchCopyOnDrag = true
        let copy = try XCTUnwrap(f.model.beginSketchTransformControlGesture(.x))
        f.model.updateSketchTransformControl(.x, value: 10, gestureID: copy)
        XCTAssertGreaterThan(try source(f).entities.count, f.source.entities.count)
        XCTAssertTrue(f.model.cancelSketchDragGesture(copy))
        XCTAssertEqual(try source(f), f.source)
        f.model.selectedSketchEntityIDs = Set(f.source.entities.map(\.id))
        let rotate = try XCTUnwrap(f.model.beginSketchTransformControlGesture(.rotation))
        f.model.updateSketchTransformControl(.rotation, value: 30, gestureID: rotate)
        // Prepared rotation migrates metadata to lines inside the same preview.
        XCTAssertNotEqual(try source(f).entities, f.source.entities)
        XCTAssertTrue(f.model.cancelSketchDragGesture(rotate))
        XCTAssertEqual(try source(f), f.source)
        XCTAssertEqual(try source(f).dimensions.map(\.id), f.source.dimensions.map(\.id))
        let ordinary = try await fixture()
        ordinary.model.selectedSketchEntityIDs = [ordinary.source.entities[0].id]
        ordinary.model.sketchTransformActive = true
        let decomposed = try XCTUnwrap(ordinary.model.beginSketchTransformControlGesture(.rotation))
        ordinary.model.updateSketchTransformControl(.rotation, value: 30, gestureID: decomposed)
        XCTAssertEqual(try source(ordinary).entities.count, 4)
        XCTAssertTrue(ordinary.model.cancelSketchDragGesture(decomposed))
        XCTAssertEqual(try source(ordinary), ordinary.source)
    }

    func testContextRectangleAndRadiusAndRetainedTransformUseSameAtomicOwner() async throws {
        let rect = try await fixture()
        rect.model.selectedSketchEntityIDs = [rect.source.entities[0].id]
        rect.model.selectedAxisRectangleEdge = (rect.source.entities[0].id, 1)
        let count = rect.document.session.undoStack.undoCommands.count
        let resize = try XCTUnwrap(rect.model.beginRectangleEdgeDragGesture())
        rect.model.updateRectangleEdgeDrag(delta: 5, gestureID: resize)
        rect.model.endRectangleEdgeDrag(gestureID: resize)
        XCTAssertEqual(rect.document.session.undoStack.undoCommands.count, count + 1)
        XCTAssertNotEqual(try source(rect).entities, rect.source.entities)
        rect.model.undo()
        XCTAssertEqual(try source(rect), rect.source)

        let circle = try await fixture(circle: true)
        circle.model.selectedSketchEntityIDs = [circle.source.entities[0].id]
        let radialCount = circle.document.session.undoStack.undoCommands.count
        let radial = try XCTUnwrap(circle.model.beginRadialRadiusDragGesture())
        circle.model.updateRadialRadiusDrag(delta: 2, gestureID: radial)
        circle.model.endRadialRadiusDrag(gestureID: radial)
        XCTAssertEqual(circle.document.session.undoStack.undoCommands.count, radialCount + 1)
        XCTAssertEqual(try volume(circle, body: circle.sourceBody), .pi * 49 * 10, accuracy: 1e-3)
        circle.model.undo()
        XCTAssertEqual(try source(circle), circle.source)
        circle.model.selectedSketchEntityIDs = [circle.source.entities[0].id]
        circle.model.sketchTransformActive = true
        let transform = try XCTUnwrap(circle.model.beginSketchTransformControlGesture(.x))
        circle.model.updateSketchTransformControl(.x, value: 5, gestureID: transform)
        circle.model.endSketchTransformControl(gestureID: transform)
        XCTAssertEqual(circle.model.retainedSketchTransformValue(.x), 5)
        XCTAssertTrue(circle.model.commitSketchTransformControl(.x, text: "8"))
        XCTAssertEqual(try datum(circle).plane.origin.x, 23, accuracy: 1e-3)
        XCTAssertEqual(try exactTopCenterX(circle, body: circle.sourceBody), 23, accuracy: 1e-4)
        XCTAssertEqual(try exactTopCenterX(circle, body: circle.childBody), 23, accuracy: 1e-4)
        circle.model.undo()
        XCTAssertEqual(try datum(circle).plane.origin.x, 20, accuracy: 1e-3)
        guard case let .circle(_, afterFirstUndo, _) = try source(circle).entities[0] else { return XCTFail("Expected circle") }
        XCTAssertEqual(afterFirstUndo.x, 20, accuracy: 1e-3)
        XCTAssertEqual(try exactTopCenterX(circle, body: circle.sourceBody), 20, accuracy: 1e-4)
        XCTAssertEqual(try exactTopCenterX(circle, body: circle.childBody), 20, accuracy: 1e-4)
        circle.model.undo()
        XCTAssertEqual(try source(circle), circle.source)
        XCTAssertEqual(try datum(circle).plane.origin.x, 15, accuracy: 1e-3)
        XCTAssertEqual(try exactTopCenterX(circle, body: circle.sourceBody), 15, accuracy: 1e-4)
        XCTAssertEqual(try exactTopCenterX(circle, body: circle.childBody), 15, accuracy: 1e-4)
        XCTAssertEqual(try volume(circle, body: circle.sourceBody), .pi * 25 * 10, accuracy: 1e-3)
    }

    func testWeldAndEntityMoveShareOneUndo() async throws {
        let f = try await fixture()
        let first = UUID(), second = UUID()
        f.document.session.perform(AddSketchEntitiesCommand(sketchID: f.source.id, entities: [
            .line(id: first, a: SIMD2(60, 10), b: SIMD2(65, 10)),
            .line(id: second, a: SIMD2(70, 10), b: SIMD2(75, 10))
        ]))
        let baseline = try source(f)
        let settings = f.model.autoConstrainSettings
        defer { f.model.autoConstrainSettings = settings }
        var enabled = settings; enabled.enabled = true; enabled.pointSnap = true
        f.model.autoConstrainSettings = enabled
        let count = f.document.session.undoStack.undoCommands.count
        let id = try begin(f, at: SIMD2(65, 10))
        move(f, to: SIMD2(70, 10), id: id)
        end(f, at: SIMD2(70, 10), id: id)
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, count + 1)
        XCTAssertTrue(try source(f).constraints.contains { $0.kind == .coincident && Set($0.refs.map(\.entityID)) == [first, second] })
        f.model.undo()
        XCTAssertEqual(try source(f), baseline)
    }

    func testDoneCommitsButModeSwitchCancelsAndCloseFencesLateCallbacks() async throws {
        let f = try await fixture()
        let count = f.document.session.undoStack.undoCommands.count
        let done = try begin(f, at: SIMD2(40, 30))
        move(f, to: SIMD2(50, 35), id: done)
        f.model.finishSketch()
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, count + 1)
        XCTAssertEqual(try volume(f, body: f.sourceBody), 17500, accuracy: 1e-3)
        f.model.undo()
        f.model.mode = .sketching(f.source.id, tool: nil)
        let cancelled = try begin(f, at: SIMD2(40, 30))
        move(f, to: SIMD2(50, 35), id: cancelled)
        f.model.mode = .idle
        XCTAssertEqual(try source(f), f.source)
        f.model.mode = .sketching(f.source.id, tool: nil)
        let closing = try begin(f, at: SIMD2(40, 30))
        move(f, to: SIMD2(50, 35), id: closing)
        f.document.close()
        move(f, to: SIMD2(80, 80), id: closing)
        end(f, at: SIMD2(80, 80), id: closing)
        XCTAssertEqual(try source(f), f.source)
        XCTAssertTrue(f.document.isClosed)
        XCTAssertFalse(f.document.session.isSketchPreviewActive)
    }

    func testNoMovementGestureAndCircleFrameOnlyAreNotGeometryHistory() async throws {
        let f = try await fixture(circle: true)
        f.model.selectedSketchEntityIDs = [f.source.entities[0].id]
        f.model.sketchTransformActive = true
        let count = f.document.session.undoStack.undoCommands.count
        let bytes = try CADAssociativeFormatFixture.bytes(f.document.url)
        let gesture = try XCTUnwrap(f.model.beginSketchTransformControlGesture(.rotation))
        f.model.updateSketchTransformControl(.rotation, value: 30, gestureID: gesture)
        f.model.endSketchTransformControl(gestureID: gesture)
        XCTAssertEqual(try source(f), f.source)
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, count)
        XCTAssertFalse(f.document.hasUnsavedChanges)
        XCTAssertEqual(try CADAssociativeFormatFixture.bytes(f.document.url), bytes)
    }

    func testPublicContextInputAdapterUsesTouchDownDeltaAndExplicitCancellation() async throws {
        let f = try await fixture(circle: true)
        f.model.selectedSketchEntityIDs = [f.source.entities[0].id]
        f.model.sketchTransformActive = true
        let coordinator = CADSketchControlDragGesture.Coordinator()
        var ended = 0, cancelled = 0
        let callbacks = CADSketchControlDragGesture(onBegan: {
            f.model.beginSketchTransformControlGesture(.x)
        }, onChanged: { delta, id in
            f.model.updateSketchTransformControl(.x, value: delta.x, gestureID: id)
        }, onEnded: { id in
            ended += 1; f.model.endSketchTransformControl(gestureID: id)
        }, onCancelled: { id in
            cancelled += 1; _ = f.model.cancelSketchDragGesture(id)
        })
        coordinator.receive(state: .began, point: CGPoint(x: 100, y: 200), callbacks: callbacks)
        coordinator.receive(state: .changed, point: CGPoint(x: 103, y: 200), callbacks: callbacks)
        guard case let .circle(_, center, _) = try source(f).entities[0] else { return XCTFail("Expected source circle") }
        XCTAssertEqual(center.x, 18, accuracy: 1e-4, "First 3pt are not lost to a late pan threshold")
        coordinator.receive(state: .cancelled, point: CGPoint(x: 103, y: 200), callbacks: callbacks)
        XCTAssertEqual(ended, 0)
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(try source(f), f.source)
        coordinator.receive(state: .began, point: CGPoint(x: 100, y: 200), callbacks: callbacks)
        coordinator.receive(state: .ended, point: CGPoint(x: 105, y: 200), callbacks: callbacks)
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(try datum(f).plane.origin.x, 20, accuracy: 1e-3)
    }
    @MainActor
    private final class ModelInputDelegate: ViewportGestureDelegate {
        let model: EditorViewModel
        var leases: [UUID: EditorViewModel.SketchDragGestureID] = [:]
        var ended = 0
        var cancelled = 0
        init(_ model: EditorViewModel) { self.model = model }
        private func ray(_ point: CGPoint) -> Ray {
            Ray(origin: SIMD3(Float(point.x), 100, -Float(point.y)), direction: SIMD3(0, -1, 0))
        }
        func gestureDragBegan(at point: CGPoint, isPencil: Bool) -> Bool { model.beginSketchStroke(ray: ray(point)) }
        func gestureDragChanged(at point: CGPoint) {}
        func gestureDragEnded(at point: CGPoint) {}
        func gestureDragBegan(at point: CGPoint, isPencil: Bool, gestureID: UUID) -> Bool {
            guard model.beginSketchStroke(ray: ray(point)), let lease = model.currentSketchDragGestureID else { return false }
            leases[gestureID] = lease
            return true
        }
        func gestureDragChanged(at point: CGPoint, gestureID: UUID) {
            if let lease = leases[gestureID] { model.updateSketchStroke(ray: ray(point), gestureID: lease) }
        }
        func gestureDragEnded(at point: CGPoint, gestureID: UUID) {
            if let lease = leases.removeValue(forKey: gestureID) {
                ended += 1; model.endSketchStroke(ray: ray(point), gestureID: lease)
            }
        }
        func gestureDragCancelled(at point: CGPoint, gestureID: UUID) {
            if let lease = leases.removeValue(forKey: gestureID) {
                cancelled += 1; _ = model.cancelSketchDragGesture(lease)
            }
        }
        func gestureTapped(at point: CGPoint) {}
        func gestureDoubleTapped(at point: CGPoint) {}
        func gestureLongPressed(at point: CGPoint) {}
        func gestureHovered(at point: CGPoint?) {}
        func gesturePencilDoubleTapped() {}
    }

    func testActualViewportInputCompletionRoutesCancelSeparatelyFromCommit() async throws {
        let f = try await fixture()
        let delegate = ModelInputDelegate(f.model)
        let controller = ViewportGestureController()
        controller.delegate = delegate
        let count = f.document.session.undoStack.undoCommands.count
        XCTAssertTrue(controller.claimDrag(at: CGPoint(x: 40, y: 30), isPencil: true))
        controller.changeClaimedDrag(at: CGPoint(x: 50, y: 35))
        XCTAssertNotEqual(try source(f).entities, f.source.entities)
        controller.finishClaimedDrag(at: CGPoint(x: 50, y: 35), cancelled: true)
        XCTAssertEqual(delegate.cancelled, 1)
        XCTAssertEqual(delegate.ended, 0)
        XCTAssertEqual(try source(f), f.source)
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, count)
        XCTAssertTrue(controller.claimDrag(at: CGPoint(x: 40, y: 30), isPencil: true))
        controller.changeClaimedDrag(at: CGPoint(x: 50, y: 35))
        controller.finishClaimedDrag(at: CGPoint(x: 50, y: 35), cancelled: false)
        XCTAssertEqual(delegate.ended, 1)
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, count + 1)
        XCTAssertEqual(try volume(f, body: f.sourceBody), 17500, accuracy: 1e-3)
    }

    func testReadonlyCannotAcquireAndPlainDocumentKeepsLegacyDrag() async throws {
        let readonly = try await fixture()
        let count = readonly.document.session.undoStack.undoCommands.count
        readonly.document.project.formatVersion = Project.currentFormatVersion + 1
        XCTAssertFalse(readonly.model.beginSketchStroke(ray: ray(SIMD2(40, 30))))
        XCTAssertFalse(readonly.document.session.isSketchPreviewActive)
        XCTAssertEqual(try source(readonly), readonly.source)
        XCTAssertEqual(readonly.document.session.undoStack.undoCommands.count, count)

        let plain = try await fixture()
        plain.model.undo() // Removes the associated child transaction completely.
        XCTAssertTrue(plain.document.session.document.planes.isEmpty)
        XCTAssertFalse(plain.document.session.document.sketches.contains { $0.support != nil })
        let oldCount = plain.document.session.undoStack.undoCommands.count
        let id = try begin(plain, at: SIMD2(40, 30))
        move(plain, to: SIMD2(50, 35), id: id)
        XCTAssertFalse(plain.document.session.isSketchPreviewActive)
        end(plain, at: SIMD2(50, 35), id: id)
        XCTAssertEqual(try volume(plain, body: plain.sourceBody), 17500, accuracy: 1e-3)
        XCTAssertEqual(plain.document.session.undoStack.undoCommands.count, oldCount + 2,
                       "The unchanged plain path still has its historical source/rebuild steps")
    }

}

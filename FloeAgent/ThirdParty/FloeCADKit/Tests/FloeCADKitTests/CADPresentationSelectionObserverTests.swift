import Foundation
import XCTest
#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import SwiftUI
import UIKit
import Observation
@testable import FloeCAD

/// Requires an actual UIKit App-hosted test target with a UIWindowScene.
/// Hosts production Present + the same publisher used by the public wrapper.
/// Component pick/raycast tests and physical touch acceptance are separate.
@MainActor
final class CADPresentationSelectionObserverTests: XCTestCase {
    private var documents: [FloeCADDocument] = []
    private var directories: [URL] = []
    private var stores: [CADPresentationSceneStore] = []
    private var handles: [CADPresentationHandle] = []
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var hosting: UIHostingController<AnyView>?

    private final class Recorder {
        struct Record { var owner: ObjectIdentifier; var context: CADSelectionContext }
        var records: [Record] = []
        var waiting: [(XCTestExpectation, (Record) -> Bool)] = []
        func next(_ description: String, matching: @escaping (Record) -> Bool) -> XCTestExpectation {
            let expectation = XCTestExpectation(description: description)
            waiting.append((expectation, matching))
            return expectation
        }
        func record(owner: ObjectIdentifier, context: CADSelectionContext) {
            let record = Record(owner: owner, context: context)
            records.append(record)
            let matches = waiting.filter { $0.1(record) }
            waiting.removeAll { $0.1(record) }
            for (expectation, _) in matches { expectation.fulfill() }
        }
    }

    private struct Fixture {
        var document: FloeCADDocument
        var bodyID: BodyID
        var store: CADPresentationSceneStore
        var handle: CADPresentationHandle
    }

    override func tearDown() async throws {
        // Dispose only the test window and synthetic documents; restore the
        // application's prior key window rather than disturbing its workspace.
        hosting?.rootView = AnyView(EmptyView())
        window?.isHidden = true
        window?.rootViewController = nil
        hosting = nil; window = nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        for store in stores { store.stopObserving() }
        for handle in handles { handle.controller?.release() }
        for document in documents {
            CADPresentationCaptureRegistry.shared.unregister(document)
            document.close()
        }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        documents = []; directories = []; stores = []; handles = []
    }

    private func fixture(name: String = "Observer source") async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PresentObserver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("Observer.floecad"), name: name)
        documents.append(document)
        let bodyID = BodyID()
        let node = FeatureNode(name: name, kind: .primitive(
            spec: .box(width: 40, depth: 20, height: 10), placement: .identity), outputBodyIDs: [bodyID])
        document.session.recordAndRebuild([node], title: name)
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        let saved = await document.save()
        XCTAssertNil(saved.error)
        return presentation(document, bodyID: bodyID)
    }

    private func presentation(_ document: FloeCADDocument, bodyID: BodyID) -> Fixture {
        let store = CADPresentationSceneStore(document: document)
        let handle = CADPresentationHandle()
        stores.append(store); handles.append(handle)
        return Fixture(document: document, bodyID: bodyID, store: store, handle: handle)
    }

    private func observer(_ fixture: Fixture, recorder: Recorder) -> CADSelectionObserverBox {
        let owner = ObjectIdentifier(fixture.document)
        return CADSelectionObserverBox { recorder.record(owner: owner, context: $0) }
    }

    private func pane(_ fixture: Fixture, recorder: Recorder) -> AnyView {
        AnyView(CADPresentationPresentationPane(document: fixture.document,
            handle: fixture.handle, store: fixture.store, onEdit: {})
            .modifier(CADPresentationSelectionObserver(document: fixture.document))
            .environment(\.cadSelectionObserver, observer(fixture, recorder: recorder))
            .id(ObjectIdentifier(fixture.document)))
    }

    private func mount(_ view: AnyView) throws {
        if let hosting { hosting.rootView = view; return }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive },
            "Run this suite in the App-hosted UIKit target; hostless xctest has no UIWindowScene.")
        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let hosting = UIHostingController(rootView: view)
        window.rootViewController = hosting
        self.window = window; self.hosting = hosting
        window.makeKeyAndVisible()
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
    }

    private func mount(_ fixture: Fixture, recorder: Recorder) async throws {
        let owner = ObjectIdentifier(fixture.document)
        let initial = recorder.next("initial Present context") { $0.owner == owner }
        try mount(pane(fixture, recorder: recorder))
        await fulfillment(of: [initial], timeout: 10)
    }

    private func hide() async throws {
        let hidden = XCTestExpectation(description: "production publisher removed from hierarchy")
        try mount(AnyView(Color.clear.onAppear { hidden.fulfill() }))
        await fulfillment(of: [hidden], timeout: 10)
    }

    func testHostedPresentInitialBodyAndClearPublishWithoutDocumentEdits() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()
        let revision = fixture.document.revision
        let generation = fixture.document.liveChangeCount
        let bodyBytes = try Data(contentsOf: fixture.document.url.appendingPathComponent("document.json"))
        try await mount(fixture, recorder: recorder)
        XCTAssertTrue(try XCTUnwrap(recorder.records.first).context.isEmpty)
        let bodyID = fixture.bodyID.raw.uuidString
        let selected = recorder.next("live body callback") { $0.context.bodies.map(\.id) == [bodyID] && $0.context.faces.isEmpty }
        XCTAssertTrue(fixture.document.viewModel().selectPresentation(bodyID: fixture.bodyID))
        await fulfillment(of: [selected], timeout: 10)
        let cleared = recorder.next("blank clears host callback") { $0.context.isEmpty }
        XCTAssertTrue(fixture.document.viewModel().selectPresentation(bodyID: nil))
        await fulfillment(of: [cleared], timeout: 10)
        XCTAssertEqual(fixture.document.revision, revision)
        XCTAssertEqual(fixture.document.liveChangeCount, generation)
        XCTAssertFalse(fixture.document.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: fixture.document.url.appendingPathComponent("document.json")), bodyBytes)
    }

    func testHostedEqualTriangleCountFacesPublishDifferentActualFaceGeometry() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()
        try await mount(fixture, recorder: recorder)
        let body = try XCTUnwrap(fixture.document.session.document.body(with: fixture.bodyID))
        let planar = FaceTopology.enumerateFaces(in: body.render).planar
        let first = try XCTUnwrap(planar.first)
        let second = try XCTUnwrap(planar.first {
            $0.triangles.count == first.triangles.count && Set($0.triangles) != Set(first.triangles)
        })
        let firstExpected = CADSelectionContext.capture(document: fixture.document, bodyIDs: [fixture.bodyID],
            facePicks: [.init(bodyID: fixture.bodyID.raw, triangles: first.triangles, curved: false)]).faces
        let secondExpected = CADSelectionContext.capture(document: fixture.document, bodyIDs: [fixture.bodyID],
            facePicks: [.init(bodyID: fixture.bodyID.raw, triangles: second.triangles, curved: false)]).faces
        XCTAssertNotEqual(firstExpected, secondExpected)
        let firstCallback = recorder.next("first exact selected face") { $0.context.faces == firstExpected }
        XCTAssertTrue(fixture.document.viewModel().selectPresentation(bodyID: fixture.bodyID, faceTriangles: first.triangles))
        await fulfillment(of: [firstCallback], timeout: 10)
        let secondCallback = recorder.next("different face with same triangle count") { $0.context.faces == secondExpected }
        XCTAssertTrue(fixture.document.viewModel().selectPresentation(bodyID: fixture.bodyID, faceTriangles: second.triangles))
        await fulfillment(of: [secondCallback], timeout: 10)
        XCTAssertEqual(recorder.records.last?.context.faces.first?.bodyID, fixture.bodyID.raw.uuidString)
        XCTAssertEqual(recorder.records.last?.context.faces.first?.triangleCount, second.triangles.count)
    }

    func testHostedAssemblyInstancePreservesIdentityAndClears() async throws {
        let fixture = try await fixture()
        let service = CADAssemblyService(document: fixture.document)
        let reply = service.handle(action: "addInstance", args: ["bodyID": fixture.bodyID.raw.uuidString,
            "name": "Placed copy", "transform": ["position": [60.0, 0.0, 0.0]]])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let instanceID = try XCTUnwrap(UUID(uuidString: reply["id"] as? String ?? ""))
        let saved = await fixture.document.save(); XCTAssertNil(saved.error)
        let recorder = Recorder()
        try await mount(fixture, recorder: recorder)
        let selected = recorder.next("instance callback") { $0.context.instances.map(\.id) == [instanceID.uuidString] }
        XCTAssertTrue(fixture.document.viewModel().selectPresentation(bodyID: fixture.bodyID, instanceID: instanceID))
        await fulfillment(of: [selected], timeout: 10)
        XCTAssertTrue(try XCTUnwrap(recorder.records.last).context.bodies.isEmpty)
        XCTAssertEqual(recorder.records.last?.context.instances.first?.bodyID, fixture.bodyID.raw.uuidString)
        let cleared = recorder.next("instance clears") { $0.context.isEmpty }
        XCTAssertTrue(fixture.document.viewModel().selectPresentation(bodyID: nil))
        await fulfillment(of: [cleared], timeout: 10)
    }

    func testHostedDocumentGenerationAndSavedRevisionRefreshContext() async throws {
        let fixture = try await fixture()
        let recorder = Recorder()
        try await mount(fixture, recorder: recorder)
        let bodyID = fixture.bodyID.raw.uuidString
        let selected = recorder.next("body selected before edit") { $0.context.bodies.map(\.id) == [bodyID] }
        XCTAssertTrue(fixture.document.viewModel().selectPresentation(bodyID: fixture.bodyID))
        await fulfillment(of: [selected], timeout: 10)
        let oldGeneration = fixture.document.liveChangeCount
        let changed = recorder.next("document generation callback") { $0.context.changeCount > oldGeneration }
        fixture.document.session.perform(AddConstructionPlaneCommand(plane: ConstructionPlane(plane: .ground, size: 10)))
        await fulfillment(of: [changed], timeout: 10)
        XCTAssertEqual(recorder.records.last?.context.bodies.map(\.id), [bodyID])
        let oldRevision = fixture.document.revision
        let savedRevision = recorder.next("saved document revision callback") { $0.context.documentRevision > oldRevision }
        let outcome = await fixture.document.save(); XCTAssertNil(outcome.error)
        // A durable identity change must notify the actual host automatically,
        // without forcing a child scene refresh or waiting for a poll timer.
        await fulfillment(of: [savedRevision], timeout: 10)
        XCTAssertEqual(recorder.records.last?.context.documentRevision, Int64(fixture.document.revision))
        XCTAssertEqual(recorder.records.last?.context.changeCount, fixture.document.liveChangeCount)
    }

    func testHostedDisappearAndReplacementCannotPublishOldDocument() async throws {
        let first = try await fixture(name: "First")
        let second = try await fixture(name: "Second")
        let recorder = Recorder()
        try await mount(first, recorder: recorder)
        let firstOwner = ObjectIdentifier(first.document), secondOwner = ObjectIdentifier(second.document)
        try await hide()
        try await mount(second, recorder: recorder)
        let countOfOld = recorder.records.filter { $0.owner == firstOwner }.count
        let newSelection = recorder.next("replacement live owner callback") {
            $0.owner == secondOwner && $0.context.bodies.map(\.id) == [second.bodyID.raw.uuidString]
        }
        // An offscreen old editor can still receive a late local event. Its
        // removed publisher cannot call the public host observer any more.
        XCTAssertTrue(first.document.viewModel().selectPresentation(bodyID: first.bodyID))
        XCTAssertTrue(second.document.viewModel().selectPresentation(bodyID: second.bodyID))
        await fulfillment(of: [newSelection], timeout: 10)
        XCTAssertEqual(recorder.records.filter { $0.owner == firstOwner }.count, countOfOld)
    }

    func testHostedReopenSameURLUsesNewLiveDocumentIdentity() async throws {
        let first = try await fixture()
        let recorder = Recorder()
        try await mount(first, recorder: recorder)
        try await hide()
        first.document.close()
        let reopened = try await FloeCADDocument.open(at: first.document.url)
        documents.append(reopened)
        let second = presentation(reopened, bodyID: first.bodyID)
        XCTAssertNotEqual(ObjectIdentifier(first.document), ObjectIdentifier(reopened))
        try await mount(second, recorder: recorder)
        let before = recorder.records.filter { $0.owner == ObjectIdentifier(first.document) }.count
        let current = recorder.next("same URL new owner selection") {
            $0.owner == ObjectIdentifier(reopened) && !$0.context.bodies.isEmpty
        }
        _ = first.document.viewModel().selectPresentation(bodyID: first.bodyID)
        XCTAssertTrue(reopened.viewModel().selectPresentation(bodyID: first.bodyID))
        await fulfillment(of: [current], timeout: 10)
        XCTAssertEqual(recorder.records.filter { $0.owner == ObjectIdentifier(first.document) }.count, before)
    }

    @Observable
    fileprivate final class ModeState {
        var present = false
        var appeared: ((Bool) -> Void)?
    }
    private struct ModeContent: View {
        let fixture: Fixture
        let state: ModeState
        let observer: CADSelectionObserverBox
        var body: some View {
            Group {
                if state.present {
                    CADPresentationPresentationPane(document: fixture.document, handle: fixture.handle,
                        store: fixture.store, onEdit: {}).onAppear { state.appeared?(true) }
                } else {
                    FloeCADEditorView(document: fixture.document, canvasActions: nil)
                        .onAppear { state.appeared?(false) }
                }
            }
            .modifier(CADPresentationSelectionObserver(document: fixture.document))
            .environment(\.cadSelectionObserver, observer)
        }
    }

    func testHostedEditToPresentHasOnePublisherForLiveSelection() async throws {
        let fixture = try await fixture()
        let recorder = Recorder(), state = ModeState()
        let initial = recorder.next("wrapped Edit initial context") { _ in true }
        try mount(AnyView(ModeContent(fixture: fixture, state: state,
                                    observer: observer(fixture, recorder: recorder))))
        await fulfillment(of: [initial], timeout: 10)
        let appeared = XCTestExpectation(description: "production Present pane appeared")
        state.appeared = { if $0 { appeared.fulfill() } }
        state.present = true
        await fulfillment(of: [appeared], timeout: 10)
        let bodyID = fixture.bodyID.raw.uuidString
        let selected = recorder.next("selection event after switching rendering mode") { $0.context.bodies.map(\.id) == [bodyID] }
        XCTAssertTrue(fixture.document.viewModel().selectPresentation(bodyID: fixture.bodyID))
        await fulfillment(of: [selected], timeout: 10)
        let selectedRecords = recorder.records.filter { $0.context.bodies.map(\.id) == [bodyID] }
        let byFence = Dictionary(grouping: selectedRecords, by: { $0.context.observationKey })
        XCTAssertTrue(byFence.values.allSatisfy { $0.count == 1 },
                      "One selection/revision fence has one publisher; a later real save may legitimately notify again")
    }
}
#endif

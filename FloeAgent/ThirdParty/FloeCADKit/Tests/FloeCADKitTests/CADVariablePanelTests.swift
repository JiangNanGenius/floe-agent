import Foundation
import XCTest
@testable import FloeCAD

@MainActor
final class CADVariablePanelTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("VariablePanel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for document in documents where !document.isClosed { document.close() }
        documents.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func makeDocument() async throws -> FloeCADDocument {
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("\(UUID().uuidString).floecad"), name: "Panel")
        documents.append(document)
        return document
    }

    private func run(_ document: FloeCADDocument, op: String, args: [String: Any]) throws -> [String: Any] {
        let result = document.executeJSON(try JSONSerialization.data(withJSONObject: ["op": op, "args": args]))
        XCTAssertTrue(result.isOK, result.message ?? "command failed")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
    }

    private func box(_ document: FloeCADDocument) throws -> FeatureID {
        let sketch = try run(document, op: "sketch.create", args: ["name": "Plate"])
        let id = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try run(document, op: "sketch.addEntities", args: ["sketchID": id,
            "entities": [["kind": "rect", "min": [0, 0], "max": [40, 20]]]])
        _ = try run(document, op: "feature.extrude", args: ["sketchID": id, "seedPoint": [5, 5], "distance": 10])
        return try XCTUnwrap(document.session.document.features.nodes.last?.id)
    }

    private func bind(_ document: FloeCADDocument, feature: FeatureID, expression: String) {
        let reply = CADParameterService(document: document).handle(action: "feature.setExpression", args: [
            "feature_id": feature.raw.uuidString, "parameter": "distance", "expression": expression])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
    }

    private func variable(_ document: FloeCADDocument, named name: String) throws -> Variable {
        try XCTUnwrap(document.session.document.variables.first { $0.name == name })
    }

    private func volume(_ document: FloeCADDocument) throws -> Double {
        OCCTKernel.volume(try XCTUnwrap(document.session.document.bodies.first?.brep))
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func testPanelUpdateAndDependentGeometryAreOneUndoStep() async throws {
        let document = try await makeDocument()
        let feature = try box(document)
        let model = document.viewModel()
        XCTAssertEqual(model.createVariable(holding: "10", preferredName: "height"), "height")
        bind(document, feature: feature, expression: "height")
        let height = try variable(document, named: "height")
        let count = document.session.undoStack.undoCommands.count
        model.setVariable(height.id, name: "height", expression: "20")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, count + 1)
        XCTAssertEqual(try volume(document), 16_000, accuracy: 1e-3)
        model.undo()
        XCTAssertEqual(try variable(document, named: "height").expression, "10")
        XCTAssertEqual(try volume(document), 8_000, accuracy: 1e-3)
        model.redo()
        XCTAssertEqual(try variable(document, named: "height").expression, "20")
        XCTAssertEqual(try volume(document), 16_000, accuracy: 1e-3)
    }

    func testPanelRenameRewritesReferenceTokensThroughTheSharedService() async throws {
        let document = try await makeDocument()
        let feature = try box(document)
        let model = document.viewModel()
        XCTAssertEqual(model.createVariable(holding: "10", preferredName: "w"), "w")
        XCTAssertEqual(model.createVariable(holding: "3", preferredName: "w2"), "w2")
        XCTAssertEqual(model.createVariable(holding: "2", preferredName: "width"), "width")
        XCTAssertEqual(model.createVariable(holding: "max(w,w2)+width", preferredName: "derived"), "derived")
        bind(document, feature: feature, expression: "w + w2 + width")
        let w = try variable(document, named: "w")
        model.setVariable(w.id, name: "thickness", expression: "10")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try variable(document, named: "derived").expression, "max(thickness,w2)+width")
        XCTAssertEqual(try variable(document, named: "w2").value, 3)
        XCTAssertEqual(try variable(document, named: "width").value, 2)
        let node = try XCTUnwrap(document.session.document.features.node(feature))
        guard case let .extrude(_, _, distance, _, _, _) = node.kind else { return XCTFail("expected extrude") }
        XCTAssertEqual(distance.formula, "thickness + w2 + width")
        XCTAssertEqual(try volume(document), 12_000, accuracy: 1e-3)
        model.undo()
        XCTAssertEqual(try variable(document, named: "w").value, 10)
        XCTAssertEqual(try variable(document, named: "derived").expression, "max(w,w2)+width")
    }

    func testPanelReferencedDeleteRefusesWithoutChangingHistoryOrGeometry() async throws {
        let document = try await makeDocument()
        let feature = try box(document)
        let model = document.viewModel()
        _ = model.createVariable(holding: "10", preferredName: "height")
        bind(document, feature: feature, expression: "height")
        let height = try variable(document, named: "height")
        let beforeVariables = try encoded(document.session.document.variables)
        let beforeGraph = try encoded(document.session.document.features)
        let beforeShape = try XCTUnwrap(OCCTKernel.serialize(try XCTUnwrap(document.session.document.bodies.first?.brep)))
        let beforeUndo = document.session.undoStack.undoCommands.map(\.title)
        let generation = document.liveChangeCount
        model.deleteVariable(height.id)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try encoded(document.session.document.variables), beforeVariables)
        XCTAssertEqual(try encoded(document.session.document.features), beforeGraph)
        XCTAssertEqual(OCCTKernel.serialize(try XCTUnwrap(document.session.document.bodies.first?.brep)), beforeShape)
        XCTAssertEqual(document.session.undoStack.undoCommands.map(\.title), beforeUndo)
        XCTAssertEqual(document.liveChangeCount, generation)
    }

    func testPanelInvalidFormulaAndFailedRebuildPreservePreexistingRedo() async throws {
        let document = try await makeDocument()
        let feature = try box(document)
        let model = document.viewModel()
        _ = model.createVariable(holding: "10", preferredName: "height")
        bind(document, feature: feature, expression: "height")
        let height = try variable(document, named: "height")
        model.setVariable(height.id, name: "height", expression: "20")
        model.undo()
        let variables = try encoded(document.session.document.variables)
        let graph = try encoded(document.session.document.features)
        let shape = try XCTUnwrap(OCCTKernel.serialize(try XCTUnwrap(document.session.document.bodies.first?.brep)))
        let undo = document.session.undoStack.undoCommands.map(\.title)
        let redo = document.session.undoStack.redoCommands.map(\.title)
        XCTAssertFalse(redo.isEmpty)
        for expression in ["missing + 1", "1/0", "0"] {
            model.setVariable(height.id, name: "height", expression: expression)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(try encoded(document.session.document.variables), variables)
            XCTAssertEqual(try encoded(document.session.document.features), graph)
            XCTAssertEqual(OCCTKernel.serialize(try XCTUnwrap(document.session.document.bodies.first?.brep)), shape)
            XCTAssertEqual(document.session.undoStack.undoCommands.map(\.title), undo)
            XCTAssertEqual(document.session.undoStack.redoCommands.map(\.title), redo)
            XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        }
        model.redo()
        XCTAssertEqual(try variable(document, named: "height").expression, "20")
        XCTAssertEqual(try volume(document), 16_000, accuracy: 1e-3)
        XCTAssertFalse(document.session.undoStack.canRedo)
    }

    func testPanelSaveReopenKeepsFormulaAndBindsTheNewEditor() async throws {
        let document = try await makeDocument()
        let feature = try box(document)
        let model = document.viewModel()
        _ = model.createVariable(holding: "10", preferredName: "height")
        bind(document, feature: feature, expression: "height")
        let height = try variable(document, named: "height")
        model.setVariable(height.id, name: "height", expression: "15")
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        documents.append(reopened)
        XCTAssertEqual(try variable(reopened, named: "height").expression, "15")
        XCTAssertEqual(try volume(reopened), 12_000, accuracy: 1e-3)
        let reopenedVariable = try variable(reopened, named: "height")
        reopened.viewModel().setVariable(reopenedVariable.id, name: "height", expression: "25")
        XCTAssertNil(reopened.viewModel().errorMessage)
        XCTAssertEqual(try volume(reopened), 20_000, accuracy: 1e-3)
        reopened.viewModel().undo()
        XCTAssertEqual(try volume(reopened), 12_000, accuracy: 1e-3)
    }

    func testPanelDefaultsAreCaseInsensitiveAndUnboundEditorRefuses() async throws {
        let document = try await makeDocument()
        let model = document.viewModel()
        XCTAssertEqual(model.createVariable(holding: "1", preferredName: "VAR1"), "VAR1")
        model.addVariable()
        XCTAssertEqual(try variable(document, named: "var2").expression, "0")
        XCTAssertEqual(model.createVariable(holding: "2", preferredName: "1 invalid name"), "var3")
        let longName = String(repeating: "a", count: 100)
        XCTAssertEqual(model.createVariable(holding: "3", preferredName: longName), longName)
        let suffixed = try XCTUnwrap(model.createVariable(holding: "4", preferredName: longName))
        XCTAssertEqual(suffixed.count, 100)
        XCTAssertNotEqual(suffixed, longName)
        let disposable = try variable(document, named: "var2")
        let count = document.session.undoStack.undoCommands.count
        model.deleteVariable(disposable.id)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(document.session.document.variables.contains { $0.id == disposable.id })
        XCTAssertEqual(document.session.undoStack.undoCommands.count, count + 1)
        model.undo()
        XCTAssertEqual(try variable(document, named: "var2").expression, "0")
        let before = try encoded(document.session.document.variables)
        let undo = document.session.undoStack.undoCommands.map(\.title)
        let generation = document.liveChangeCount
        model.variableActionHandler = nil
        XCTAssertNil(model.createVariable(holding: "9", preferredName: "unbound"))
        model.addVariable()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try encoded(document.session.document.variables), before)
        XCTAssertEqual(document.session.undoStack.undoCommands.map(\.title), undo)
        XCTAssertEqual(document.liveChangeCount, generation)
    }

    func testPanelRefusesAllActionsDuringRealRotatePreviewWithoutCancellingIt() async throws {
        let document = try await makeDocument()
        _ = try box(document)
        let model = document.viewModel()
        _ = model.createVariable(holding: "10", preferredName: "height")
        let height = try variable(document, named: "height")
        let body = try XCTUnwrap(document.session.document.bodies.first)
        model.selection = [body.id]
        model.beginRotateAxisPick()
        model.setRotateWorldAxis(.z)
        model.setRotateAngle(30)
        XCTAssertEqual(model.rotateAxisState?.angleDegrees, 30)
        let previewTransform = try XCTUnwrap(document.session.document.body(with: body.id)?.transform)
        XCTAssertNotEqual(previewTransform, body.transform, "fixture must install a real uncommitted rotate preview")
        let variables = try encoded(document.session.document.variables)
        let undo = document.session.undoStack.undoCommands.map(\.title)
        let redo = document.session.undoStack.redoCommands.map(\.title)
        let generation = document.liveChangeCount
        XCTAssertNil(model.createVariable(holding: "1", preferredName: "blocked"))
        model.addVariable()
        model.setVariable(height.id, name: "height", expression: "20")
        model.deleteVariable(height.id)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.rotateAxisState?.angleDegrees, 30)
        XCTAssertEqual(document.session.document.body(with: body.id)?.transform, previewTransform)
        XCTAssertEqual(try encoded(document.session.document.variables), variables)
        XCTAssertEqual(document.session.undoStack.undoCommands.map(\.title), undo)
        XCTAssertEqual(document.session.undoStack.redoCommands.map(\.title), redo)
        XCTAssertEqual(document.liveChangeCount, generation)
        model.cancelRotateAxis()
        XCTAssertEqual(document.session.document.body(with: body.id)?.transform, body.transform)
    }
}

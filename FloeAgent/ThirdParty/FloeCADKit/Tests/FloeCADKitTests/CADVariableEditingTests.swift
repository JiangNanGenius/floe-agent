//
//  CADVariableEditingTests.swift
//  FloeCADKitTests
//
//  The LLM-facing variable/formula editing contract, exercised through the REAL
//  production services:
//
//    * `CADParameterService.variable.create/update/delete` and
//      `feature.setExpression` validate names, functions, references and cycles
//      BEFORE any command is built;
//    * one variable edit plus every downstream feature/sketch rebuild is ONE
//      undo/redo transaction (the geometry assertions read the real kernel);
//    * a rename rewrites identifier TOKENS only (`w2`, `width`, `max(` survive);
//    * deletion refuses with the exact dependent IDs while the name is used;
//    * a public degree formula bound to the radian-persisted rotateFace angle
//      stores an explicit radians(...) conversion, never degrees as radians;
//    * query kind=variables/features exposes ids, formulas, resolved values,
//      unit contracts and dependencies;
//    * failed edits preserve the document AND the redo stack, and save/reopen
//      persists the formula source and resolved geometry.
//
//  The fixture helpers create geometry with the same typed commands the tool
//  uses; no renderer, fake service or fabricated result is involved.
//

import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADVariableEditingTests: XCTestCase {
    private var workDir: URL!
    private var openDocuments: [FloeCADDocument] = []

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADVariables-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for document in openDocuments where !document.isClosed {
            document.close()
        }
        openDocuments.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Fixtures

    private func makeDocument(_ name: String = "Variables") async throws -> FloeCADDocument {
        let url = workDir.appendingPathComponent("\(name)-\(UUID().uuidString).floecad")
        let document = try await FloeCADDocument.create(at: url, name: name)
        openDocuments.append(document)
        return document
    }

    @discardableResult
    private func run(_ document: FloeCADDocument, _ op: String,
                     _ args: [String: Any],
                     file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: ["op": op, "args": args])
        let result = document.executeJSON(input)
        XCTAssertTrue(result.isOK,
                      "\(op): \(result.errorCode ?? "") \(result.message ?? "")",
                      file: file, line: line)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: result.payload) as? [String: Any],
            file: file, line: line)
        XCTAssertNotEqual(payload["failed"] as? Bool, true, "\(op): \(payload)",
                          file: file, line: line)
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "\(op): \(document.session.lastEvalErrors)",
                      file: file, line: line)
        return payload
    }

    private func rows(_ document: FloeCADDocument, _ scope: String,
                      file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
        let result = document.nativeQueryJSON(["scope": scope])
        XCTAssertTrue(result.isOK, "\(scope): \(result.message ?? "")", file: file, line: line)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: result.payload) as? [String: Any],
            file: file, line: line)
        return try XCTUnwrap(payload["rows"] as? [[String: Any]], file: file, line: line)
    }

    private func addRectangleSketch(_ document: FloeCADDocument, y: Double = 0,
                                    withHole: Bool = false) throws -> String {
        let created = try run(document, "sketch.create", [
            "origin": [0, y, 0], "xAxis": [1, 0, 0], "yAxis": [0, 0, -1],
        ])
        let id = try XCTUnwrap(created["sketchID"] as? String)
        var entities: [[String: Any]] = [
            ["kind": "rect", "min": [0, 0], "max": [40, 20]],
        ]
        if withHole {
            entities.append(["kind": "rect", "min": [10, 5], "max": [30, 15]])
        }
        try run(document, "sketch.addEntities", ["sketchID": id, "entities": entities])
        return id
    }

    @discardableResult
    private func makeBox(_ document: FloeCADDocument,
                         distance: Double = 10) throws -> FeatureNode {
        let sketch = try addRectangleSketch(document)
        try run(document, "feature.extrude", [
            "sketchID": sketch, "seedPoint": [5, 5], "distance": distance,
        ])
        return try XCTUnwrap(document.session.document.features.nodes.last)
    }

    private func body(_ document: FloeCADDocument) throws -> Body {
        try XCTUnwrap(document.session.document.bodies.first)
    }

    private func volume(_ document: FloeCADDocument) throws -> Double {
        let current = try body(document)
        let result = document.measureJSON(["kind": "body",
                                           "bodyID": current.id.raw.uuidString])
        XCTAssertTrue(result.isOK, result.message ?? "")
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: result.payload) as? [String: Any])
        return try XCTUnwrap(payload["volumeMM3"] as? Double)
    }

    private func featureRow(_ document: FloeCADDocument, _ id: FeatureID) throws -> [String: Any] {
        try XCTUnwrap(try rows(document, "features").first {
            ($0["id"] as? String) == id.raw.uuidString
        })
    }

    private func parameterRow(_ document: FloeCADDocument, feature: FeatureID,
                              _ name: String) throws -> [String: Any] {
        let row = try featureRow(document, feature)
        let parameters = try XCTUnwrap(row["parameters"] as? [[String: Any]])
        return try XCTUnwrap(parameters.first { ($0["name"] as? String) == name })
    }

    private func variableRow(_ document: FloeCADDocument, _ id: String) throws -> [String: Any] {
        try XCTUnwrap(try rows(document, "variables").first { ($0["id"] as? String) == id })
    }

    private func variableID(_ reply: [String: Any],
                            file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let variable = try XCTUnwrap(reply["variable"] as? [String: Any],
                                     "reply has no variable row: \(reply)",
                                     file: file, line: line)
        return try XCTUnwrap(variable["id"] as? String, file: file, line: line)
    }

    @discardableResult
    private func createVariable(_ service: CADParameterService, name: String,
                                expression: String,
                                file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let reply = service.handle(action: "variable.create",
                                   args: ["name": name, "expression": expression])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)", file: file, line: line)
        return try variableID(reply, file: file, line: line)
    }

    @discardableResult
    private func setExpression(_ service: CADParameterService, feature: FeatureID,
                               parameter: String, expression: String,
                               expected: String? = nil,
                               file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        var args: [String: Any] = [
            "feature_id": feature.raw.uuidString,
            "parameter": parameter,
            "expression": expression,
        ]
        if let expected { args["expected_expression"] = expected }
        let reply = service.handle(action: "feature.setExpression", args: args)
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)", file: file, line: line)
        return reply
    }

    /// The production dimension command the inline field uses, invoked directly
    /// so a test can place a FORMULA on a dimension the service created with a
    /// numeric value. Value and geometry stay unchanged here.
    private func attachFormula(_ document: FloeCADDocument, sketchID: String,
                               dimensionID: String, formula: String) throws {
        let id = try XCTUnwrap(UUID(uuidString: sketchID))
        let sketch = try XCTUnwrap(document.session.document.sketches.first { $0.id.raw == id })
        let dimension = try XCTUnwrap(sketch.dimensions.first { $0.id.uuidString == dimensionID })
        var after = dimension
        after.formula = formula
        document.session.perform(UpdateSketchDimensionCommand(
            sketchID: sketch.id, before: dimension, after: after))
    }

    private func dimensionValue(_ document: FloeCADDocument, sketchID: String,
                                dimensionID: String) throws -> Double {
        let id = try XCTUnwrap(UUID(uuidString: sketchID))
        let sketch = try XCTUnwrap(document.session.document.sketches.first { $0.id.raw == id })
        return try XCTUnwrap(sketch.dimensions.first { $0.id.uuidString == dimensionID }).value
    }

    // A mesh-only rotation fixture (the B-rep writer correctly refuses to
    // degrade an exact solid; face rotation is supported on the mesh path).
    // Mirrors CADParameterCorrectnessTests so the REAL rotateFace evaluation
    // and its persisted-radian contract are exercised.
    private func makeMeshRotation(_ document: FloeCADDocument,
                                  degrees: Double) throws -> FeatureID {
        let first = try addRectangleSketch(document, withHole: true)
        let last = try addRectangleSketch(document, y: 10, withHole: true)
        try run(document, "feature.loft", ["sections": [
            ["sketchID": first, "seedPoint": [5, 5]],
            ["sketchID": last, "seedPoint": [5, 5]],
        ]])
        let source = try XCTUnwrap(document.session.document.features.nodes.last)
        let current = try body(document)
        XCTAssertNil(current.brep, "Fixture must exercise the supported mesh-only path")
        let table = document.session.naming.faceTable(
            for: current, createdBy: source.id, scheme: .generic)
        let top = try XCTUnwrap(table.entries.max { $0.signature.normal.y < $1.signature.normal.y })
        XCTAssertGreaterThan(top.signature.normal.y, 0.99)
        let ref = FaceRef(body: BodyRef(producer: source.id, bodyID: current.id),
                          creator: source.id, role: top.role, signature: top.signature)
        let node = FeatureNode(
            name: "Rotate Face",
            kind: .rotateFace(face: ref, angle: Expr(value: degrees * .pi / 180),
                              axis: PointWrapper(SIMD3(1, 0, 0))),
            outputBodyIDs: [current.id])
        document.session.recordAndRebuild([node], title: "Rotate Face")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "\(document.session.lastEvalErrors)")
        return node.id
    }

    // MARK: - Create, bind, update, one undo, persistence

    func testCreateBindAndUpdateVariableIsOneUndoAndPersists() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        let feature = try makeBox(document, distance: 10)
        XCTAssertEqual(try volume(document), 8_000, accuracy: 0.1)
        let service = CADParameterService(document: document)

        let id = try createVariable(service, name: "height", expression: "20")
        let created = try variableRow(document, id)
        XCTAssertEqual(created["name"] as? String, "height")
        XCTAssertEqual(created["formula"] as? String, "20")
        XCTAssertEqual(created["value"] as? Double, 20)
        XCTAssertEqual(created["unit"] as? String, "unitless")
        XCTAssertEqual(created["status"] as? String, "ok")
        XCTAssertEqual(created["update_action"] as? String, "variable.update")
        XCTAssertEqual(created["delete_action"] as? String, "variable.delete")

        _ = setExpression(service, feature: feature.id, parameter: "distance",
                          expression: "height")
        let parameter = try parameterRow(document, feature: feature.id, "distance")
        XCTAssertEqual(parameter["formula"] as? String, "height")
        XCTAssertEqual(parameter["value"] as? Double, 20)
        XCTAssertEqual(parameter["stored_value"] as? Double, 20)
        XCTAssertEqual(parameter["set_expression_unit"] as? String, "mm")
        XCTAssertEqual(try volume(document), 16_000, accuracy: 0.1)

        let update = service.handle(action: "variable.update", args: [
            "variable_id": id, "expression": "30", "expected_expression": "20",
        ])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        XCTAssertEqual(update["mutated"] as? Bool, true)
        XCTAssertEqual(try volume(document), 24_000, accuracy: 0.1)
        XCTAssertEqual(try variableRow(document, id)["value"] as? Double, 30)

        // ONE undo covers the variable and the rebuilt geometry.
        document.session.undo()
        XCTAssertEqual(try volume(document), 16_000, accuracy: 0.1)
        XCTAssertEqual(try variableRow(document, id)["expression"] as? String, "20")
        XCTAssertEqual(try parameterRow(document, feature: feature.id, "distance")["value"]
                       as? Double, 20)
        document.session.redo()
        XCTAssertEqual(try volume(document), 24_000, accuracy: 0.1)
        XCTAssertEqual(try variableRow(document, id)["value"] as? Double, 30)

        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        openDocuments.append(reopened)
        XCTAssertEqual(try volume(reopened), 24_000, accuracy: 0.1)
        let persisted = try parameterRow(reopened, feature: feature.id, "distance")
        XCTAssertEqual(persisted["formula"] as? String, "height")
        XCTAssertEqual(persisted["value"] as? Double, 30)
        XCTAssertEqual(try variableRow(reopened, id)["formula"] as? String, "30")
    }

    // MARK: - Rename: token-aware references across every formula owner

    func testRenameRewritesOnlyIdentifierTokensEverywhere() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        let sketch = try addRectangleSketch(document)
        try run(document, "feature.extrude", [
            "sketchID": sketch, "seedPoint": [5, 5], "distance": 10,
        ])
        let feature = try XCTUnwrap(document.session.document.features.nodes.last)
        let service = CADParameterService(document: document)

        let width = try createVariable(service, name: "w", expression: "40")
        _ = try createVariable(service, name: "w2", expression: "5")
        _ = try createVariable(service, name: "half", expression: "w / 2")

        // `w2` and the function call `max(` must never be treated as `w`.
        _ = setExpression(service, feature: feature.id, parameter: "distance",
                          expression: "max(w, w2) + w")

        let widthReply = service.handle(action: "setSketchDimension", args: [
            "sketch_id": sketch, "kind": "width", "entity_id": try rectEntityID(document, sketch),
            "value": 40,
        ])
        XCTAssertEqual(widthReply["ok"] as? Bool, true, "\(widthReply)")
        let dimension = try XCTUnwrap(widthReply["dimension"] as? [String: Any])
        let dimensionID = try XCTUnwrap(dimension["id"] as? String)
        try attachFormula(document, sketchID: sketch, dimensionID: dimensionID, formula: "w")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)

        let rename = service.handle(action: "variable.update", args: [
            "variable_id": width, "name": "span", "expected_expression": "40",
        ])
        XCTAssertEqual(rename["ok"] as? Bool, true, "\(rename)")
        XCTAssertEqual(rename["renamed_from"] as? String, "w")
        XCTAssertEqual((rename["rewritten_feature_ids"] as? [String])?.count, 1)
        XCTAssertEqual(rename["rewritten_dimension_ids"] as? [String], [dimensionID])

        let variables = try rows(document, "variables")
        XCTAssertEqual(Set(variables.compactMap { $0["name"] as? String }),
                       ["span", "w2", "half"])
        let half = try XCTUnwrap(variables.first { ($0["name"] as? String) == "half" })
        XCTAssertEqual(half["expression"] as? String, "span / 2")
        let w2 = try XCTUnwrap(variables.first { ($0["name"] as? String) == "w2" })
        XCTAssertEqual(w2["expression"] as? String, "5")
        XCTAssertEqual(try parameterRow(document, feature: feature.id, "distance")["formula"]
                       as? String, "max(span, w2) + span")
        let constraint = try XCTUnwrap(try rows(document, "constraints").first {
            ($0["id"] as? String) == dimensionID
        })
        XCTAssertEqual(constraint["formula"] as? String, "span")
        XCTAssertEqual(constraint["formula_unit"] as? String, "mm")
        XCTAssertEqual(constraint["formula_reference_names"] as? [String], ["span"])

        // The rename and BOTH rewrites are a single undo step (the formula
        // attach that preceded it is the step after this one).
        document.session.undo()
        let restored = try rows(document, "variables")
        XCTAssertEqual(Set(restored.compactMap { $0["name"] as? String }),
                       ["w", "w2", "half"])
        XCTAssertEqual(try parameterRow(document, feature: feature.id, "distance")["formula"]
                       as? String, "max(w, w2) + w")
        XCTAssertEqual(try rows(document, "constraints").first {
            ($0["id"] as? String) == dimensionID
        }?["formula"] as? String, "w")
    }

    func rectEntityID(_ document: FloeCADDocument, _ sketchID: String) throws -> String {
        let sketch = try XCTUnwrap(try rows(document, "sketches").first {
            ($0["id"] as? String) == sketchID
        })
        let entities = try XCTUnwrap(sketch["entityRows"] as? [[String: Any]])
        return try XCTUnwrap(entities.first { ($0["kind"] as? String) == "rect" }?["id"] as? String)
    }

    // MARK: - Deletion refusal

    func testDeleteRefusesWhileReferencedAndReturnsExactDependentIDs() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        let sketch = try addRectangleSketch(document)
        try run(document, "feature.extrude", [
            "sketchID": sketch, "seedPoint": [5, 5], "distance": 10,
        ])
        let feature = try XCTUnwrap(document.session.document.features.nodes.last)
        let service = CADParameterService(document: document)

        let width = try createVariable(service, name: "w", expression: "40")
        let derived = try createVariable(service, name: "derived", expression: "w + 1")
        _ = try createVariable(service, name: "unused", expression: "7")
        _ = setExpression(service, feature: feature.id, parameter: "distance",
                          expression: "w / 4")
        let widthReply = service.handle(action: "setSketchDimension", args: [
            "sketch_id": sketch, "kind": "width", "entity_id": try rectEntityID(document, sketch),
            "value": 40,
        ])
        XCTAssertEqual(widthReply["ok"] as? Bool, true, "\(widthReply)")
        let dimensionID = try XCTUnwrap(
            (widthReply["dimension"] as? [String: Any])?["id"] as? String)
        try attachFormula(document, sketchID: sketch, dimensionID: dimensionID, formula: "w")

        let changeCount = document.session.changeCount
        let undoCount = document.session.undoStack.undoCommands.count
        let refused = service.handle(action: "variable.delete", args: ["variable_id": width])
        XCTAssertEqual(refused["ok"] as? Bool, false, "\(refused)")
        XCTAssertEqual(refused["error"] as? String, "variable_in_use")
        XCTAssertEqual(refused["dependent_variable_ids"] as? [String], [derived])
        XCTAssertEqual(refused["dependent_feature_ids"] as? [String],
                       [feature.id.raw.uuidString])
        XCTAssertEqual(refused["dependent_sketch_dimension_ids"] as? [String], [dimensionID])
        let dependents = try XCTUnwrap(refused["dependents"] as? [String: Any])
        XCTAssertEqual(dependents["variable_ids"] as? [String], [derived])
        XCTAssertEqual(document.session.changeCount, changeCount)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoCount)

        let unusedID = try XCTUnwrap(try rows(document, "variables")
            .first { ($0["name"] as? String) == "unused" }?["id"] as? String)
        let removed = service.handle(action: "variable.delete",
                                     args: ["variable_id": unusedID])
        XCTAssertEqual(removed["ok"] as? Bool, true, "\(removed)")
        XCTAssertNil(try rows(document, "variables").first { ($0["name"] as? String) == "unused" })
        document.session.undo()
        XCTAssertNotNil(try rows(document, "variables").first { ($0["name"] as? String) == "unused" })
    }

    // MARK: - Invalid input is refused before commit and preserves redo

    func testInvalidNamesFunctionsReferencesAndCyclesPreserveDocumentAndRedo() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        let service = CADParameterService(document: document)
        let a = try createVariable(service, name: "a", expression: "1")
        _ = try createVariable(service, name: "b", expression: "a + 1")

        // Undo an unrelated variable so a and b still form the prospective
        // cycle under test, while every refusal must preserve a redo entry.
        _ = try createVariable(service, name: "redoSentinel", expression: "0")
        document.session.undo()
        XCTAssertEqual(try rows(document, "variables").count, 2)
        XCTAssertTrue(document.session.undoStack.canRedo)
        let changeCount = document.session.changeCount
        let undoCount = document.session.undoStack.undoCommands.count

        let refusals: [([String: Any], String)] = [
            (["name": "A", "expression": "3"], "duplicate_name"),
            (["name": "2bad", "expression": "3"], "invalid_name"),
            (["name": "bad name", "expression": "3"], "invalid_name"),
            (["name": "__x", "expression": "3"], "invalid_name"),
            (["name": "fn", "expression": "nope(2)"], "unknown_function"),
            (["name": "missing", "expression": "absent + 1"], "unresolved_reference"),
            (["name": "selfref", "expression": "selfref + 1"], "cyclic_reference"),
            (["variable_id": a, "expression": "a + 1"], "cyclic_reference"),
            (["variable_id": a, "expression": "b + 1"], "cyclic_reference"),
            (["variable_id": a, "expression": "1 / 0"], "divided_by_zero"),
            (["variable_id": a, "expression": "2", "expected_expression": "99"],
             "expression_mismatch"),
        ]
        for (args, code) in refusals {
            let action = args["variable_id"] == nil ? "variable.create" : "variable.update"
            let reply = service.handle(action: action, args: args)
            XCTAssertEqual(reply["ok"] as? Bool, false, "\(args) -> \(reply)")
            XCTAssertEqual(reply["error"] as? String, code, "\(args) -> \(reply)")
            XCTAssertEqual(document.session.changeCount, changeCount, "\(args)")
            XCTAssertEqual(document.session.undoStack.undoCommands.count, undoCount, "\(args)")
            XCTAssertTrue(document.session.undoStack.canRedo, "\(args)")
            XCTAssertEqual(try variableRow(document, a)["expression"] as? String, "1")
        }
        document.session.redo()
        XCTAssertEqual(try rows(document, "variables").count, 3)
    }

    // MARK: - Feature expression refusals and unit truthfulness

    func testFeatureExpressionRefusesUnsupportedParametersWithoutMutation() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        let feature = try makeBox(document)
        let service = CADParameterService(document: document)
        _ = try createVariable(service, name: "x", expression: "10")

        let changeCount = document.session.changeCount
        let symmetric = service.handle(action: "feature.setExpression", args: [
            "feature_id": feature.id.raw.uuidString,
            "parameter": "symmetric", "expression": "x",
        ])
        XCTAssertEqual(symmetric["error"] as? String, "unsupported_parameter", "\(symmetric)")
        let unknown = service.handle(action: "feature.setExpression", args: [
            "feature_id": feature.id.raw.uuidString,
            "parameter": "bogus", "expression": "x",
        ])
        XCTAssertEqual(unknown["error"] as? String, "unknown_parameter", "\(unknown)")
        let unresolved = service.handle(action: "feature.setExpression", args: [
            "feature_id": feature.id.raw.uuidString,
            "parameter": "distance", "expression": "missing + 1",
        ])
        XCTAssertEqual(unresolved["error"] as? String, "unresolved_reference", "\(unresolved)")
        let unknownFunction = service.handle(action: "feature.setExpression", args: [
            "feature_id": feature.id.raw.uuidString,
            "parameter": "distance", "expression": "nope(2)",
        ])
        XCTAssertEqual(unknownFunction["error"] as? String, "unknown_function",
                       "\(unknownFunction)")
        let badExpected = service.handle(action: "feature.setExpression", args: [
            "feature_id": feature.id.raw.uuidString,
            "parameter": "distance", "expression": "x", "expected_expression": "other",
        ])
        XCTAssertEqual(badExpected["error"] as? String, "expression_mismatch", "\(badExpected)")
        let badValue = service.handle(action: "feature.setExpression", args: [
            "feature_id": feature.id.raw.uuidString,
            "parameter": "distance", "expression": "0",
        ])
        XCTAssertEqual(badValue["error"] as? String, "invalid_parameter_value", "\(badValue)")
        XCTAssertEqual(document.session.changeCount, changeCount)
        XCTAssertTrue(try parameterRow(document, feature: feature.id, "distance")["formula"]
                      is NSNull)
    }

    func testPublicDegreesBindToRadianRotationWithExplicitConversion() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        let feature = try makeMeshRotation(document, degrees: 10)
        let service = CADParameterService(document: document)
        let angle = try createVariable(service, name: "ang", expression: "30")

        _ = setExpression(service, feature: feature, parameter: "angle",
                          expression: "ang", expected: "")
        var parameter = try parameterRow(document, feature: feature, "angle")
        XCTAssertEqual(parameter["unit"] as? String, "deg")
        XCTAssertEqual(parameter["value"] as? Double ?? -1, 30, accuracy: 1e-10)
        XCTAssertEqual(parameter["stored_unit"] as? String, "rad")
        XCTAssertEqual(parameter["stored_value"] as? Double ?? -1, .pi / 6, accuracy: 1e-12)
        XCTAssertEqual(parameter["formula"] as? String, "radians(ang)")
        XCTAssertEqual(parameter["source_expression"] as? String, "ang")
        XCTAssertEqual(parameter["source_expression_unit"] as? String, "deg")
        XCTAssertEqual(parameter["public_expression"] as? String, "ang")
        XCTAssertEqual(parameter["public_expression_unit"] as? String, "deg")
        XCTAssertEqual(parameter["public_expression_derived"] as? Bool, false)
        XCTAssertEqual(parameter["set_expression_unit"] as? String, "deg")
        XCTAssertEqual(parameter["variable_references"] as? [String], ["ang"])
        guard case let .rotateFace(_, stored, _) = try XCTUnwrap(
            document.session.document.features.node(feature)).kind else {
            return XCTFail("Expected the rotation feature")
        }
        XCTAssertEqual(stored.value, .pi / 6, accuracy: 1e-12)
        let before = try body(document).render.localAABB

        let update = service.handle(action: "variable.update", args: [
            "variable_id": angle, "expression": "45",
        ])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        parameter = try parameterRow(document, feature: feature, "angle")
        XCTAssertEqual(parameter["value"] as? Double ?? -1, 45, accuracy: 1e-10)
        XCTAssertEqual(parameter["stored_value"] as? Double ?? -1, .pi / 4, accuracy: 1e-12)
        guard case let .rotateFace(_, changed, _) = try XCTUnwrap(
            document.session.document.features.node(feature)).kind else {
            return XCTFail("Expected the rotation feature")
        }
        // A stored degree value would be ~45 rad here; the persisted unit is
        // radians and the conversion happened exactly once.
        XCTAssertEqual(changed.value, .pi / 4, accuracy: 1e-12)
        XCTAssertEqual(changed.formula, "radians(ang)")
        let after = try body(document).render.localAABB
        XCTAssertGreaterThan(simd_length(after.max - before.max), 0.01)

        document.session.undo()
        XCTAssertEqual(try parameterRow(document, feature: feature, "angle")["value"]
                       as? Double ?? -1, 30, accuracy: 1e-10)
        XCTAssertEqual(try variableRow(document, angle)["expression"] as? String, "30")
        document.session.redo()
        XCTAssertEqual(try parameterRow(document, feature: feature, "angle")["value"]
                       as? Double ?? -1, 45, accuracy: 1e-10)
    }

    // A legacy stored formula may START with `radians(` and end with `)` yet
    // wrap the WHOLE expression in radians only at the outside
    // (`radians(a) + sin(b)`). The adapter must not strip it to `a) + sin(b`;
    // it exposes the exact radian source and a clearly-derived degree
    // equivalent, and the expected_expression fence keeps matching the exact
    // stored text.
    func testLegacyArbitraryRadianFormulaIsNotRelabeledAsDegrees() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        let feature = try makeMeshRotation(document, degrees: 10)
        let service = CADParameterService(document: document)
        _ = try createVariable(service, name: "a", expression: "0.5")
        _ = try createVariable(service, name: "b", expression: "0.25")

        guard let node = document.session.document.features.node(feature),
              case let .rotateFace(face, _, axis) = node.kind else {
            return XCTFail("Expected the rotation feature")
        }
        let legacy = "radians(a) + sin(b)"
        let radians = 0.5 + Foundation.sin(0.25)
        document.session.editFeature(
            feature,
            to: .rotateFace(face: face, angle: Expr(value: radians, formula: legacy),
                            axis: axis))
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "\(document.session.lastEvalErrors)")

        let row = try parameterRow(document, feature: feature, "angle")
        XCTAssertEqual(row["formula"] as? String, legacy,
                       "the exact stored radian source must be preserved")
        XCTAssertEqual(row["formula_unit"] as? String, "rad")
        XCTAssertTrue(row["source_expression"] is NSNull,
                      "an arbitrary radian formula is not a degree source")
        XCTAssertEqual(row["public_expression"] as? String,
                       "(\(legacy)) * 180 / pi()")
        XCTAssertEqual(row["public_expression_unit"] as? String, "deg")
        XCTAssertEqual(row["public_expression_derived"] as? Bool, true)

        // A prefix/suffix truncation would claim the current formula is
        // `radians(a)` and either wrongly accept or wrongly import geometry.
        let truncated = service.handle(action: "feature.setExpression", args: [
            "feature_id": feature.raw.uuidString, "parameter": "angle",
            "expression": "a", "expected_expression": "radians(a)",
        ])
        XCTAssertEqual(truncated["error"] as? String, "expression_mismatch", "\(truncated)")
        XCTAssertEqual(try parameterRow(document, feature: feature, "angle")["formula"]
                       as? String, legacy)

        let rebound = service.handle(action: "feature.setExpression", args: [
            "feature_id": feature.raw.uuidString, "parameter": "angle",
            "expression": "a", "expected_expression": legacy,
        ])
        XCTAssertEqual(rebound["ok"] as? Bool, true, "\(rebound)")
        let reboundRow = try parameterRow(document, feature: feature, "angle")
        XCTAssertEqual(reboundRow["formula"] as? String, "radians(a)")
        XCTAssertEqual(reboundRow["source_expression"] as? String, "a")
        XCTAssertEqual(reboundRow["public_expression"] as? String, "a")
        XCTAssertEqual(reboundRow["public_expression_derived"] as? Bool, false)

        document.session.undo()
        let restored = try parameterRow(document, feature: feature, "angle")
        XCTAssertEqual(restored["formula"] as? String, legacy)
        XCTAssertEqual(restored["stored_value"] as? Double ?? -1, radians, accuracy: 1e-12)
    }

    // MARK: - Multi-owner fan-out: one undo for every sketch and the solid

    func testVariableChangeRebuildsEverySketchAndFeatureInOneUndo() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        let firstSketch = try addRectangleSketch(document)
        try run(document, "feature.extrude", [
            "sketchID": firstSketch, "seedPoint": [5, 5], "distance": 10,
        ])
        let feature = try XCTUnwrap(document.session.document.features.nodes.last)
        let secondSketch = try addRectangleSketch(document, y: 30)

        let service = CADParameterService(document: document)
        let size = try createVariable(service, name: "size", expression: "40")
        _ = setExpression(service, feature: feature.id, parameter: "distance",
                          expression: "size / 4")

        var dimensions: [String: String] = [:]  // sketch id -> dimension id
        for sketchID in [firstSketch, secondSketch] {
            let reply = service.handle(action: "setSketchDimension", args: [
                "sketch_id": sketchID, "kind": "width",
                "entity_id": try rectEntityID(document, sketchID), "value": 40,
            ])
            XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
            let dimensionID = try XCTUnwrap(
                (reply["dimension"] as? [String: Any])?["id"] as? String)
            try attachFormula(document, sketchID: sketchID,
                              dimensionID: dimensionID, formula: "size")
            dimensions[sketchID] = dimensionID
        }
        XCTAssertEqual(try volume(document), 8_000, accuracy: 0.1)

        let update = service.handle(action: "variable.update", args: [
            "variable_id": size, "expression": "60",
        ])
        XCTAssertEqual(update["ok"] as? Bool, true, "\(update)")
        XCTAssertEqual(try volume(document), 18_000, accuracy: 0.1,
                       "60 wide × 20 deep × 15 tall")
        for (sketchID, dimensionID) in dimensions {
            XCTAssertEqual(try dimensionValue(document, sketchID: sketchID,
                                             dimensionID: dimensionID),
                           60, accuracy: 1e-6, "sketch \(sketchID)")
        }

        // ONE undo restores the variable, BOTH sketches and the extruded body.
        document.session.undo()
        XCTAssertEqual(try volume(document), 8_000, accuracy: 0.1)
        XCTAssertEqual(try variableRow(document, size)["value"] as? Double, 40)
        for (sketchID, dimensionID) in dimensions {
            XCTAssertEqual(try dimensionValue(document, sketchID: sketchID,
                                             dimensionID: dimensionID),
                           40, accuracy: 1e-6, "sketch \(sketchID)")
        }
        document.session.redo()
        XCTAssertEqual(try volume(document), 18_000, accuracy: 0.1)
        for (sketchID, dimensionID) in dimensions {
            XCTAssertEqual(try dimensionValue(document, sketchID: sketchID,
                                             dimensionID: dimensionID),
                           60, accuracy: 1e-6, "sketch \(sketchID)")
        }

        // The final formula source is persisted with the resolved geometry.
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        openDocuments.append(reopened)
        XCTAssertEqual(try volume(reopened), 18_000, accuracy: 0.1)
        for (sketchID, dimensionID) in dimensions {
            XCTAssertEqual(try dimensionValue(reopened, sketchID: sketchID,
                                             dimensionID: dimensionID),
                           60, accuracy: 1e-6)
        }
    }

    // MARK: - Query discovery is executable and unit-truthful

    func testQueryExposesIDsFormulasValuesUnitsAndDependencies() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        let feature = try makeBox(document)
        let service = CADParameterService(document: document)
        let width = try createVariable(service, name: "width", expression: "20")
        let height = try createVariable(service, name: "height", expression: "width + 5")
        _ = setExpression(service, feature: feature.id, parameter: "distance",
                          expression: "width + height")

        let rows = try rows(document, "variables")
        let widthRow = try XCTUnwrap(rows.first { ($0["id"] as? String) == width })
        XCTAssertEqual(widthRow["unit"] as? String, "unitless")
        XCTAssertEqual(widthRow["editable"] as? Bool, true)
        XCTAssertEqual(widthRow["formula"] as? String, "20")
        let referenced = try XCTUnwrap(widthRow["referenced_by"] as? [String: Any])
        XCTAssertEqual(referenced["variable_ids"] as? [String], [height])
        let referencedFeatures = referenced["feature_parameters"] as? [[String: Any]] ?? []
        XCTAssertEqual(referencedFeatures.first?["feature_id"] as? String,
                       feature.id.raw.uuidString)
        let heightRow = try variableRow(document, height)
        let depends = try XCTUnwrap(heightRow["depends_on"] as? [[String: Any]])
        XCTAssertEqual(depends.compactMap { $0["id"] as? String }, [width])

        let featureQuery = try featureRow(document, feature.id)
        XCTAssertTrue((featureQuery["actions"] as? [String] ?? [])
            .contains("feature.setExpression"))
        let expressionParameters = try XCTUnwrap(
            featureQuery["expression_parameters"] as? [[String: Any]])
        let distance = try XCTUnwrap(expressionParameters.first {
            ($0["name"] as? String) == "distance"
        })
        XCTAssertEqual(distance["unit"] as? String, "mm")
        XCTAssertEqual(distance["formula"] as? String, "width + height")
        XCTAssertEqual(distance["action"] as? String, "feature.setExpression")
        XCTAssertEqual(featureQuery["variable_references"] as? [String],
                       ["height", "width"])

        // The list action advertises the same executable vocabulary.
        let list = service.handle(action: "list", args: [:])
        XCTAssertEqual(list["ok"] as? Bool, true)
        XCTAssertTrue((list["actions"] as? [String] ?? []).contains("variable.create"))
        XCTAssertTrue((list["actions"] as? [String] ?? []).contains("feature.setExpression"))
        let variableActions = try XCTUnwrap(list["variable_actions"] as? [String: Any])
        XCTAssertNotNil(variableActions["variable.update"])
        let expressionUpdate = try XCTUnwrap(list["expression_update"] as? [String: Any])
        XCTAssertEqual(expressionUpdate["action"] as? String, "feature.setExpression")
    }

    // MARK: - Coordinated USDZ caller adaptation

    func testUSDZExportSurfacesItsRealDiagnosticNotGenericUnavailable() async throws {
        try XCTSkipIf(!USDZExporter.isSupported,
                      "ModelIO reports no USDZ writer on this platform")
        let document = try await makeDocument()
        defer { document.close() }
        switch document.nativeExportData(format: "usdz", pageID: nil) {
        case .failure(let error):
            XCTAssertEqual(error.code, "emptyModel", error.message)
            XCTAssertNotEqual(error.code, "usdz_unavailable")
            XCTAssertTrue(error.message.contains("emptyModel"), error.message)
        case .success:
            XCTFail("An empty document must not produce a USDZ body")
        }
    }
}

import Foundation
import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration
@testable import FloeCanvasFlow

/// Pure evaluation semantics: lexical variable resolution with
/// same-name/different-type shadowing, unary predicates, JSON wildcard
/// projection, non-finite rejection and the tagged-number Codable round
/// trip used by node parameters.
final class FlowEvaluationTests: XCTestCase {

    private func frame(
        owner: UUID? = nil,
        declarations: [FlowVariable] = [],
        values: [String: FlowValue]
    ) -> FlowVariableFrame {
        FlowVariableFrame(ownerNodeID: owner, declarations: declarations, values: values)
    }

    // MARK: Shadowing

    func testInnerShadowWithDifferentTypeWins() throws {
        let outerDecl = FlowVariable(name: "x", dataType: .string, ownerNodeID: UUID())
        let innerDecl = FlowVariable(name: "x", dataType: .number, ownerNodeID: UUID())
        let frames = [
            frame(declarations: [outerDecl], values: ["x": .string("outer")]),
            frame(declarations: [innerDecl], values: ["x": .number(42)]),
        ]
        let value = try FlowEvaluation.resolve(
            .variable(name: "x"),
            variables: frames,
            nodeOutputs: [:],
            graphVariables: [])
        XCTAssertEqual(value, .number(42))
    }

    func testOuterValueUsedWhenInnerFrameDoesNotBind() throws {
        let outerDecl = FlowVariable(name: "x", dataType: .string, ownerNodeID: UUID())
        let innerDecl = FlowVariable(name: "y", dataType: .number, ownerNodeID: UUID())
        let frames = [
            frame(declarations: [outerDecl], values: ["x": .string("outer")]),
            frame(declarations: [innerDecl], values: ["y": .number(1)]),
        ]
        let value = try FlowEvaluation.resolve(
            .variable(name: "x"),
            variables: frames,
            nodeOutputs: [:],
            graphVariables: [])
        XCTAssertEqual(value, .string("outer"))
    }

    func testTypeMismatchAgainstLexicalDeclarationThrows() {
        // Inner frame binds x but only an OUTER declaration of x exists
        // with a different type: the lexical chain governs, not a global
        // first-name match.
        let outerDecl = FlowVariable(name: "x", dataType: .string, ownerNodeID: UUID())
        let frames = [
            frame(declarations: [outerDecl], values: ["x": .string("typed")]),
            frame(values: ["x": .number(5)]),
        ]
        XCTAssertThrowsError(try FlowEvaluation.resolve(
            .variable(name: "x"),
            variables: frames,
            nodeOutputs: [:],
            graphVariables: [])) { error in
            guard case FlowVariableError.typeMismatch = error else {
                XCTFail("expected typeMismatch, got \(error)")
                return
            }
        }
    }

    func testJSONDeclarationAcceptsAnyValue() throws {
        let decl = FlowVariable(name: "blob", dataType: .json, ownerNodeID: UUID())
        let frames = [frame(declarations: [decl], values: ["blob": .number(3)])]
        let value = try FlowEvaluation.resolve(
            .variable(name: "blob"),
            variables: frames,
            nodeOutputs: [:],
            graphVariables: [])
        XCTAssertEqual(value, .number(3))
    }

    // MARK: Iteration isolation (subgraph instances / loop iterations)

    func testSiblingFramesDoNotPolluteEachOther() throws {
        let decl = FlowVariable(name: "item", dataType: .json, ownerNodeID: UUID())
        let instanceA = frame(owner: UUID(), declarations: [decl], values: ["item": .string("A")])
        let instanceB = frame(owner: UUID(), declarations: [decl], values: ["item": .string("B")])
        let a = try FlowEvaluation.resolve(
            .variable(name: "item"), variables: [instanceA],
            nodeOutputs: [:], graphVariables: [])
        let b = try FlowEvaluation.resolve(
            .variable(name: "item"), variables: [instanceB],
            nodeOutputs: [:], graphVariables: [])
        XCTAssertEqual(a, .string("A"))
        XCTAssertEqual(b, .string("B"))
    }

    // MARK: isEmpty is unary

    func testIsEmptyDoesNotResolveRightHandSide() throws {
        let predicate = FlowPredicate.comparison(
            .isEmpty,
            lhs: .literal(.string("")),
            rhs: .variable(name: "missing.operand")) // must NOT be resolved
        let result = try FlowEvaluation.evaluate(
            predicate, variables: [], nodeOutputs: [:], graphVariables: [])
        XCTAssertTrue(result)
    }

    func testIsEmptyOnNonEmptyStringIsFalse() throws {
        let predicate = FlowPredicate.comparison(
            .isEmpty,
            lhs: .literal(.string("data")),
            rhs: .literal(.json(.null)))
        XCTAssertFalse(try FlowEvaluation.evaluate(
            predicate, variables: [], nodeOutputs: [:], graphVariables: []))
    }

    // MARK: Projection

    func testProjectConvertsJSONPayload() {
        let projected = FlowEvaluation.project(.json(.string("hello")), to: .string)
        XCTAssertEqual(projected, .string("hello"))
    }

    func testProjectLeavesConcreteValuesUnchanged() {
        XCTAssertEqual(FlowEvaluation.project(.number(4), to: .string), .number(4))
        XCTAssertEqual(FlowEvaluation.project(.json(.null), to: .number), .json(.null))
    }

    // MARK: Non-finite rejection

    func testNonFiniteNumberLiteralIsRejected() {
        XCTAssertThrowsError(try FlowLiterals.value(.number("1e400"), as: .number)) { error in
            guard case FlowLiteralError.typeMismatch = error else {
                XCTFail("expected typeMismatch, got \(error)")
                return
            }
        }
    }

    func testFiniteNumberLiteralConverts() throws {
        let value = try FlowLiterals.value(.number("9007199254740993"), as: .number)
        guard case .number(let number) = value else {
            XCTFail("expected number")
            return
        }
        XCTAssertEqual(number, 9007199254740993, accuracy: 1)
    }

    // MARK: Tagged-number Codable round trip (predicate parameters)

    struct PredicateHolder: Codable, Equatable {
        var predicate: FlowPredicate
    }

    func testPredicateRoundTripsThroughTaggedJSONValue() throws {
        let predicate = FlowPredicate.comparison(
            .greaterThan,
            lhs: .variable(name: "carry.value"),
            rhs: .literal(.number(5)))
        let json = try FlowLiterals.encodeToJSON(predicate)
        // Simulate the native save/reopen: JSONValue Codable uses tagged
        // numbers, so a plain Codable round trip must not lose the value.
        let data = try JSONEncoder().encode(json)
        let reopened = try JSONDecoder().decode(JSONValue.self, from: data)
        let decoded = try FlowLiterals.decodeFromJSON(reopened, as: FlowPredicate.self)
        XCTAssertEqual(decoded, predicate)
    }

    func testNumberLiteralSurvivesTaggedRoundTripExactly() throws {
        let json = JSONValue.object(["n": .number("9007199254740993")])
        let data = try JSONEncoder().encode(json)
        let reopened = try JSONDecoder().decode(JSONValue.self, from: data)
        let holder = try FlowLiterals.decodeFromJSON(reopened, as: NumberHolder.self)
        XCTAssertEqual(holder.n, 9007199254740993, accuracy: 1)
        // Literal spelling is preserved in the JSONValue layer.
        XCTAssertEqual(reopened["n"]?.numberLiteral, "9007199254740993")
    }

    struct NumberHolder: Codable {
        var n: Double
    }

    func testNonFiniteTagIsRejectedOnDecode() throws {
        let json = JSONValue.object(["n": .number("1e400")])
        let data = try JSONEncoder().encode(json)
        let reopened = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertThrowsError(try FlowLiterals.decodeFromJSON(reopened, as: NumberHolder.self))
    }

    // MARK: Comparators

    func testNumericComparators() throws {
        func check(_ comparator: FlowPredicate.Comparator, _ expected: Bool) throws {
            let predicate = FlowPredicate.comparison(
                comparator, lhs: .literal(.number(2)), rhs: .literal(.number(3)))
            XCTAssertEqual(try FlowEvaluation.evaluate(
                predicate, variables: [], nodeOutputs: [:], graphVariables: []), expected)
        }
        try check(.lessThan, true)
        try check(.lessThanOrEqual, true)
        try check(.greaterThan, false)
        try check(.greaterThanOrEqual, false)
        try check(.equal, false)
        try check(.notEqual, true)
    }

    func testContainsAndRegex() throws {
        let contains = FlowPredicate.comparison(
            .contains, lhs: .literal(.string("hello world")),
            rhs: .literal(.string("world")))
        XCTAssertTrue(try FlowEvaluation.evaluate(
            contains, variables: [], nodeOutputs: [:], graphVariables: []))
        let matches = FlowPredicate.comparison(
            .matchesRegex, lhs: .literal(.string("flow-123")),
            rhs: .literal(.string("^flow-[0-9]+$")))
        XCTAssertTrue(try FlowEvaluation.evaluate(
            matches, variables: [], nodeOutputs: [:], graphVariables: []))
    }
}

// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeEngineeringCore

/// Load-independent singularity detection, cancellation, conflicting boundary
/// conditions and resource budgets — including the hinge-mechanism and
/// arbitrary-point-support counterexamples.
final class SingularityAndControlTests: XCTestCase {

    func testMissingBoundaryConditionsFail() {
        // No displacement BCs at all: rigid body modes must be reported even
        // though the load is a perfectly ordinary point force.
        let mesh = EngineeringExamples.twoTetBipyramid()
        let study = EngineeringStudy(
            id: "no-bc", name: "Missing BC",
            meshNodes: mesh.nodes, meshElements: mesh.elements,
            material: MaterialLibrary.structuralSteelA36,
            structural: EngineeringStudy.StructuralConfig(
                concentratedLoads: [ConcentratedLoad(node: 3, components: Vector3(0, 0, -100))]))
        XCTAssertThrowsError(try study.structuralRequest().solve()) { error in
            guard case EngineeringError.singular = error else {
                return XCTFail("expected singular, got \(error)")
            }
        }
    }

    func testZeroLoadWithIncompleteSupportFails() {
        // Arbitrary-point support: a single fully-fixed node still leaves five
        // rigid modes free. With ZERO applied load the old "residual is zero"
        // shortcut would have succeeded vacuously; the LDL^T certification must
        // reject it anyway.
        let mesh = EngineeringExamples.twoTetBipyramid()
        let study = EngineeringStudy(
            id: "point-support", name: "Single-point support, no load",
            meshNodes: mesh.nodes, meshElements: mesh.elements,
            material: MaterialLibrary.structuralSteelA36,
            structural: EngineeringStudy.StructuralConfig(
                displacementBCs: [DisplacementBC(node: 0, constrained: [true, true, true],
                                                 prescribedMM: [0, 0, 0])]))
        XCTAssertThrowsError(try study.structuralRequest().solve()) { error in
            guard case EngineeringError.singular = error else {
                return XCTFail("expected singular, got \(error)")
            }
        }
    }

    func testHingeMechanismFails() {
        // Two tets sharing only EDGE (0,1) — no common face. Fixing the free
        // nodes of tet A leaves tet B free to rotate about the shared edge: a
        // hinge mechanism (not a rigid mode), which a masked-basis scan misses
        // and the pivot test must catch.
        let nodes = [
            MeshNode(Vector3(0, 0, 0)),
            MeshNode(Vector3(1, 0, 0)),
            MeshNode(Vector3(0, 1, 0)),
            MeshNode(Vector3(0, 0, 1)),   // tet A apex above the shared edge
            MeshNode(Vector3(0, -1, 0)),  // valid positive-volume tet B sharing only edge 0-1
            MeshNode(Vector3(0, 0, -1)),
        ]
        let elements = [Tetrahedron(0, 1, 2, 3), Tetrahedron(0, 1, 4, 5)]
        let study = EngineeringStudy(
            id: "hinge", name: "Edge-hinged tets",
            meshNodes: nodes, meshElements: elements,
            material: MaterialLibrary.structuralSteelA36,
            structural: EngineeringStudy.StructuralConfig(
                concentratedLoads: [ConcentratedLoad(node: 4, components: Vector3(10, 0, 0))],
                displacementBCs: [
                    DisplacementBC(node: 0, constrained: [true, true, true], prescribedMM: [0, 0, 0]),
                    DisplacementBC(node: 2, constrained: [true, true, true], prescribedMM: [0, 0, 0]),
                    DisplacementBC(node: 3, constrained: [true, true, true], prescribedMM: [0, 0, 0]),
                ]))
        XCTAssertThrowsError(try study.structuralRequest().solve()) { error in
            guard case EngineeringError.singular = error else {
                return XCTFail("expected singular, got \(error)")
            }
        }
    }

    func testFloatingComponentWithoutSupportFails() {
        // Two disjoint tets: one supported and loaded, one floating completely
        // free — even though the loaded part is perfectly well posed.
        let a = [
            MeshNode(Vector3(0, 0, 0)), MeshNode(Vector3(1, 0, 0)),
            MeshNode(Vector3(0, 1, 0)), MeshNode(Vector3(0, 0, 1)),
        ]
        let offset = Vector3(100, 0, 0)
        let b = a.map { MeshNode($0.position + offset) }
        let nodes = a + b
        let elements = [Tetrahedron(0, 1, 2, 3), Tetrahedron(4, 5, 6, 7)]
        let study = EngineeringStudy(
            id: "float", name: "Floating component",
            meshNodes: nodes, meshElements: elements,
            material: MaterialLibrary.structuralSteelA36,
            structural: EngineeringStudy.StructuralConfig(
                concentratedLoads: [ConcentratedLoad(node: 3, components: Vector3(0, 0, -5))],
                displacementBCs: [
                    DisplacementBC(node: 0, constrained: [true, true, true], prescribedMM: [0, 0, 0]),
                    DisplacementBC(node: 1, constrained: [true, true, true], prescribedMM: [0, 0, 0]),
                    DisplacementBC(node: 2, constrained: [true, true, true], prescribedMM: [0, 0, 0]),
                ]))
        XCTAssertThrowsError(try study.structuralRequest().solve()) { error in
            guard case EngineeringError.singular = error else {
                return XCTFail("expected singular, got \(error)")
            }
        }
    }

    func testConflictingDisplacementBCRejected() {
        let mesh = EngineeringExamples.twoTetBipyramid()
        let study = EngineeringStudy(
            id: "conflict", name: "Conflicting BCs",
            meshNodes: mesh.nodes, meshElements: mesh.elements,
            material: MaterialLibrary.structuralSteelA36,
            structural: EngineeringStudy.StructuralConfig(
                displacementBCs: [
                    DisplacementBC(node: 0, constrained: [true, false, false], prescribedMM: [0, 0, 0]),
                    DisplacementBC(node: 0, constrained: [true, false, false], prescribedMM: [0.1, 0, 0]),
                ]))
        XCTAssertThrowsError(try study.structuralRequest().solve()) { error in
            guard case EngineeringError.invalidInput(let msg) = error else {
                return XCTFail("expected invalidInput, got \(error)")
            }
            XCTAssertTrue(msg.contains("conflicting"), msg)
        }
    }

    func testDuplicateIdenticalDisplacementBCAccepted() {
        let mesh = EngineeringExamples.twoTetBipyramid()
        let bc = DisplacementBC(node: 0, constrained: [true, true, true], prescribedMM: [0, 0, 0])
        let more = [bc] + (1...2).map { DisplacementBC(node: $0, constrained: [true, true, true], prescribedMM: [0, 0, 0]) }
        let study = EngineeringStudy(
            id: "dup", name: "Duplicate identical BC",
            meshNodes: mesh.nodes, meshElements: mesh.elements,
            material: MaterialLibrary.structuralSteelA36,
            structural: EngineeringStudy.StructuralConfig(
                concentratedLoads: [ConcentratedLoad(node: 3, components: Vector3(0, 0, -1))],
                displacementBCs: more + [bc]))
        // Well-supported (three bottom nodes fixed) -> solves fine.
        let result = try? study.structuralRequest().solve()
        XCTAssertNotNil(result)
    }

    func testCancellationDuringSolve() {
        let mesh = EngineeringExamples.twoTetBipyramid()
        let bcs = (0...2).map { DisplacementBC(node: $0, constrained: [true, true, true], prescribedMM: [0, 0, 0]) }
        let request = StructuralRequest(
            meshNodes: mesh.nodes, meshElements: mesh.elements,
            material: MaterialLibrary.structuralSteelA36,
            concentratedLoads: [ConcentratedLoad(node: 4, components: Vector3(0, 0, -50))],
            displacementBCs: bcs)
        XCTAssertThrowsError(try request.solve(control: EngineeringSolveControl(isCancelled: { true }))) { error in
            guard case EngineeringError.cancelled = error else {
                return XCTFail("expected cancelled, got \(error)")
            }
        }
    }

    func testIterationBudgetProducesExplicitFailure() {
        // A tiny iteration budget must fail closed with illConditioned/budget,
        // never a wrong "success".
        let mesh = EngineeringExamples.twoTetBipyramid()
        let bcs = (0...2).map { DisplacementBC(node: $0, constrained: [true, true, true], prescribedMM: [0, 0, 0]) }
        var budget = EngineeringBudget()
        budget.maxIterations = 1
        let request = StructuralRequest(
            meshNodes: mesh.nodes, meshElements: mesh.elements,
            material: MaterialLibrary.structuralSteelA36,
            concentratedLoads: [ConcentratedLoad(node: 4, components: Vector3(0, 0, -50))],
            displacementBCs: bcs, budget: budget)
        XCTAssertThrowsError(try request.solve()) { error in
            switch error {
            case EngineeringError.illConditioned, EngineeringError.budgetExceeded:
                break
            default:
                XCTFail("expected illConditioned or budgetExceeded, got \(error)")
            }
        }
    }

    func testNonzeroBudgetEnforcedAtValidation() {
        var budget = EngineeringBudget()
        budget.maxIterations = 0
        XCTAssertThrowsError(try budget.validate()) { error in
            guard case EngineeringError.invalidInput = error else {
                return XCTFail("expected invalidInput, got \(error)")
            }
        }
    }

    func testMemoryBudgetOnCertificationProfile() {
        // The LDL^T profile for the 2-tet mesh is small; cap memory below it and
        // the solve must fail closed with budgetExceeded.
        let mesh = EngineeringExamples.twoTetBipyramid()
        let bcs = (0...2).map { DisplacementBC(node: $0, constrained: [true, true, true], prescribedMM: [0, 0, 0]) }
        var budget = EngineeringBudget()
        budget.maxEstimatedBytes = 64
        let request = StructuralRequest(
            meshNodes: mesh.nodes, meshElements: mesh.elements,
            material: MaterialLibrary.structuralSteelA36,
            displacementBCs: bcs, budget: budget)
        XCTAssertThrowsError(try request.solve()) { error in
            guard case EngineeringError.budgetExceeded(let msg) = error else {
                return XCTFail("expected budgetExceeded, got \(error)")
            }
            XCTAssertTrue(msg.contains("memory") || msg.contains("profile"), msg)
        }
    }

    func testUnsupportedAnalysisLedgerIsExplicit() {
        XCTAssertTrue(EngineeringUnsupported.ledger.contains(.plasticity))
        XCTAssertTrue(EngineeringUnsupported.ledger.contains(.meshFromSurface))
        XCTAssertEqual(EngineeringUnsupported.anisotropicMaterials.note.contains("never"), true)
    }
}

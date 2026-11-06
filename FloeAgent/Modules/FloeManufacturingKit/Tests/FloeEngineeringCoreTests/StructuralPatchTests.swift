// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeEngineeringCore

/// Structural analysis: two-tet patch test with nonzero Dirichlet data, exact
/// von Mises / factor-of-safety expectations, and force equilibrium under body +
/// pressure loads on a skewed mesh (guards the Jacobian path end to end).
final class StructuralPatchTests: XCTestCase {

    func testPatchFieldMatchesAffineSolution() throws {
        let study = try EngineeringExamples.patchFieldStudy(edgeMM: 10, lengthMM: 40,
                                                        alpha: 1e-3,
                                                        material: MaterialLibrary.structuralSteelA36)
        let result = try study.structuralRequest().solve()
        let expectation = try EngineeringExamples.patchFieldExpectation(
            edgeMM: 10, alpha: 1e-3, material: MaterialLibrary.structuralSteelA36)

        // Free-node displacements reproduce the affine field exactly.
        XCTAssertEqual(result.nodalDisplacementMM[3].x, expectation.expectedU3X, accuracy: 1e-12)
        XCTAssertEqual(result.nodalDisplacementMM[4].x, expectation.expectedU4X, accuracy: 1e-12)
        XCTAssertEqual(result.nodalDisplacementMM[3].y, 0, accuracy: 1e-12)
        XCTAssertEqual(result.nodalDisplacementMM[4].z, 0, accuracy: 1e-12)

        // Constant strain (alpha,0,0) -> von Mises 2G*alpha on both elements.
        XCTAssertEqual(result.elements.count, 2)
        for el in result.elements {
            XCTAssertEqual(el.strain[0], 1e-3, accuracy: 1e-12)
            XCTAssertEqual(el.strain[1], 0, accuracy: 1e-12)
            XCTAssertEqual(el.vonMisesMPa, expectation.expectedVonMisesMPa, accuracy: 1e-6)
            XCTAssertEqual(el.safetyFactorStatus, .computed)
            XCTAssertEqual(el.factorOfSafety ?? -1, expectation.expectedFactorOfSafety ?? -1, accuracy: 1e-6)
        }
        XCTAssertEqual(result.maxVonMisesMPa ?? -1, expectation.expectedVonMisesMPa, accuracy: 1e-6)
        XCTAssertEqual(result.minFactorOfSafety ?? -1, expectation.expectedFactorOfSafety ?? -1, accuracy: 1e-6)

        // Convergence is reported on the residual; reactions balance the
        // consistent exterior tractions with nonzero Dirichlet excitation.
        XCTAssertLessThan(result.relativeResidual, 1e-8)
        XCTAssertEqual(result.reactionSum.x + result.appliedLoadSum.x, 0, accuracy: 1e-6)
        XCTAssertEqual(result.reactionSum.y + result.appliedLoadSum.y, 0, accuracy: 1e-6)
        XCTAssertEqual(result.reactionSum.z + result.appliedLoadSum.z, 0, accuracy: 1e-6)
        XCTAssertFalse(result.reactions.isEmpty)
        // Reactions are nonzero: the prescribed strain is genuinely resisted.
        let maxReaction = result.reactions.map { abs($0.valueN) }.max() ?? 0
        XCTAssertGreaterThan(maxReaction, 1e-3)
        // External work equals stored strain energy for the exact solution.
        XCTAssertEqual(result.externalWork, result.strainEnergy, accuracy: 1e-6 * max(1, abs(result.strainEnergy)))
    }

    func testPatchFieldOnSkewedMesh() throws {
        // Same affine field on a sheared/rotated mesh: a transpose/cofactor bug in
        // the Jacobian would corrupt the gradients and fail these expectations.
        let material = MaterialLibrary.aluminum6061T6
        let base = EngineeringExamples.twoTetBipyramid(edgeMM: 10, lengthMM: 40)
        func skew(_ p: Vector3) -> Vector3 {
            // Shear in x by 0.3*y, rotate slightly about z, translate.
            Vector3(p.x + 0.3 * p.y + 50, p.y - 0.2 * p.x - 20, p.z + 11)
        }
        let nodes = base.nodes.map { MeshNode(skew($0.position)) }
        let alpha = 7e-4
        func field(_ node: Int) -> Double { alpha * nodes[node].position.x }
        let bcs = [
            DisplacementBC(node: 0, constrained: [true, true, true], prescribedMM: [field(0), 0, 0]),
            DisplacementBC(node: 1, constrained: [true, true, true], prescribedMM: [field(1), 0, 0]),
            DisplacementBC(node: 2, constrained: [true, true, true], prescribedMM: [field(2), 0, 0]),
        ]
        let study = EngineeringStudy(id: "skew-patch", name: "Skewed patch",
                                     meshNodes: nodes, meshElements: base.elements, material: material,
                                     structural: EngineeringStudy.StructuralConfig(
                                        concentratedLoads:try EngineeringExamples.patchFieldLoads(nodes:nodes,elements:base.elements,alpha:alpha,material:material),
                                        displacementBCs: bcs))
        let result = try study.structuralRequest().solve()
        XCTAssertEqual(result.nodalDisplacementMM[3].x, field(3), accuracy: 1e-10)
        XCTAssertEqual(result.nodalDisplacementMM[4].x, field(4), accuracy: 1e-10)
        let g = material.elasticModulusMPa / (2 * (1 + material.poissonRatio))
        XCTAssertEqual(result.elements[0].vonMisesMPa, 2 * g * alpha, accuracy: 1e-6)
        XCTAssertLessThan(result.relativeResidual, 1e-8)
    }

    func testLoadedForceEquilibrium() throws {
        // Bottom face fixed, gravity-like body load + outward pressure traction.
        // Global equilibrium: reactionSum + appliedLoadSum == 0 componentwise.
        let study = EngineeringExamples.loadedEquilibriumStudy()
        let result = try study.structuralRequest().solve()
        XCTAssertEqual(result.reactionSum.x + result.appliedLoadSum.x, 0, accuracy: 1e-6)
        XCTAssertEqual(result.reactionSum.y + result.appliedLoadSum.y, 0, accuracy: 1e-6)
        XCTAssertEqual(result.reactionSum.z + result.appliedLoadSum.z, 0, accuracy: 1e-6)
        // The applied load must actually be nonzero, otherwise the test is vacuous.
        XCTAssertGreaterThan(abs(result.appliedLoadSum.z), 1.0)
        // Displacements point downward on average (body load dominates by design).
        let meanZ = result.nodalDisplacementMM.reduce(0) { $0 + $1.z } / Double(result.nodalDisplacementMM.count)
        XCTAssertLessThan(meanZ, 0)
        XCTAssertLessThan(result.relativeResidual, 1e-8)
    }

    func testZeroStressYieldsUnboundedSafetyFactorStatusNotInfinity() throws {
        // Fully constrained with zero prescribed values and no loads: zero stress.
        // FoS must be an explicit status, never an infinity literal, so the result
        // stays JSON-encodable.
        let mesh = EngineeringExamples.twoTetBipyramid()
        let zero = [Double](repeating: 0, count: 3)
        let bcs = (0..<5).map { DisplacementBC(node: $0, constrained: [true, true, true], prescribedMM: zero) }
        let study = EngineeringStudy(id: "zero-stress", name: "Zero stress",
                                     meshNodes: mesh.nodes, meshElements: mesh.elements,
                                     material: MaterialLibrary.structuralSteelA36,
                                     structural: EngineeringStudy.StructuralConfig(displacementBCs: bcs))
        let result = try study.structuralRequest().solve()
        XCTAssertEqual(result.maxVonMisesMPa ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(result.minVonMisesMPa ?? -1, 0, accuracy: 1e-12)
        for el in result.elements {
            XCTAssertEqual(el.safetyFactorStatus, .unboundedZeroStress)
            XCTAssertNil(el.factorOfSafety)
        }
        XCTAssertNil(result.minFactorOfSafety)
        let record = try study.exportSession(structural: result)
        let data = try EngineeringExport.encode(record)
        XCTAssertFalse(data.isEmpty)
        let decoded = try EngineeringExport.decode(data)
        XCTAssertEqual(decoded.studySourceHash, record.studySourceHash)
    }

    func testNoYieldMaterialReportsNotRequested() throws {
        var material = MaterialLibrary.structuralSteelA36
        material.yieldStrengthMPa = nil
        let study = try EngineeringExamples.patchFieldStudy(material: material)
        let result = try study.structuralRequest().solve()
        for el in result.elements {
            XCTAssertEqual(el.safetyFactorStatus, .notRequested)
            XCTAssertNil(el.factorOfSafety)
        }
        XCTAssertNil(result.minFactorOfSafety)
    }

    func testNonIsotropicMaterialRejected() throws {
        var material = MaterialLibrary.structuralSteelA36
        material.symmetry = .orthotropic
        var study = try EngineeringExamples.patchFieldStudy()
        study.material = material
        XCTAssertThrowsError(try study.structuralRequest().solve()) { error in
            guard case EngineeringError.invalidMaterial(let msg) = error else {
                return XCTFail("expected invalidMaterial, got \(error)")
            }
            XCTAssertTrue(msg.contains("isotropic"), msg)
        }
    }
}

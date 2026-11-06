// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeEngineeringCore

/// Steady isotropic heat conduction: nonzero Dirichlet temperatures, sources,
/// energy balance, and load-independent singularity for unsupported components.
final class ThermalTests: XCTestCase {

    func testConductionWithSourceBalancesEnergy() throws {
        let study = EngineeringExamples.thermalStudy(material: MaterialLibrary.structuralSteelA36)
        let result = try study.thermalRequest().solve()

        // Nonzero Dirichlet data were used: the fixed nodes must hold exactly.
        XCTAssertEqual(result.nodalTemperatureCelsius[0], 20, accuracy: 1e-12)
        XCTAssertEqual(result.nodalTemperatureCelsius[1], 20, accuracy: 1e-12)
        XCTAssertEqual(result.nodalTemperatureCelsius[2], 20, accuracy: 1e-12)
        XCTAssertEqual(result.nodalTemperatureCelsius[4], 120, accuracy: 1e-12)

        // Energy balance: boundary supply + sources - outward applied flux = 0.
        let expectedSource = 1e-3 * (10 * 10 * 40 / 3)
        XCTAssertEqual(result.totalSourcePowerW, expectedSource, accuracy: 1e-9)
        XCTAssertEqual(result.totalAppliedFluxW, 0, accuracy: 1e-12)
        XCTAssertEqual(result.energyBalanceResidualW, 0, accuracy: 1e-6)
        XCTAssertEqual(result.totalBoundaryHeatFlowW, -expectedSource, accuracy: 1e-6)
        XCTAssertLessThan(result.relativeResidual, 1e-8)

        // All nodal temperatures finite; with a non-negative source the discrete
        // minimum principle keeps every node at or above the cold boundary.
        XCTAssertTrue(result.nodalTemperatureCelsius.allSatisfy { $0.isFinite })
        XCTAssertGreaterThanOrEqual(result.maxTemperatureCelsius, 120 - 1e-9)
        XCTAssertGreaterThanOrEqual(result.minTemperatureCelsius, 20 - 1e-9)
    }

    func testConductionWithoutSourceIsBoundedByDirichletData() throws {
        let mesh = EngineeringExamples.twoTetBipyramid()
        let study = EngineeringStudy(
            id: "cond", name: "Pure conduction",
            meshNodes: mesh.nodes, meshElements: mesh.elements,
            material: MaterialLibrary.aluminum6061T6,
            thermal: EngineeringStudy.ThermalConfig(
                fixedTemperatures: [
                    FixedTemperatureBC(node: 0, temperatureCelsius: 100),
                    FixedTemperatureBC(node: 1, temperatureCelsius: 100),
                    FixedTemperatureBC(node: 2, temperatureCelsius: 100),
                    FixedTemperatureBC(node: 4, temperatureCelsius: 200),
                ]))
        let result = try study.thermalRequest().solve()
        // Discrete maximum principle (up to solve tolerance): no interior node
        // escapes the prescribed range.
        XCTAssertGreaterThanOrEqual(result.minTemperatureCelsius, 100 - 1e-6)
        XCTAssertLessThanOrEqual(result.maxTemperatureCelsius, 200 + 1e-6)
        // Zero source and zero applied flux -> boundary heat flow sums to zero.
        XCTAssertEqual(result.totalSourcePowerW, 0, accuracy: 1e-12)
        XCTAssertEqual(result.totalAppliedFluxW, 0, accuracy: 1e-12)
        XCTAssertEqual(result.totalBoundaryHeatFlowW, 0, accuracy: 1e-6)
        XCTAssertEqual(result.energyBalanceResidualW, 0, accuracy: 1e-6)
    }

    func testPositiveOutwardFluxCoolsFreeNodesAndRequiresBoundarySupply() throws {
        let mesh = EngineeringExamples.twoTetBipyramid()
        let request = ThermalRequest(meshNodes:mesh.nodes,meshElements:mesh.elements,
            material:MaterialLibrary.aluminum6061T6,
            fixedTemperatures:[0,1,2,4].map { FixedTemperatureBC(node:$0,temperatureCelsius:20) },
            faceFluxes:[ThermalFlux(element:0,face:0,fluxWPerMM2:0.001)])
        let result = try request.solve()
        XCTAssertLessThan(result.nodalTemperatureCelsius[3],20)
        XCTAssertGreaterThan(result.totalAppliedFluxW,0)
        XCTAssertEqual(result.totalBoundaryHeatFlowW,result.totalAppliedFluxW,accuracy:1e-8)
        XCTAssertEqual(result.energyBalanceResidualW,0,accuracy:1e-8)
    }

    func testFixedTemperatureConflictsRejected() {
        let mesh = EngineeringExamples.twoTetBipyramid()
        let study = EngineeringStudy(
            id: "tconflict", name: "Conflicting temperatures",
            meshNodes: mesh.nodes, meshElements: mesh.elements,
            material: MaterialLibrary.structuralSteelA36,
            thermal: EngineeringStudy.ThermalConfig(
                fixedTemperatures: [
                    FixedTemperatureBC(node: 0, temperatureCelsius: 20),
                    FixedTemperatureBC(node: 1, temperatureCelsius: 20),
                    FixedTemperatureBC(node: 2, temperatureCelsius: 20),
                    FixedTemperatureBC(node: 4, temperatureCelsius: 120),
                    FixedTemperatureBC(node: 4, temperatureCelsius: 121),
                ]))
        XCTAssertThrowsError(try study.thermalRequest().solve()) { error in
            guard case EngineeringError.invalidInput(let msg) = error else {
                return XCTFail("expected invalidInput, got \(error)")
            }
            XCTAssertTrue(msg.contains("conflicting"), msg)
        }
    }

    func testMissingFixedTemperaturesFail() {
        let mesh = EngineeringExamples.twoTetBipyramid()
        let study = EngineeringStudy(
            id: "tbc", name: "No thermal BCs",
            meshNodes: mesh.nodes, meshElements: mesh.elements,
            material: MaterialLibrary.structuralSteelA36,
            thermal: EngineeringStudy.ThermalConfig(
                sources: [ThermalSource(element: 0, powerPerVolume: 1e-3)]))
        XCTAssertThrowsError(try study.thermalRequest().solve()) { error in
            guard case EngineeringError.singular = error else {
                return XCTFail("expected singular, got \(error)")
            }
        }
    }

    func testFloatingThermalComponentFails() {
        // Two disjoint tets, only one with a fixed temperature: the constant
        // null space on the free component makes the system singular regardless
        // of sources.
        let a = [
            MeshNode(Vector3(0, 0, 0)), MeshNode(Vector3(1, 0, 0)),
            MeshNode(Vector3(0, 1, 0)), MeshNode(Vector3(0, 0, 1)),
        ]
        let b = a.map { MeshNode($0.position + Vector3(100, 0, 0)) }
        let study = EngineeringStudy(
            id: "tfloat", name: "Floating thermal component",
            meshNodes: a + b, meshElements: [Tetrahedron(0, 1, 2, 3), Tetrahedron(4, 5, 6, 7)],
            material: MaterialLibrary.structuralSteelA36,
            thermal: EngineeringStudy.ThermalConfig(
                fixedTemperatures: [FixedTemperatureBC(node: 0, temperatureCelsius: 50)],
                sources: [ThermalSource(element: 1, powerPerVolume: 1e-3)]))
        XCTAssertThrowsError(try study.thermalRequest().solve()) { error in
            guard case EngineeringError.singular = error else {
                return XCTFail("expected singular, got \(error)")
            }
        }
    }

    func testMissingConductivityFails() {
        var material = MaterialLibrary.structuralSteelA36
        material.thermalConductivityWPerMMK = nil
        let mesh = EngineeringExamples.twoTetBipyramid()
        let study = EngineeringStudy(
            id: "tcond", name: "No conductivity",
            meshNodes: mesh.nodes, meshElements: mesh.elements, material: material,
            thermal: EngineeringStudy.ThermalConfig(
                fixedTemperatures: [FixedTemperatureBC(node: 0, temperatureCelsius: 0),
                                    FixedTemperatureBC(node: 4, temperatureCelsius: 100)]))
        XCTAssertThrowsError(try study.thermalRequest().solve()) { error in
            guard case EngineeringError.invalidMaterial = error else {
                return XCTFail("expected invalidMaterial, got \(error)")
            }
        }
    }
}

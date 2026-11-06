// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeEngineeringCore

/// Export identity (JSON roundtrip, hash stability and hash sensitivity) plus
/// manufacturability screening and material library provenance.
final class ExportAndManufacturabilityTests: XCTestCase {

    func testSessionRoundTripAndHashStability() throws {
        let study = try EngineeringExamples.patchFieldStudy()
        let result = try study.structuralRequest().solve()
        let record = try study.exportSession(structural: result)
        let data = try EngineeringExport.encode(record)
        let decoded = try EngineeringExport.decode(data)
        XCTAssertEqual(decoded.studySourceHash, record.studySourceHash)
        XCTAssertEqual(decoded.recordHash, record.recordHash)
        XCTAssertEqual(decoded.formatVersion, EngineeringExport.formatVersion)
        XCTAssertEqual(decoded.study, study)
        XCTAssertEqual(decoded.structuralResult?.elements.count, result.elements.count)
        XCTAssertEqual(decoded.structuralResult?.nodalDisplacementMM.count, result.nodalDisplacementMM.count)
        XCTAssertTrue(decoded.unsupportedDomains.contains(EngineeringUnsupported.meshFromSurface.rawValue))
        XCTAssertTrue(decoded.materialProvenance[0].contains("ASTM A36"))
        XCTAssertTrue(decoded.solverProvenance.contains("tetrahedron"))
        // The source hash binds every input — loads, BCs, numerics included:
        // changing any of them changes the hash.
        var altered = study
        altered.structural?.tolerance.relativeResidual = 1e-6
        let record2 = try altered.exportSession()
        XCTAssertNotEqual(record2.studySourceHash, record.studySourceHash)
        var alteredBC = study
        alteredBC.structural?.displacementBCs[0].prescribedMM[0] = 0.5
        let record3 = try alteredBC.exportSession()
        XCTAssertNotEqual(record3.studySourceHash, record.studySourceHash)
        // Identical inputs -> identical hash (deterministic canonical encoding).
        let record4 = try study.exportSession()
        XCTAssertEqual(record4.studySourceHash, record.studySourceHash)
    }

    func testSessionHashExcludesWallClock() throws {
        let study = try EngineeringExamples.patchFieldStudy()
        let r1 = try study.structuralRequest().solve()
        let r2 = try study.structuralRequest().solve()
        let a = try study.exportSession(structural: r1)
        let b = try study.exportSession(structural: r2)
        XCTAssertNotEqual(a.recordHash, b.recordHash) // wallSeconds differs inside results
        // But the study/source identity is timing-free and stable.
        XCTAssertEqual(a.studySourceHash, b.studySourceHash)
    }

    func testMaterialLibraryRecordsCarryProvenance() {
        XCTAssertEqual(MaterialLibrary.all.count, 3)
        for record in MaterialLibrary.all {
            XCTAssertFalse(record.certified)
            XCTAssertFalse(record.provenance.isEmpty)
            XCTAssertTrue(record.provenance.contains("MatWeb") || record.provenance.contains("AZoM"))
            XCTAssertEqual(record.symmetry, .isotropic)
        }
        XCTAssertEqual(MaterialLibrary.record("aluminum-6061-t6")?.elasticModulusMPa, 68_900)
        XCTAssertNil(MaterialLibrary.record("does-not-exist"))
    }

    func testWallThicknessFlagsThinElements() throws {
        // A sliver tet must be flagged by the inradius proxy.
        let nodes = [
            MeshNode(Vector3(0, 0, 0)),
            MeshNode(Vector3(10, 0, 0)),
            MeshNode(Vector3(0, 10, 0)),
            MeshNode(Vector3(5, 5, 0.05)), // very flat apex -> tiny inradius
        ]
        let study = EngineeringStudy(id: "thin", name: "Thin wall",
                                     meshNodes: nodes, meshElements: [Tetrahedron(0, 1, 2, 3)],
                                     material: MaterialLibrary.structuralSteelA36,
                                     manufacturability: EngineeringStudy.ManufacturabilityConfig(
                                        minimumWallThicknessMM: 0.5))
        let run = try study.run()
        let wall = try XCTUnwrap(run.manufacturability?.wallThickness)
        XCTAssertEqual(wall.belowMinimum.count, 1)
        XCTAssertEqual(wall.belowMinimum[0].element, 0)
        XCTAssertLessThan(wall.minimumInradiusProxyMM, 0.5)
        XCTAssertTrue(wall.isMeshProxy)
        XCTAssertEqual(wall.meshTotalVolumeMM3, 10 * 10 * 0.05 / 6, accuracy: 1e-9)
    }

    func testCuttingForceEstimateIsPositiveAndMonotonic() throws {
        let small = try ManufacturabilityCheck.cuttingForce(widthMM: 2, chipThicknessMM: 0.1)
        let large = try ManufacturabilityCheck.cuttingForce(widthMM: 2, chipThicknessMM: 0.4)
        XCTAssertGreaterThan(small.cuttingForceN, 0)
        XCTAssertGreaterThan(large.cuttingForceN, small.cuttingForceN)
        // Kienzle: Fc = kc11 * b * h^(1-mc).
        let expected = 1600 * 2 * pow(0.1, 0.75)
        XCTAssertEqual(small.cuttingForceN, expected, accuracy: 1e-9)
        XCTAssertFalse(small.provenance.isEmpty)
        XCTAssertThrowsError(try ManufacturabilityCheck.cuttingForce(widthMM: 0, chipThicknessMM: 0.1))
        XCTAssertThrowsError(try ManufacturabilityCheck.cuttingForce(widthMM: 2, chipThicknessMM: -1))
    }

    func testUnitsAreExplicit() {
        XCTAssertEqual(EngineeringUnit.conductivityWPerMMK.summary, "W/(mm·K)")
        XCTAssertEqual(EngineeringUnit.stressMPa.summary, "MPa (N/mm^2)")
        XCTAssertTrue(EngineeringUnit.allCases.contains(.lengthMM))
        XCTAssertTrue(EngineeringUnit.allCases.contains(.sourceWPerMM3))
    }
}

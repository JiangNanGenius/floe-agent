// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeEngineeringCore

/// Mesh geometry validation: volumes, Jacobian gradients, orientation and
/// degenerate/inverted rejection, including skewed and rotated affine maps.
final class MeshGeometryTests: XCTestCase {

    private func validated(nodes: [MeshNode], elements: [Tetrahedron]) throws -> ValidatedTetraMesh {
        try ValidatedTetraMesh(nodes: nodes, elements: elements, budget: EngineeringBudget())
    }

    func testUnitTetVolumeAndGradients() throws {
        let nodes = [
            MeshNode(Vector3(0, 0, 0)),
            MeshNode(Vector3(1, 0, 0)),
            MeshNode(Vector3(0, 1, 0)),
            MeshNode(Vector3(0, 0, 1)),
        ]
        let mesh = try validated(nodes: nodes, elements: [Tetrahedron(0, 1, 2, 3)])
        let g = mesh.geometry[0]
        XCTAssertEqual(g.volume, 1.0 / 6.0, accuracy: 1e-15)
        XCTAssertEqual(g.gradients[1], Vector3(1, 0, 0), accuracy: 1e-15)
        XCTAssertEqual(g.gradients[2], Vector3(0, 1, 0), accuracy: 1e-15)
        XCTAssertEqual(g.gradients[3], Vector3(0, 0, 1), accuracy: 1e-15)
        XCTAssertEqual(g.gradients[0], Vector3(-1, -1, -1), accuracy: 1e-15)
        // Face 0 (opposite node 0) is the slanted unit-simplex face.
        XCTAssertEqual(g.faceArea[0], 0.5 * Vector3(1, 1, 1).magnitude, accuracy: 1e-15)
        // Outward normal points away from node 0: positive octant direction.
        let n = g.outwardNormal[0]
        XCTAssertGreaterThan(n.x, 0); XCTAssertGreaterThan(n.y, 0); XCTAssertGreaterThan(n.z, 0)
    }

    func testShearedTetGradientMatchesHandComputation() throws {
        // Regression for the cofactor/transpose defect: nodes (0,0,0),(1,0,0),
        // (1,1,0),(0,0,1) must give det = 1 and grad N1 = (1,-1,0).
        let nodes = [
            MeshNode(Vector3(0, 0, 0)),
            MeshNode(Vector3(1, 0, 0)),
            MeshNode(Vector3(1, 1, 0)),
            MeshNode(Vector3(0, 0, 1)),
        ]
        let mesh = try validated(nodes: nodes, elements: [Tetrahedron(0, 1, 2, 3)])
        let g = mesh.geometry[0]
        XCTAssertEqual(g.volume, 1.0 / 6.0, accuracy: 1e-15)
        XCTAssertEqual(g.gradients[1], Vector3(1, -1, 0), accuracy: 1e-15)
        XCTAssertEqual(g.gradients[2], Vector3(0, 1, 0), accuracy: 1e-15)
        // Shape functions must still sum to 1 at any point: gradients sum to 0.
        let sum = g.gradients.reduce(Vector3.zero) { $0 + $1 }
        XCTAssertEqual(sum, Vector3.zero, accuracy: 1e-15)
    }

    func testRotatedAndScaledAffineMapPreservesLinearFields() throws {
        // Rotation about z by 90 degrees plus translation and a uniform stretch.
        // Affine maps of the reference tet must preserve volume ratios exactly and
        // transform gradients as g' = R g (rotation), catching transpose bugs that
        // only axis-aligned tets would hide.
        let angle = Double.pi / 2
        let c = cos(angle), s = sin(angle)
        func rz(_ p: Vector3) -> Vector3 { Vector3(c * p.x - s * p.y, s * p.x + c * p.y, p.z) }
        func mapScaled(_ p: Vector3) -> Vector3 {
            // Rz(90): (x,y,z) -> (-y,x,z); then scale 2x and translate.
            return Vector3(2 * (-p.y) + 5, 2 * p.x - 3, 2 * p.z + 7)
        }
        let ref = [
            Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1),
        ]
        // Rigid rotation: volume preserved, gradients rotate exactly.
        let rigidNodes = ref.map { MeshNode(rz($0)) }
        let rigidMesh = try validated(nodes: rigidNodes, elements: [Tetrahedron(0, 1, 2, 3)])
        let rg = rigidMesh.geometry[0]
        XCTAssertEqual(rg.volume, 1.0 / 6.0, accuracy: 1e-15)
        XCTAssertEqual(rg.gradients[1], rz(Vector3(1, 0, 0)), accuracy: 1e-15)
        XCTAssertEqual(rg.gradients[2], rz(Vector3(0, 1, 0)), accuracy: 1e-15)
        XCTAssertEqual(rg.gradients[3], rz(Vector3(0, 0, 1)), accuracy: 1e-15)
        // Scale + rotation + translation: volume scales by 2^3 = 8.
        let nodes = ref.map { MeshNode(mapScaled($0)) }
        let mesh = try validated(nodes: nodes, elements: [Tetrahedron(0, 1, 2, 3)])
        XCTAssertEqual(mesh.geometry[0].volume, 8.0 / 6.0, accuracy: 1e-14)
    }

    func testInvertedTetRejected() {
        let nodes = [
            MeshNode(Vector3(0, 0, 0)),
            MeshNode(Vector3(1, 0, 0)),
            MeshNode(Vector3(0, 1, 0)),
            MeshNode(Vector3(0, 0, 1)),
        ]
        // Swapping nodes 1 and 2 inverts orientation.
        XCTAssertThrowsError(try validated(nodes: nodes, elements: [Tetrahedron(0, 2, 1, 3)])) { error in
            guard case EngineeringError.invalidMesh(let msg) = error else {
                return XCTFail("expected invalidMesh, got \(error)")
            }
            XCTAssertTrue(msg.contains("inverted") || msg.contains("degenerate"), msg)
        }
    }

    func testDegenerateCoplanarTetRejected() {
        let nodes = [
            MeshNode(Vector3(0, 0, 0)),
            MeshNode(Vector3(1, 0, 0)),
            MeshNode(Vector3(0, 1, 0)),
            MeshNode(Vector3(1, 1, 0)), // coplanar with the first three
        ]
        XCTAssertThrowsError(try validated(nodes: nodes, elements: [Tetrahedron(0, 1, 2, 3)])) { error in
            guard case EngineeringError.invalidMesh = error else {
                return XCTFail("expected invalidMesh, got \(error)")
            }
        }
    }

    func testDuplicateNodeIndexRejected() {
        let nodes = [
            MeshNode(Vector3(0, 0, 0)),
            MeshNode(Vector3(1, 0, 0)),
            MeshNode(Vector3(0, 1, 0)),
            MeshNode(Vector3(0, 0, 1)),
        ]
        XCTAssertThrowsError(try validated(nodes: nodes, elements: [Tetrahedron(0, 1, 1, 3)])) { error in
            guard case EngineeringError.invalidMesh = error else {
                return XCTFail("expected invalidMesh, got \(error)")
            }
        }
    }

    func testElementBudgetExceeded() {
        let mesh = EngineeringExamples.twoTetBipyramid()
        var budget = EngineeringBudget()
        budget.maxElements = 1
        XCTAssertThrowsError(try ValidatedTetraMesh(nodes: mesh.nodes, elements: mesh.elements, budget: budget)) { error in
            guard case EngineeringError.budgetExceeded = error else {
                return XCTFail("expected budgetExceeded, got \(error)")
            }
        }
    }

    func testTwoTetBipyramidVolume() throws {
        let mesh = EngineeringExamples.twoTetBipyramid(edgeMM: 10, lengthMM: 40)
        let valid = try validated(nodes: mesh.nodes, elements: mesh.elements)
        XCTAssertEqual(valid.totalVolume, 10 * 10 * 40 / 3, accuracy: 1e-9)
        XCTAssertEqual(valid.geometry.count, 2)
    }
}

private func XCTAssertEqual(_ a: Vector3, _ b: Vector3, accuracy: Double,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
}

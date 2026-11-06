// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Small deterministic demonstration meshes with documented expected results, so
/// Root can wire a local qualification flow without inventing fixtures.
public enum EngineeringExamples {
    /// A two-tetrahedron solid (triangular bipyramid), 5 nodes, 2 elements:
    ///   n0 = (0,0,0)  n1 = (edge,0,0)  n2 = (0,edge,0)  n3 = (0,0,length)  n4 = (edge,0,length)
    /// Tet 0 = (0,1,2,3), Tet 1 = (1,2,3,4), sharing face (1,2,3).
    /// Total volume = edge^2 * length / 3.
    public static func twoTetBipyramid(edgeMM: Double = 10, lengthMM: Double = 40)
        -> (nodes: [MeshNode], elements: [Tetrahedron])
    {
        let e = edgeMM, l = lengthMM
        let nodes = [
            MeshNode(Vector3(0, 0, 0)),
            MeshNode(Vector3(e, 0, 0)),
            MeshNode(Vector3(0, e, 0)),
            MeshNode(Vector3(0, 0, l)),
            MeshNode(Vector3(e, 0, l)),
        ]
        let elements = [Tetrahedron(0, 1, 2, 3), Tetrahedron(1, 2, 3, 4)]
        return (nodes, elements)
    }

    /// Documented expected patch-test quantities for `twoTetBipyramid` under the
    /// affine displacement field u = (alpha * x, 0, 0):
    ///   * With nodes {0,1,2} prescribed from the field and consistent exterior
    ///     tractions on free nodes {3,4}, linear tetrahedra reproduce the field:
    ///     solved displacements match the field to solver tolerance:
    ///     u3x = 0, u4x = alpha * edge.
    ///   * Strain is (alpha, 0, 0, 0, 0, 0); stress is D*(alpha,0,0):
    ///     sxx = c1*alpha, syy = szz = c2*alpha, and von Mises = 2*G*|alpha|.
    ///   * Factor of safety (yield supplied) = yield / (2*G*|alpha|).
    ///   * Reactions balance the applied surface tractions.
    public struct PatchFieldExpectation: Sendable {
        public var expectedU3X: Double
        public var expectedU4X: Double
        public var expectedVonMisesMPa: Double
        public var expectedFactorOfSafety: Double?
    }

    public static func patchFieldExpectation(edgeMM: Double, alpha: Double,
                                             material: EngineeringMaterial) throws -> PatchFieldExpectation {
        let elastic = try IsotropicElasticity(material: material)
        let vm = 2 * elastic.shearModulusMPa * abs(alpha)
        return PatchFieldExpectation(
            expectedU3X: 0,
            expectedU4X: alpha * edgeMM,
            expectedVonMisesMPa: vm,
            expectedFactorOfSafety: vm > 0 ? material.yieldStrengthMPa.map { $0 / vm } : nil)
    }

    /// Consistent exterior-face tractions for u=(alpha*x,0,0), applied only
    /// to nodes 3 and 4. The prescribed base supplies the omitted tractions.
    /// Face area vectors are independent of the stiffness/strain matrix path.
    public static func patchFieldLoads(nodes:[MeshNode],elements:[Tetrahedron],
                                       alpha:Double,material:EngineeringMaterial) throws -> [ConcentratedLoad] {
        let mesh = try ValidatedTetraMesh(nodes:nodes,elements:elements,budget:EngineeringBudget())
        let elastic = try IsotropicElasticity(material:material)
        let stress = Vector3(elastic.constitutiveD[0]*alpha,
                             elastic.constitutiveD[6]*alpha,elastic.constitutiveD[12]*alpha)
        var occurrences:[[Int]:Int] = [:]
        for tet in elements { for opposite in 0..<4 {
            let face = tet.nodes.enumerated().filter { $0.offset != opposite }.map(\.element).sorted()
            occurrences[face,default:0] += 1
        } }
        var forces = [Vector3](repeating:.zero,count:nodes.count)
        for (e,tet) in elements.enumerated() { for opposite in 0..<4 {
            let face = tet.nodes.enumerated().filter { $0.offset != opposite }.map(\.element).sorted()
            guard occurrences[face] == 1 else { continue }
            let areaVector = mesh.geometry[e].outwardNormal[opposite] * mesh.geometry[e].faceArea[opposite]
            let load = Vector3(stress.x*areaVector.x,stress.y*areaVector.y,stress.z*areaVector.z)*(1.0/3)
            for n in face where n == 3 || n == 4 { forces[n] = forces[n]+load }
        } }
        return [3,4].filter { $0 < nodes.count }.map { ConcentratedLoad(node:$0,components:forces[$0]) }
    }

    /// Builds the complete patch-field study described above.
    public static func patchFieldStudy(edgeMM: Double = 10, lengthMM: Double = 40,
                                       alpha: Double = 1e-3,
                                       material: EngineeringMaterial = MaterialLibrary.structuralSteelA36) throws
        -> EngineeringStudy
    {
        let mesh = twoTetBipyramid(edgeMM: edgeMM, lengthMM: lengthMM)
        func field(_ node: Int) -> Double {
            alpha * mesh.nodes[node].position.x
        }
        let bcs = [
            DisplacementBC(node: 0, constrained: [true, true, true], prescribedMM: [field(0), 0, 0]),
            DisplacementBC(node: 1, constrained: [true, true, true], prescribedMM: [field(1), 0, 0]),
            DisplacementBC(node: 2, constrained: [true, true, true], prescribedMM: [field(2), 0, 0]),
        ]
        return EngineeringStudy(
            id: "eng-example-patch-field", name: "Two-tet patch field (nonzero Dirichlet)",
            meshNodes: mesh.nodes, meshElements: mesh.elements, material: material,
            structural: EngineeringStudy.StructuralConfig(
                concentratedLoads:try patchFieldLoads(nodes:mesh.nodes,elements:mesh.elements,alpha:alpha,material:material),
                displacementBCs: bcs))
    }

    /// Builds a loaded study on the same mesh: the bottom face fully fixed, a
    /// downward body load and an outward pressure on element 0 face 0, used to
    /// demonstrate force equilibrium (reaction sum = -applied load sum).
    public static func loadedEquilibriumStudy(edgeMM: Double = 10, lengthMM: Double = 40,
                                              material: EngineeringMaterial = MaterialLibrary.structuralSteelA36)
        -> EngineeringStudy
    {
        let mesh = twoTetBipyramid(edgeMM: edgeMM, lengthMM: lengthMM)
        let zero = [Double](repeating: 0, count: 3)
        let bcs = (0...2).map { DisplacementBC(node: $0, constrained: [true, true, true], prescribedMM: zero) }
        return EngineeringStudy(
            id: "eng-example-equilibrium", name: "Two-tet loaded equilibrium",
            meshNodes: mesh.nodes, meshElements: mesh.elements, material: material,
            structural: EngineeringStudy.StructuralConfig(
                concentratedLoads: [],
                bodyLoads: [BodyLoad(componentsPerVolume: Vector3(0, 0, -1e-3), label: "gravity-like")],
                pressureLoads: [PressureLoad(element: 0, face: 0, pressureMPa: 5e-4, label: "face-traction")],
                displacementBCs: bcs))
    }

    /// Builds a thermal study on the same mesh: fixed nonzero temperatures at the
    /// bottom nodes and the top node, plus a uniform volumetric source, with an
    /// energy-balance expectation documented in the tests.
    public static func thermalStudy(edgeMM: Double = 10, lengthMM: Double = 40,
                                    material: EngineeringMaterial = MaterialLibrary.structuralSteelA36)
        -> EngineeringStudy
    {
        let mesh = twoTetBipyramid(edgeMM: edgeMM, lengthMM: lengthMM)
        return EngineeringStudy(
            id: "eng-example-thermal", name: "Two-tet steady conduction",
            meshNodes: mesh.nodes, meshElements: mesh.elements, material: material,
            thermal: EngineeringStudy.ThermalConfig(
                fixedTemperatures: [
                    FixedTemperatureBC(node: 0, temperatureCelsius: 20),
                    FixedTemperatureBC(node: 1, temperatureCelsius: 20),
                    FixedTemperatureBC(node: 2, temperatureCelsius: 20),
                    FixedTemperatureBC(node: 4, temperatureCelsius: 120),
                ],
                sources: [ThermalSource(element: 0, powerPerVolume: 1e-3),
                          ThermalSource(element: 1, powerPerVolume: 1e-3)]))
    }
}

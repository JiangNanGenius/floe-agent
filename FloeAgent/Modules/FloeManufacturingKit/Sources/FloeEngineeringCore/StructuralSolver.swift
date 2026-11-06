// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Per-element structural output.
public struct ElementStressResult: Codable, Sendable, Equatable {
    public var element: Int
    /// Constant strain [exx, eyy, ezz, gyz, gxz, gxy].
    public var strain: [Double]
    /// Constant stress [sxx, syy, szz, tyz, txz, txy], MPa.
    public var stressMPa: [Double]
    public var vonMisesMPa: Double
    /// Factor of safety interpretation; see `factorOfSafety`. `factorOfSafety`
    /// is always finite (never infinity) so results stay JSON-encodable.
    public var safetyFactorStatus: SafetyFactorStatus
    /// Yield / von Mises when computable (finite, > 0). nil when no yield was
    /// supplied or when von Mises is zero (unbounded) — check the status.
    public var factorOfSafety: Double?
}

public enum SafetyFactorStatus: String, Codable, Sendable {
    /// No yield strength on the material record.
    case notRequested
    /// von Mises is zero: any positive yield gives infinite safety; reported as
    /// an explicit status, never as an infinity literal.
    case unboundedZeroStress
    /// factorOfSafety carries yield / von Mises.
    case computed
}

/// Reaction record at one constrained DOF.
public struct ReactionRecord: Codable, Sendable, Equatable {
    public var node: Int
    /// 0 = x, 1 = y, 2 = z.
    public var component: Int
    public var valueN: Double
}

/// Result of a structural (linear-elastic static) analysis. Units are explicit:
/// displacements mm, forces N, stresses MPa.
public struct StructuralResult: Codable, Sendable {
    public var nodalDisplacementMM: [Vector3]
    public var reactions: [ReactionRecord]
    public var elements: [ElementStressResult]
    /// min/max nodal von Mises across elements (nil when mesh empty — never for a
    /// successful run).
    public var minVonMisesMPa: Double?
    public var maxVonMisesMPa: Double?
    /// min factor of safety across elements, when yield was supplied.
    public var minFactorOfSafety: Double?
    /// CG convergence information: relative residual actually achieved.
    public var relativeResidual: Double
    public var iterations: Int
    public var wallSeconds: Double
    /// Linear-ramp external work including prescribed-support reactions,
    /// versus stored energy 0.5 * u^T K u; these agree to
    /// solver tolerance for a converged solution.
    public var externalWork: Double
    public var strainEnergy: Double
    /// Sum of all reaction components; equals the negative of the sum of applied
    /// external loads at equilibrium. Deviation indicates loss of equilibrium.
    public var reactionSum: Vector3
    public var appliedLoadSum: Vector3
    public var sourceHash: String
}

/// Complete structural request: mesh + isotropic material + loads + displacement
/// boundary conditions + numerics. Codable and Sendable so Root can archive and
/// replay studies exactly.
public struct StructuralRequest: Codable, Sendable {
    public var meshNodes: [MeshNode]
    public var meshElements: [Tetrahedron]
    public var material: EngineeringMaterial
    public var concentratedLoads: [ConcentratedLoad]
    public var bodyLoads: [BodyLoad]
    public var pressureLoads: [PressureLoad]
    public var displacementBCs: [DisplacementBC]
    public var tolerance: EngineeringTolerance
    public var budget: EngineeringBudget

    public init(meshNodes: [MeshNode], meshElements: [Tetrahedron],
                material: EngineeringMaterial,
                concentratedLoads: [ConcentratedLoad] = [],
                bodyLoads: [BodyLoad] = [],
                pressureLoads: [PressureLoad] = [],
                displacementBCs: [DisplacementBC] = [],
                tolerance: EngineeringTolerance = EngineeringTolerance(),
                budget: EngineeringBudget = EngineeringBudget()) {
        self.meshNodes = meshNodes
        self.meshElements = meshElements
        self.material = material
        self.concentratedLoads = concentratedLoads
        self.bodyLoads = bodyLoads
        self.pressureLoads = pressureLoads
        self.displacementBCs = displacementBCs
        self.tolerance = tolerance
        self.budget = budget
    }

    /// Validates and solves. Cancellation is honoured during assembly and solving.
    public func solve(control: EngineeringSolveControl = EngineeringSolveControl()) throws -> StructuralResult {
        let start = Date()
        try tolerance.validate()
        try material.validateForStructural()
        let mesh = try ValidatedTetraMesh(nodes: meshNodes, elements: meshElements, budget: budget)

        let nNodes = mesh.nodes.count
        let ndof = 3 * nNodes
        var fixed = [Bool](repeating: false, count: ndof)
        var prescribed = [Double](repeating: 0, count: ndof)
        var reactionNodeComponent: [(node: Int, component: Int)] = []
        reactionNodeComponent.reserveCapacity(displacementBCs.count)
        for bc in displacementBCs {
            guard bc.node >= 0, bc.node < nNodes else {
                throw EngineeringError.invalidInput("displacement BC references node \(bc.node) out of range")
            }
            guard bc.constrained.count == 3, bc.prescribedMM.count == 3 else {
                throw EngineeringError.invalidInput("displacement BC at node \(bc.node) needs 3 constraint flags and 3 prescribed values")
            }
            for c in 0..<3 where bc.constrained[c] {
                guard bc.prescribedMM[c].isFinite else {
                    throw EngineeringError.invalidInput("displacement BC at node \(bc.node) component \(c) is not finite")
                }
                let d = bc.node * 3 + c
                if fixed[d] {
                    // Duplicate constraint on the same DOF: only an exact repeat is
                    // accepted; any conflicting prescribed value is rejected.
                    guard prescribed[d] == bc.prescribedMM[c] else {
                        throw EngineeringError.invalidInput("conflicting displacement constraints at node \(bc.node) component \(c): \(prescribed[d]) vs \(bc.prescribedMM[c])")
                    }
                    continue
                }
                fixed[d] = true
                prescribed[d] = bc.prescribedMM[c]
                reactionNodeComponent.append((bc.node, c))
            }
        }
        guard !reactionNodeComponent.isEmpty else {
            throw EngineeringError.singular("no displacement boundary conditions: a free elastic body has rigid body modes")
        }

        // Element stiffness blocks (12 DOFs each) for the sparsity pattern.
        let elastic = try IsotropicElasticity(material: material)
        let keBlocks: [[Double]] = mesh.geometry.map { elastic.elementStiffness(geometry: $0) }
        let dofBlocks = mesh.elements.map { tet -> [Int] in
            var out = [Int](); out.reserveCapacity(12)
            for n in tet.nodes { out.append(contentsOf: [n * 3, n * 3 + 1, n * 3 + 2]) }
            return out
        }

        var k = SparseAssembler.makeMatrix(size: ndof, blocks: dofBlocks)
        guard k.column.count <= budget.maxNonzeros else {
            throw EngineeringError.budgetExceeded("assembled nonzeros \(k.column.count) exceed budget \(budget.maxNonzeros)")
        }
        var f = [Double](repeating: 0, count: ndof)
        // Right-hand side from loads, checked against budgets/finiteness.
        for load in concentratedLoads {
            guard load.node >= 0, load.node < nNodes else {
                throw EngineeringError.invalidInput("concentrated load references node \(load.node) out of range")
            }
            guard load.components.isFinite else {
                throw EngineeringError.invalidInput("concentrated load at node \(load.node) is not finite")
            }
            f[load.node * 3] += load.components.x
            f[load.node * 3 + 1] += load.components.y
            f[load.node * 3 + 2] += load.components.z
        }
        for body in bodyLoads {
            guard body.componentsPerVolume.isFinite else {
                throw EngineeringError.invalidInput("body load is not finite")
            }
            for (e, geom) in mesh.geometry.enumerated() {
                try throwIfCancelled(control, e)
                let share = geom.volume / 4.0
                for n in mesh.elements[e].nodes {
                    f[n * 3] += body.componentsPerVolume.x * share
                    f[n * 3 + 1] += body.componentsPerVolume.y * share
                    f[n * 3 + 2] += body.componentsPerVolume.z * share
                }
            }
        }
        for pressure in pressureLoads {
            guard pressure.element >= 0, pressure.element < mesh.elements.count else {
                throw EngineeringError.invalidInput("pressure load references element \(pressure.element) out of range")
            }
            guard pressure.face >= 0, pressure.face < 4 else {
                throw EngineeringError.invalidInput("pressure load face \(pressure.face) out of range 0...3")
            }
            guard pressure.pressureMPa.isFinite else {
                throw EngineeringError.invalidInput("pressure load is not finite")
            }
            let geom = mesh.geometry[pressure.element]
            let n = geom.outwardNormal[pressure.face]
            let a = geom.faceArea[pressure.face]
            for node in mesh.elements[pressure.element].nodes where node != mesh.elements[pressure.element].nodes[pressure.face] {
                f[node * 3] += pressure.pressureMPa * n.x * a / 3.0
                f[node * 3 + 1] += pressure.pressureMPa * n.y * a / 3.0
                f[node * 3 + 2] += pressure.pressureMPa * n.z * a / 3.0
            }
        }
        let appliedLoadSum = Vector3(
            (0..<nNodes).reduce(0.0) { $0 + f[$1 * 3] },
            (0..<nNodes).reduce(0.0) { $0 + f[$1 * 3 + 1] },
            (0..<nNodes).reduce(0.0) { $0 + f[$1 * 3 + 2] })

        let externalLoads = f
        // Assemble with load correction for nonzero prescribed displacements:
        // free DOFs solve K_ff u_f = F_f - K_fc u_c.
        for (e, ke) in keBlocks.enumerated() {
            try throwIfCancelled(control, e)
            let dofs = dofBlocks[e]
            for (li, gi) in dofs.enumerated() where fixed[gi] && prescribed[gi] != 0 {
                for (lj, gj) in dofs.enumerated() where !fixed[gj] {
                    f[gj] -= ke[li * 12 + lj] * prescribed[gi]
                }
            }
            k.addBlock(ke, indices: dofs)
            if Date().timeIntervalSince(start) > budget.maxWallSeconds {
                throw EngineeringError.budgetExceeded("assembly wall-time budget \(budget.maxWallSeconds)s exceeded")
            }
        }

        // Reduced system on free DOFs.
        var freeDOFs: [Int] = []
        freeDOFs.reserveCapacity(ndof)
        for d in 0..<ndof where !fixed[d] { freeDOFs.append(d) }
        var freeIndex = [Int](repeating: -1, count: ndof)
        for (i, d) in freeDOFs.enumerated() { freeIndex[d] = i }
        let kff = try reducedMatrix(k, freeDOFs: freeDOFs, freeIndex: freeIndex, budget: budget)
        var ff = [Double](repeating: 0, count: freeDOFs.count)
        for (i, d) in freeDOFs.enumerated() { ff[i] = f[d] }

        // Load-independent validation: these checks decide singularity from the
        // constrained topology and stiffness alone, so a zero or unexcited
        // right-hand side can never mask a rigid mode.
        try SystemValidation.requireMemoryBudget(diagCount: ndof, offDiagonalNonzeros: k.column.count,
                                                 budget: budget, label: "assembled structural matrix")
        try SystemValidation.requireMemoryBudget(diagCount: freeDOFs.count, offDiagonalNonzeros: kff.column.count,
                                                 budget: budget, label: "reduced structural matrix")
        try SystemValidation.requirePositiveDiagonal(kff.diag, label: "structural")
        try SystemValidation.requireSupportInEveryComponent(
            elementNodes: mesh.elements.map { $0.nodes }, nodeCount: nNodes,
            isSupported: { n in fixed[n * 3] || fixed[n * 3 + 1] || fixed[n * 3 + 2] },
            kind: "structural")
        if !freeDOFs.isEmpty {
            // Load-independent SPD proof: bounded profile LDL^T factorization
            // (Sylvester). Catches arbitrary-point supports, hinge mechanisms and
            // floating components that a masked rigid-basis scan would miss.
            _ = try LDLCertification.certifySPD(kff, budget: budget, control: control, start: start)
        }

        let cg = try ConjugateGradientSolver.solve(kff, b: ff, tolerance: tolerance,
                                                   budget: budget, control: control)

        // Full displacement vector.
        var u = prescribed
        for (i, d) in freeDOFs.enumerated() { u[d] = cg.solution[i] }

        // Reactions at constrained DOFs: R = K u - F.
        var reactions: [ReactionRecord] = []
        reactions.reserveCapacity(reactionNodeComponent.count)
        var reactionSum = Vector3.zero
        let ku = k.multiply(u)
        for (node, component) in reactionNodeComponent {
            let d = node * 3 + component
            let r = ku[d] - f[d]
            reactions.append(ReactionRecord(node: node, component: component, valueN: r))
            if component == 0 { reactionSum.x += r } else if component == 1 { reactionSum.y += r } else { reactionSum.z += r }
        }

        // Element strains/stresses/von Mises/factor of safety.
        var elementResults: [ElementStressResult] = []
        elementResults.reserveCapacity(mesh.elements.count)
        var minVM = Double.greatestFiniteMagnitude, maxVM = 0.0
        var minFoS: Double? = nil
        for (e, tet) in mesh.elements.enumerated() {
            var ue = [Double](repeating: 0, count: 12)
            for (i, n) in tet.nodes.enumerated() {
                ue[i * 3] = u[n * 3]; ue[i * 3 + 1] = u[n * 3 + 1]; ue[i * 3 + 2] = u[n * 3 + 2]
            }
            let (strain, stress) = elastic.elementStrainStress(geometry: mesh.geometry[e], nodalDisplacement: ue)
            let vm = vonMisesStressMPa(stress)
            minVM = min(minVM, vm); maxVM = max(maxVM, vm)
            var fos: Double? = nil
            var fosStatus: SafetyFactorStatus = .notRequested
            if let yieldStrength = material.yieldStrengthMPa {
                if vm <= 1e-12 * max(1.0, yieldStrength) {
                    fosStatus = .unboundedZeroStress
                } else {
                    let value = yieldStrength / vm
                    fos = value
                    fosStatus = .computed
                    minFoS = min(minFoS ?? .greatestFiniteMagnitude, value)
                }
            }
            elementResults.append(ElementStressResult(element: e, strain: strain,
                                                      stressMPa: stress, vonMisesMPa: vm,
                                                      safetyFactorStatus: fosStatus,
                                                      factorOfSafety: fos))
        }

        // Linear ramp work includes reactions at nonzero prescribed DOFs.
        // The corrected reduced RHS is not the physical external load vector.
        var externalWork = 0.5 * dot(u,externalLoads)
        for reaction in reactions {
            externalWork += 0.5 * u[reaction.node*3+reaction.component] * reaction.valueN
        }
        let strainEnergy = 0.5 * dot(u,ku)

        return StructuralResult(
            nodalDisplacementMM: (0..<nNodes).map { Vector3(u[$0 * 3], u[$0 * 3 + 1], u[$0 * 3 + 2]) },
            reactions: reactions,
            elements: elementResults,
            minVonMisesMPa: minVM == .greatestFiniteMagnitude ? nil : minVM,
            maxVonMisesMPa: maxVM,
            minFactorOfSafety: minFoS,
            relativeResidual: cg.relativeResidual,
            iterations: cg.iterations,
            wallSeconds: Date().timeIntervalSince(start),
            externalWork: externalWork,
            strainEnergy: strainEnergy,
            reactionSum: reactionSum,
            appliedLoadSum: appliedLoadSum,
            sourceHash: try EngineeringExport.canonicalHash(of: self))
    }

    private func throwIfCancelled(_ control: EngineeringSolveControl, _ e: Int) throws {
        if e & 0x3FF == 0x3FF { try control.checkCancelled() }
    }

    private func dot(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for i in 0..<a.count { s += a[i] * b[i] }
        return s
    }

    private func reducedMatrix(_ k: SymmetricSparseMatrix, freeDOFs: [Int],
                               freeIndex: [Int], budget: EngineeringBudget) throws -> SymmetricSparseMatrix {
        // Gather row patterns of the full matrix restricted to free DOFs.
        var blocks: [[Int]] = []
        blocks.reserveCapacity(freeDOFs.count)
        for gi in freeDOFs {
            var row: [Int] = [freeIndex[gi]]
            let lo = k.rowStart[gi], hi = k.rowStart[gi + 1]
            for p in lo..<hi {
                let fj = freeIndex[k.column[p]]
                if fj >= 0 { row.append(fj) }
            }
            blocks.append(row)
        }
        var out = SparseAssembler.makeMatrix(size: freeDOFs.count, blocks: blocks)
        guard out.column.count <= budget.maxNonzeros else {
            throw EngineeringError.budgetExceeded("reduced nonzeros \(out.column.count) exceed budget \(budget.maxNonzeros)")
        }
        for (row, gi) in freeDOFs.enumerated() {
            out.diag[row] = k.diag[gi]
            let lo = k.rowStart[gi], hi = k.rowStart[gi + 1]
            for p in lo..<hi {
                let fj = freeIndex[k.column[p]]
                if fj < 0 { continue }
                let col = fj > row ? fj : row
                let rowi = fj > row ? row : fj
                var p2 = out.rowStart[rowi], pEnd = out.rowStart[rowi + 1]
                while p2 < pEnd {
                    if out.column[p2] == col { out.value[p2] = k.value[p]; break }
                    p2 += 1
                }
            }
        }
        return out
    }
}

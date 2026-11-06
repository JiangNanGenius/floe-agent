// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Nodal heat-flow record at one fixed-temperature DOF (the heat the boundary
/// must supply/remove to hold the prescribed temperature), watts.
public struct BoundaryFluxRecord: Codable, Sendable, Equatable {
    public var node: Int
    public var heatFlowW: Double
}

/// Result of a steady-state isotropic heat-conduction analysis. Temperatures in
/// degrees Celsius, heat flows in watts.
public struct ThermalResult: Codable, Sendable {
    public var nodalTemperatureCelsius: [Double]
    public var boundaryFluxes: [BoundaryFluxRecord]
    /// Sum of all volumetric sources (positive = generated), W.
    public var totalSourcePowerW: Double
    /// Sum of all applied face fluxes (positive = leaving the body), W.
    public var totalAppliedFluxW: Double
    /// Sum of boundary heat flows at fixed-temperature nodes (positive into body), W.
    public var totalBoundaryHeatFlowW: Double
    /// totalBoundaryHeatFlowW + totalSourcePowerW - totalAppliedFluxW; must be ~0
    /// for a converged solve. Reported (not hidden) so callers can validate.
    public var energyBalanceResidualW: Double
    public var minTemperatureCelsius: Double
    public var maxTemperatureCelsius: Double
    public var relativeResidual: Double
    public var iterations: Int
    public var wallSeconds: Double
    public var sourceHash: String
}

/// Steady-state isotropic heat conduction request:
///   div(k grad T) + q = 0  with fixed temperatures, volumetric sources and
/// outward face fluxes. Requires a real conductivity on the material record.
public struct ThermalRequest: Codable, Sendable {
    public var meshNodes: [MeshNode]
    public var meshElements: [Tetrahedron]
    public var material: EngineeringMaterial
    public var fixedTemperatures: [FixedTemperatureBC]
    public var sources: [ThermalSource]
    public var faceFluxes: [ThermalFlux]
    public var tolerance: EngineeringTolerance
    public var budget: EngineeringBudget

    public init(meshNodes: [MeshNode], meshElements: [Tetrahedron],
                material: EngineeringMaterial,
                fixedTemperatures: [FixedTemperatureBC] = [],
                sources: [ThermalSource] = [],
                faceFluxes: [ThermalFlux] = [],
                tolerance: EngineeringTolerance = EngineeringTolerance(),
                budget: EngineeringBudget = EngineeringBudget()) {
        self.meshNodes = meshNodes
        self.meshElements = meshElements
        self.material = material
        self.fixedTemperatures = fixedTemperatures
        self.sources = sources
        self.faceFluxes = faceFluxes
        self.tolerance = tolerance
        self.budget = budget
    }

    public func solve(control: EngineeringSolveControl = EngineeringSolveControl()) throws -> ThermalResult {
        let start = Date()
        try tolerance.validate()
        try material.validateForThermal()
        let mesh = try ValidatedTetraMesh(nodes: meshNodes, elements: meshElements, budget: budget)
        let n = mesh.nodes.count
        guard !fixedTemperatures.isEmpty else {
            throw EngineeringError.singular("no fixed-temperature boundary conditions: steady conduction problem is indeterminate")
        }
        var fixed = [Bool](repeating: false, count: n)
        var prescribed = [Double](repeating: 0, count: n)
        var fixedNodes: [Int] = []
        for bc in fixedTemperatures {
            guard bc.node >= 0, bc.node < n else {
                throw EngineeringError.invalidInput("fixed temperature references node \(bc.node) out of range")
            }
            guard bc.temperatureCelsius.isFinite else {
                throw EngineeringError.invalidInput("fixed temperature at node \(bc.node) is not finite")
            }
            if fixed[bc.node] {
                // Conflicting duplicate fixed-temperature values are rejected.
                guard prescribed[bc.node] == bc.temperatureCelsius else {
                    throw EngineeringError.invalidInput("conflicting fixed temperatures at node \(bc.node): \(prescribed[bc.node]) vs \(bc.temperatureCelsius)")
                }
                continue
            }
            fixed[bc.node] = true
            prescribed[bc.node] = bc.temperatureCelsius
            fixedNodes.append(bc.node)
        }
        let kCond = material.thermalConductivityWPerMMK!

        // Element conductivity matrices (4x4): Ke = k * V * grad_i . grad_j.
        let keBlocks: [[Double]] = mesh.geometry.map { g in
            var ke = [Double](repeating: 0, count: 16)
            for i in 0..<4 {
                for j in 0..<4 {
                    ke[i * 4 + j] = kCond * g.volume * g.gradients[i].dot(g.gradients[j])
                }
            }
            return ke
        }
        let dofBlocks = mesh.elements.map { $0.nodes }

        var k = SparseAssembler.makeMatrix(size: n, blocks: dofBlocks)
        guard k.column.count <= budget.maxNonzeros else {
            throw EngineeringError.budgetExceeded("assembled nonzeros \(k.column.count) exceed budget \(budget.maxNonzeros)")
        }
        var f = [Double](repeating: 0, count: n)
        var totalSource = 0.0
        for src in sources {
            guard src.element >= 0, src.element < mesh.elements.count else {
                throw EngineeringError.invalidInput("thermal source references element \(src.element) out of range")
            }
            guard src.powerPerVolume.isFinite else {
                throw EngineeringError.invalidInput("thermal source is not finite")
            }
            let geom = mesh.geometry[src.element]
            totalSource += src.powerPerVolume * geom.volume
            for node in mesh.elements[src.element].nodes {
                f[node] += src.powerPerVolume * geom.volume / 4.0
            }
        }
        var totalFlux = 0.0
        for flux in faceFluxes {
            guard flux.element >= 0, flux.element < mesh.elements.count else {
                throw EngineeringError.invalidInput("thermal flux references element \(flux.element) out of range")
            }
            guard flux.face >= 0, flux.face < 4 else {
                throw EngineeringError.invalidInput("thermal flux face \(flux.face) out of range 0...3")
            }
            guard flux.fluxWPerMM2.isFinite else {
                throw EngineeringError.invalidInput("thermal flux is not finite")
            }
            let geom = mesh.geometry[flux.element]
            let q = flux.fluxWPerMM2 * geom.faceArea[flux.face]
            totalFlux += q
            for node in mesh.elements[flux.element].nodes where node != mesh.elements[flux.element].nodes[flux.face] {
                f[node] -= q / 3.0
            }
        }

        // Load correction for nonzero prescribed temperatures.
        for (e, ke) in keBlocks.enumerated() {
            if e & 0x3FF == 0x3FF { try control.checkCancelled() }
            let dofs = dofBlocks[e]
            for i in 0..<4 where fixed[dofs[i]] && prescribed[dofs[i]] != 0 {
                for j in 0..<4 where !fixed[dofs[j]] {
                    f[dofs[j]] -= ke[i * 4 + j] * prescribed[dofs[i]]
                }
            }
            k.addBlock(ke, indices: dofs)
            if Date().timeIntervalSince(start) > budget.maxWallSeconds {
                throw EngineeringError.budgetExceeded("assembly wall-time budget \(budget.maxWallSeconds)s exceeded")
            }
        }

        var freeNodes: [Int] = []
        var freeIndex = [Int](repeating: -1, count: n)
        for d in 0..<n where !fixed[d] { freeIndex[d] = freeNodes.count; freeNodes.append(d) }
        let kff = try reducedMatrix(k, freeNodes: freeNodes, freeIndex: freeIndex, budget: budget)
        var ff = [Double](repeating: 0, count: freeNodes.count)
        for (i, d) in freeNodes.enumerated() { ff[i] = f[d] }

        // Load-independent validation. The conduction operator has a constant
        // null space; eliminating fixed temperatures leaves an SPD reduced system
        // iff every connected component is anchored by a fixed node. Checked
        // explicitly so zero-source/zero-flux problems cannot vacuously succeed.
        try SystemValidation.requireMemoryBudget(diagCount: n, offDiagonalNonzeros: k.column.count,
                                                 budget: budget, label: "assembled thermal matrix")
        try SystemValidation.requireMemoryBudget(diagCount: freeNodes.count, offDiagonalNonzeros: kff.column.count,
                                                 budget: budget, label: "reduced thermal matrix")
        try SystemValidation.requirePositiveDiagonal(kff.diag, label: "thermal")
        try SystemValidation.requireSupportInEveryComponent(
            elementNodes: mesh.elements.map { $0.nodes }, nodeCount: n,
            isSupported: { fixed[$0] }, kind: "thermal")
        if !freeNodes.isEmpty {
            _ = try LDLCertification.certifySPD(kff, budget: budget, control: control, start: start)
        }

        let cg = try ConjugateGradientSolver.solve(kff, b: ff, tolerance: tolerance,
                                                   budget: budget, control: control)
        var t = prescribed
        for (i, d) in freeNodes.enumerated() { t[d] = cg.solution[i] }

        // Boundary heat flow at fixed nodes from the residual of the full system.
        let kt = k.multiply(t)
        var records: [BoundaryFluxRecord] = []
        var totalBoundary: Double = 0
        for node in fixedNodes {
            let q = kt[node] - f[node]
            records.append(BoundaryFluxRecord(node: node, heatFlowW: q))
            totalBoundary += q
        }

        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for v in t { lo = min(lo, v); hi = max(hi, v) }
        return ThermalResult(
            nodalTemperatureCelsius: t,
            boundaryFluxes: records,
            totalSourcePowerW: totalSource,
            totalAppliedFluxW: totalFlux,
            totalBoundaryHeatFlowW: totalBoundary,
            energyBalanceResidualW: totalBoundary + totalSource - totalFlux,
            minTemperatureCelsius: lo,
            maxTemperatureCelsius: hi,
            relativeResidual: cg.relativeResidual,
            iterations: cg.iterations,
            wallSeconds: Date().timeIntervalSince(start),
            sourceHash: try EngineeringExport.canonicalHash(of: self))
    }

    private func reducedMatrix(_ k: SymmetricSparseMatrix, freeNodes: [Int],
                               freeIndex: [Int], budget: EngineeringBudget) throws -> SymmetricSparseMatrix {
        var blocks: [[Int]] = []
        blocks.reserveCapacity(freeNodes.count)
        for gi in freeNodes {
            var row: [Int] = [freeIndex[gi]]
            for p in k.rowStart[gi]..<k.rowStart[gi + 1] {
                let fj = freeIndex[k.column[p]]
                if fj >= 0 { row.append(fj) }
            }
            blocks.append(row)
        }
        var out = SparseAssembler.makeMatrix(size: freeNodes.count, blocks: blocks)
        guard out.column.count <= budget.maxNonzeros else {
            throw EngineeringError.budgetExceeded("reduced nonzeros \(out.column.count) exceed budget \(budget.maxNonzeros)")
        }
        for (row, gi) in freeNodes.enumerated() {
            out.diag[row] = k.diag[gi]
            for p in k.rowStart[gi]..<k.rowStart[gi + 1] {
                let fj = freeIndex[k.column[p]]
                if fj < 0 { continue }
                let col = max(fj, row), rowi = min(fj, row)
                for p2 in out.rowStart[rowi]..<out.rowStart[rowi + 1] where out.column[p2] == col {
                    out.value[p2] = k.value[p]
                }
            }
        }
        return out
    }
}

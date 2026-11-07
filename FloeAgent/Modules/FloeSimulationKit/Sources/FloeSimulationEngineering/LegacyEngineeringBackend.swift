import Foundation
import FloeSimulationCore
import FloeEngineeringCore

/// Reuses the existing qualified tet4 implementation; its capability declaration
/// deliberately keeps advanced/native analyses on their own adapters.
public struct LegacyEngineeringSimulationBackend: SimulationBackend {
    public init() {}
    public var descriptor: SimulationBackendDescriptor { .init(id: "floe.tet4", version: "r5-si-adapter-1", supportedStudies: [.structuralStatic, .thermalSteady], isAvailable: true) }

    public func validate(_ request: SimulationRequest) throws {
        try request.validate()
        guard descriptor.supportedStudies.contains(request.study.kind) else { throw SimulationError.unsupported(request.study.kind.rawValue) }
        let configuration = try request.study.configuration(as: EngineeringSimulationConfiguration.self)
        try configuration.validate(for: request)
        guard let mesh = request.mesh, mesh.elements.allSatisfy({ $0.kind == .tetrahedron4 }), Set(request.study.materialAssignments.values).count == 1 else { throw SimulationError.unsupported("The tet4 backend requires tetrahedra and one assigned isotropic material.") }
        guard configuration.materialModel == .linearIsotropic, !configuration.largeDeformation, configuration.contacts.isEmpty,
              configuration.convection.isEmpty, configuration.beamSections.isEmpty, configuration.shellSections.isEmpty else { throw SimulationError.unsupported("These settings require an advanced engineering backend.") }
        _ = try material(request)
    }

    public func solve(_ request: SimulationRequest, progress: @escaping SimulationProgressHandler) async throws -> SimulationResult {
        try validate(request); try Task.checkCancellation()
        let configuration = try request.study.configuration(as: EngineeringSimulationConfiguration.self)
        guard let mesh = request.mesh else { throw SimulationError.invalidInput("Missing mesh.") }
        let nodes = mesh.nodes.map { MeshNode(Vector3($0.x * 1000, $0.y * 1000, $0.z * 1000)) }
        let elements = mesh.elements.map { Tetrahedron($0.nodes[0], $0.nodes[1], $0.nodes[2], $0.nodes[3]) }
        let material = try material(request)
        let budget = EngineeringBudget(maxNodes: request.budget.maximumNodes, maxElements: request.budget.maximumElements, maxIterations: request.budget.maximumIterations)
        let tolerance = EngineeringTolerance(relativeResidual: configuration.relativeTolerance)
        let control = EngineeringSolveControl(isCancelled: { Task.isCancelled })
        await progress(.init(stage: "assembling"))
        var fields: [SimulationResultField] = [], diagnostics: [String:String] = [:]
        do {
            if request.study.kind == .structuralStatic {
                let constraints = try configuration.constraints.flatMap { constraint in
                    try constraint.selection.resolveNodes(in: mesh).map { DisplacementBC(node: $0, constrained: constraint.fixedAxes, prescribedMM: [constraint.displacementMeters.x * 1000, constraint.displacementMeters.y * 1000, constraint.displacementMeters.z * 1000]) }
                }
                let forces = try configuration.forces.flatMap { condition in
                    let indices = try condition.selection.resolveNodes(in: mesh), value = condition.value / Double(indices.count)
                    return indices.map { ConcentratedLoad(node: $0, components: Vector3(value.x, value.y, value.z)) }
                }
                let pressures = try configuration.pressures.flatMap { condition in
                    try faces(condition.selection, mesh: mesh).map { PressureLoad(element: $0.0, face: $0.1, pressureMPa: -condition.value / 1e6) }
                }
                let body = configuration.bodyForceNewtonsPerCubicMeter * 1e-9
                let solved = try StructuralRequest(meshNodes: nodes, meshElements: elements, material: material, concentratedLoads: forces,
                    bodyLoads: body == .zero ? [] : [BodyLoad(componentsPerVolume: Vector3(body.x,body.y,body.z))], pressureLoads: pressures, displacementBCs: constraints, tolerance: tolerance, budget: budget).solve(control: control)
                fields.append(.init(id: "displacement", name: "Displacement", unit: "m", location: .node, components: 3, values: solved.nodalDisplacementMM.flatMap { [$0.x / 1000,$0.y / 1000,$0.z / 1000] }))
                fields.append(.init(id: "stress", name: "Stress", unit: "Pa", location: .element, components: 6, values: solved.elements.flatMap { $0.stressMPa.map { $0 * 1e6 } }))
                fields.append(.init(id: "strain", name: "Strain", unit: "1", location: .element, components: 6, values: solved.elements.flatMap(\.strain)))
                fields.append(.init(id: "von_mises", name: "Von Mises stress", unit: "Pa", location: .element, components: 1, values: solved.elements.map { $0.vonMisesMPa * 1e6 }))
                var reactions = [Double](repeating: 0, count: mesh.nodes.count * 3)
                for reaction in solved.reactions { reactions[reaction.node * 3 + reaction.component] += reaction.valueN }
                fields.append(.init(id: "reaction", name: "Reaction", unit: "N", location: .node, components: 3, values: reactions))
                diagnostics = ["relativeResidual":String(solved.relativeResidual), "iterations":String(solved.iterations), "strainEnergyJ":String(solved.strainEnergy / 1000), "legacySourceHash":solved.sourceHash]
            } else {
                let temperatures = try configuration.fixedTemperatures.flatMap { value in try value.selection.resolveNodes(in: mesh).map { FixedTemperatureBC(node: $0, temperatureCelsius: value.value - 273.15) } }
                let sources = mesh.elements.enumerated().compactMap { index, element in configuration.volumeHeatSourcesWPerCubicMeter[element.regionID].map { ThermalSource(element: index, powerPerVolume: $0 * 1e-9) } }
                let fluxes = try configuration.faceHeatFluxes.flatMap { value in try faces(value.selection, mesh: mesh).map { ThermalFlux(element: $0.0, face: $0.1, fluxWPerMM2: value.value * 1e-6) } }
                let solved = try ThermalRequest(meshNodes: nodes, meshElements: elements, material: material, fixedTemperatures: temperatures, sources: sources, faceFluxes: fluxes, tolerance: tolerance, budget: budget).solve(control: control)
                fields.append(.init(id: "temperature", name: "Temperature", unit: "K", location: .node, components: 1, values: solved.nodalTemperatureCelsius.map { $0 + 273.15 }))
                var flows = [Double](repeating: 0, count: mesh.nodes.count)
                for flux in solved.boundaryFluxes { flows[flux.node] += flux.heatFlowW }
                fields.append(.init(id: "boundary_heat_flow", name: "Boundary heat flow", unit: "W", location: .node, components: 1, values: flows))
                diagnostics = ["relativeResidual":String(solved.relativeResidual), "iterations":String(solved.iterations), "energyBalanceResidualW":String(solved.energyBalanceResidualW), "legacySourceHash":solved.sourceHash]
            }
        } catch EngineeringError.cancelled { throw SimulationError.cancelled }
        try Task.checkCancellation()
        await progress(.init(stage: "complete", completed: 1, total: 1, residual: Double(diagnostics["relativeResidual"] ?? "")))
        let result = SimulationResult(requestID: request.id, source: request.source, studyID: request.study.id, studyRevision: request.study.revision, backend: descriptor, mesh: mesh, frames: [.init(id: 0, fields: fields)], diagnostics: diagnostics)
        try result.validate(for: request); return result
    }

    private func material(_ request: SimulationRequest) throws -> EngineeringMaterial {
        guard let id = request.study.materialAssignments.values.first, let material = request.materials.first(where: { $0.id == id }), material.layers.isEmpty else { throw SimulationError.invalidInput("An isotropic engineering material is required.") }
        let values = material.properties
        if request.study.kind == .structuralStatic, values["youngModulusPa"] == nil || values["poissonRatio"] == nil { throw SimulationError.invalidInput("Set Young's modulus and Poisson's ratio.") }
        if request.study.kind == .thermalSteady, values["thermalConductivityWPerMeterK"] == nil { throw SimulationError.invalidInput("Set thermal conductivity.") }
        return EngineeringMaterial(id: material.id.uuidString, name: material.name, elasticModulusMPa: (values["youngModulusPa"] ?? 1) / 1e6, poissonRatio: values["poissonRatio"] ?? 0,
            massDensityKgPerMM3: values["densityKgPerCubicMeter"].map { $0 / 1e9 }, yieldStrengthMPa: values["yieldStrengthPa"].map { $0 / 1e6 }, thermalConductivityWPerMMK: values["thermalConductivityWPerMeterK"].map { $0 / 1000 }, provenance: material.provenance)
    }

    private func faces(_ selection: SimulationSelection, mesh: SimulationMesh) throws -> [(Int,Int)] {
        if case .boundary(let id) = selection, let boundary = mesh.boundaries.first(where:{ $0.id == id }), let facets = boundary.facets, !facets.isEmpty {
            return try facets.map { facet in
                guard let face = facet.localFace, mesh.elements.indices.contains(facet.elementIndex), mesh.elements[facet.elementIndex].kind == .tetrahedron4, (0..<4).contains(face) else { throw SimulationError.invalidInput("A tet4 surface load requires tetrahedron face references.") }
                return (facet.elementIndex,face)
            }
        }
        let selected = Set(try selection.resolveNodes(in: mesh))
        var incidence: [[Int]:[(Int,Int)]] = [:]
        for (index, element) in mesh.elements.enumerated() { for face in 0..<4 {
            let faceNodes = element.nodes.enumerated().filter { $0.offset != face }.map(\.element).sorted()
            if faceNodes.allSatisfy({ selected.contains($0) }) { incidence[faceNodes, default: []].append((index,face)) }
        } }
        var exterior: [(Int,Int)] = []
        for values in incidence.values where values.count == 1 { exterior.append(contentsOf:values) }
        exterior.sort { first, second in
            if first.0 == second.0 { return first.1 < second.1 }
            return first.0 < second.0
        }
        guard !exterior.isEmpty else { throw SimulationError.invalidInput("Select an exterior triangular face for a surface load.") }
        return exterior
    }
}

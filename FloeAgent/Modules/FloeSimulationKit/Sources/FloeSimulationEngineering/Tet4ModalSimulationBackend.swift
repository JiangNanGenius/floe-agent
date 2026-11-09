// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeSimulationCore
import FloeEngineeringCore

/// Real, unloaded, constrained small-strain tet4 modes. This does not claim
/// prestressed, free-free, damped or transient structural dynamics.
public struct Tet4ModalSimulationBackend: SimulationBackend {
    public init() {}
    public var descriptor: SimulationBackendDescriptor {
        .init(id:"floe.modal.tet4",version:"consistent-mass-accelerate-1",supportedStudies:[.modal],isAvailable:true)
    }
    public func validate(_ request:SimulationRequest) throws { _ = try checked(request) }
    public func solve(_ request:SimulationRequest,progress:@escaping SimulationProgressHandler) async throws -> SimulationResult {
        let (mesh,input) = try checked(request)
        try Task.checkCancellation();await progress(.init(stage:"assembling"))
        let solved:EngineeringModalResult
        do { solved = try input.solve(control:.init(isCancelled:{ Task.isCancelled })) }
        catch let error as EngineeringError {
            switch error {
            case .cancelled: throw SimulationError.cancelled
            case .budgetExceeded(let message): throw SimulationError.resourceLimit(message)
            case .unsupportedAnalysis(let message): throw SimulationError.unsupported(message)
            case .invalidInput(let message),.invalidMesh(let message),.invalidMaterial(let message): throw SimulationError.invalidInput(message)
            case .singular(let message),.illConditioned(let message): throw SimulationError.solverFailure(message)
            }
        }
        try Task.checkCancellation()
        let frames = solved.modes.map { mode in
            SimulationResultFrame(id:mode.index,frequencyHz:mode.frequencyHz,fields:[
                .init(id:"mode_shape",name:"Normalized mode shape",unit:"1",location:.node,components:3,values:mode.normalizedShape.flatMap { [$0.x,$0.y,$0.z] }),
                .init(id:"modal_mass",name:"Generalized modal mass",unit:"kg",location:.global,components:1,values:[mode.generalizedMassKg]),
                .init(id:"modal_stiffness",name:"Generalized modal stiffness",unit:"N/m",location:.global,components:1,values:[mode.generalizedStiffnessNPerMeter])
            ])
        }
        var diagnostics = ["element":"tet4 / isotropic small strain","massMatrix":"consistent structural mass (kg)","eigensolver":"Accelerate dsygvd / K_SI phi = omega^2 M phi","shapeNormalization":"dimensionless; maximum nodal vector norm = 1; no excitation amplitude","freeDOFs":String(solved.freeDOFs),"maximumMassOrthogonalityError":String(solved.maximumMassOrthogonalityError),"minimumStiffnessPivot":String(solved.minimumStiffnessPivot),"wallSeconds":String(solved.wallSeconds),"engineeringSourceHash":solved.sourceHash]
        for mode in solved.modes {
            diagnostics["frame/\(mode.index)/relativeResidual"] = String(mode.relativeResidual)
            diagnostics["frame/\(mode.index)/massNormalizationError"] = String(mode.massNormalizationError)
            diagnostics["frame/\(mode.index)/omegaSquaredPerSecondSquared"] = String(mode.angularFrequencySquaredPerSecondSquared)
        }
        let result = SimulationResult(requestID:request.id,source:request.source,studyID:request.study.id,studyRevision:request.study.revision,backend:descriptor,mesh:mesh,frames:frames,diagnostics:diagnostics)
        try result.validate(for:request)
        await progress(.init(stage:"complete",completed:1,total:1,residual:solved.modes.map(\.relativeResidual).max()))
        return result
    }
    private func checked(_ request:SimulationRequest) throws -> (SimulationMesh,EngineeringModalRequest) {
        try request.validate()
        guard request.study.kind == .modal else { throw SimulationError.unsupported(request.study.kind.rawValue) }
        let c = try request.study.configuration(as:EngineeringSimulationConfiguration.self);try c.validate(for:request)
        guard let mesh=request.mesh,mesh.elements.allSatisfy({ $0.kind == .tetrahedron4 }),Set(request.study.materialAssignments.values).count==1 else { throw SimulationError.unsupported("Modal analysis requires a tet4 volume mesh and one assigned isotropic material.") }
        guard c.materialModel == .linearIsotropic,!c.largeDeformation,c.contacts.isEmpty,c.beamSections.isEmpty,c.shellSections.isEmpty,
              c.forces.isEmpty,c.pressures.isEmpty,c.bodyForceNewtonsPerCubicMeter == .zero,c.preloadedResultID == nil,
              c.fixedTemperatures.isEmpty,c.faceHeatFluxes.isEmpty,c.volumeHeatSourcesWPerCubicMeter.isEmpty,c.convection.isEmpty,c.temperatureResultID == nil else { throw SimulationError.unsupported("These modes require unloaded linear isotropic solids; prestress, thermal coupling and advanced mechanics are unavailable.") }
        guard !c.constraints.isEmpty else { throw SimulationError.invalidInput("Add displacement supports for constrained modal analysis.") }
        guard let id=request.study.materialAssignments.values.first,let m=request.materials.first(where:{ $0.id==id }),m.layers.isEmpty,
              let young=m.properties["youngModulusPa"],young>0,let poisson=m.properties["poissonRatio"],poisson > -1,poisson < 0.5,
              let density=m.properties["densityKgPerCubicMeter"],density>0 else { throw SimulationError.invalidInput("Set positive Young's modulus, mass density and a Poisson ratio between -1 and 0.5.") }
        let material=EngineeringMaterial(id:m.id.uuidString,name:m.name,elasticModulusMPa:young/1e6,poissonRatio:poisson,massDensityKgPerMM3:density/1e9,provenance:m.provenance)
        try material.validateForStructural()
        guard let coreDensity=material.massDensityKgPerMM3,coreDensity>0 else { throw SimulationError.invalidInput("The mass density cannot be represented in the solver's units.") }
        var fixed=Set<Int>(),supports:[DisplacementBC]=[]
        for condition in c.constraints {
            let displacement=[condition.displacementMeters.x,condition.displacementMeters.y,condition.displacementMeters.z]
            guard (0..<3).allSatisfy({ !condition.fixedAxes[$0] || displacement[$0]==0 }) else { throw SimulationError.unsupported("Modal supports must have zero prescribed displacement; prestress is unavailable.") }
            for node in try condition.selection.resolveNodes(in:mesh) {
                for axis in 0..<3 where condition.fixedAxes[axis] { fixed.insert(node*3+axis) }
                supports.append(.init(node:node,constrained:condition.fixedAxes,prescribedMM:[0,0,0]))
            }
        }
        let free=mesh.nodes.count*3-fixed.count
        guard free>0,free<=512,c.requestedModes<=free else { throw SimulationError.resourceLimit("Use 1...512 free displacement components and request no more modes than free components.") }
        let (count,overflow)=(mesh.nodes.count*3+2).multipliedReportingOverflow(by:c.requestedModes)
        guard !overflow,count<=request.budget.maximumResultValues else { throw SimulationError.resourceLimit("The requested mode shapes exceed the result budget.") }
        let input=EngineeringModalRequest(meshNodes:mesh.nodes.map { MeshNode(Vector3($0.x*1000,$0.y*1000,$0.z*1000)) },meshElements:mesh.elements.map { Tetrahedron($0.nodes[0],$0.nodes[1],$0.nodes[2],$0.nodes[3]) },material:material,displacementBCs:supports,requestedModes:c.requestedModes,tolerance:.init(relativeResidual:c.relativeTolerance),budget:.init(maxNodes:request.budget.maximumNodes,maxElements:request.budget.maximumElements,maxIterations:request.budget.maximumIterations))
        return (mesh,input)
    }
}

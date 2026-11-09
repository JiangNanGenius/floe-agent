// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeSimulationCore
import FloeEngineeringCore

public typealias SimulationTemperatureResultLoader = @Sendable (UUID) async throws -> SimulationArchivedResult

/// One-way thermal stress from an explicitly selected saved temperature
/// snapshot. No heat/mechanics feedback, plasticity or transient dynamics.
public struct Tet4ThermoelasticSimulationBackend: SimulationBackend {
    private let loadTemperature:SimulationTemperatureResultLoader?
    public init(loadTemperature:SimulationTemperatureResultLoader? = nil) { self.loadTemperature=loadTemperature }
    public var descriptor:SimulationBackendDescriptor {
        .init(id:"floe.thermoelastic.tet4",version:"snapshot-initial-strain-1",supportedStudies:[.thermalStress],isAvailable:loadTemperature != nil,unavailableReason:loadTemperature == nil ? "Open a saved simulation workspace to select its temperature result.":nil)
    }
    public func validate(_ request:SimulationRequest) throws { _ = try checked(request) }
    public func solve(_ request:SimulationRequest,progress:@escaping SimulationProgressHandler) async throws -> SimulationResult {
        let (c,mesh,mechanical,alpha)=try checked(request)
        guard let loadTemperature,let temperatureID=c.temperatureResultID else { throw SimulationError.backendUnavailable(descriptor.id) }
        try Task.checkCancellation();await progress(.init(stage:"preparing"))
        let snapshot=try await loadTemperature(temperatureID)
        try snapshot.request.validate();try snapshot.result.validate(for:snapshot.request);try Task.checkCancellation()
        guard snapshot.result.id==temperatureID,snapshot.request.source==request.source,snapshot.result.source==request.source else { throw SimulationError.staleSource }
        guard [.thermalSteady,.thermalTransient].contains(snapshot.request.study.kind) else { throw SimulationError.invalidInput("Choose a steady or transient temperature result.") }
        guard let sourceMesh=snapshot.result.mesh ?? snapshot.request.mesh,sourceMesh==mesh,snapshot.request.mesh==mesh,
              snapshot.request.study.materialAssignments==request.study.materialAssignments else { throw SimulationError.invalidInput("The temperature result uses a different mesh or region assignment. Re-run temperature analysis for this mesh.") }
        for id in Set(request.study.materialAssignments.values) {
            guard snapshot.request.materials.first(where:{$0.id==id})==request.materials.first(where:{$0.id==id}) else { throw SimulationError.invalidInput("The material changed after temperature analysis. Re-run it with the current material.") }
        }
        let frame:SimulationResultFrame
        if let id=c.temperatureFrameID {
            guard let selected=snapshot.result.frames.first(where:{$0.id==id}) else { throw SimulationError.invalidInput("The selected temperature frame is unavailable.") };frame=selected
        } else {
            guard let last=snapshot.result.frames.last else { throw SimulationError.invalidInput("The temperature result has no saved frame.") };frame=last
        }
        guard let temperature=frame.fields.first(where:{$0.id=="temperature"}),temperature.unit=="K",temperature.location == .node,temperature.components==1,temperature.imaginaryValues==nil,
              temperature.values.count==mesh.nodes.count,temperature.values.allSatisfy({$0.isFinite&&$0>=0}) else { throw SimulationError.invalidInput("The selected frame needs one real non-negative Kelvin temperature per node.") }
        await progress(.init(stage:"assembling"));try Task.checkCancellation()
        let solved:ThermoelasticResult
        do { solved=try ThermoelasticRequest(mechanical:mechanical,thermalExpansionPerKelvin:alpha,nodalTemperatureKelvin:temperature.values,referenceTemperatureKelvin:c.referenceTemperatureKelvin).solve(control:.init(isCancelled:{Task.isCancelled})) }
        catch let error as EngineeringError {
            switch error {
            case .cancelled:throw SimulationError.cancelled
            case .budgetExceeded(let message):throw SimulationError.resourceLimit(message)
            case .unsupportedAnalysis(let message):throw SimulationError.unsupported(message)
            case .invalidInput(let message),.invalidMaterial(let message),.invalidMesh(let message):throw SimulationError.invalidInput(message)
            case .singular(let message),.illConditioned(let message):throw SimulationError.solverFailure(message)
            }
        }
        try Task.checkCancellation()
        var reactions=[Double](repeating:0,count:mesh.nodes.count*3)
        for value in solved.reactions { reactions[value.node*3+value.component]+=value.valueN }
        let fields:[SimulationResultField]=[
            .init(id:"temperature",name:"Temperature",unit:"K",location:.node,components:1,values:temperature.values),
            .init(id:"displacement",name:"Displacement",unit:"m",location:.node,components:3,values:solved.nodalDisplacementMM.flatMap { [$0.x/1000,$0.y/1000,$0.z/1000] }),
            .init(id:"thermoelastic_stress",name:"Mean thermoelastic stress",unit:"Pa",location:.element,components:6,values:solved.elements.flatMap { $0.meanStressMPa.map { $0*1e6 } }),
            .init(id:"von_mises_mean_stress",name:"Von Mises of mean stress",unit:"Pa",location:.element,components:1,values:solved.elements.map { $0.vonMisesOfMeanStressMPa*1e6 }),
            .init(id:"total_strain",name:"Total strain",unit:"1",location:.element,components:6,values:solved.elements.flatMap(\.totalStrain)),
            .init(id:"thermal_strain",name:"Mean thermal strain",unit:"1",location:.element,components:6,values:solved.elements.flatMap(\.meanThermalStrain)),
            .init(id:"elastic_strain",name:"Mean elastic strain",unit:"1",location:.element,components:6,values:solved.elements.flatMap(\.meanElasticStrain)),
            .init(id:"reaction",name:"Support reaction",unit:"N",location:.node,components:3,values:reactions)
        ]
        var diagnostics=["coupling":"one-way temperature snapshot / small-strain isotropic tet4","temperatureResultID":temperatureID.uuidString,"temperatureStudyID":snapshot.request.study.id.uuidString,"temperatureStudyRevision":String(snapshot.request.study.revision),"temperatureFrameID":String(frame.id),"referenceTemperatureKelvin":String(c.referenceTemperatureKelvin),"thermalExpansionPerKelvin":String(alpha),"elasticEnergyJ":String(solved.elasticEnergyJ),"equilibriumResidualN":String(solved.equilibriumResidualN),"relativeResidual":String(solved.relativeLinearResidual),"iterations":String(solved.iterations),"engineeringSourceHash":solved.sourceHash,"stressLocation":"element mean; temperature is interpolated linearly inside each tet","energyIntegration":"exact linear-tet temperature second moment; no mechanical time integration"]
        if let time=frame.timeSeconds { diagnostics["temperatureTimeSeconds"]=String(time) }
        let result=SimulationResult(requestID:request.id,source:request.source,studyID:request.study.id,studyRevision:request.study.revision,backend:descriptor,mesh:mesh,frames:[.init(id:0,timeSeconds:frame.timeSeconds,fields:fields)],diagnostics:diagnostics)
        try result.validate(for:request);await progress(.init(stage:"complete",completed:1,total:1,residual:solved.relativeLinearResidual));return result
    }
    private func checked(_ request:SimulationRequest) throws -> (EngineeringSimulationConfiguration,SimulationMesh,StructuralRequest,Double) {
        try request.validate()
        guard request.study.kind == .thermalStress else { throw SimulationError.unsupported(request.study.kind.rawValue) }
        guard descriptor.isAvailable else { throw SimulationError.backendUnavailable(descriptor.unavailableReason ?? descriptor.id) }
        let c=try request.study.configuration(as:EngineeringSimulationConfiguration.self);try c.validate(for:request)
        guard let mesh=request.mesh,mesh.elements.allSatisfy({$0.kind == .tetrahedron4}),Set(request.study.materialAssignments.values).count==1 else { throw SimulationError.unsupported("Thermal stress requires a tet4 mesh and one assigned isotropic material.") }
        guard c.materialModel == .linearIsotropic,!c.largeDeformation,c.contacts.isEmpty,c.beamSections.isEmpty,c.shellSections.isEmpty,c.preloadedResultID==nil,
              c.fixedTemperatures.isEmpty,c.faceHeatFluxes.isEmpty,c.volumeHeatSourcesWPerCubicMeter.isEmpty,c.convection.isEmpty else { throw SimulationError.unsupported("This study reads a saved temperature snapshot. Coupled heat feedback and advanced mechanics are unavailable.") }
        guard c.temperatureFrameID.map({$0>=0}) ?? true else { throw SimulationError.invalidInput("The temperature frame number must be non-negative.") }
        guard let id=request.study.materialAssignments.values.first,let m=request.materials.first(where:{$0.id==id}),m.layers.isEmpty,
              let e=m.properties["youngModulusPa"],e>0,let nu=m.properties["poissonRatio"],nu > -1,nu < 0.5,let alpha=m.properties["thermalExpansionPerKelvin"] else { throw SimulationError.invalidInput("Set isotropic Young's modulus, Poisson ratio and thermal expansion coefficient.") }
        let material=EngineeringMaterial(id:m.id.uuidString,name:m.name,elasticModulusMPa:e/1e6,poissonRatio:nu,provenance:m.provenance)
        try material.validateForStructural()
        let constraints=try c.constraints.flatMap { item in try item.selection.resolveNodes(in:mesh).map { DisplacementBC(node:$0,constrained:item.fixedAxes,prescribedMM:[item.displacementMeters.x*1000,item.displacementMeters.y*1000,item.displacementMeters.z*1000]) } }
        let forces=try c.forces.flatMap { item in
            let nodes=try item.selection.resolveNodes(in:mesh),f=item.value/Double(nodes.count)
            return nodes.map { ConcentratedLoad(node:$0,components:.init(f.x,f.y,f.z)) }
        }
        let pressures=try c.pressures.flatMap { item in try faces(item.selection,mesh:mesh).map { PressureLoad(element:$0.0,face:$0.1,pressureMPa:-item.value/1e6) } }
        let body=c.bodyForceNewtonsPerCubicMeter*1e-9
        let count=mesh.nodes.count*7+mesh.elements.count*25
        guard count<=request.budget.maximumResultValues else { throw SimulationError.resourceLimit("Thermoelastic fields exceed the result budget.") }
        let input=StructuralRequest(meshNodes:mesh.nodes.map { .init(.init($0.x*1000,$0.y*1000,$0.z*1000)) },meshElements:mesh.elements.map { .init($0.nodes[0],$0.nodes[1],$0.nodes[2],$0.nodes[3]) },material:material,concentratedLoads:forces,bodyLoads:body == .zero ? []:[.init(componentsPerVolume:.init(body.x,body.y,body.z))],pressureLoads:pressures,displacementBCs:constraints,tolerance:.init(relativeResidual:c.relativeTolerance),budget:.init(maxNodes:request.budget.maximumNodes,maxElements:request.budget.maximumElements,maxIterations:request.budget.maximumIterations))
        return (c,mesh,input,alpha)
    }
    private func faces(_ selection:SimulationSelection,mesh:SimulationMesh) throws -> [(Int,Int)] {
        if case .boundary(let id)=selection,let boundary=mesh.boundaries.first(where:{$0.id==id}),let facets=boundary.facets,!facets.isEmpty {
            return try facets.map { facet in
                guard let face=facet.localFace,mesh.elements.indices.contains(facet.elementIndex),mesh.elements[facet.elementIndex].kind == .tetrahedron4,(0..<4).contains(face) else { throw SimulationError.invalidInput("A pressure needs exterior tet4 face references.") };return (facet.elementIndex,face)
            }
        }
        let selected=Set(try selection.resolveNodes(in:mesh));var incidence:[[Int]:[(Int,Int)]]=[:]
        for (e,tet) in mesh.elements.enumerated() { for face in 0..<4 {
            let nodes=tet.nodes.enumerated().filter {$0.offset != face}.map(\.element).sorted()
            if nodes.allSatisfy({selected.contains($0)}) { incidence[nodes,default:[]].append((e,face)) }
        } }
        var exterior:[(Int,Int)]=[]
        for values in incidence.values where values.count==1 { exterior.append(contentsOf:values) }
        exterior.sort { a,b in
            if a.0==b.0 { return a.1<b.1 }
            return a.0<b.0
        }
        guard !exterior.isEmpty else { throw SimulationError.invalidInput("Select an exterior triangular face for pressure.") };return exterior
    }
}

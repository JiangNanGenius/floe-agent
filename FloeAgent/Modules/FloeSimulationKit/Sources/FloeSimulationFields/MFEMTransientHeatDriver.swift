// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeSimulationCore
import FloeSimulationEngineering
#if canImport(FloeFieldsNative)
import FloeFieldsNative
#endif

/// Limited to real, isotropic tet4 heat transport. It does not advertise
/// structural thermal stress, fluid heat transfer, phase change or mechanics.
public struct MFEMTransientHeatSimulationDriver: SimulationBackend, SimulationNativeDriver {
    public init() {}
    public var descriptor: SimulationBackendDescriptor {
        #if canImport(FloeFieldsNative)
        .init(id:"floe.heat.mfem",version:String(cString:floe_fields_mfem_version()),supportedStudies:[.thermalTransient],isAvailable:true)
        #else
        .init(id:"floe.heat.mfem",version:"MFEM4.8 / heat ABI3",supportedStudies:[.thermalTransient],isAvailable:false,unavailableReason:"The native transient heat artifact is unavailable.")
        #endif
    }
    public func validate(_ request:SimulationRequest) throws { _ = try checked(request) }
    public func solve(_ request:SimulationRequest,progress:@escaping SimulationProgressHandler) async throws -> SimulationResult { try await execute(request,progress:progress) }
    public func execute(_ request:SimulationRequest,progress:@escaping SimulationProgressHandler) async throws -> SimulationResult {
        let (configuration,input,steps) = try checked(request)
        try Task.checkCancellation()
        #if canImport(FloeFieldsNative)
        let session = try MFEMSession()
        await progress(.init(stage:"preparing"));try session.load(input)
        for region in input.regionIDs {
            let id = request.study.materialAssignments[region]!,material = request.materials.first { $0.id == id }!
            let k = material.properties["thermalConductivityWPerMeterK"]!,capacity = material.properties["densityKgPerCubicMeter"]!*material.properties["specificHeatJPerKgK"]!
            try session.check(region.withCString { floe_fields_mfem_add_thermal_material(session.pointer,$0,k,capacity,configuration.volumeHeatSourcesWPerCubicMeter[region] ?? 0) })
        }
        for boundary in configuration.fixedTemperatures {
            for node in try boundary.selection.resolveNodes(in:input.mesh) { try session.check(floe_fields_mfem_add_thermal_temperature(session.pointer,Int32(node),boundary.value)) }
        }
        for boundary in configuration.faceHeatFluxes {
            guard case .boundary(let id) = boundary.selection else { throw SimulationError.unsupported("Heat flux needs an exterior boundary selection.") }
            try session.check(id.withCString { floe_fields_mfem_add_thermal_flux(session.pointer,$0,boundary.value) })
        }
        for boundary in configuration.convection {
            try session.check(boundary.boundaryID.withCString { floe_fields_mfem_add_thermal_convection(session.pointer,$0,boundary.coefficientWPerSquareMeterK,boundary.ambientKelvin) })
        }
        let initial = try await withTaskCancellationHandler { try session.beginHeat(configuration.initialTemperatureKelvin,nodes:input.mesh.nodes.count,elements:input.mesh.elements.count) } onCancel: { session.cancel() }
        var frames:[SimulationResultFrame] = [.init(id:0,timeSeconds:0,fields:initial.fields)]
        var diagnostics = ["timeScheme":"backward Euler with consistent heat capacity","element":"tet4 / isotropic","initialEnergyJ":String(initial.energy)]
        var previousTime = 0.0,peakBalance = 0.0
        for (index,step) in steps.enumerated() {
            try Task.checkCancellation()
            let solved = try await withTaskCancellationHandler { try session.stepHeat(step.time-previousTime,tolerance:configuration.relativeTolerance,iterations:request.budget.maximumIterations,nodes:input.mesh.nodes.count,elements:input.mesh.elements.count) } onCancel: { session.cancel() }
            previousTime = step.time;peakBalance = max(peakBalance,abs(solved.balance))
            if step.output {
                let id = frames.count
                frames.append(.init(id:id,timeSeconds:step.time,fields:solved.fields))
                for (key,value) in solved.diagnostics { diagnostics["frame/\(id)/"+key] = value }
                await progress(.init(stage:"solving",completed:index+1,total:steps.count,residual:solved.residual))
            }
        }
        diagnostics["peakEnergyBalanceResidualW"] = String(peakBalance);diagnostics["nativeStepCount"] = String(steps.count)
        try Task.checkCancellation()
        let result = SimulationResult(requestID:request.id,source:request.source,studyID:request.study.id,studyRevision:request.study.revision,backend:descriptor,mesh:input.mesh,frames:frames,diagnostics:diagnostics)
        try result.validate(for:request);await progress(.init(stage:"complete",completed:1,total:1));return result
        #else
        throw SimulationError.backendUnavailable(descriptor.id)
        #endif
    }
    private struct Step { var time:Double; var output:Bool }
    private func checked(_ request:SimulationRequest) throws -> (EngineeringSimulationConfiguration,MFEMNativeInput,[Step]) {
        try request.validate()
        guard request.study.kind == .thermalTransient else { throw SimulationError.unsupported(request.study.kind.rawValue) }
        guard descriptor.isAvailable else { throw SimulationError.backendUnavailable(descriptor.id) }
        let c = try request.study.configuration(as:EngineeringSimulationConfiguration.self);try c.validate(for:request)
        guard c.materialModel == .linearIsotropic,!c.largeDeformation,c.contacts.isEmpty,c.beamSections.isEmpty,c.shellSections.isEmpty,
              c.constraints.isEmpty,c.forces.isEmpty,c.pressures.isEmpty,c.bodyForceNewtonsPerCubicMeter == .zero,c.temperatureResultID == nil,c.preloadedResultID == nil else { throw SimulationError.unsupported("This heat driver does not calculate mechanics or coupled thermal stress.") }
        var ids = Set(c.convection.map(\.boundaryID))
        for value in c.faceHeatFluxes {
            guard case .boundary(let id) = value.selection else { throw SimulationError.unsupported("Heat flux needs an exterior boundary selection.") };ids.insert(id)
        }
        let input = try MFEMNativeInput(request,boundaryIDs:Array(ids))
        for region in input.regionIDs {
            guard let id = request.study.materialAssignments[region],let m = request.materials.first(where: { $0.id == id }),m.layers.isEmpty,
                  let k=m.properties["thermalConductivityWPerMeterK"],k.isFinite,k>0,
                  let density=m.properties["densityKgPerCubicMeter"],density.isFinite,density>0,
                  let cp=m.properties["specificHeatJPerKgK"],cp.isFinite,cp>0,(density*cp).isFinite else { throw SimulationError.invalidInput("Assign positive isotropic conductivity, density and specific heat to every heat region.") }
        }
        var fixed:[Int:Double] = [:]
        for condition in c.fixedTemperatures {
            for node in try condition.selection.resolveNodes(in:input.mesh) {
                if let old=fixed[node],old != condition.value { throw SimulationError.invalidInput("Two prescribed temperatures conflict at a shared mesh node.") };fixed[node]=condition.value
            }
        }
        let limit=min(10_000,request.budget.maximumIterations);try c.time.validate(maximumSteps:limit)
        var steps:[Step]=[],time=0.0
        let outputs=max(1,Int(ceil(c.time.durationSeconds/c.time.outputIntervalSeconds)))
        for output in 1...outputs {
            let target=min(Double(output)*c.time.outputIntervalSeconds,c.time.durationSeconds)
            while time<target {
                let remaining=target-time,roundoff=32*Double.ulpOfOne*max(c.time.stepSeconds,abs(target),abs(time))
                let next=remaining<=c.time.stepSeconds+roundoff ? target:time+c.time.stepSeconds
                guard next>time,next.isFinite,(1/(next-time)).isFinite,steps.count<limit else { throw SimulationError.resourceLimit("The heat step cannot be resolved or exceeds its 10,000-step or requested iteration budget.") }
                time=next;steps.append(.init(time:time,output:time==target))
            }
        }
        let values=input.mesh.nodes.count+input.mesh.elements.count*3
        guard outputs+1<=min(request.budget.maximumResultValues,10_000_000)/max(1,values) else { throw SimulationError.resourceLimit("The heat history exceeds its result budget.") }
        return (c,input,steps)
    }
}

#if canImport(FloeFieldsNative)
extension MFEMSession {
    struct HeatFrame {
        var fields:[SimulationResultField];var energy:Double;var balance:Double;var residual:Double;var diagnostics:[String:String]
    }
    private func heatFields(_ temperature:[Double],_ flux:[Double]) -> [SimulationResultField] {
        [.init(id:"temperature",name:"Temperature",unit:"K",location:.node,components:1,values:temperature),.init(id:"heat_flux",name:"Heat flux",unit:"W/m²",location:.element,components:3,values:flux)]
    }
    func beginHeat(_ initial:Double,nodes:Int,elements:Int) throws -> HeatFrame {
        var temperature=[Double](repeating:0,count:nodes),flux=[Double](repeating:0,count:elements*3),energy=0.0
        try check(floe_fields_mfem_thermal_begin(pointer,initial,&temperature,&flux,&energy))
        return .init(fields:heatFields(temperature,flux),energy:energy,balance:0,residual:0,diagnostics:["storedEnergyJ":String(energy)])
    }
    func stepHeat(_ dt:Double,tolerance:Double,iterations:Int,nodes:Int,elements:Int) throws -> HeatFrame {
        var temperature=[Double](repeating:0,count:nodes),flux=[Double](repeating:0,count:elements*3),energy=0.0,source=0.0,boundary=0.0,balance=0.0,residual=0.0,seconds=0.0
        try check(floe_fields_mfem_thermal_step(pointer,dt,tolerance,Int32(clamping:iterations),&temperature,&flux,&energy,&source,&boundary,&balance,&residual,&seconds))
        return .init(fields:heatFields(temperature,flux),energy:energy,balance:balance,residual:residual,diagnostics:["storedEnergyJ":String(energy),"volumePowerW":String(source),"boundaryPowerIntoDomainW":String(boundary),"energyBalanceResidualW":String(balance),"relativeResidual":String(residual),"solveSeconds":String(seconds)])
    }
}
#endif

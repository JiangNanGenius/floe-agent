import Foundation
import FloeSimulationCore
#if canImport(FloeFieldsNative)
import FloeFieldsNative
#endif

/// CPU-only MFEM, linked into the App. Advertises only the equations actually
/// assembled by this artifact; RF, magnetic and flow remain separate drivers.
public struct MFEMSimulationDriver: SimulationNativeDriver, SimulationBackend {
    public init() {}
    public var descriptor: SimulationBackendDescriptor {
        #if canImport(FloeFieldsNative)
        .init(id:"floe.fields.mfem",version:String(cString:floe_fields_mfem_version()),supportedStudies:[.electrostatic,.pressureAcoustics],isAvailable:true)
        #else
        .init(id:"floe.fields.mfem",version:"MFEM 4.8.0 / floe-fields 2",supportedStudies:[.electrostatic,.pressureAcoustics],isAvailable:false,unavailableReason:"The native field artifact is unavailable.")
        #endif
    }
    public func validate(_ request: SimulationRequest) throws {
        try request.validate()
        guard descriptor.supportedStudies.contains(request.study.kind) else { throw SimulationError.unsupported(request.study.kind.rawValue) }
        guard descriptor.isAvailable else { throw SimulationError.backendUnavailable(descriptor.id) }
        guard let mesh = request.mesh else { throw SimulationError.invalidInput("Create a volume mesh first.") }
        let order: Int, frames: Int, valuesPerFrame: Int
        if request.study.kind == .electrostatic {
            let configuration = try request.study.configuration(as:ElectromagneticSimulationConfiguration.self)
            try configuration.validate(for:request); order = configuration.finiteElementOrder; frames = 1; valuesPerFrame = mesh.nodes.count+mesh.elements.count*6+2
            guard configuration.ports.isEmpty, configuration.coils.isEmpty,
                  configuration.boundaries.allSatisfy({ [.electricPotential,.perfectElectric,.perfectMagnetic].contains($0.kind) && $0.value.imaginary == 0 }) else { throw SimulationError.unsupported("This electrostatic model supports real potential and insulated boundaries.") }
            guard configuration.boundaries.allSatisfy({ $0.kind == .electricPotential || $0.value.magnitude == 0 }) else { throw SimulationError.invalidInput("Ground and insulated boundaries require zero amplitude.") }
            try MFEMNativeInput.validateElectrodes(configuration,mesh:mesh)
            for material in request.materials where request.study.materialAssignments.values.contains(material.id) {
                guard material.layers.isEmpty else { throw SimulationError.unsupported("Layered dielectric tensors require another field formulation.") }
                guard let epsilon = material.properties["relativePermittivity"], epsilon > 0 else { throw SimulationError.invalidInput("Set a positive relative permittivity.") }
                guard (material.properties["electricalConductivitySiemensPerMeter"] ?? 0) == 0 else { throw SimulationError.unsupported("Conducting volumes require a conduction model; use electrode boundaries for electrostatics.") }
            }
        } else {
            let configuration = try request.study.configuration(as:AcousticSimulationConfiguration.self)
            try configuration.validate(for:request); order = configuration.finiteElementOrder; frames = configuration.frequencies.frequenciesHz.count; valuesPerFrame = mesh.nodes.count*3+mesh.elements.count*6
            guard configuration.boundaries.allSatisfy({ ![.rigidWall,.radiation].contains($0.kind) || $0.value.magnitude == 0 }) else { throw SimulationError.invalidInput("Rigid-wall and radiation boundaries require zero imposed amplitude.") }
            guard configuration.boundaries.contains(where:{ [.pressure,.normalVelocity].contains($0.kind) && $0.value.magnitude > 0 }) else { throw SimulationError.invalidInput("Set an acoustic pressure or normal-velocity excitation.") }
            var prescribed: [Int:SimulationComplex] = [:]
            for boundary in configuration.boundaries where boundary.kind == .pressure {
                for node in try SimulationSelection.boundary(boundary.boundaryID).resolveNodes(in:mesh) {
                    if let old = prescribed[node], old != boundary.value { throw SimulationError.invalidInput("Two acoustic pressures conflict at a shared mesh node.") }
                    prescribed[node] = boundary.value
                }
            }
        }
        guard (1...3).contains(order) else { throw SimulationError.unsupported("This field artifact supports element orders 1 through 3.") }
        guard valuesPerFrame > 0, frames <= request.budget.maximumResultValues/valuesPerFrame else { throw SimulationError.resourceLimit("The field sweep exceeds its result budget.") }
    }
    public func solve(_ request: SimulationRequest, progress: @escaping SimulationProgressHandler) async throws -> SimulationResult { try await execute(request,progress:progress) }
    public func execute(_ request: SimulationRequest, progress: @escaping SimulationProgressHandler) async throws -> SimulationResult {
        try validate(request); try Task.checkCancellation()
        #if canImport(FloeFieldsNative)
        let session = try MFEMSession()
        let electromagnetic = request.study.kind == .electrostatic ? try request.study.configuration(as:ElectromagneticSimulationConfiguration.self) : nil
        let acoustic = request.study.kind == .pressureAcoustics ? try request.study.configuration(as:AcousticSimulationConfiguration.self) : nil
        let input = try MFEMNativeInput(request,boundaryIDs:electromagnetic?.boundaries.map(\.boundaryID) ?? acoustic!.boundaries.map(\.boundaryID))
        await progress(.init(stage:"preparing"))
        try session.load(input)
        for region in input.regionIDs {
            let material = request.study.materialAssignments[region].flatMap { id in request.materials.first { $0.id == id } }
            if electromagnetic != nil {
                try session.check(region.withCString { floe_fields_mfem_add_em_material(session.pointer,$0,material!.properties["relativePermittivity"]!,material!.properties["relativePermeability"] ?? 1,0) })
            } else if let acoustic {
                guard material?.layers.isEmpty ?? true else { throw SimulationError.unsupported("Layered acoustic media require another formulation.") }
                try session.check(region.withCString { floe_fields_mfem_add_acoustic_medium(session.pointer,$0,material?.properties["densityKgPerCubicMeter"] ?? acoustic.densityKgPerCubicMeter,material?.properties["soundSpeedMetersPerSecond"] ?? acoustic.soundSpeedMetersPerSecond,material?.properties["acousticLossFactor"] ?? acoustic.lossFactor) })
            }
        }
        for boundary in electromagnetic?.boundaries ?? [] {
            let kind: Int32 = switch boundary.kind { case .perfectElectric:0; case .perfectMagnetic:1; case .electricPotential:4; default:-1 }
            try session.check(boundary.boundaryID.withCString { floe_fields_mfem_add_em_boundary(session.pointer,$0,kind,boundary.value.real,boundary.value.imaginary) })
        }
        for boundary in acoustic?.boundaries ?? [] {
            let kind: Int32 = switch boundary.kind { case .rigidWall:0; case .pressure:1; case .normalVelocity:2; case .impedance:3; case .radiation:4 }
            try session.check(boundary.boundaryID.withCString { floe_fields_mfem_add_acoustic_boundary(session.pointer,$0,kind,boundary.value.real,boundary.value.imaginary) })
        }
        var frames: [SimulationResultFrame] = [], diagnostics: [String:String] = [:]
        if let electromagnetic {
            await progress(.init(stage:"solving"))
            let solved = try await withTaskCancellationHandler { try session.electrostatic(order:electromagnetic.finiteElementOrder,tolerance:electromagnetic.relativeTolerance,iterations:request.budget.maximumIterations,nodes:input.mesh.nodes.count,elements:input.mesh.elements.count) } onCancel: { session.cancel() }
            frames = [.init(id:0,fields:solved.fields)]; diagnostics = solved.diagnostics
        } else if let acoustic {
            floe_fields_mfem_set_acoustic_reference_pressure(session.pointer,acoustic.referencePressurePascal)
            for (index,frequency) in acoustic.frequencies.frequenciesHz.enumerated() {
                try Task.checkCancellation(); await progress(.init(stage:"solving",completed:index,total:acoustic.frequencies.frequenciesHz.count))
                let solved = try await withTaskCancellationHandler { try session.acoustic(frequency:frequency,order:acoustic.finiteElementOrder,iterations:request.budget.maximumIterations,nodes:input.mesh.nodes.count,elements:input.mesh.elements.count) } onCancel: { session.cancel() }
                frames.append(.init(id:index,frequencyHz:frequency,fields:solved.fields))
                for (key,value) in solved.diagnostics { diagnostics["frame/\(index)/"+key] = value }
            }
            diagnostics["phasorConvention"] = "exp(+i*omega*t); pressure and velocity are peak amplitudes; SPL uses RMS"
        }
        try Task.checkCancellation()
        let result = SimulationResult(requestID:request.id,source:request.source,studyID:request.study.id,studyRevision:request.study.revision,backend:descriptor,mesh:input.mesh,frames:frames,diagnostics:diagnostics)
        try result.validate(for:request); await progress(.init(stage:"complete",completed:1,total:1)); return result
        #else
        throw SimulationError.backendUnavailable(descriptor.id)
        #endif
    }
}

#if canImport(FloeFieldsNative)
final class MFEMSession: @unchecked Sendable {
    // The immutable handle stays alive through the cancellation handler. Only
    // cancel() crosses threads; its native state is an atomic flag.
    let pointer: OpaquePointer
    init() throws { guard let pointer = floe_fields_mfem_create() else { throw SimulationError.resourceLimit("Unable to allocate the native field session.") }; self.pointer = pointer }
    deinit { floe_fields_mfem_destroy(pointer) }
    func cancel() { floe_fields_mfem_cancel(pointer) }
    func check(_ code: Int32) throws {
        guard code != 0 else { return }
        var buffer = [CChar](repeating:0,count:4096); floe_fields_mfem_last_error(pointer,&buffer,Int32(buffer.count))
        let message = String(decoding:buffer.prefix { $0 != 0 }.map { UInt8(bitPattern:$0) },as:UTF8.self)
        switch code { case 1:throw SimulationError.invalidInput(message); case 2:throw SimulationError.unsupported(message); case 4:throw SimulationError.cancelled; case 5:throw SimulationError.resourceLimit(message); default:throw SimulationError.solverFailure(message) }
    }
    func load(_ input: MFEMNativeInput) throws {
        try withStrings(input.regionIDs) { regions in try withStrings(input.boundaryIDs) { boundaries in
            try input.coordinates.withUnsafeBufferPointer { xyz in try input.tetrahedra.withUnsafeBufferPointer { tetrahedra in try input.regions.withUnsafeBufferPointer { regionIndices in
                try input.triangles.withUnsafeBufferPointer { triangles in try input.boundaries.withUnsafeBufferPointer { boundaryIndices in
                    try check(floe_fields_mfem_set_mesh(pointer,xyz.baseAddress,Int32(input.mesh.nodes.count),tetrahedra.baseAddress,Int32(input.mesh.elements.count),regions,regionIndices.baseAddress,Int32(input.regionIDs.count),triangles.baseAddress,Int32(input.boundaries.count),boundaries,boundaryIndices.baseAddress,Int32(input.boundaryIDs.count)))
                } }
            } } }
        } }
    }
    private func withStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) throws -> T) rethrows -> T {
        let pointers = strings.map { string in
            let bytes = Array(string.utf8CString), pointer = UnsafeMutablePointer<CChar>.allocate(capacity:bytes.count)
            pointer.initialize(from:bytes,count:bytes.count); return pointer
        }
        defer { for pointer in pointers { pointer.deallocate() } }
        let immutable = pointers.map { Optional(UnsafePointer($0)) }
        return try immutable.withUnsafeBufferPointer { try body($0.baseAddress!) }
    }
    func electrostatic(order: Int, tolerance: Double, iterations: Int, nodes: Int, elements: Int) throws -> (fields:[SimulationResultField],diagnostics:[String:String]) {
        var potential = [Double](repeating:0,count:nodes), electric = [Double](repeating:0,count:elements*3), flux = electric
        var energy = 0.0, capacitance = 0.0, residual = 0.0, seconds = 0.0
        try check(floe_fields_mfem_solve_electrostatic(pointer,Int32(order),tolerance,Int32(clamping:iterations),&potential,&electric,&flux,&energy,&capacitance,&residual,&seconds))
        return ([.init(id:"potential",name:"Electric potential",unit:"V",location:.node,components:1,values:potential),
                 .init(id:"electric_field",name:"Electric field",unit:"V/m",location:.element,components:3,values:electric),
                 .init(id:"electric_flux",name:"Electric displacement",unit:"C/m²",location:.element,components:3,values:flux),
                 .init(id:"electric_energy",name:"Electric energy",unit:"J",location:.global,components:1,values:[energy]),
                 .init(id:"effective_capacitance",name:"Energy-equivalent capacitance",unit:"F",location:.global,components:1,values:[capacitance])],
                ["relativeResidual":String(residual),"solveSeconds":String(seconds),"epsilon0FPerMeter":"8.8541878128e-12 (CODATA 2018)"])
    }
    func acoustic(frequency: Double, order: Int, iterations: Int, nodes: Int, elements: Int) throws -> (fields:[SimulationResultField],diagnostics:[String:String]) {
        var real = [Double](repeating:0,count:nodes), imaginary = real, spl = real
        var velocityReal = [Double](repeating:0,count:elements*3), velocityImaginary = velocityReal, residual = 0.0, seconds = 0.0
        try check(floe_fields_mfem_solve_acoustic(pointer,frequency,Int32(order),1e-8,Int32(clamping:iterations),&real,&imaginary,&velocityReal,&velocityImaginary,&spl,&residual,&seconds))
        return ([.init(id:"pressure",name:"Pressure",unit:"Pa",location:.node,components:1,values:real,imaginaryValues:imaginary),
                 .init(id:"particle_velocity",name:"Particle velocity",unit:"m/s",location:.element,components:3,values:velocityReal,imaginaryValues:velocityImaginary),
                 .init(id:"sound_pressure_level",name:"Sound pressure level",unit:"dB",location:.node,components:1,values:spl)],
                ["relativeResidual":String(residual),"solveSeconds":String(seconds)])
    }
}
#endif

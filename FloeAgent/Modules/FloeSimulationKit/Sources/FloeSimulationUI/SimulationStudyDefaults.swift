import Foundation
import FloeSimulationCore
import FloeSimulationRuntime
import FloeSimulationPhysics
import FloeSimulationEngineering
import FloeSimulationFields
import FloeSimulationGeometry

enum SimulationStudyDefaults {
    static func materialProperties(_ kind: SimulationStudyKind) -> (values:[String:Double],units:[String:String]) {
        switch kind {
        case .structuralStatic,.beamShell,.laminate,.modal,.buckling,.nonlinearContact:
            (["youngModulusPa":210e9,"poissonRatio":0.3,"densityKgPerCubicMeter":7800],["youngModulusPa":"Pa","poissonRatio":"1","densityKgPerCubicMeter":"kg/m³"])
        case .thermalSteady,.thermalTransient,.thermalStress:
            (["youngModulusPa":210e9,"poissonRatio":0.3,"thermalConductivityWPerMeterK":45,"densityKgPerCubicMeter":7800,"specificHeatJPerKgK":500,"thermalExpansionPerKelvin":12e-6],["youngModulusPa":"Pa","poissonRatio":"1","thermalConductivityWPerMeterK":"W/(m K)","densityKgPerCubicMeter":"kg/m³","specificHeatJPerKgK":"J/(kg K)","thermalExpansionPerKelvin":"1/K"])
        case .pressureAcoustics:
            (["densityKgPerCubicMeter":1.225,"soundSpeedMetersPerSecond":343,"acousticLossFactor":0],["densityKgPerCubicMeter":"kg/m³","soundSpeedMetersPerSecond":"m/s","acousticLossFactor":"1"])
        case .electrostatic,.magnetostatic,.eddyCurrent,.radioFrequency,.electromagneticModes,.antenna:
            (["relativePermittivity":2.4,"relativePermeability":1,"electricalConductivitySiemensPerMeter":0],["relativePermittivity":"1","relativePermeability":"1","electricalConductivitySiemensPerMeter":"S/m"])
        default: ([:],[:])
        }
    }
    static func configure(_ study: inout SimulationStudy) throws {
        switch study.kind {
        case .rigidBody,.skeletalPhysics,.cloth,.rope,.softBody: try study.setConfiguration(PhysicsSimulationConfiguration())
        case .structuralStatic,.beamShell,.laminate,.modal,.buckling,.nonlinearContact,.thermalSteady,.thermalTransient,.thermalStress: try study.setConfiguration(EngineeringSimulationConfiguration())
        case .incompressibleFlow,.compressibleFlow,.turbulentFlow:
            var value = FlowSimulationConfiguration(); value.regime = study.kind == .compressibleFlow ? .compressible : .incompressible; value.turbulence = study.kind == .turbulentFlow ? .sst : .laminar
            try study.setConfiguration(value)
        case .pressureAcoustics: try study.setConfiguration(AcousticSimulationConfiguration())
        case .electrostatic,.magnetostatic,.eddyCurrent,.radioFrequency,.electromagneticModes,.antenna: try study.setConfiguration(ElectromagneticSimulationConfiguration())
        case .particles: try study.setConfiguration(ParticleSimulationConfiguration())
        case .conjugateHeatTransfer,.fluidStructure,.structuralAcoustics: break
        }
    }
    static func templates() throws -> [SimulationToolStudyTemplate] {
        func json<T: Encodable>(_ value: T) throws -> SimulationJSONValue { try JSONDecoder().decode(SimulationJSONValue.self,from:JSONEncoder().encode(value)) }
        return try SimulationStudyKind.allCases.map { kind in
            var study = SimulationStudy(name:kind.simulationDisplayName,kind:kind); try configure(&study)
            let preset = materialProperties(kind)
            var prototypes: [String:SimulationJSONValue] = [:]
            prototypes["meshSettings"] = try json(SimulationMeshSettings())
            switch kind {
            case .rigidBody,.skeletalPhysics,.cloth,.rope,.softBody:
                prototypes["body"] = try json(SimulationPhysicsBody(sourceObjectID:"replace-with-object-id"))
                prototypes["softBody"] = try json(SimulationPhysicsSoftBody(sourceObjectID:"replace-with-object-id",kind:kind == .rope ? .rope : kind == .softBody ? .volume : .cloth))
                prototypes["joint"] = try json(SimulationPhysicsJoint(kind:.spherical,firstBody:UUID(),secondBody:UUID()))
            case .particles: prototypes["emitter"] = try json(SimulationParticleEmitter())
            case .pressureAcoustics:
                prototypes["boundary"] = try json(SimulationAcousticBoundary(boundaryID:"replace-with-boundary-id",kind:.pressure,value:.init(real:1)))
            case .electrostatic,.magnetostatic,.eddyCurrent,.radioFrequency,.electromagneticModes,.antenna:
                prototypes["boundary"] = try json(SimulationEMBoundary(boundaryID:"replace-with-boundary-id",kind:.electricPotential))
            default: break
            }
            if !preset.values.isEmpty { prototypes["material"] = try json(SimulationMaterial(name:"Material",properties:preset.values)) }
            return .init(kind:kind,name:study.name,configuration:try JSONDecoder().decode(SimulationJSONValue.self,from:study.configuration),materialPropertyUnits:preset.units,prototypes:prototypes)
        }
    }
}

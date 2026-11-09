// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct ThermoelasticElementResult: Codable, Equatable, Sendable {
    public var element:Int
    public var meanTemperatureKelvin:Double
    /// Strain ordering: [xx, yy, zz, yz, xz, xy], engineering shear.
    public var totalStrain:[Double]
    public var meanThermalStrain:[Double]
    public var meanElasticStrain:[Double]
    /// Element mean of D*(B*u-alpha*(T-Tref)*I), in MPa.
    public var meanStressMPa:[Double]
    public var vonMisesOfMeanStressMPa:Double
}
public struct ThermoelasticResult: Codable, Sendable {
    public var nodalDisplacementMM:[Vector3]
    public var reactions:[ReactionRecord]
    public var elements:[ThermoelasticElementResult]
    /// Integral of elastic energy including the within-tet temperature variance.
    public var elasticEnergyJ:Double
    public var equilibriumResidualN:Double
    public var relativeLinearResidual:Double
    public var iterations:Int
    public var wallSeconds:Double
    public var sourceHash:String
}

/// One-way, small-strain isotropic tet4 thermoelasticity at a temperature
/// snapshot. Thermal data never advances a mechanical time integrator.
/// The existing StructuralRequest and its support/SPD checks are unchanged.
public struct ThermoelasticRequest: Codable, Sendable {
    public var mechanical:StructuralRequest
    public var thermalExpansionPerKelvin:Double
    public var nodalTemperatureKelvin:[Double]
    public var referenceTemperatureKelvin:Double
    public init(mechanical:StructuralRequest,thermalExpansionPerKelvin:Double,nodalTemperatureKelvin:[Double],referenceTemperatureKelvin:Double) {
        self.mechanical=mechanical;self.thermalExpansionPerKelvin=thermalExpansionPerKelvin;self.nodalTemperatureKelvin=nodalTemperatureKelvin;self.referenceTemperatureKelvin=referenceTemperatureKelvin
    }
    public func solve(control:EngineeringSolveControl = .init()) throws -> ThermoelasticResult {
        let started=Date();try mechanical.budget.validate();try mechanical.tolerance.validate();try mechanical.material.validateForStructural();try control.checkCancelled()
        guard thermalExpansionPerKelvin.isFinite,referenceTemperatureKelvin.isFinite,referenceTemperatureKelvin>=0,
              nodalTemperatureKelvin.count==mechanical.meshNodes.count,nodalTemperatureKelvin.allSatisfy({$0.isFinite&&$0>=0}) else { throw EngineeringError.invalidInput("Set finite expansion, non-negative Kelvin temperatures and one temperature per mesh node.") }
        let mesh=try ValidatedTetraMesh(nodes:mechanical.meshNodes,elements:mechanical.meshElements,budget:mechanical.budget)
        let extraBytes=mesh.nodes.count*512+mesh.elements.count*1024
        guard extraBytes<mechanical.budget.maxEstimatedBytes else { throw EngineeringError.budgetExceeded("Thermoelastic assembly and result storage exceed the request's memory budget.") }
        let elastic=try IsotropicElasticity(material:mechanical.material),alpha=thermalExpansionPerKelvin
        let unitThermalStrain=[alpha,alpha,alpha,0,0,0],unitThermalStress=stress(unitThermalStrain,elastic)
        var thermal=[Double](repeating:0,count:mesh.nodes.count*3)
        let applied=try appliedLoads(mesh,control:control,started:started)
        for (e,tet) in mesh.elements.enumerated() {
            if e&63==0 { try checkpoint(control,started) }
            let mean=tet.nodes.reduce(0.0) { $0+nodalTemperatureKelvin[$1]/4 },delta=mean-referenceTemperatureKelvin
            let b=IsotropicElasticity.strainDisplacementMatrix(mesh.geometry[e].gradients)
            for local in 0..<12 {
                let value=(0..<6).reduce(0.0) { $0+b[$1*12+local]*unitThermalStress[$1]*delta }*mesh.geometry[e].volume
                thermal[tet.nodes[local/3]*3+local%3]+=value
            }
        }
        guard thermal.allSatisfy(\.isFinite),(zip(thermal,applied).map { $0+$1 }).allSatisfy(\.isFinite) else { throw EngineeringError.illConditioned("The thermal or combined load cannot be represented.") }
        var input=mechanical
        input.budget.maxEstimatedBytes-=extraBytes
        for node in mesh.nodes.indices {
            let f=Vector3(thermal[node*3],thermal[node*3+1],thermal[node*3+2])
            if f != .zero { input.concentratedLoads.append(.init(node:node,components:f)) }
        }
        try checkpoint(control,started)
        input.budget.maxWallSeconds=mechanical.budget.maxWallSeconds-Date().timeIntervalSince(started)
        guard input.budget.maxWallSeconds>0 else { throw EngineeringError.budgetExceeded("Thermoelastic solve exceeded its wall-time budget.") }
        let solved=try input.solve(control:control)
        var elements:[ThermoelasticElementResult]=[],internalForce=[Double](repeating:0,count:thermal.count),energy=0.0
        for (e,tet) in mesh.elements.enumerated() {
            if e&63==0 { try checkpoint(control,started) }
            let temperatures=tet.nodes.map { nodalTemperatureKelvin[$0] },mean=temperatures.reduce(0.0) { $0+$1/4 },delta=mean-referenceTemperatureKelvin
            let thermalStrain=unitThermalStrain.map { $0*delta },total=solved.elements[e].strain,elasticStrain=zip(total,thermalStrain).map { $0-$1 },sigma=stress(elasticStrain,elastic)
            let b=IsotropicElasticity.strainDisplacementMatrix(mesh.geometry[e].gradients),volume=mesh.geometry[e].volume
            for local in 0..<12 { internalForce[tet.nodes[local/3]*3+local%3]+=(0..<6).reduce(0.0) { $0+b[$1*12+local]*sigma[$1] }*volume }
            let variance=temperatures.reduce(0.0) { $0+pow($1-mean,2)/20 }
            let stored=0.0005*volume*(dot(elasticStrain,sigma)+variance*dot(unitThermalStrain,unitThermalStress))
            guard sigma.allSatisfy(\.isFinite),thermalStrain.allSatisfy(\.isFinite),elasticStrain.allSatisfy(\.isFinite),stored.isFinite,stored>=0 else { throw EngineeringError.illConditioned("Thermoelastic stress, strain or stored energy is not finite and non-negative.") }
            energy+=stored
            let equivalent=vonMisesStressMPa(sigma)
            guard equivalent.isFinite else { throw EngineeringError.illConditioned("The equivalent thermoelastic stress overflowed.") }
            elements.append(.init(element:e,meanTemperatureKelvin:mean,totalStrain:total,meanThermalStrain:thermalStrain,meanElasticStrain:elasticStrain,meanStressMPa:sigma,vonMisesOfMeanStressMPa:equivalent))
        }
        // Independent recovered stress equilibrium, using physical mechanical
        // loads and support reactions, not the equivalent thermal load vector.
        var external=applied
        for r in solved.reactions { external[r.node*3+r.component]+=r.valueN }
        let residual=norm(zip(internalForce,external).map { $0-$1 }),scale=max(norm(internalForce),norm(external))
        let limit=max(mechanical.tolerance.absoluteResidualFloor,mechanical.tolerance.relativeResidual*scale)
        guard energy.isFinite,residual.isFinite,scale.isFinite,residual<=limit else { throw EngineeringError.illConditioned("Recovered thermoelastic stress failed physical force-equilibrium read-back.") }
        let hash=try EngineeringExport.canonicalHash(of:self);try checkpoint(control,started)
        return .init(nodalDisplacementMM:solved.nodalDisplacementMM,reactions:solved.reactions,elements:elements,elasticEnergyJ:energy,equilibriumResidualN:residual,relativeLinearResidual:solved.relativeResidual,iterations:solved.iterations,wallSeconds:Date().timeIntervalSince(started),sourceHash:hash)
    }
    private func appliedLoads(_ mesh:ValidatedTetraMesh,control:EngineeringSolveControl,started:Date) throws -> [Double] {
        var f=[Double](repeating:0,count:mesh.nodes.count*3)
        for load in mechanical.concentratedLoads {
            guard mesh.nodes.indices.contains(load.node),load.components.isFinite else { throw EngineeringError.invalidInput("Invalid thermoelastic mechanical nodal load.") }
            f[load.node*3]+=load.components.x;f[load.node*3+1]+=load.components.y;f[load.node*3+2]+=load.components.z
        }
        for body in mechanical.bodyLoads {
            guard body.componentsPerVolume.isFinite else { throw EngineeringError.invalidInput("Invalid thermoelastic body load.") }
            for (e,tet) in mesh.elements.enumerated() {
                if e&63==0 { try checkpoint(control,started) }
                let share=mesh.geometry[e].volume/4
                for node in tet.nodes { f[node*3]+=body.componentsPerVolume.x*share;f[node*3+1]+=body.componentsPerVolume.y*share;f[node*3+2]+=body.componentsPerVolume.z*share }
            }
        }
        for load in mechanical.pressureLoads {
            guard mesh.elements.indices.contains(load.element),(0..<4).contains(load.face),load.pressureMPa.isFinite else { throw EngineeringError.invalidInput("Invalid thermoelastic pressure load.") }
            let tet=mesh.elements[load.element],geometry=mesh.geometry[load.element],force=geometry.outwardNormal[load.face]*(load.pressureMPa*geometry.faceArea[load.face]/3)
            for node in tet.nodes where node != tet.nodes[load.face] { f[node*3]+=force.x;f[node*3+1]+=force.y;f[node*3+2]+=force.z }
        }
        guard f.allSatisfy(\.isFinite) else { throw EngineeringError.illConditioned("Mechanical load accumulation overflowed.") };return f
    }
    private func stress(_ strain:[Double],_ elastic:IsotropicElasticity) -> [Double] { (0..<6).map { r in (0..<6).reduce(0.0) { $0+elastic.constitutiveD[r*6+$1]*strain[$1] } } }
    private func dot(_ a:[Double],_ b:[Double]) -> Double { zip(a,b).reduce(0.0) { $0+$1.0*$1.1 } }
    private func norm(_ a:[Double]) -> Double { a.reduce(0.0) { hypot($0,$1) } }
    private func checkpoint(_ control:EngineeringSolveControl,_ started:Date) throws {
        try control.checkCancelled();guard Date().timeIntervalSince(started)<=mechanical.budget.maxWallSeconds else { throw EngineeringError.budgetExceeded("Thermoelastic solve exceeded its wall-time budget.") }
    }
}

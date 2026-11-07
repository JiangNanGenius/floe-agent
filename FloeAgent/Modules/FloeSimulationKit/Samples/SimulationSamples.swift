import Foundation
import CryptoKit
import FloeSimulationCore
import FloeSimulationRuntime
import FloeSimulationGeometry
import FloeSimulationEngineering
import FloeSimulationPhysics

/// Explicit qualification fixtures; never substitute these inputs for user CAD.
public enum SimulationSamples {
    public static func workspace() throws -> SimulationWorkspaceDocument {
        let digest = SHA256.hash(data:Data("simulation-fixture1/box/0.1,0.02,0.02/6,2,2".utf8)).map { String(format:"%02x",$0) }.joined()
        let source = SimulationSourceRef(projectID:UUID(uuidString:"30C9D802-DCAB-4C62-ACB5-7EF330CDE110")!,documentID:UUID(uuidString:"87B4DDE5-5C46-48CA-A8BA-7925B72A2A88")!,revision:1,contentSHA256:digest)
        let mesh = try SimulationBoxMesher.generate(source:source,maximum:.init(0.1,0.02,0.02),divisions:[6,2,2])
        let material = SimulationMaterial(name:"Steel / 钢",properties:["youngModulusPa":210e9,"poissonRatio":0.3,"densityKgPerCubicMeter":7800,"thermalConductivityWPerMeterK":45,"specificHeatJPerKgK":500,"thermalExpansionPerKelvin":12e-6],provenance:"Editable qualification fixture")
        var staticConfiguration = EngineeringSimulationConfiguration()
        staticConfiguration.constraints = [.init(selection:.boundary("xmin"))]
        staticConfiguration.forces = [.init(selection:.boundary("xmax"),value:.init(0,-100,0))]
        var structural = SimulationStudy(name:"Cantilever / 悬臂",kind:.structuralStatic,materialAssignments:["body":material.id]); structural.meshID = mesh.id; try structural.setConfiguration(staticConfiguration)
        var thermalConfiguration = EngineeringSimulationConfiguration()
        thermalConfiguration.fixedTemperatures = [.init(selection:.boundary("xmin"),value:293.15),.init(selection:.boundary("xmax"),value:373.15)]
        var thermal = SimulationStudy(name:"Heat / 导热",kind:.thermalSteady,materialAssignments:["body":material.id]); thermal.meshID = mesh.id; try thermal.setConfiguration(thermalConfiguration)
        var scene = PhysicsSimulationConfiguration()
        var floor = SimulationPhysicsBody(sourceObjectID:"floor"); floor.motion = .fixed; floor.translation = .init(0,-0.1,0); floor.collider.halfExtents = .init(3,0.1,3)
        var box = SimulationPhysicsBody(sourceObjectID:"box"); box.translation = .init(0,1,0); box.collider.halfExtents = .init(0.15,0.15,0.15)
        var cloth = SimulationPhysicsSoftBody(sourceObjectID:"cloth",kind:.cloth); cloth.dimensions = [8,8,2]; cloth.pinnedIndices = [0,7]; cloth.origin = .init(0.6,1,0)
        scene.bodies = [floor,box]; scene.softBodies = [cloth]; scene.time.durationSeconds = 2
        var physics = SimulationStudy(name:"Motion / 运动",kind:.rigidBody); try physics.setConfiguration(scene)
        var particles = ParticleSimulationConfiguration(); particles.emitters = [.init()]; particles.collisionBodies = [floor]
        var particle = SimulationStudy(name:"Particles / 粒子",kind:.particles); try particle.setConfiguration(particles)
        return .init(source:source,materials:[material],studies:[structural,thermal,physics,particle],meshes:[mesh])
    }
}

import Foundation
import Testing
import FloeSimulationCore
import FloeSimulationGeometry
import FloeSimulationFields

private func fieldSource() -> SimulationSourceRef { .init(projectID:UUID(),documentID:UUID(),revision:1,contentSHA256:String(repeating:"7",count:64)) }

@Test func mfem02LayeredDielectricsReturnPotentialFluxAndActualEnergy() async throws {
    let source = fieldSource()
    var mesh = try SimulationBoxMesher.generate(source:source,maximum:.init(0.1,0.02,0.03),divisions:[4,2,2])
    for index in mesh.elements.indices {
        let center = mesh.elements[index].nodes.reduce(0.0) { $0+mesh.nodes[$1].x }/4
        mesh.elements[index].regionID = center < 0.05 ? "left" : "right"
    }
    let left = SimulationMaterial(name:"Dielectric 2",properties:["relativePermittivity":2]), right = SimulationMaterial(name:"Dielectric 4",properties:["relativePermittivity":4])
    var configuration = ElectromagneticSimulationConfiguration(); configuration.finiteElementOrder = 2
    configuration.boundaries = [.init(boundaryID:"xmin",kind:.electricPotential),.init(boundaryID:"xmax",kind:.electricPotential,value:.init(real:10))]
    var study = SimulationStudy(name:"Series capacitor",kind:.electrostatic,materialAssignments:["left":left.id,"right":right.id]); study.meshID = mesh.id; try study.setConfiguration(configuration)
    let request = SimulationRequest(source:source,study:study,mesh:mesh,materials:[left,right])
    let result = try await MFEMSimulationDriver().solve(request) { _ in }
    try result.validate(for:request)
    let fields = result.frames[0].fields, potential = try #require(fields.first { $0.id == "potential" })
    for (index,node) in mesh.nodes.enumerated() {
        let expected = node.x <= 0.05 ? node.x*(10/0.075) : (0.05*10/0.075)+(node.x-0.05)*(5/0.075)
        #expect(abs(potential.values[index]-expected) < 2e-6)
    }
    let epsilon0 = 8.8541878128e-12, area = 0.02*0.03
    let expectedCapacitance = epsilon0*area/(0.05/2+0.05/4)
    let energy = try #require(fields.first { $0.id == "electric_energy" }?.values.first)
    #expect(abs(energy/(0.5*expectedCapacitance*100)-1) < 1e-7)
    let capacitance = try #require(fields.first { $0.id == "effective_capacitance" }?.values.first)
    #expect(abs(capacitance/expectedCapacitance-1) < 1e-7)
    let displacement = try #require(fields.first { $0.id == "electric_flux" })
    let expectedFlux = -epsilon0*2*10/0.075
    for index in mesh.elements.indices { #expect(abs(displacement.values[index*3]/expectedFlux-1) < 1e-5) }
}

@Test func mfem02AcousticRadiationGivesTravelingComplexPressureAndSPL() async throws {
    let source = fieldSource(), mesh = try SimulationBoxMesher.generate(source:source,maximum:.init(0.2,0.02,0.02),divisions:[20,1,1])
    var configuration = AcousticSimulationConfiguration(); configuration.finiteElementOrder = 2; configuration.frequencies = .init(frequenciesHz:[343])
    configuration.boundaries = [.init(boundaryID:"xmin",kind:.pressure,value:.init(real:1)),.init(boundaryID:"xmax",kind:.radiation)]
    var study = SimulationStudy(name:"Matched acoustic duct",kind:.pressureAcoustics); study.meshID = mesh.id; try study.setConfiguration(configuration)
    let request = SimulationRequest(source:source,study:study,mesh:mesh)
    let result = try await MFEMSimulationDriver().solve(request) { _ in }
    try result.validate(for:request)
    let pressure = try #require(result.frames.first?.fields.first { $0.id == "pressure" }), imaginary = try #require(pressure.imaginaryValues)
    for (index,node) in mesh.nodes.enumerated() {
        #expect(abs(pressure.values[index]-cos(2*Double.pi*node.x)) < 0.002)
        #expect(abs(imaginary[index]+sin(2*Double.pi*node.x)) < 0.002)
    }
    let spl = try #require(result.frames.first?.fields.first { $0.id == "sound_pressure_level" })
    #expect(abs(spl.values[0]-20*log10(1/(sqrt(2)*configuration.referencePressurePascal))) < 1e-8)
    let velocity = try #require(result.frames.first?.fields.first { $0.id == "particle_velocity" })
    let admittance = 1/(configuration.densityKgPerCubicMeter*configuration.soundSpeedMetersPerSecond)
    for (index,element) in mesh.elements.enumerated() {
        let x = element.nodes.reduce(0.0) { $0+mesh.nodes[$1].x }/4
        #expect(abs(velocity.values[index*3]/admittance-cos(2*Double.pi*x)) < 0.003)
        #expect(abs(velocity.values[index*3+1]/admittance) < 0.003)
        #expect(abs(velocity.values[index*3+2]/admittance) < 0.003)
    }
}

@Test func mfem02FloatingDisconnectedDomainFailsInsteadOfReturningZero() async throws {
    let source = fieldSource(), first = try SimulationBoxMesher.generate(source:source,maximum:.init(0.1,0.1,0.1))
    let second = try SimulationBoxMesher.generate(source:source,minimum:.init(0.2,0,0),maximum:.init(0.3,0.1,0.1))
    let offset = first.nodes.count
    let mesh = SimulationMesh(source:source,nodes:first.nodes+second.nodes,elements:first.elements+second.elements.map { .init(kind:$0.kind,nodes:$0.nodes.map { $0+offset },regionID:$0.regionID) },boundaries:first.boundaries)
    var configuration = ElectromagneticSimulationConfiguration(); configuration.boundaries = [.init(boundaryID:"xmin",kind:.electricPotential)]
    let material = SimulationMaterial(name:"Air",properties:["relativePermittivity":1])
    var study = SimulationStudy(name:"Floating",kind:.electrostatic,materialAssignments:["body":material.id]); study.meshID = mesh.id; try study.setConfiguration(configuration)
    await #expect(throws:SimulationError.self) { try await MFEMSimulationDriver().solve(.init(source:source,study:study,mesh:mesh,materials:[material])) { _ in } }
}

@Test func mfem02NaturalConditionsRejectUnusedNonzeroAmplitudes() throws {
    let source = fieldSource(), mesh = try SimulationBoxMesher.generate(source:source,maximum:.init(0.1,0.1,0.1))
    let material = SimulationMaterial(name:"Air",properties:["relativePermittivity":1])
    var electromagnetic = ElectromagneticSimulationConfiguration()
    electromagnetic.boundaries = [.init(boundaryID:"xmin",kind:.perfectElectric,value:.init(real:1))]
    var electrostatic = SimulationStudy(name:"Invalid ground",kind:.electrostatic,materialAssignments:["body":material.id]);electrostatic.meshID = mesh.id;try electrostatic.setConfiguration(electromagnetic)
    #expect(throws:SimulationError.self) { try MFEMSimulationDriver().validate(.init(source:source,study:electrostatic,mesh:mesh,materials:[material])) }
    var acoustic = AcousticSimulationConfiguration()
    acoustic.boundaries = [.init(boundaryID:"xmin",kind:.pressure,value:.init(real:1)),.init(boundaryID:"xmax",kind:.rigidWall,value:.init(real:1))]
    var sound = SimulationStudy(name:"Invalid rigid wall",kind:.pressureAcoustics);sound.meshID = mesh.id;try sound.setConfiguration(acoustic)
    #expect(throws:SimulationError.self) { try MFEMSimulationDriver().validate(.init(source:source,study:sound,mesh:mesh)) }
}

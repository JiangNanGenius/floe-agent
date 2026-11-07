import Foundation
import Testing
@testable import FloeSimulationCore

@Test func sourceAndMeshFence() throws {
    let source = SimulationSourceRef(projectID: UUID(), documentID: UUID(), revision: 1, contentSHA256: String(repeating: "a", count: 64))
    var mesh = SimulationMesh(source: source, nodes: [.zero, .init(1,0,0), .init(0,1,0), .init(0,0,1)], elements: [.init(kind: .tetrahedron4, nodes: [0,1,2,3], regionID: "solid")])
    try mesh.validate()
    mesh.elements[0].nodes = [0,2,1,3]
    #expect(throws: SimulationError.self) { try mesh.validate() }
}

@Test func materialAndSourceReferencesCannotDrift() throws {
    let source = SimulationSourceRef(projectID: UUID(), documentID: UUID(), revision: 1, contentSHA256: String(repeating: "0", count: 64))
    let study = SimulationStudy(name: "Static", kind: .structuralStatic, materialAssignments: ["body":UUID()])
    let request = SimulationRequest(source: source, study: study)
    #expect(throws: SimulationError.self) { try request.validate() }
}

@Test func complexResultsShareTheBudget() throws {
    let source = SimulationSourceRef(projectID: UUID(), documentID: UUID(), revision: 1, contentSHA256: String(repeating: "1", count: 64))
    let request = SimulationRequest(source: source, study: .init(name: "RF", kind: .radioFrequency), budget: .init(maximumResultValues: 3))
    let field = SimulationResultField(id: "s11", name: "S11", unit: "1", location: .global, components: 1, values: [1,2], imaginaryValues: [0,0])
    let result = SimulationResult(requestID: request.id, source: source, studyID: request.study.id, backend: .init(id: "test", version: "1", supportedStudies: [.radioFrequency], isAvailable: true), frames: [.init(id: 0, fields: [field])])
    #expect(throws: SimulationError.self) { try result.validate(for: request) }
}

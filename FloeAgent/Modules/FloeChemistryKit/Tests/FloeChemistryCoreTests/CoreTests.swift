import Foundation
import Testing
@testable import FloeChemistryCore

@Test func balancingAndFormula() throws {
    #expect(try ReactionBalancer.balance(reactants: ["C2H6", "O2"], products: ["CO2", "H2O"]) == [2,7,4,6])
    #expect(try ReactionBalancer.balance(reactants: ["MnO4^-", "Fe^2+", "H^+"], products: ["Mn^2+", "Fe^3+", "H2O"]) == [1,5,8,1,5,4])
    #expect(try ChemicalFormula("CuSO4·5H2O").elements == ["Cu":1,"S":1,"O":9,"H":10])
    #expect(throws: (any Error).self) { try ChemicalFormula("(H2O") }
    #expect(throws: (any Error).self) { try ChemicalFormula("Xx3") }
    #expect(throws: (any Error).self) { try ReactionBalancer.balance(reactants: ["H2"], products: ["O2"]) }
    #expect(throws: (any Error).self) { try ReactionBalancer.balance(reactants: ["C", "O2"], products: ["CO", "CO2"]) }
}
@Test func spectrumAnalysis() throws {
    let s = try SpectrumAnalysis.csv("x,y\n0,0\n1,2\n2,0")
    #expect(s.area == 2); #expect(s.peaks == [SpectrumPoint(x: 1, y: 2)])
    #expect(throws: (any Error).self) { try SpectrumAnalysis.csv("0,0\n0,2") }
    #expect(throws: (any Error).self) { try SpectrumAnalysis.csv("0,0\n1,nan") }
}
@Test func persistenceConflictRecoveryAndCorruption() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try ChemistryProjectStore(root: root), b = try ChemistryProjectStore(root: root)
    var p = ChemistryProject(title: "Chemistry")
    p.objects = [ChemicalObject(title: "Water", format: "xyz", source: "3\nwater\nO 0 0 0\nH 0.95 0 0\nH -0.24 0.92 0")]
    p = try await a.save(p, expectedRevision: 0)
    #expect(try await b.load(p.id) == p)
    let original = p; p.title = "Updated"
    p = try await b.save(p, expectedRevision: 1)
    await #expect(throws: ChemistryError.conflict(expected: 1, actual: 2)) { try await a.save(original, expectedRevision: 1) }
    let history = try await a.history(p.id)
    let restored = try await a.restore(history.last!, expectedRevision: p.revision)
    #expect(restored.title == "Chemistry"); #expect(restored.revision == 3)
    let head = root.appendingPathComponent(p.id.uuidString).appendingPathComponent("HEAD.json")
    try Data("broken".utf8).write(to: head)
    await #expect(throws: (any Error).self) { try await b.load(p.id) }
    #expect(try String(contentsOf: head, encoding: .utf8) == "broken")
}
@Test func documentReferencesValidated() throws {
    var p = ChemistryProject(title: "References")
    p.blocks = [ChemistryBlock(objectID: UUID())]
    #expect(throws: (any Error).self) { try p.validate() }
}

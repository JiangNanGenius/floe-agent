import Foundation
import Testing
import FloeSimulationCore
import FloeSimulationGeometry
import FloeSimulationRuntime
import FloeSimulationUI

@Test @MainActor func ai02DiscoveredTemplatesAndFaceMetadataDriveActualMFEMSolve() async throws {
    var root = URL(fileURLWithPath:#filePath); for _ in 0..<6 { root.deleteLastPathComponent() }
    let directory = root.appendingPathComponent("Local/Scratch/simulation-tests/"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let source = SimulationSourceRef(projectID:UUID(),documentID:UUID(),revision:1,contentSHA256:String(repeating:"a",count:64))
    let mesh = try SimulationBoxMesher.generate(source:source,maximum:.init(0.1,0.02,0.02),divisions:[2,1,1])
    let model = try SimulationWorkbenchFactory.make(document:.init(source:source,meshes:[mesh]),directory:directory)
    let tools = SimulationWorkbenchFactory.tools(for:model) { _,_,_ in }
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    var context = SimulationToolContext(taskID:UUID(),source:source,expectedGeneration:0)
    let templatesData = try await tools.invoke(name:"simulation.templates",arguments:Data("{}".utf8),context:context)
    let templates = try decoder.decode([SimulationToolStudyTemplate].self,from:templatesData)
    let template = try #require(templates.first { $0.kind == .electrostatic })
    #expect(!templates.contains { [.radioFrequency,.nonlinearContact,.incompressibleFlow].contains($0.kind) })
    #expect(template.materialPropertyUnits["relativePermittivity"] == "1")
    let metadata = try await tools.meshInfo(meshID:mesh.id,context:context)
    #expect(metadata.regions.map(\.id) == ["body"])
    #expect(metadata.boundaries.first { $0.id == "xmin" }?.maximumMeters.x == 0)
    #expect(metadata.boundaries.first { $0.id == "xmax" }?.sourceEntityID == "box/xmax")
    let material = try decoder.decode(SimulationMaterial.self,from:encoder.encode(try #require(template.prototypes["material"])))
    struct PutMaterial: Encodable { var material: SimulationMaterial;var expectedGeneration: UInt64 }
    let savedMaterial = try await tools.invoke(name:"simulation.material.put",arguments:encoder.encode(PutMaterial(material:material,expectedGeneration:0)),context:context)
    context.expectedGeneration = try decoder.decode(SimulationToolCommitReceipt.self,from:savedMaterial).generation
    // A freshly rebound host context must not make an AI edit based on an old
    // read overwrite the newer workspace.
    await #expect(throws:SimulationError.self) { try await tools.invoke(name:"simulation.material.put",arguments:encoder.encode(PutMaterial(material:material,expectedGeneration:0)),context:context) }
    guard case .object(var configuration) = template.configuration, case .object(let boundary) = template.prototypes["boundary"] else { Issue.record("The discovered template must contain editable objects"); return }
    var left = boundary,right = boundary
    left["boundaryID"] = .string("xmin");right["boundaryID"] = .string("xmax")
    right["value"] = .object(["real":.number(10),"imaginary":.number(0)])
    configuration["boundaries"] = .array([.object(left),.object(right)])
    let input = SimulationToolStudyInput(name:"From discovered template",kind:.electrostatic,meshID:mesh.id,materialAssignments:["body":material.id],configuration:.object(configuration))
    struct PutStudy: Encodable { var study: SimulationToolStudyInput;var expectedGeneration: UInt64 }
    let savedStudy = try await tools.invoke(name:"simulation.study.put",arguments:encoder.encode(PutStudy(study:input,expectedGeneration:context.expectedGeneration)),context:context)
    context.expectedGeneration = try decoder.decode(SimulationToolCommitReceipt.self,from:savedStudy).generation
    struct Run: Encodable { var studyID: UUID;var expectedStudyRevision: UInt64;var expectedGeneration: UInt64 }
    let started = try await tools.invoke(name:"simulation.run",arguments:encoder.encode(Run(studyID:input.id,expectedStudyRevision:0,expectedGeneration:context.expectedGeneration)),context:context)
    let jobID = try #require(decoder.decode([String:UUID].self,from:started)["jobID"])
    var job: SimulationJobSnapshot?
    for _ in 0..<200 {
        job = try await tools.jobs(context).first { $0.id == jobID && $0.status.isTerminal }
        if job != nil { break };try await Task.sleep(for:.milliseconds(10))
    }
    #expect(job?.status == .completed)
    let resultID = try #require(job?.resultID)
    let field = try await tools.field(resultID:resultID,frameID:0,fieldID:"potential",context:context)
    for (index,node) in mesh.nodes.enumerated() { #expect(abs(field.values[index]-100*node.x) < 1e-6) }
    let csv = try await tools.export(resultID:resultID,context:context)
    #expect(try String(contentsOf:csv,encoding:.utf8).contains("effective_capacitance"))
    await model.close()
}

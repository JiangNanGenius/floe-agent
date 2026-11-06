// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
import FloeEngineeringCore

public struct EngineeringAnalysisProject:Codable,Sendable,Identifiable {
    public enum Analysis:Codable,Sendable { case structural(StructuralRequest),thermal(ThermalRequest) }
    public var formatVersion = 1
    public var id = UUID()
    public var name:String
    public var source:ManufacturingStudy.Source
    public var analysis:Analysis
    public init(name:String,source:ManufacturingStudy.Source,analysis:Analysis) { self.name = name;self.source = source;self.analysis = analysis }
    public func validate() throws {
        guard formatVersion == 1,!name.isEmpty,name.utf8.count <= 512,!source.documentID.isEmpty,source.revision >= 0,
              source.contentSHA256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else { throw ManufacturingError.invalid("engineering project identity/version") }
        switch analysis {
        case .structural(let input):
            try input.budget.validate();try input.tolerance.validate();try input.material.validateForStructural()
            _ = try ValidatedTetraMesh(nodes:input.meshNodes,elements:input.meshElements,budget:input.budget)
            guard input.displacementBCs.allSatisfy({ input.meshNodes.indices.contains($0.node) && $0.constrained.count == 3 && $0.prescribedMM.count == 3 && $0.prescribedMM.allSatisfy(\.isFinite) }),
                  input.concentratedLoads.allSatisfy({ input.meshNodes.indices.contains($0.node) && $0.components.isFinite }),
                  input.bodyLoads.allSatisfy({ $0.componentsPerVolume.isFinite }),
                  input.pressureLoads.allSatisfy({ input.meshElements.indices.contains($0.element) && (0..<4).contains($0.face) && $0.pressureMPa.isFinite }) else { throw ManufacturingError.invalid("engineering load/constraint shape or index") }
        case .thermal(let input):
            try input.budget.validate();try input.tolerance.validate();try input.material.validateForThermal()
            _ = try ValidatedTetraMesh(nodes:input.meshNodes,elements:input.meshElements,budget:input.budget)
            guard input.fixedTemperatures.allSatisfy({ input.meshNodes.indices.contains($0.node) && $0.temperatureCelsius.isFinite }),
                  input.sources.allSatisfy({ input.meshElements.indices.contains($0.element) && $0.powerPerVolume.isFinite }),
                  input.faceFluxes.allSatisfy({ input.meshElements.indices.contains($0.element) && (0..<4).contains($0.face) && $0.fluxWPerMM2.isFinite }) else { throw ManufacturingError.invalid("thermal load/boundary shape or index") }
        }
    }
    /// A small explicit volume mesh. This does not imply a surface-to-volume mesher.
    public static func demonstration(thermal:Bool = false) -> Self {
        let nodes = [MeshNode(.init(0,0,0)),MeshNode(.init(10,0,0)),MeshNode(.init(2,10,0)),MeshNode(.init(1,2,10))]
        let elements = [Tetrahedron(0,1,2,3)]
        let source = ManufacturingStudy.Source(documentID:"fixture:skew-tetrahedron-10mm",revision:1,
            contentSHA256:ManufacturingStudy.digest(Data("tetra-0-1000-2100-1210".utf8)))
        let budget = EngineeringBudget(maxNodes:1024,maxElements:4096,maxNonzeros:1_000_000,maxIterations:2000,maxWallSeconds:30,maxEstimatedBytes:128_000_000)
        if thermal {
            let request = ThermalRequest(meshNodes:nodes,meshElements:elements,material:MaterialLibrary.aluminum6061T6,
                fixedTemperatures:[.init(node:0,temperatureCelsius:20),.init(node:1,temperatureCelsius:80)],budget:budget)
            return .init(name:"稳态导热 / Steady conduction",source:source,analysis:.thermal(request))
        }
        let request = StructuralRequest(meshNodes:nodes,meshElements:elements,material:MaterialLibrary.aluminum6061T6,
            concentratedLoads:[.init(node:3,components:.init(0,0,-100))],
            displacementBCs:[0,1,2].map { .init(node:$0,constrained:[true,true,true],prescribedMM:[0,0,0]) },budget:budget)
        return .init(name:"线弹性静力 / Linear static",source:source,analysis:.structural(request))
    }
}

public struct EngineeringAnalysisArtifact:Codable,Sendable {
    public enum Result:Codable,Sendable { case structural(StructuralResult),thermal(ThermalResult) }
    public var formatVersion = 1
    public var projectID:UUID
    public var inputSHA256:String
    public var result:Result
    public var unsupportedDomains:[String]
    public var capabilities:[String]
    public var sources:[String]
    public var elapsedSeconds:Double
    public var processPeakBytes:UInt64
    public func validate(for project:EngineeringAnalysisProject) throws {
        try project.validate()
        guard formatVersion == 1,projectID == project.id,inputSHA256 == (try ResearchArchive.digest(project)),
              elapsedSeconds.isFinite && elapsedSeconds >= 0,
              unsupportedDomains == EngineeringUnsupported.ledger.map(\.rawValue) else { throw ManufacturingError.stale }
        switch (project.analysis,result) {
        case (.structural(let input),.structural(let output)):
            guard output.sourceHash == (try EngineeringExport.canonicalHash(of:input)),
                  capabilities == ["tet4-isotropic-small-strain-linear-static","displacement-reaction-strain-stress-von-mises"],
                  sources == [SolverProvenance.summary,input.material.provenance],
                  output.nodalDisplacementMM.count == input.meshNodes.count,output.elements.count == input.meshElements.count,
                  output.nodalDisplacementMM.allSatisfy(\.isFinite),output.relativeResidual.isFinite && output.relativeResidual >= 0,
                  output.elements.allSatisfy({ $0.strain.count == 6 && $0.stressMPa.count == 6 &&
                    ($0.strain+$0.stressMPa+[$0.vonMisesMPa]).allSatisfy(\.isFinite) && $0.vonMisesMPa >= 0 }) else { throw ManufacturingError.archive("structural source/result contract") }
        case (.thermal(let input),.thermal(let output)):
            guard output.sourceHash == (try EngineeringExport.canonicalHash(of:input)),
                  capabilities == ["tet4-isotropic-steady-conduction","temperature-boundary-flux-energy-balance"],
                  sources == [SolverProvenance.summary,input.material.provenance],
                  output.nodalTemperatureCelsius.count == input.meshNodes.count,output.nodalTemperatureCelsius.allSatisfy(\.isFinite),
                  output.energyBalanceResidualW.isFinite,output.relativeResidual.isFinite && output.relativeResidual >= 0 else { throw ManufacturingError.archive("thermal source/result contract") }
        default:throw ManufacturingError.archive("engineering analysis/result type mismatch")
        }
    }
}

public struct EngineeringAnalysisEngine:Sendable {
    public init() {}
    public func compute(_ project:EngineeringAnalysisProject,control:ComputationControl = .init()) throws -> EngineeringAnalysisArtifact {
        try control.check();try project.validate();try control.check()
        let start = Date(),solveControl = EngineeringSolveControl(isCancelled:{ control.isCancelled })
        let result:EngineeringAnalysisArtifact.Result
        switch project.analysis {
        case .structural(let input):result = .structural(try input.solve(control:solveControl))
        case .thermal(let input):result = .thermal(try input.solve(control:solveControl))
        }
        try control.check()
        var usage = rusage();getrusage(RUSAGE_SELF,&usage)
        let capabilities:[String],provenance:String
        switch project.analysis {
        case .structural(let input):capabilities = ["tet4-isotropic-small-strain-linear-static","displacement-reaction-strain-stress-von-mises"];provenance = input.material.provenance
        case .thermal(let input):capabilities = ["tet4-isotropic-steady-conduction","temperature-boundary-flux-energy-balance"];provenance = input.material.provenance
        }
        let artifact = EngineeringAnalysisArtifact(projectID:project.id,inputSHA256:try ResearchArchive.digest(project),result:result,
            unsupportedDomains:EngineeringUnsupported.ledger.map(\.rawValue),capabilities:capabilities,
            sources:[SolverProvenance.summary,provenance],elapsedSeconds:Date().timeIntervalSince(start),processPeakBytes:UInt64(max(0,usage.ru_maxrss)))
        try artifact.validate(for:project)
        guard try ManufacturingStudy.encoder.encode(artifact).count <= ResearchArchive.byteLimit else { throw ManufacturingError.native("engineering result byte budget") }
        return artifact
    }
}

public actor EngineeringAnalysisService {
    private var controls:[UUID:ComputationControl] = [:]
    public init() {}
    public func calculate(_ project:EngineeringAnalysisProject) async throws -> EngineeringAnalysisArtifact {
        let id = UUID(),control = ComputationControl();controls[id] = control
        defer { controls.removeValue(forKey:id) }
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority:.userInitiated) { try EngineeringAnalysisEngine().compute(project,control:control) }.value
            try control.check();try Task.checkCancellation();return result
        } onCancel:{ control.cancel() }
    }
}

public enum EngineeringAnalysisArchive {
    public static func save(project:EngineeringAnalysisProject,artifact:EngineeringAnalysisArtifact,to url:URL) throws {
        try ResearchArchive.save(input:project,output:artifact,family:.engineeringAnalysis,to:url) { try $1.validate(for:$0) }
    }
    public static func open(_ url:URL) throws -> (EngineeringAnalysisProject,EngineeringAnalysisArtifact) {
        try ResearchArchive.open(url,input:EngineeringAnalysisProject.self,output:EngineeringAnalysisArtifact.self,family:.engineeringAnalysis) { try $1.validate(for:$0) }
    }
}

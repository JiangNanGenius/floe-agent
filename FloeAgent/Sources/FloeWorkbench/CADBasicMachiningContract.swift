// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools

/// CAD domain adapter only. Execution remains jobs.submit -> exec.shell.
public protocol CadBasicMachiningHosting: Sendable {
    func basicMachining(documentID: String, request: CadBasicMachiningRequest,
                        context: ToolContext) async throws -> CadBasicMachiningReply
}

public struct CadBasicMachiningParameters: Codable, Sendable, Equatable {
    public var preview: CadMultiAxisPreviewParameters?
    public var resolutionMM: Double
    public var radiusMM: Double
    public var lengthMM: Double
    public var startTipMM: [Double]
    public var endTipMM: [Double]
    public init(resolutionMM: Double = 1, radiusMM: Double = 2, lengthMM: Double = 6,
                startTipMM: [Double], endTipMM: [Double], preview: CadMultiAxisPreviewParameters? = nil) {
        self.preview=preview
        self.resolutionMM=resolutionMM; self.radiusMM=radiusMM; self.lengthMM=lengthMM
        self.startTipMM=startTipMM; self.endTipMM=endTipMM
    }
    public func validate() throws {
        if let preview {try preview.validate(radius:radiusMM,length:lengthMM,resolution:resolutionMM);return}
        guard [0.25,0.5,1,2].contains(resolutionMM), radiusMM.isFinite,
              lengthMM.isFinite, (0.1...100).contains(radiusMM), (0.1...100).contains(lengthMM),
              startTipMM.count==3, endTipMM.count==3,
              (startTipMM+endTipMM).allSatisfy({ $0.isFinite && abs($0)<=10_000 }),
              startTipMM[2]==endTipMM[2],
              hypot(endTipMM[0]-startTipMM[0],endTipMM[1]-startTipMM[1])<=100 else {
            throw FloeError.validationFailed("Basic machining supports one fixed-Z straight flat-end-mill cut, bounded tools, and 0.25/0.5/1/2 mm voxels.")
        }
    }
}

public struct CadBasicMachiningRequest: Sendable {
    public enum Action: String, Sendable { case availability, prepare, collect, status, cancel }
    public enum Phase: String, Codable, Sendable { case environment, simulation }
    public var action: Action
    public var bodyID: UUID?
    public var operationID: UUID?
    public var jobID: UUID?
    public var phase: Phase?
    public var parameters: CadBasicMachiningParameters?
    public static func decode(_ text: String?) throws -> Self {
        guard let text, let d=text.data(using:.utf8), d.count<=16_384,
              let o=try JSONSerialization.jsonObject(with:d) as? [String:Any],
              Set(o.keys).isSubset(of:["action","body_id","operation_id","job_id","phase","parameters"]),
              let raw=o["action"] as? String, let action=Action(rawValue:raw) else {
            throw FloeError.validationFailed("machining payload.action must be availability|prepare|collect|status|cancel. No commands or target overrides are accepted.")
        }
        func id(_ key:String) throws -> UUID? {
            guard let value=o[key] else { return nil }
            guard let raw=value as? String, let id=UUID(uuidString:raw) else { throw FloeError.validationFailed("Invalid \(key)") }; return id
        }
        let parameters: CadBasicMachiningParameters?
        if let value=o["parameters"] {
            guard let fields=value as? [String:Any] else {throw FloeError.validationFailed("parameters must be an object")}
            if fields["mode"] as? String=="multi-axis-preview" {parameters=try CadMultiAxisPreviewParameters.decode(fields)}
            else {
            guard Set(fields.keys)==["resolutionMM","radiusMM","lengthMM","startTipMM","endTipMM"] else {
                throw FloeError.validationFailed("Only voxel size, flat tool radius/length and two fixed-Z tips are supported. Rotation, axes, holder and machine simulation are unavailable.")
            }
            parameters=try JSONDecoder().decode(CadBasicMachiningParameters.self,from:JSONSerialization.data(withJSONObject:fields))
            }
        }
        else { parameters=nil }
        let phase=(o["phase"] as? String).flatMap(Phase.init(rawValue:))
        if o["phase"] != nil && phase == nil { throw FloeError.validationFailed("phase must be environment|simulation") }
        let request=Self(action:action,bodyID:try id("body_id"),operationID:try id("operation_id"),jobID:try id("job_id"),phase:phase,parameters:parameters)
        if action == .prepare { guard request.bodyID != nil, let parameters else { throw FloeError.validationFailed("prepare requires body_id and parameters") };try parameters.validate() }
        if action == .collect { guard request.operationID != nil,request.jobID != nil,phase != nil else { throw FloeError.validationFailed("collect requires operation_id, phase and real jobs.submit job_id") } }
        if action == .status || action == .cancel { guard request.operationID != nil else { throw FloeError.validationFailed("operation_id is required") } }
        return request
    }
}

public struct CadBasicMachiningArtifact: Codable, Sendable {
    public var workspacePath: String
    public var artifactPath: String
    public var sha256: String
    public var byteCount: Int
    public var manifestSHA256: String
    public init(workspacePath:String,artifactPath:String,sha256:String,byteCount:Int,manifestSHA256:String) {
        self.workspacePath=workspacePath;self.artifactPath=artifactPath;self.sha256=sha256
        self.byteCount=byteCount;self.manifestSHA256=manifestSHA256
    }
}
public struct CadBasicMachiningReply: Sendable {
    public var json: String
    public var artifact: CadBasicMachiningArtifact?
    public init(json:String,artifact:CadBasicMachiningArtifact?=nil) {self.json=json;self.artifact=artifact}
}

// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeExecution
import FloeModels
import FloePersistence
import FloeTools
import FloeWorkbench

struct CADBasicMachiningSource: Codable, Sendable, Equatable {
    var documentURL: URL
    var bodyID: UUID
    var revision: Int
    var contentSHA256: String
    var modelSHA256: String
    var members: [String:String]
}
struct CADBasicMachiningStudy: Codable, Sendable, Identifiable {
    enum State: String, Codable, Sendable {
        case prepared, preparingEnvironment, environmentReady, simulating, ready, cancelling, cancelled, failed, interrupted, stale
    }
    var formatVersion = 1
    var id: UUID
    var conversationID: UUID
    var createdRunID: UUID
    var environmentID: String
    var workspaceRoot: URL
    var source: CADBasicMachiningSource
    var parameters: CadBasicMachiningParameters
    var relativeDirectory: String
    var inputSHA256: String
    var preparationPayload: Data
    var simulationPayload: Data
    var environmentVerified = false
    var cancelRequested = false
    var previewSummary: CADMultiAxisPreviewSummary?
    var removedMM3: Double?
    var remainingMM3: Double?
    var preparationJobID: UUID?
    var simulationJobID: UUID?
    var acceptedJobRunID: UUID?
    var state: State
    var error: String?
    var artifact: CadBasicMachiningArtifact?
    var createdAt: Date
    var updatedAt: Date
}

/// Domain metadata only; durable execution state remains BackgroundJobStore's.
/// Outside the mirrored workspace so progress writes cannot conflict with Bridge sync.
@MainActor
final class CADBasicMachiningStudyStore {
    let root: URL
    init(root: URL? = nil) throws {
        self.root = try root ?? FloeArtifactStore.root().appendingPathComponent("JobDownloads/BasicMachining",isDirectory:true)
        try FileManager.default.createDirectory(at:self.root,withIntermediateDirectories:true)
    }
    func directory(_ id:UUID)->URL { root.appendingPathComponent(id.uuidString,isDirectory:true) }
    func save(_ study:CADBasicMachiningStudy) throws {
        let dir=directory(study.id);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        try JSONEncoder().encode(study).write(to:dir.appendingPathComponent("study.json"),options:.atomic)
    }
    func load(_ id:UUID)throws->CADBasicMachiningStudy {
        let study=try JSONDecoder().decode(CADBasicMachiningStudy.self,from:Data(contentsOf:directory(id).appendingPathComponent("study.json")))
        guard (study.formatVersion==1 && study.parameters.preview==nil) || (study.formatVersion==2 && study.parameters.preview != nil) else{throw FloeError.validationFailed("A newer basic machining study is preserved; open it with a compatible version")}
        return study
    }
    func latest(documentURL:URL,conversationID:UUID,root:URL,preview:Bool=false)->CADBasicMachiningStudy? {
        let dirs=(try? FileManager.default.contentsOfDirectory(at:self.root,includingPropertiesForKeys:nil)) ?? []
        return dirs.compactMap { try? load(UUID(uuidString:$0.lastPathComponent) ?? UUID()) }
            .filter { $0.source.documentURL==documentURL && $0.conversationID==conversationID && $0.workspaceRoot==root && ($0.parameters.preview != nil)==preview }
            .max { $0.updatedAt<$1.updatedAt }
    }
}

@MainActor
enum CADBasicMachiningText {
    static func t(_ zh:String,_ en:String)->String {
        FloeL10n.isChinese ? zh : en
    }
    static var title:String { t("基础加工仿真","Basic Machining Simulation") }
}

/// Trusted native status event only. No provider turn or extra execution channel is created.
struct CADBasicMachiningNativeRunMetadata:Codable,Sendable {
    var activity="basicMachining"
    var version=1
    var source=NativeJobSubmissionSource.nativeService
    var runID:UUID
    var conversationID:UUID
    var operationID:UUID
    var environmentID:String
    var targetTool="exec.shell"
    func payloadJSON()throws->String {String(decoding:try JSONEncoder().encode(self),as:UTF8.self)}
    static func matches(_ event:RunEventRecord,runID:UUID,conversationID:UUID,targetTool:String="exec.shell")->Bool {
        guard event.kind == .status,event.runID==runID,targetTool=="exec.shell",let data=event.payloadJSON.data(using:.utf8),
              let value=try? JSONDecoder().decode(Self.self,from:data) else{return false}
        return value.activity=="basicMachining" && value.version==1 && value.source == .nativeService && value.targetTool==targetTool
            && value.runID==runID && value.conversationID==conversationID && !value.environmentID.isEmpty
    }
}

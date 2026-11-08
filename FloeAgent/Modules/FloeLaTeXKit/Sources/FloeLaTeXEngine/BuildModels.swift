// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeLaTeXCore

public struct LaTeXEngineCapability: Codable, Hashable, Sendable,Identifiable {
    public var engine: LaTeXEngine
    public var version: String
    public var bibliography: [String]
    public var isLocal: Bool
    public var environmentID:String?
    public var auxiliaryTools:[String:String]
    public var id:String {(environmentID ?? "native")+":"+engine.rawValue}
    public init(engine: LaTeXEngine, version: String, bibliography: [String], isLocal: Bool,environmentID:String?=nil,auxiliaryTools:[String:String]=[:]) {
        self.engine=engine; self.version=version; self.bibliography=bibliography; self.isLocal=isLocal;self.environmentID=environmentID;self.auxiliaryTools=auxiliaryTools
    }
}
public struct LaTeXBuildConfiguration: Codable, Hashable, Sendable {
    public var offline: Bool
    public var timeoutSeconds: Int
    public var bundlePath: URL?
    /// Includes repeated TeX passes and bibliography/index processing on a local runtime.
    public static let defaultTimeoutSeconds = 600
    public init(offline: Bool = false, timeoutSeconds: Int = LaTeXBuildConfiguration.defaultTimeoutSeconds, bundlePath: URL? = nil) {
        self.offline=offline; self.timeoutSeconds=min(600,max(1,timeoutSeconds)); self.bundlePath=bundlePath
    }
}
public struct LaTeXEngineRequest: Sendable {
    public var snapshot: LaTeXProjectSnapshot
    public var outputRoot: URL
    public var cacheRoot: URL
    public var configuration: LaTeXBuildConfiguration
    public var executionOwner:LaTeXExecutionOwner?
    public var buildDate:Date
    public init(snapshot: LaTeXProjectSnapshot, outputRoot: URL, cacheRoot: URL, configuration: LaTeXBuildConfiguration,executionOwner:LaTeXExecutionOwner?=nil,buildDate:Date=Date()) {
        self.snapshot=snapshot;self.outputRoot=outputRoot;self.cacheRoot=cacheRoot;self.configuration=configuration;self.executionOwner=executionOwner;self.buildDate=buildDate
    }
}
public struct LaTeXEngineOutput: Sendable {
    public var pdf: URL
    public var version: String
    public var bundleDigest: String?
    public var messages: [String]
    public init(pdf: URL, version: String, bundleDigest: String? = nil, messages: [String] = []) {
        self.pdf=pdf;self.version=version;self.bundleDigest=bundleDigest;self.messages=messages
    }
}
public protocol LaTeXEngineRunning: Sendable {
    func capabilities() async -> [LaTeXEngineCapability]
    func run(_ request: LaTeXEngineRequest, progress: @escaping @Sendable (String) -> Void) async throws -> LaTeXEngineOutput
}
public protocol LaTeXBuildLifetime:AnyObject,Sendable {}
public struct LaTeXExecutionOwner:Codable,Hashable,Sendable {
    public var taskID:UUID;public var runID:UUID;public var environmentID:String?
    public init(taskID:UUID,runID:UUID,environmentID:String?) {self.taskID=taskID;self.runID=runID;self.environmentID=environmentID}
}
public struct LaTeXEngineFailure: Error, LocalizedError, Sendable {
    public var message: String
    public var messages: [String]
    public var cancelled: Bool
    public var workerStopped:Bool
    public init(_ message: String, messages: [String] = [], cancelled: Bool = false,workerStopped:Bool=true) {self.message=message;self.messages=messages;self.cancelled=cancelled;self.workerStopped=workerStopped}
    public var errorDescription: String? { message }
}
public struct LaTeXDiagnostic: Codable, Hashable, Sendable, Identifiable {
    public enum Severity: String, Codable, Sendable { case error, warning, information }
    public var id: UUID
    public var severity: Severity
    public var message: String
    public var path: String?
    public var line: Int?
    public init(severity: Severity, message: String, path: String? = nil, line: Int? = nil) {
        id=UUID();self.severity=severity;self.message=message;self.path=path;self.line=line
    }
}
public struct LaTeXBuildRecord: Codable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case queued, preparing, compiling, succeeded, failed, cancelled, interrupted }
    public var id: UUID
    public var projectID: UUID
    public var revision: Int64
    public var fingerprint: String
    public var snapshotID: UUID
    public var executionOwner:LaTeXExecutionOwner?
    public var workerStopped:Bool?
    public var state: State
    public var engine: LaTeXEngine
    public var engineVersion: String?
    public var bundleDigest: String?
    public var startedAt: Date
    public var finishedAt: Date?
    public var pdfRelativePath: String?
    public var synctexRelativePath: String?
    public var messages: [String]
    public var diagnostics: [LaTeXDiagnostic]
    public var isActive: Bool { [.queued,.preparing,.compiling].contains(state) }
    public var succeeded: Bool { state == .succeeded }
    public var duration: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }
    public init(id: UUID = UUID(), snapshot: LaTeXProjectSnapshot) {
        self.id=id;projectID=snapshot.manifest.id;revision=snapshot.manifest.revision;fingerprint=snapshot.fingerprint;snapshotID=snapshot.id
        state = .queued;engine=snapshot.manifest.engine;startedAt=Date();messages=[];diagnostics=[]
    }
}

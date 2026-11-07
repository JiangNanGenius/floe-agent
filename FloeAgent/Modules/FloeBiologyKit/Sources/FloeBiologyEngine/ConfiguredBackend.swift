// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBiologyCore

public struct BiologyWorkerIdentity: Codable, Sendable, Equatable {
    public var projectID:String
    public var runID:String
    public var objectID:String
    public var taskID:String
    public var hostRunID:String
    public var attemptID:String
    public var objectRevision:UInt64
    public var inputDigest:String
    public var environmentID:String
}
public struct BiologyTransportRequest: Sendable {
    public let identity:BiologyWorkerIdentity
    public let requestDigest:String
    public let envelope:Data
}
/// The trusted host verifies the actual durable job/target before returning this
/// receipt; model arguments and imported content cannot grant this authority.
public struct BiologyTransportReceipt: Sendable {
    public let jobID:UUID
    public let projectID:UUID
    public let runID:UUID
    public let owner:BiologyExecutionOwner
    public let environmentID:String
    public let requestDigest:String
    public let workerStopped:Bool
    public let exitCode:Int
    public let response:Data
    public init(jobID:UUID,projectID:UUID,runID:UUID,owner:BiologyExecutionOwner,environmentID:String,requestDigest:String,workerStopped:Bool,exitCode:Int,response:Data) {
        self.jobID=jobID;self.projectID=projectID;self.runID=runID;self.owner=owner;self.environmentID=environmentID;self.requestDigest=requestDigest;self.workerStopped=workerStopped;self.exitCode=exitCode;self.response=response
    }
}
public struct ConfiguredBiologyBackend: BiologyBackend {
    public let environmentID:String
    public let engineVersion:String
    public let methods:Set<String>
    private let execute:@Sendable (BiologyTransportRequest) async throws -> BiologyTransportReceipt
    private let stop:@Sendable (UUID) async throws -> Bool
    public init(environmentID:String,engineVersion:String,methods:Set<String>,execute:@escaping @Sendable (BiologyTransportRequest) async throws -> BiologyTransportReceipt,stop:@escaping @Sendable (UUID) async throws -> Bool) throws {
        guard !environmentID.isEmpty,environmentID != "native.local",environmentID.utf8.count<=4096,!engineVersion.isEmpty,!methods.isEmpty,methods.count<=256 else {throw BiologyError.invalid("Invalid configured scientific backend.")}
        self.environmentID=environmentID;self.engineVersion=engineVersion;self.methods=methods;self.execute=execute;self.stop=stop
    }
    private struct Inner:Encodable {let operation:String;let snapshotJSON:String;let options:JSONValue}
    private struct Envelope:Encodable {
        let protocolName="floe.biology.worker"
        let version=1
        let identity:BiologyWorkerIdentity
        let requestJSON:String
        let requestDigest:String
        enum CodingKeys:String,CodingKey {case protocolName="protocol";case version,identity,requestJSON,requestDigest}
    }
    private struct Reply:Decodable {
        struct Failure:Decodable {let message:String}
        let protocolName:String
        let version:Int
        let identity:BiologyWorkerIdentity?
        let requestDigest:String?
        let complete:Bool
        let success:Bool
        let result:BiologyAnalysisResult?
        let error:Failure?
        enum CodingKeys:String,CodingKey {case protocolName="protocol";case version,identity,requestDigest,complete,success,result,error}
    }
    public func evaluate(projectID:UUID,asset:BiologyAsset,method:String,options:JSONValue,runID:UUID,owner:BiologyExecutionOwner?) async throws -> BiologyAnalysisResult {
        guard let owner,methods.contains(method) else {throw BiologyError.unavailable("A configured calculation requires its host-owned task and run.")}
        let snapshot=try BiologyCoding.encode(asset)
        let identity=BiologyWorkerIdentity(projectID:projectID.uuidString.lowercased(),runID:runID.uuidString.lowercased(),objectID:asset.id.uuidString.lowercased(),taskID:owner.taskID.uuidString.lowercased(),hostRunID:owner.hostRunID.uuidString.lowercased(),attemptID:UUID().uuidString.lowercased(),objectRevision:asset.revision,inputDigest:BiologyProjectStore.digest(snapshot),environmentID:environmentID)
        let requestData=try BiologyCoding.encode(Inner(operation:method,snapshotJSON:String(decoding:snapshot,as:UTF8.self),options:options))
        let digest=BiologyProjectStore.digest(requestData)
        let envelope=try BiologyCoding.encode(Envelope(identity:identity,requestJSON:String(decoding:requestData,as:UTF8.self),requestDigest:digest))
        guard envelope.count<=32*1024*1024 else {throw BiologyError.invalid("Scientific request exceeds its inline transport budget.")}
        let receipt=try await execute(.init(identity:identity,requestDigest:digest,envelope:envelope))
        guard receipt.projectID==projectID,receipt.runID==runID,receipt.owner==owner,receipt.environmentID==environmentID,receipt.requestDigest==digest,receipt.workerStopped,receipt.exitCode==0,receipt.response.count<=32*1024*1024 else {throw BiologyError.corrupt("Scientific job ownership, stop acknowledgement, exit code or output size did not validate.")}
        let reply=try JSONDecoder().decode(Reply.self,from:receipt.response)
        guard reply.protocolName=="floe.biology.worker",reply.version==1,reply.identity==identity,reply.requestDigest==digest,reply.complete else {throw BiologyError.corrupt("Scientific output does not match its exact input, attempt and environment.")}
        guard reply.success,let result=reply.result else {throw BiologyError.unavailable(reply.error?.message ?? "Scientific engine did not return a result.")}
        return result
    }
    public func cancel(runID:UUID) async throws {
        guard try await stop(runID) else {throw BiologyError.unavailable("The host has not confirmed that the owned scientific worker stopped.")}
    }
}

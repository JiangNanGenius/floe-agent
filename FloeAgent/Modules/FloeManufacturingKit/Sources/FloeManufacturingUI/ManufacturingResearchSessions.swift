// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeManufacturingCore

public enum ManufacturingResearchFamily:String,Codable,CaseIterable,Sendable {
    case manufacturingCell,virtualMachine,engineeringAnalysis
    public var directoryName:String { switch self { case .manufacturingCell:"cell";case .virtualMachine:"virtual";case .engineeringAnalysis:"engineering" } }
    public var fileName:String { switch self { case .manufacturingCell:"latest.floecell";case .virtualMachine:"latest.floetwin";case .engineeringAnalysis:"latest.floeanalysis" } }
}
enum ManufacturingResearchRunState:String,Codable,Sendable { case prepared,opening,running,cancelling,completed,cancelled,failed }

/// Present only while an accepted calculation runs. The actual host lease
/// remains captured by that worker until the native engine has drained.
@MainActor enum ManufacturingResearchOwnerMonitor {
    static func start(provider:(@MainActor ()throws->AnyObject)?,isCurrent:@escaping @MainActor ()->Bool,
                      cancel:@escaping @MainActor ()->Void) -> Task<Void,Never>? {
        guard let provider else { return nil }
        return Task { @MainActor in
            while !Task.isCancelled,isCurrent() {
                do { let lease = try provider();withExtendedLifetime(lease) {} }
                catch { if isCurrent() { cancel() };return }
                do { try await Task.sleep(for:.milliseconds(200)) } catch { return }
            }
        }
    }
}

/// Owned by the existing ManufacturingModel, never a second per-path model.
/// UI child pages and native tools both select these exact model instances.
@MainActor @Observable public final class ManufacturingResearchSessions {
    public struct Snapshot:Codable,Sendable {
        public let family:ManufacturingResearchFamily
        public let ownerDocumentID:String
        public let state:String
        public let fingerprint:String
        public let inputSHA256:String?
        public let inputRevision:Int
        public let operationID:UUID?
        public let hasResult:Bool
        public let resultSHA256:String?
        public let diagnostic:String?
        public let contentKind:String
        public let contentJSON:String?
        public let nextOffset:Int?
        public let totalCharacters:Int
        public func withoutContent() -> Self {
            .init(family:family,ownerDocumentID:ownerDocumentID,state:state,fingerprint:fingerprint,inputSHA256:inputSHA256,
                inputRevision:inputRevision,operationID:operationID,hasResult:hasResult,resultSHA256:resultSHA256,diagnostic:diagnostic,
                contentKind:contentKind,contentJSON:nil,nextOffset:nil,totalCharacters:totalCharacters)
        }
    }
    public let directory:URL
    public let ownerDocumentID:String
    public var storageLeaseProvider:(@MainActor ()throws->AnyObject)?
    private let instanceID = UUID()
    private var cellStorage:CellWorkbenchModel?
    private var virtualStorage:VirtualMachineModel?
    private var engineeringStorage:EngineeringWorkbenchModel?
    private var released = false
    public init(directory:URL,ownerDocumentID:String) {
        self.directory = directory.standardizedFileURL;self.ownerDocumentID = ownerDocumentID
    }
    public var isBusy:Bool { cellStorage?.busy == true || virtualStorage?.busy == true || engineeringStorage?.busy == true || (cellStorage?.activeWorkerCount ?? 0) > 0 || (cellStorage?.activeReadCount ?? 0) > 0 || (virtualStorage?.activeWorkerCount ?? 0) > 0 || (virtualStorage?.activePoseWorkerCount ?? 0) > 0 || virtualStorage?.checking == true || (engineeringStorage?.activeWorkerCount ?? 0) > 0 }
    func cell(project:ManufacturingCellProject) -> CellWorkbenchModel {
        if let value = cellStorage { return value }
        let value = CellWorkbenchModel(project:project,directory:child(.manufacturingCell))
        value.operationLeaseProvider = { [weak self] in try Self.requiredLease(self) }
        cellStorage = value;return value
    }
    func virtual(project:VirtualMachineProject,cellArtifact:CellSimulationArtifact? = nil) -> VirtualMachineModel {
        if let value = virtualStorage { return value }
        let value = VirtualMachineModel(project:project,directory:child(.virtualMachine),cellArtifact:cellArtifact)
        value.operationLeaseProvider = { [weak self] in try Self.requiredLease(self) }
        virtualStorage = value;return value
    }
    func engineering(project:EngineeringAnalysisProject? = nil) -> EngineeringWorkbenchModel {
        if let value = engineeringStorage { return value }
        let value = EngineeringWorkbenchModel(directory:child(.engineeringAnalysis),project:project)
        value.operationLeaseProvider = { [weak self] in try Self.requiredLease(self) }
        engineeringStorage = value;return value
    }
    public func requireOwner(directory:URL,documentID:String) throws {
        guard !released,self.directory == directory.standardizedFileURL,ownerDocumentID == documentID else { throw ManufacturingError.stale }
    }
    public func release() {
        released = true;cellStorage?.cancel();virtualStorage?.cancel();engineeringStorage?.cancel()
        virtualStorage?.stop()
    }
    public func snapshot(_ family:ManufacturingResearchFamily,content:String = "input",offset:Int = 0,limit:Int = 12_000) throws -> Snapshot {
        guard !released,["input","result"].contains(content),offset >= 0,(1...12_000).contains(limit) else { throw ManufacturingError.stale }
        let value = try values(family)
        let inputHash = value.inputSHA256
        let resultHash = value.result.map(ManufacturingStudy.digest)
        let fingerprint = try ResearchArchive.digest(Fingerprint(owner:ownerDocumentID,instance:instanceID,family:family,
            input:inputHash,revision:value.revision,generation:value.generation,result:resultHash,state:value.state))
        let selected = content == "input" ? value.input:value.result
        let text = selected.map { String(decoding:$0,as:UTF8.self) }
        guard offset <= (text?.count ?? 0) else { throw ManufacturingError.invalid("Research page offset exceeds the current document") }
        let part:String?,next:Int?
        if let text {
            let start = text.index(text.startIndex,offsetBy:offset),length = min(limit,text.count-offset)
            let end = text.index(start,offsetBy:length)
            part = String(text[start..<end]);next = end == text.endIndex ? nil:offset+length
        } else { part = nil;next = nil }
        return .init(family:family,ownerDocumentID:ownerDocumentID,state:value.state,fingerprint:fingerprint,
            inputSHA256:inputHash,inputRevision:value.revision,operationID:value.operationID,
            hasResult:value.result != nil,resultSHA256:resultHash,diagnostic:value.diagnostic,
            contentKind:content,contentJSON:part,nextOffset:next,totalCharacters:text?.count ?? 0)
    }
    /// Only the App's verified fixed-family reader supplies these bytes.
    /// Hydration is read-only and never replaces an already open dirty model.
    public func adoptSaved(_ family:ManufacturingResearchFamily,data:Data,isArchive:Bool,expectedFingerprint:String) throws -> Snapshot {
        try installSaved(family,data:data,isArchive:isArchive,expectedFingerprint:expectedFingerprint,onlyWhenAbsent:true)
    }
    /// Explicitly opening the actual saved original may replace this exact
    /// inspected UI generation. Read-only inspection never takes this path.
    public func openSaved(_ family:ManufacturingResearchFamily,data:Data,expectedFingerprint:String) throws -> Snapshot {
        try installSaved(family,data:data,isArchive:true,expectedFingerprint:expectedFingerprint,onlyWhenAbsent:false)
    }
    private func installSaved(_ family:ManufacturingResearchFamily,data:Data,isArchive:Bool,expectedFingerprint:String,onlyWhenAbsent:Bool) throws -> Snapshot {
        try requireFingerprint(family,expectedFingerprint)
        guard !isBusy,data.count <= ResearchArchive.byteLimit else { throw ManufacturingError.stale }
        if onlyWhenAbsent { guard try snapshot(family).state == "none" else { throw ManufacturingError.stale } }
        if !isArchive { _ = try Self.inputFingerprint(data,family:family) }
        switch family {
        case .manufacturingCell:
            let project:ManufacturingCellProject,artifact:CellSimulationArtifact?
            if isArchive { let loaded = try ManufacturingCellArchive.open(data:data);project = loaded.0;artifact = loaded.1 }
            else { project = try JSONDecoder().decode(ManufacturingCellProject.self,from:data);try project.validate();artifact = nil }
            try cell(project:project).adoptSaved(project:project,artifact:artifact)
        case .virtualMachine:
            let project:VirtualMachineProject,artifact:VirtualMachineArtifact?
            if isArchive {
                let loaded = try ResearchArchive.open(data:data,input:VirtualMachineProject.self,output:VirtualMachineArtifact.self,family:.virtualMachine) { try $1.validate(for:$0) }
                project = loaded.0;artifact = loaded.1
            } else { project = try JSONDecoder().decode(VirtualMachineProject.self,from:data);try project.validate();artifact = nil }
            try virtual(project:project).adoptSaved(project:project,artifact:artifact)
        case .engineeringAnalysis:
            let project:EngineeringAnalysisProject,artifact:EngineeringAnalysisArtifact?
            if isArchive {
                let loaded = try ResearchArchive.open(data:data,input:EngineeringAnalysisProject.self,output:EngineeringAnalysisArtifact.self,family:.engineeringAnalysis) { try $1.validate(for:$0) }
                project = loaded.0;artifact = loaded.1
            } else { project = try JSONDecoder().decode(EngineeringAnalysisProject.self,from:data);try project.validate();artifact = nil }
            try engineering(project:project).adoptSaved(project:project,artifact:artifact)
        }
        return try snapshot(family)
    }

    /// Explicit full typed input only; no demonstration is created by a tool.
    public func configure(_ family:ManufacturingResearchFamily,inputJSON:Data,expectedFingerprint:String) throws -> Snapshot {
        try requireFingerprint(family,expectedFingerprint)
        guard !isBusy,inputJSON.count <= 2 * 1_024 * 1_024 else { throw ManufacturingError.invalid("Stop the current calculation or reduce the research input") }
        let lease = try acquireLease();defer { withExtendedLifetime(lease) {} }
        let decoder = JSONDecoder()
        switch family {
        case .manufacturingCell:
            let proposed = try decoder.decode(ManufacturingCellProject.self,from:inputJSON);try proposed.validate()
            try Self.rejectUnknownFields(inputJSON,canonical:ManufacturingStudy.encoder.encode(proposed))
            if let existing = cellStorage { guard existing.project.id == proposed.id else { throw ManufacturingError.stale } }
            try ResearchArchive.saveInput(proposed,to:child(family).appendingPathComponent("draft.json"))
            if let existing = cellStorage { existing.project = proposed } else { _ = cell(project:proposed) }
        case .virtualMachine:
            let proposed = try decoder.decode(VirtualMachineProject.self,from:inputJSON);try proposed.validate()
            try Self.rejectUnknownFields(inputJSON,canonical:ManufacturingStudy.encoder.encode(proposed))
            if let existing = virtualStorage { guard existing.project.id == proposed.id else { throw ManufacturingError.stale } }
            try ResearchArchive.saveInput(proposed,to:child(family).appendingPathComponent("draft.json"))
            if let existing = virtualStorage { existing.project = proposed } else { _ = virtual(project:proposed) }
        case .engineeringAnalysis:
            let proposed = try decoder.decode(EngineeringAnalysisProject.self,from:inputJSON);try proposed.validate()
            try Self.rejectUnknownFields(inputJSON,canonical:ManufacturingStudy.encoder.encode(proposed))
            if let existing = engineeringStorage { guard existing.project.id == proposed.id else { throw ManufacturingError.stale } }
            try ResearchArchive.saveInput(proposed,to:child(family).appendingPathComponent("draft.json"))
            let model = engineering(project:proposed);model.project = proposed
        }
        return try snapshot(family)
    }
    public func persistConfiguration(_ family:ManufacturingResearchFamily,expectedFingerprint:String) throws -> Snapshot {
        try requireFingerprint(family,expectedFingerprint)
        guard let input = try values(family).input else { throw ManufacturingError.invalid("Configure this research program first") }
        return try configure(family,inputJSON:input,expectedFingerprint:expectedFingerprint)
    }
    /// Caller supplies the existing source/archive CAS checks. It is checked
    /// before compute and again immediately before the real archive write.
    public func calculateAndSave(_ family:ManufacturingResearchFamily,expectedFingerprint:String,
                                 validateSource:@MainActor ()async throws->Void) async throws -> Snapshot {
        try requireFingerprint(family,expectedFingerprint)
        guard !isBusy else { throw ManufacturingError.invalid("A research calculation is already running") }
        let lease = try acquireLease();defer { withExtendedLifetime(lease) {} }
        try await validateSource();try Task.checkCancellation()
        try requireFingerprint(family,expectedFingerprint)
        let worker:Task<Void,Never>,operationID:UUID
        switch family {
        case .manufacturingCell:
            guard let model = cellStorage else { throw ManufacturingError.invalid("Configure or explicitly open the saved manufacturing cell first") }
            model.calculate();guard let work = model.work else { throw ManufacturingError.invalid(model.diagnostic) };worker = work;operationID = model.generation
        case .virtualMachine:
            guard let model = virtualStorage else { throw ManufacturingError.invalid("Configure or explicitly open the saved virtual machine first") }
            model.calculate();guard let work = model.work else { throw ManufacturingError.invalid(model.diagnostic) };worker = work;operationID = model.generation
        case .engineeringAnalysis:
            guard let model = engineeringStorage else { throw ManufacturingError.invalid("Configure or explicitly open the saved analysis first") }
            model.calculate();guard let work = model.work else { throw ManufacturingError.invalid(model.diagnostic) };worker = work;operationID = model.generation
        }
        await withTaskCancellationHandler(operation:{ await worker.value },onCancel:{
            Task { @MainActor [weak self] in self?.cancelOwned(family,operationID:operationID) }
        })
        try Task.checkCancellation()
        let completed = try snapshot(family)
        guard generation(family) == operationID,completed.hasResult,completed.state == ManufacturingResearchRunState.completed.rawValue else {
            throw ManufacturingError.invalid(completed.diagnostic ?? "The calculation was cancelled or superseded; no result was saved")
        }
        try await validateSource();try Task.checkCancellation()
        guard generation(family) == operationID,try snapshot(family).fingerprint == completed.fingerprint else { throw ManufacturingError.stale }
        switch family { case .manufacturingCell:try cellStorage!.saveResult();case .virtualMachine:try virtualStorage!.saveResult();case .engineeringAnalysis:try engineeringStorage!.saveResult() }
        return try snapshot(family)
    }
    @discardableResult public func cancel(_ family:ManufacturingResearchFamily,expectedFingerprint:String,operationID:UUID) throws -> Snapshot {
        try requireFingerprint(family,expectedFingerprint)
        guard activeOperation(family) == operationID else { throw ManufacturingError.stale }
        let lease = try acquireLease();defer { withExtendedLifetime(lease) {} }
        cancelOwned(family,operationID:operationID);return try snapshot(family)
    }
    public func save(_ family:ManufacturingResearchFamily,expectedFingerprint:String) throws -> Snapshot {
        try requireFingerprint(family,expectedFingerprint)
        switch family {
        case .manufacturingCell:guard let model = cellStorage else { throw ManufacturingError.stale };try model.saveResult()
        case .virtualMachine:guard let model = virtualStorage else { throw ManufacturingError.stale };try model.saveResult()
        case .engineeringAnalysis:guard let model = engineeringStorage else { throw ManufacturingError.stale };try model.saveResult()
        }
        return try snapshot(family)
    }
    private nonisolated struct Fingerprint:Encodable {
        let owner:String,instance:UUID,family:ManufacturingResearchFamily,input:String?,revision:Int,generation:UUID?,result:String?,state:String
    }
    private struct Values {
        var input:Data?,result:Data?,inputSHA256:String?,revision = 0,generation:UUID?,operationID:UUID?,running = false,state = "none",diagnostic:String?
    }
    private func values(_ family:ManufacturingResearchFamily) throws -> Values {
        func encode<T:Encodable>(_ value:T) throws -> Data { try ManufacturingStudy.encoder.encode(value) }
        switch family {
        case .manufacturingCell:
            guard let model = cellStorage else { return .init() }
            return try .init(input:encode(model.project),result:model.artifact.map(encode),inputSHA256:ResearchArchive.digest(model.project),revision:model.inputRevision,generation:model.generation,operationID:model.activeOperationID,
                running:model.busy,state:model.runState.rawValue,diagnostic:model.diagnostic.isEmpty ? nil:model.diagnostic)
        case .virtualMachine:
            guard let model = virtualStorage else { return .init() }
            return try .init(input:encode(model.project),result:model.artifact.map(encode),inputSHA256:ResearchArchive.digest(model.project),revision:model.inputRevision,generation:model.generation,operationID:model.activeOperationID ?? model.poseOperationID,
                running:model.busy || model.checking,state:model.checking ? "checking":model.runState.rawValue,diagnostic:model.diagnostic.isEmpty ? nil:model.diagnostic)
        case .engineeringAnalysis:
            guard let model = engineeringStorage else { return .init() }
            return try .init(input:encode(model.project),result:model.artifact.map(encode),inputSHA256:ResearchArchive.digest(model.project),revision:model.inputRevision,generation:model.generation,operationID:model.activeOperationID,
                running:model.busy,state:model.runState.rawValue,diagnostic:model.diagnostic.isEmpty ? nil:model.diagnostic)
        }
    }
    private func generation(_ family:ManufacturingResearchFamily) -> UUID? {
        switch family { case .manufacturingCell:cellStorage?.generation;case .virtualMachine:virtualStorage?.generation;case .engineeringAnalysis:engineeringStorage?.generation }
    }
    private func requireFingerprint(_ family:ManufacturingResearchFamily,_ fingerprint:String) throws {
        guard !released,try snapshot(family).fingerprint == fingerprint else { throw ManufacturingError.stale }
    }
    public nonisolated static func inputFingerprint(_ data:Data,family:ManufacturingResearchFamily) throws -> String {
        let canonical:Data
        switch family {
        case .manufacturingCell:let input = try JSONDecoder().decode(ManufacturingCellProject.self,from:data);try input.validate();canonical = try ManufacturingStudy.encoder.encode(input)
        case .virtualMachine:let input = try JSONDecoder().decode(VirtualMachineProject.self,from:data);try input.validate();canonical = try ManufacturingStudy.encoder.encode(input)
        case .engineeringAnalysis:let input = try JSONDecoder().decode(EngineeringAnalysisProject.self,from:data);try input.validate();canonical = try ManufacturingStudy.encoder.encode(input)
        }
        try rejectUnknownFields(data,canonical:canonical);return ManufacturingStudy.digest(canonical)
    }
    private nonisolated static func rejectUnknownFields(_ original:Data,canonical:Data) throws {
        func visit(_ given:Any,_ typed:Any,_ path:String) throws {
            if let given = given as? [String:Any],let typed = typed as? [String:Any] {
                let extra = Set(given.keys).subtracting(typed.keys)
                guard extra.isEmpty else { throw ManufacturingError.invalid("Unknown research input fields at \(path): \(extra.sorted().joined(separator:", ")). Use the current typed input from inspection.") }
                for (key,value) in given { if let target = typed[key] { try visit(value,target,path+"."+key) } }
            } else if let given = given as? [Any],let typed = typed as? [Any] {
                for (index,pair) in zip(given,typed).enumerated() { try visit(pair.0,pair.1,path+"[\(index)]") }
            }
        }
        try visit(JSONSerialization.jsonObject(with:original),JSONSerialization.jsonObject(with:canonical),"input")
    }
    private func activeOperation(_ family:ManufacturingResearchFamily) -> UUID? {
        switch family { case .manufacturingCell:cellStorage?.activeOperationID;case .virtualMachine:virtualStorage?.activeOperationID ?? virtualStorage?.poseOperationID;case .engineeringAnalysis:engineeringStorage?.activeOperationID }
    }
    private func cancelOwned(_ family:ManufacturingResearchFamily,operationID:UUID) {
        guard activeOperation(family) == operationID else { return }
        switch family { case .manufacturingCell:cellStorage?.cancel();case .virtualMachine:virtualStorage?.cancel();case .engineeringAnalysis:engineeringStorage?.cancel() }
    }
    private func child(_ family:ManufacturingResearchFamily) -> URL { directory.appendingPathComponent(family.directoryName,isDirectory:true) }
    private func acquireLease() throws -> AnyObject? { guard !released else { throw ManufacturingError.stale };return try storageLeaseProvider?() }
    private static func requiredLease(_ owner:ManufacturingResearchSessions?) throws -> AnyObject {
        guard let owner,!owner.released else { throw ManufacturingError.stale }
        return try owner.acquireLease() ?? NSObject()
    }
}
#endif

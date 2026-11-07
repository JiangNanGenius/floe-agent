// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeManufacturingCore
import FloeEngineeringCore

@MainActor @Observable final class EngineeringWorkbenchModel {
    var project:EngineeringAnalysisProject {
        didSet {
            let next = try? ResearchArchive.digest(project),previous = try? ResearchArchive.digest(oldValue)
            if next == nil || next != previous { inputRevision += 1;invalidate() }
        }
    }
    private(set) var artifact:EngineeringAnalysisArtifact?
    private(set) var busy = false
    private(set) var notice = ""
    private(set) var diagnostic = ""
    let directory:URL
    private let service = EngineeringAnalysisService()
    private(set) var generation = UUID()
    private(set) var inputRevision = 0
    private(set) var activeWorkerCount = 0
    private(set) var activeOperationID:UUID?
    private(set) var runState:ManufacturingResearchRunState = .prepared
    var operationLeaseProvider:(@MainActor () throws -> AnyObject)?
    private(set) var work:Task<Void,Never>?
    init(directory:URL,project:EngineeringAnalysisProject? = nil) { self.directory = directory;self.project = project ?? .demonstration() }
    func invalidate() { generation = UUID();work?.cancel();work = nil;busy = activeWorkerCount > 0;artifact = nil;notice = "";diagnostic = "";runState = activeWorkerCount > 0 ? .cancelling:.prepared }
    func select(thermal:Bool) { invalidate();project = .demonstration(thermal:thermal) }
    func editStructural(_ body:(inout StructuralRequest)->Void) {
        guard case .structural(var value) = project.analysis else { return }
        body(&value);project.analysis = .structural(value)
    }
    func editThermal(_ body:(inout ThermalRequest)->Void) {
        guard case .thermal(var value) = project.analysis else { return }
        body(&value);project.analysis = .thermal(value)
    }
    func calculate() {
        guard !busy,activeWorkerCount == 0 else { return }
        let storageLease:AnyObject?
        do { storageLease = try operationLeaseProvider?() } catch { report(error);return }
        invalidate();busy = true;runState = .running
        let input = project,token = generation,service = service
        activeWorkerCount += 1;activeOperationID = token
        work = Task { [weak self] in
            let monitor = ManufacturingResearchOwnerMonitor.start(provider:self?.operationLeaseProvider,
                isCurrent:{ [weak self] in self?.generation == token && self?.busy == true },
                cancel:{ [weak self] in self?.cancel() })
            defer { monitor?.cancel();self?.finishWorker(token);withExtendedLifetime(storageLease) {} }
            do {
                let value = try await service.calculate(input)
                guard let self,self.generation == token,!Task.isCancelled,value.inputSHA256 == (try ResearchArchive.digest(self.project)) else { return }
                self.artifact = value;self.busy = false;self.work = nil;self.runState = .completed;self.notice = L("计算完成","Calculation completed")
            } catch {
                guard let self,self.generation == token else { return }
                self.busy = false;self.work = nil;self.runState = Task.isCancelled ? .cancelled:.failed;self.report(error)
            }
        }
    }
    func cancel() { invalidate();runState = activeWorkerCount > 0 ? .cancelling:.cancelled;notice = activeWorkerCount > 0 ? L("正在停止","Stopping"):L("已取消","Cancelled") }
    func save() { do { try saveResult() } catch { report(error) } }
    func saveResult() throws {
        let lease = try operationLeaseProvider?();defer { withExtendedLifetime(lease) {} }
        guard !busy,let artifact else { throw ManufacturingError.invalid("No completed engineering result") }
        try artifact.validate(for:project)
        try EngineeringAnalysisArchive.save(project:project,artifact:artifact,to:directory.appendingPathComponent("latest.floeanalysis"))
        notice = L("已保存分析","Analysis saved")
    }
    func reopen() { load(directory.appendingPathComponent("latest.floeanalysis")) }
    func load(_ url:URL) {
        let access = url.startAccessingSecurityScopedResource();defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            if url.pathExtension.lowercased() == "json" {
                let value = try ResearchArchive.openInput(url,as:EngineeringAnalysisProject.self);try value.validate()
                invalidate();project = value
            } else {
                let (input,result) = try EngineeringAnalysisArchive.open(url)
                invalidate();project = input;artifact = result;runState = .completed
            }
            notice = L("分析已加载","Analysis loaded")
        } catch { report(error) }
    }
    func adoptSaved(project:EngineeringAnalysisProject,artifact:EngineeringAnalysisArtifact?) throws {
        guard !busy else { throw ManufacturingError.stale }
        try project.validate();if let artifact { try artifact.validate(for:project) }
        invalidate();self.project = project;self.artifact = artifact
        runState = artifact == nil ? .prepared:.completed
    }
    func export(input:Bool) throws -> URL {
        let url = directory.appendingPathComponent(input ? "engineering-input.json" : "engineering-result.json")
        if input { try project.validate();try ResearchArchive.saveInput(project,to:url) }
        else {
            guard let artifact else { throw ManufacturingError.invalid("calculate first") }
            try artifact.validate(for:project);try ResearchArchive.saveInput(artifact,to:url)
        }
        return url
    }
    private func finishWorker(_ operation:UUID) {
        activeWorkerCount = max(0,activeWorkerCount-1)
        if activeWorkerCount == 0,activeOperationID == operation {
            activeOperationID = nil
            if runState == .cancelling { busy = false;work = nil;runState = .cancelled;notice = L("已取消","Cancelled") }
        }
    }
    func report(_ error:Error) { diagnostic = String(describing:error);notice = L("未能完成，当前配置已保留","Unable to complete; current configuration retained") }
}
#endif

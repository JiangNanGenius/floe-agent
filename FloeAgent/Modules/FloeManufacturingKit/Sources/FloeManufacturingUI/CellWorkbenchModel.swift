// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeManufacturingCore

@MainActor @Observable final class CellWorkbenchModel {
    var project:ManufacturingCellProject {
        didSet { if !installingProject, project != oldValue { inputRevision += 1;invalidate() } }
    }
    struct SavedOpenRequest {
        fileprivate let generation:UUID
        fileprivate let project:ManufacturingCellProject
    }
    enum SavedResultAvailability:Equatable { case unchecked, missing, available, unavailable }
    private(set) var savedResultAvailability:SavedResultAvailability = .unchecked
    private(set) var openingSavedResult = false
    private var cleanProject:ManufacturingCellProject
    private var hasUnsavedResult = false
    private var installingProject = false
    private var progressBeforeOpen = 0.0
    private let archiveLoader:@Sendable (CellWorkbenchLoadSource) async throws -> CellWorkbenchLoadedDocument
    var hasUnsavedChanges:Bool { project != cleanProject || hasUnsavedResult }
    private(set) var artifact:CellSimulationArtifact?
    private(set) var busy = false
    private(set) var progress = 0.0
    private(set) var notice = ""
    private(set) var diagnostic = ""
    private let directory:URL
    private let service = CellManufacturingService()
    private(set) var generation = UUID()
    private(set) var inputRevision = 0
    private(set) var activeWorkerCount = 0
    private(set) var activeReadCount = 0
    private(set) var activeOperationID:UUID?
    private(set) var runState:ManufacturingResearchRunState = .prepared
    var operationLeaseProvider:(@MainActor () throws -> AnyObject)?
    private(set) var work:Task<Void,Never>?
    init(project:ManufacturingCellProject,directory:URL,
         archiveLoader:@escaping @Sendable (CellWorkbenchLoadSource) async throws -> CellWorkbenchLoadedDocument = CellWorkbenchArchiveReader.load) {
        self.project = project;self.cleanProject = project;self.directory = directory;self.archiveLoader = archiveLoader
    }
    func refreshSavedResultAvailability() {
        do { savedResultAvailability = try CellWorkbenchArchiveReader.hasSavedFile(in:directory) ? .available:.missing }
        catch { savedResultAvailability = .unavailable;report(error) }
    }
    func savedOpenRequest() -> SavedOpenRequest { .init(generation:generation,project:project) }
    func invalidate() {
        generation = UUID(); work?.cancel(); work = nil
        artifact = nil;busy = activeWorkerCount > 0;openingSavedResult = false;hasUnsavedResult = false;progress = 0;notice = "";diagnostic = "";runState = activeWorkerCount > 0 ? .cancelling:.prepared
    }
    func calculate() {
        guard !busy,activeWorkerCount == 0 else { return }
        let storageLease:AnyObject?
        do { storageLease = try operationLeaseProvider?() } catch { report(error);return }
        invalidate(); busy = true;runState = .running
        let token = generation,input = project,service = service
        activeWorkerCount += 1;activeOperationID = token
        work = Task { [weak self] in
            let monitor = ManufacturingResearchOwnerMonitor.start(provider:self?.operationLeaseProvider,
                isCurrent:{ [weak self] in self?.generation == token && self?.busy == true },
                cancel:{ [weak self] in self?.cancel() })
            defer { monitor?.cancel();self?.finishWorker(token);withExtendedLifetime(storageLease) {} }
            do {
                let value = try await service.calculate(input) { [weak self] fraction,_ in
                    Task { @MainActor [weak self] in
                        guard let self,self.generation == token,self.busy else { return }
                        self.progress = max(self.progress,fraction)
                    }
                }
                guard let self,self.generation == token,!Task.isCancelled,
                      value.inputSHA256 == (try ResearchArchive.digest(self.project)) else { return }
                self.artifact = value;self.hasUnsavedResult = true;self.busy = false;self.progress = 1;self.work = nil;self.runState = .completed
                self.notice = L("计算完成","Calculation completed")
            } catch {
                guard let self,self.generation == token else { return }
                self.busy = false; self.work = nil
                self.runState = Task.isCancelled ? .cancelled:.failed
                self.diagnostic = error.localizedDescription
                self.notice = Task.isCancelled ? L("已取消","Cancelled") : L("未能完成计算","Unable to calculate")
            }
        }
    }
    func cancel() {
        guard busy else { return }
        generation = UUID();work?.cancel();work = nil;busy = activeWorkerCount > 0
        if openingSavedResult { progress = progressBeforeOpen }
        else { artifact = nil;hasUnsavedResult = false }
        openingSavedResult = false;runState = activeWorkerCount > 0 ? .cancelling:.cancelled;notice = activeWorkerCount > 0 ? L("正在停止","Stopping"):L("已取消","Cancelled")
    }
    func save() { do { try saveResult() } catch { report(error) } }
    func saveResult() throws {
        let lease = try operationLeaseProvider?();defer { withExtendedLifetime(lease) {} }
        guard !busy,let artifact else { throw ManufacturingError.invalid("No completed manufacturing cell result") }
        try artifact.validate(for:project)
        try ManufacturingCellArchive.save(project:project,artifact:artifact,to:directory.appendingPathComponent("latest.floecell"))
        cleanProject = project;hasUnsavedResult = false;savedResultAvailability = .available
        notice = L("已保存制造单元","Manufacturing cell saved")
    }
    @discardableResult func reopen(_ request:SavedOpenRequest? = nil) -> Task<Void,Never>? {
        guard !busy else { return nil }
        if let request, request.generation != generation || request.project != project {
            report(ManufacturingError.stale);return nil
        }
        return load(directory.appendingPathComponent("latest.floecell"))
    }
    /// A read installs only at the same editor generation. Keep the current
    /// program/result until successful validation, including on cancel/failure.
    @discardableResult func load(_ url:URL) -> Task<Void,Never>? {
        guard !busy else { return nil }
        let storageLease:AnyObject?
        do { storageLease = try operationLeaseProvider?() } catch { report(error);return nil }
        generation = UUID();let token = generation,input = project,loader = archiveLoader
        let isSaved = url.standardizedFileURL == directory.appendingPathComponent("latest.floecell").standardizedFileURL
        let source = CellWorkbenchLoadSource(url:url,savedDirectory:isSaved ? directory:nil)
        progressBeforeOpen = progress;openingSavedResult = true;busy = true;diagnostic = "";runState = .opening
        notice = L("正在打开制造单元…","Opening manufacturing cell…")
        activeReadCount += 1
        let task = Task { [weak self] in
            defer { if let self { self.activeReadCount = max(0,self.activeReadCount-1) };withExtendedLifetime(storageLease) {} }
            do {
                let loaded = try await loader(source)
                try Task.checkCancellation()
                guard let self,self.generation == token,self.project == input else { return }
                self.installingProject = true;self.project = loaded.project;self.installingProject = false
                self.artifact = loaded.artifact;self.hasUnsavedResult = loaded.artifact != nil && !isSaved
                if isSaved { self.cleanProject = loaded.project;self.savedResultAvailability = .available }
                self.progress = loaded.artifact == nil ? 0:1;self.runState = loaded.artifact == nil ? .prepared:.completed
                self.busy = false;self.openingSavedResult = false;self.work = nil
                self.notice = L("制造单元已打开","Manufacturing cell opened")
            } catch {
                guard let self,self.generation == token else { return }
                self.busy = false;self.openingSavedResult = false;self.work = nil;self.progress = self.progressBeforeOpen
                if error is CancellationError { self.notice = L("已取消","Cancelled") }
                else { self.report(error) }
                self.refreshSavedResultAvailability()
                if isSaved, !(error is CancellationError), self.savedResultAvailability == .available { self.savedResultAvailability = .unavailable }
            }
        }
        work = task;return task
    }
    func adoptSaved(project:ManufacturingCellProject,artifact:CellSimulationArtifact?) throws {
        guard !busy else { throw ManufacturingError.stale }
        try project.validate();if let artifact { try artifact.validate(for:project) }
        invalidate();installingProject = true;self.project = project;installingProject = false
        self.artifact = artifact;cleanProject = project;hasUnsavedResult = false
        runState = artifact == nil ? .prepared:.completed;progress = artifact == nil ? 0:1
        if artifact != nil { savedResultAvailability = .available }
    }
    func export(input:Bool) throws -> URL {
        let url = directory.appendingPathComponent(input ? "manufacturing-cell-input.json" : "manufacturing-cell-result.json")
        if input { try project.validate(); try ResearchArchive.saveInput(project,to:url) }
        else {
            guard let artifact,artifact.inputSHA256 == (try ResearchArchive.digest(project)) else { throw ManufacturingError.stale }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try ManufacturingCellArchive.neutralExport(artifact).write(to:url,options:.atomic)
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
    func report(_ error:Error) { diagnostic = error.localizedDescription; notice = L("操作未完成，当前配置已保留","Unable to complete; current configuration retained") }
}
#endif

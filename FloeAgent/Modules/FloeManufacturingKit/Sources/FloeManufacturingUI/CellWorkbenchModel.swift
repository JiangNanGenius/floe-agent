// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeManufacturingCore

@MainActor @Observable final class CellWorkbenchModel {
    var project:ManufacturingCellProject {
        didSet { if !installingProject, project != oldValue { invalidate() } }
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
    private var generation = UUID()
    private var work:Task<Void,Never>?
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
        artifact = nil;busy = false;openingSavedResult = false;hasUnsavedResult = false;progress = 0;notice = "";diagnostic = ""
    }
    func calculate() {
        guard !busy else { return }
        invalidate(); busy = true
        let token = generation,input = project,service = service
        work = Task { [weak self] in
            do {
                let value = try await service.calculate(input) { [weak self] fraction,_ in
                    Task { @MainActor [weak self] in
                        guard let self,self.generation == token,self.busy else { return }
                        self.progress = max(self.progress,fraction)
                    }
                }
                guard let self,self.generation == token,!Task.isCancelled,
                      value.inputSHA256 == (try ResearchArchive.digest(self.project)) else { return }
                self.artifact = value;self.hasUnsavedResult = true;self.busy = false;self.progress = 1;self.work = nil
                self.notice = L("计算完成","Calculation completed")
            } catch {
                guard let self,self.generation == token else { return }
                self.busy = false; self.work = nil
                self.diagnostic = error.localizedDescription
                self.notice = Task.isCancelled ? L("已取消","Cancelled") : L("未能完成计算","Unable to calculate")
            }
        }
    }
    func cancel() {
        guard busy else { return }
        generation = UUID();work?.cancel();work = nil;busy = false
        if openingSavedResult { progress = progressBeforeOpen }
        else { artifact = nil;hasUnsavedResult = false }
        openingSavedResult = false;notice = L("已取消","Cancelled")
    }
    func save() {
        do {
            guard !busy,let artifact else { return }
            try ManufacturingCellArchive.save(project:project,artifact:artifact,to:directory.appendingPathComponent("latest.floecell"))
            cleanProject = project;hasUnsavedResult = false;savedResultAvailability = .available
            notice = L("已保存制造单元","Manufacturing cell saved")
        } catch { report(error) }
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
        generation = UUID();let token = generation,input = project,loader = archiveLoader
        let isSaved = url.standardizedFileURL == directory.appendingPathComponent("latest.floecell").standardizedFileURL
        let source = CellWorkbenchLoadSource(url:url,savedDirectory:isSaved ? directory:nil)
        progressBeforeOpen = progress;openingSavedResult = true;busy = true;diagnostic = ""
        notice = L("正在打开制造单元…","Opening manufacturing cell…")
        let task = Task { [weak self] in
            do {
                let loaded = try await loader(source)
                try Task.checkCancellation()
                guard let self,self.generation == token,self.project == input else { return }
                self.installingProject = true;self.project = loaded.project;self.installingProject = false
                self.artifact = loaded.artifact;self.hasUnsavedResult = loaded.artifact != nil && !isSaved
                if isSaved { self.cleanProject = loaded.project;self.savedResultAvailability = .available }
                self.progress = loaded.artifact == nil ? 0:1
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
    func report(_ error:Error) { diagnostic = error.localizedDescription; notice = L("操作未完成，当前配置已保留","Unable to complete; current configuration retained") }
}
#endif

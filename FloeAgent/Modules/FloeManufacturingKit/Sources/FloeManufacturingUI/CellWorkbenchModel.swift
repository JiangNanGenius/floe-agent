// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeManufacturingCore

@MainActor @Observable final class CellWorkbenchModel {
    var project:ManufacturingCellProject
    private(set) var artifact:CellSimulationArtifact?
    private(set) var busy = false
    private(set) var progress = 0.0
    private(set) var notice = ""
    private(set) var diagnostic = ""
    private let directory:URL
    private let service = CellManufacturingService()
    private var generation = UUID()
    private var work:Task<Void,Never>?
    init(project:ManufacturingCellProject,directory:URL) { self.project = project; self.directory = directory }
    func invalidate() {
        generation = UUID(); work?.cancel(); work = nil
        artifact = nil; busy = false; progress = 0; notice = ""; diagnostic = ""
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
                self.artifact = value; self.busy = false; self.progress = 1; self.work = nil
                self.notice = L("计算完成","Calculation completed")
            } catch {
                guard let self,self.generation == token else { return }
                self.busy = false; self.work = nil
                self.diagnostic = error.localizedDescription
                self.notice = Task.isCancelled ? L("已取消","Cancelled") : L("未能完成计算","Unable to calculate")
            }
        }
    }
    func cancel() { guard busy else { return }; generation = UUID(); work?.cancel(); work = nil; busy = false; artifact = nil; notice = L("已取消","Cancelled") }
    func save() {
        do {
            guard let artifact else { return }
            try ManufacturingCellArchive.save(project:project,artifact:artifact,to:directory.appendingPathComponent("latest.floecell"))
            notice = L("已保存制造单元","Manufacturing cell saved")
        } catch { report(error) }
    }
    func reopen() { load(directory.appendingPathComponent("latest.floecell")) }
    func load(_ url:URL) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            if url.pathExtension.lowercased() == "json" {
                let value = try ResearchArchive.openInput(url,as:ManufacturingCellProject.self); try value.validate()
                invalidate(); project = value
            } else {
                let (input,result) = try ManufacturingCellArchive.open(url)
                invalidate(); project = input; artifact = result; progress = 1
            }
            notice = L("制造单元已加载","Manufacturing cell loaded")
        } catch { report(error) }
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

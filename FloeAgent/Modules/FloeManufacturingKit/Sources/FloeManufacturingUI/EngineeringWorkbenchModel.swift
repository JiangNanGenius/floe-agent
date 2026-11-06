// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeManufacturingCore
import FloeEngineeringCore

@MainActor @Observable final class EngineeringWorkbenchModel {
    var project:EngineeringAnalysisProject
    private(set) var artifact:EngineeringAnalysisArtifact?
    private(set) var busy = false
    private(set) var notice = ""
    private(set) var diagnostic = ""
    let directory:URL
    private let service = EngineeringAnalysisService()
    private var generation = UUID()
    private var work:Task<Void,Never>?
    init(directory:URL) { self.directory = directory;project = .demonstration() }
    func invalidate() { generation = UUID();work?.cancel();work = nil;busy = false;artifact = nil;notice = "";diagnostic = "" }
    func select(thermal:Bool) { invalidate();project = .demonstration(thermal:thermal) }
    func editStructural(_ body:(inout StructuralRequest)->Void) {
        guard case .structural(var value) = project.analysis else { return }
        invalidate();body(&value);project.analysis = .structural(value)
    }
    func editThermal(_ body:(inout ThermalRequest)->Void) {
        guard case .thermal(var value) = project.analysis else { return }
        invalidate();body(&value);project.analysis = .thermal(value)
    }
    func calculate() {
        guard !busy else { return };invalidate();busy = true
        let input = project,token = generation,service = service
        work = Task { [weak self] in
            do {
                let value = try await service.calculate(input)
                guard let self,self.generation == token,!Task.isCancelled,value.inputSHA256 == (try ResearchArchive.digest(self.project)) else { return }
                self.artifact = value;self.busy = false;self.work = nil;self.notice = L("计算完成","Calculation completed")
            } catch {
                guard let self,self.generation == token else { return }
                self.busy = false;self.work = nil;self.report(error)
            }
        }
    }
    func cancel() { invalidate();notice = L("已取消","Cancelled") }
    func save() {
        do {
            guard let artifact else { return }
            try EngineeringAnalysisArchive.save(project:project,artifact:artifact,to:directory.appendingPathComponent("latest.floeanalysis"))
            notice = L("已保存分析","Analysis saved")
        } catch { report(error) }
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
                invalidate();project = input;artifact = result
            }
            notice = L("分析已加载","Analysis loaded")
        } catch { report(error) }
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
    func report(_ error:Error) { diagnostic = String(describing:error);notice = L("未能完成，当前配置已保留","Unable to complete; current configuration retained") }
}
#endif

// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeManufacturingCore

func L(_ zh: String, _ en: String) -> String { Locale.preferredLanguages.first?.hasPrefix("zh") == true ? zh : en }

@MainActor @Observable public final class ManufacturingModel {
    public enum State: Equatable { case prepared, running, cancelling, completed, cancelled, failed }
    public var study: ManufacturingStudy
    public private(set) var artifact: ManufacturingArtifact?
    public private(set) var state: State = .prepared
    public private(set) var progress = 0.0
    public private(set) var phase = ""
    public private(set) var notice = ""
    public private(set) var diagnostic = ""
    public var replay = 1.0
    public var showPaths = true
    public var showFixtures = true
    public var smoothStock = true
    public var showAssembly = true
    public var showReference = true
    public let directory: URL
    private let service: ManufacturingService
    private var generation = UUID()
    private var calculation: Task<Void,Never>?

    public init(directory: URL, service: ManufacturingService = .init()) {
        self.directory = directory; self.service = service
        study = .shaft(); study.name = L("阶梯轴","Stepped shaft")
        do {
            let draft = directory.appendingPathComponent("draft.json")
            let hasDraft = FileManager.default.fileExists(atPath: draft.path)
            if hasDraft {
                let data = try Data(contentsOf: draft)
                guard data.count <= 32_000_000 else { throw ManufacturingError.invalid("draft file budget") }
                let restored = try JSONDecoder().decode(ManufacturingStudy.self, from: data)
                try restored.validate(requireOperations: false)
                study = restored
            }
            let archive = directory.appendingPathComponent("latest.floemanufacturing")
            if FileManager.default.fileExists(atPath: archive.path) {
                let (saved, result) = try ManufacturingArchive.open(archive)
                if !hasDraft { study = saved }
                if try study.fingerprint() == saved.fingerprint() {
                    artifact = result; state = .completed; progress = 1
                }
            }
        } catch {
            diagnostic = error.localizedDescription
            notice = L("部分保存资料未能载入，请查看详情","Some saved data could not be loaded; see details")
        }
    }
    public func saveDraft() throws {
        try study.validate(requireOperations: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try study.encoded().write(to: directory.appendingPathComponent("draft.json"), options: .atomic)
    }
    public func replaceStudy(_ proposed: ManufacturingStudy, expectedFingerprint: String) throws {
        guard !isBusy else { throw ManufacturingError.invalid("calculation is running") }
        guard try study.fingerprint() == expectedFingerprint else { throw ManufacturingError.stale }
        try proposed.validate(requireOperations: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try proposed.encoded().write(to: directory.appendingPathComponent("draft.json"), options: .atomic)
        invalidate(); study = proposed
    }
    public func calculateAndWait() async throws -> ManufacturingArtifact {
        guard !isBusy else { throw ManufacturingError.invalid("calculation is running") }
        try saveDraft()
        calculate()
        await withTaskCancellationHandler { await calculation?.value } onCancel: {
            Task { @MainActor in self.cancel() }
        }
        try Task.checkCancellation()
        guard state == .completed, let artifact else {
            throw ManufacturingError.invalid(diagnostic.isEmpty ? status : diagnostic)
        }
        // A completed calculation is delivered only after its native archive
        // has been committed and read back, rather than a success string.
        try ManufacturingArchive.save(study: study, artifact: artifact, to: archiveURL)
        _ = try ManufacturingArchive.open(archiveURL)
        return artifact
    }
    public var isBusy: Bool { state == .running || state == .cancelling }
    public var archiveURL: URL { directory.appendingPathComponent("latest.floemanufacturing") }
    public var status: String {
        switch state {
        case .prepared: return L("准备就绪","Ready")
        case .running: return L("正在计算","Calculating")
        case .cancelling: return L("正在停止","Stopping")
        case .completed: return L("计算完成","Completed")
        case .cancelled: return L("已取消","Cancelled")
        case .failed: return L("未能完成计算","Unable to calculate")
        }
    }
    public func select(_ index: Int) {
        invalidate()
        switch index {
        case 8: study = .turnMillCAM(); study.name = L("单主轴车铣工序","Single-spindle turn-mill operations")
        case 7: study = .selectedTurning(); study.name = L("可选车削工序","Selected turning operations")
        case 6: study = .surfaceCAM(); study.name = L("曲面栅格","Surface raster")
        case 5: study = .featureCAM(); study.name = L("多工序方料","Multi-operation block")
        case 4: study = .cuttingSpeedExample(); study.name = L("恒线速车削","CSS turning")
        case 3: study = .holderInterference(); study.name = L("刀柄干涉例","Holder interference example")
        case 2: study = .fiveAxis(); study.name = L("A/C 五轴轨迹","A/C five-axis motion")
        default: study = .shaft(milled:index == 1); study.name = index == 1 ? L("车铣件","Turn-mill part") : L("阶梯轴","Stepped shaft")
        }
    }
    public func invalidate() {
        generation = UUID(); calculation?.cancel(); calculation = nil
        artifact = nil; state = .prepared; progress = 0; phase = ""; notice = ""; diagnostic = ""; replay = 1
    }
    public func calculate() {
        guard !isBusy else { return }
        generation = UUID(); let token = generation, frozen = study
        artifact = nil; state = .running; progress = 0; notice = ""; diagnostic = ""; replay = 1
        let service = self.service
        calculation = Task { [weak self] in
            do {
                let result = try await service.calculate(frozen) { [weak self] fraction,phase in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.state == .running else { return }
                        self.progress = max(self.progress,fraction); self.phase = phase
                    }
                }
                guard let self, self.generation == token, !Task.isCancelled,
                      result.inputSHA256 == (try self.study.fingerprint()) else { return }
                self.artifact = result; self.progress = 1; self.state = .completed; self.calculation = nil
                self.save()
            } catch {
                guard let self, self.generation == token else { return }
                if Task.isCancelled || (error as? ManufacturingError).map({ if case .cancelled = $0 { true } else { false } }) == true {
                    self.state = .cancelled
                } else { self.state = .failed; self.diagnostic = error.localizedDescription }
                self.calculation = nil
            }
        }
    }
    public func cancel() { guard isBusy else { return }; state = .cancelling; calculation?.cancel() }
    public func save() {
        do {
            guard let artifact, !isBusy else { return }
            try ManufacturingArchive.save(study:study,artifact:artifact,to:archiveURL)
            notice = L("已保存","Saved")
        } catch { diagnostic = error.localizedDescription; notice = L("保存未完成","Unable to save") }
    }
    public func reopen() {
        do { let (study,artifact) = try ManufacturingArchive.open(archiveURL); install(study,artifact); notice = L("已重新打开保存结果","Saved result reopened") }
        catch { diagnostic = error.localizedDescription; notice = L("无法打开文件","Unable to open file") }
    }
    public func load(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            if url.pathExtension.lowercased() == "json" {
                guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 32_000_000 else { throw ManufacturingError.invalid("input file budget") }
                let input = try JSONDecoder().decode(ManufacturingStudy.self,from:Data(contentsOf:url)); try input.validate(requireOperations:false)
                invalidate(); study = input; notice = L("工件已加载","Workpiece loaded")
            } else { let (input,output) = try ManufacturingArchive.open(url); install(input,output) }
        } catch { diagnostic = error.localizedDescription; notice = L("文件未加载，当前工件已保留","File not loaded; current workpiece retained") }
    }
    private func install(_ study: ManufacturingStudy, _ artifact: ManufacturingArtifact) {
        invalidate(); self.study = study; self.artifact = artifact; state = .completed; progress = 1
    }
    public func export(stl: Bool) throws -> URL {
        guard let artifact, artifact.inputSHA256 == (try study.fingerprint()) else { throw ManufacturingError.stale }
        let data = try (stl ? ManufacturingArchive.stl(artifact.result) : ManufacturingArchive.toolpath(artifact.result))
        let url = directory.appendingPathComponent(stl ? "remaining-stock.stl" : "toolpath.json")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try data.write(to:url,options:.atomic)
        notice = stl ? L("STL 已导出","STL exported") : L("刀路已导出","Toolpath exported")
        return url
    }
    public func exportStudy() throws -> URL {
        try study.validate(requireOperations:false)
        let url = directory.appendingPathComponent("manufacturing-study.json")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try study.encoded().write(to:url,options:.atomic)
        notice = L("工艺单已导出","Process sheet exported")
        return url
    }
    public func report(_ error: Error) { diagnostic = error.localizedDescription; notice = L("操作未完成，请查看详情","Unable to finish; see details") }
}
#endif

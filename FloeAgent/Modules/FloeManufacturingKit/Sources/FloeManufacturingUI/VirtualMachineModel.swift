// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeManufacturingCore

@MainActor @Observable final class VirtualMachineModel {
    var project:VirtualMachineProject { didSet { if project != oldValue { inputRevision += 1;invalidate() } } }
    private(set) var artifact:VirtualMachineArtifact?
    private(set) var snapshot:VirtualCellSnapshot?
    private(set) var scene:VirtualScene?
    private(set) var currentCollision:VirtualPoseCollision?
    private(set) var busy = false
    private(set) var checking = false
    private(set) var progress = 0.0
    private(set) var seconds = 0.0
    private(set) var playing = false
    private(set) var notice = ""
    private(set) var diagnostic = ""
    var speed = 0.25
    private(set) var generation = UUID()
    private(set) var inputRevision = 0
    private(set) var activeWorkerCount = 0
    private(set) var activePoseWorkerCount = 0
    private(set) var poseOperationID:UUID?
    private(set) var activeOperationID:UUID?
    private(set) var runState:ManufacturingResearchRunState = .prepared
    var operationLeaseProvider:(@MainActor () throws -> AnyObject)?
    private var seekGeneration = UUID()
    private(set) var work:Task<Void,Never>?
    private var playback:Task<Void,Never>?
    private var query:Task<Void,Never>?
    private var replay:VirtualCellReplay?
    private var reused:CellSimulationArtifact?
    private let directory:URL
    private let service = VirtualMachineService()
    init(project:VirtualMachineProject,directory:URL,cellArtifact:CellSimulationArtifact? = nil) {
        self.project = project;self.directory = directory;reused = cellArtifact
    }
    var duration:Double { artifact?.cellArtifact.schedule.totalSeconds ?? 0 }
    func invalidate() {
        stop();generation = UUID();seekGeneration = UUID();work?.cancel();work = nil;query?.cancel();query = nil
        busy = activeWorkerCount > 0 || activePoseWorkerCount > 0;checking = false;artifact = nil;snapshot = nil;scene = nil;replay = nil;currentCollision = nil;seconds = 0;progress = 0;runState = activeWorkerCount > 0 || activePoseWorkerCount > 0 ? .cancelling:.prepared
    }
    func calculate() {
        guard !busy,activeWorkerCount == 0,activePoseWorkerCount == 0 else { return }
        let storageLease:AnyObject?
        do { storageLease = try operationLeaseProvider?() } catch { report(error);return }
        invalidate();busy = true;notice = "";diagnostic = "";runState = .running
        let token = generation,input = project,service = service,reused = reused
        activeWorkerCount += 1;activeOperationID = token
        work = Task { [weak self] in
            let monitor = ManufacturingResearchOwnerMonitor.start(provider:self?.operationLeaseProvider,
                isCurrent:{ [weak self] in self?.generation == token && self?.busy == true },
                cancel:{ [weak self] in self?.cancel() })
            defer { monitor?.cancel();self?.finishWorker(token);withExtendedLifetime(storageLease) {} }
            do {
                let compatible = reused?.inputSHA256 == (try input.cellDigest()) ? reused : nil
                let value = try await service.calculate(input,reusing:compatible) { [weak self] fraction,_ in
                    Task { @MainActor [weak self] in
                        guard let self,self.generation == token,self.busy else { return };self.progress = max(self.progress,fraction)
                    }
                }
                guard let self,self.generation == token,!Task.isCancelled else { return }
                try self.install(value);self.busy = false;self.work = nil;self.runState = .completed;self.notice = L("虚拟主轴已准备好","Virtual spindles are ready")
            } catch {
                guard let self,self.generation == token else { return };self.busy = false;self.work = nil;self.runState = Task.isCancelled ? .cancelled:.failed;self.report(error)
            }
        }
    }
    private func install(_ value:VirtualMachineArtifact) throws {
        let playback = try VirtualCellReplay(project:project.cell,artifact:value.cellArtifact)
        artifact = value;reused = value.cellArtifact;replay = playback;progress = 1;seek(0)
    }
    func seek(_ value:Double) {
        guard let artifact,let replay else { return }
        guard value.isFinite else { report(ManufacturingError.invalid("virtual replay time"));return }
        query?.cancel();query = nil;checking = false;seekGeneration = UUID();currentCollision = nil
        do {
            let time = max(0,min(duration,value)),snapshot = try replay.snapshot(at:time)
            scene = try VirtualMachineSceneBuilder.build(configuration:project.scene,project:project.cell,artifact:artifact.cellArtifact,snapshot:snapshot)
            self.snapshot = snapshot;seconds = time
            if let result = artifact.collisions.first(where:{ abs($0.seconds-time)<1e-8 }) { currentCollision = result }
        } catch { stop();report(error) }
    }
    func play() {
        guard !playing,replay != nil,duration>0 else { return }
        if seconds>=duration { seek(0) };playing = true
        let clock = ContinuousClock(),start = clock.now,initial = seconds
        playback = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,self.playing else { return }
                let elapsed = start.duration(to:clock.now).components
                let t = initial+(Double(elapsed.seconds)+Double(elapsed.attoseconds)*1e-18)*self.speed
                self.seek(t)
                if self.seconds>=self.duration { self.stop();return }
                do { try await clock.sleep(for:.milliseconds(80)) } catch { return }
            }
        }
    }
    func stop() { playing = false;playback?.cancel();playback = nil }
    func cancel() { invalidate();runState = activeWorkerCount > 0 || activePoseWorkerCount > 0 ? .cancelling:.cancelled;notice = activeWorkerCount > 0 || activePoseWorkerCount > 0 ? L("正在停止","Stopping"):L("已取消","Cancelled") }
    func checkPose() {
        guard let scene,let snapshot,!checking,!busy,activePoseWorkerCount == 0 else { return }
        let storageLease:AnyObject?
        do { storageLease = try operationLeaseProvider?() } catch { report(error);return }
        stop();checking = true
        let token = generation,seek = seekGeneration,clearance = project.scene.clearanceMM,time = seconds,total = duration,operation = UUID()
        activePoseWorkerCount += 1;poseOperationID = operation
        query = Task { [weak self] in
            let monitor = ManufacturingResearchOwnerMonitor.start(provider:self?.operationLeaseProvider,
                isCurrent:{ [weak self] in self?.generation == token && self?.seekGeneration == seek && self?.checking == true },
                cancel:{ [weak self] in self?.cancel() })
            defer { monitor?.cancel();self?.finishPose(operation);withExtendedLifetime(storageLease) {} }
            do {
                let control = ComputationControl()
                let feedback = try await withTaskCancellationHandler {
                    try await Task.detached(priority:.userInitiated) {
                        try Task.checkCancellation()
                        let request = try scene.queryRequest(clearanceMM:clearance),result = try NativeManufacturingEngine().machineQuery(request,control:control)
                        try Task.checkCancellation()
                        return VirtualPoseCollision(fraction:total>0 ? time/total : 0,seconds:time,requestSHA256:try ResearchArchive.digest(request),result:result,
                            verdict:VirtualMachineEngine.verdict(result,scene:scene,snapshot:snapshot))
                    }.value
                } onCancel:{ control.cancel() }
                guard let self,self.generation == token,self.seekGeneration == seek,!Task.isCancelled else { return }
                self.checking = false;self.query = nil;self.currentCollision = feedback
            } catch { guard let self,self.generation == token,self.seekGeneration == seek else { return };self.checking = false;self.query = nil;self.report(error) }
        }
    }
    func save() { do { try saveResult() } catch { report(error) } }
    func saveResult() throws {
        let lease = try operationLeaseProvider?();defer { withExtendedLifetime(lease) {} }
        guard !busy,let artifact else { throw ManufacturingError.invalid("No completed virtual machine result") }
        try artifact.validate(for:project)
        try VirtualMachineArchive.save(project:project,artifact:artifact,to:directory.appendingPathComponent("latest.floetwin"))
        notice = L("已保存虚拟主轴研究","Virtual spindle study saved")
    }
    func load(_ url:URL) {
        let access = url.startAccessingSecurityScopedResource();defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            if url.pathExtension.lowercased() == "json" {
                let input = try ResearchArchive.openInput(url,as:VirtualMachineProject.self);try input.validate();invalidate();project = input;reused = nil
            } else {
                let (input,result) = try VirtualMachineArchive.open(url);invalidate();project = input;try install(result);runState = .completed
            }
            notice = L("虚拟主轴研究已打开","Virtual spindle study opened")
        } catch { report(error) }
    }
    func reopen() { load(directory.appendingPathComponent("latest.floetwin")) }
    func adoptSaved(project:VirtualMachineProject,artifact:VirtualMachineArtifact?) throws {
        guard !busy else { throw ManufacturingError.stale }
        try project.validate();if let artifact { try artifact.validate(for:project) }
        invalidate();self.project = project
        if let artifact { try install(artifact);runState = .completed }
    }
    func export(input:Bool) throws -> URL {
        let url = directory.appendingPathComponent(input ? "virtual-machine-input.json" : "virtual-machine-result.json")
        if input { try project.validate();try ResearchArchive.saveInput(project,to:url) }
        else { guard let artifact,artifact.inputSHA256 == (try ResearchArchive.digest(project)) else { throw ManufacturingError.stale };try ResearchArchive.saveInput(artifact,to:url) }
        return url
    }
    private func finishPose(_ operation:UUID) {
        activePoseWorkerCount = max(0,activePoseWorkerCount-1)
        if activePoseWorkerCount == 0,poseOperationID == operation {
            poseOperationID = nil
            if activeWorkerCount == 0,runState == .cancelling { busy = false;query = nil;runState = .cancelled;notice = L("已取消","Cancelled") }
        }
    }
    private func finishWorker(_ operation:UUID) {
        activeWorkerCount = max(0,activeWorkerCount-1)
        if activeWorkerCount == 0,activeOperationID == operation {
            activeOperationID = nil
            if runState == .cancelling { busy = false;work = nil;runState = .cancelled;notice = L("已取消","Cancelled") }
        }
    }
    func report(_ error:Error) { diagnostic = error.localizedDescription;notice = L("未能完成，当前设置已保留","Unable to complete; current setup retained") }
}
private extension VirtualMachineProject {
    func cellDigest() throws -> String { try ResearchArchive.digest(cell) }
}
#endif

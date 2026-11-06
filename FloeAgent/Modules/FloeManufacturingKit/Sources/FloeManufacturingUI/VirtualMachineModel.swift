// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeManufacturingCore

@MainActor @Observable final class VirtualMachineModel {
    var project:VirtualMachineProject
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
    private var generation = UUID()
    private var seekGeneration = UUID()
    private var work:Task<Void,Never>?
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
        busy = false;checking = false;artifact = nil;snapshot = nil;scene = nil;replay = nil;currentCollision = nil;seconds = 0;progress = 0
    }
    func calculate() {
        guard !busy else { return };invalidate();busy = true;notice = "";diagnostic = ""
        let token = generation,input = project,service = service,reused = reused
        work = Task { [weak self] in
            do {
                let compatible = reused?.inputSHA256 == (try input.cellDigest()) ? reused : nil
                let value = try await service.calculate(input,reusing:compatible) { [weak self] fraction,_ in
                    Task { @MainActor [weak self] in
                        guard let self,self.generation == token,self.busy else { return };self.progress = max(self.progress,fraction)
                    }
                }
                guard let self,self.generation == token,!Task.isCancelled else { return }
                try self.install(value);self.busy = false;self.work = nil;self.notice = L("虚拟主轴已准备好","Virtual spindles are ready")
            } catch {
                guard let self,self.generation == token else { return };self.busy = false;self.work = nil;self.report(error)
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
    func cancel() { invalidate();notice = L("已取消","Cancelled") }
    func checkPose() {
        guard let scene,let snapshot,!checking else { return };stop();checking = true
        let token = generation,seek = seekGeneration,clearance = project.scene.clearanceMM,time = seconds,total = duration
        query = Task { [weak self] in
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
    func save() {
        do { guard let artifact else { return };try VirtualMachineArchive.save(project:project,artifact:artifact,to:directory.appendingPathComponent("latest.floetwin"));notice = L("已保存虚拟主轴研究","Virtual spindle study saved") }
        catch { report(error) }
    }
    func load(_ url:URL) {
        let access = url.startAccessingSecurityScopedResource();defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            if url.pathExtension.lowercased() == "json" {
                let input = try ResearchArchive.openInput(url,as:VirtualMachineProject.self);try input.validate();invalidate();project = input;reused = nil
            } else {
                let (input,result) = try VirtualMachineArchive.open(url);invalidate();project = input;try install(result)
            }
            notice = L("虚拟主轴研究已打开","Virtual spindle study opened")
        } catch { report(error) }
    }
    func reopen() { load(directory.appendingPathComponent("latest.floetwin")) }
    func export(input:Bool) throws -> URL {
        let url = directory.appendingPathComponent(input ? "virtual-machine-input.json" : "virtual-machine-result.json")
        if input { try project.validate();try ResearchArchive.saveInput(project,to:url) }
        else { guard let artifact,artifact.inputSHA256 == (try ResearchArchive.digest(project)) else { throw ManufacturingError.stale };try ResearchArchive.saveInput(artifact,to:url) }
        return url
    }
    func report(_ error:Error) { diagnostic = error.localizedDescription;notice = L("未能完成，当前设置已保留","Unable to complete; current setup retained") }
}
private extension VirtualMachineProject {
    func cellDigest() throws -> String { try ResearchArchive.digest(cell) }
}
#endif

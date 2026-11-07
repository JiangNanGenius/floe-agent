// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeManufacturingCore

@MainActor @Observable final class CAMPreviewModel {
    let source:CAMPreviewSource
    let directory:URL
    private(set) var program:CAMPreviewProgram?
    private(set) var frame:CAMPreviewFrame?
    private(set) var preparing = false
    private(set) var playing = false
    private(set) var rendering = false
    private(set) var diagnostic = ""
    private(set) var notice = ""
    private(set) var savedURL:URL?
    private(set) var fileBusy = false
    var settings = CAMPreviewSettings()
    var cameraRevision = UUID()
    private var generation = UUID()
    private var work:Task<Void,Never>?
    private var playback:Task<Void,Never>?
    private var fileWork:Task<Void,Never>?
    private var renderWork:Task<Void,Never>?
    private var renderControl:ComputationControl?
    private var pendingFrame:(id:UUID,position:Double)?
    private var requestedFrame = UUID()
    private var collisionPaused = false
    init(source:CAMPreviewSource,directory:URL) { self.source = source;self.directory = directory }
    var range:ClosedRange<Double> {
        if settings.selectedOnly,let chapter = selectedChapter,let a = chapter.start,let b = chapter.end,b>a { return a...b }
        return 0...(program?.extent ?? 0)
    }
    var selectedChapter:CAMPreviewChapter? { program?.chapters.first { $0.id == settings.selectedChapterID } }
    var operationInspection:CAMOperationInspection? {
        guard let id = settings.selectedChapterID ?? frame?.activeChapterIDs.first else { return nil }
        return program?.inspection(forChapterID:id)
    }
    var timed:Bool { program?.metric == .seconds }
    func setDisplayScope(_ scope:CAMDisplayScope) { settings.applyScope(scope);cameraRevision = UUID() }
    func reportSelectionBudget() { notice = L("刀路较多，请先在工序列表中缩小显示范围。","Many toolpaths are visible. Narrow the display using the operation list, then select a path.") }
    func prepare(autoplay:Bool = false,initialOperationID:String? = nil,viewState:Data? = nil) {
        guard !preparing,program == nil else { return };preparing = true;diagnostic = ""
        let token = generation,source = source,control = ComputationControl()
        work = Task { [weak self] in
            do {
                let program = try await withTaskCancellationHandler {
                    try await Task.detached(priority:.userInitiated) { try CAMPreviewProgram(source:source,control:control) }.value
                } onCancel:{ control.cancel() }
                guard let self,self.generation == token,!Task.isCancelled else { return }
                self.program = program;self.preparing = false;self.work = nil
                do { try self.restore(viewState) } catch { self.report(error) }
                self.seek(self.settings.position);self.cameraRevision = UUID()
                if let initialOperationID,let chapter = program.chapters.first(where:{ $0.id.hasSuffix(":"+initialOperationID) }) { self.select(chapter.id) }
                if autoplay { self.play() }
            } catch {
                guard let self,self.generation == token,!Task.isCancelled else { return }
                self.preparing = false;self.work = nil;self.report(error)
            }
        }
    }
    func seek(_ value:Double) {
        guard program != nil,value.isFinite else { return }
        let position = max(range.lowerBound,min(range.upperBound,value))
        requestedFrame = UUID();pendingFrame = (requestedFrame,position)
        renderControl?.cancel()
        // One native render runs at a time. Rapid scrubbing coalesces to the
        // latest cursor instead of queuing detached native jobs without a cap.
        guard renderWork == nil else { return }
        rendering = true;let token = generation
        renderWork = Task { [weak self] in
            guard let self else { return }
            while let request = self.pendingFrame,self.generation == token,!Task.isCancelled {
                self.pendingFrame = nil
                guard let program = self.program else { break }
                let control = ComputationControl(),chapter = self.selectedChapter,selectedOnly = self.settings.selectedOnly,range = self.range
                self.renderControl = control
                do {
                    let value = try await withTaskCancellationHandler {
                        try await Task.detached(priority:.userInitiated) {
                            var value = try program.frame(at:request.position,control:control)
                            if selectedOnly,let chapter,chapter.kind != "machine",request.position == range.upperBound,range.upperBound>range.lowerBound {
                                let before = try program.frame(at:max(range.lowerBound,request.position.nextDown),control:control),group = "tool:"+chapter.jobID
                                value.scene.bodies.removeAll { $0.groupID == group }
                                value.scene.bodies += before.scene.bodies.filter { $0.groupID == group }
                                value.tools.removeAll { $0.id == chapter.jobID };value.tools += before.tools.filter { $0.id == chapter.jobID }
                                value.activeChapterIDs.removeAll { id in program.chapters.contains { $0.id == id && $0.jobID == chapter.jobID } }
                                value.activeChapterIDs.append(chapter.id)
                            }
                            return value
                        }.value
                    } onCancel:{ control.cancel() }
                    guard self.generation == token,!Task.isCancelled else { break }
                    if request.id == self.requestedFrame {
                        let previous = Set((self.frame?.collisions ?? []).filter { ["intersecting","clearance"].contains($0.state) }.map(Self.collisionKey))
                        let newContact = value.collisions.contains { ["intersecting","clearance"].contains($0.state) && !previous.contains(Self.collisionKey($0)) }
                        self.frame = value;self.settings.position = request.position
                        if self.playing,self.settings.stopOnCollision,newContact {
                            self.stop();self.collisionPaused = true
                            self.notice = L("检测到干涉或间隙不足，已暂停。请查看检查详情。","Paused for interference or insufficient clearance. Review the check details.")
                        }
                    }
                } catch {
                    guard self.generation == token,!Task.isCancelled else { break }
                    if !control.isCancelled && request.id == self.requestedFrame { self.stop();self.report(error) }
                }
            }
            guard self.generation == token else { return }
            self.renderWork = nil;self.renderControl = nil;self.rendering = false
        }
    }
    func scrub(_ value:Double) { stop();seek(value) }
    func select(_ id:String?) {
        stop();settings.selectedChapterID = id
        if let chapter = selectedChapter,let start = chapter.start { seek(start) }
        else if id == nil { settings.selectedOnly = false;seek(0) }
    }
    func changeScope() {
        stop();seek(max(range.lowerBound,min(range.upperBound,settings.position)))
    }
    func step(forward:Bool) {
        stop();guard let program else { return }
        seek(program.nextBoundary(from:settings.position,forward:forward,within:range))
    }
    func play() {
        guard let program,!playing,range.upperBound>range.lowerBound else { return }
        if collisionPaused { collisionPaused = false;notice = "" }
        playing = true
        playback = Task { [weak self] in
            guard let self else { return }
            // Preparing/rewinding stock is asynchronous. Do not advance an
            // old end cursor while its replacement frame is still in flight.
            if self.settings.position >= self.range.upperBound { self.seek(self.range.lowerBound) }
            await self.renderWork?.value
            guard self.playing,!Task.isCancelled else { return }
            let clock = ContinuousClock();var last = clock.now
            while !Task.isCancelled {
                do { try await clock.sleep(for:.milliseconds(40)) } catch { return }
                guard self.playing else { return }
                let now = clock.now,delta = last.duration(to:now).components
                last = now
                let elapsed = Double(delta.seconds)+Double(delta.attoseconds)*1e-18
                // Untimed geometry traverses at a clearly marked viewing rate.
                // It is never labelled as machining seconds or feed simulation.
                let rate = program.metric == .seconds ? 1 : max(program.extent/30,0.001)
                self.seek(self.settings.position+elapsed*self.settings.speed*rate)
                await self.renderWork?.value
                guard self.playing,!Task.isCancelled else { return }
                if self.settings.position>=self.range.upperBound { self.stop();return }
            }
        }
    }
    func stop() { playing = false;playback?.cancel();playback = nil }
    private static func collisionKey(_ value:ManufacturingResult.Collision)->String { [value.component,value.toolPart ?? "",value.targetKind ?? "",value.operation ?? "",value.state].joined(separator:"|") }
    func close() { stop();persist();generation = UUID();work?.cancel();work = nil;fileWork?.cancel();fileWork = nil;renderControl?.cancel();renderWork?.cancel();renderWork = nil;pendingFrame = nil;rendering = false;fileBusy = false;preparing = false }
    func persist() {
        guard let program else { return }
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let data = try ManufacturingStudy.encoder.encode(settings)
            try data.write(to:stateURL(program.sourceKey),options:.atomic)
        } catch { report(error) }
    }
    private func restore(_ supplied:Data?) throws {
        guard let program else { return }
        let url = stateURL(program.sourceKey)
        guard supplied != nil || FileManager.default.fileExists(atPath:url.path) else { return }
            let data:Data
            if let supplied { data = supplied }
            else {
                guard try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max <= 32_768 else { throw ManufacturingError.archive("preview cursor byte budget") }
                data = try Data(contentsOf:url)
            }
            guard data.count <= 32_768 else { throw ManufacturingError.archive("preview cursor byte budget") }
            let saved = try JSONDecoder().decode(CAMPreviewSettings.self,from:data)
            guard saved.position.isFinite,saved.speed.isFinite,[0.05,0.25,1,5,20].contains(saved.speed),saved.selectedChapterID == nil || program.chapters.contains(where:{ $0.id == saved.selectedChapterID }) else { throw ManufacturingError.stale }
            settings = saved
    }
    func save() {
        stop();guard let program,!fileBusy else { return };persist()
        let token = generation,source = source,url = directory.appendingPathComponent("preview-"+program.sourceKey+".floepreview"),settings = settings,control = ComputationControl()
        fileBusy = true;notice = L("正在保存仿真…","Saving simulation…")
        fileWork = Task { [weak self] in
            do {
                try await withTaskCancellationHandler {
                    try await Task.detached(priority:.userInitiated) { try CAMPreviewArchive.save(source:source,viewState:ManufacturingStudy.encoder.encode(settings),to:url,control:control) }.value
                } onCancel:{ control.cancel() }
                guard let self,self.generation == token,!Task.isCancelled else { return }
                self.savedURL = url;self.fileBusy = false;self.fileWork = nil;self.notice = L("工件、刀路和预览位置已保存","Workpiece, toolpaths and preview position saved")
            } catch {
                guard let self,self.generation == token,!Task.isCancelled else { return };self.fileBusy = false;self.fileWork = nil;self.diagnostic = error.localizedDescription;self.notice = L("保存未完成，当前预览已保留","Unable to save; current preview retained")
            }
        }
    }
    func reopen() {
        stop();guard let program,!fileBusy else { return }
        let token = generation,key = program.sourceKey,url = directory.appendingPathComponent("preview-"+program.sourceKey+".floepreview")
        fileBusy = true;notice = L("正在打开仿真…","Opening simulation…")
        fileWork = Task { [weak self] in
            do {
                let value = try await Task.detached(priority:.userInitiated) {
                    let value = try CAMPreviewArchive.open(url)
                    guard try CAMPreviewProgram(source:value.source).sourceKey == key else { throw ManufacturingError.stale }
                    return value
                }.value
                guard let self,self.generation == token,!Task.isCancelled else { return }
                try self.restore(value.viewState);self.seek(self.settings.position);self.savedURL = url
                self.fileBusy = false;self.fileWork = nil;self.notice = L("已重新打开保存的仿真","Saved simulation reopened")
            } catch {
                guard let self,self.generation == token,!Task.isCancelled else { return };self.fileBusy = false;self.fileWork = nil;self.report(error)
            }
        }
    }
    private func stateURL(_ key:String)->URL { directory.appendingPathComponent("preview-"+key+".json") }
    func report(_ error:Error) { diagnostic = error.localizedDescription;notice = L("无法打开预览，请检查计算结果","Unable to open preview; check the calculation result") }
}
#endif

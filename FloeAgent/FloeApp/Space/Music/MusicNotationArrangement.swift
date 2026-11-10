// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeCore
import FloeHeavyEditorSupport
import FloeMusicCore
import FloeMusicNative
import FloeTools

nonisolated struct MusicNotationArrangementReceipt: Codable, Sendable {
    let operationID: UUID
    let projectID: UUID
    let scoreRevision: UInt64
    let baseMusicRevision: Int64
    let musicRevision: Int64
    let positionSeconds: Double
    let frames: Int64
    let sampleRate: Int
    let assetID: String
    let trackIDs: [String]
    let clipIDs: [String]
    let fileID: String
    let name: String
    let byteCount: Int
    let sha256: String
    func json() throws -> EditorJSON { try EditorJSON.decode(JSONEncoder().encode(self)) }
    func fileReceipt() -> EditorJSON {
        .object(["fileID": .string(fileID), "name": .string(name), "byteCount": .number(Double(byteCount)), "sha256": .string(sha256)])
    }
}

private nonisolated final class NotationRenderProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    func admit(_ frames: Int64, total: Int64) -> Bool {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            guard frames >= total || now - last >= 0.1 else { return false }
            last = now; return true
        }
    }
}

/// The same music renderer/preset resolver used by ordinary score playback.
/// One native invocation owns render/cancel/import; view reconstruction does
/// not stop it and an older invocation cannot cancel another operation.
@MainActor @Observable final class MusicNotationArrangement {
    enum Phase: Sendable, Equatable { case idle, rendering, adding, completed, cancelling, cancelled, failed }
    private weak var parent: MusicProjectSession?
    private(set) var phase = Phase.idle
    private(set) var progress = 0.0
    private(set) var message: String?
    private(set) var recoverableWAV: URL?
    private(set) var lastReceipt: MusicNotationArrangementReceipt?
    @ObservationIgnored private var invocation: UUID?
    @ObservationIgnored private var task: Task<MusicNotationArrangementReceipt, any Error>?
    @ObservationIgnored private var lease: MusicRenderLease?
    @ObservationIgnored private var cancellation: CancellationToken?
    @ObservationIgnored private var files: [String: URL] = [:]
    @ObservationIgnored private var receipts: [String: MusicNotationArrangementReceipt] = [:]
    var isBusy: Bool { task != nil }
    init(parent: MusicProjectSession) { self.parent = parent }

    func cancel(invocation expected: UUID? = nil) {
        guard task != nil, expected == nil || invocation == expected else { return }
        phase = .cancelling
        cancellation?.cancel(); lease?.invalidate(); task?.cancel()
        // Admission remains occupied until its owned worker actually settles.
    }
    func receipt(_ fileID: String) -> MusicNotationArrangementReceipt? { receipts[fileID] }
    func fileURL(_ fileID: String) throws -> URL {
        guard let file = files[fileID] else { throw PersonalContentError.missingDocument }
        _ = try MusicNotationPackage.regularData(file, maximum: 128 * 1024 * 1024)
        return file
    }

    func run(performance: EditorJSON, scoreRevision: UInt64, musicRevision: Int64,
             positionSeconds: Double, invocation id: UUID,
             validate: @escaping @MainActor @Sendable () async throws -> Void) async throws -> MusicNotationArrangementReceipt {
        guard task == nil, let parent, parent.document.revision == musicRevision,
              !parent.saving, !parent.notationRestoring, !parent.notationImporting,
              !parent.isRecording, !parent.isMIDIRecording, !parent.djCaptureBusy,
              positionSeconds.isFinite, positionSeconds >= 0 else { throw PersonalFileActionError.busy }
        let original = parent.document
        let projected = try MusicNotationPerformance.document(performance, parent: original)
        guard projected.tracks.contains(where: { $0.clips.contains(where: { clip in
            if case .midi(let notes) = clip.body { return !notes.notes.isEmpty }; return false
        }) }) else {
            throw HeavyEditorError.engine(WorkbenchText.t("请先添加音符，或取消所有声部的静音。", "Add notes or unmute a part before performing."))
        }
        let end = try projected.tracks.flatMap(\.clips).map { try $0.endSample(tempoMap: projected.tempoMap).value }.max() ?? 0
        let release = projected.tracks.compactMap { $0.instrument }.compactMap { MusicPresetCatalog.preset(index: $0.presetIndex)?.parameters["release"] }.max() ?? 0
        let tail = Int64((release * Double(projected.tempoMap.sampleRate)).rounded(.up))
        let (totalFrames, overflow) = end.addingReportingOverflow(tail)
        // Keep the existing native audio-import limit honest, before rendering
        // an output that could never be committed by that same service.
        guard !overflow, totalFrames > 0, totalFrames <= (128 * 1024 * 1024 - 65_536) / 8 else {
            throw HeavyEditorError.engine(WorkbenchText.t("这段演奏超过当前音频导入的大小限制，请缩短后重试。", "This performance exceeds the audio import size limit. Shorten it and try again."))
        }
        let token = CancellationToken()
        let renderLease = try MusicRenderLease(document: projected, ownerToken: parent.notationOwnerToken)
        invocation = id; cancellation = token; lease = renderLease
        phase = .rendering; progress = 0; message = nil; recoverableWAV = nil; lastReceipt = nil
        let renderer = parent.notationRenderer, progressGate = NotationRenderProgressGate()
        let worker = Task { @MainActor [self, parent] in
            let use = try PersonalLibraryFileActions.acquireUse(id: parent.id, directory: parent.root.deletingLastPathComponent())
            defer { use.release() }
            try await validate(); try token.throwIfCancelled(); try Task.checkCancellation()
            guard parent.document.revision == musicRevision else { throw MusicError.staleRevision(expected: musicRevision, actual: parent.document.revision) }
            let directory = parent.root.appendingPathComponent("Exports/NotationPerformances", isDirectory: true)
                .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            guard !FileManager.default.fileExists(atPath: directory.path) else { throw PersonalContentError.changedDocument }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(WorkbenchText.t("乐谱演奏.wav", "Score performance.wav"))
            let rendered = try await renderer.render(document: projected, sources: [], destination: destination, lease: renderLease,
                tailFrames: tail, onProgress: { [weak self] frames in
                    guard progressGate.admit(frames, total: totalFrames) else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.invocation == id, self.phase == .rendering else { return }
                        self.progress = min(1, Double(frames) / Double(totalFrames))
                    }
                })
            // A complete WAV is a recoverable result, even if the score,
            // arrangement, task authorization or cancellation changed meanwhile.
            // Verify the completed native result off the UI actor. The
            // bounded hash itself finishes even after late cancellation so a
            // complete WAV can be surfaced before the commit fence refuses it.
            let actualSHA256 = try await personalPreviewOffMain { try MusicAudioPreparation.hashFile(destination) }
            guard rendered.frames == totalFrames, rendered.sampleRate == original.tempoMap.sampleRate,
                  rendered.sha256 == actualSHA256 else { throw HeavyEditorError.invalidDocument }
            let bytes = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes > 0, bytes <= 128 * 1024 * 1024 else { throw HeavyEditorError.invalidDocument }
            recoverableWAV = destination
            parent.registerNotationExport(destination)
            try JSONEncoder().encode(rendered).write(to: directory.appendingPathComponent("RENDERED.json"), options: .withoutOverwriting)
            try await validate(); try token.throwIfCancelled(); try Task.checkCancellation()
            guard parent.document.revision == musicRevision else { throw MusicError.staleRevision(expected: musicRevision, actual: parent.document.revision) }
            phase = .adding; progress = 1
            let imported = try await parent.importAuthorizedFile(destination, sourceRoot: parent.root,
                sourceReference: "score-performance:\(parent.id.uuidString.lowercased()):\(id.uuidString.lowercased())",
                provenance: "Score revision \(scoreRevision); native performance; arrangement revision \(musicRevision)",
                expectedRevision: musicRevision, expectedSHA256: rendered.sha256, cancellation: token,
                offsetSeconds: positionSeconds, validateSource: validate)
            // The actual store commit is decisive: do not relabel an imported
            // track as cancelled because a late UI/notification callback stopped.
            let fileID = "music:\(parent.id.uuidString.lowercased()):notation-performance:\(id.uuidString.lowercased())"
            let receipt = MusicNotationArrangementReceipt(operationID: id, projectID: parent.id, scoreRevision: scoreRevision,
                baseMusicRevision: musicRevision, musicRevision: imported.revision, positionSeconds: positionSeconds,
                frames: rendered.frames, sampleRate: rendered.sampleRate, assetID: imported.asset.id.rawValue,
                trackIDs: imported.trackIDs.map(\.rawValue), clipIDs: imported.clipIDs.map(\.rawValue),
                fileID: fileID, name: destination.lastPathComponent, byteCount: bytes, sha256: rendered.sha256)
            files[fileID] = destination; receipts[fileID] = receipt; lastReceipt = receipt; recoverableWAV = nil; phase = .completed
            do { try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent("ADDED.json"), options: .withoutOverwriting) }
            catch { message = WorkbenchText.t("已加入编曲，演奏记录暂未更新。", "Added to the arrangement; its performance record could not be updated.") }
            return receipt
        }
        task = worker
        defer {
            if invocation == id { task = nil; lease = nil; cancellation = nil; invocation = nil }
        }
        do {
            return try await withTaskCancellationHandler { try await worker.value } onCancel: { token.cancel(); worker.cancel() }
        } catch {
            if invocation == id {
                phase = token.isCancelled || error is CancellationError ? .cancelled : .failed
                if recoverableWAV != nil {
                    message = WorkbenchText.t("演奏音频已保留，尚未加入编曲。请查看当前编曲后重试。", "The performed audio is kept but was not added. Check the current arrangement before trying again.")
                } else if phase != .cancelled { message = error.localizedDescription }
            }
            throw error
        }
    }
}
#endif

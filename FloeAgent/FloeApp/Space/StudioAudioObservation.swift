// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import GRDB
import FloeCore
import FloeTools
import FloeMusicCore
import FloeWorkbench
import FloeMedia
import FloeMeetings
import FloeMeetingsAV

nonisolated struct StudioAudioSourceDescriptor: Codable, Hashable, Sendable {
    let sourceID: String
    let kind: String
    let title: String
    let revision: String
    /// Registered/stopped identifies native metadata, not decoded audio.
    /// Silent videos/no-audio tracks remain real decoder errors on inspect.
    let state: String
}
nonisolated struct StudioAudioSourcePage: Encodable, Sendable {
    let kind = "sources"
    let projectID: UUID
    let sources: [StudioAudioSourceDescriptor]
    let total: Int
    let nextOffset: Int?
}
nonisolated struct StudioAudioSourceDiscovery: Encodable, Sendable {
    let status: String
    let page: StudioAudioSourcePage?
    let unavailableReason: String?
}
nonisolated struct StudioAudioObservationReceipt: Encodable, Sendable {
    let kind = "waveform"
    let projectID: UUID
    /// Existing Music numeric revision/assetID fields remain compatible.
    /// Meeting has no document counter; source.revision binds its recording.
    let revision: Int64?
    let assetID: MusicAssetID?
    let source: StudioAudioSourceDescriptor
    let audioObservation: AudioWaveformInspection
}

/// Native original observation only. All callers first resolve the real
/// Studio location and retain its existing PersonalLibraryUsageLease. Neither
/// an opaque sourceID nor a model assetID is authority or a host path.
@MainActor enum StudioAudioObservation {
    private enum NativeSource: Sendable {
        case music(MusicAsset, Int64)
        case media(MediaAssetReference, Int64)
        case meeting(CaptureSessionSnapshot)
    }
    private struct Entry: Sendable { let descriptor: StudioAudioSourceDescriptor; let source: NativeSource }
    private struct Located: Sendable {
        let file: PersonalPreviewFile
        let expectedSHA256: String?
        let revision: Int64?
        let legacyAssetID: MusicAssetID?
    }

    static func sources(record: PersonalContentRecord, directory: URL, offset: Int = 0, limit: Int = 16) async throws -> StudioAudioSourcePage {
        guard offset >= 0, (1...64).contains(limit) else { throw FloeError.validationFailed("Audio source page bounds") }
        let entries = try await entries(record: record, directory: directory)
        guard offset <= entries.count else { throw FloeError.validationFailed("Audio source offset exceeds this work") }
        let end = min(entries.count, offset + limit)
        return .init(projectID: record.id, sources: entries[offset..<end].map(\.descriptor), total: entries.count,
                     nextOffset: end < entries.count ? end : nil)
    }

    static func discovery(record: PersonalContentRecord, directory: URL, context: ToolContext) async throws -> StudioAudioSourceDiscovery? {
        guard [.music, .meeting, .image, .drawing, .video].contains(record.kind) else { return nil }
        try context.cancellation.throwIfCancelled()
        do {
            let page = try await sources(record: record, directory: directory)
            try context.cancellation.throwIfCancelled()
            return .init(status: "available", page: page, unavailableReason: nil)
        } catch {
            try context.cancellation.throwIfCancelled()
            if error is CancellationError { throw error }
            // A source-inventory failure must not make the rest of the native
            // work unreadable or masquerade as an empty/decoded audio set.
            return .init(status: "unavailable", page: nil,
                unavailableReason: "Audio sources could not be listed. inspectAudio with {} retries the inventory and returns the actual source error; no waveform was measured.")
        }
    }

    static func inspect(record: PersonalContentRecord, directory: URL, input: StudioAudioInspectInput,
                        context: ToolContext, validateProject: @escaping @MainActor @Sendable () async throws -> Void) async throws -> ToolExecutionOutput {
        guard !context.temporaryReadOnly else { throw FloeError.validationFailed("Temporary chat cannot inspect native project audio.") }
        guard [.music, .meeting, .image, .drawing, .video].contains(record.kind) else {
            throw FloeError.validationFailed("inspectAudio supports Music, stopped Meeting recordings and native Media audio/video assets.")
        }
        try context.cancellation.throwIfCancelled(); try await validateProject()
        if input.listsSources {
            let page = try await sources(record: record, directory: directory, offset: input.offset ?? 0, limit: input.limit ?? 32)
            try await validateProject(); try context.cancellation.throwIfCancelled()
            return try StudioToolOutput.make(page)
        }
        let candidates = try await entries(record: record, directory: directory)
        let selected: Entry?
        if let legacy = input.assetID {
            guard record.kind == .music else { throw FloeError.validationFailed("Legacy assetID is only for Music. List and choose this work's sourceID.") }
            selected = candidates.first { if case .music(let asset, _) = $0.source { asset.id == legacy } else { false } }
        } else { selected = candidates.first { $0.descriptor.sourceID == input.sourceID } }
        guard let selected else { throw FloeError.notFound("Audio source in this authorized work; list fresh audioSources after a revision change") }
        let located = try await locate(selected.source, record: record, directory: directory)
        let cancellation = context.cancellation
        let hash: String
        if let expected = located.expectedSHA256 { hash = expected }
        else {
            hash = try await personalPreviewOffMain {
                try located.file.sha256 { try cancellation.throwIfCancelled(); try Task.checkCancellation() }
            }
        }
        try context.cancellation.throwIfCancelled()
        let check: @MainActor @Sendable () async throws -> Void = {
            try context.cancellation.throwIfCancelled(); try await validateProject()
            let current = try await entries(record: record, directory: directory)
            guard let same = current.first(where: { $0.descriptor.sourceID == selected.descriptor.sourceID }),
                  same.descriptor == selected.descriptor else { throw PersonalContentError.changedDocument }
            let resolved = try await locate(same.source, record: record, directory: directory)
            guard resolved.file.url == located.file.url, resolved.file.identity == located.file.identity,
                  resolved.expectedSHA256 == located.expectedSHA256 else { throw PersonalContentError.changedDocument }
            try located.file.validate(); try context.cancellation.throwIfCancelled()
        }
        let report = try await AudioWaveformInspector().inspectAuthorizedSource(at: located.file.url,
            sourceReference: "studio/\(record.id.uuidString.lowercased())/\(selected.descriptor.sourceID)", expectedSHA256: hash,
            startSeconds: input.startSeconds, endSeconds: input.endSeconds, bins: input.bins, context: context, validateSource: check)
        try await check()
        return try StudioToolOutput.make(StudioAudioObservationReceipt(projectID: record.id, revision: located.revision,
            assetID: located.legacyAssetID, source: selected.descriptor, audioObservation: report))
    }

    private static func descriptor(projectID: UUID, kind: String, nativeID: String, revision: String,
                                   metadata: Data, title: String, state: String = "registered") -> StudioAudioSourceDescriptor {
        let bytes = Data("\(projectID.uuidString.lowercased())|\(kind)|\(nativeID)|\(revision)|".utf8) + metadata
        return .init(sourceID: "audio_" + previewHash(bytes), kind: kind, title: String(title.prefix(160)), revision: revision, state: state)
    }
    private static func entries(record: PersonalContentRecord, directory: URL) async throws -> [Entry] {
        switch record.kind {
        case .music:
            let document = try await musicDocument(id: record.id, directory: directory)
            guard document.assets.count <= 4_096 else { throw FloeError.validationFailed("Too many audio sources in this work") }
            return try document.assets.filter { $0.kind != .midiFile }.map { asset in
                .init(descriptor: descriptor(projectID: record.id, kind: "musicAsset", nativeID: asset.id.rawValue,
                    revision: "\(document.revision):\(asset.sourceRevision)", metadata: try StudioToolOutput.data(asset), title: asset.name),
                      source: .music(asset, document.revision))
            }
        case .image, .drawing, .video:
            let project = try await mediaDocument(id: record.id, directory: directory)
            guard let document = project.prepared, document.assets.count <= 4_096 else { throw PersonalContentError.invalidProject }
            return try document.assets.filter { $0.kind == .audio || $0.kind == .video }.map { asset in
                .init(descriptor: descriptor(projectID: record.id, kind: "mediaAsset", nativeID: asset.id.uuidString,
                    revision: String(document.revision), metadata: try StudioToolOutput.data(asset), title: asset.originalName),
                      source: .media(asset, document.revision))
            }
        case .meeting:
            let values = try await personalPreviewOffMain { try stoppedRecordings(id: record.id, directory: directory) }
            return try values.map { capture in
                let metadata = try StudioToolOutput.data(capture), revision = previewHash(metadata)
                let title = capture.sourceFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? previewText("已完成录音", "Completed recording")
                return .init(descriptor: descriptor(projectID: record.id, kind: "meetingRecording", nativeID: capture.id.description,
                    revision: revision, metadata: metadata, title: title, state: "stopped"), source: .meeting(capture))
            }
        default: return []
        }
    }
    static func musicDocument(id: UUID, directory: URL) async throws -> MusicDocument {
        let root = directory.appendingPathComponent("Music", isDirectory: true)
        if let existing = try MusicProjectSession.existingForAudioObservation(id: id, directory: root) { return existing.document }
        return try await personalPreviewOffMain {
            let file = try PersonalPreviewFile(root: root,
                url: root.appendingPathComponent("documents/\(previewHash(Data(id.uuidString.lowercased().utf8))).json"), maximumBytes: 32 * 1_024 * 1_024)
            let value = try JSONDecoder().decode(MusicDocument.self, from: file.data())
            guard value.id.rawValue == id.uuidString.lowercased() else { throw PersonalContentError.changedDocument }
            try value.validate(); try file.validate(); return value
        }
    }
    static func mediaDocument(id: UUID, directory: URL) async throws -> MediaProject {
        let root = directory.appendingPathComponent("Media", isDirectory: true)
        if let existing = try MediaV2Session.existingForAudioObservation(id: id, root: root) { return existing.project }
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects"))
        let file = try await personalPreviewOffMain { try PersonalPreviewFile(root: root, url: store.projectURL(id: id), maximumBytes: 8 * 1_024 * 1_024) }
        guard let value = try await store.loadProject(id: id), value.id == id, value.ownerID == id else { throw PersonalContentError.invalidProject }
        try MediaPreparedIntegrity.validateEnvelope(value); try file.validate(); return value
    }
    private static func locate(_ source: NativeSource, record: PersonalContentRecord, directory: URL) async throws -> Located {
        switch source {
        case .music(let asset, let revision):
            let root = directory.appendingPathComponent("Music", isDirectory: true)
            let value = try await personalPreviewOffMain {
                let metadata = try PersonalPreviewFile(root: root, url: root.appendingPathComponent("assets/\(previewHash(Data(asset.id.rawValue.utf8))).json"), maximumBytes: 64 * 1_024)
                let stored = try JSONDecoder().decode(MusicAsset.self, from: metadata.data())
                guard stored == asset else { throw PersonalContentError.changedDocument }
                let ext: String
                switch asset.kind { case .audioPCM: ext = "wav";case .audioMP3: ext = "mp3";case .audioM4A: ext = "m4a";case .unsupportedRaw: ext = "bin";case .midiFile: throw FloeError.validationFailed("MIDI is note events. Render the actual mix explicitly before observing audio.") }
                let file = try PersonalPreviewFile(root: root, url: root.appendingPathComponent("blobs/\(asset.contentHash).\(ext)"), maximumBytes: 256 * 1_024 * 1_024)
                try metadata.validate(); return file
            }
            return .init(file: value, expectedSHA256: asset.contentHash, revision: revision, legacyAssetID: asset.id)
        case .media(let asset, let revision):
            let root = directory.appendingPathComponent("Media", isDirectory: true)
            let url = asset.relativePath.hasPrefix("/") ? URL(fileURLWithPath: asset.relativePath) : root.appendingPathComponent(asset.relativePath)
            let file = try await personalPreviewOffMain { try PersonalPreviewFile(root: root, url: url, maximumBytes: 256 * 1_024 * 1_024) }
            if let bytes = asset.byteCount, bytes != file.identity.size { throw PersonalContentError.changedDocument }
            return .init(file: file, expectedSHA256: asset.contentHash, revision: revision, legacyAssetID: nil)
        case .meeting(let capture):
            guard capture.meetingID.rawValue == record.id, capture.state == .stopped, capture.endedAt != nil else {
                throw FloeError.validationFailed("Stop and finish this recording before inspecting its saved audio.")
            }
            let root = directory.appendingPathComponent("Meeting", isDirectory: true)
            let url: URL
            if let source = capture.sourceFile { url = URL(fileURLWithPath: source) }
            else {
                let configuration = CaptureConfiguration(directory: root.appendingPathComponent("Recordings"))
                let pcm = try MeetingPCMChunkRecorder.originalURL(configuration: configuration, session: capture.id)
                url = FileManager.default.fileExists(atPath: pcm.path) ? pcm : try AVAudioRecorderCaptureBackend.makeFileURL(configuration: configuration, session: capture.id)
            }
            let file = try await personalPreviewOffMain { try PersonalPreviewFile(root: root, url: url, maximumBytes: 256 * 1_024 * 1_024) }
            return .init(file: file, expectedSHA256: nil, revision: nil, legacyAssetID: nil)
        }
    }

    private nonisolated static func stoppedRecordings(id: UUID, directory: URL) throws -> [CaptureSessionSnapshot] {
        let root = directory.appendingPathComponent("Meeting", isDirectory: true)
        let file = try PersonalPreviewFile(root: root, url: root.appendingPathComponent("meeting.sqlite"), maximumBytes: 128 * 1_024 * 1_024)
        var configuration = Configuration(); configuration.readonly = true
        configuration.observesSuspensionNotifications = true; configuration.busyMode = .timeout(0.5)
        let queue = try DatabaseQueue(path: file.url.path, configuration: configuration), meeting = MeetingID(id)
        let result = try queue.read { db -> [CaptureSessionSnapshot] in
            guard try String.fetchOne(db, sql: "SELECT id FROM meetings WHERE id=?", arguments: [meeting.description]) == meeting.description else { throw PersonalContentError.invalidProject }
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM capture_sessions WHERE meetingID=? AND state=? AND endedAt IS NOT NULL ORDER BY id LIMIT 4097", arguments: [meeting.description, CaptureSessionState.stopped.rawValue])
            guard rows.count <= 4_096 else { throw FloeError.validationFailed("Too many recording sources in this work") }
            return try rows.map { row in
                let raw: String = row["id"], rawKind: String = row["kind"]
                guard let uuid = UUID(uuidString: raw), let kind = CaptureKind(rawValue: rawKind) else { throw PersonalContentError.invalidProject }
                let folder: String? = row["directory"]
                return .init(id: CaptureSessionID(uuid), meetingID: meeting, kind: kind, state: .stopped,
                    directory: folder.map(URL.init(fileURLWithPath:)), sourceFile: row["sourceFile"], durationSeconds: row["durationSeconds"],
                    startedAt: row["startedAt"], endedAt: row["endedAt"], stopReason: (row["stopReason"] as String?).flatMap(CaptureStopReason.init(rawValue:)))
            }
        }
        try Task.checkCancellation(); try file.validate(); return result
    }
}
#endif

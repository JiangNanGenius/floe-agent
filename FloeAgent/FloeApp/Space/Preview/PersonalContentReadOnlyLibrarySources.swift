// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import GRDB
import FloeMeetings
import FloeMusicCore
import FloeCanvasCore
import FloeCanvasExchange
import FloeDiagramCore
import FloeDiagramExchange

/// Additional saved originals. These readers never initialize an editor,
/// repository writer, recording/transcription pipeline, slicer or renderer job.
extension PersonalContentPreviewService {
    func remainingLibraryRequest(record: PersonalContentRecord, directory: URL, ownerID: String,
        maximumPixelSize: Int, validate: @escaping @MainActor @Sendable () async throws -> Void) async throws -> PersonalContentPreviewRequest {
        switch record.kind {
        case .music:
            let root = directory.appendingPathComponent("Music", isDirectory: true)
            let saved = try await personalPreviewOffMain {
                let name = previewHash(Data(record.id.uuidString.lowercased().utf8))
                let file = try PersonalPreviewFile(root: directory, url: root.appendingPathComponent("documents/\(name).json"), maximumBytes: 8 * 1_024 * 1_024)
                let document = try JSONDecoder().decode(MusicDocument.self, from: file.data())
                guard document.id.rawValue == record.id.uuidString.lowercased() else { throw PersonalContentPreviewError.sourceChanged }
                try document.validate(); return (file, document)
            }
            let check: @MainActor @Sendable () async throws -> Void = { try await validate(); try saved.0.validate() }
            if let clip = saved.1.tracks.flatMap(\.clips).first(where: { if case .midi(let notes) = $0.body { !notes.notes.isEmpty } else { false } }) {
                return .init(key: .init(ownerID: ownerID, objectID: record.id.uuidString, revision: String(saved.1.revision),
                    variant: saved.0.identity.token, maximumPixelSize: maximumPixelSize), validate: check,
                    produce: { try PersonalEditorPreviewRequests.midiClip(clip, maximumPixelSize: maximumPixelSize) })
            }
            guard let asset = saved.1.assets.first(where: { [.audioPCM, .audioMP3, .audioM4A].contains($0.kind) }) else { throw PersonalContentPreviewError.notPrepared }
            let source = try await personalPreviewOffMain {
                let metadata = try PersonalPreviewFile(root: directory,
                    url: root.appendingPathComponent("assets/\(previewHash(Data(asset.id.rawValue.utf8))).json"), maximumBytes: 64 * 1_024)
                let stored = try JSONDecoder().decode(MusicAsset.self, from: metadata.data())
                guard stored == asset else { throw PersonalContentPreviewError.sourceChanged }
                let ext = asset.kind == .audioPCM ? "wav" : asset.kind == .audioMP3 ? "mp3" : "m4a"
                return (metadata, root.appendingPathComponent("blobs/\(asset.contentHash).\(ext)"))
            }
            let original = try await PersonalContentPreviewProducers.file(ownerID: ownerID, objectID: record.id.uuidString,
                revision: String(saved.1.revision), root: directory, url: source.1, kind: .audio,
                maximumPixelSize: maximumPixelSize, expectedSHA256: asset.contentHash,
                validate: { try await check(); try source.0.validate() })
            return .init(key: original.key, validate: original.validate, produce: {
                let value = try await original.produce()
                return .init(value.content, provenance: value.provenance,
                    detail: previewText("已保存素材波形，非混音", "Saved source waveform, not a mix"))
            })
        case .diagram:
            let saved = try await personalPreviewOffMain {
                let file = try PersonalPreviewFile(root: directory,
                    url: directory.appendingPathComponent("Diagram/\(record.id.uuidString).json"), maximumBytes: 8 * 1_024 * 1_024)
                let value = try JSONDecoder().decode(PreviewDiagramRecord.self, from: file.data()).document
                guard value.id == record.id else { throw PersonalContentPreviewError.sourceChanged }
                try value.validate()
                guard let page = value.pages.first, page.elements.count <= 512 else { throw PersonalContentPreviewError.notPrepared }
                return (file, value)
            }
            return .init(key: .init(ownerID: ownerID, objectID: record.id.uuidString, revision: String(saved.1.revision),
                variant: saved.0.identity.token, maximumPixelSize: maximumPixelSize),
                validate: { try await validate(); try saved.0.validate() }, produce: {
                    let result = try await DiagramNativeExporter.export(saved.1, format: .png)
                    guard result.issues.allSatisfy({ $0.code == "rasterScaleReduced" }) else { throw PersonalContentPreviewError.notPrepared }
                    return try await personalPreviewOffMain {
                        try PersonalContentPreviewProducers.image(result.data, maximumPixelSize: maximumPixelSize, provenance: .moduleSnapshot)
                    }
                })
        case .canvas:
            let saved = try await personalPreviewOffMain {
                let root = directory.appendingPathComponent("Canvas/canvases/\(record.id.uuidString)", isDirectory: true)
                let manifest = try PersonalPreviewFile(root: directory, url: root.appendingPathComponent("manifest.json"), maximumBytes: 4 * 1_024 * 1_024)
                let head = try JSONDecoder().decode(PreviewCanvasHead.self, from: manifest.data())
                guard head.schemaVersion == 1, head.canvasID == record.id, head.snapshotRevision >= 0,
                      head.snapshotBlob.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw PersonalContentPreviewError.unavailable }
                let blob = try PersonalPreviewFile(root: directory, url: root.appendingPathComponent("blobs/\(head.snapshotBlob).json"), maximumBytes: 8 * 1_024 * 1_024)
                let value = try JSONDecoder().decode(CanvasSnapshot.self, from: blob.data(expectedSHA256: head.snapshotBlob))
                guard value.id == record.id, value.revision == head.snapshotRevision, value.pages.count <= 64,
                      value.pages.allSatisfy({ $0.nodes.count <= 512 }) else { throw PersonalContentPreviewError.tooLarge }
                try manifest.validate(); return (manifest, blob, value)
            }
            return .init(key: .init(ownerID: ownerID, objectID: record.id.uuidString, revision: String(saved.2.revision),
                variant: saved.0.identity.token, maximumPixelSize: maximumPixelSize),
                validate: { try await validate(); try saved.0.validate(); try saved.1.validate() }, produce: {
                    // No asset resolver is invented. Any missing/lossy proxy
                    // reported by the native exporter is rejected as a preview.
                    let result = try await CanvasNativeExporter.png(snapshot: saved.2)
                    guard result.issues.allSatisfy({ $0.code == "rasterScaleReduced" }),
                          result.files.count == 1, let image = result.files.first else { throw PersonalContentPreviewError.notPrepared }
                    return try await personalPreviewOffMain {
                        try PersonalContentPreviewProducers.image(image.data, maximumPixelSize: maximumPixelSize, provenance: .moduleSnapshot)
                    }
                })
        case .meeting:
            let file = try await personalPreviewOffMain {
                try PersonalPreviewFile(root: directory, url: directory.appendingPathComponent("Meeting/meeting.sqlite"), maximumBytes: 128 * 1_024 * 1_024)
            }
            let meetingID = MeetingID(record.id).description
            let value = try await personalPreviewOffMain { try previewTranscript(file: file, meetingID: meetingID) }
            return .init(key: .init(ownerID: ownerID, objectID: record.id.uuidString, revision: value.digest,
                variant: file.identity.token, maximumPixelSize: maximumPixelSize), validate: {
                    try await validate()
                    let current = try await personalPreviewOffMain { try previewTranscript(file: file, meetingID: meetingID) }
                    guard current.digest == value.digest else { throw PersonalContentPreviewError.sourceChanged }
                }, produce: { .init(.text(value.text), provenance: .readableText,
                    detail: previewText("已保存转写片段", "Saved transcript excerpts")) })
        case .printing:
            let saved = try await personalPreviewOffMain {
                let file = try PersonalPreviewFile(root: directory, url: directory.appendingPathComponent("Printing/print.json"), maximumBytes: 512 * 1_024)
                let value = try JSONDecoder().decode(PrintProjectDocument.self, from: file.data())
                guard value.projectID == record.id, value.layerHeight.isFinite, value.layerHeight > 0 else { throw PersonalContentPreviewError.unavailable }
                return (file, value)
            }
            let names = Array((saved.1.objects?.map(\.name) ?? saved.1.meshName.map { [$0] } ?? []).prefix(12)).map { String($0.prefix(200)) }
            let summary = ([previewText("层高", "Layer height") + String(format: ": %.3f mm", saved.1.layerHeight)] + names).joined(separator: "\n")
            return .init(key: .init(ownerID: ownerID, objectID: record.id.uuidString, revision: String(saved.1.revision),
                variant: saved.0.identity.token, maximumPixelSize: maximumPixelSize),
                validate: { try await validate(); try saved.0.validate() },
                produce: { .init(.text(summary), provenance: .readableText,
                    detail: previewText("配置摘要，非模型或切片图", "Setup summary, not geometry or sliced layers")) })
        default: throw PersonalContentPreviewError.notPrepared
        }
    }
}

private nonisolated struct PreviewDiagramRecord: Decodable, Sendable { let document: DiagramDocument }
private nonisolated struct PreviewCanvasHead: Decodable, Sendable {
    let schemaVersion: Int; let canvasID: UUID; let snapshotBlob: String; let snapshotRevision: Int64
}
private nonisolated struct PreviewTranscript: Sendable { let text: String; let digest: String }

/// A short-lived GRDB read-only connection. It never invokes MeetingDatabase
/// migrations, reconciliation, recording or a NotesStore constructor.
private nonisolated func previewTranscript(file: PersonalPreviewFile, meetingID: String) throws -> PreviewTranscript {
    try Task.checkCancellation(); try file.validate()
    var configuration = Configuration(); configuration.readonly = true
    configuration.observesSuspensionNotifications = true; configuration.busyMode = .timeout(0.5)
    let queue = try DatabaseQueue(path: file.url.path, configuration: configuration)
    let result = try queue.read { db -> PreviewTranscript in
        guard try String.fetchOne(db, sql: "SELECT id FROM meetings WHERE id = ?", arguments: [meetingID]) == meetingID else {
            throw PersonalContentPreviewError.unavailable
        }
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments WHERE meetingID = ?", arguments: [meetingID]) ?? 0
        let rows = try Row.fetchAll(db, sql: "SELECT startSeconds, endSeconds, substr(text, 1, 800) AS excerpt FROM transcript_segments WHERE meetingID = ? ORDER BY sessionID, ordinal LIMIT 12", arguments: [meetingID])
        guard !rows.isEmpty else { throw PersonalContentPreviewError.notPrepared }
        let snippets = rows.map { row -> String in
            let start: Double = row["startSeconds"], end: Double = row["endSeconds"], text: String = row["excerpt"]
            return String(format: "%.2f–%.2f s  ", start, end) + text
        }
        let full = snippets.joined(separator: "\n\n")
        return .init(text: String(full.prefix(4_000)), digest: previewHash(Data(("\(count)|" + full).utf8)))
    }
    try Task.checkCancellation(); try file.validate(); return result
}
#endif

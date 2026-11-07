// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import UIKit
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import AVFoundation
import CryptoKit
import FloeNotes
import FloeDocuments
import FloeWorkbench
import FloeChemistryCore
import FloeChemistryUI
import FloeMedia
import FloeTools

@MainActor enum PersonalContentPreviewProducers {
    enum FileKind: Sendable, Equatable { case automatic, image, video, audio, pdf, office, text }

    static func file(ownerID: String, objectID: String, revision: String, root: URL, url: URL,
                     kind: FileKind = .automatic, maximumPixelSize: Int = 640,
                     expectedSHA256: String? = nil, seconds: Double = 0,
                     validate: @escaping @MainActor @Sendable () async throws -> Void) async throws -> PersonalContentPreviewRequest {
        let selected = kind == .automatic ? try fileKind(url.pathExtension.lowercased()) : kind
        guard seconds.isFinite, seconds >= 0 else { throw PersonalContentPreviewError.unavailable }
        let limit = selected == .text ? 128 * 1_024 : selected == .office ? 48 * 1_024 * 1_024 : 256 * 1_024 * 1_024
        let file = try await personalPreviewOffMain { try PersonalPreviewFile(root: root, url: url, maximumBytes: limit) }
        let key = PersonalContentPreviewKey(ownerID: ownerID, objectID: objectID, revision: revision,
            variant: "file:\(file.identity.token):\(expectedSHA256 ?? ""):t\(seconds)", maximumPixelSize: maximumPixelSize)
        let check: @MainActor @Sendable () async throws -> Void = { try await validate(); try file.validate() }
        return .init(key: key, validate: check, produce: {
            try await personalPreviewOffMain { try file.verifyHash(expectedSHA256) }
            switch selected {
            case .image:
                return try await personalPreviewOffMain {
                    try image(try file.data(expectedSHA256: expectedSHA256), maximumPixelSize: key.maximumPixelSize, provenance: .originalImage)
                }
            case .text:
                let bytes = try await personalPreviewOffMain { try file.data(expectedSHA256: expectedSHA256) }
                guard let text = String(data: bytes, encoding: .utf8), !text.isEmpty else { throw PersonalContentPreviewError.notPrepared }
                return .init(.text(String(text.prefix(4_000))), provenance: .readableText)
            case .pdf:
                // The only PDF producer is the existing PDFKit affinity and
                // exception gate. No PDF object crosses its boundary.
                let bytes = try await personalPreviewOffMain { try OfficeSavedCoverRenderer.firstPageData(at: file.url) }
                return try await personalPreviewOffMain { try image(bytes, maximumPixelSize: key.maximumPixelSize, provenance: .pdfPage) }
            case .office:
                let outcome = await NotesOfficeThumbnailGenerator.thumbnail(url: file.url,
                    size: CGSize(width: key.maximumPixelSize, height: key.maximumPixelSize), fileExtension: file.url.pathExtension.lowercased())
                try Task.checkCancellation()
                if let original = outcome.image, !outcome.wasIconFallback, let bytes = original.pngData() {
                    return try await personalPreviewOffMain { try image(bytes, maximumPixelSize: key.maximumPixelSize, provenance: .officePage) }
                }
                // Same native bounded OOXML content fallback as Notes; it is
                // explicitly identified as a summary, not original pagination.
                let snapshot = try await personalPreviewOffMain { try OfficeDocumentService.inspect(url: file.url) }
                guard let kind = NotesDocumentCoverService.summaryDocumentKind(for: file.url.pathExtension.lowercased()),
                      let summary = NotesDocumentCoverService.renderSummary(snapshot: snapshot, kind: kind,
                        size: CGSize(width: key.maximumPixelSize, height: key.maximumPixelSize)), let bytes = summary.image.pngData() else {
                    throw PersonalContentPreviewError.notPrepared
                }
                return .init(.image(bytes), provenance: .officeContentSummary, detail: previewText("内容摘要", "Content summary"))
            case .video:
                return try await video(file: file, seconds: seconds, maximumPixelSize: key.maximumPixelSize)
            case .audio:
                let cancellation = CancellationToken()
                let report = try await withTaskCancellationHandler {
                    // Shared accurate PCM decoder, also used by audio.inspect;
                    // UI supplies its own native source lease, never a fake task.
                    try await AudioWaveformInspector().inspectNativePreview(at: file.url,
                        sourceReference: "preview/\(previewHash(Data(ownerID.utf8)))/\(previewHash(Data(objectID.utf8)))/\(previewHash(Data(revision.utf8)))",
                        expectedSHA256: expectedSHA256, startSeconds: seconds, bins: 64,
                        cancellation: cancellation, validateSource: { @MainActor in try await check() })
                } onCancel: { cancellation.cancel() }
                return waveform(report)
            case .automatic: throw PersonalContentPreviewError.unsupported
            }
        })
    }

    static func notes(document: NoteDocument, store: NotesStore, ownerID: String,
                      maximumPixelSize: Int = 640) -> PersonalContentPreviewRequest {
        let key = PersonalContentPreviewKey(ownerID: ownerID, objectID: document.id.uuidString,
            revision: String(document.revision), variant: document.coverCacheToken, maximumPixelSize: maximumPixelSize)
        return .init(key: key, validate: {
            let latest = try await store.document(document.id)
            guard latest.deletedAt == nil, latest.revision == document.revision, latest.coverCacheToken == document.coverCacheToken else {
                throw PersonalContentPreviewError.sourceChanged
            }
        }, produce: {
            let outcome = await NotesDocumentCoverService.render(document: document, store: store,
                size: CGSize(width: key.maximumPixelSize, height: key.maximumPixelSize), maximumSourceBytes: 48 * 1_024 * 1_024)
            try Task.checkCancellation()
            guard outcome.source.hasContent, let bytes = outcome.image?.pngData() else { throw PersonalContentPreviewError.notPrepared }
            let source: PersonalContentPreviewArtifact.Provenance = outcome.source == .officeContentSummary ? .officeContentSummary
                : outcome.source == .notePage ? .notePage : outcome.source == .officeSavedPreview || outcome.source == .quickLookThumbnail ? .officePage : .moduleSnapshot
            return try await personalPreviewOffMain { try image(bytes, maximumPixelSize: key.maximumPixelSize, provenance: source) }
        })
    }

    static func media(project: MediaProject, root: URL, ownerID: String, maximumPixelSize: Int = 640,
                      seconds: Double = 0, validate: @escaping @MainActor @Sendable () async throws -> Void) async throws -> PersonalContentPreviewRequest {
        guard let document = project.prepared, seconds.isFinite, seconds >= 0, document.assets.count <= 128 else {
            throw PersonalContentPreviewError.notPrepared
        }
        try MediaPreparedIntegrity.validateEnvelope(project)
        let files = try await personalPreviewOffMain {
            let values = try document.assets.map { asset -> (UUID, PersonalPreviewFile) in
                let url = asset.relativePath.hasPrefix("/") ? URL(fileURLWithPath: asset.relativePath) : root.appendingPathComponent(asset.relativePath)
                let file = try PersonalPreviewFile(root: root, url: url, maximumBytes: 256 * 1_024 * 1_024)
                if let expected = asset.byteCount, expected != file.identity.size { throw PersonalContentPreviewError.sourceChanged }
                return (asset.id, file)
            }
            guard Set(values.map(\.0)).count == values.count,
                  values.reduce(Int64(0), { $0 + $1.1.identity.size }) <= 512 * 1_024 * 1_024 else { throw PersonalContentPreviewError.tooLarge }
            return values
        }
        let assetIdentity = previewHash(Data(files.map { "\($0.0):\($0.1.identity.token)" }.joined(separator: "|").utf8))
        let key = PersonalContentPreviewKey(ownerID: ownerID, objectID: project.id.uuidString,
            revision: String(project.revision), variant: "media:\(previewHash(Data(root.path.utf8))):\(assetIdentity):t\(seconds)", maximumPixelSize: maximumPixelSize)
        return .init(key: key, validate: {
            try await validate()
            for (_, file) in files { try file.validate() }
        }, produce: {
            try await personalPreviewOffMain {
                for (asset, value) in zip(document.assets, files) { try value.1.verifyHash(asset.contentHash) }
            }
            let urls = Dictionary(uniqueKeysWithValues: files.map { ($0.0, $0.1.url) })
            let rendered: CGImage
            if project.kind == .image {
                let canvas = project.canvas ?? .init(width: 1600, height: 1200)
                rendered = try await WorkbenchImageRenderer().render(project: project,
                    canvas: CGSize(width: canvas.width, height: canvas.height), resolveAsset: { urls[$0] }, previewMaxEdge: key.maximumPixelSize)
            } else {
                guard document.trackGraph.totalDurationSeconds > 0, document.trackGraph.tracks.contains(where: {
                    $0.kind == .visual && !$0.isMuted && $0.clips.contains(where: { $0.timelineRange.durationSeconds > 0 })
                }) else { throw PersonalContentPreviewError.notPrepared }
                let plan = try MediaPreparedVideoDocumentAdapter.resolve(document, assetURLs: urls, includeAudio: false)
                let scale = min(1, Double(key.maximumPixelSize) / Double(max(plan.canvas.width, plan.canvas.height)))
                let settings = try PreparedVideoOutputSettings(width: max(2, Int(Double(plan.canvas.width) * scale) / 2 * 2),
                    height: max(2, Int(Double(plan.canvas.height) * scale) / 2 * 2), frameRate: plan.frameRate)
                let token = PreparedVideoCancellation()
                rendered = try await withTaskCancellationHandler {
                    try await PreparedVideoFrameRenderer().renderFrame(plan: plan,
                        at: .init(seconds: min(seconds, max(0, document.trackGraph.totalDurationSeconds - 0.001)), timescale: plan.timeScale),
                        settings: settings, cancellation: token).image
                } onCancel: { token.cancel() }
            }
            try Task.checkCancellation()
            for (_, file) in files { try file.validate() }
            return .init(.image(try encode(rendered)), provenance: project.kind == .image ? .originalImage : .videoFrame)
        })
    }

    static func chemical(object: ChemicalObject, ownerID: String, maximumPixelSize: Int = 640,
                         validate: @escaping @MainActor @Sendable () async throws -> Void) -> PersonalContentPreviewRequest {
        .init(key: .init(ownerID: ownerID, objectID: object.id.uuidString, revision: String(object.revision), maximumPixelSize: maximumPixelSize),
            validate: validate, produce: {
                let result: ChemistryNoteImage
                if let ket = object.sketchDocument ?? (object.format.lowercased() == "ket" ? object.source : nil) {
                    guard ket.utf8.count <= 2 * 1_024 * 1_024 else { throw PersonalContentPreviewError.tooLarge }
                    result = try ChemistryNoteImageExporter.structurePNG(ket: ket)
                } else if object.kind == .spectrum, object.format.lowercased() == "csv" {
                    guard object.source.utf8.count <= 2 * 1_024 * 1_024 else { throw PersonalContentPreviewError.tooLarge }
                    result = try ChemistryNoteImageExporter.spectrumPNG(csv: object.source, title: object.title)
                } else {
                    // A formula or bond graph with no 2D coordinates is not
                    // an image. Previewing never embeds coordinates or runs a job.
                    throw PersonalContentPreviewError.notPrepared
                }
                return try await personalPreviewOffMain {
                    try image(result.png, maximumPixelSize: min(1_024, max(64, maximumPixelSize)), provenance: result.kind == "spectrum" ? .spectrum : .chemicalDrawing)
                }
            })
    }

    /// For a real snapshot already emitted by the module's existing renderer,
    /// including unsaved editor subobjects/results. Never invent an icon here.
    static func renderedImage(ownerID: String, objectID: String, revision: String, bytes: Data,
                              maximumPixelSize: Int = 640,
                              validate: @escaping @MainActor @Sendable () async throws -> Void) throws -> PersonalContentPreviewRequest {
        guard !bytes.isEmpty, bytes.count <= 8 * 1_024 * 1_024 else { throw PersonalContentPreviewError.tooLarge }
        let key = PersonalContentPreviewKey(ownerID: ownerID, objectID: objectID, revision: revision,
            variant: previewHash(bytes), maximumPixelSize: maximumPixelSize)
        return .init(key: key, validate: validate, produce: {
            try await personalPreviewOffMain { try image(bytes, maximumPixelSize: key.maximumPixelSize, provenance: .moduleSnapshot) }
        })
    }

    static func waveform(_ report: AudioWaveformInspection) -> PersonalContentPreviewArtifact {
        .init(.waveform(.init(channels: report.channels.map { .init(minimum: $0.binMin, maximum: $0.binMax) },
            durationSeconds: report.source.durationSeconds, startSeconds: report.window.startSeconds, endSeconds: report.window.endSeconds)), provenance: .audioWaveform)
    }

    private static func fileKind(_ ext: String) throws -> FileKind {
        if ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"].contains(ext) { return .image }
        if ["mp4", "mov", "m4v"].contains(ext) { return .video }
        if ["wav", "m4a", "mp3", "aac", "aiff", "aif", "caf", "flac"].contains(ext) { return .audio }
        if ext == "pdf" { return .pdf }
        if ["docx", "xlsx", "pptx", "doc", "xls", "ppt", "rtf", "odt"].contains(ext) { return .office }
        if ["txt", "md", "markdown", "csv", "json", "log"].contains(ext) { return .text }
        throw PersonalContentPreviewError.unsupported
    }
    nonisolated static func image(_ bytes: Data, maximumPixelSize: Int, provenance: PersonalContentPreviewArtifact.Provenance) throws -> PersonalContentPreviewArtifact {
        try Task.checkCancellation()
        guard !bytes.isEmpty, bytes.count <= 128 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(1_024, max(64, maximumPixelSize)), kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw PersonalContentPreviewError.unavailable }
        try Task.checkCancellation()
        return .init(.image(try encode(image)), provenance: provenance)
    }
    nonisolated static func encode(_ image: CGImage) throws -> Data {
        guard image.width > 0, image.height > 0, image.width <= 2_048, image.height <= 2_048 else { throw PersonalContentPreviewError.tooLarge }
        let bytes = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(bytes as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { throw PersonalContentPreviewError.unavailable }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target), bytes.length <= 8 * 1_024 * 1_024 else { throw PersonalContentPreviewError.tooLarge }
        return bytes as Data
    }
    private static func video(file: PersonalPreviewFile, seconds: Double, maximumPixelSize: Int) async throws -> PersonalContentPreviewArtifact {
        let asset = AVURLAsset(url: file.url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw PersonalContentPreviewError.notPrepared
        }
        let generator = PreviewFrameGenerator(asset: asset, maximumPixelSize: maximumPixelSize)
        let time = CMTime(seconds: min(seconds, max(0, duration - 0.001)), preferredTimescale: 600)
        let result = try await withTaskCancellationHandler { try await generator.value.image(at: time) }
            onCancel: { generator.value.cancelAllCGImageGeneration() }
        try Task.checkCancellation(); try file.validate()
        return .init(.image(try encode(result.image)), provenance: .videoFrame,
            detail: String(format: "%.2f / %.2f s", result.actualTime.seconds, duration))
    }
}

/// AVFoundation explicitly supports cancelling outstanding generation. The
/// box is used only to send that cancellation to the one owned generator.
private nonisolated final class PreviewFrameGenerator: @unchecked Sendable {
    let value: AVAssetImageGenerator
    init(asset: AVAsset, maximumPixelSize: Int) {
        value = AVAssetImageGenerator(asset: asset); value.appliesPreferredTrackTransform = true
        value.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
    }
}
nonisolated func previewHash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
nonisolated func previewText(_ chinese: String, _ english: String) -> String {
    Locale.current.language.languageCode?.identifier == "zh" ? chinese : english
}
#endif

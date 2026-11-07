// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import ImageIO
import UniformTypeIdentifiers
import FloeCore
import FloeModels
import FloeTools
import FloeWorkbench

nonisolated struct StudioPublishedResult: Sendable {
    let file: RunOutputFile
    var bytes: Int { file.byteCount }
    var sha256: String { file.sha256 }
}

@MainActor enum StudioResultPublication {
    /// The caller owns the real Studio location/use lease. Publication uses
    /// only its runtime context, never a model path or invented task binding.
    static func publish(file url: URL, projectRoot: URL, action: String, context: ToolContext,
                        validateSource: @escaping @MainActor @Sendable () async throws -> Void) async throws -> StudioPublishedResult {
        guard let producer = context.executionToolName, ["studio.run", "studio.machining"].contains(producer) else {
            throw FloeError.validationFailed("A real native result call is required")
        }
        try context.cancellation.throwIfCancelled(); try await validateSource()
        let token = context.cancellation
        let original = try await personalPreviewOffMain {
            try PersonalPreviewFile(root: projectRoot, url: url, maximumBytes: RunOutputCaps.standard.perFileBytes)
        }
        let hash = try await personalPreviewOffMain {
            try original.sha256 { try token.throwIfCancelled(); try Task.checkCancellation() }
        }
        let type = UTType(filenameExtension: url.pathExtension)
        let request = RunOutputSnapshotRequest(producerTool: producer, slot: "studio-" + action,
            commit: .init(sourceURL: original.url, sha256: hash, byteCount: Int(original.identity.size),
                displayName: original.url.lastPathComponent, mimeType: type?.preferredMIMEType ?? "application/octet-stream", uti: type?.identifier))
        try await validateSource(); try original.validate(); try token.throwIfCancelled()
        let file = try await personalPreviewOffMain { try RunOutputSnapshotStore.publish(request, using: context) }
        // Never delete a committed snapshot when a later owner fence changes.
        try await validateSource(); try original.validate(); try token.throwIfCancelled()
        return .init(file: file)
    }

    /// Native composed-image evidence uses the existing image-artifact
    /// namespace and verifier. No viewport/UI screenshot or new renderer.
    static func imageArtifact(_ bytes: Data, context: ToolContext) async throws -> ToolArtifactReference {
        try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, bytes.count <= 16 * 1_024 * 1_024,
              ProviderImageEvidencePolicy.sniffedMIME(bytes) == "image/png" else {
            throw FloeError.validationFailed("A bounded native PNG is required")
        }
        let digest = StudioToolOutput.hash(bytes), runID = context.runID
        let reference = ToolArtifactReference(id: UUID(),
            relativePath: "GeneratedImages/Studio/\(runID.uuidString)/\(digest).png", mimeType: "image/png", byteCount: bytes.count, sha256: digest)
        let cancellation = context.cancellation
        return try await personalPreviewOffMain {
            try cancellation.throwIfCancelled()
            let root = try FloeArtifactStore.root().standardizedFileURL.resolvingSymlinksInPath()
            let url = root.appendingPathComponent(reference.relativePath), directory = url.deletingLastPathComponent()
            // All names are native constants/run ID/content hash. Reject an
            // aliased parent before writing and verify the real stored bytes.
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var parent = root
            for component in ["GeneratedImages", "Studio", runID.uuidString] {
                parent.appendPathComponent(component, isDirectory: true)
                if FileManager.default.fileExists(atPath: parent.path) {
                    let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else { throw PersonalContentPreviewError.sourceChanged }
                } else { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false) }
                guard parent.standardizedFileURL == parent.standardizedFileURL.resolvingSymlinksInPath() else { throw PersonalContentPreviewError.sourceChanged }
            }
            guard parent == directory else { throw PersonalContentPreviewError.sourceChanged }
            do { try bytes.write(to: url, options: .withoutOverwriting) }
            catch let error as CocoaError where error.code == .fileWriteFileExists { /* verified equal below */ }
            _ = try VerifiedToolImageArtifact.load(reference, root: root)
            try cancellation.throwIfCancelled(); try Task.checkCancellation()
            return reference
        }
    }
}

nonisolated struct StudioFrameInput: Decodable, Sendable {
    let expectedRevision: Int64
    let seconds: Double?
    let maximumPixelSize: Int?
    static func decode(_ json: String?) throws -> Self {
        guard let data = json?.data(using: .utf8), var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["expectedRevision", "seconds", "maximumPixelSize"]) else {
            throw FloeError.validationFailed("inspectFrame requires {expectedRevision,seconds?,maximumPixelSize?}; no host paths")
        }
        if let revision = object["expectedRevision"] as? String {
            guard revision.range(of: "^(0|[1-9][0-9]*)$", options: .regularExpression) != nil,
                  let value = Int64(revision) else { throw FloeError.validationFailed("Use the exact revision from studio.read") }
            object["expectedRevision"] = value
        }
        let value = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: object))
        guard value.expectedRevision >= 0, value.seconds.map({ $0.isFinite && $0 >= 0 }) != false,
              (64...1_024).contains(value.maximumPixelSize ?? 1_024) else { throw FloeError.validationFailed("Invalid native frame parameters") }
        return value
    }
}

@MainActor enum StudioFrameObservation {
    private struct Receipt: Encodable {
        let projectID: UUID; let revision: Int64; let sourceSHA256: String
        let requestedSeconds: Double; let width: Int; let height: Int
        let artifact: ToolArtifactReference
        let semantics = "Actual composed native image/frame near the requested timeline time. Not a UI screenshot or playback claim. Only a vision-capable model may inspect its pixels."
    }
    static func inspect(record: PersonalContentRecord, directory: URL, input: StudioFrameInput, context: ToolContext,
                        validateProject: @escaping @MainActor @Sendable () async throws -> Void) async throws -> ToolExecutionOutput {
        guard [.image, .drawing, .video].contains(record.kind), !context.temporaryReadOnly else { throw PersonalContentError.invalidProject }
        try context.cancellation.throwIfCancelled(); try await validateProject()
        let project = try await StudioAudioObservation.mediaDocument(id: record.id, directory: directory)
        guard let document = project.prepared, document.revision == input.expectedRevision else { throw PersonalContentError.changedDocument }
        let seconds = input.seconds ?? 0
        if project.kind == .image {
            guard seconds == 0 else { throw FloeError.validationFailed("A still image has no timeline") }
        } else {
            guard seconds < document.trackGraph.totalDurationSeconds else { throw FloeError.validationFailed("Choose a time inside this video's saved timeline") }
        }
        let sourceHash = StudioToolOutput.hash(try StudioToolOutput.data(project))
        let root = directory.appendingPathComponent("Media"), cancellation = context.cancellation
        let validate: @MainActor @Sendable () async throws -> Void = {
            try context.cancellation.throwIfCancelled(); try await validateProject()
            let current = try await StudioAudioObservation.mediaDocument(id: record.id, directory: directory)
            guard StudioToolOutput.hash(try StudioToolOutput.data(current)) == sourceHash else { throw PersonalContentError.changedDocument }
        }
        let request = try await PersonalContentPreviewProducers.media(project: project, root: root,
            ownerID: "studio-frame:\(record.id)", maximumPixelSize: input.maximumPixelSize ?? 1_024, seconds: seconds, validate: validate)
        let worker = Task { try await PersonalContentPreviewService.shared.preview(request) }
        let monitor = Task {
            while !Task.isCancelled {
                if cancellation.isCancelled { worker.cancel(); return }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        defer { monitor.cancel() }
        let rendered = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try await validate()
        guard case .image(let bytes) = rendered.content,
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let fields = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = fields[kCGImagePropertyPixelWidth] as? Int, let height = fields[kCGImagePropertyPixelHeight] as? Int else {
            throw PersonalContentPreviewError.notPrepared
        }
        let artifact = try await StudioResultPublication.imageArtifact(bytes, context: context)
        try await validate()
        var output = try StudioToolOutput.make(Receipt(projectID: record.id, revision: document.revision,
            sourceSHA256: sourceHash, requestedSeconds: seconds, width: width, height: height, artifact: artifact))
        output.artifacts = [artifact]
        return output
    }
}
#endif

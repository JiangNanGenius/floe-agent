// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The exact allowlist shared by model advertisement and the saved-receipt
/// resolver. An external tool's text/namespace cannot authorize an embed.
public enum ChatInlineContentCatalog {
    public static func accepts(_ artifact: ToolArtifactReference, runID: UUID, tool: String) -> Bool {
        let path = artifact.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard artifact.byteCount > 0, path.count >= 2,
              !artifact.relativePath.contains("\\"),
              !artifact.relativePath.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              path.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              RunOutputFile.isValidSHA256Hex(artifact.sha256.lowercased()) else { return false }
        let fileWriters: Set<String> = ["workspace.createFile", "workspace.writeFile", "workspace.applyPatch", "workspace.appendFile", "workspace.replaceText"]
        if fileWriters.contains(tool) {
            let suffix: String
            switch artifact.mimeType {
            case "text/x-diff": suffix = ".diff"
            case "application/vnd.floe.file-preview+json": suffix = ".preview.json"
            default: return false
            }
            return artifact.byteCount <= 512 * 1024 && path.count == 3
                && path[0] == "ChangeArtifacts" && path[1] == Substring(runID.uuidString)
                && path[2] == Substring(artifact.sha256.lowercased() + suffix)
        }
        if tool == "document.presentation.createInline" {
            let suffix: String
            switch artifact.mimeType {
            case "application/vnd.floe.chart+json": suffix = "chart.json"
            case "application/vnd.floe.table+json": suffix = "table.json"
            case "text/html": suffix = "html"
            default: return false
            }
            return artifact.byteCount <= 2 * 1_024 * 1_024
                && artifact.relativePath == "PresentationArtifacts/\(runID.uuidString)/\(artifact.id.uuidString).\(suffix)"
        }
        if tool == "audio.synthesize" {
            // The native audio factory writes one bounded, self-contained
            // data-URI player. Its filename UUID is independent of artifact.id.
            guard path.count == 3, path[0] == "ChangeArtifacts",
                  path[1] == Substring(runID.uuidString), artifact.mimeType == "text/html",
                  artifact.byteCount <= 1_000_000, path[2].hasSuffix(".html"),
                  let fileID = UUID(uuidString: String(path[2].dropLast(5))) else { return false }
            return path[2] == Substring(fileID.uuidString.lowercased() + ".html")
        }
        if tool == "cad.document" {
            // These are cad.document's real retained capture/observe outputs,
            // not arbitrary images quoted by another tool or another run.
            guard path.count == 3, path[1] == Substring(runID.uuidString),
                  artifact.byteCount <= 16 * 1_024 * 1_024,
                  VerifiedToolImageArtifact.namespaces.contains(String(path[0])) else { return false }
            let suffix: String
            switch (String(path[0]), artifact.mimeType) {
            case ("CADViewportArtifacts", "image/png"),
                 ("EngineeringObservations", "image/png"),
                 ("CADAnimationFrames", "image/png"): suffix = "png"
            case ("CADAnimationFrames", "image/jpeg"): suffix = "jpg"
            default: return false
            }
            return path[2] == Substring(artifact.sha256 + "." + suffix)
        }
        if tool == "notes.read" {
            return path.count == 2 && path[0] == "GeneratedImages"
                && VerifiedToolImageArtifact.namespaces.contains(String(path[0]))
                && path[1] == Substring("office-region-" + artifact.id.uuidString + ".png")
                && artifact.mimeType == "image/png"
                && artifact.byteCount <= ProviderImageEvidencePolicy.maximumImageBytes
        }
        if tool == "ios.bridge.observe" {
            let suffix: String
            switch artifact.mimeType {
            case "image/png": suffix = "png"
            case "image/jpeg": suffix = "jpg"
            default: return false
            }
            return path.count == 2 && path[0] == "VNCArtifacts"
                && VerifiedToolImageArtifact.namespaces.contains(String(path[0]))
                && path[1] == Substring(artifact.id.uuidString + "." + suffix)
                && artifact.byteCount <= VerifiedToolImageArtifact.maximumStoredImageBytes
        }
        let vncPostActionProducers: Set<String> = ["vnc.clickElement", "vnc.click", "vnc.typeText",
            "vnc.scroll", "vnc.drag", "vnc.keyPress"]
        if vncPostActionProducers.contains(tool) {
            return path.count == 2 && path[0] == "VNCArtifacts"
                && VerifiedToolImageArtifact.namespaces.contains(String(path[0]))
                && path[1] == Substring(artifact.id.uuidString + ".jpg")
                && artifact.mimeType == "image/jpeg"
                && artifact.byteCount <= VerifiedToolImageArtifact.maximumStoredImageBytes
        }
        if tool == "browser.clickPoint" || tool == "browser.clickVisualText" {
            return path.count == 2 && path[0] == "BrowserArtifacts"
                && VerifiedToolImageArtifact.namespaces.contains(String(path[0]))
                && path[1] == Substring(artifact.id.uuidString + ".jpg")
                && artifact.mimeType == "image/jpeg"
                && artifact.byteCount <= 8 * 1_024 * 1_024
        }
        let imageProducers: Set<String> = ["image.generate", "image.playground", "image.view", "image.inspect",
            "document.pdf.render", "browser.screenshot", "browser.observe", "vnc.observe", "studio.run"]
        return imageProducers.contains(tool) && VerifiedToolImageArtifact.namespaces.contains(String(path[0]))
            && ProviderImageEvidencePolicy.canonicalMIMEType(artifact.mimeType) != nil
            && artifact.byteCount <= VerifiedToolImageArtifact.maximumStoredImageBytes
    }
    public static func accepts(_ output: RunOutputFile, runID: UUID, taskID: UUID,
                               callID: String, tool: String) -> Bool {
        output.runID == runID && output.taskID == taskID && output.producerCallID == callID
            && output.producerTool == tool && output.isCanonicalForCurrentRun && output.hasRuntimeConsistentIdentity
    }
    public static func descriptors(artifacts: [ToolArtifactReference], outputs: [RunOutputFile],
                                   runID: UUID, taskID: UUID, callID: String, tool: String) -> [ChatContentDescriptor] {
        var result = artifacts.filter { accepts($0, runID: runID, tool: tool) }.compactMap { artifact -> ChatContentDescriptor? in
            guard let reference = ChatContentReference(kind: .artifact, ownerID: runID, contentID: artifact.id.uuidString) else { return nil }
            let title: String
            switch artifact.mimeType {
            case "application/vnd.floe.chart+json": title = "Chart"
            case "application/vnd.floe.table+json": title = "Table"
            case "text/html": title = tool == "audio.synthesize" ? "Audio preview" : "Interactive preview"
            case "text/x-diff": title = "File changes"
            case "application/vnd.floe.file-preview+json": title = "Saved file preview"
            default: title = "Image"
            }
            return .init(reference: reference, mimeType: artifact.mimeType, title: title)
        }
        result += outputs.filter { accepts($0, runID: runID, taskID: taskID, callID: callID, tool: tool) }.compactMap {
            guard let reference = ChatContentReference(kind: .output, ownerID: runID, contentID: $0.outputID) else { return nil }
            return .init(reference: reference, mimeType: $0.mimeType, title: $0.displayName)
        }
        var seen: Set<ChatContentReference> = []
        return Array(result.filter { seen.insert($0.reference).inserted }.prefix(64))
    }
    public static func descriptors(_ result: ToolResult) -> [ChatContentDescriptor] {
        guard result.status == .ok, !result.outcomeUnknown, result.ephemeralSensitiveOutput == nil,
              let source = result.provenance, let taskID = source.taskID else { return [] }
        return descriptors(artifacts: result.artifacts, outputs: result.outputFiles,
            runID: source.runID, taskID: taskID, callID: result.callID, tool: source.toolName)
    }
    public static func wireItems(_ descriptors: [ChatContentDescriptor]) -> [[String: String]] {
        descriptors.map { ["inlineMarkdown": $0.inlineMarkdown, "mimeType": $0.mimeType, "title": $0.title] }
    }

    /// Preserve a complete JSON page instead of letting a generic summary
    /// character limit cut a reference or cursor in half. A truncated page
    /// must be repeated with a smaller event limit before advancing its cursor.
    public static func listingData(_ descriptors: [ChatContentDescriptor], pages: [[String: String]],
                                   maximumBytes: Int = 60 * 1_024) throws -> Data {
        var contents = Array(descriptors.prefix(128))
        while true {
            let data = try JSONSerialization.data(withJSONObject: [
                "contents": wireItems(contents), "pages": pages,
                "truncated": descriptors.count > contents.count,
                "instructions": ChatContentReference.modelInstructions + " If truncated is true, select runID and retry with a smaller eventLimit from the same startAfterSequence; advance nextAfterSequence only after a complete page."
            ], options: [.sortedKeys])
            if data.count <= maximumBytes { return data }
            guard !contents.isEmpty else {
                throw FloeError.validationFailed("Content index exceeds its page limit; select one runID and a smaller eventLimit")
            }
            contents.removeLast()
        }
    }
}

/// Bounded, no-follow reading for native presentation and image artifacts.
/// Every component is opened relative to the preceding directory descriptor;
/// in-root aliases and a swapped symlink cannot redirect this read.
public struct VerifiedChatInlineArtifact: Sendable {
    public let artifact: ToolArtifactReference
    public let data: Data
    public let fileURL: URL
    public func imagePreviewData() -> Data? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384, width <= 40_000_000 / height,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_600
              ] as CFDictionary) else { return nil }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination), bytes.length <= 10 * 1_024 * 1_024 else { return nil }
        return bytes as Data
        #else
        return nil
        #endif
    }
    public static func load(_ artifact: ToolArtifactReference, runID: UUID, tool: String, root: URL) throws -> Self {
        guard ChatInlineContentCatalog.accepts(artifact, runID: runID, tool: tool) else { throw FloeError.unauthorized }
        let loaded = try read(relativePath: artifact.relativePath, root: root,
            byteCount: artifact.byteCount, digest: artifact.sha256, limit: 24 * 1_024 * 1_024)
        if ProviderImageEvidencePolicy.canonicalMIMEType(artifact.mimeType) != nil {
            guard ProviderImageEvidencePolicy.sniffedMIME(loaded) == ProviderImageEvidencePolicy.canonicalMIMEType(artifact.mimeType) else {
                throw FloeError.validationFailed("The image type does not match its saved receipt.")
            }
        }
        return .init(artifact: artifact, data: loaded,
            fileURL: root.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(artifact.relativePath))
    }
    public static func read(relativePath: String, root: URL, byteCount: Int, digest: String, limit: Int) throws -> Data {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard byteCount > 0, byteCount <= limit, !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !relativePath.contains("\\"), !relativePath.contains("\0"),
              RunOutputFile.isValidSHA256Hex(digest.lowercased()) else { throw FloeError.unauthorized }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var directory = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw FloeError.notFound("Saved content is unavailable") }
        defer { close(directory) }
        for part in parts.dropLast() {
            let next = openat(directory, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw FloeError.unauthorized }
            close(directory); directory = next
        }
        let descriptor = openat(directory, String(parts.last!), O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { throw FloeError.notFound("Saved content is unavailable") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var facts = stat()
        guard fstat(descriptor, &facts) == 0, (facts.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              facts.st_nlink == 1, facts.st_size == byteCount else { throw FloeError.unauthorized }
        var data = Data()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(65_536, limit - data.count + 1)), !chunk.isEmpty else { break }
            data.append(chunk)
            guard data.count <= limit else { throw FloeError.unauthorized }
        }
        guard data.count == byteCount, FloeDigest.sha256Hex(data) == digest.lowercased() else {
            throw FloeError.validationFailed("Saved content no longer matches its receipt.")
        }
        return data
    }
}

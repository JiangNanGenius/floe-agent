// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCanvasCore

/// Formats supported by FloeCanvasExchange.
public enum CanvasExchangeFormat: String, Codable, Sendable, CaseIterable {
    /// Native complete laboratory archive (recovery authority).
    case floecanvaslab
    /// Obsidian JSON Canvas 1.0.
    case jsonCanvas
    /// Excalidraw scene JSON.
    case excalidraw
    /// diagrams.net draw.io XML.
    case drawio
    case pdf, svg, png

    public var fileExtension: String {
        switch self {
        case .jsonCanvas: return "canvas"
        case .floecanvaslab, .excalidraw, .drawio, .pdf, .svg, .png: return rawValue
        }
    }
}

public struct CanvasImportOptions: Sendable {
    public var canvasID: UUID
    public var canvasName: String
    public var namespace: String?
    public var trustedAssetRoot: URL?
    public var resolveAssetBytes: Bool
    public init(canvasID: UUID = UUID(), canvasName: String = "Imported", namespace: String? = nil, trustedAssetRoot: URL? = nil, resolveAssetBytes: Bool = false) {
        self.canvasID = canvasID
        self.canvasName = canvasName
        self.namespace = namespace
        self.trustedAssetRoot = trustedAssetRoot
        self.resolveAssetBytes = resolveAssetBytes
    }
}

public struct CanvasExportOptions: Sendable {
    public var pageID: UUID?
    public var multiPageStrategy: CanvasMultiPageStrategy
    /// uuid -> original foreign id (from a prior import bundle).
    public var externalIDs: [UUID: String]
    /// uuid -> original foreign node/element tree (unknown fields re-injected).
    public var originalNodes: [UUID: JSONValue]
    /// connection uuid -> original foreign edge tree.
    public var originalEdges: [UUID: JSONValue]
    /// Original foreign top-level document (unknown top-level keys re-injected).
    public var originalDocument: JSONValue?
    /// Asset bytes for formats that embed media (Excalidraw files, draw.io images).
    public var assetBytes: [UUID: Data]
    /// Asset resolver for rendered exports (PDF/SVG/PNG) and draw.io images.
    public var assetResolver: (any CanvasAssetResolver)?
    /// Host provider archiving professional child projects (native archive).
    public var childProjectProvider: (any CanvasNativeArchive.CanvasChildProjectExportProvider)?
    /// Opaque original imports to carry inside a native archive.
    public var originalSources: [CanvasNativeArchive.OriginalSourceEnvelope]
    /// Host registry of reusable flow template definitions for a native
    /// archive. The archive embeds only definitions reachable from the
    /// snapshot graphs (see `CanvasNativeArchive.FlowTemplateDefinition`).
    public var flowTemplates: [CanvasNativeArchive.FlowTemplateDefinition]
    /// Render scope and presentation (PDF/SVG/PNG).
    public var scope: CanvasExportScope
    public var regionPresentation: CanvasCollapsedRegionPresentation
    public var appearance: CanvasRenderAppearance
    /// Compress draw.io payloads.
    public var drawioCompressed: Bool

    public init(
        pageID: UUID? = nil,
        multiPageStrategy: CanvasMultiPageStrategy = .selectedPageOnly,
        externalIDs: [UUID: String] = [:],
        originalNodes: [UUID: JSONValue] = [:],
        originalEdges: [UUID: JSONValue] = [:],
        originalDocument: JSONValue? = nil,
        assetBytes: [UUID: Data] = [:],
        assetResolver: (any CanvasAssetResolver)? = nil,
        childProjectProvider: (any CanvasNativeArchive.CanvasChildProjectExportProvider)? = nil,
        originalSources: [CanvasNativeArchive.OriginalSourceEnvelope] = [],
        flowTemplates: [CanvasNativeArchive.FlowTemplateDefinition] = [],
        scope: CanvasExportScope = .wholePage,
        regionPresentation: CanvasCollapsedRegionPresentation = .chip,
        appearance: CanvasRenderAppearance = .light,
        drawioCompressed: Bool = false
    ) {
        self.pageID = pageID
        self.multiPageStrategy = multiPageStrategy
        self.externalIDs = externalIDs
        self.originalNodes = originalNodes
        self.originalEdges = originalEdges
        self.originalDocument = originalDocument
        self.assetBytes = assetBytes
        self.assetResolver = assetResolver
        self.childProjectProvider = childProjectProvider
        self.originalSources = originalSources
        self.flowTemplates = flowTemplates
        self.scope = scope
        self.regionPresentation = regionPresentation
        self.appearance = appearance
        self.drawioCompressed = drawioCompressed
    }
}

/// Facade dispatching between the concrete codecs.
public enum CanvasExchange {
    public static func importData(_ data: Data, format: CanvasExchangeFormat, options: CanvasImportOptions = CanvasImportOptions()) async throws -> CanvasExchangeBundle {
        try CanvasExchangeLimits.validateInputSize(data)
        switch format {
        case .jsonCanvas:
            var codecOptions = CanvasJSONCanvasCodec.ImportOptions(canvasID: options.canvasID, canvasName: options.canvasName)
            if let namespace = options.namespace { codecOptions.namespace = namespace }
            codecOptions.trustedAssetRoot = options.trustedAssetRoot
            codecOptions.resolveAssetBytes = options.resolveAssetBytes
            return try CanvasJSONCanvasCodec.decode(data, options: codecOptions)
        case .excalidraw:
            var codecOptions = CanvasExcalidrawCodec.ImportOptions(canvasID: options.canvasID, canvasName: options.canvasName)
            if let namespace = options.namespace { codecOptions.namespace = namespace }
            return try CanvasExcalidrawCodec.decode(data, options: codecOptions)
        case .drawio:
            var codecOptions = CanvasDrawIOCodec.ImportOptions(canvasID: options.canvasID, canvasName: options.canvasName)
            if let namespace = options.namespace { codecOptions.namespace = namespace }
            return try CanvasDrawIOCodec.decode(data, options: codecOptions)
        case .floecanvaslab:
            let result = try CanvasNativeArchive.import(data)
            return CanvasExchangeBundle(
                snapshot: result.snapshot,
                assets: result.assets,
                originalSources: result.originalSources,
                originalNodes: [:],
                originalEdges: [:],
                flowTemplates: result.flowTemplates,
                issues: result.issues
            )
        case .pdf, .svg, .png:
            throw CanvasExchangeError.invalid("\(format.rawValue) is an output format")
        }
    }

    public static func export(_ snapshot: CanvasSnapshot, format: CanvasExchangeFormat, options: CanvasExportOptions = CanvasExportOptions()) async throws -> CanvasExchangeOutput {
        switch format {
        case .jsonCanvas:
            let codecOptions = CanvasJSONCanvasCodec.ExportOptions(
                pageID: options.pageID,
                multiPageStrategy: options.multiPageStrategy,
                externalIDs: options.externalIDs,
                originalNodes: options.originalNodes,
                originalEdges: options.originalEdges,
                originalDocument: options.originalDocument
            )
            return try CanvasJSONCanvasCodec.export(snapshot, options: codecOptions)
        case .excalidraw:
            let codecOptions = CanvasExcalidrawCodec.ExportOptions(
                pageID: options.pageID,
                multiPageStrategy: options.multiPageStrategy,
                externalIDs: options.externalIDs,
                originalNodes: options.originalNodes,
                assetBytes: options.assetBytes,
                originalEdges: options.originalEdges,
                originalDocument: options.originalDocument
            )
            return try CanvasExcalidrawCodec.export(snapshot, options: codecOptions)
        case .drawio:
            let codecOptions = CanvasDrawIOCodec.ExportOptions(
                assetResolver: options.assetResolver.map { CanvasDrawIOCodec.CanvasDiagramAssetResolverAdapter(base: $0) },
                compressed: options.drawioCompressed
            )
            return try await CanvasDrawIOCodec.export(snapshot, options: codecOptions)
        case .floecanvaslab:
            let result = try await CanvasNativeArchive.export(
                snapshot,
                assetResolver: options.assetResolver,
                childProjectProvider: options.childProjectProvider,
                originalSources: options.originalSources,
                flowTemplates: options.flowTemplates
            )
            return CanvasExchangeOutput(
                files: [CanvasExchangeFile(name: CanvasExchangeFilename.sanitized(snapshot.name, extension: CanvasNativeArchive.fileExtension), data: result.data)],
                issues: result.issues
            )
        case .pdf:
            let pdfOptions = CanvasNativeExporter.PDFOptions(
                scope: options.scope,
                regionPresentation: options.regionPresentation,
                appearance: options.appearance,
                assetResolver: options.assetResolver,
                pageIDs: options.pageID.map { [$0] }
            )
            return try await CanvasNativeExporter.pdf(snapshot: snapshot, options: pdfOptions)
        case .svg:
            let svgOptions = CanvasSVGExporter.Options(
                scope: options.scope,
                regionPresentation: options.regionPresentation,
                appearance: options.appearance,
                assetResolver: options.assetResolver
            )
            return try await CanvasSVGExporter.svg(snapshot: snapshot, pageID: options.pageID, options: svgOptions)
        case .png:
            let rasterOptions = CanvasNativeExporter.RasterOptions(
                scope: options.scope,
                regionPresentation: options.regionPresentation,
                appearance: options.appearance,
                assetResolver: options.assetResolver
            )
            return try await CanvasNativeExporter.png(snapshot: snapshot, pageID: options.pageID, options: rasterOptions)
        }
    }

    /// Writes every output file with a staged, fsynced, same-directory
    /// atomic rename (the same discipline as the kit's file repository):
    /// a crash mid-write leaves the previous file untouched, and no partial
    /// file is ever visible at the destination.
    ///
    /// Batch semantics are explicit and honest: every file name is
    /// validated (plain basename — no separators, dot segments, NULs or
    /// duplicates) and every payload is staged BEFORE the first publish;
    /// a validation/staging failure leaves the destination untouched.
    /// Publishing is then a per-file atomic rename sequence — not a global
    /// filesystem transaction. If a rename fails mid-sequence, files
    /// already published by THIS save are rolled back when they did not
    /// pre-exist (pre-existing destinations are reported, never deleted),
    /// and the error says exactly what happened.
    public static func save(_ output: CanvasExchangeOutput, to directory: URL) throws {
        // 1) Validate every name before touching anything.
        var seen: Set<String> = []
        for file in output.files {
            try CanvasAtomicFile.validateFileName(file.name)
            guard seen.insert(file.name).inserted else {
                throw CanvasExchangeError.invalid("duplicate output file name \"\(file.name)\"")
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL

        // 2) Stage every payload (unique O_EXCL staging, fsync) before any
        //    publish; a failure here removes only our own staging files.
        struct StagedOutput {
            var staging: URL
            var destination: URL
            var replacedExistingFile: Bool
        }
        var staged: [StagedOutput] = []
        for file in output.files {
            let destination = directory.appendingPathComponent(file.name, isDirectory: false)
            let resolved = destination.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(resolvedDirectory.path + "/") else {
                for item in staged { _ = unlink(item.staging.path) }
                throw CanvasExchangeError.invalid("output \"\(file.name)\" escapes the destination directory")
            }
            let replacedExistingFile = FileManager.default.fileExists(atPath: destination.path)
            do {
                let staging = try CanvasAtomicFile.stage(file.data, in: directory)
                staged.append(StagedOutput(staging: staging, destination: destination, replacedExistingFile: replacedExistingFile))
            } catch {
                for item in staged { _ = unlink(item.staging.path) }
                throw error
            }
        }

        // 3) Publish per file. On failure roll back this save's own
        //    replacements (never a pre-existing destination) and report.
        var published: [StagedOutput] = []
        do {
            for item in staged {
                guard rename(item.staging.path, item.destination.path) == 0 else {
                    let code = errno
                    _ = unlink(item.staging.path)
                    throw CanvasExchangeError.io("replace output \"\(item.destination.lastPathComponent)\": \(code)")
                }
                published.append(item)
            }
        } catch {
            for item in published where !item.replacedExistingFile {
                _ = unlink(item.destination.path)
            }
            for index in published.count..<staged.count {
                _ = unlink(staged[index].staging.path)
            }
            throw CanvasExchangeError.io("\(error.localizedDescription); rolled back \(published.count) published file(s) and removed the remaining staging files")
        }
        let directoryFD = Darwin.open(directory.path, O_RDONLY)
        if directoryFD >= 0 {
            _ = fsync(directoryFD)
            _ = Darwin.close(directoryFD)
        }
    }
}

/// Staged atomic file write (unique O_EXCL staging file, full write +
/// fsync, atomic rename, directory fsync). Buffers are caller-bounded by
/// the export limits; a failure unlinks its own staging file only.
public enum CanvasAtomicFile {
    /// A safe output name is a plain basename: non-empty, free of path
    /// separators, drive colons, NULs and control characters, and not a
    /// dot segment.
    public static func validateFileName(_ name: String) throws {
        guard !name.isEmpty else {
            throw CanvasExchangeError.invalid("output file name is empty")
        }
        guard name != ".", name != ".." else {
            throw CanvasExchangeError.invalid("output file name \"\(name)\" is not a writable file name")
        }
        guard !name.contains("/"), !name.contains("\\"), !name.contains(":"), !name.contains("\0") else {
            throw CanvasExchangeError.invalid("output file name \"\(name)\" must be a plain file name without path separators")
        }
        guard !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CanvasExchangeError.invalid("output file name \"\(name)\" contains control characters")
        }
    }

    /// Writes `data` to a unique O_EXCL staging file in `directory` and
    /// returns its URL. The caller owns the staging file (publish with
    /// `rename`, discard with `unlink`).
    static func stage(_ data: Data, in directory: URL) throws -> URL {
        let staging = directory.appendingPathComponent(".floe-canvas-output-\(UUID().uuidString).tmp")
        let fd = Darwin.open(staging.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw CanvasExchangeError.io("stage output: \(errno)")
        }
        var open = true
        defer {
            if open { _ = Darwin.close(fd) }
            if open { _ = unlink(staging.path) }
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CanvasExchangeError.io("write staged output: \(errno)")
                }
                guard count > 0 else {
                    throw CanvasExchangeError.io("short write")
                }
                offset += count
            }
        }
        guard fsync(fd) == 0 else {
            throw CanvasExchangeError.io("flush staged output: \(errno)")
        }
        _ = Darwin.close(fd)
        open = false
        return staging
    }

    /// Single-file atomic write: stage + rename + directory fsync.
    public static func write(_ data: Data, to destination: URL) throws {
        try validateFileName(destination.lastPathComponent)
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(resolvedDirectory.path + "/") else {
            throw CanvasExchangeError.invalid("output escapes its destination directory")
        }
        let staging = try stage(data, in: directory)
        guard rename(staging.path, destination.path) == 0 else {
            _ = unlink(staging.path)
            throw CanvasExchangeError.io("replace output: \(errno)")
        }
        let directoryFD = Darwin.open(directory.path, O_RDONLY)
        if directoryFD >= 0 {
            _ = fsync(directoryFD)
            _ = Darwin.close(directoryFD)
        }
    }
}

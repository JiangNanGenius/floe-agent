// FloeImages — image.renderSVG agent tool.
//
// SPDX-License-Identifier: MPL-2.0
//
// Converts SVG (inline source or a workspace .svg file) into a real
// PNG or JPEG raster inside the resolved task workspace using the same
// bounded, JavaScript-disabled renderer that powers the chat preview.
// No provider, no Linux guest, no external library. The encoded output
// is re-opened: the reported MIME, pixel size, alpha presence, byte
// count and SHA-256 are measured from the bytes actually written. A
// bound run publishes the raster through the standard run-output
// receipt chain (runtime seal → toolResult → chat file card) exactly
// like image.qr.generate; nothing is fabricated for unbound contexts.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Crypto
import FloeCore
import FloeTools
import FloeWorkspace

/// SVG → PNG/JPEG conversion with truthful reopen-verified metadata.
public struct SVGRenderTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        /// Inline SVG source (mutually exclusive with `path`).
        public var svg: String?
        /// Workspace-relative .svg file to read (mutually exclusive with `svg`).
        public var path: String?
        /// "png" (default) or "jpeg".
        public var format: String?
        /// Target pixel width; the height follows the document aspect
        /// unless given too. Clamped to the shared raster ceilings.
        public var width: Int?
        public var height: Int?
        /// JPEG quality 0.3–1 (default 0.92). PNG keeps alpha.
        public var quality: Double?
        /// Optional PNG backdrop: "transparent" (default), "white" or
        /// "#rrggbb". JPEG always renders over white.
        public var background: String?
        /// Workspace-relative output path; defaults to
        /// `SVGExport/<source-basename|svg>-<id>.<ext>`.
        public var outputPath: String?

        public init(
            svg: String? = nil, path: String? = nil, format: String? = nil,
            width: Int? = nil, height: Int? = nil, quality: Double? = nil,
            background: String? = nil, outputPath: String? = nil
        ) {
            self.svg = svg
            self.path = path
            self.format = format
            self.width = width
            self.height = height
            self.quality = quality
            self.background = background
            self.outputPath = outputPath
        }
    }

    public static let name = "image.renderSVG"
    public static let toolDescription =
        "Render an SVG into a real PNG or JPEG raster locally (no network, no Linux). Provide either inline `svg` source or a workspace `path` to a .svg file. All SVG is untrusted input: scripts, event handlers, DTDs/entities, animation, external or file references, unsafe CSS and pathological complexity are rejected with a machine-readable reason. PNG preserves alpha (optional background); JPEG always flattens over white. width/height are target pixels (default = document size capped at 4096 px, 40 MP total; one edge follows the aspect ratio). Writes a NEW workspace file (never overwrites), reopens it to report the actual pixel size, alpha, MIME, bytes and SHA-256, and publishes the raster as this run's chat output receipt."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "svg": {"type": "string", "description": "Inline SVG source (max 1 MiB). Mutually exclusive with path"},
        "path": {"type": "string", "description": "Workspace-relative .svg file to read. Mutually exclusive with svg"},
        "format": {"type": "string", "enum": ["png", "jpeg"], "description": "Output raster format (default png)"},
        "width": {"type": "integer", "description": "Target pixel width (16-4096; height follows document aspect unless given)"},
        "height": {"type": "integer", "description": "Target pixel height (16-4096)"},
        "quality": {"type": "number", "description": "JPEG quality 0.3-1 (default 0.92)"},
        "background": {"type": "string", "description": "PNG backdrop: transparent (default), white or #rrggbb; JPEG is always white"},
        "outputPath": {"type": "string", "description": "Workspace-relative PNG/JPEG path; defaults to SVGExport/<name>-<id>.<ext>"}
      },
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let rootProvider: @Sendable () -> URL?
    /// Run-output artifact root used by the snapshot publisher.
    /// Production resolves the app-owned artifact store; tests inject a
    /// deterministic scratch root (same seam convention as QRCode).
    private let artifactRootProvider: @Sendable () -> URL?

    public init(
        rootProvider: @escaping @Sendable () -> URL?,
        artifactRootProvider: @escaping @Sendable () -> URL? = { try? FloeArtifactStore.root() }
    ) {
        self.rootProvider = rootProvider
        self.artifactRootProvider = artifactRootProvider
    }

    /// Stable logical output slot: this tool publishes exactly one
    /// raster per call, idempotent per call identity like QRCode.
    static let outputSlot = "image"

    static let jpegDefaultQuality = 0.92

    public func validate(_ args: Arguments) throws {
        let hasSVG = args.svg?.isEmpty == false
        let hasPath = (args.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        guard hasSVG != hasPath else {
            throw FloeError.validationFailed("provide exactly one of svg (inline source) or path (workspace .svg)")
        }
        if let svg = args.svg {
            guard !svg.isEmpty, svg.utf8.count <= SVGSafetyLimits.maxSourceBytes else {
                throw FloeError.validationFailed("svg source must be 1…\(SVGSafetyLimits.maxSourceBytes) bytes")
            }
        }
        if let path = args.path {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasSuffix(".svg") else {
                throw FloeError.validationFailed("path must end in .svg")
            }
            try Self.validateWorkspaceRelative(trimmed, argument: "path")
        }
        if let format = args.format, ["png", "jpeg"].contains(format.lowercased()) == false {
            throw FloeError.validationFailed("format must be png or jpeg")
        }
        if let width = args.width, !(SVGSafetyLimits.minOutputEdge...SVGSafetyLimits.maxOutputEdge).contains(width) {
            throw FloeError.validationFailed("width must be \(SVGSafetyLimits.minOutputEdge)…\(SVGSafetyLimits.maxOutputEdge) px")
        }
        if let height = args.height, !(SVGSafetyLimits.minOutputEdge...SVGSafetyLimits.maxOutputEdge).contains(height) {
            throw FloeError.validationFailed("height must be \(SVGSafetyLimits.minOutputEdge)…\(SVGSafetyLimits.maxOutputEdge) px")
        }
        if let quality = args.quality, !(0.3...1.0).contains(quality) {
            throw FloeError.validationFailed("quality must be 0.3-1")
        }
        if let background = args.background, SVGBackground.parse(background) == nil {
            throw FloeError.validationFailed("background must be transparent, white or #rrggbb")
        }
        if let outputPath = args.outputPath {
            let trimmed = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw FloeError.validationFailed("outputPath must not be empty")
            }
            try Self.validateWorkspaceRelative(trimmed, argument: "outputPath")
            let ext = (trimmed as NSString).pathExtension.lowercased()
            guard ext == "png" || ext == "jpg" || ext == "jpeg" else {
                throw FloeError.validationFailed("outputPath must end in .png, .jpg or .jpeg")
            }
            let normalizedFormat = (args.format ?? "png").lowercased()
            let rasterIsJPEG = normalizedFormat == "jpeg"
            let pathIsJPEG = ext != "png"
            guard rasterIsJPEG == pathIsJPEG else {
                throw FloeError.validationFailed("outputPath extension must match the requested format")
            }
        }
    }

    private static func validateWorkspaceRelative(_ path: String, argument: String) throws {
        guard !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.split(separator: "/").contains("..") else {
            throw FloeError.validationFailed("\(argument) must be workspace-relative")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let root = context.workspaceRootURL ?? rootProvider() else {
            return Self.output("status=error error=No workspace is open", exitStatus: 2)
        }
        do {
            // 1. Obtain the source bytes (inline or workspace file).
            let sourceText: String
            var sourceLabel = "inline"
            if let path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                try context.authorizeWorkspacePath(path)
                let guarder = WorkspacePathGuard(rootURL: root)
                let url = try guarder.resolve(path)
                // Bounded no-follow regular read; the fstat inside the
                // reader closes the stat/read TOCTOU window, and the
                // cap refuses anything oversized before it is decoded.
                guard let data = try Self.readBoundedRegular(
                        url, maxBytes: SVGSafetyLimits.maxSourceBytes,
                        isCancelled: { context.cancellation.isCancelled }),
                      data.count > 0,
                      let text = String(data: data, encoding: .utf8) else {
                    throw FloeError.validationFailed("SVG source file must be a regular non-empty UTF-8 file within \(SVGSafetyLimits.maxSourceBytes) bytes")
                }
                sourceText = text
                sourceLabel = path
            } else {
                guard let inline = args.svg else {
                    throw FloeError.validationFailed("missing svg source")
                }
                sourceText = inline
            }

            // 2. Validate through the shared untrusted-document contract.
            let document: ValidatedSVGDocument
            do {
                document = try SVGDocumentValidator.validate(sourceText)
            } catch let rejection as SVGDocumentRejection {
                return Self.output(
                    "status=error error=svg_rejected code=\(rejection.code) detail=\(rejection.errorDescription ?? "") source=\(sourceLabel)",
                    exitStatus: 2)
            }

            // 3. Resolve the target raster size through the shared rules.
            guard let size = SVGRenderSize.resolve(
                metrics: document.metrics,
                requestedWidth: args.width,
                requestedHeight: args.height
            ), size.width >= 1, size.height >= 1,
               size.width <= SVGSafetyLimits.maxOutputEdge,
               size.height <= SVGSafetyLimits.maxOutputEdge,
               size.width * size.height <= SVGSafetyLimits.maxOutputPixels else {
                return Self.output(
                    "status=error error=could not resolve a safe raster size from source=\(sourceLabel)",
                    exitStatus: 2)
            }

            // 4. Render with the SAME bounded renderer as chat, honoring
            //    the run cancellation flag mid-render.
            let format = (args.format ?? "png").lowercased()
            let rasterIsJPEG = format == "jpeg"
            let pngBackground = SVGBackground.parse(args.background) ?? .transparent
            let rasterData: Data
            if rasterIsJPEG {
                rasterData = try await SVGRendering.renderJPEG(
                    document: document, width: size.width, height: size.height,
                    quality: args.quality ?? Self.jpegDefaultQuality,
                    cancellation: context.cancellation)
            } else {
                rasterData = try await SVGRendering.renderPNG(
                    document: document, width: size.width, height: size.height,
                    background: pngBackground,
                    cancellation: context.cancellation)
            }

            // 5. Prove the raster truthfully BEFORE writing: reopen with
            //    ImageIO and read the real decoded size/alpha.
            let measured = try Self.measureEncoded(rasterData, expectJPEG: rasterIsJPEG)

            // 6. Write a NEW workspace file with an EXCLUSIVE staged
            //    commit. Retrying the same trusted call at the same
            //    identity-derived default path may recover a missing
            //    receipt only when the existing bytes are bounded and
            //    byte-identical; anything else fails closed and leaves
            //    both files untouched. No overwrite exists in any path.
            let identityToken = Self.identityToken(context: context, document: document,
                                                   size: size, format: format,
                                                   background: args.background,
                                                   quality: args.quality)
            let relativePath: String
            var isDerivedPath = false
            if let outputPath = args.outputPath?.trimmingCharacters(in: .whitespacesAndNewlines),
               !outputPath.isEmpty {
                relativePath = outputPath
            } else {
                let base = sourceLabel.lowercased().hasSuffix(".svg")
                    ? ((sourceLabel as NSString).lastPathComponent as NSString).deletingPathExtension
                    : "svg"
                let sanitized = base.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted)
                    .filter { !$0.isEmpty }.joined(separator: "-")
                let name = sanitized.isEmpty ? "svg" : String(sanitized.prefix(48))
                let ext = rasterIsJPEG ? "jpg" : "png"
                relativePath = "SVGExport/\(name)-\(identityToken).\(ext)"
                isDerivedPath = true
            }
            try context.authorizeWorkspacePath(relativePath)
            let guarder = WorkspacePathGuard(rootURL: root)
            let url = try guarder.resolve(relativePath)
            try guarder.assertWritable(url)
            if FileManager.default.fileExists(atPath: url.path) {
                guard isDerivedPath,
                      url.lastPathComponent.contains(identityToken) else {
                    throw FloeError.validationFailed("Output already exists: \(relativePath)")
                }
                // Bounded compare-first: reject anything not exactly the
                // raster this call would have written (size must match
                // BEFORE any read; max read is the raster's own size).
                let existing = try Self.readBoundedRegular(
                    url, maxBytes: rasterData.count,
                    isCancelled: { context.cancellation.isCancelled })
                guard let existing, existing == rasterData else {
                    throw FloeError.validationFailed(
                        "Output already exists with different bytes: \(relativePath)")
                }
                // Reused this call's verified prior output.
            } else {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // Cancellation is honored immediately before any commit.
                try context.cancellation.throwIfCancelled()
                try Self.exclusiveStageAndLink(
                    rasterData, to: url,
                    isCancelled: { context.cancellation.isCancelled })
            }
            try context.cancellation.throwIfCancelled()

            // 7. Measure the committed bytes at this boundary (streamed
            //    digest, never a whole-file load).
            let sha256 = try FloeDigest.sha256Hex(
                ofFileAt: url,
                isCancelled: { context.cancellation.isCancelled }
            )
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let bytes = values.fileSize, bytes >= 0 else {
                return Self.output(
                    "status=error error=SVG raster output is not a regular file; the original is preserved at output=\(relativePath)",
                    exitStatus: 2)
            }
            let mimeType = measured.mimeType
            let uti = rasterIsJPEG ? UTType.jpeg.identifier : UTType.png.identifier
            let alphaFlag = measured.hasAlpha ? "true" : "false"
            let baseSummary = "status=ok output=\(relativePath) format=\(rasterIsJPEG ? "jpeg" : "png") width=\(measured.pixelWidth) height=\(measured.pixelHeight) alpha=\(alphaFlag) mime=\(mimeType) bytes=\(bytes) sha256=\(sha256) source=\(sourceLabel)"
            switch Self.runOutputBinding(context) {
            case .legacyDirect, .temporaryExempt:
                // Genuine legacy direct use and temporary (ephemeral) runs
                // keep the workspace-only result: no durable run output
                // exists for them by policy, and none is faked.
                return Self.output(baseSummary, exitStatus: 0)
            case .partiallyBound:
                return Self.output(
                    "status=error error=run output publication requires both the tool-call and task binding; the SVG raster is preserved at output=\(relativePath)",
                    exitStatus: 2)
            case .required:
                do {
                    let published = try RunOutputSnapshotStore.publish(
                        RunOutputSnapshotRequest(
                            producerTool: Self.name,
                            slot: Self.outputSlot,
                            commit: RunOutputCommit(
                                sourceURL: url,
                                sha256: sha256,
                                byteCount: bytes,
                                displayName: url.lastPathComponent,
                                mimeType: mimeType,
                                uti: uti
                            )
                        ),
                        using: context,
                        artifactRoot: artifactRootProvider()
                    )
                    return ToolExecutionOutput(
                        digesting: baseSummary + " published=\(published.displayName)",
                        exitStatus: 0,
                        outputFiles: [published]
                    )
                } catch let error as RunOutputSnapshotError {
                    // The workspace raster and its SVG source are never
                    // deleted here; only the receipt outcome changes.
                    return Self.output(
                        "status=error error=\(Self.publicationMessage(error)); the SVG raster is preserved at output=\(relativePath)",
                        exitStatus: 2)
                }
            }
        } catch is CancellationError {
            return Self.output("status=error error=SVG rendering cancelled", exitStatus: 2)
        } catch let error as SVGRenderingError {
            return Self.output("status=error error=\(error.errorDescription ?? "SVG rendering failed")", exitStatus: 2)
        } catch let error as SVGDocumentRejection {
            return Self.output(
                "status=error error=svg_rejected code=\(error.code) detail=\(error.errorDescription ?? "")",
                exitStatus: 2)
        } catch {
            return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }

    // MARK: - Truthful reopen of the encoded raster

    struct EncodedMeasure: Sendable {
        let pixelWidth: Int
        let pixelHeight: Int
        let hasAlpha: Bool
        let mimeType: String
    }

    static func measureEncoded(_ data: Data, expectJPEG: Bool) throws -> EncodedMeasure {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) == 1,
              let typeID = CGImageSourceGetType(source),
              let type = UTType(typeID as String) else {
            throw FloeError.internalError("SVG raster output could not be reopened as a single-frame image")
        }
        let conformsJPEG = type.conforms(to: .jpeg)
        let conformsPNG = type.conforms(to: .png)
        guard expectJPEG ? conformsJPEG : conformsPNG else {
            throw FloeError.internalError("SVG raster container does not match the requested format")
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw FloeError.internalError("SVG raster output carries no decodable pixel size")
        }
        let hasAlpha: Bool
        if let alphaInfo = properties[kCGImagePropertyHasAlpha] as? Bool {
            hasAlpha = conformsPNG && alphaInfo
        } else {
            hasAlpha = false
        }
        return EncodedMeasure(
            pixelWidth: width,
            pixelHeight: height,
            hasAlpha: hasAlpha,
            mimeType: conformsJPEG ? "image/jpeg" : "image/png")
    }

    // MARK: - Commit identity and exclusive write

    /// Stable per-call identity token. Bound runs derive it from the
    /// runtime-issued tool-call id plus the exact render options, so a
    /// retry of the SAME call at the SAME options lands on the SAME
    /// path (receipt recovery), while any option change (size, format,
    /// background, quality) lands on a DIFFERENT path. Unbound direct
    /// use gets a random token — never a cross-call collision.
    static func identityToken(
        context: ToolContext,
        document: ValidatedSVGDocument,
        size: (width: Int, height: Int),
        format: String,
        background: String?,
        quality: Double?
    ) -> String {
        let options = "w=\(size.width) h=\(size.height) f=\(format) b=\(background ?? "transparent") q=\(quality.map { String($0) } ?? "")"
        var digest = FloeDigest.sha256Hex(
            Data((document.sourceDigest + "|" + options).utf8))
        if let callID = context.toolCallID, !callID.isEmpty {
            digest = String(FloeDigest.sha256Hex(Data(callID.utf8)).prefix(8)) + "-" + String(digest.prefix(8))
        } else {
            digest = String(UUID().uuidString.prefix(8)).replacingOccurrences(of: "-", with: "") + "-" + String(digest.prefix(8))
        }
        return digest
    }

    /// Bounded no-follow regular-file read; returns nil when the file
    /// is not a plain single-link regular file or exceeds the cap.
    static func readBoundedRegular(
        _ url: URL,
        maxBytes: Int,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= maxBytes else { return nil }
        var bytes = Data()
        do {
            while !isCancelled() {
                guard let part = try handle.read(upToCount: min(65_536, maxBytes - bytes.count + 1)),
                      !part.isEmpty else { break }
                bytes.append(part)
                guard bytes.count <= maxBytes else { return nil }
            }
        } catch {
            throw FloeError.storageCorrupted("SVG output could not be read safely")
        }
        guard !isCancelled(), bytes.count == Int(info.st_size) else { return nil }
        return bytes
    }

    /// Writes `data` to `url` via a unique same-parent stage plus an
    /// EXCLUSIVE POSIX link. `link()` fails with EEXIST when a
    /// concurrent commit already created the destination, so a race
    /// never overwrites; the owned stage is always cleaned up.
    static func exclusiveStageAndLink(
        _ data: Data,
        to url: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        let parent = url.deletingLastPathComponent()
        let stageURL = parent.appendingPathComponent(".floe-svg-\(UUID().uuidString).stage")
        do {
            // The stage name is UUID-unique; withoutOverwriting is a
            // belt-and-braces guard, exclusivity is proven by link().
            try data.write(to: stageURL, options: [.withoutOverwriting])
        } catch {
            try? FileManager.default.removeItem(at: stageURL)
            throw error
        }
        // Cleanup touches ONLY this call's owned stage file.
        defer { try? FileManager.default.removeItem(at: stageURL) }
        if isCancelled() {
            throw CancellationError()
        }
        let result = link(stageURL.path, url.path)
        if result != 0 {
            if errno == EEXIST {
                throw FloeError.validationFailed(
                    "Output already exists: \(url.lastPathComponent)")
            }
            throw FloeError.storageCorrupted("SVG output could not be committed (\(String(cString: strerror(errno))))")
        }
        // Ownership of the staged inode ends at the successful link.
        try? FileManager.default.removeItem(at: stageURL)
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        return ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
    }

    /// S3-D binding state at the producer commit boundary — the same
    /// frozen policy the other native publishers apply (URLDownloadTool,
    /// QRCodeGenerateTool): a fully bound run MUST publish or fail
    /// observably; a genuine unbound/legacy or temporary context keeps
    /// the legacy result; a partially bound context fails honestly.
    enum RunOutputBinding: Equatable {
        case required
        case legacyDirect
        case temporaryExempt
        case partiallyBound
    }

    static func runOutputBinding(_ context: ToolContext) -> RunOutputBinding {
        let hasCall = context.toolCallID?.isEmpty == false
        let hasTask = context.conversationID != nil
        if !hasCall && !hasTask { return .legacyDirect }
        if hasCall != hasTask { return .partiallyBound }
        if context.temporaryReadOnly { return .temporaryExempt }
        return .required
    }

    /// Path-free labels for typed publication failures.
    static func publicationMessage(_ error: RunOutputSnapshotError) -> String {
        switch error {
        case .bindingMissing: return "run output publication failed (unbound)"
        case .policyRefused: return "run output publication refused by policy"
        case .identityInvalid: return "run output publication failed (invalid identity)"
        case .sourceUnavailable: return "run output publication failed (source unavailable)"
        case .commitIdentityStale: return "run output publication failed (stale commit identity)"
        case .conflict(let name): return "run output publication failed (conflict: \(name))"
        case .overCap: return "run output publication failed (over cap)"
        case .snapshotAliased: return "run output publication failed (aliased snapshot)"
        case .ioFailure: return "run output publication failed (storage)"
        }
    }
}

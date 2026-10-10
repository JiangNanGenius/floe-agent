// FloeApp — Design adapters: real editor/asset connections for the design workflow.
//
// Each adapter binds one design content type to the existing services that
// already own that content (asset ingestion, media generation, PDFKitGate,
// CadDocumentCenter, OfficeCommandCenter, browser sessions, NoteProposal).
// Adapters only advertise operations with a genuinely connected call path;
// every unavailable operation carries the real reason. The Canvas keeps
// owning the project graph and layout; revision payloads live in the shared
// artifact store (no parallel design material library).

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import UIKit
import PDFKit
import AVFoundation
import FloeCore
import FloeTools
import FloeModels
import FloeProviders
import FloePersistence
import FloeWorkbench
import FloeSkills
import FloeDocuments

// MARK: - Errors and value types

public enum DesignAdapterError: Error, Equatable {
    case unavailable(String)
    case validationFailed(String)
}

/// A source file imported by the owning editor/service, verified bytes.
public struct DesignAdapterImportedSource: Sendable {
    public let bytes: Data
    /// Real output format of the imported content (e.g. "png", "pdf").
    public let format: String
    public let displayName: String

    public init(bytes: Data, format: String, displayName: String) {
        self.bytes = bytes
        self.format = format
        self.displayName = displayName
    }
}

/// A verified export of one revision.
public struct DesignAdapterExport: Sendable {
    public let url: URL
    public let format: String
    public let byteCount: Int64
    public let contentSHA256: String

    public init(url: URL, format: String, byteCount: Int64, contentSHA256: String) {
        self.url = url
        self.format = format
        self.byteCount = byteCount
        self.contentSHA256 = contentSHA256
    }
}

// MARK: - Narrow service ports (wired to the real services in AppEnvironment)

/// Imports a user-picked source file through the existing asset ingestion.
@MainActor
protocol DesignAssetImportPort: Sendable {
    func importDesignSource(_ url: URL) async throws -> DesignAdapterImportedSource
}

/// Real image generation through the media generation service.
@MainActor
protocol DesignImageGenerationPort: Sendable {
    /// True only when a usable generation/edit model is configured right now.
    func isGenerationConfigured() -> Bool
    /// Generates with explicit Canvas ownership (canvas + document + node +
    /// durable operation identity). `agentInitiated` must be true whenever the
    /// request originates from an agent run rather than a user click. The
    /// returned result carries the bytes plus a `releaseReservation` closure
    /// the caller must invoke after the retained snapshot commit succeeds —
    /// and on every failure path — so the transient generated reservation is
    /// never leaked or discarded before durability.
    func generate(
        prompt: String,
        sourceImage: Data?,
        canvasID: UUID,
        documentID: UUID,
        nodeID: UUID,
        operationID: String,
        agentInitiated: Bool
    ) async throws -> DesignAdapterGeneratedResult
}

/// A generation result whose transient reservation is finalized by the caller
/// after the design payload snapshot has been durably committed.
struct DesignAdapterGeneratedResult: Sendable {
    let bytes: Data
    let format: String
    let releaseReservation: @Sendable () async -> Void
}

/// Browser page capture for webpage/prototype revisions.
@MainActor
protocol DesignPageCapturePort: Sendable {
    /// Captures the page bound to the EXACT originating task conversation (the
    /// same guard the browser tools enforce). Returns only allowed locator
    /// fields (url/title/viewport/scroll + non-form visual text regions) plus
    /// an optional screenshot artifact — never full DOM/form state.
    func capturePage(conversationID: UUID, runID: UUID?) async throws -> (snapshotJSON: Data, screenshotPNG: Data?)
}

/// A CAD document binding resolved from the node's recorded source path.
struct DesignCADBinding: Sendable {
    enum Dimension: Sendable { case native3D, drawing2D }
    let documentID: String
    let workspacePath: String
    let ownerID: UUID
    let dimension: Dimension
    /// The document's real on-disk format (dwg/dxf/floecad).
    let sourceFormat: String
}

/// Binding provider: resolves the explicit Canvas-owned workspace binding
/// recorded on the node's design subdocument, when any.
typealias DesignBindingProvider = @MainActor @Sendable (UUID, UUID) async -> DesignWorkspaceBinding?

/// CAD verified export through CadDocumentCenter.
@MainActor
protocol DesignCADExportPort: Sendable {
    /// Resolves the guarded canonical CAD binding recorded on the canvas node
    /// (2D drawings and 3D packages are distinct), when any.
    func binding(for canvasID: UUID, nodeID: UUID) async -> DesignCADBinding?
    func exportSource(_ binding: DesignCADBinding, format: String) async throws -> DesignAdapterImportedSource
}

/// Office verified export through OfficeCommandCenter.
@MainActor
protocol DesignOfficeExportPort: Sendable {
    func exportSource(
        documentID: String,
        workspacePath: String,
        relativeOutput: String?,
        ownerID: UUID
    ) async throws -> DesignAdapterImportedSource
}

// MARK: - Type adapters

/// One design content type bound to its real services.
@MainActor
protocol DesignTypeAdapter: Sendable {
    var contentType: DesignContentType { get }
    /// Operations with a genuinely connected call path in this build.
    var connectedOperations: Set<DesignOperation> { get }
    /// Human-readable reason an operation is unavailable.
    func unavailableReason(_ operation: DesignOperation) -> String?

    func importSource(fileURL: URL, canvasID: UUID, nodeID: UUID) async throws -> DesignAdapterImportedSource
    func generateImage(
        prompt: String, sourceImage: Data?, canvasID: UUID, documentID: UUID, nodeID: UUID,
        operationID: String, agentInitiated: Bool
    ) async throws -> DesignAdapterGeneratedResult
    /// Reopens exported bytes with the actual format parser for this content
    /// type before a verified export is claimed. Throws on malformed data.
    func verifyExportReopen(bytes: Data, format: String) async throws
    /// Previews one revision's payload by exporting a verified on-disk copy.
    func preview(verifiedBytes: Data, format: String) async throws -> URL
}

extension DesignTypeAdapter {
    func unavailableReason(_ operation: DesignOperation) -> String? {
        connectedOperations.contains(operation)
            ? nil
            : "Not connected for \(contentType.rawValue) in this build"
    }

    func importSource(fileURL: URL, canvasID: UUID, nodeID: UUID) async throws -> DesignAdapterImportedSource {
        throw DesignAdapterError.unavailable(unavailableReason(.importSource) ?? "Import is not connected")
    }

    func generateImage(
        prompt: String, sourceImage: Data?, canvasID: UUID, documentID: UUID, nodeID: UUID,
        operationID: String, agentInitiated: Bool
    ) async throws -> DesignAdapterGeneratedResult {
        throw DesignAdapterError.unavailable(unavailableReason(.generate) ?? "Generation is not connected")
    }

    func verifyExportReopen(bytes: Data, format: String) async throws {
        // Default: text-family validation (UTF-8, non-empty). Binary adapters
        // override with the real parser.
        guard !bytes.isEmpty, String(data: bytes, encoding: .utf8) != nil else {
            throw FloeError.validationFailed("Exported bytes are not valid \(format) content")
        }
    }

    func preview(verifiedBytes: Data, format: String) async throws -> URL {
        // Default preview: a verified scratch copy the native preview can open.
        let directory = try FloeScratch.makeDirectory(purpose: "media")
        let url = directory.appendingPathComponent("preview.\(format)")
        try verifiedBytes.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Image

struct ImageDesignAdapter: DesignTypeAdapter {
    let contentType: DesignContentType = .image
    let importPort: DesignAssetImportPort
    let generationPort: DesignImageGenerationPort?

    var connectedOperations: Set<DesignOperation> {
        var ops: Set<DesignOperation> = [.importSource, .preview, .sourceExport, .verifiedExport]
        if generationPort?.isGenerationConfigured() == true { ops.formUnion([.generate, .editRegion]) }
        return ops
    }

    func unavailableReason(_ operation: DesignOperation) -> String? {
        if (operation == .generate || operation == .editRegion),
           generationPort?.isGenerationConfigured() != true {
            return "Image generation needs a configured image model (Settings → Models)"
        }
        return DesignTypeAdapter_defaultReason(operation, contentType: contentType, connected: connectedOperations)
    }

    func importSource(fileURL: URL, canvasID: UUID, nodeID: UUID) async throws -> DesignAdapterImportedSource {
        try await importPort.importDesignSource(fileURL)
    }

    func generateImage(
        prompt: String, sourceImage: Data?, canvasID: UUID, documentID: UUID, nodeID: UUID,
        operationID: String, agentInitiated: Bool
    ) async throws -> DesignAdapterGeneratedResult {
        guard let generationPort else {
            throw DesignAdapterError.unavailable("Image generation is not connected")
        }
        return try await generationPort.generate(
            prompt: prompt, sourceImage: sourceImage, canvasID: canvasID, documentID: documentID,
            nodeID: nodeID, operationID: operationID, agentInitiated: agentInitiated
        )
    }

    func verifyExportReopen(bytes: Data, format: String) async throws {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String? else {
            throw FloeError.validationFailed("Exported bytes are not a decodable image")
        }
        // The declared format must match the real encoded family: a renamed
        // extension is a conversion, which this exporter does not claim.
        let declared = UTType(filenameExtension: format.lowercased()) ?? UTType(format) ?? UTType.data
        let actual = UTType(type) ?? UTType.data
        guard declared.conforms(to: .image), actual.conforms(to: declared) || declared.conforms(to: actual) else {
            throw FloeError.validationFailed("Exported image is \(type), not the recorded \(format) format")
        }
    }
}

private func DesignTypeAdapter_defaultReason(
    _ operation: DesignOperation,
    contentType: DesignContentType,
    connected: Set<DesignOperation>
) -> String? {
    connected.contains(operation) ? nil : "Not connected for \(contentType.rawValue) in this build"
}

// MARK: - PDF

struct PDFDesignAdapter: DesignTypeAdapter {
    let contentType: DesignContentType = .pdf
    let importPort: DesignAssetImportPort?

    var connectedOperations: Set<DesignOperation> {
        importPort.map { _ in [.importSource, .preview, .sourceExport, .verifiedExport] } ?? [.preview, .sourceExport, .verifiedExport]
    }

    func unavailableReason(_ operation: DesignOperation) -> String? {
        DesignTypeAdapter_defaultReason(operation, contentType: contentType, connected: connectedOperations)
    }

    func importSource(fileURL: URL, canvasID: UUID, nodeID: UUID) async throws -> DesignAdapterImportedSource {
        guard let importPort else { throw DesignAdapterError.unavailable("PDF import is not connected") }
        let source = try await importPort.importDesignSource(fileURL)
        // The real editor validation: the bytes must be an unlocked, readable
        // PDF. Anything else is rejected instead of masquerading as a PDF.
        try PDFKitGate.run {
            guard let document = PDFDocument(data: source.bytes),
                  !document.isLocked, document.pageCount > 0 else {
                throw FloeError.validationFailed("The imported file is not a readable PDF")
            }
        }
        return source
    }

    func verifyExportReopen(bytes: Data, format: String) async throws {
        guard format.lowercased() == "pdf" else {
            throw FloeError.validationFailed("PDF revisions export as pdf, not \(format)")
        }
        // All PDF work goes through the existing serial gate.
        let valid = try PDFKitGate.run { () -> Bool in
            guard let document = PDFDocument(data: bytes), !document.isLocked else { return false }
            return document.pageCount > 0
        }
        guard valid else {
            throw FloeError.validationFailed("Exported bytes are not a readable PDF")
        }
    }
}

// MARK: - Video

struct VideoDesignAdapter: DesignTypeAdapter {
    let contentType: DesignContentType = .video
    let importPort: DesignAssetImportPort?

    var connectedOperations: Set<DesignOperation> {
        importPort.map { _ in [.importSource, .preview, .sourceExport, .verifiedExport] } ?? [.preview, .sourceExport, .verifiedExport]
    }

    func unavailableReason(_ operation: DesignOperation) -> String? {
        DesignTypeAdapter_defaultReason(operation, contentType: contentType, connected: connectedOperations)
    }

    func importSource(fileURL: URL, canvasID: UUID, nodeID: UUID) async throws -> DesignAdapterImportedSource {
        guard let importPort else { throw DesignAdapterError.unavailable("Video import is not connected") }
        let source = try await importPort.importDesignSource(fileURL)
        try await verifyExportReopen(bytes: source.bytes, format: source.format)
        return source
    }

    func verifyExportReopen(bytes: Data, format: String) async throws {
        let directory = try FloeScratch.makeDirectory(purpose: "media")
        let url = directory.appendingPathComponent("verify.\(format)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try bytes.write(to: url, options: .atomic)
        let asset = AVURLAsset(url: url)
        // A real reopen: the container must parse and expose a positive
        // duration. Byte-count/hash equality alone is not format proof.
        let duration = try? await asset.load(.duration)
        guard let duration, duration.seconds > 0 else {
            throw FloeError.validationFailed("Exported bytes are not a playable \(format) video")
        }
    }
}

// MARK: - Notes (text/markdown revisions on the bound note content)

struct NotesDesignAdapter: DesignTypeAdapter {
    let contentType: DesignContentType = .notes
    let importPort: DesignAssetImportPort?

    var connectedOperations: Set<DesignOperation> {
        // Anchored feedback/candidates/adopt are the design core (connected for
        // every type via the Canvas CAS); import/export go through the port.
        importPort.map { _ in [.importSource, .preview, .sourceExport, .verifiedExport] }
            ?? [.preview, .sourceExport, .verifiedExport]
    }

    func unavailableReason(_ operation: DesignOperation) -> String? {
        DesignTypeAdapter_defaultReason(operation, contentType: contentType, connected: connectedOperations)
    }

    func importSource(fileURL: URL, canvasID: UUID, nodeID: UUID) async throws -> DesignAdapterImportedSource {
        guard let importPort else { throw DesignAdapterError.unavailable("Notes import is not connected") }
        return try await importPort.importDesignSource(fileURL)
    }
}

// MARK: - Webpage / prototype (browser snapshot revisions)

struct WebpageDesignAdapter: DesignTypeAdapter {
    enum Kind: Sendable { case webpage, prototype }
    let kind: Kind
    let importPort: DesignAssetImportPort?
    let capturePort: DesignPageCapturePort?

    var contentType: DesignContentType { kind == .webpage ? .webpage : .prototype }

    var connectedOperations: Set<DesignOperation> {
        var ops: Set<DesignOperation> = [.anchoredFeedback, .candidateRevision, .compareAdopt, .preview, .sourceExport, .verifiedExport]
        if importPort != nil { ops.insert(.importSource) }
        if capturePort != nil { ops.insert(.generate) } // capture-as-revision
        return ops
    }

    func unavailableReason(_ operation: DesignOperation) -> String? {
        switch operation {
        case .importSource where importPort == nil:
            return "Web source import needs the asset ingestion service"
        case .generate where capturePort == nil:
            return "Page capture needs the browser session for this canvas"
        default:
            return DesignTypeAdapter_defaultReason(operation, contentType: contentType, connected: connectedOperations)
        }
    }

    func importSource(fileURL: URL, canvasID: UUID, nodeID: UUID) async throws -> DesignAdapterImportedSource {
        guard let importPort else { throw DesignAdapterError.unavailable(unavailableReason(.importSource)!) }
        return try await importPort.importDesignSource(fileURL)
    }

    func verifyExportReopen(bytes: Data, format: String) async throws {
        let text = String(data: bytes, encoding: .utf8)
        guard format.lowercased() == "html" || format.lowercased() == "json" else {
            throw FloeError.validationFailed("Web revisions export as their recorded format, not \(format)")
        }
        guard let text, !text.isEmpty else {
            throw FloeError.validationFailed("Exported bytes are not valid \(format) content")
        }
    }
}

// MARK: - CAD (delegates verified export to the CAD document authority)

struct CADDesignAdapter: DesignTypeAdapter {
    let contentType: DesignContentType = .cad
    let exportPort: DesignCADExportPort?

    var connectedOperations: Set<DesignOperation> {
        exportPort.map { _ in [.importSource, .preview, .sourceExport, .verifiedExport] } ?? []
    }

    func unavailableReason(_ operation: DesignOperation) -> String? {
        if exportPort == nil {
            return "CAD design revisions bind to a canvas node with a recorded CAD source path; none is connected here"
        }
        return DesignTypeAdapter_defaultReason(operation, contentType: contentType, connected: connectedOperations)
    }

    /// Export formats genuinely supported per dimension (3D exchange set;
    /// 2D drawings only round-trip their own format — the engine does not
    /// convert).
    static func exportFormats(for dimension: DesignCADBinding.Dimension) -> Set<String> {
        switch dimension {
        case .native3D: return ["step", "stp", "stl", "obj", "3mf", "glb", "usdz", "pdf"]
        case .drawing2D: return ["dwg", "dxf"]
        }
    }

    func importSource(fileURL: URL, canvasID: UUID, nodeID: UUID) async throws -> DesignAdapterImportedSource {
        guard let exportPort else { throw DesignAdapterError.unavailable("CAD export is not connected") }
        guard let binding = await exportPort.binding(for: canvasID, nodeID: nodeID) else {
            throw DesignAdapterError.unavailable("No CAD document is bound to this canvas node")
        }
        // Adopting externally-produced CAD bytes goes through the CAD proposal
        // flow (cad.document tools with grants); the honest import here is a
        // verified export round-trip of the bound document, in its real
        // format (no conversion is claimed).
        let format = binding.dimension == .native3D ? "glb" : binding.sourceFormat
        return try await exportPort.exportSource(binding, format: format)
    }

    func verifyExportReopen(bytes: Data, format: String) async throws {
        // CAD exports are verified at the engine boundary (the CAD center
        // re-reads its own output and reports the digest); the bytes are a
        // binary container this adapter does not parse further. Hash equality
        // with the engine-reported digest is the real verification and is
        // enforced by the export port.
        guard !bytes.isEmpty else { throw FloeError.validationFailed("CAD export is empty") }
    }
}

// MARK: - Office / presentation (delegates to the office command authority)

struct OfficeDesignAdapter: DesignTypeAdapter {
    enum Kind: Sendable { case document, presentation }
    let kind: Kind
    let exportPort: DesignOfficeExportPort?
    let bindingProvider: DesignBindingProvider?

    var contentType: DesignContentType { kind == .presentation ? .presentation : .officeDocument }

    /// Connected when the office center is available and the node has an
    /// explicit Canvas-owned workspace binding.
    var connectedOperations: Set<DesignOperation> {
        exportPort.map { _ in [.importSource, .preview, .sourceExport, .verifiedExport] } ?? []
    }

    func unavailableReason(_ operation: DesignOperation) -> String? {
        if exportPort == nil {
            return "The office command center is unavailable"
        }
        return "Bind a design workspace document first (canvas.designBindDocument) — office proposals stay in the existing office flow"
    }

    /// Verified export of the bound workspace document through
    /// OfficeCommandCenter (digest-verified snapshot).
    func importSource(fileURL: URL, canvasID: UUID, nodeID: UUID) async throws -> DesignAdapterImportedSource {
        guard let exportPort else { throw DesignAdapterError.unavailable("Office export is not connected") }
        guard let binding = await bindingProvider?(canvasID, nodeID) else {
            throw DesignAdapterError.unavailable(unavailableReason(.importSource) ?? "No design workspace binding")
        }
        let relativeOutput = "design-export-\(UUID().uuidString.lowercased()).\(binding.format)"
        return try await exportPort.exportSource(
            documentID: binding.relativeDocumentPath,
            workspacePath: binding.workspaceRootPath,
            relativeOutput: relativeOutput,
            ownerID: canvasID
        )
    }

    func verifyExportReopen(bytes: Data, format: String) async throws {
        // Office export receipts are digest-verified by OfficeCommandCenter at
        // capture; the immutable-payload hash equality in the export path is
        // the verification. A non-empty sanity check only.
        guard !bytes.isEmpty else { throw FloeError.validationFailed("Office export is empty") }
    }
}

// MARK: - Real service ports (AppEnvironment wiring)

/// Source-file import through the existing asset ingestion boundary.
@MainActor
struct CreativeAssetDesignImportPort: DesignAssetImportPort {
    let environment: AppEnvironment

    func importDesignSource(_ url: URL) async throws -> DesignAdapterImportedSource {
        let service = CreativeAssetIngestionService(assetStore: environment.creativeAssetStore)
        let record = try await service.importLocalFile(url)
        let root = try FloeArtifactStore.root()
        guard let relative = record.localRelativePath else {
            throw FloeError.storageCorrupted("Imported asset has no material path")
        }
        let bytes = try Data(contentsOf: root.appendingPathComponent(relative), options: [.mappedIfSafe])
        let format = (relative as NSString).pathExtension.lowercased()
        return DesignAdapterImportedSource(
            bytes: bytes,
            format: format.isEmpty ? "bin" : format,
            displayName: record.displayName
        )
    }
}

/// Image generation through the media generation service (same resolution
/// logic as the chat image flow; no spoofed capability).
@MainActor
struct MediaGenerationDesignPort: DesignImageGenerationPort {
    let environment: AppEnvironment

    func isGenerationConfigured() -> Bool {
        let center = environment.conversationCenter
        let operation = RemoteImageOperation.generate
        guard let (provider, _) = center.auxiliaryProviderAndModel(for: operation) else { return false }
        let adapter = ImageProviderAdapterFactory().adapter(for: provider)
        return adapter?.supports(operation, for: provider) == true
    }

    func generate(
        prompt: String,
        sourceImage: Data?,
        canvasID: UUID,
        documentID: UUID,
        nodeID: UUID,
        operationID: String,
        agentInitiated: Bool
    ) async throws -> DesignAdapterGeneratedResult {
        let operation: RemoteImageOperation = sourceImage == nil ? .generate : .edit
        guard let (provider, model) = environment.conversationCenter.auxiliaryProviderAndModel(for: operation) else {
            throw FloeError.invalidConfiguration("Image generation needs a configured image model (Settings → Models)")
        }
        guard ImageProviderAdapterFactory().adapter(for: provider)?.supports(operation, for: provider) == true else {
            throw FloeError.invalidConfiguration("The selected image model or provider does not support \(operation.rawValue)")
        }
        let batch: ReservedGeneratedImageBatch
        do {
            batch = try await environment.mediaGenerationService.generateImages(
                prompt: prompt,
                sourceImages: sourceImage.map { [$0] } ?? [],
                modelID: model.id,
                owner: GeneratedImageReservationOwner(
                    canvasID: canvasID,
                    documentID: documentID,
                    configurationNodeID: nodeID,
                    generationAttemptID: "design.\(operationID)",
                    resultNodeIDs: []
                ),
                agentInitiated: agentInitiated
            )
        } catch {
            // Nothing was reserved for us to leak.
            throw error
        }
        // The transient reservation is released ONLY by the caller: after the
        // retained payload snapshot commit succeeds, or on its failure path.
        let release: @Sendable () async -> Void = { [environment] in
            await environment.mediaGenerationService.discardUnreferencedGeneratedAssets(batch)
        }
        do {
            guard let asset = batch.assets.first,
                  let relative = asset.localRelativePath else {
                await release()
                throw FloeError.storageCorrupted("Generation produced no asset path")
            }
            let root = try FloeArtifactStore.root()
            let bytes = try Data(contentsOf: root.appendingPathComponent(relative), options: [.mappedIfSafe])
            let format = (relative as NSString).pathExtension.lowercased()
            guard !format.isEmpty else {
                await release()
                throw FloeError.storageCorrupted("Generation produced no asset format")
            }
            return DesignAdapterGeneratedResult(bytes: bytes, format: format, releaseReservation: release)
        } catch {
            await release()
            throw error
        }
    }
}

/// Canvas-bound CAD export through CadDocumentCenter. Canvas CAD packages
/// live in the per-canvas CanvasCAD container and are addressed by absolute
/// path inside that workspace root.
@MainActor
struct CanvasCADDesignExportPort: DesignCADExportPort {
    let environment: AppEnvironment

    /// 1) Explicit design-workspace binding (canvas.designBindDocument) —
    /// the existing CAD engine addresses the workspace document directly.
    /// 2) Otherwise the guarded CanvasCAD source path recorded on the node.
    func binding(for canvasID: UUID, nodeID: UUID) async -> DesignCADBinding? {
        let designService = DesignCanvasService(repository: FileCanvasDocumentRepository())
        if let design = try? await designService.designState(canvasID: canvasID, nodeID: nodeID),
           let workspace = design.workspaceBinding {
            let ext = (workspace.relativeDocumentPath as NSString).pathExtension.lowercased()
            let dimension: DesignCADBinding.Dimension
            if ext == "floecad" { dimension = .native3D }
            else if ext == "dwg" || ext == "dxf" { dimension = .drawing2D }
            else { return nil }
            return DesignCADBinding(
                documentID: workspace.relativeDocumentPath,
                workspacePath: workspace.workspaceRootPath,
                ownerID: canvasID,
                dimension: dimension,
                sourceFormat: ext
            )
        }
        guard let project = try? await FileCanvasDocumentRepository().project(canvasID: canvasID),
              let node = project.documents.flatMap({ $0.nodes }).first(where: { $0.id == nodeID }),
              let key = node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath],
              key.hasPrefix(CanvasCADStorage.keyPrefix),
              let packageURL = CanvasCADStorage.packageURL(forKey: key) else { return nil }
        let ext = packageURL.pathExtension.lowercased()
        let dimension: DesignCADBinding.Dimension
        if ext == "floecad" { dimension = .native3D }
        else if ext == "dwg" || ext == "dxf" { dimension = .drawing2D }
        else { return nil }
        return DesignCADBinding(
            documentID: packageURL.path,
            workspacePath: packageURL.deletingLastPathComponent().path,
            ownerID: canvasID,
            dimension: dimension,
            sourceFormat: ext
        )
    }

    func exportSource(_ binding: DesignCADBinding, format: String) async throws -> DesignAdapterImportedSource {
        let format = format.lowercased()
        // 2D drawings export only as their own real format (the engine does
        // not convert); 3D packages export to the supported exchange set.
        if binding.dimension == .drawing2D {
            guard format == binding.sourceFormat else {
                throw FloeError.validationFailed(
                    "Cannot export a \(binding.sourceFormat) drawing as .\(format); format conversion is not supported"
                )
            }
        } else {
            guard CADDesignAdapter.exportFormats(for: binding.dimension).contains(format) else {
                throw FloeError.validationFailed(
                    "Format '\(format)' is not a supported 3D CAD export format"
                )
            }
        }
        let access = CadDocumentAccess(
            environmentID: nil,
            workspacePath: binding.workspacePath,
            ownerKind: "design-adapter",
            ownerID: binding.ownerID
        )
        let outputName = "design-export.\(format)"
        let request: [String: Any]
        let responseJSON: String
        switch binding.dimension {
        case .native3D:
            request = ["kind": "export", "payload": ["output": outputName, "format": format]]
            let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            responseJSON = try await environment.cadDocumentCenter.threeDAction(
                documentID: binding.documentID,
                requestJSON: String(data: data, encoding: .utf8)!,
                access: access
            )
        case .drawing2D:
            // 2D drawings use the engine's verified export path.
            let receipt = try await environment.cadDocumentCenter.export(
                documentID: binding.documentID,
                relativeOutput: outputName,
                access: access
            )
            let root = URL(fileURLWithPath: binding.workspacePath, isDirectory: true)
            let bytes = try Data(contentsOf: root.appendingPathComponent(receipt.relativePath), options: [.mappedIfSafe])
            guard FloeDigest.sha256Hex(bytes) == receipt.sha256.lowercased() else {
                throw FloeError.storageCorrupted("CAD 2D export failed hash verification")
            }
            return DesignAdapterImportedSource(bytes: bytes, format: format, displayName: outputName)
        }
        guard let response = try JSONSerialization.jsonObject(with: Data(responseJSON.utf8)) as? [String: Any],
              response["ok"] as? Bool == true,
              let output = response["output"] as? String,
              let sha = response["sha256"] as? String else {
            throw FloeError.validationFailed("CAD export failed: \(String(responseJSON.prefix(300)))")
        }
        let root = URL(fileURLWithPath: binding.workspacePath, isDirectory: true)
        let bytes = try Data(contentsOf: root.appendingPathComponent(output), options: [.mappedIfSafe])
        guard FloeDigest.sha256Hex(bytes) == sha.lowercased() else {
            throw FloeError.storageCorrupted("CAD export failed hash verification")
        }
        return DesignAdapterImportedSource(bytes: bytes, format: format, displayName: output)
    }
}

/// Browser page capture through the conversation's browser session. Used by
/// webpage/prototype revisions; never touches forms or credentials — the
/// snapshot is the same structured page model the browser tools produce.
@MainActor
struct BrowserPageCapturePort: DesignPageCapturePort {
    let environment: AppEnvironment

    func capturePage(conversationID: UUID, runID: UUID?) async throws -> (snapshotJSON: Data, screenshotPNG: Data?) {
        let center = environment.browserCenter
        // Exact task binding: the same guard the browser tools enforce, so a
        // capture can never read another task's session. Fail closed.
        guard center.conversationID == conversationID else {
            throw FloeError.validationFailed("This task's browser is not currently visible; page capture is bound to the originating task only")
        }
        let command = BrowserCommand(sessionID: center.sessionID, action: .observe(cursor: nil))
        let result = await center.execute(command)
        guard result.status == .ok, let page = result.page else {
            throw FloeError.validationFailed("Page capture failed: \(result.status.rawValue)")
        }
        // Privacy-filtered locator snapshot: url/title/viewport/scroll plus
        // non-form visual text regions. Full DOM nodes (which can carry form
        // values and credentials) are deliberately NOT persisted as design
        // source.
        struct LocatorSnapshot: Encodable {
            struct Region: Encodable {
                let id: String
                let text: String
                let x: Double
                let y: Double
                let width: Double
                let height: Double
            }
            let url: String
            let title: String
            let viewportWidth: Double
            let viewportHeight: Double
            let scrollX: Double
            let scrollY: Double
            let capturedAt: Date
            let regions: [Region]
        }
        let locator = LocatorSnapshot(
            url: page.url,
            title: page.title,
            viewportWidth: page.viewportWidth,
            viewportHeight: page.viewportHeight,
            scrollX: page.scrollX,
            scrollY: page.scrollY,
            capturedAt: Date(),
            regions: page.visualTextRegions.map {
                LocatorSnapshot.Region(
                    id: $0.reference,
                    text: $0.text,
                    x: Double($0.x), y: Double($0.y),
                    width: Double($0.width), height: Double($0.height)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let snapshotJSON = try encoder.encode(locator)
        let screenshot: Data?
        if let reference = page.screenshotArtifact {
            let root = try FloeArtifactStore.root()
            screenshot = try? Data(contentsOf: root.appendingPathComponent(reference.relativePath), options: [.mappedIfSafe])
        } else {
            screenshot = nil
        }
        return (snapshotJSON, screenshot)
    }
}

// MARK: - Adapter center

/// The design adapter layer: payload persistence on the shared artifact
/// authority plus per-type adapters. The panel and the agent tools drive this;
/// the Canvas keeps owning layout and node identity.
@MainActor
final class DesignAdapterCenter {
    private let payloads: DesignRevisionPayloadStore
    private let adapters: [DesignContentType: any DesignTypeAdapter]
    /// Bound by AppEnvironment after construction (the adapters already
    /// reference it; the center exposes it for the content applicator).
    private(set) weak var environment: AppEnvironment?

    init(payloads: DesignRevisionPayloadStore = DesignRevisionPayloadStore(), adapters: [DesignContentType: any DesignTypeAdapter]) {
        self.payloads = payloads
        self.adapters = adapters
    }

    func bind(environment: AppEnvironment) {
        self.environment = environment
    }

    func adapter(for contentType: DesignContentType) -> (any DesignTypeAdapter)? {
        adapters[contentType]
    }

    /// Capability registry reflecting exactly what is connected right now.
    func capabilityRegistry() -> DesignCapabilityRegistry {
        var capabilities: [DesignContentType: DesignAdapterCapability] = [:]
        let core: Set<DesignOperation> = [.anchoredFeedback, .candidateRevision, .compareAdopt]
        for type in DesignContentType.allCases {
            if let adapter = adapters[type] {
                let available = adapter.connectedOperations.union(core)
                var reasons: [DesignOperation: String] = [:]
                for operation in DesignOperation.allCases where !available.contains(operation) {
                    reasons[operation] = adapter.unavailableReason(operation) ?? "Not connected"
                }
                capabilities[type] = DesignAdapterCapability(contentType: type, available: available, unavailableReasons: reasons)
            } else {
                capabilities[type] = DesignAdapterCapability(contentType: type, available: core, unavailableReasons: [
                    .importSource: "No adapter is connected for \(type.rawValue) in this build",
                    .generate: "No adapter is connected for \(type.rawValue) in this build",
                    .editRegion: "No adapter is connected for \(type.rawValue) in this build",
                    .preview: "No adapter is connected for \(type.rawValue) in this build",
                    .sourceExport: "No adapter is connected for \(type.rawValue) in this build",
                    .verifiedExport: "No adapter is connected for \(type.rawValue) in this build"
                ])
            }
        }
        return DesignCapabilityRegistry(capabilities: capabilities)
    }

    // MARK: Payload persistence (shared artifact authority)

    func storeRevisionPayload(
        canvasID: UUID, nodeID: UUID, artifactID: String, revisionID: String,
        bytes: Data, expectedContentSHA256: String? = nil
    ) throws -> String {
        try payloads.store(
            canvasID: canvasID, nodeID: nodeID, artifactID: artifactID, revisionID: revisionID,
            bytes: bytes, expectedContentSHA256: expectedContentSHA256
        )
    }

    /// Stages a payload (verified, unpublished) so a Canvas CAS commit can
    /// record the final pointer in ONE atomic write; the caller commits after
    /// the CAS succeeds and abandons on failure.
    func stageRevisionPayload(
        canvasID: UUID, nodeID: UUID, artifactID: String, revisionID: String,
        bytes: Data, expectedContentSHA256: String? = nil
    ) throws -> DesignRevisionPayloadStore.StagedPayload {
        try payloads.stage(
            canvasID: canvasID, nodeID: nodeID, artifactID: artifactID, revisionID: revisionID,
            bytes: bytes, expectedContentSHA256: expectedContentSHA256
        )
    }

    func commitRevisionPayload(_ staged: DesignRevisionPayloadStore.StagedPayload) throws {
        try payloads.commit(staged)
    }

    func abandonRevisionPayload(_ staged: DesignRevisionPayloadStore.StagedPayload) {
        payloads.abandon(staged)
    }

    func verifiedRevisionBytes(
        canvasID: UUID, nodeID: UUID, artifactID: String, revisionID: String,
        expectedContentSHA256: String
    ) throws -> Data {
        try payloads.verifiedBytes(
            canvasID: canvasID, nodeID: nodeID, artifactID: artifactID, revisionID: revisionID,
            expectedContentSHA256: expectedContentSHA256
        )
    }

    func verifiedRevisionFile(
        canvasID: UUID, nodeID: UUID, artifactID: String, revisionID: String,
        expectedContentSHA256: String
    ) throws -> URL {
        try payloads.verifiedFile(
            canvasID: canvasID, nodeID: nodeID, artifactID: artifactID, revisionID: revisionID,
            expectedContentSHA256: expectedContentSHA256
        )
    }

    func removeRevisionPayload(canvasID: UUID, nodeID: UUID, artifactID: String, revisionID: String) throws {
        try payloads.remove(canvasID: canvasID, nodeID: nodeID, artifactID: artifactID, revisionID: revisionID)
    }

    /// Active export deliveries (lease held until superseded or released).
    private var exportDeliveries: [String: ScratchLeaseToken] = [:]

    func releaseExportDelivery(forKey key: String) {
        exportDeliveries.removeValue(forKey: key)?.release()
    }

    /// Verified export: reads the revision payload through the artifact
    /// authority (hash-verified), writes a scratch copy under the RECORDED
    /// format extension (no renaming/conversion is claimed), re-reads and
    /// re-hashes the copy, and reopens it with the actual format parser
    /// before the export is reported as verified.
    func exportVerifiedRevision(
        canvasID: UUID, nodeID: UUID, artifactID: String, revision: DesignRevision,
        artifact: DesignArtifact, requestedFormat: String?
    ) async throws -> DesignAdapterExport {
        // Format discipline: only the recorded original format may be
        // exported; a different extension would be an unproven conversion.
        guard let format = requestedFormat ?? revision.payloadFormat else {
            throw FloeError.validationFailed("This revision has no recorded payload format; re-import it with a format-aware adapter before exporting")
        }
        if let recorded = revision.payloadFormat, format != recorded {
            throw FloeError.validationFailed("Format conversion is not supported: the revision is recorded as \(recorded), not \(format)")
        }
        let bytes = try verifiedRevisionBytes(
            canvasID: canvasID, nodeID: nodeID, artifactID: artifactID, revisionID: revision.id,
            expectedContentSHA256: revision.contentSHA256
        )
        let directory = try FloeScratch.makeDirectory(purpose: "media")
        do {
            let url = directory.appendingPathComponent("export-\(artifactID.prefix(8)).\(format)")
            try bytes.write(to: url, options: .atomic)
            let copied = try Data(contentsOf: url)
            let copiedDigest = FloeDigest.sha256Hex(copied)
            guard copiedDigest == revision.contentSHA256 else {
                throw FloeError.storageCorrupted("Exported copy failed re-verification")
            }
            // Reopen with the real format parser before claiming verified.
            // Absent adapter fails closed: hash equality alone is integrity,
            // not a verified export.
            guard let adapter = adapters[artifact.contentType] else {
                throw FloeError.validationFailed("No adapter is connected for \(artifact.contentType.rawValue); refusing to claim a verified export without a real reopen parser")
            }
            try await adapter.verifyExportReopen(bytes: copied, format: format)
            // Handoff ownership: the copy stays leased until a newer
            // export of the same revision supersedes it (or the consumer
            // releases it); the 24h quiescence cutoff is the backstop.
            let key = "\(canvasID.uuidString.lowercased())/\(nodeID.uuidString.lowercased())/\(artifactID)/\(revision.id)"
            let token = await StorageCleanupLeaseCenter.shared.acquireToken(path: url.path)
            if let token {
                exportDeliveries[key]?.release()
                exportDeliveries[key] = token
            }
            return DesignAdapterExport(
                url: url, format: format, byteCount: Int64(copied.count), contentSHA256: copiedDigest
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
#endif

// MARK: - Canvas content applicator (real node adoption)

/// Turns verified candidate/restoration bytes into the REAL Canvas node
/// content update, committed in the SAME CAS transaction as the design
/// metadata via `DesignCanvasService.mutateProject`. Layout (position, size,
/// rotation, zIndex, group, document connections) is always preserved;
/// `updateOriginal` keeps the node identity and `variant` creates an actual
/// new node carrying the new content.
@MainActor
enum DesignCanvasContentApplicator {
    struct PreparedUpdate: Sendable {
        /// New asset reference for media/file nodes, when applicable.
        var asset: CanvasAssetReference?
        /// New text body for text/sticky nodes, when applicable.
        var text: String?
        /// Provenance metadata recorded on the node (hashes, never paths).
        var provenance: [String: String]
    }

    static let provenancePrefix = "design.adopt."

    /// Ingests verified payload bytes into the shared material library so the
    /// node references REAL, reopenable content.
    static func prepare(
        nodeKind: CanvasNodeKind,
        bytes: Data,
        format: String,
        displayName: String,
        candidateRevisionID: String,
        contentSHA256: String,
        environment: AppEnvironment,
        canvasID: UUID? = nil,
        nodeID: UUID? = nil
    ) async throws -> PreparedUpdate {
        var update = PreparedUpdate(provenance: [
            "\(provenancePrefix)revision": candidateRevisionID,
            "\(provenancePrefix)sha256": contentSHA256,
            "\(provenancePrefix)format": format
        ])
        switch nodeKind {
        case .image, .video:
            let type = UTType(filenameExtension: format.lowercased())
            let service = CreativeAssetIngestionService(assetStore: environment.creativeAssetStore)
            let record = try await service.importPhotoData(bytes, contentType: type, displayName: displayName)
            update.asset = CanvasAssetReference(
                id: record.id,
                contentHash: record.contentHash,
                localRelativePath: record.localRelativePath,
                mimeType: record.mimeType,
                byteCount: record.byteCount,
                license: record.license
            )
        case .file:
            // Office/presentation with an explicit binding: adopted bytes
            // become the bound workspace document (the existing editor
            // reopens it). Unbound file nodes keep the asset path.
            if let canvasID, let nodeID,
               let binding = try await boundWorkspaceDocument(
                canvasID: canvasID, nodeID: nodeID, format: format
            ) {
                try DesignWorkspace.write(bytes: bytes, to: binding)
                update.provenance["\(provenancePrefix)workspaceDocument"] = binding.relativeDocumentPath
            } else {
                let type = UTType(filenameExtension: format.lowercased())
                let service = CreativeAssetIngestionService(assetStore: environment.creativeAssetStore)
                let record = try await service.importPhotoData(bytes, contentType: type, displayName: displayName)
                update.asset = CanvasAssetReference(
                    id: record.id,
                    contentHash: record.contentHash,
                    localRelativePath: record.localRelativePath,
                    mimeType: record.mimeType,
                    byteCount: record.byteCount,
                    license: record.license
                )
            }
        case .text, .stickyNote:
            guard let text = String(data: bytes, encoding: .utf8) else {
                throw FloeError.validationFailed("The payload is not valid UTF-8 text for this node")
            }
            update.text = text
        case .scene3D:
            // With an explicit Canvas-owned workspace binding, CAD bytes are
            // written to the bound document (the CAD editor reopens it);
            // without one, adoption stays provenance-only and says so.
            if let canvasID, let nodeID,
               let binding = try await boundWorkspaceDocument(
                canvasID: canvasID, nodeID: nodeID, format: format
            ) {
                try DesignWorkspace.write(bytes: bytes, to: binding)
                update.provenance["\(provenancePrefix)workspaceDocument"] = binding.relativeDocumentPath
            } else {
                update.provenance["\(provenancePrefix)cadDelegated"] = "bind a design workspace document first (canvas.designBindDocument)"
            }
        case .card, .shape, .group, .generationTask, .audio:
            // No editable content body on these node kinds; provenance only.
            break
        }
        return update
    }


    /// Resolves the explicit Canvas-owned workspace binding recorded on the
    /// node's design subdocument, when any.
    static func boundWorkspaceDocument(
        canvasID: UUID,
        nodeID: UUID,
        format: String
    ) async throws -> DesignWorkspaceBinding? {
        let service = DesignCanvasService(repository: FileCanvasDocumentRepository())
        guard let design = try? await service.designState(canvasID: canvasID, nodeID: nodeID) else { return nil }
        return design.workspaceBinding
    }
}

/// Applies the update to the node in place (update-original). Never touches
/// position/size/rotation/zIndex/group/title. Nonisolated pure value work so
/// it can run inside the CAS body.
func designApplyContentUpdate(_ update: DesignCanvasContentApplicator.PreparedUpdate, to node: inout CanvasNode) {
    if let asset = update.asset { node.asset = asset }
    if let text = update.text { node.text = text }
    for (key, value) in update.provenance { node.metadata[key] = value }
}

/// Creates the actual variant node (same document) carrying the new content;
/// layout is copied with a small offset so both remain visible.
@discardableResult
func designApplyVariantUpdate(
    _ update: DesignCanvasContentApplicator.PreparedUpdate,
    from node: CanvasNode,
    into nodes: inout [CanvasNode]
) -> CanvasNode {
    var variant = node
    variant.id = UUID()
    variant.position = .init(x: node.position.x + 40, y: node.position.y + 40)
    variant.generationJobID = nil
    designApplyContentUpdate(update, to: &variant)
    nodes.append(variant)
    return variant
}

// MARK: - Signed templates (existing signed content-update service)

/// Maps installed signed content-update entries of kind `templates` onto
/// `DesignTemplateManifest` (read-only view). Version/hash/license/rollback
/// come from the signed content authority; install/update/rollback run
/// through the existing ContentUpdate flows, never a parallel system.
@MainActor
enum DesignSignedTemplateSource {
    /// Materializes templates installed by the SIGNED content-update service
    /// (kind `.templates`) into the design template library as read-only
    /// `.signedContent` records: the panel, engine and tools treat them like
    /// any template, while install/update/rollback/version/hash/license stay
    /// owned by the ContentUpdate authority. Called after content updates and
    /// when the design panel refreshes.
    @discardableResult
    static func refresh(environment: AppEnvironment) async -> Int {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        guard let store = try? ContentUpdateStore(root: support.appendingPathComponent("FloeAgent/ContentUpdates", isDirectory: true)),
              let templateRoot = DesignTemplateStore.defaultRoot() else { return 0 }
        let state = try await store.currentState()
        let templates = DesignTemplateStore(root: templateRoot)
        var materialized = 0
        for stored in state.entries.values where stored.entry.kind == .templates {
            let manifest = map(entry: stored, history: state.history[stored.entry.id] ?? [])
            // Payload = the installed package bytes (DESIGN.md spec/template).
            let payload = (try? await store.files(id: stored.entry.id)) ?? [:]
            let body = payload["DESIGN.md"] ?? payload.values.first ?? Data()
            guard !body.isEmpty else { continue }
            // Hash discipline: the manifest hash must match the real payload
            // bytes; the signed entry's contentDigest is the authority.
            guard FloeDigest.sha256Hex(body) == manifest.contentSHA256 else { continue }
            var signed = manifest
            signed.origin = .signedContent
            if let _ = try? templates.saveUser(manifest: signed, payload: body) {
                materialized += 1
            }
        }
        return materialized
    }

    static func installedTemplates(environment: AppEnvironment) async -> [DesignTemplateManifest] {
        _ = await refresh(environment: environment)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        guard let templateRoot = DesignTemplateStore.defaultRoot() else { return [] }
        let templates = DesignTemplateStore(root: templateRoot)
        return (try? templates.userTemplates().map(\.manifest).filter { $0.origin == .signedContent }) ?? []
    }

    static func map(entry stored: ContentUpdateState.StoredEntry, history: [ContentUpdateState.StoredEntry]) -> DesignTemplateManifest {
        let entry = stored.entry
        let contentType = DesignContentType(rawValue: entry.requiredCapabilities
            .first(where: { DesignContentType(rawValue: $0) != nil }) ?? "") ?? .webpage
        let installedVersion = stored.entry.version
        let rollbackVersion = history.first.map(\.entry.version)
        return DesignTemplateManifest(
            id: "signed.\(entry.id)",
            name: entry.id,
            contentType: contentType,
            capabilities: entry.requiredCapabilities,
            inputs: entry.dependencies,
            dependencies: entry.dependencies,
            outputFormats: [],
            license: "Signed content (official feed)",
            source: entry.sourceRevision,
            version: installedVersion,
            contentSHA256: entry.contentDigest,
            rollbackVersion: rollbackVersion,
            origin: .signedContent
        )
    }
}

// MARK: - Office export port + design binding resolution

struct OfficeDesignExportPort: DesignOfficeExportPort {
    let environment: AppEnvironment

    func exportSource(
        documentID: String,
        workspacePath: String,
        relativeOutput: String?,
        ownerID: UUID
    ) async throws -> DesignAdapterImportedSource {
        let access = OfficeCommandAccess(
            environmentID: nil,
            workspacePath: workspacePath,
            ownerKind: "design-workspace",
            ownerID: ownerID,
            conversationID: nil
        )
        let receipt = try await environment.officeCommandCenter.export(
            documentID: documentID,
            relativeOutput: relativeOutput ?? "design-export.\(documentID.pathExtension)",
            access: access
        )
        let root = URL(fileURLWithPath: workspacePath, isDirectory: true)
        let bytes = try Data(contentsOf: root.appendingPathComponent(receipt.relativePath), options: [.mappedIfSafe])
        guard FloeDigest.sha256Hex(bytes) == receipt.sha256.lowercased() else {
            throw FloeError.storageCorrupted("Office export failed hash verification")
        }
        return DesignAdapterImportedSource(
            bytes: bytes,
            format: (receipt.relativePath as NSString).pathExtension.lowercased(),
            displayName: receipt.relativePath
        )
    }
}

extension String {
    fileprivate var pathExtension: String {
        (self as NSString).pathExtension
    }
}

/// Shared binding resolution for adapters: reads the explicit Canvas-owned
/// workspace binding recorded on the node's design subdocument.
@MainActor
enum DesignBindingResolution {
    static let provider: DesignBindingProvider = { canvasID, nodeID in
        let service = DesignCanvasService(repository: FileCanvasDocumentRepository())
        guard let design = try? await service.designState(canvasID: canvasID, nodeID: nodeID) else { return nil }
        return design.workspaceBinding
    }
}

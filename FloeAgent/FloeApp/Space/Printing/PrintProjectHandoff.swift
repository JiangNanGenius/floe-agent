// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit
import Darwin
import FloeCore
import FloeCAD
import FloeWorkspace
import FloePrintCore

/// Provenance only: none of these identifiers/locators grants file access.
/// The printable geometry is an independent content-addressed .mesh asset.
nonisolated struct PrintSourceSnapshot: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case file, cad }
    var kind: Kind
    var sourceDocumentID: String
    var sourceOwnerID: String
    var sourceRevision: String
    var sourceLocator: String
    var sourceName: String
    var workspaceID: UUID?
    var conversationID: UUID?
    var savedCADRevision: Int?
    var cadChangeCount: Int?
    var sourceHadUnsavedChanges = false
    var sourceContentSHA256: String?
    var geometrySHA256 = ""
    var geometryAsset = ""
    var capturedAt = Date()
    var sourceUnitScaleToMM: Double?
    var outputUnit = "mm"
    var cadScope: String?
    var includedBodyIDs: [UUID] = []
    var includedInstanceIDs: [UUID] = []
    var acceptedPartialGeometry = false
    var excludedObjectCount = 0
    var formatLoss: [String] = []

    func validate() throws {
        guard !sourceDocumentID.isEmpty, sourceDocumentID.utf8.count <= 1_024,
              !sourceOwnerID.isEmpty, sourceOwnerID.utf8.count <= 256,
              !sourceRevision.isEmpty, sourceRevision.utf8.count <= 1_024,
              sourceLocator.utf8.count <= 4_096, !sourceLocator.hasPrefix("/"),
              sourceName.utf8.count <= 1_024, outputUnit == "mm",
              geometrySHA256.count == 64, geometrySHA256.allSatisfy(\.isHexDigit),
              geometryAsset == geometrySHA256 + ".mesh",
              includedBodyIDs.count <= 512, includedInstanceIDs.count <= 512,
              excludedObjectCount >= 0, excludedObjectCount <= 512,
              formatLoss.count <= 16, formatLoss.allSatisfy({ $0.utf8.count <= 2_048 }) else { throw PrintError.invalidMesh }
        if let sourceContentSHA256 {
            guard sourceContentSHA256.count == 64, sourceContentSHA256.allSatisfy(\.isHexDigit) else { throw PrintError.invalidMesh }
        }
        if let sourceUnitScaleToMM {
            guard sourceUnitScaleToMM.isFinite, sourceUnitScaleToMM > 0, sourceUnitScaleToMM <= 1_000_000 else { throw PrintError.invalidMesh }
        }
    }
}

@MainActor struct PrintPreparationRequest: Identifiable {
    nonisolated let id = UUID()
    let title: String
    let requiresMeshUnits: Bool
    let prepare: @MainActor @Sendable (_ title: String, _ unitScale: Double, _ acceptedCoverage: CADExchangeCoverage?) async throws -> PersonalContentRecord
}

nonisolated enum PrintHandoffError: Error {
    case sourceChanged, unsupported, incomplete(CADExchangeCoverage), emptyGeometry
}
extension PrintHandoffError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .sourceChanged: IDELanguageRunText.t("原文件已改变，请重新打开后准备打印。", "The source changed. Reopen it before preparing a print.")
        case .unsupported: IDELanguageRunText.t("请先在 CAD 中打开这个格式，再准备打印。", "Open this format in CAD before preparing a print.")
        case .incomplete: IDELanguageRunText.t("部分内容不能复制，请查看后继续。", "Some content cannot be copied. Review it before continuing.")
        case .emptyGeometry: IDELanguageRunText.t("没有可打印的几何。", "No printable geometry is available.")
        }
    }
}

private nonisolated enum PrintHandoffGeometry: Sendable {
    case mesh(PrintMesh)
    case file(Data, String, Double)
}

/// Shared native entry for Files and CAD. Existing access owners supply the
/// source; PersonalContentLibrary owns staging/promotion and recovery.
@MainActor enum PrintProjectHandoff {
    static let fileExtensions: Set<String> = ["stl", "obj", "step", "stp", "iges", "igs"]
    private static let reader = PrintSourceFileReader()

    static func workspaceRequest(center: WorkspaceCenter, path: String,
                                 conversationID: UUID?, document: FloeCADDocument?,
                                 validateAccess: @escaping @MainActor @Sendable () throws -> Void) throws -> PrintPreparationRequest {
        try validateAccess()
        guard let workspace = center.currentWorkspace, let root = center.currentRootURL else { throw PrintHandoffError.sourceChanged }
        let workspaceID = workspace.id, guardResolver = center.fileService?.guardResolver
        let remote = center.isCloudWorkspacePath(path) || center.isNetworkWorkspacePath(path)
        let name = (path as NSString).lastPathComponent
        guard document != nil || fileExtensions.contains((name as NSString).pathExtension.lowercased()) else { throw PrintHandoffError.unsupported }
        let validateRoute: @MainActor @Sendable () throws -> Void = { [weak center, weak document] in
            try Task.checkCancellation()
            try validateAccess()
            guard let center, center.currentWorkspace?.id == workspaceID, center.currentRootURL == root,
                  center.fileService?.guardResolver.rootURL == guardResolver?.rootURL,
                  (center.isCloudWorkspacePath(path) || center.isNetworkWorkspacePath(path)) == remote else { throw PrintHandoffError.sourceChanged }
            if let document {
                guard !document.isClosed, let guardResolver,
                      try guardResolver.resolve(path) == document.url.standardizedFileURL.resolvingSymlinksInPath() else { throw PrintHandoffError.sourceChanged }
            }
        }
        return .init(title: suggestedTitle(name), requiresMeshUnits: document == nil && ["stl", "obj"].contains((name as NSString).pathExtension.lowercased())) {
            [weak center, weak document] title, scale, accepted in
            try validateRoute()
            let sourceID: String
            if let document {
                let resource = try document.url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier.map { String(describing: $0) } ?? path
                sourceID = "workspace:" + workspaceID.uuidString + ":" + hash(Data(resource.utf8))
                let snapshot = try await captureCAD(document, sourceID: sourceID, ownerID: workspaceID.uuidString,
                    locator: path, sourceName: name, workspaceID: workspaceID, conversationID: conversationID, accepted: accepted)
                return try await create(title: title, geometry: .mesh(snapshot.mesh), source: snapshot.source, validateSource: {
                    try validateRoute(); try checkCAD(document, coverage: snapshot.coverage)
                })
            }
            guard let center else { throw PrintHandoffError.sourceChanged }
            let bytes: Data
            let local: PrintSourceFileData?
            if remote { bytes = try await center.readRemotePreview(relativePath: path); local = nil }
            else {
                guard let guardResolver else { throw PrintHandoffError.sourceChanged }
                let url = try guardResolver.resolve(path, for: .read(maxBytes: PrintSourceFileReader.maximumBytes))
                let input = try await reader.read(url); local = input; bytes = input.data
            }
            try validateRoute()
            let digest = hash(bytes)
            let stable = local?.resourceID ?? path
            sourceID = "workspace:" + workspaceID.uuidString + ":" + hash(Data(stable.utf8))
            let source = PrintSourceSnapshot(kind: .file, sourceDocumentID: sourceID, sourceOwnerID: workspaceID.uuidString,
                sourceRevision: "sha256:" + digest, sourceLocator: path, sourceName: name, workspaceID: workspaceID,
                conversationID: conversationID, sourceContentSHA256: digest,
                sourceUnitScaleToMM: ["stl", "obj"].contains((name as NSString).pathExtension.lowercased()) ? scale : nil)
            return try await create(title: title, geometry: .file(bytes, name, scale), source: source, validateSource: {
                try validateRoute()
                if let local, let guardResolver {
                    let url = try guardResolver.resolve(path, for: .read(maxBytes: PrintSourceFileReader.maximumBytes))
                    guard url == local.url, try await reader.read(url).sha256 == digest else { throw PrintHandoffError.sourceChanged }
                } else {
                    guard hash(try await center.readRemotePreview(relativePath: path)) == digest else { throw PrintHandoffError.sourceChanged }
                }
                try validateRoute()
            })
        }
    }

    static func personalRequest(record: PersonalContentRecord, document: FloeCADDocument?) async throws -> PrintPreparationRequest {
        let library = try await PersonalContentService.shared.library(), location = try await library.resolve(record.id)
        let expectedPath = location.record.relativePath
        let file = document == nil ? try await PersonalContentService.shared.originalFile(record.id) : nil
        guard document != nil || file.map({ fileExtensions.contains($0.pathExtension.lowercased()) }) == true else { throw PrintHandoffError.unsupported }
        let name = file?.lastPathComponent ?? record.title
        let validateOwner: @MainActor @Sendable () async throws -> Void = { [weak document] in
            try Task.checkCancellation()
            let current = try await library.resolve(record.id)
            guard current.record.relativePath == expectedPath, current.record.kind == record.kind, current.url == location.url else { throw PrintHandoffError.sourceChanged }
            if let document {
                guard !document.isClosed, document.url == current.url.appendingPathComponent("Document.floecad") else { throw PrintHandoffError.sourceChanged }
            }
        }
        return .init(title: suggestedTitle(record.title), requiresMeshUnits: document == nil && ["stl", "obj"].contains(file?.pathExtension.lowercased() ?? "")) {
            [weak document] title, scale, accepted in
            try await validateOwner()
            if let document {
                let snapshot = try await captureCAD(document, sourceID: "personal:" + record.id.uuidString,
                    ownerID: record.id.uuidString, locator: expectedPath, sourceName: record.title,
                    workspaceID: nil, conversationID: nil, accepted: accepted)
                return try await create(title: title, folders: record.folders, geometry: .mesh(snapshot.mesh), source: snapshot.source, validateSource: {
                    try await validateOwner(); try checkCAD(document, coverage: snapshot.coverage)
                })
            }
            let url = try await PersonalContentService.shared.originalFile(record.id)
            guard url == file else { throw PrintHandoffError.sourceChanged }
            let input = try await reader.read(url), digest = input.sha256
            let source = PrintSourceSnapshot(kind: .file, sourceDocumentID: "personal:" + record.id.uuidString,
                sourceOwnerID: record.id.uuidString, sourceRevision: "sha256:" + digest,
                sourceLocator: expectedPath + "/Original/" + url.lastPathComponent, sourceName: name,
                sourceContentSHA256: digest,
                sourceUnitScaleToMM: ["stl", "obj"].contains(url.pathExtension.lowercased()) ? scale : nil)
            return try await create(title: title, folders: record.folders, geometry: .file(input.data, name, scale), source: source, validateSource: {
                try await validateOwner()
                guard try await PersonalContentService.shared.originalFile(record.id) == url,
                      try await reader.read(url).sha256 == digest else { throw PrintHandoffError.sourceChanged }
            })
        }
    }

    private static func captureCAD(_ document: FloeCADDocument, sourceID: String, ownerID: String,
                                   locator: String, sourceName: String, workspaceID: UUID?, conversationID: UUID?,
                                   accepted: CADExchangeCoverage?) async throws -> (mesh: PrintMesh, source: PrintSourceSnapshot, coverage: CADExchangeCoverage) {
        guard !document.isClosed else { throw PrintHandoffError.sourceChanged }
        if let accepted { try checkCAD(document, coverage: accepted) }
        let revision = document.revision, changeCount = document.exchangeChangeCount, content = document.contentSHA256
        let outcome = document.nativePrintGeometrySnapshot(expectedRevision: revision, expectedChangeCount: changeCount,
            expectedContentSHA256: content, acceptPartial: accepted != nil)
        switch outcome {
        case let .success(data, _, coverage):
            guard data.count <= PrintSourceFileReader.maximumBytes, coverage.includedCount > 0 else { throw PrintHandoffError.emptyGeometry }
            let mesh = try await meshSnapshot(data)
            var source = PrintSourceSnapshot(kind: .cad, sourceDocumentID: sourceID, sourceOwnerID: ownerID,
                sourceRevision: "cad:\(coverage.documentRevision):\(coverage.changeCount):" + coverage.contentSHA256,
                sourceLocator: locator, sourceName: sourceName, workspaceID: workspaceID, conversationID: conversationID,
                savedCADRevision: coverage.documentRevision, cadChangeCount: coverage.changeCount,
                sourceHadUnsavedChanges: document.hasUnsavedChanges,
                sourceContentSHA256: coverage.contentSHA256.isEmpty ? nil : coverage.contentSHA256)
            source.cadScope = coverage.scope.rawValue
            source.includedBodyIDs = Array(Set(coverage.items.filter(\.included).map(\.bodyID))).sorted { $0.uuidString < $1.uuidString }
            source.includedInstanceIDs = coverage.items.filter(\.included).compactMap(\.instanceID)
            source.acceptedPartialGeometry = coverage.acceptedPartial
            source.excludedObjectCount = coverage.excludedCount
            source.formatLoss = coverage.formatLoss
            try checkCAD(document, coverage: coverage)
            return (mesh, source, coverage)
        case .coverageRequired(let coverage): throw PrintHandoffError.incomplete(coverage)
        case .coverage: throw PrintHandoffError.emptyGeometry
        case .failure(let error): throw error
        }
    }
    private static func checkCAD(_ document: FloeCADDocument, coverage: CADExchangeCoverage) throws {
        try Task.checkCancellation()
        guard !document.isClosed, document.revision == coverage.documentRevision,
              document.exchangeChangeCount == coverage.changeCount, document.contentSHA256 == coverage.contentSHA256 else { throw PrintHandoffError.sourceChanged }
    }

    private static func create(title: String, folders: [String] = [], geometry: PrintHandoffGeometry, source: PrintSourceSnapshot,
                               validateSource: @escaping @MainActor @Sendable () async throws -> Void) async throws -> PersonalContentRecord {
        let library = try await PersonalContentService.shared.library()
        let plateName = IDELanguageRunText.t("盘 1", "Plate 1")
        let record = try await library.create(kind: .printing, title: title, in: folders) { directory, id in
            let mesh = try await convertedMesh(geometry, staging: directory)
            try Task.checkCancellation()
            try await validateSource()
            let disk = PrintProjectDisk(root: directory.appendingPathComponent("Printing"))
            let asset = try await disk.storeMesh(mesh)
            var metadata = source; metadata.geometrySHA256 = mesh.sha256; metadata.geometryAsset = asset
            try metadata.validate()
            var document = PrintProjectDocument(projectID: id)
            document.sourceSnapshot = metadata
            document.meshName = source.sourceName; document.meshAsset = asset
            document.plates = [.init(id: document.plateID, name: plateName)]
            document.objects = [.init(plateID: document.plateID, name: String(source.sourceName.prefix(160)), meshAsset: asset)]
            try await disk.create(document)
            let saved = try await disk.load()
            guard saved.sourceSnapshot?.geometrySHA256 == mesh.sha256,
                  try await disk.mesh(saved).sha256 == mesh.sha256 else { throw PrintError.invalidMesh }
            try await validateSource()
            try Task.checkCancellation()
        }
        // Resolve the promoted location before UI opens a cached session. A
        // session is never registered against the temporary .creating folder.
        let saved = try await library.resolve(record.id)
        let document = try await PrintProjectDisk(root: saved.url.appendingPathComponent("Printing")).load()
        guard document.projectID == record.id, document.sourceSnapshot != nil else { throw PrintError.invalidMesh }
        NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: record.id)
        return record
    }

    private static func convertedMesh(_ geometry: PrintHandoffGeometry, staging: URL) async throws -> PrintMesh {
        switch geometry {
        case .mesh(let mesh): return mesh
        case .file(let bytes, let name, let scale):
            let format = (name as NSString).pathExtension.lowercased()
            guard fileExtensions.contains(format), scale.isFinite, scale > 0, scale <= 1_000_000 else { throw PrintHandoffError.unsupported }
            let token = MeshImportCancellation()
            return try await withTaskCancellationHandler {
                let url = staging.appendingPathComponent(".print-import.floecad", isDirectory: true)
                let document = try await FloeCADDocument.create(at: url, name: "Print geometry")
                defer { document.close(); try? FileManager.default.removeItem(at: url) }
                let outcome: CADCommandOutcome
                if ["step", "stp", "iges", "igs"].contains(format) {
                    let plan = try await CADExactImportService.parseOffMain(data: bytes, format: format, fileName: name, cancellation: token)
                    outcome = try CADExactImportService.apply(plan, to: document, cancellation: token).outcome
                } else {
                    let plan = try await CADMeshImportService.parseSingleMeshOffMain(data: bytes, fileName: name, format: format, unitScale: scale, cancellation: token)
                    guard plan.triangleCount <= 1_000_000 else { throw PrintError.sizeLimit }
                    outcome = try CADMeshImportService.applySingleMesh(plan, to: document, cancellation: token)
                }
                try Task.checkCancellation()
                guard outcome.isOK else { throw CADDocumentError(code: outcome.errorCode ?? "print_import_failed", message: outcome.message ?? "No printable geometry") }
                switch document.nativePrintGeometrySnapshot(expectedRevision: document.revision, expectedChangeCount: document.exchangeChangeCount,
                    expectedContentSHA256: document.contentSHA256) {
                case .success(let data, _, let coverage):
                    guard coverage.includedCount > 0, data.count <= PrintSourceFileReader.maximumBytes else { throw PrintHandoffError.emptyGeometry }
                    let mesh = try await meshSnapshot(data)
                    try Task.checkCancellation(); return mesh
                // A raw-file conversion with incomplete geometry must first
                // be reviewed in its own CAD document. A receipt from this
                // throwaway parser cannot authorize a later different parse.
                case .coverageRequired: throw PrintHandoffError.unsupported
                case .coverage: throw PrintHandoffError.emptyGeometry
                case .failure(let error): throw error
                }
            } onCancel: { token.cancel() }
        }
    }
    private static func suggestedTitle(_ name: String) -> String {
        let cleaned = String(((name as NSString).deletingPathExtension).prefix(110))
            .replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: "\\", with: " ").replacingOccurrences(of: ":", with: " ")
            .components(separatedBy: .controlCharacters).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? IDELanguageRunText.t("模型", "Model") : cleaned) + IDELanguageRunText.t(" 打印", " Print")
    }
    private nonisolated static func meshSnapshot(_ data: Data) async throws -> PrintMesh {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let mesh = try PrintMesh(binarySTL: data)
            try Task.checkCancellation()
            return mesh
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    private nonisolated static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}

private nonisolated struct PrintSourceFileData: Sendable {
    let url: URL
    let data: Data
    let resourceID: String
    var sha256: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
/// The URL is supplied by an existing native owner/guard, never model input.
private actor PrintSourceFileReader {
    nonisolated static let maximumBytes = 50_000_084
    func read(_ url: URL) throws -> PrintSourceFileData {
        try Task.checkCancellation()
        guard url.isFileURL else { throw PrintHandoffError.unsupported }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw PrintHandoffError.sourceChanged }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0, before.st_size <= Int64(Self.maximumBytes) else { throw PrintError.sizeLimit }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count <= Self.maximumBytes - bytes.count else { throw PrintError.sizeLimit }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        var after = stat(), path = stat()
        guard fstat(descriptor, &after) == 0, lstat(url.path, &path) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_size == Int64(bytes.count),
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              path.st_dev == after.st_dev, path.st_ino == after.st_ino, (path.st_mode & S_IFMT) == S_IFREG else { throw PrintHandoffError.sourceChanged }
        return .init(url: url, data: bytes, resourceID: "\(before.st_dev):\(before.st_ino)")
    }
}
#endif

// SPDX-License-Identifier: MPL-2.0
import Foundation
import ZIPFoundation
import Crypto
import FloeCore

/// Canvas backup package: the canvas project plus every bound child media
/// project (INCLUDING the assets those projects reference) and every
/// node-referenced Materials asset, in one zip.
///
/// Restore is staged and transactional in structure:
///   1. entries stream to a private staging directory (bounded, duplicate
///      entry names are refused),
///   2. EVERY SHA-256 is verified while still in staging,
///   3. destinations are validated (containment, Materials allowlist, no
///      symlink escape) and content collisions are remapped to unique names,
///   4. only then are bytes moved into place; a mid-commit failure rolls back
///      the files this restore created.
/// A restore therefore never leaves partially-imported children or clobbered
/// same-name assets behind.
public enum CanvasBackupPackage {
    public static let formatVersion = 1
    public static let canvasEntry = "canvas.json"
    public static let manifestEntry = "manifest.json"

    public struct Manifest: Codable, Sendable, Equatable {
        public var formatVersion: Int
        public var canvasID: UUID
        public var canvasName: String
        public var canvasSchemaVersion: Int
        public var exportedAt: Date
        public var canvasByteCount: Int64
        public var canvasSHA256: String
        /// Child media projects carried in the package.
        public var childProjects: [ChildProject]
        /// Node-referenced materials (filename-only under Materials/).
        public var materials: [Material]
        /// Assets referenced by the carried child projects, keyed to the
        /// fallback media root (WorkbenchRoot).
        public var assets: [ChildAsset]
        /// Node assets that live directly under the fallback media root
        /// (WorkbenchRoot/...), e.g. CAD drawing nodes. Their app-root-relative
        /// path is kept verbatim so the node reference restores correctly.
        public var externalNodeAssets: [NodeAsset]
        /// Bound child projects whose bytes were unavailable at export time;
        /// bindings pointing at them stay but are listed here truthfully.
        public var missingChildProjects: [UUID]
        /// Referenced asset paths whose bytes were unavailable at export time.
        public var missingAssets: [String]
        /// External node asset paths whose bytes were unavailable at export
        /// time; the node reference survives but the bytes are listed here.
        public var missingExternalNodeAssets: [String]
        /// Unapplied CAD drafts carried by the package (durable user edits
        /// not yet adopted by a node), descriptor + drawing bytes each.
        public var cadDrafts: [CADDraft]
        /// Immutable CAD revision bytes referenced by node revision history.
        public var cadRevisionAssets: [CADRevisionAsset]
        /// CAD revision paths whose bytes were unavailable at export time.
        public var missingCADRevisionAssets: [String]

        public init(formatVersion: Int, canvasID: UUID, canvasName: String,
                    canvasSchemaVersion: Int, exportedAt: Date,
                    canvasByteCount: Int64, canvasSHA256: String,
                    childProjects: [ChildProject], materials: [Material],
                    assets: [ChildAsset], missingChildProjects: [UUID],
                    missingAssets: [String],
                    externalNodeAssets: [NodeAsset] = [],
                    missingExternalNodeAssets: [String] = [],
                    cadDrafts: [CADDraft] = [],
                    cadRevisionAssets: [CADRevisionAsset] = [],
                    missingCADRevisionAssets: [String] = []) {
            self.formatVersion = formatVersion
            self.canvasID = canvasID
            self.canvasName = canvasName
            self.canvasSchemaVersion = canvasSchemaVersion
            self.exportedAt = exportedAt
            self.canvasByteCount = canvasByteCount
            self.canvasSHA256 = canvasSHA256
            self.childProjects = childProjects
            self.materials = materials
            self.assets = assets
            self.externalNodeAssets = externalNodeAssets
            self.missingChildProjects = missingChildProjects
            self.missingAssets = missingAssets
            self.missingExternalNodeAssets = missingExternalNodeAssets
            self.cadDrafts = cadDrafts
            self.cadRevisionAssets = cadRevisionAssets
            self.missingCADRevisionAssets = missingCADRevisionAssets
        }

        // Packages written before external node assets existed decode with
        // empty lists instead of failing.
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try values.decode(Int.self, forKey: .formatVersion)
            canvasID = try values.decode(UUID.self, forKey: .canvasID)
            canvasName = try values.decodeIfPresent(String.self, forKey: .canvasName) ?? ""
            canvasSchemaVersion = try values.decodeIfPresent(Int.self, forKey: .canvasSchemaVersion) ?? 1
            exportedAt = try values.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
            canvasByteCount = try values.decodeIfPresent(Int64.self, forKey: .canvasByteCount) ?? 0
            canvasSHA256 = try values.decodeIfPresent(String.self, forKey: .canvasSHA256) ?? ""
            childProjects = try values.decodeIfPresent([ChildProject].self, forKey: .childProjects) ?? []
            materials = try values.decodeIfPresent([Material].self, forKey: .materials) ?? []
            assets = try values.decodeIfPresent([ChildAsset].self, forKey: .assets) ?? []
            externalNodeAssets = try values.decodeIfPresent([NodeAsset].self, forKey: .externalNodeAssets) ?? []
            missingChildProjects = try values.decodeIfPresent([UUID].self, forKey: .missingChildProjects) ?? []
            missingAssets = try values.decodeIfPresent([String].self, forKey: .missingAssets) ?? []
            missingExternalNodeAssets = try values.decodeIfPresent(
                [String].self, forKey: .missingExternalNodeAssets) ?? []
            cadDrafts = try values.decodeIfPresent([CADDraft].self, forKey: .cadDrafts) ?? []
            cadRevisionAssets = try values.decodeIfPresent(
                [CADRevisionAsset].self, forKey: .cadRevisionAssets) ?? []
            missingCADRevisionAssets = try values.decodeIfPresent(
                [String].self, forKey: .missingCADRevisionAssets) ?? []
        }
    }

    public struct ChildProject: Codable, Sendable, Equatable {
        public var projectID: UUID
        public var file: String
        public var byteCount: Int64
        public var sha256: String

        public init(projectID: UUID, file: String, byteCount: Int64, sha256: String) {
            self.projectID = projectID
            self.file = file
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    public struct Material: Codable, Sendable, Equatable {
        /// Filename ONLY (no separators), written under Materials/.
        public var fileName: String
        public var byteCount: Int64
        public var sha256: String

        public init(fileName: String, byteCount: Int64, sha256: String) {
            self.fileName = fileName
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    public struct ChildAsset: Codable, Sendable, Equatable {
        /// Original path relative to the media root (no leading slash).
        public var relativePath: String
        /// Package entry name (assets/<index>-<basename>).
        public var file: String
        public var byteCount: Int64
        public var sha256: String

        public init(relativePath: String, file: String, byteCount: Int64, sha256: String) {
            self.relativePath = relativePath
            self.file = file
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    /// A node asset carried outside Materials/, addressed by its
    /// app-root-relative path (e.g. `WorkbenchRoot/drawings/plate.dwg`).
    public struct NodeAsset: Codable, Sendable, Equatable {
        public var relativePath: String
        public var file: String
        public var byteCount: Int64
        public var sha256: String

        public init(relativePath: String, file: String, byteCount: Int64, sha256: String) {
            self.relativePath = relativePath
            self.file = file
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    /// One unapplied CAD draft carried in the package.
    public struct CADDraft: Codable, Sendable, Equatable {
        /// Original owning node id (node ids are preserved by restore).
        public var nodeID: UUID
        /// Original canvas id (recorded for ownership validation).
        public var canvasID: UUID
        /// Package entry for the durable draft descriptor JSON.
        public var descriptorFile: String
        /// Package entry for the staged drawing bytes.
        public var drawingFile: String
        public var drawingByteCount: Int64
        public var drawingSHA256: String
        public var descriptorByteCount: Int64
        public var descriptorSHA256: String

        public init(nodeID: UUID, canvasID: UUID,
                    descriptorFile: String, drawingFile: String,
                    drawingByteCount: Int64, drawingSHA256: String,
                    descriptorByteCount: Int64, descriptorSHA256: String) {
            self.nodeID = nodeID
            self.canvasID = canvasID
            self.descriptorFile = descriptorFile
            self.drawingFile = drawingFile
            self.drawingByteCount = drawingByteCount
            self.drawingSHA256 = drawingSHA256
            self.descriptorByteCount = descriptorByteCount
            self.descriptorSHA256 = descriptorSHA256
        }
    }

    /// Immutable CAD revision bytes referenced by a node's typed revision
    /// history (older adopts and the immutable original).
    public struct CADRevisionAsset: Codable, Sendable, Equatable {
        /// Original stored path, verbatim: Materials/<name> or
        /// WorkbenchRoot/<...>.
        public var relativePath: String
        /// Package entry carrying the bytes.
        public var file: String
        public var byteCount: Int64
        public var sha256: String

        public init(relativePath: String, file: String,
                    byteCount: Int64, sha256: String) {
            self.relativePath = relativePath
            self.file = file
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    /// Export-side source for one unapplied CAD draft.
    public struct CADDraftSource: Sendable, Equatable {
        public var descriptor: CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor
        public var descriptorJSON: Data
        public var drawingData: Data

        public init(descriptor: CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor,
                    descriptorJSON: Data, drawingData: Data) {
            self.descriptor = descriptor
            self.descriptorJSON = descriptorJSON
            self.drawingData = drawingData
        }
    }

    /// Export-side file reference for one unapplied CAD draft. Used by the
    /// production file-backed path: bytes are streamed from these owned URLs
    /// one draft at a time, never preloaded into a Data array.
    public struct CADDraftFileSource: Sendable, Equatable {
        public var descriptor: CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor
        public var descriptorJSONURL: URL
        public var drawingURL: URL

        public init(descriptor: CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor,
                    descriptorJSONURL: URL, drawingURL: URL) {
            self.descriptor = descriptor
            self.descriptorJSONURL = descriptorJSONURL
            self.drawingURL = drawingURL
        }
    }

    public enum BackupError: Error, LocalizedError, Equatable {
        case unsupportedFormat(Int)
        case corrupt(String)
        case hashMismatch(String)
        case unsafePath(String)
        /// A source file failed export preflight (missing, not a regular
        /// file, symlink escaping its workspace root, or over the size cap).
        case sourceFile(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let version):
                return "画布备份格式版本 \(version) 不受支持，请升级应用后再导入。"
            case .corrupt(let detail):
                return "画布备份已损坏：\(detail)"
            case .hashMismatch(let name):
                return "画布备份校验失败：\(name)"
            case .unsafePath(let path):
                return "画布备份包含不安全路径：\(path)"
            case .sourceFile(let detail):
                return "导出前检查未通过：\(detail)"
            }
        }
    }

    static let maximumEntry: Int64 = 512 * 1024 * 1024
    static let maximumTotal: Int64 = 2 * 1024 * 1024 * 1024

    private struct PlannedFile {
        var source: URL
        var byteCount: Int64
        var sha256: String
        var label: String
    }

    // MARK: Export

    /// Builds the backup zip. `childProjectData` returns the stored project
    /// JSON for a bound project id (nil when unavailable); `materialData`
    /// returns bytes for a filename under Materials/; `assetData` returns
    /// bytes for a media-root-relative asset path. Unavailable bytes are
    /// RECORDED in the manifest (never silently skipped) so the importer can
    /// surface them.
    /// Builds the backup zip. Payloads are staged as FILES (never held in
    /// memory together), the running total is bounded, referenced materials
    /// with missing bytes are an EXPLICIT error (never silently skipped), and
    /// unavailable child bytes are recorded in the manifest for the importer
    /// to surface.
    public static func make(project: CanvasProject,
                            childProjectData: (UUID) throws -> Data?,
                            materialData: (String) throws -> Data?,
                            assetData: (String) throws -> Data?,
                            externalNodeAssetData: (String) throws -> Data? = { _ in nil },
                            cadDraftSources: () throws -> [CADDraftSource] = { [] }) throws -> Data {
        let url = try makeZip(project: project, childProjectData: childProjectData,
                              materialData: materialData, assetData: assetData,
                              externalNodeAssetData: externalNodeAssetData,
                              cadDraftItems: { try cadDraftSources().map(DraftItem.memory) },
                              maximumDataBytes: maximumInMemoryBytes)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// One draft item to stage: in-memory bytes (bounded convenience API) or
    /// an owned file reference (production streaming path).
    private enum DraftItem {
        case memory(CADDraftSource)
        case file(CADDraftFileSource)

        var descriptor: CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor {
            switch self {
            case .memory(let source): source.descriptor
            case .file(let source): source.descriptor
            }
        }
    }

    private static func makeZip(project: CanvasProject,
                                childProjectData: (UUID) throws -> Data?,
                                materialData: (String) throws -> Data?,
                                assetData: (String) throws -> Data?,
                                externalNodeAssetData: (String) throws -> Data?,
                                cadDraftItems: () throws -> [DraftItem],
                                revisionAssetData: ((String) throws -> Data?)? = nil,
                                maximumDataBytes: Int64) throws -> URL {
        let manager = FileManager.default
        let totalCap = min(maximumTotal, maximumDataBytes)
        let staging = manager.temporaryDirectory
            .appendingPathComponent("canvas-backup-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        var total: Int64 = 0
        func stage(_ data: Data, as name: String) throws -> URL {
            total += Int64(data.count)
            guard total <= totalCap else {
                throw BackupError.corrupt("备份超过大小限制（内存导出 64 MB，文件导出 2 GB）。")
            }
            let url = staging.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return url
        }
        /// Streaming file stage: size is preflighted/accounted BEFORE bytes
        /// are copied, then the source is streamed in bounded chunks through
        /// SHA-256 into the staged file. Never loads the draft into memory.
        func stageFile(from source: URL, as name: String) throws -> (Int64, String) {
            let resolved = source.standardizedFileURL.resolvingSymlinksInPath()
            let attributes = try manager.attributesOfItem(atPath: resolved.path)
            let size = (attributes[.size] as? Int64) ?? 0
            guard size > 0 else { throw BackupError.corrupt("CAD 草稿内容为空。") }
            total += size
            guard total <= totalCap else {
                throw BackupError.corrupt("备份超过大小限制（内存导出 64 MB，文件导出 2 GB）。")
            }
            let destination = staging.appendingPathComponent(name)
            try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            guard manager.createFile(atPath: destination.path, contents: nil) else {
                throw BackupError.corrupt("无法暂存 CAD 草稿。")
            }
            let readHandle = try FileHandle(forReadingFrom: resolved)
            let writeHandle = try FileHandle(forWritingTo: destination)
            defer { try? readHandle.close(); try? writeHandle.close() }
            var hasher = SHA256()
            var copied: Int64 = 0
            while true {
                let chunk = try readHandle.read(upToCount: 2 * 1024 * 1024) ?? Data()
                guard !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                try writeHandle.write(contentsOf: chunk)
                copied += Int64(chunk.count)
            }
            guard copied == size else {
                throw BackupError.hashMismatch(source.lastPathComponent)
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return (size, digest)
        }
        func stagedData(_ name: String) throws -> Data {
            try Data(contentsOf: staging.appendingPathComponent(name))
        }

        let childIDs = Self.boundChildProjectIDs(in: project)
        var children: [ChildProject] = []
        var missingChildren: [UUID] = []
        var assetPaths = Set<String>()
        for id in childIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let data = try childProjectData(id), !data.isEmpty else {
                missingChildren.append(id)
                continue
            }
            let name = "child-\(id.uuidString.lowercased()).json"
            try stage(data, as: name)
            children.append(ChildProject(
                projectID: id,
                file: "projects/\(id.uuidString.lowercased()).json",
                byteCount: Int64(data.count),
                sha256: Self.digest(data)))
            for path in Self.assetPaths(inProjectJSON: data) {
                assetPaths.insert(path)
            }
        }

        var materials: [Material] = []
        var missingMaterials: [String] = []
        for fileName in Self.referencedMaterialNames(in: project).sorted() {
            guard let data = try materialData(fileName), !data.isEmpty else {
                missingMaterials.append(fileName)
                continue
            }
            try stage(data, as: "material-\(fileName)")
            materials.append(Material(
                fileName: fileName,
                byteCount: Int64(data.count),
                sha256: Self.digest(data)))
        }
        guard missingMaterials.isEmpty else {
            throw BackupError.corrupt("备份缺少被节点引用的素材：\(missingMaterials.joined(separator: ", "))")
        }

        var assets: [ChildAsset] = []
        var missingAssets: [String] = []
        for path in assetPaths.sorted() {
            guard let data = try assetData(path), !data.isEmpty else {
                missingAssets.append(path)
                continue
            }
            let base = (path as NSString).lastPathComponent
            let name = "asset-\(assets.count)-\(base)"
            try stage(data, as: name)
            assets.append(ChildAsset(
                relativePath: path,
                file: "assets/\(assets.count)-\(base)",
                byteCount: Int64(data.count),
                sha256: Self.digest(data)))
        }

        var nodeAssets: [NodeAsset] = []
        var missingNodeAssets: [String] = []
        for path in Self.referencedExternalNodePaths(in: project).sorted() {
            guard let data = try externalNodeAssetData(path), !data.isEmpty else {
                missingNodeAssets.append(path)
                continue
            }
            let base = (path as NSString).lastPathComponent
            let index = nodeAssets.count
            try stage(data, as: "nodeasset-\(index)-\(base)")
            nodeAssets.append(NodeAsset(
                relativePath: path,
                file: "nodeassets/\(index)-\(base)",
                byteCount: Int64(data.count),
                sha256: Self.digest(data)))
        }

        // CAD unapplied drafts: ownership-validated by the caller, staged as
        // descriptor + drawing pairs. They are independent from node asset
        // payloads and carry user work not yet adopted by any node.
        // CAD unapplied drafts: ownership-validated descriptor + drawing
        // pairs. They are independent from node asset payloads and carry
        // user work not yet adopted by any node.
        let draftItems = try cadDraftItems()
        var cadDrafts: [CADDraft] = []
        for (index, item) in draftItems.enumerated() {
            let descriptor = item.descriptor
            guard descriptor.canvasID == project.id,
                  project.documents.contains(where: { document in
                      document.nodes.contains { $0.id == descriptor.nodeID }
                  }) else {
                throw BackupError.corrupt("CAD 草稿的归属校验失败。")
            }
            let drawingExt = (descriptor.stagedRelativePath as NSString).pathExtension
            guard !drawingExt.isEmpty else {
                throw BackupError.corrupt("CAD 草稿缺少图纸格式。")
            }
            let drawingFile = "caddrafts/\(index)-\(descriptor.nodeID.uuidString.lowercased()).\(drawingExt)"
            let descriptorFile = "caddrafts/\(index)-\(descriptor.nodeID.uuidString.lowercased()).draft.json"
            let drawingSize: Int64
            let drawingHash: String
            let descriptorSize: Int64
            let descriptorHash: String
            switch item {
            case .memory(let source):
                guard !source.drawingData.isEmpty,
                      Int64(source.drawingData.count) <= maximumEntry,
                      !source.descriptorJSON.isEmpty else {
                    throw BackupError.corrupt("CAD 草稿的内容校验失败。")
                }
                try stage(source.drawingData, as: "caddraft-\(index)-drawing")
                try stage(source.descriptorJSON, as: "caddraft-\(index)-descriptor")
                drawingSize = Int64(source.drawingData.count)
                drawingHash = Self.digest(source.drawingData)
                descriptorSize = Int64(source.descriptorJSON.count)
                descriptorHash = Self.digest(source.descriptorJSON)
            case .file(let source):
                let (streamedDrawingSize, streamedDrawingHash) =
                    try stageFile(from: source.drawingURL, as: "caddraft-\(index)-drawing")
                let (streamedDescriptorSize, streamedDescriptorHash) =
                    try stageFile(from: source.descriptorJSONURL,
                                  as: "caddraft-\(index)-descriptor")
                drawingSize = streamedDrawingSize
                drawingHash = streamedDrawingHash
                descriptorSize = streamedDescriptorSize
                descriptorHash = streamedDescriptorHash
            }
            guard drawingSize <= maximumEntry else {
                throw BackupError.sourceFile("CAD 草稿超过单条目大小限制。")
            }
            cadDrafts.append(CADDraft(
                nodeID: descriptor.nodeID,
                canvasID: descriptor.canvasID,
                descriptorFile: descriptorFile,
                drawingFile: drawingFile,
                drawingByteCount: drawingSize,
                drawingSHA256: drawingHash,
                descriptorByteCount: descriptorSize,
                descriptorSHA256: descriptorHash))
        }

        // CAD revision history bytes: every stored path node history points
        // at that is not already carried as a current material/node asset.
        // Refuse when a node carries unclosable raw history: never omit.
        try CanvasDrawingRevisionHistory.requireClosableHistory(in: project)
        var carriedPaths = Set<String>()
        for material in materials { carriedPaths.insert("Materials/\(material.fileName)") }
        for nodeAsset in nodeAssets { carriedPaths.insert(nodeAsset.relativePath) }
        var revisionAssets: [CADRevisionAsset] = []
        var missingRevisionAssets: [String] = []
        let revisionPathList = CanvasDrawingRevisionHistory.revisionRelativePaths(in: project)
        for path in revisionPathList where !carriedPaths.contains(path) {
            let data: Data?
            if path.hasPrefix("Materials/") {
                let fileName = String(path.dropFirst("Materials/".count))
                guard !fileName.isEmpty, !fileName.contains("/") else {
                    throw BackupError.unsafePath(path)
                }
                if let revisionProvider = revisionAssetData {
                    data = try revisionProvider(path)
                } else {
                    data = try materialData(fileName)
                }
            } else if path.hasPrefix("WorkbenchRoot/") {
                if let revisionProvider = revisionAssetData {
                    data = try revisionProvider(path)
                } else {
                    data = try externalNodeAssetData(path)
                }
            } else {
                throw BackupError.unsafePath(path)
            }
            guard let bytes = data, !bytes.isEmpty else {
                missingRevisionAssets.append(path)
                continue
            }
            let base = (path as NSString).lastPathComponent
            let index = revisionAssets.count
            try stage(bytes, as: "cadrevision-\(index)-\(base)")
            revisionAssets.append(CADRevisionAsset(
                relativePath: path,
                file: "cadrevisions/\(index)-\(base)",
                byteCount: Int64(bytes.count),
                sha256: Self.digest(bytes)))
        }

        let canvasData = try CanvasProjectCodec.encode(project)
        try stage(canvasData, as: "canvas.json")
        let manifest = Manifest(
            formatVersion: formatVersion,
            canvasID: project.id,
            canvasName: project.name,
            canvasSchemaVersion: project.schemaVersion,
            exportedAt: Date(),
            canvasByteCount: Int64(canvasData.count),
            canvasSHA256: Self.digest(canvasData),
            childProjects: children,
            materials: materials,
            assets: assets,
            missingChildProjects: missingChildren,
            missingAssets: missingAssets,
            externalNodeAssets: nodeAssets,
            missingExternalNodeAssets: missingNodeAssets,
            cadDrafts: cadDrafts,
            cadRevisionAssets: revisionAssets,
            missingCADRevisionAssets: missingRevisionAssets)
        let manifestData = try JSONEncoder().encode(manifest)
        try stage(manifestData, as: "manifest.json")

        let temporary = manager.temporaryDirectory
            .appendingPathComponent("canvas-backup-\(UUID().uuidString).zip")
        guard let archive = Archive(url: temporary, accessMode: .create) else {
            try? manager.removeItem(at: temporary)
            throw BackupError.corrupt("无法创建备份存档。")
        }
        func appendEntry(_ packagePath: String, stagedName: String, sha: String) throws {
            let source = staging.appendingPathComponent(stagedName)
            let attributes = try manager.attributesOfItem(atPath: source.path)
            let size = (attributes[.size] as? Int64) ?? 0
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            var hasher = SHA256()
            try archive.addEntry(with: packagePath, type: .file,
                                 uncompressedSize: size,
                                 compressionMethod: .deflate) { position, chunkSize in
                try handle.seek(toOffset: UInt64(position))
                let data = try handle.read(upToCount: chunkSize) ?? Data()
                hasher.update(data: data)
                return data
            }
            let finalized = hasher.finalize()
            let digest = finalized.map { String(format: "%02x", $0) }.joined()
            guard digest == sha else { throw BackupError.hashMismatch(packagePath) }
        }
        try appendEntry(canvasEntry, stagedName: "canvas.json", sha: manifest.canvasSHA256)
        try appendEntry(manifestEntry, stagedName: "manifest.json",
                        sha: Self.digest(manifestData))
        for child in children {
            try appendEntry(child.file, stagedName: "child-\(child.projectID.uuidString.lowercased()).json",
                            sha: child.sha256)
        }
        for material in materials {
            try appendEntry("materials/\(material.fileName)",
                            stagedName: "material-\(material.fileName)", sha: material.sha256)
        }
        for asset in assets {
            try appendEntry(asset.file, stagedName: stagedAssetName(asset), sha: asset.sha256)
        }
        for nodeAsset in nodeAssets {
            try appendEntry(nodeAsset.file, stagedName: stagedNodeAssetName(nodeAsset),
                            sha: nodeAsset.sha256)
        }
        for (index, draft) in manifest.cadDrafts.enumerated() {
            try appendEntry(draft.drawingFile,
                            stagedName: "caddraft-\(index)-drawing",
                            sha: draft.drawingSHA256)
            try appendEntry(draft.descriptorFile,
                            stagedName: "caddraft-\(index)-descriptor",
                            sha: draft.descriptorSHA256)
        }
        for revisionAsset in revisionAssets {
            try appendEntry(revisionAsset.file,
                            stagedName: stagedCADRevisionName(revisionAsset),
                            sha: revisionAsset.sha256)
        }
        return temporary
    }

    /// File-backed export for production sharing: the zip is built at
    /// `destination` and never fully resident in memory. Payload reads still
    /// go through the providers; callers must preflight each source file
    /// (the app providers read bounded workspace files).
    public static func makeToURL(project: CanvasProject, destination: URL,
                                 childProjectData: (UUID) throws -> Data?,
                                 materialData: (String) throws -> Data?,
                                 assetData: (String) throws -> Data?,
                                 externalNodeAssetData: (String) throws -> Data? = { _ in nil },
                                 revisionAssetData: ((String) throws -> Data?)? = nil,
                                 cadDraftFileSources: () throws -> [CADDraftFileSource] = { [] }) throws {
        let temporary = try makeZip(project: project,
                                    childProjectData: childProjectData,
                                    materialData: materialData,
                                    assetData: assetData,
                                    externalNodeAssetData: externalNodeAssetData,
                                    cadDraftItems: { try cadDraftFileSources().map(DraftItem.file) },
                                    revisionAssetData: revisionAssetData,
                                    maximumDataBytes: maximumFileBackedBytes)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// Where production export resolves its payloads from.
    ///
    /// - `projectsRoot`: FloeAgent/MediaProjects (the recorded child project
    ///   JSONs).
    /// - `materialsRoot`: FloeAgent/Materials (filename-only assets).
    /// - `fallbackMediaRoot`: WorkbenchRoot, used only for a child project
    ///   that has no recorded `taskWorkspacePath`.
    public struct ExportLayout: Sendable {
        public var projectsRoot: URL
        public var materialsRoot: URL
        public var fallbackMediaRoot: URL
        /// Root of durable CAD drawing drafts (`<floeRoot>/CanvasDrafts`).
        /// Required by the production path; nil only for legacy callers that
        /// do not export CAD drafts (export then fails if drafts exist).
        public var cadDraftsRoot: URL?
        /// Bound for a child project JSON document.
        public var maximumChildProjectBytes: Int64
        /// Bound for one material/asset payload.
        public var maximumEntryBytes: Int64
        /// Bound for the sum of all preflighted payloads.
        public var maximumTotalBytes: Int64

        public init(projectsRoot: URL, materialsRoot: URL, fallbackMediaRoot: URL,
                    cadDraftsRoot: URL? = nil,
                    maximumChildProjectBytes: Int64 = 8 * 1024 * 1024,
                    maximumEntryBytes: Int64 = 512 * 1024 * 1024,
                    maximumTotalBytes: Int64 = 2 * 1024 * 1024 * 1024) {
            self.projectsRoot = projectsRoot
            self.materialsRoot = materialsRoot
            self.fallbackMediaRoot = fallbackMediaRoot
            self.cadDraftsRoot = cadDraftsRoot
            self.maximumChildProjectBytes = maximumChildProjectBytes
            self.maximumEntryBytes = maximumEntryBytes
            self.maximumTotalBytes = maximumTotalBytes
        }
    }

    /// Production, file-backed export with a full preflight.
    ///
    /// For every bound child project this resolves the media root from the
    /// project's recorded `taskWorkspacePath` (falling back to
    /// `layout.fallbackMediaRoot` only when absent) and validates every
    /// referenced material/asset BEFORE the destination is written: regular
    /// files only (symlinks must resolve inside their workspace root), bounded
    /// sizes, safe relative paths. A missing child project or asset is
    /// recorded truthfully in the manifest by the shared builder; a hostile,
    /// escaping or oversize source refuses the whole export without creating
    /// the destination.
    public static func exportToURL(project: CanvasProject, destination: URL,
                                   layout: ExportLayout) throws {
        let manager = FileManager.default
        let projectsRoot = layout.projectsRoot.standardizedFileURL.resolvingSymlinksInPath()
        let materialsRoot = layout.materialsRoot.standardizedFileURL.resolvingSymlinksInPath()
        let fallbackMediaRoot = layout.fallbackMediaRoot.standardizedFileURL.resolvingSymlinksInPath()
        let cadDraftsRoot = layout.cadDraftsRoot?.standardizedFileURL.resolvingSymlinksInPath()

        struct ChildSource {
            var jsonURL: URL
            var assetURLs: [String: URL]
        }
        var childSources: [UUID: ChildSource] = [:]
        var resolvedAssets: [String: URL] = [:]
        var total: Int64 = 0

        for id in boundChildProjectIDs(in: project).sorted(by: { $0.uuidString < $1.uuidString }) {
            let jsonURL = projectsRoot.appendingPathComponent(
                "media-project-\(id.uuidString.lowercased()).json")
            guard manager.fileExists(atPath: jsonURL.path) else { continue }
            try validatedSourceFile(at: jsonURL, under: projectsRoot,
                                    maximumBytes: layout.maximumChildProjectBytes,
                                    label: "子工程 \(id.uuidString)")
            let jsonData = try boundedData(at: jsonURL,
                                           maximumBytes: layout.maximumChildProjectBytes,
                                           label: "子工程 \(id.uuidString)")
            total += Int64(jsonData.count)
            guard let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                throw BackupError.corrupt("子工程 \(id.uuidString) 不是有效 JSON。")
            }
            let mediaRoot: URL
            if let recorded = object["taskWorkspacePath"] as? String, !recorded.isEmpty {
                mediaRoot = URL(fileURLWithPath: recorded)
                    .standardizedFileURL.resolvingSymlinksInPath()
            } else {
                mediaRoot = fallbackMediaRoot
            }
            var assetURLs: [String: URL] = [:]
            for path in assetPaths(inProjectJSON: jsonData) {
                guard let assetURL = try? validatedDestination(
                    under: mediaRoot, relativePath: path) else {
                    throw BackupError.unsafePath(path)
                }
                guard manager.fileExists(atPath: assetURL.path) else { continue }
                let size = try validatedSourceFile(at: assetURL, under: mediaRoot,
                                                   maximumBytes: layout.maximumEntryBytes,
                                                   label: path)
                total += size
                guard total <= layout.maximumTotalBytes else {
                    throw BackupError.sourceFile("备份超过大小限制。")
                }
                assetURLs[path] = assetURL
            }
            childSources[id] = ChildSource(jsonURL: jsonURL, assetURLs: assetURLs)
            for (path, url) in assetURLs {
                if let existing = resolvedAssets[path], existing != url {
                    throw BackupError.corrupt(
                        "不同子工程引用了同一相对路径但位置不同的素材：\(path)。")
                }
                resolvedAssets[path] = url
            }
        }

        var materialURLs: [String: URL] = [:]
        var missingMaterials: [String] = []
        for fileName in referencedMaterialNames(in: project).sorted() {
            let url = materialsRoot.appendingPathComponent(fileName)
            guard manager.fileExists(atPath: url.path) else {
                missingMaterials.append(fileName)
                continue
            }
            let size = try validatedSourceFile(at: url, under: materialsRoot,
                                               maximumBytes: layout.maximumEntryBytes,
                                               label: fileName)
            total += size
            guard total <= layout.maximumTotalBytes else {
                throw BackupError.sourceFile("备份超过大小限制。")
            }
            materialURLs[fileName] = url
        }
        guard missingMaterials.isEmpty else {
            throw BackupError.corrupt(
                "备份缺少被节点引用的素材：\(missingMaterials.joined(separator: ", "))")
        }

        // Node assets outside Materials/ (e.g. CAD drawing nodes stored under
        // the fallback WorkbenchRoot) must ship with the package; anything
        // else is refused explicitly instead of silently omitted.
        for doc in project.documents {
            for node in doc.nodes {
                guard let relative = node.asset?.localRelativePath, !relative.isEmpty else { continue }
                if relative.hasPrefix("Materials/") || relative.hasPrefix("WorkbenchRoot/") { continue }
                if relative.hasPrefix("/") || relative.contains("..") {
                    throw BackupError.unsafePath(relative)
                }
                throw BackupError.sourceFile("节点素材不在可备份位置：\(relative)")
            }
        }
        var nodeAssetURLs: [String: URL] = [:]
        var missingNodeAssets: [String] = []
        for path in referencedExternalNodePaths(in: project).sorted() {
            let suffix = String(path.dropFirst("WorkbenchRoot/".count))
            guard let url = try? validatedDestination(
                under: fallbackMediaRoot, relativePath: suffix) else {
                throw BackupError.unsafePath(path)
            }
            guard manager.fileExists(atPath: url.path) else {
                missingNodeAssets.append(path)
                continue
            }
            let size = try validatedSourceFile(at: url, under: fallbackMediaRoot,
                                               maximumBytes: layout.maximumEntryBytes,
                                               label: path)
            total += size
            guard total <= layout.maximumTotalBytes else {
                throw BackupError.sourceFile("备份超过大小限制。")
            }
            nodeAssetURLs[path] = url
        }
        guard missingNodeAssets.isEmpty else {
            throw BackupError.sourceFile(
                "备份缺少被节点引用的图纸/素材：\(missingNodeAssets.joined(separator: ", "))")
        }

        // Scan ONLY this canvas's owned draft directory, pairing each
        // descriptor with its drawing via the descriptor's own
        // stagedRelativePath. Everything is preflighted (containment, regular
        // file, sizes, total cap) before the destination is created; bytes
        // are later streamed one draft at a time. A legacy caller without a
        // drafts root keeps the prior behavior (drafts not exported); the
        // production path always supplies one.
        let nodeIDsByID = Dictionary(uniqueKeysWithValues:
            project.documents.flatMap(\.nodes).map { ($0.id, $0) })

        var draftFileSources: [CADDraftFileSource] = []
        if let cadDraftsRoot {
            let canvasDraftDirectory = cadDraftsRoot
                .appendingPathComponent(project.id.uuidString.lowercased(), isDirectory: true)
            if manager.fileExists(atPath: canvasDraftDirectory.path) {
            guard let nodeEnumerator = manager.enumerator(
                at: canvasDraftDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsSubdirectoryDescendants]) else {
                throw BackupError.corrupt("无法读取 CAD 草稿目录。")
            }
            for case let nodeDirectory as URL in nodeEnumerator {
                let nodeDirectoryID = nodeDirectory.lastPathComponent
                guard let nodeUUID = UUID(uuidString: nodeDirectoryID),
                      nodeIDsByID[nodeUUID] != nil else {
                    // Unknown subdirectory (not a current node): skip without
                    // touching; do not export drafts with no owner.
                    continue
                }
                guard let fileEnumerator = manager.enumerator(
                    at: nodeDirectory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsSubdirectoryDescendants]) else {
                    throw BackupError.corrupt("无法读取 CAD 草稿目录。")
                }
                var descriptorURLs: [URL] = []
                for case let fileURL as URL in fileEnumerator {
                    if fileURL.lastPathComponent.hasSuffix(".draft.json") {
                        descriptorURLs.append(fileURL)
                    }
                }
                for descriptorURL in descriptorURLs.sorted(by: { $0.path < $1.path }) {
                    let descriptorSize = try validatedSourceFile(
                        at: descriptorURL, under: cadDraftsRoot,
                        maximumBytes: 1 * 1024 * 1024,
                        label: "CAD 草稿描述")
                    let descriptorData = try boundedData(
                        at: descriptorURL, maximumBytes: 1 * 1024 * 1024,
                        label: "CAD 草稿描述")
                    guard let descriptor = try? JSONDecoder().decode(
                        CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor.self,
                        from: descriptorData) else {
                        throw BackupError.corrupt("CAD 草稿描述无法解析。")
                    }
                    guard descriptor.canvasID == project.id,
                          descriptor.nodeID == nodeUUID,
                          !descriptor.stagedRelativePath.contains(".."),
                          !descriptor.stagedRelativePath.hasPrefix("/") else {
                        throw BackupError.corrupt("CAD 草稿的归属或路径不安全。")
                    }
                    // The descriptor must address a drawing inside exactly
                    // this node draft directory.
                    let pathComponents = descriptor.stagedRelativePath
                        .split(separator: "/", omittingEmptySubsequences: true)
                        .map(String.init)
                    guard pathComponents.count == 3,
                          pathComponents[0] == project.id.uuidString.lowercased(),
                          pathComponents[1] == nodeUUID.uuidString.lowercased() else {
                        throw BackupError.corrupt("CAD 草稿路径与归属不一致。")
                    }
                    let drawingURL = cadDraftsRoot
                        .appendingPathComponent(descriptor.stagedRelativePath)
                    guard manager.fileExists(atPath: drawingURL.path) else {
                        throw BackupError.sourceFile(
                            "CAD 缺少草稿图纸文件：\(descriptor.stagedRelativePath)")
                    }
                    let drawingSize = try validatedSourceFile(
                        at: drawingURL, under: cadDraftsRoot,
                        maximumBytes: layout.maximumEntryBytes,
                        label: "CAD 草稿图纸")
                    total += drawingSize + descriptorSize
                    guard total <= layout.maximumTotalBytes else {
                        throw BackupError.sourceFile("备份超过大小限制。")
                    }
                    draftFileSources.append(CADDraftFileSource(
                        descriptor: descriptor,
                        descriptorJSONURL: descriptorURL,
                        drawingURL: drawingURL))
                }
            }
        }
        }

        // Revision history bytes preflight. Resolve every stored path the
        // node histories reference that is not already carried as a current
        // asset; production refuses a missing revision instead of silently
        // shipping partial history, and refuses unclosable raw metadata.
        try CanvasDrawingRevisionHistory.requireClosableHistory(in: project)
        var carriedPaths = Set<String>()
        for fileName in materialURLs.keys { carriedPaths.insert("Materials/\(fileName)") }
        for path in nodeAssetURLs.keys { carriedPaths.insert(path) }
        var revisionURLs: [String: URL] = [:]
        for path in CanvasDrawingRevisionHistory.revisionRelativePaths(in: project)
        where !carriedPaths.contains(path) {
            let resolved: URL
            if path.hasPrefix("Materials/") {
                let fileName = String(path.dropFirst("Materials/".count))
                guard !fileName.isEmpty, !fileName.contains("/") else {
                    throw BackupError.unsafePath(path)
                }
                resolved = materialsRoot.appendingPathComponent(fileName)
            } else if path.hasPrefix("WorkbenchRoot/") {
                let suffix = String(path.dropFirst("WorkbenchRoot/".count))
                resolved = try validatedDestination(
                    under: fallbackMediaRoot, relativePath: suffix)
            } else {
                throw BackupError.unsafePath(path)
            }
            guard manager.fileExists(atPath: resolved.path) else {
                throw BackupError.sourceFile("备份缺少历史版本文件：\(path)")
            }
            let size = if path.hasPrefix("Materials/") {
                try validatedSourceFile(at: resolved, under: materialsRoot,
                                        maximumBytes: layout.maximumEntryBytes, label: path)
            } else {
                try validatedSourceFile(at: resolved, under: fallbackMediaRoot,
                                        maximumBytes: layout.maximumEntryBytes, label: path)
            }
            total += size
            guard total <= layout.maximumTotalBytes else {
                throw BackupError.sourceFile("备份超过大小限制。")
            }
            revisionURLs[path] = resolved
        }

        try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        try makeToURL(
            project: project,
            destination: destination,
            childProjectData: { id in
                guard let source = childSources[id] else { return nil }
                return try? Data(contentsOf: source.jsonURL, options: .mappedIfSafe)
            },
            materialData: { fileName in
                guard let url = materialURLs[fileName] else { return nil }
                return try? Data(contentsOf: url, options: .mappedIfSafe)
            },
            assetData: { path in
                guard let url = resolvedAssets[path] else { return nil }
                return try? Data(contentsOf: url, options: .mappedIfSafe)
            },
            externalNodeAssetData: { path in
                if let url = nodeAssetURLs[path] {
                    return try? Data(contentsOf: url, options: .mappedIfSafe)
                }
                if let url = revisionURLs[path] {
                    return try? Data(contentsOf: url, options: .mappedIfSafe)
                }
                return nil
            },
            revisionAssetData: { path in
                guard let url = revisionURLs[path] else { return nil }
                return try? Data(contentsOf: url, options: .mappedIfSafe)
            },
            cadDraftFileSources: { draftFileSources })
    }

    /// ZIP detection for import preflight: reads only the first bytes from
    /// disk (never the whole package) so a multi-hundred-MB package is not
    /// loaded into memory on the main actor.
    public static func looksLikeZipArchive(at source: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 4) ?? Data()
        return magic.prefix(2) == Data([0x50, 0x4B])
    }

    @discardableResult
    private static func validatedSourceFile(at url: URL, under root: URL,
                                            maximumBytes: Int64, label: String) throws -> Int64 {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") else {
            throw BackupError.sourceFile("\(label) 指向工作区之外。")
        }
        guard let values = try? resolved.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true else {
            throw BackupError.sourceFile("\(label) 不是常规文件。")
        }
        let size = Int64(values.fileSize ?? 0)
        guard size <= maximumBytes else {
            throw BackupError.sourceFile("\(label) 超过大小限制。")
        }
        return size
    }

    private static func boundedData(at url: URL, maximumBytes: Int64, label: String) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? Int64) ?? 0
        guard size <= maximumBytes else {
            throw BackupError.sourceFile("\(label) 超过大小限制。")
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// In-memory compatibility bound: above this, callers must use
    /// `makeToURL` (file-backed) instead of holding the zip as Data.
    public static let maximumInMemoryBytes: Int64 = 64 * 1024 * 1024
    private static let maximumFileBackedBytes: Int64 = 2 * 1024 * 1024 * 1024

    private static func stagedAssetName(_ asset: ChildAsset) -> String {
        // Mirrors the staging name chosen in make(): asset-<index>-<base>.
        let base = (asset.relativePath as NSString).lastPathComponent
        guard let index = Int(asset.file.split(separator: "/").last?.split(separator: "-").first ?? "") else {
            return asset.file
        }
        return "asset-\(index)-\(base)"
    }

    private static func stagedNodeAssetName(_ asset: NodeAsset) -> String {
        // Mirrors the staging name chosen in make(): nodeasset-<index>-<base>.
        let base = (asset.relativePath as NSString).lastPathComponent
        guard let index = Int(asset.file.split(separator: "/").last?.split(separator: "-").first ?? "") else {
            return asset.file
        }
        return "nodeasset-\(index)-\(base)"
    }

    private static func stagedCADRevisionName(_ asset: CADRevisionAsset) -> String {
        // Mirrors the staging name chosen in make(): cadrevision-<index>-<base>.
        let base = (asset.relativePath as NSString).lastPathComponent
        guard let index = Int(asset.file.split(separator: "/").last?.split(separator: "-").first ?? "") else {
            return asset.file
        }
        return "cadrevision-\(index)-\(base)"
    }

    // MARK: Import

    public struct Restored {
        /// Canvas project with a fresh id and remapped child-project bindings.
        public var project: CanvasProject
        public var manifest: Manifest
        /// material fileName → restored fileName (identity unless remapped).
        public var remappedMaterials: [String: String]
        /// media-relative asset path → restored relative path (identity
        /// unless remapped after a content collision).
        public var remappedAssets: [String: String]
        /// app-root-relative external node asset path → restored path
        /// (identity unless remapped after a content collision).
        public var remappedNodeAssets: [String: String]
        /// Original CAD revision path → restored path after collision remap.
        public var remappedRevisionPaths: [String: String]
        /// Node ids whose unapplied CAD drafts were restored (resumable).
        public var restoredDraftNodeIDs: [UUID]

        public init(project: CanvasProject, manifest: Manifest,
                    remappedMaterials: [String: String],
                    remappedAssets: [String: String],
                    remappedNodeAssets: [String: String],
                    remappedRevisionPaths: [String: String] = [:],
                    restoredDraftNodeIDs: [UUID] = []) {
            self.project = project
            self.manifest = manifest
            self.remappedMaterials = remappedMaterials
            self.remappedAssets = remappedAssets
            self.remappedNodeAssets = remappedNodeAssets
            self.remappedRevisionPaths = remappedRevisionPaths
            self.restoredDraftNodeIDs = restoredDraftNodeIDs
        }
    }

    /// Staged, verified restore from a file on disk. Nothing but the archive
    /// header is read into memory up front; entries stream into staging.
    /// Everything lands inside `floeRoot`: Materials/<name>,
    /// MediaProjects/<id>.json and the fallback media root
    /// WorkbenchRoot/<relativePath>. Restored child projects have their
    /// `taskWorkspacePath` cleared (the packaged assets live in the fallback
    /// root here), so `WorkbenchPaths` resolves them from WorkbenchRoot.
    /// On ANY validation or hash failure the file system is left untouched; on
    /// a mid-commit failure every file this restore created is removed again.
    /// `finalize` (the canvas registry write) runs AFTER the payload commits
    /// and its failure rolls them back.
    @discardableResult
    public static func restore(fileURL: URL, floeRoot: URL,
                               finalize: ((CanvasProject) throws -> Void)? = nil) throws -> Restored {
        try restoreArchive(at: fileURL, floeRoot: floeRoot, finalize: finalize)
    }

    /// Staged, verified restore for an in-memory package (legacy callers and
    /// tests). Prefer `restore(fileURL:)` for large packages.
    @discardableResult
    public static func restore(data: Data, floeRoot: URL,
                               finalize: ((CanvasProject) throws -> Void)? = nil) throws -> Restored {
        let manager = FileManager.default
        let archiveFile = manager.temporaryDirectory
            .appendingPathComponent("canvas-restore-input-\(UUID().uuidString).zip")
        try data.write(to: archiveFile, options: .atomic)
        defer { try? manager.removeItem(at: archiveFile) }
        return try restoreArchive(at: archiveFile, floeRoot: floeRoot, finalize: finalize)
    }

    private static func restoreArchive(at archiveSource: URL, floeRoot: URL,
                                       finalize: ((CanvasProject) throws -> Void)?) throws -> Restored {
        let manager = FileManager.default
        let canonicalRoot = floeRoot.standardizedFileURL.resolvingSymlinksInPath()
        let materialsRoot = try containedDirectory(canonicalRoot, "Materials", create: true)
        let projectsRoot = try containedDirectory(canonicalRoot, "MediaProjects", create: true)
        let mediaRoot = try containedDirectory(canonicalRoot, "WorkbenchRoot", create: true)
        let cadDraftsRoot = try containedDirectory(
            canonicalRoot, CanvasDrawingNodePlanner.draftRootDirectoryName, create: true)
        // The restored canvas identity is fixed before destinations resolve so
        // carried drafts can be rewritten onto it.
        let restoredCanvasID = UUID()

        // Phase 1: stream entries into a private staging directory.
        let staging = manager.temporaryDirectory
            .appendingPathComponent("canvas-restore-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        guard let archive = Archive(url: archiveSource, accessMode: .read) else {
            throw BackupError.corrupt("无法读取备份存档。")
        }
        var staged: [String: URL] = [:]
        var stagedBytes: [String: Int64] = [:]
        var total: Int64 = 0
        for entry in archive where entry.type == .file {
            guard !staged.keys.contains(entry.path) else {
                throw BackupError.corrupt("重复条目 \(entry.path)。")
            }
            let entrySize = Int64(entry.uncompressedSize)
            guard entrySize >= 0, entrySize <= maximumEntry else {
                throw BackupError.corrupt("条目超过大小限制。")
            }
            total += entrySize
            guard total <= maximumTotal else {
                throw BackupError.corrupt("备份超过 2 GB。")
            }
            // Entry names are package-relative and verified against the
            // manifest before use; staging uses a flat index-based name.
            let stagedURL = staging.appendingPathComponent("entry-\(staged.count).bin")
            do {
                _ = try archive.extract(entry, to: stagedURL, skipCRC32: false, progress: nil)
                let attributes = try FileManager.default.attributesOfItem(atPath: stagedURL.path)
                guard (attributes[.size] as? Int64) == entrySize else {
                    throw BackupError.hashMismatch(entry.path)
                }
            } catch let error as BackupError {
                throw error
            } catch {
                throw BackupError.corrupt("无法解压 \(entry.path)。")
            }
            staged[entry.path] = stagedURL
            stagedBytes[entry.path] = entrySize
        }

        // Phase 2: manifest + canvas integrity (still in staging; nothing
        // outside the staging dir has been touched).
        guard let manifestURL = staged[manifestEntry] else {
            throw BackupError.corrupt("缺少 manifest.json。")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.formatVersion <= formatVersion else {
            throw BackupError.unsupportedFormat(manifest.formatVersion)
        }
        guard let canvasURL = staged[canvasEntry] else {
            throw BackupError.corrupt("缺少 canvas.json。")
        }
        let canvasData = try Data(contentsOf: canvasURL)
        guard Int64(canvasData.count) == manifest.canvasByteCount,
              Self.digest(canvasData) == manifest.canvasSHA256 else {
            throw BackupError.hashMismatch(canvasEntry)
        }
        var project = try CanvasProjectCodec.decode(canvasData)
        guard (1...CanvasProject.currentSchemaVersion).contains(project.schemaVersion) else {
            throw BackupError.unsupportedFormat(project.schemaVersion)
        }
        guard !project.documents.isEmpty else {
            throw BackupError.corrupt("画布备份不包含任何文档。")
        }

        // Phase 3: verify EVERY carried payload before any commit.
        var plan: [PlannedFile] = []
        func requireStaged(_ file: String, _ byteCount: Int64, _ sha256: String, _ label: String) throws -> PlannedFile {
            guard let url = staged[file] else { throw BackupError.corrupt("缺少 \(label) \(file)。") }
            let data = try Data(contentsOf: url)
            guard Int64(data.count) == byteCount, Self.digest(data) == sha256 else {
                throw BackupError.hashMismatch(file)
            }
            return PlannedFile(source: url, byteCount: byteCount, sha256: sha256, label: label)
        }
        _ = plan
        var childPlans: [UUID: PlannedFile] = [:]
        for child in manifest.childProjects {
            childPlans[child.projectID] = try requireStaged(child.file, child.byteCount, child.sha256, "子工程")
        }
        var materialPlans: [String: PlannedFile] = [:]
        for material in manifest.materials {
            materialPlans[material.fileName] = try requireStaged(
                "materials/\(material.fileName)", material.byteCount, material.sha256, "素材")
        }
        var assetPlans: [String: PlannedFile] = [:]
        for asset in manifest.assets {
            assetPlans[asset.relativePath] = try requireStaged(
                asset.file, asset.byteCount, asset.sha256, "工程素材")
        }
        var nodeAssetPlans: [String: PlannedFile] = [:]
        for nodeAsset in manifest.externalNodeAssets {
            nodeAssetPlans[nodeAsset.relativePath] = try requireStaged(
                nodeAsset.file, nodeAsset.byteCount, nodeAsset.sha256, "节点素材")
        }

        // Carried unapplied CAD drafts: verify descriptor + drawing pairs and
        // that the descriptor decodes with ownership matching the manifest.
        struct RestoredDraft {
            var drawingPlan: PlannedFile
            var descriptorPlan: PlannedFile
            var descriptor: CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor
            var drawingDestination: URL
            var descriptorDestination: URL
            /// The rewritten descriptor JSON committed for the new canvas.
            var rewrittenDescriptorData: Data
        }
        var restoredDrafts: [RestoredDraft] = []
        for draft in manifest.cadDrafts {
            let drawingPlan = try requireStaged(
                draft.drawingFile, draft.drawingByteCount, draft.drawingSHA256, "CAD 草稿")
            let descriptorPlan = try requireStaged(
                draft.descriptorFile, draft.descriptorByteCount,
                draft.descriptorSHA256, "CAD 草稿描述")
            let descriptorData = try Data(contentsOf: descriptorPlan.source)
            guard let descriptor = try? JSONDecoder().decode(
                CanvasDrawingNodePlanner.CanvasDrawingDraftDescriptor.self,
                from: descriptorData) else {
                throw BackupError.corrupt("CAD 草稿描述无法解析。")
            }
            guard descriptor.nodeID == draft.nodeID,
                  descriptor.canvasID == draft.canvasID,
                  manifest.canvasID == descriptor.canvasID,
                  !descriptor.stagedRelativePath.contains(".."),
                  !descriptor.stagedRelativePath.hasPrefix("/") else {
                throw BackupError.corrupt("CAD 草稿的归属校验失败。")
            }
            // Resolve the destination under the NEW canvas id; node ids and
            // the drawing basename are preserved, only the canvas prefix and
            // descriptor fields change.
            let drawingBase = (draft.drawingFile as NSString).lastPathComponent
            let descriptorBase = (draft.descriptorFile as NSString).lastPathComponent
            let nodeDirectory = "\(restoredCanvasID.uuidString.lowercased())/\(draft.nodeID.uuidString.lowercased())"
            let drawingDestination = cadDraftsRoot
                .appendingPathComponent(nodeDirectory, isDirectory: true)
                .appendingPathComponent(drawingBase)
            let descriptorDestination = cadDraftsRoot
                .appendingPathComponent(nodeDirectory, isDirectory: true)
                .appendingPathComponent(descriptorBase)
            guard let drawingDestination = try? validatedDestination(
                under: cadDraftsRoot,
                relativePath: String(drawingDestination.path.dropFirst(
                    cadDraftsRoot.path.count + 1))),
                  let descriptorDestination = try? validatedDestination(
                    under: cadDraftsRoot,
                    relativePath: String(descriptorDestination.path.dropFirst(
                        cadDraftsRoot.path.count + 1))) else {
                throw BackupError.unsafePath("CAD 草稿恢复路径不安全。")
            }
            var rewrittenDescriptor = descriptor
            rewrittenDescriptor.canvasID = restoredCanvasID
            rewrittenDescriptor.stagedRelativePath = String(
                drawingDestination.path.dropFirst(cadDraftsRoot.path.count + 1))
            // Keep the unapplied state: a carried draft stays unapplied and
            // must never auto-delete. The original source hash/path is kept
            // so reopen compares against the node's still-current baseline.
            let rewrittenData = try JSONEncoder().encode(rewrittenDescriptor)
            restoredDrafts.append(.init(
                drawingPlan: drawingPlan, descriptorPlan: descriptorPlan,
                descriptor: rewrittenDescriptor,
                drawingDestination: drawingDestination,
                descriptorDestination: descriptorDestination,
                rewrittenDescriptorData: rewrittenData))
        }

        // Carried CAD revision bytes. Destinations mirror the original stored
        // path (Materials filename-only or WorkbenchRoot relative) with
        // collision-aware remapping; history entries are rewritten to match.
        var revisionDestinations: [String: URL] = [:]
        var revisionPlans: [String: PlannedFile] = [:]
        var remappedRevisionPaths: [String: String] = [:]
        for revisionAsset in manifest.cadRevisionAssets {
            let planFile = try requireStaged(
                revisionAsset.file, revisionAsset.byteCount,
                revisionAsset.sha256, "CAD 历史版本")
            let destination: URL
            if revisionAsset.relativePath.hasPrefix("Materials/") {
                let fileName = String(
                    revisionAsset.relativePath.dropFirst("Materials/".count))
                guard !fileName.isEmpty, !fileName.contains("/") else {
                    throw BackupError.unsafePath(revisionAsset.relativePath)
                }
                let candidate = try validatedDestination(
                    under: materialsRoot, fileName: fileName)
                destination = try collisionAwareDestination(
                    candidate, planFile: planFile)
            } else if revisionAsset.relativePath.hasPrefix("WorkbenchRoot/") {
                let suffix = String(
                    revisionAsset.relativePath.dropFirst("WorkbenchRoot/".count))
                let candidate = try validatedDestination(
                    under: mediaRoot, relativePath: suffix)
                destination = try collisionAwareDestination(
                    candidate, planFile: planFile)
            } else {
                throw BackupError.unsafePath(revisionAsset.relativePath)
            }
            revisionDestinations[revisionAsset.relativePath] = destination
            revisionPlans[revisionAsset.relativePath] = planFile
            let restoredPath: String
            if revisionAsset.relativePath.hasPrefix("Materials/") {
                restoredPath = "Materials/\(destination.lastPathComponent)"
            } else {
                let restoredSuffix = String(
                    destination.path.dropFirst(mediaRoot.path.count + 1))
                restoredPath = "WorkbenchRoot/\(restoredSuffix)"
            }
            if restoredPath != revisionAsset.relativePath {
                remappedRevisionPaths[revisionAsset.relativePath] = restoredPath
            }
        }

        // Phase 4: resolve destinations. Materials are filename-only under
        // Materials/; assets resolve inside WorkbenchRoot with no "..", no
        // absolute paths, no symlink escapes. Content collisions remap to a
        // unique content-addressed name instead of overwriting.
        var remappedMaterials: [String: String] = [:]
        var materialDestinations: [String: URL] = [:]
        for (fileName, planFile) in materialPlans {
            let destination = try validatedDestination(under: materialsRoot, fileName: fileName)
            let resolved = try collisionAwareDestination(destination, planFile: planFile)
            remappedMaterials[fileName] = resolved.lastPathComponent
            materialDestinations[fileName] = resolved
        }
        var remappedAssets: [String: String] = [:]
        var assetDestinations: [String: URL] = [:]
        for (relativePath, planFile) in assetPlans {
            let destination = try validatedDestination(under: mediaRoot, relativePath: relativePath)
            let resolved = try collisionAwareDestination(destination, planFile: planFile)
            remappedAssets[relativePath] = String(resolved.path.dropFirst(mediaRoot.path.count + 1))
            assetDestinations[relativePath] = resolved
        }
        var remappedNodeAssets: [String: String] = [:]
        var nodeAssetDestinations: [String: URL] = [:]
        for (relativePath, planFile) in nodeAssetPlans {
            guard relativePath.hasPrefix("WorkbenchRoot/") else {
                throw BackupError.unsafePath(relativePath)
            }
            let suffix = String(relativePath.dropFirst("WorkbenchRoot/".count))
            let destination = try validatedDestination(under: mediaRoot, relativePath: suffix)
            let resolved = try collisionAwareDestination(destination, planFile: planFile)
            let restoredSuffix = String(resolved.path.dropFirst(mediaRoot.path.count + 1))
            remappedNodeAssets[relativePath] = "WorkbenchRoot/\(restoredSuffix)"
            nodeAssetDestinations[relativePath] = resolved
        }

        // Phase 5: commit. Track created files; a failure removes everything
        // this restore created (files that pre-existed with identical bytes
        // were reused, never recreated, and are never removed).
        var created: [URL] = []
        var idMap: [UUID: UUID] = [:]
        func commit(_ url: URL, from source: URL) throws {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: url.path) {
                // collisionAwareDestination already resolved identical content.
                return
            }
            try manager.moveItem(at: source, to: url)
            created.append(url)
        }
        do {
            for (fileName, destination) in materialDestinations {
                try commit(destination, from: materialPlans[fileName]!.source)
            }
            for (relativePath, destination) in assetDestinations {
                try commit(destination, from: assetPlans[relativePath]!.source)
            }
            for (relativePath, destination) in nodeAssetDestinations {
                try commit(destination, from: nodeAssetPlans[relativePath]!.source)
            }
            // CAD revision bytes land at their (possibly remapped) paths.
            for (relativePath, destination) in revisionDestinations {
                try commit(destination, from: revisionPlans[relativePath]!.source)
            }
            // CAD unapplied drafts: drawing via staged copy, descriptor as the
            // rewritten JSON for the new canvas identity.
            for restoredDraft in restoredDrafts {
                try commit(restoredDraft.drawingDestination,
                           from: restoredDraft.drawingPlan.source)
                let stagedDescriptor = staging
                    .appendingPathComponent("restored-draft-\(UUID().uuidString).json")
                try restoredDraft.rewrittenDescriptorData.write(
                    to: stagedDescriptor, options: .atomic)
                try commit(restoredDraft.descriptorDestination,
                           from: stagedDescriptor)
            }
            // Child projects: fresh ids; inner id remapped; asset paths
            // remapped to the restored locations.
            var remappedChildData: [UUID: Data] = [:]
            for child in manifest.childProjects {
                let planFile = childPlans[child.projectID]!
                let data = try Data(contentsOf: planFile.source)
                let newID = UUID()
                guard let rewritten = Self.remappingProject(
                    data, to: newID, assetRemap: remappedAssets) else {
                    throw BackupError.corrupt("子工程 \(child.file) 不是有效工程 JSON。")
                }
                idMap[child.projectID] = newID
                remappedChildData[newID] = rewritten
            }
            for (newID, data) in remappedChildData {
                let target = projectsRoot.appendingPathComponent("media-project-\(newID.uuidString.lowercased()).json")
                let stagingFile = staging.appendingPathComponent("child-\(newID.uuidString).json")
                try data.write(to: stagingFile, options: .atomic)
                try commit(target, from: stagingFile)
            }
        } catch {
            for url in created { try? manager.removeItem(at: url) }
            throw error
        }

        // Phase 6: in-memory remaps (fresh identity, chat bindings cut).
        project.id = restoredCanvasID
        project.workspaceID = nil
        project.agentConversationID = nil
        project.assistantSessions = []
        project.selectedAssistantSessionID = nil
        project.agentConversationIDsByDocument = [:]
        project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if project.name.isEmpty { project.name = "导入画布" }
        project.updatedAt = Date()
        // Combined path remap applied inside CAD revision history: collision
        // remaps for revision bytes plus remaps for current assets.
        var historyPathRemap = remappedRevisionPaths
        for (fileName, restoredName) in remappedMaterials where restoredName != fileName {
            historyPathRemap["Materials/\(fileName)"] = "Materials/\(restoredName)"
        }
        for (original, restored) in remappedNodeAssets where original != restored {
            historyPathRemap[original] = restored
        }
        for documentIndex in project.documents.indices {
            for nodeIndex in project.documents[documentIndex].nodes.indices {
                var node = project.documents[documentIndex].nodes[nodeIndex]
                if let binding = node.childProjectBinding,
                   let mapped = idMap[binding.projectID] {
                    var rebound = binding
                    rebound.projectID = mapped
                    node.childProjectBinding = rebound
                }
                if let relative = node.asset?.localRelativePath,
                   relative.hasPrefix("Materials/") {
                    let fileName = String(relative.dropFirst("Materials/".count))
                    if let restoredName = remappedMaterials[fileName],
                       restoredName != fileName {
                        node.asset?.localRelativePath = "Materials/\(restoredName)"
                    }
                } else if let relative = node.asset?.localRelativePath,
                          relative.hasPrefix("WorkbenchRoot/"),
                          let restored = remappedNodeAssets[relative],
                          restored != relative {
                    node.asset?.localRelativePath = restored
                }
                // Rewrite typed revision history paths after collision remaps.
                // Absent history stays absent; unsupported raw metadata is
                // preserved verbatim (never re-encoded or seeded here).
                if case .usable(let revisions) = CanvasDrawingRevisionHistory.read(from: node),
                   CanvasDrawingNodePlanner.isDrawingNode(node) {
                    let rewritten = try CanvasDrawingRevisionHistory.remapping(
                        revisions, pathRemap: historyPathRemap)
                    if let entry = try CanvasDrawingRevisionHistory.metadata(rewritten)
                        .first {
                        node.metadata[entry.key] = entry.value
                    }
                }
                project.documents[documentIndex].nodes[nodeIndex] = node
            }
        }
        // The registry write is the LAST step: if it fails, every payload file
        // this restore created is rolled back so no orphan state survives.
        if let finalize {
            do {
                try finalize(project)
            } catch {
                for url in created { try? manager.removeItem(at: url) }
                throw error
            }
        }
        return Restored(project: project, manifest: manifest,
                        remappedMaterials: remappedMaterials,
                        remappedAssets: remappedAssets,
                        remappedNodeAssets: remappedNodeAssets,
                        remappedRevisionPaths: remappedRevisionPaths,
                        restoredDraftNodeIDs: restoredDrafts.map(\.descriptor.nodeID))
    }

    // MARK: Path safety

    /// A direct child directory of the canonical root whose resolved path
    /// stays inside the root (no symlink escapes).
    private static func containedDirectory(_ root: URL, _ name: String, create: Bool) throws -> URL {
        guard !name.contains("/"), !name.contains("..") else { throw BackupError.unsafePath(name) }
        let url = root.appendingPathComponent(name, isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") || resolved.path == root.path else {
            throw BackupError.unsafePath(name)
        }
        return url
    }

    /// Materials destination: a PLAIN filename (no separators, no "..", not
    /// hidden) inside `root`, with no symlink escape in existing ancestors.
    private static func validatedDestination(under root: URL, fileName: String) throws -> URL {
        guard !fileName.isEmpty, !fileName.contains("/"), !fileName.contains("\\"),
              !fileName.contains(".."), !fileName.hasPrefix(".") else {
            throw BackupError.unsafePath(fileName)
        }
        return try validatedDestination(under: root, relativePath: fileName)
    }

    /// General relative path destination: no absolute paths, no ".."
    /// components, resolved containment under `root`, and every EXISTING
    /// ancestor must itself resolve inside the root (symlink aliases refused).
    private static func validatedDestination(under root: URL, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw BackupError.unsafePath(relativePath)
        }
        var components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, !components.contains("..") else {
            throw BackupError.unsafePath(relativePath)
        }
        components = components.filter { !$0.isEmpty && !$0.hasPrefix(".") }
        guard components.count == relativePath.split(separator: "/", omittingEmptySubsequences: true).count else {
            throw BackupError.unsafePath(relativePath)
        }
        let manager = FileManager.default
        var current = root
        for component in components.dropLast() {
            current = current.appendingPathComponent(component, isDirectory: true)
            if manager.fileExists(atPath: current.path) {
                let resolved = current.standardizedFileURL.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(root.path + "/") || resolved.path == root.path else {
                    throw BackupError.unsafePath(relativePath)
                }
            }
        }
        let destination = root.appendingPathComponent(components.joined(separator: "/"))
        let resolved = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") || resolved.path == root.path else {
            throw BackupError.unsafePath(relativePath)
        }
        return destination
    }

    /// Same-name, different-content collisions are remapped to a unique
    /// content-addressed name; identical content reuses the existing file.
    private static func collisionAwareDestination(_ destination: URL, planFile: PlannedFile) throws -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: destination.path) else { return destination }
        let existing = try Data(contentsOf: destination)
        if Int64(existing.count) == planFile.byteCount, Self.digest(existing) == planFile.sha256 {
            return destination
        }
        let ext = destination.pathExtension
        let stem = destination.deletingPathExtension().lastPathComponent
        let base = destination.deletingLastPathComponent()
        for suffix in 1...100 {
            let candidate = base.appendingPathComponent(
                "\(stem)-\(String(planFile.sha256.prefix(8)))\(suffix > 1 ? "-\(suffix)" : "")\(ext.isEmpty ? "" : ".\(ext)")")
            if !manager.fileExists(atPath: candidate.path) { return candidate }
        }
        throw BackupError.unsafePath(destination.lastPathComponent)
    }

    // MARK: Helpers

    /// Ids of resolved child projects bound by any node.
    public static func boundChildProjectIDs(in project: CanvasProject) -> [UUID] {
        var ids = Set<UUID>()
        for document in project.documents {
            for node in document.nodes {
                if let binding = node.childProjectBinding {
                    ids.insert(binding.projectID)
                }
            }
        }
        return Array(ids)
    }

    /// Distinct plain filenames referenced by node assets under Materials/.
    public static func referencedMaterialNames(in project: CanvasProject) -> [String] {
        var refs = Set<String>()
        for document in project.documents {
            for node in document.nodes {
                if let relative = node.asset?.localRelativePath,
                   relative.hasPrefix("Materials/") {
                    let name = String(relative.dropFirst("Materials/".count))
                    if !name.isEmpty, !name.contains("/") { refs.insert(name) }
                }
            }
        }
        return Array(refs)
    }

    /// App-root-relative node asset paths under the fallback media root
    /// (WorkbenchRoot/...), e.g. CAD drawing nodes. `Materials/` assets are
    /// carried through `referencedMaterialNames` instead.
    public static func referencedExternalNodePaths(in project: CanvasProject) -> [String] {
        var refs = Set<String>()
        for document in project.documents {
            for node in document.nodes {
                guard let relative = node.asset?.localRelativePath,
                      relative.hasPrefix("WorkbenchRoot/"),
                      !relative.contains(".."),
                      !relative.hasSuffix("/") else { continue }
                refs.insert(relative)
            }
        }
        return Array(refs)
    }

    /// Media-root-relative asset paths referenced by a child project JSON.
    public static func assetPaths(inProjectJSON data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = object["assets"] as? [[String: Any]] else { return [] }
        var paths = Set<String>()
        for asset in assets {
            guard let relative = asset["relativePath"] as? String,
                  !relative.hasPrefix("/"), !relative.isEmpty else { continue }
            paths.insert(relative)
        }
        return Array(paths)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Rewrites the top-level "id", the asset relativePaths and the task
    /// workspace path of a media project JSON document; every other value
    /// stays untouched. `taskWorkspacePath` is cleared because the packaged
    /// assets were just restored under the fallback WorkbenchRoot: keeping a
    /// stale absolute path would either resolve against another device's
    /// files or silently point at the wrong root.
    static func remappingProject(_ data: Data, to newID: UUID,
                                 assetRemap: [String: String]) -> Data? {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["id"] != nil else { return nil }
        object["id"] = newID.uuidString
        object.removeValue(forKey: "taskWorkspacePath")
        if var assets = object["assets"] as? [[String: Any]] {
            for index in assets.indices {
                if let relative = assets[index]["relativePath"] as? String,
                   let mapped = assetRemap[relative] {
                    assets[index]["relativePath"] = mapped
                }
            }
            object["assets"] = assets
        }
        guard JSONSerialization.isValidJSONObject(object),
              let rewritten = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return rewritten
    }
}

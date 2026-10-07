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
        /// Bound child projects whose bytes were unavailable at export time;
        /// bindings pointing at them stay but are listed here truthfully.
        public var missingChildProjects: [UUID]
        /// Referenced asset paths whose bytes were unavailable at export time.
        public var missingAssets: [String]

        public init(formatVersion: Int, canvasID: UUID, canvasName: String,
                    canvasSchemaVersion: Int, exportedAt: Date,
                    canvasByteCount: Int64, canvasSHA256: String,
                    childProjects: [ChildProject], materials: [Material],
                    assets: [ChildAsset], missingChildProjects: [UUID],
                    missingAssets: [String]) {
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
            self.missingChildProjects = missingChildProjects
            self.missingAssets = missingAssets
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

    public enum BackupError: Error, LocalizedError, Equatable {
        case unsupportedFormat(Int)
        case corrupt(String)
        case hashMismatch(String)
        case unsafePath(String)

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
            }
        }
    }

    private static let maximumEntry: Int64 = 512 * 1024 * 1024
    private static let maximumTotal: Int64 = 2 * 1024 * 1024 * 1024

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
                            assetData: (String) throws -> Data?) throws -> Data {
        let url = try makeZip(project: project, childProjectData: childProjectData,
                              materialData: materialData, assetData: assetData,
                              maximumDataBytes: maximumInMemoryBytes)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func makeZip(project: CanvasProject,
                                childProjectData: (UUID) throws -> Data?,
                                materialData: (String) throws -> Data?,
                                assetData: (String) throws -> Data?,
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
            missingAssets: missingAssets)
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
        return temporary
    }

    /// File-backed export for production sharing: the zip is built at
    /// `destination` and never fully resident in memory. Payload reads still
    /// go through the providers; callers must preflight each source file
    /// (the app providers read bounded workspace files).
    public static func makeToURL(project: CanvasProject, destination: URL,
                                 childProjectData: (UUID) throws -> Data?,
                                 materialData: (String) throws -> Data?,
                                 assetData: (String) throws -> Data?) throws {
        let temporary = try makeZip(project: project,
                                    childProjectData: childProjectData,
                                    materialData: materialData,
                                    assetData: assetData,
                                    maximumDataBytes: maximumFileBackedBytes)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
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
    }

    /// Staged, verified restore. Everything lands inside `floeRoot`:
    /// Materials/<name>, MediaProjects/<id>.json and the fallback media root
    /// WorkbenchRoot/<relativePath>. On ANY validation or hash failure the
    /// file system is left untouched; on a mid-commit failure every file this
    /// restore created is removed again. `finalize` (the canvas registry
    /// write) runs AFTER the payload commits and its failure rolls them back.
    @discardableResult
    public static func restore(data: Data, floeRoot: URL,
                               finalize: ((CanvasProject) throws -> Void)? = nil) throws -> Restored {
        let manager = FileManager.default
        let canonicalRoot = floeRoot.standardizedFileURL.resolvingSymlinksInPath()
        let materialsRoot = try containedDirectory(canonicalRoot, "Materials", create: true)
        let projectsRoot = try containedDirectory(canonicalRoot, "MediaProjects", create: true)
        let mediaRoot = try containedDirectory(canonicalRoot, "WorkbenchRoot", create: true)

        // Phase 1: stream entries into a private staging directory.
        let staging = manager.temporaryDirectory
            .appendingPathComponent("canvas-restore-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        let archiveFile = staging.appendingPathComponent("package.zip")
        try data.write(to: archiveFile)
        guard let archive = Archive(url: archiveFile, accessMode: .read) else {
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
        project.id = UUID()
        project.workspaceID = nil
        project.agentConversationID = nil
        project.assistantSessions = []
        project.selectedAssistantSessionID = nil
        project.agentConversationIDsByDocument = [:]
        project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if project.name.isEmpty { project.name = "导入画布" }
        project.updatedAt = Date()
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
                        remappedAssets: remappedAssets)
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

    /// Rewrites the top-level "id" and any asset relativePaths of a media
    /// project JSON document; every other value stays untouched.
    static func remappingProject(_ data: Data, to newID: UUID,
                                 assetRemap: [String: String]) -> Data? {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["id"] != nil else { return nil }
        object["id"] = newID.uuidString
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

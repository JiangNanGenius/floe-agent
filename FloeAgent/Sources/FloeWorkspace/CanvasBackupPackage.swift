// SPDX-License-Identifier: MPL-2.0
import Foundation
import ZIPFoundation
import Crypto
import FloeCore

/// Canvas backup package: the canvas project plus every bound child media
/// project and every referenced Materials asset, in one zip. Import remaps
/// canvas and child-project ids (an import never overwrites existing
/// projects), verifies SHA-256 for every carried byte, and preserves unknown
/// metadata verbatim. This is a backup/restore format, not a new project
/// manager: the canvas stays the single source of truth for its nodes.
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
        /// Child media projects carried in the package.
        public var childProjects: [ChildProject]
        /// Material assets referenced by nodes, carried under materials/.
        public var materials: [Material]
        /// Bound child projects whose bytes were unavailable at export time;
        /// bindings pointing at them stay but are listed here truthfully.
        public var missingChildProjects: [UUID]

        public init(formatVersion: Int, canvasID: UUID, canvasName: String,
                    canvasSchemaVersion: Int, exportedAt: Date,
                    childProjects: [ChildProject], materials: [Material],
                    missingChildProjects: [UUID]) {
            self.formatVersion = formatVersion
            self.canvasID = canvasID
            self.canvasName = canvasName
            self.canvasSchemaVersion = canvasSchemaVersion
            self.exportedAt = exportedAt
            self.childProjects = childProjects
            self.materials = materials
            self.missingChildProjects = missingChildProjects
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
        /// Original node reference, e.g. "Materials/<name>.png".
        public var relativePath: String
        /// Location inside the package.
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

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let version):
                return "画布备份格式版本 \(version) 不受支持，请升级应用后再导入。"
            case .corrupt(let detail):
                return "画布备份已损坏：\(detail)"
            case .hashMismatch(let name):
                return "画布备份校验失败：\(name)"
            }
        }
    }

    private static let maximumEntry: Int64 = 512 * 1024 * 1024
    private static let maximumTotal: Int64 = 2 * 1024 * 1024 * 1024

    // MARK: Export

    /// Builds the backup zip. `childProjectData` returns the stored project
    /// JSON for a bound project id (nil when unavailable); `materialData`
    /// returns bytes for a "Materials/<name>" relative path.
    public static func make(project: CanvasProject,
                            childProjectData: (UUID) throws -> Data?,
                            materialData: (String) throws -> Data?) throws -> Data {
        let childIDs = Self.boundChildProjectIDs(in: project)
        var children: [ChildProject] = []
        var missing: [UUID] = []
        var childPayloads: [UUID: Data] = [:]
        for id in childIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let data = try childProjectData(id), !data.isEmpty else {
                missing.append(id)
                continue
            }
            children.append(ChildProject(
                projectID: id,
                file: "projects/\(id.uuidString.lowercased()).json",
                byteCount: Int64(data.count),
                sha256: Self.digest(data)))
            childPayloads[id] = data
        }

        let materialRefs = Self.referencedMaterials(in: project)
        var materials: [Material] = []
        var materialPayloads: [String: Data] = [:]
        for relative in materialRefs.sorted() {
            guard let data = try materialData(relative), !data.isEmpty else { continue }
            let name = String(relative.dropFirst("Materials/".count))
            materials.append(Material(
                relativePath: relative,
                file: "materials/\(name)",
                byteCount: Int64(data.count),
                sha256: Self.digest(data)))
            materialPayloads[relative] = data
        }

        let manifest = Manifest(
            formatVersion: formatVersion,
            canvasID: project.id,
            canvasName: project.name,
            canvasSchemaVersion: project.schemaVersion,
            exportedAt: Date(),
            childProjects: children,
            materials: materials,
            missingChildProjects: missing)
        let manifestData = try JSONEncoder().encode(manifest)
        let canvasData = try CanvasProjectCodec.encode(project)

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-backup-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let archive = Archive(url: temporary, accessMode: .create) else {
            throw BackupError.corrupt("无法创建备份存档。")
        }
        var total: Int64 = 0
        func append(_ data: Data, as path: String) throws {
            total += Int64(data.count)
            guard total <= maximumTotal else {
                throw BackupError.corrupt("备份超过 2 GB，请拆分画布。")
            }
            try archive.addEntry(with: path, type: .file,
                                 uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        try append(canvasData, as: canvasEntry)
        try append(manifestData, as: manifestEntry)
        for child in children {
            guard let data = childPayloads[child.projectID] else { continue }
            try append(data, as: child.file)
        }
        for material in materials {
            guard let data = materialPayloads[material.relativePath] else { continue }
            try append(data, as: material.file)
        }
        return try Data(contentsOf: temporary)
    }

    // MARK: Import

    public struct Restored {
        /// Canvas project with a fresh id and remapped child-project bindings.
        public var project: CanvasProject
        public var manifest: Manifest
    }

    /// Restores a backup. Child projects are written with NEW ids through
    /// `childProjectWriter`; node bindings are remapped to those new ids.
    /// Materials keep their "Materials/<name>" relative path and are verified
    /// against the recorded SHA-256 before writing.
    public static func restore(data: Data,
                               childProjectWriter: (UUID, Data) throws -> Void,
                               materialWriter: (String, Data) throws -> Void) throws -> Restored {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-restore-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        guard let archive = Archive(url: temporary, accessMode: .read) else {
            throw BackupError.corrupt("无法读取备份存档。")
        }
        var entries: [String: Data] = [:]
        var total: Int64 = 0
        for entry in archive where entry.type == .file {
            let entrySize = Int64(entry.uncompressedSize)
            guard entrySize <= maximumEntry else {
                throw BackupError.corrupt("条目超过大小限制。")
            }
            total += entrySize
            guard total <= maximumTotal else {
                throw BackupError.corrupt("备份超过 2 GB。")
            }
            var data = Data()
            do {
                _ = try archive.extract(entry, bufferSize: 1 << 20, skipCRC32: false, progress: nil) { chunk in
                    data.append(chunk)
                }
            } catch {
                throw BackupError.corrupt("无法解压 \(entry.path)。")
            }
            guard Int64(data.count) == entrySize else {
                throw BackupError.hashMismatch(entry.path)
            }
            entries[entry.path] = data
        }
        guard let manifestData = entries[manifestEntry] else {
            throw BackupError.corrupt("缺少 manifest.json。")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard manifest.formatVersion <= formatVersion else {
            throw BackupError.unsupportedFormat(manifest.formatVersion)
        }
        guard let canvasData = entries[canvasEntry] else {
            throw BackupError.corrupt("缺少 canvas.json。")
        }
        var project = try CanvasProjectCodec.decode(canvasData)
        guard (1...CanvasProject.currentSchemaVersion).contains(project.schemaVersion) else {
            throw BackupError.unsupportedFormat(project.schemaVersion)
        }

        // Verify and write child projects under fresh ids, building the remap.
        var idMap: [UUID: UUID] = [:]
        for child in manifest.childProjects {
            guard let data = entries[child.file] else {
                throw BackupError.corrupt("缺少子工程 \(child.file)。")
            }
            guard data.count == child.byteCount, Self.digest(data) == child.sha256 else {
                throw BackupError.hashMismatch(child.file)
            }
            let newID = UUID()
            guard let remapped = Self.remappingProjectID(of: data, to: newID) else {
                throw BackupError.corrupt("子工程 \(child.file) 不是有效工程 JSON。")
            }
            try childProjectWriter(newID, remapped)
            idMap[child.projectID] = newID
        }

        // Verify and write materials at their original relative path.
        for material in manifest.materials {
            guard let data = entries[material.file] else {
                throw BackupError.corrupt("缺少素材 \(material.file)。")
            }
            guard data.count == material.byteCount, Self.digest(data) == material.sha256 else {
                throw BackupError.hashMismatch(material.file)
            }
            try materialWriter(material.relativePath, data)
        }

        // Fresh canvas identity; chat/workspace bindings are deliberately cut.
        project.id = UUID()
        project.workspaceID = nil
        project.agentConversationID = nil
        project.assistantSessions = []
        project.selectedAssistantSessionID = nil
        project.agentConversationIDsByDocument = [:]
        project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if project.name.isEmpty { project.name = "导入画布" }
        project.updatedAt = Date()

        // Remap child bindings; unknown-version/malformed markers stay raw.
        for documentIndex in project.documents.indices {
            for nodeIndex in project.documents[documentIndex].nodes.indices {
                var node = project.documents[documentIndex].nodes[nodeIndex]
                if let binding = node.childProjectBinding,
                   let mapped = idMap[binding.projectID] {
                    var rebound = binding
                    rebound.projectID = mapped
                    node.childProjectBinding = rebound
                }
                project.documents[documentIndex].nodes[nodeIndex] = node
            }
        }
        return Restored(project: project, manifest: manifest)
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

    /// Distinct "Materials/<name>" references from node assets.
    public static func referencedMaterials(in project: CanvasProject) -> [String] {
        var refs = Set<String>()
        for document in project.documents {
            for node in document.nodes {
                if let relative = node.asset?.localRelativePath,
                   relative.hasPrefix("Materials/") {
                    refs.insert(relative)
                }
            }
        }
        return Array(refs)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Rewrites the top-level "id" of a media project JSON document while
    /// leaving every other value (dates, revisions, history) untouched.
    static func remappingProjectID(of data: Data, to newID: UUID) -> Data? {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["id"] != nil else { return nil }
        object["id"] = newID.uuidString
        guard JSONSerialization.isValidJSONObject(object),
              let rewritten = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return rewritten
    }
}

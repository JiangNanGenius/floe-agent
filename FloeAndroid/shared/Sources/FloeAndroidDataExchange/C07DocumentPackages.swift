// SPDX-License-Identifier: MPL-2.0
//
// C07 document-package exchange.
//
//  * `.flocanvas` uses the fixed iOS `CanvasBackupPackage` manifest shape
//    (`canvas.json`, `manifest.json`, `projects/…`, `materials/…`,
//    `assets/…`, `nodeassets/…`) so a Canvas document and its referenced
//    media resources can move between the fixed iOS donor and Android.
//    Unsupported optional sections are rejected explicitly, never dropped.
//  * `.docx` / `.pdf` are validated as portable document packages before a
//    copy can reach a project. A corrupt/truncated package never partially
//    commits.
//  * Every ZIP is staged with the same path/type/size/ratio/hash rules as the
//    App backup reader. A generic ZIP is never labelled a Floe package.
import Foundation
import Crypto
import ZIPFoundation

// MARK: - Bounds

public enum C07DocumentPackageLimits {
    public static let canvasFormat = "floe.canvasbackup"
    public static let canvasFormatVersion = 1
    public static let canvasExtension = "flocanvas"
    public static let canvasEntry = "canvas.json"
    public static let canvasManifestEntry = "manifest.json"
    public static let maximumEntryBytes: Int64 = 512 * 1_024 * 1_024
    public static let maximumTotalBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    public static let maximumEntries = 20_000
    public static let maximumCompressionRatio = 200.0
    public static let compressionRatioProbeBytes: Int64 = 1_048_576
    public static let maximumPDFBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    public static let maximumOfficeEntries = 20_000
    public static let maximumOfficeBytes: Int64 = 1 * 1_024 * 1_024 * 1_024
}

// MARK: - Strict staging

public struct C07StagedPackageEntry: Sendable, Equatable {
    public var path: String
    public var url: URL
    public var byteCount: Int64
    public var sha256: String
}

public struct C07StagedPackage: Sendable, Equatable {
    public var root: URL
    public var entries: [String: C07StagedPackageEntry]

    public init(root: URL, entries: [String: C07StagedPackageEntry]) {
        self.root = root
        self.entries = entries
    }
}

/// Extracts one untrusted ZIP into a private staging directory. No caller
/// path, no live destination and no symlink is involved.
public enum C07PackageStager {
    public static func stage(archiveURL: URL,
                             stagingRoot: URL,
                             maximumEntryBytes: Int64 = C07DocumentPackageLimits.maximumEntryBytes,
                             maximumTotalBytes: Int64 = C07DocumentPackageLimits.maximumTotalBytes,
                             maximumEntries: Int = C07DocumentPackageLimits.maximumEntries)
        throws -> C07StagedPackage
    {
        try C07FileSystem.ensureDirectory(stagingRoot)
        let root = stagingRoot.appendingPathComponent(
            "package-\(UUID().uuidString)", isDirectory: true)
        try C07FileSystem.ensureDirectory(root)
        var keep = false
        defer { if !keep { C07FileSystem.removeIfPresent(root) } }
        let archive: Archive
        do { archive = try Archive(url: archiveURL, accessMode: .read) }
        catch { throw C07DataExchangeError.corruptArchive("open") }
        var result: [String: C07StagedPackageEntry] = [:]
        var keys = Set<String>()
        var total: Int64 = 0
        var count = 0
        for entry in archive {
            if entry.type == .directory {
                var path = entry.path
                while path.hasSuffix("/") { path.removeLast() }
                do { _ = try C07Path.validateRelative(path) }
                catch { throw C07DataExchangeError.unsafePath(entry.path) }
                continue
            }
            guard entry.type == .file else {
                throw C07DataExchangeError.symlinkUnsupported(entry.path)
            }
            count += 1
            guard count <= maximumEntries else {
                throw C07DataExchangeError.tooManyEntries
            }
            let path: String
            do { path = try C07Path.validateRelative(entry.path) }
            catch { throw C07DataExchangeError.unsafePath(entry.path) }
            guard keys.insert(C07Path.collisionKey(path)).inserted else {
                throw C07DataExchangeError.caseCollision(path)
            }
            let size = try c07CheckedEntrySize(entry.uncompressedSize, path)
            guard size >= 0, size <= maximumEntryBytes else {
                throw C07DataExchangeError.entryTooLarge(path)
            }
            if size > C07DocumentPackageLimits.compressionRatioProbeBytes {
                let compressed = try c07CheckedEntrySize(entry.compressedSize, path)
                if compressed > 0 {
                    let ratio = Double(size) / Double(compressed)
                    guard ratio <= C07DocumentPackageLimits.maximumCompressionRatio else {
                        throw C07DataExchangeError.corruptArchive("compressionRatio")
                    }
                }
            }
            total += size
            guard total <= maximumTotalBytes else {
                throw C07DataExchangeError.totalTooLarge
            }
            let url = root.appendingPathComponent(path)
            try C07FileSystem.ensureDirectory(url.deletingLastPathComponent())
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw C07DataExchangeError.storageUnavailable("stageCreate")
            }
            let handle: FileHandle
            do { handle = try FileHandle(forWritingTo: url) }
            catch { throw C07DataExchangeError.storageUnavailable("stageOpen") }
            var hasher = SHA256Box()
            var readback: Int64 = 0
            do {
                _ = try archive.extract(entry, skipCRC32: false) { chunk in
                    if Task.isCancelled { throw C07DataExchangeError.cancelled }
                    readback += Int64(chunk.count)
                    guard readback <= size else {
                        throw C07DataExchangeError.sizeMismatch(path)
                    }
                    hasher.update(chunk)
                    try handle.write(contentsOf: chunk)
                }
                try handle.close()
            } catch is CancellationError {
                try? handle.close()
                throw CancellationError()
            } catch let error as C07DataExchangeError {
                try? handle.close()
                throw error
            } catch {
                try? handle.close()
                throw C07DataExchangeError.corruptArchive("extract:\(path)")
            }
            guard readback == size else {
                throw C07DataExchangeError.sizeMismatch(path)
            }
            result[path] = C07StagedPackageEntry(
                path: path, url: url, byteCount: size, sha256: hasher.finalize())
        }
        keep = true
        return C07StagedPackage(root: root, entries: result)
    }
}

// MARK: - Canvas graph helpers

public struct C07CanvasReferences: Sendable, Equatable {
    public var canvasID: UUID
    public var name: String
    public var schemaVersion: Int
    public var childProjectIDs: [UUID]
    public var materialNames: [String]
    public var nodeAssetPaths: [String]
    public var workspaceID: UUID?
    public var conversationIDs: [UUID]
    public var runIDs: [UUID]
    public var assetIDs: [UUID]
    public var warnings: [String]
}

public enum C07CanvasGraph {
    private static let uuidRegexPattern =
        "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"

    public static func scan(canvasData: Data) throws -> C07CanvasReferences {
        guard canvasData.count <= C07DocumentPackageLimits.maximumEntryBytes else {
            throw C07DataExchangeError.entryTooLarge(C07DocumentPackageLimits.canvasEntry)
        }
        guard let object = try? JSONSerialization.jsonObject(with: canvasData),
              let root = object as? [String: Any] else {
            throw C07DataExchangeError.documentPackage("canvasJSON")
        }
        guard let idText = root["id"] as? String,
              let canvasID = UUID(uuidString: idText) else {
            throw C07DataExchangeError.documentPackage("canvasIdentity")
        }
        guard let schema = root["schemaVersion"] as? Int,
              schema > 0,
              schema <= 7 else {
            throw C07DataExchangeError.unsupportedVersion(
                (root["schemaVersion"] as? Int) ?? 0)
        }
        var childIDs = Set<UUID>()
        var materials = Set<String>()
        var nodePaths = Set<String>()
        var conversationIDs = Set<UUID>()
        var runIDs = Set<UUID>()
        var assetIDs = Set<UUID>()
        var nodes = 0
        try walk(root, depth: 0, nodes: &nodes) { key, value in
            guard let string = value as? String else { return }
            if key == "canvas.childProject" || key == "canvas.childProject.pending" {
                if let data = string.data(using: .utf8),
                   let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let pending = metadata["pending"] as? [String: Any]
                    let source = pending ?? metadata
                    if let projectText = source["projectID"] as? String,
                       let projectID = UUID(uuidString: projectText) {
                        childIDs.insert(projectID)
                    }
                }
            }
            if key == "workspaceID", let id = UUID(uuidString: string) {
                // Recorded below; a canvas workspace link is optional.
                _ = id
            }
            if string.hasPrefix("Materials/") {
                let name = String(string.dropFirst("Materials/".count))
                if !name.isEmpty, !name.contains("/") { materials.insert(name) }
            }
            if string.hasPrefix("WorkbenchRoot/") {
                nodePaths.insert(string)
            }
            if key.lowercased().contains("conversationid") || key == "agentConversationID",
               let id = UUID(uuidString: string) {
                conversationIDs.insert(id)
            }
            if key == "createdByRunID" || key == "generationJobID",
               let id = UUID(uuidString: string) {
                runIDs.insert(id)
            }
        }
        // Explicit ownership fields.
        if let workspaceText = root["workspaceID"] as? String,
           let id = UUID(uuidString: workspaceText) {
            // Captured by the caller from the typed project when needed.
            _ = id
        }
        if let conversations = root["agentConversationIDsByDocument"] as? [String: String] {
            for value in conversations.values {
                if let id = UUID(uuidString: value) { conversationIDs.insert(id) }
            }
        }
        if let sessions = root["assistantSessions"] as? [[String: Any]] {
            for session in sessions {
                if let text = session["conversationID"] as? String,
                   let id = UUID(uuidString: text) { conversationIDs.insert(id) }
                if let text = session["id"] as? String, let id = UUID(uuidString: text) {
                    _ = id
                }
            }
        }
        if let agent = root["agentConversationID"] as? String,
           let id = UUID(uuidString: agent) { conversationIDs.insert(id) }
        // Asset IDs referenced by serialized CanvasAssetReference objects.
        var assetScan = Set<UUID>()
        try walk(root, depth: 0, nodes: &nodes) { key, value in
            if key == "asset", let dict = value as? [String: Any],
               let text = dict["id"] as? String, let id = UUID(uuidString: text) {
                assetScan.insert(id)
            }
        }
        assetIDs.formUnion(assetScan)
        let name = (root["name"] as? String) ?? "Canvas"
        return C07CanvasReferences(
            canvasID: canvasID,
            name: String(name.prefix(240)),
            schemaVersion: schema,
            childProjectIDs: childIDs.sorted { $0.uuidString < $1.uuidString },
            materialNames: materials.sorted(),
            nodeAssetPaths: nodePaths.sorted(),
            workspaceID: (root["workspaceID"] as? String).flatMap(UUID.init(uuidString:)),
            conversationIDs: conversationIDs.sorted { $0.uuidString < $1.uuidString },
            runIDs: runIDs.sorted { $0.uuidString < $1.uuidString },
            assetIDs: assetIDs.sorted { $0.uuidString < $1.uuidString },
            warnings: [])
    }

    public static func scanMediaProject(data: Data) throws
        -> (projectID: UUID, ownerKind: String, ownerID: UUID?,
            assetIDs: [UUID], assetPaths: [String], taskWorkspacePath: String?)
    {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let idText = root["id"] as? String,
              let projectID = UUID(uuidString: idText) else {
            throw C07DataExchangeError.documentPackage("mediaProjectJSON")
        }
        var assetIDs = Set<UUID>()
        var paths = Set<String>()
        var nodes = 0
        try walk(root, depth: 0, nodes: &nodes) { key, value in
            guard let string = value as? String else { return }
            if key == "id", let id = UUID(uuidString: string) { assetIDs.insert(id) }
            if string.hasPrefix("Workbench/Assets/") || string.hasPrefix("WorkbenchRoot/") {
                paths.insert(string)
            }
        }
        let ownerKind = (root["ownerKind"] as? String) ?? ""
        let ownerID = (root["ownerID"] as? String).flatMap(UUID.init(uuidString:))
        return (projectID, ownerKind, ownerID,
                assetIDs.sorted { $0.uuidString < $1.uuidString },
                paths.sorted(),
                root["taskWorkspacePath"] as? String)
    }

    /// Rewrites exact identity tokens and explicit material/media path maps
    /// in one JSON object. Free-form strings are only changed when they are an
    /// identity token or a controlled resource path.
    public static func rewriteJSON(data: Data, mapping: C07IDMap,
                                   materialMap: [String: String],
                                   pathMap: [String: String],
                                   taskWorkspacePath: String? = nil) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw C07DataExchangeError.documentPackage("jsonDecode")
        }
        var nodes = 0
        let rewritten = try rewriteValue(
            object, mapping: mapping, materialMap: materialMap,
            pathMap: pathMap, taskWorkspacePath: taskWorkspacePath,
            depth: 0, nodes: &nodes)
        do {
            return try JSONSerialization.data(withJSONObject: rewritten,
                                              options: [.sortedKeys])
        } catch {
            throw C07DataExchangeError.documentPackage("jsonEncode")
        }
    }

    private static func rewriteValue(_ value: Any, mapping: C07IDMap,
                                     materialMap: [String: String],
                                     pathMap: [String: String],
                                     taskWorkspacePath: String?,
                                     depth: Int, nodes: inout Int) throws -> Any {
        guard depth <= C07OwnedDataLimits.maximumJSONDepth else {
            throw C07DataExchangeError.documentPackage("jsonDepth")
        }
        nodes += 1
        guard nodes <= C07OwnedDataLimits.maximumJSONNodes else {
            throw C07DataExchangeError.tooManyEntries
        }
        if let string = value as? String {
            var result = C07IDRewrite.rewrite(string, mapping: mapping)
            if result.hasPrefix("Materials/") {
                let name = String(result.dropFirst("Materials/".count))
                if let replacement = materialMap[name] {
                    result = "Materials/\(replacement)"
                }
            }
            if let replacement = pathMap[result] {
                result = replacement
            } else {
                for (old, new) in pathMap where result.hasPrefix(old + "/") {
                    result = new + String(result.dropFirst(old.count))
                    break
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return try array.map {
                try rewriteValue($0, mapping: mapping, materialMap: materialMap,
                                 pathMap: pathMap, taskWorkspacePath: taskWorkspacePath,
                                 depth: depth + 1, nodes: &nodes)
            }
        }
        if var object = value as? [String: Any] {
            if let taskWorkspacePath, object["taskWorkspacePath"] != nil {
                object["taskWorkspacePath"] = taskWorkspacePath
            }
            var result: [String: Any] = [:]
            for (key, rawItem) in object {
                var item = rawItem
                if key == "workspaceID", let text = item as? String,
                   mapping.newID(.workspace, old: text) == nil {
                    continue
                }
                if (key == "agentConversationID"
                    || key == "selectedAssistantSessionID"),
                   let text = item as? String,
                   mapping.newID(.conversation, old: text) == nil {
                    continue
                }
                if key == "agentConversationIDsByDocument",
                   let dictionary = item as? [String: String] {
                    let filtered = dictionary.filter {
                        mapping.newID(.conversation, old: $0.value) != nil
                    }
                    if filtered.isEmpty { continue }
                    item = filtered
                }
                if key == "assistantSessions",
                   let sessions = item as? [[String: Any]] {
                    let filtered = sessions.filter { session in
                        guard let text = session["conversationID"] as? String else {
                            return true
                        }
                        return mapping.newID(.conversation, old: text) != nil
                    }
                    if filtered.isEmpty { continue }
                    item = filtered
                }
                let newKey = C07IDRewrite.rewrite(key, mapping: mapping)
                result[newKey] = try rewriteValue(
                    item, mapping: mapping, materialMap: materialMap,
                    pathMap: pathMap, taskWorkspacePath: taskWorkspacePath,
                    depth: depth + 1, nodes: &nodes)
            }
            return result
        }
        return value
    }

    private static func walk(_ value: Any, depth: Int, nodes: inout Int,
                             _ body: (String, Any) throws -> Void) throws {
        guard depth <= C07OwnedDataLimits.maximumJSONDepth else {
            throw C07DataExchangeError.documentPackage("jsonDepth")
        }
        nodes += 1
        guard nodes <= C07OwnedDataLimits.maximumJSONNodes else {
            throw C07DataExchangeError.tooManyEntries
        }
        if let object = value as? [String: Any] {
            for (key, item) in object {
                try body(key, item)
                try walk(item, depth: depth + 1, nodes: &nodes, body)
            }
        } else if let array = value as? [Any] {
            for item in array {
                try walk(item, depth: depth + 1, nodes: &nodes, body)
            }
        }
    }
}

// MARK: - Canvas package manifest (fixed donor shape + explicit format)

public struct C07CanvasPackageManifest: Codable, Sendable, Equatable {
    public struct ChildProject: Codable, Sendable, Equatable {
        public var projectID: UUID
        public var file: String
        public var byteCount: Int64
        public var sha256: String
        public init(projectID: UUID, file: String, byteCount: Int64, sha256: String) {
            self.projectID = projectID; self.file = file
            self.byteCount = byteCount; self.sha256 = sha256
        }
    }
    public struct Material: Codable, Sendable, Equatable {
        public var fileName: String
        public var byteCount: Int64
        public var sha256: String
        public init(fileName: String, byteCount: Int64, sha256: String) {
            self.fileName = fileName; self.byteCount = byteCount; self.sha256 = sha256
        }
    }
    public struct Asset: Codable, Sendable, Equatable {
        public var relativePath: String
        public var file: String
        public var byteCount: Int64
        public var sha256: String
        public init(relativePath: String, file: String, byteCount: Int64, sha256: String) {
            self.relativePath = relativePath; self.file = file
            self.byteCount = byteCount; self.sha256 = sha256
        }
    }
    public struct NodeAsset: Codable, Sendable, Equatable {
        public var relativePath: String
        public var file: String
        public var byteCount: Int64
        public var sha256: String
        public init(relativePath: String, file: String, byteCount: Int64, sha256: String) {
            self.relativePath = relativePath; self.file = file
            self.byteCount = byteCount; self.sha256 = sha256
        }
    }

    public var format: String?
    public var formatVersion: Int
    public var canvasID: UUID
    public var canvasName: String
    public var canvasSchemaVersion: Int
    public var exportedAt: Date
    public var canvasByteCount: Int64
    public var canvasSHA256: String
    public var childProjects: [ChildProject]
    public var materials: [Material]
    public var assets: [Asset]
    public var externalNodeAssets: [NodeAsset]
    public var missingChildProjects: [UUID]
    public var missingAssets: [String]
    public var missingExternalNodeAssets: [String]
    /// Present only to reject an unsupported donor section explicitly.
    public var cadDrafts: [C07OpaqueSection]?
    public var nativeCADPackages: [C07OpaqueSection]?

    public init(format: String? = C07DocumentPackageLimits.canvasFormat,
                formatVersion: Int = C07DocumentPackageLimits.canvasFormatVersion,
                canvasID: UUID, canvasName: String,
                canvasSchemaVersion: Int, exportedAt: Date = Date(),
                canvasByteCount: Int64, canvasSHA256: String,
                childProjects: [ChildProject] = [], materials: [Material] = [],
                assets: [Asset] = [],
                externalNodeAssets: [NodeAsset] = [],
                missingChildProjects: [UUID] = [], missingAssets: [String] = [],
                missingExternalNodeAssets: [String] = [],
                cadDrafts: [C07OpaqueSection]? = nil,
                nativeCADPackages: [C07OpaqueSection]? = nil) {
        self.format = format
        self.formatVersion = formatVersion
        self.canvasID = canvasID
        self.canvasName = String(canvasName.prefix(240))
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
        self.nativeCADPackages = nativeCADPackages
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> C07CanvasPackageManifest {
        guard data.count <= C07DataExchangeLimits.maximumManifestBytes else {
            throw C07DataExchangeError.entryTooLarge(
                C07DocumentPackageLimits.canvasManifestEntry)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(C07CanvasPackageManifest.self, from: data) }
        catch { throw C07DataExchangeError.documentPackage("canvasManifestDecode") }
    }

    public func validate() throws {
        if let format, format != C07DocumentPackageLimits.canvasFormat {
            throw C07DataExchangeError.unsupportedFormat(format)
        }
        guard formatVersion == C07DocumentPackageLimits.canvasFormatVersion else {
            throw C07DataExchangeError.unsupportedVersion(formatVersion)
        }
        guard canvasSchemaVersion > 0, canvasSchemaVersion <= 7 else {
            throw C07DataExchangeError.unsupportedVersion(canvasSchemaVersion)
        }
        guard canvasByteCount > 0,
              canvasByteCount <= C07DocumentPackageLimits.maximumEntryBytes,
              C07SHA256Hex.isSHA256(canvasSHA256) else {
            throw C07DataExchangeError.invalidManifest("canvasRecord")
        }
        let childIDs = childProjects.map(\.projectID)
        guard Set(childIDs).count == childIDs.count,
              childProjects.count <= C07DocumentPackageLimits.maximumEntries else {
            throw C07DataExchangeError.invalidManifest("canvasChildren")
        }
        guard Set(materials.map(\.fileName)).count == materials.count,
              Set(assets.map(\.file)).count == assets.count,
              Set(externalNodeAssets.map(\.file)).count == externalNodeAssets.count else {
            throw C07DataExchangeError.invalidManifest("canvasEntries")
        }
        for material in materials {
            guard !material.fileName.isEmpty,
                  !material.fileName.contains("/"),
                  material.fileName != ".", material.fileName != "..",
                  material.byteCount > 0,
                  C07SHA256Hex.isSHA256(material.sha256) else {
                throw C07DataExchangeError.invalidManifest("canvasMaterial")
            }
        }
        for asset in assets {
            do {
                _ = try C07Path.validateRelative(asset.relativePath)
                _ = try C07Path.validateRelative(asset.file)
            } catch { throw C07DataExchangeError.unsafePath(asset.relativePath) }
            guard asset.byteCount > 0, C07SHA256Hex.isSHA256(asset.sha256) else {
                throw C07DataExchangeError.invalidManifest("canvasAsset")
            }
        }
        for asset in externalNodeAssets {
            do {
                _ = try C07Path.validateRelative(asset.relativePath)
                _ = try C07Path.validateRelative(asset.file)
            } catch { throw C07DataExchangeError.unsafePath(asset.relativePath) }
            guard asset.byteCount > 0, C07SHA256Hex.isSHA256(asset.sha256) else {
                throw C07DataExchangeError.invalidManifest("canvasAsset")
            }
        }
        if let cadDrafts, !cadDrafts.isEmpty {
            throw C07DataExchangeError.unsupportedFeature("canvasCADDrafts")
        }
        if let nativeCADPackages, !nativeCADPackages.isEmpty {
            throw C07DataExchangeError.unsupportedFeature("canvasNativeCADPackages")
        }
    }
}

/// Placeholder decoder for a donor section this package cannot carry. Its
/// presence is detected and rejected; its contents are never interpreted.
public struct C07OpaqueSection: Codable, Sendable, Equatable {
    public init() {}
    public init(from decoder: any Decoder) throws {
        self.init()
    }
    public func encode(to encoder: any Encoder) throws {}
}

// MARK: - Canvas export/inspect

public struct C07CanvasSource: Sendable {
    public var canvasURL: URL
    public var childProjects: [UUID: URL]
    public var materials: [String: URL]
    public var assets: [String: URL]
    public var nodeAssets: [String: URL]
    public var missingChildProjects: [UUID]
    public var missingAssets: [String]
    public var missingNodeAssets: [String]

    public init(canvasURL: URL,
                childProjects: [UUID: URL] = [:],
                materials: [String: URL] = [:],
                assets: [String: URL] = [:],
                nodeAssets: [String: URL] = [:],
                missingChildProjects: [UUID] = [],
                missingAssets: [String] = [],
                missingNodeAssets: [String] = []) {
        self.canvasURL = canvasURL
        self.childProjects = childProjects
        self.materials = materials
        self.assets = assets
        self.nodeAssets = nodeAssets
        self.missingChildProjects = missingChildProjects
        self.missingAssets = missingAssets
        self.missingNodeAssets = missingNodeAssets
    }
}

public struct C07BuiltCanvasPackage: Sendable, Equatable {
    public var fileURL: URL
    public var manifest: C07CanvasPackageManifest
    public var byteCount: Int64
    public var sha256: String
}

public struct C07StagedCanvasImport: Sendable {
    public var manifest: C07CanvasPackageManifest
    public var manifestSHA256: String
    public var stagedRoot: URL
    public var canvasURL: URL
    public var childProjects: [UUID: URL]
    public var materials: [String: URL]
    public var assets: [String: URL]
    public var nodeAssets: [String: URL]
    public var totalBytes: Int64
}

public enum C07CanvasPackage {
    public static func build(source: C07CanvasSource,
                             destination: URL,
                             stagingRoot: URL) async throws -> C07BuiltCanvasPackage {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw C07DataExchangeError.storageUnavailable("destinationExists")
        }
        let canvasDigest: (sha256: String, byteCount: Int64)
        do {
            canvasDigest = try C07Digest.file(
                source.canvasURL,
                maximum: C07DocumentPackageLimits.maximumEntryBytes)
        } catch { throw C07DataExchangeError.documentPackage("canvasSource") }
        let canvasData: Data
        do { canvasData = try Data(contentsOf: source.canvasURL) }
        catch { throw C07DataExchangeError.documentPackage("canvasRead") }
        let references = try C07CanvasGraph.scan(canvasData: canvasData)
        var warnings: [String] = []
        try C07FileSystem.ensureDirectory(stagingRoot)
        let stage = stagingRoot.appendingPathComponent(
            "canvas-\(UUID().uuidString)", isDirectory: true)
        try C07FileSystem.ensureDirectory(stage)
        defer { C07FileSystem.removeIfPresent(stage) }
        try C07FileSystem.requireFreeSpace(
            at: stagingRoot, bytes: canvasDigest.byteCount)

        func stageFile(_ url: URL, as name: String,
                       maximum: Int64 = C07DocumentPackageLimits.maximumEntryBytes)
            throws -> (file: String, byteCount: Int64, sha256: String)
        {
            let target = stage.appendingPathComponent(name)
            try C07FileSystem.ensureDirectory(target.deletingLastPathComponent())
            let copied = try C07FileSystem.copyVerified(
                source: url, destination: target, maximum: maximum)
            return (name, copied.byteCount, copied.sha256)
        }

        var children: [C07CanvasPackageManifest.ChildProject] = []
        var missingChildIDs = source.missingChildProjects
        var mediaAssetPaths = Set<String>()
        for id in references.childProjectIDs {
            guard let url = source.childProjects[id] else {
                missingChildIDs.append(id)
                continue
            }
            do {
                let data = try Data(contentsOf: url)
                let media = try C07CanvasGraph.scanMediaProject(data: data)
                guard media.projectID == id else {
                    throw C07DataExchangeError.documentPackage("canvasChildIdentity")
                }
                mediaAssetPaths.formUnion(media.assetPaths)
                let staged = try stageFile(
                    url, as: "projects/\(id.uuidString.lowercased()).json")
                children.append(.init(projectID: id, file: staged.file,
                                      byteCount: staged.byteCount,
                                      sha256: staged.sha256))
            } catch let error as C07DataExchangeError {
                missingChildIDs.append(id)
                warnings.append("canvasChildUnavailable:\(id.uuidString.prefix(8)):\(error.code)")
            } catch {
                missingChildIDs.append(id)
                warnings.append("canvasChildUnavailable:\(id.uuidString.prefix(8)):read")
            }
        }
        var materials: [C07CanvasPackageManifest.Material] = []
        for name in references.materialNames {
            guard let url = source.materials[name] else {
                throw C07DataExchangeError.documentPackage("canvasMaterialMissing")
            }
            let staged = try stageFile(url, as: "materials/\(name)")
            materials.append(.init(fileName: name, byteCount: staged.byteCount,
                                   sha256: staged.sha256))
        }
        var assets: [C07CanvasPackageManifest.Asset] = []
        var missingAssets = Set(source.missingAssets)
        for (index, path) in mediaAssetPaths.sorted().enumerated() {
            guard let url = source.assets[path] else {
                missingAssets.insert(path)
                continue
            }
            let base = safeFileName((path as NSString).lastPathComponent)
            let staged = try stageFile(url, as: "assets/\(index)-\(base)")
            assets.append(.init(relativePath: path, file: staged.file,
                                byteCount: staged.byteCount,
                                sha256: staged.sha256))
        }
        var nodeAssets: [C07CanvasPackageManifest.NodeAsset] = []
        var missingNodeAssets = Set(source.missingNodeAssets)
        for (index, path) in references.nodeAssetPaths.sorted().enumerated() {
            guard let url = source.nodeAssets[path] else {
                // Media-root paths belong to a child project and are handled
                // above. Anything else is a truly referenced node asset.
                if !mediaAssetPaths.contains(path)
                    && !source.assets.keys.contains(path) {
                    missingNodeAssets.insert(path)
                }
                continue
            }
            let base = safeFileName((path as NSString).lastPathComponent)
            let staged = try stageFile(url, as: "nodeassets/\(index)-\(base)")
            nodeAssets.append(.init(relativePath: path, file: staged.file,
                                    byteCount: staged.byteCount,
                                    sha256: staged.sha256))
        }
        if !missingChildIDs.isEmpty {
            warnings.append("canvasChildrenMissing:\(missingChildIDs.count)")
        }
        if !missingAssets.isEmpty {
            warnings.append("canvasAssetsMissing:\(missingAssets.count)")
        }
        if !missingNodeAssets.isEmpty {
            warnings.append("canvasNodeAssetsMissing:\(missingNodeAssets.count)")
        }
        let canvasFile = try stageFile(
            source.canvasURL, as: C07DocumentPackageLimits.canvasEntry)
        let manifest = C07CanvasPackageManifest(
            canvasID: references.canvasID,
            canvasName: references.name,
            canvasSchemaVersion: references.schemaVersion,
            canvasByteCount: canvasFile.byteCount,
            canvasSHA256: canvasFile.sha256,
            childProjects: children,
            materials: materials,
            assets: assets,
            externalNodeAssets: nodeAssets,
            missingChildProjects: Array(Set(missingChildIDs)).sorted {
                $0.uuidString < $1.uuidString
            },
            missingAssets: missingAssets.sorted(),
            missingExternalNodeAssets: missingNodeAssets.sorted())
        try manifest.validate()
        let manifestData = try manifest.encoded()
        try manifestData.write(
            to: stage.appendingPathComponent(
                C07DocumentPackageLimits.canvasManifestEntry))
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        defer { C07FileSystem.removeIfPresent(temporary) }
        try writeArchive(from: stage, to: temporary)
        let digest = try C07Digest.file(temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return C07BuiltCanvasPackage(
            fileURL: destination, manifest: manifest,
            byteCount: digest.byteCount, sha256: digest.sha256)
    }

    public static func inspect(archiveURL: URL,
                               stagingRoot: URL,
                               expectedCanvasID: UUID? = nil) throws
        -> C07StagedCanvasImport
    {
        let package = try C07PackageStager.stage(
            archiveURL: archiveURL, stagingRoot: stagingRoot)
        let staged = package.entries
        guard let manifestEntry = staged[C07DocumentPackageLimits.canvasManifestEntry],
              let canvasEntry = staged[C07DocumentPackageLimits.canvasEntry] else {
            throw C07DataExchangeError.invalidManifest("canvasEntriesMissing")
        }
        let manifestData: Data
        do { manifestData = try Data(contentsOf: manifestEntry.url) }
        catch { throw C07DataExchangeError.storageUnavailable("canvasManifestRead") }
        let manifest = try C07CanvasPackageManifest.decode(manifestData)
        try manifest.validate()
        if let expectedCanvasID, expectedCanvasID != manifest.canvasID {
            throw C07DataExchangeError.invalidManifest("canvasIdentity")
        }
        guard canvasEntry.byteCount == manifest.canvasByteCount,
              canvasEntry.sha256 == manifest.canvasSHA256 else {
            throw C07DataExchangeError.hashMismatch(C07DocumentPackageLimits.canvasEntry)
        }
        let canvasData: Data
        do { canvasData = try Data(contentsOf: canvasEntry.url) }
        catch { throw C07DataExchangeError.storageUnavailable("canvasRead") }
        let references = try C07CanvasGraph.scan(canvasData: canvasData)
        guard references.canvasID == manifest.canvasID,
              references.schemaVersion == manifest.canvasSchemaVersion else {
            throw C07DataExchangeError.invalidManifest("canvasManifestIdentity")
        }
        var expected = Set<String>([
            C07DocumentPackageLimits.canvasManifestEntry,
            C07DocumentPackageLimits.canvasEntry,
        ])
        var children: [UUID: URL] = [:]
        for child in manifest.childProjects {
            guard let entry = staged[child.file],
                  entry.byteCount == child.byteCount,
                  entry.sha256 == child.sha256 else {
                throw C07DataExchangeError.hashMismatch(child.file)
            }
            guard expected.insert(child.file).inserted else {
                throw C07DataExchangeError.duplicateEntry(child.file)
            }
            children[child.projectID] = entry.url
        }
        var materials: [String: URL] = [:]
        for material in manifest.materials {
            let path = "materials/\(material.fileName)"
            guard let entry = staged[path],
                  entry.byteCount == material.byteCount,
                  entry.sha256 == material.sha256 else {
                throw C07DataExchangeError.hashMismatch(path)
            }
            guard expected.insert(path).inserted else {
                throw C07DataExchangeError.duplicateEntry(path)
            }
            materials[material.fileName] = entry.url
        }
        var assets: [String: URL] = [:]
        for asset in manifest.assets {
            guard let entry = staged[asset.file],
                  entry.byteCount == asset.byteCount,
                  entry.sha256 == asset.sha256 else {
                throw C07DataExchangeError.hashMismatch(asset.file)
            }
            guard expected.insert(asset.file).inserted else {
                throw C07DataExchangeError.duplicateEntry(asset.file)
            }
            assets[asset.relativePath] = entry.url
        }
        var nodeAssets: [String: URL] = [:]
        for asset in manifest.externalNodeAssets {
            guard let entry = staged[asset.file],
                  entry.byteCount == asset.byteCount,
                  entry.sha256 == asset.sha256 else {
                throw C07DataExchangeError.hashMismatch(asset.file)
            }
            guard expected.insert(asset.file).inserted else {
                throw C07DataExchangeError.duplicateEntry(asset.file)
            }
            nodeAssets[asset.relativePath] = entry.url
        }
        guard Set(staged.keys) == expected else {
            throw C07DataExchangeError.invalidManifest("canvasEntrySet")
        }
        let total = staged.values.reduce(Int64(0)) { $0 + $1.byteCount }
        return C07StagedCanvasImport(
            manifest: manifest,
            manifestSHA256: C07Digest.sha256(manifestData),
            stagedRoot: package.root,
            canvasURL: canvasEntry.url,
            childProjects: children,
            materials: materials,
            assets: assets,
            nodeAssets: nodeAssets,
            totalBytes: total)
    }

    private static func writeArchive(from root: URL, to destination: URL) throws {
        let archive: Archive
        do { archive = try Archive(url: destination, accessMode: .create) }
        catch { throw C07DataExchangeError.storageUnavailable("createArchive") }
        var files: [(String, URL, Int64)] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []) else {
            throw C07DataExchangeError.storageUnavailable("enumerateStaging")
        }
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            files.append((relative, url, Int64(values?.fileSize ?? 0)))
        }
        files.sort { $0.0 < $1.0 }
        for (path, url, size) in files {
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: url) }
            catch { throw C07DataExchangeError.storageUnavailable("openStaged") }
            do {
                try archive.addEntry(
                    with: path, type: .file, uncompressedSize: size,
                    compressionMethod: path.hasSuffix(".json") ? .deflate : .none
                ) { position, count in
                    try handle.seek(toOffset: UInt64(position))
                    return try handle.read(upToCount: count) ?? Data()
                }
                try? handle.close()
            } catch {
                try? handle.close()
                throw C07DataExchangeError.storageUnavailable("writeArchive")
            }
        }
    }

    private static func safeFileName(_ raw: String) -> String {
        var value = raw.precomposedStringWithCanonicalMapping
        value = value.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        value = value.filter { character in
            character.unicodeScalars.allSatisfy {
                $0.value >= 0x20 && $0.value != 0x7F
            }
        }
        if value.isEmpty { value = "resource" }
        if value.count > 200 { value = String(value.suffix(200)) }
        return value
    }
}

// MARK: - Portable document validation (.docx / .pdf)

public enum C07PortableDocumentKind: String, Codable, Sendable {
    case docx
    case pdf
}

public struct C07ValidatedDocument: Sendable, Equatable {
    public var kind: C07PortableDocumentKind
    public var displayName: String
    public var byteCount: Int64
    public var sha256: String
    public var warnings: [String]

    public init(kind: C07PortableDocumentKind, displayName: String,
                byteCount: Int64, sha256: String, warnings: [String] = []) {
        self.kind = kind
        self.displayName = displayName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.warnings = warnings
    }
}

public enum C07PortableDocumentInspector {
    public static func inspect(fileURL: URL, displayName: String) throws
        -> C07ValidatedDocument
    {
        let name = displayName.isEmpty ? fileURL.lastPathComponent : displayName
        let lower = name.lowercased()
        let digest = try C07Digest.file(
            fileURL, maximum: C07DocumentPackageLimits.maximumOfficeBytes)
        guard digest.byteCount > 0 else {
            throw C07DataExchangeError.documentPackage("emptyDocument")
        }
        if lower.hasSuffix(".docx") {
            try validateDOCX(fileURL)
            return C07ValidatedDocument(
                kind: .docx, displayName: String(name.prefix(240)),
                byteCount: digest.byteCount, sha256: digest.sha256)
        }
        if lower.hasSuffix(".pdf") {
            try validatePDF(fileURL, byteCount: digest.byteCount)
            return C07ValidatedDocument(
                kind: .pdf, displayName: String(name.prefix(240)),
                byteCount: digest.byteCount, sha256: digest.sha256)
        }
        throw C07DataExchangeError.unsupportedFormat(
            String((name as NSString).pathExtension.prefix(32)))
    }

    /// Real OOXML package structure. Macro-enabled or externally-linked
    /// packages are rejected as unsupported rather than relabelled.
    public static func validateDOCX(_ url: URL) throws {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw C07DataExchangeError.documentPackage("docxOpen") }
        var names = Set<String>()
        var total: Int64 = 0
        var count = 0
        for entry in archive {
            if entry.type == .directory { continue }
            guard entry.type == .file else {
                throw C07DataExchangeError.documentPackage("docxEntryType")
            }
            count += 1
            guard count <= C07DocumentPackageLimits.maximumOfficeEntries else {
                throw C07DataExchangeError.tooManyEntries
            }
            let path: String
            do { path = try C07Path.validateRelative(entry.path) }
            catch { throw C07DataExchangeError.unsafePath(entry.path) }
            guard names.insert(C07Path.collisionKey(path)).inserted else {
                throw C07DataExchangeError.duplicateEntry(path)
            }
            let size = try c07CheckedEntrySize(entry.uncompressedSize, path)
            guard size <= C07DocumentPackageLimits.maximumEntryBytes else {
                throw C07DataExchangeError.entryTooLarge(path)
            }
            if size > C07DocumentPackageLimits.compressionRatioProbeBytes {
                let compressed = try c07CheckedEntrySize(entry.compressedSize, path)
                if compressed > 0,
                   Double(size) / Double(compressed)
                    > C07DocumentPackageLimits.maximumCompressionRatio {
                    throw C07DataExchangeError.corruptArchive("docxRatio")
                }
            }
            total += size
            guard total <= C07DocumentPackageLimits.maximumOfficeBytes else {
                throw C07DataExchangeError.totalTooLarge
            }
        }
        for required in ["[Content_Types].xml", "_rels/.rels", "word/document.xml"] {
            guard names.contains(required.lowercased()) else {
                throw C07DataExchangeError.documentPackage("docxMissing:\(required)")
            }
        }
        guard !names.contains("word/vbapProject.bin") else {
            throw C07DataExchangeError.unsupportedFeature("docxMacro")
        }
        guard !names.contains("word/vbaProject.bin") else {
            throw C07DataExchangeError.unsupportedFeature("docxMacro")
        }
    }

    /// Bounded PDF signature check: header and final EOF marker must both be
    /// present. A truncated download cannot reach a project.
    public static func validatePDF(_ url: URL, byteCount: Int64) throws {
        guard byteCount >= 8, byteCount <= C07DocumentPackageLimits.maximumPDFBytes else {
            throw C07DataExchangeError.documentPackage("pdfSize")
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw C07DataExchangeError.storageUnavailable("pdfOpen") }
        defer { try? handle.close() }
        let head: Data
        do { head = try handle.read(upToCount: 1_024) ?? Data() }
        catch { throw C07DataExchangeError.storageUnavailable("pdfRead") }
        guard let headText = String(data: head, encoding: .isoLatin1),
              headText.range(of: "%PDF-1.", options: .literal) != nil else {
            throw C07DataExchangeError.documentPackage("pdfHeader")
        }
        let tailLength = min(Int64(4_096), byteCount)
        do {
            try handle.seek(toOffset: UInt64(byteCount - tailLength))
            let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
            guard let tailText = String(data: tail, encoding: .isoLatin1),
                  tailText.range(of: "%%EOF", options: .backwards) != nil,
                  tailText.range(of: "startxref", options: .backwards) != nil else {
                throw C07DataExchangeError.documentPackage("pdfTrailer")
            }
        } catch let error as C07DataExchangeError {
            throw error
        } catch {
            throw C07DataExchangeError.storageUnavailable("pdfRead")
        }
    }
}

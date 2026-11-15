// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public struct AssetRenamePlan: Sendable {
    public var from: GameRelativePath
    public var to: GameRelativePath
    public var references: [AssetReference]
    public var diagnostics: [GameEditDiagnostic]
}

public struct AssetDeletePlan: Sendable {
    public var path: GameRelativePath
    public var references: [AssetReference]
    public var diagnostics: [GameEditDiagnostic]
}

extension GameEditingSession {
    /// Every project file that currently exists (base minus removals plus additions).
    public func existingPaths() -> [GameRelativePath] {
        var paths = Set(baseProject.files.map(\.path))
        paths.subtract(removedPaths)
        for (path, document) in documents where document.isNew { paths.insert(path) }
        return paths.sorted { $0.value < $1.value }
    }

    /// Lists references to a file from every other project document.
    public func references(to path: GameRelativePath) async throws -> [AssetReference] {
        var result: [AssetReference] = []
        for candidate in existingPaths() where candidate != path {
            let bytes = try await documentBytes(at: candidate)
            result.append(contentsOf: GameReferenceScanner.references(to: path, inDocumentAt: candidate, bytes: bytes))
        }
        return result.sorted { lhs, rhs in
            if lhs.referencingPath.value == rhs.referencingPath.value {
                return (lhs.line ?? -1) < (rhs.line ?? -1)
            }
            return lhs.referencingPath.value < rhs.referencingPath.value
        }
    }

    /// Previews a rename: target validity plus every reference that would be
    /// rewritten. `dryRun` leaves the working set untouched.
    @discardableResult
    public func renameAsset(at path: GameRelativePath, newName: String, dryRun: Bool = false) async throws -> AssetRenamePlan {
        try beginOperation(); defer { endOperation() }
        let components = path.value.split(separator: "/").map(String.init)
        guard let last = components.last, !newName.isEmpty, !newName.contains("/"), newName != last else {
            throw GameEditIssue([GameEditDiagnostic(severity: .error,
                message: GameEditCopy("Enter a new file name without slashes.", "请输入不含斜杠的新文件名。"), path: path)])
        }
        let target = try GameRelativePath((components.dropLast() + [newName]).joined(separator: "/"))
        guard !existingPaths().contains(target) else {
            throw GameProjectError.destinationExists
        }
        let references = try await self.references(to: path)
        var diagnostics: [GameEditDiagnostic] = []
        var updates: [ReferenceBytes] = []
        let lastName = last
        for reference in references {
            let bytes = try await documentBytes(at: reference.referencingPath)
            guard let rewritten = GameReferenceRewriter.rewrite(bytes: bytes, target: path,
                                                                oldName: lastName, newName: newName,
                                                                matchedValue: reference.matchedValue) else { continue }
            updates.append(.init(path: reference.referencingPath, before: bytes, after: rewritten))
            diagnostics.append(GameEditDiagnostic(severity: .info,
                message: GameEditCopy("Updated reference in \(reference.referencingPath.value).",
                                      "已更新 \(reference.referencingPath.value) 中的引用。"),
                path: reference.referencingPath, jsonPath: reference.jsonPath))
        }
        let plan = AssetRenamePlan(from: path, to: target, references: references, diagnostics: diagnostics)
        if dryRun { return plan }
        let bytes = try await documentBytes(at: path)
        try await applyDuringOperation(.move(from: path, to: target, before: bytes,
                              referenceUpdates: updates,
                              summary: GameEditCopy("Renamed \(path.value) to \(target.value)",
                                                    "已将 \(path.value) 重命名为 \(target.value)")))
        return plan
    }

    /// Deletes an asset. Referenced files block the delete and the plan
    /// explains exactly where the references live; nothing is cascade-deleted.
    @discardableResult
    public func deleteAsset(at path: GameRelativePath) async throws -> AssetDeletePlan {
        try beginOperation(); defer { endOperation() }
        let references = try await self.references(to: path)
        guard references.isEmpty else {
            let diagnostics = references.map {
                GameEditDiagnostic(severity: .error,
                    message: GameEditCopy("Referenced by \($0.referencingPath.value)\(lineSuffix($0.line)).",
                                          "被 \($0.referencingPath.value)\(lineSuffix($0.line)) 引用。"),
                    path: $0.referencingPath, jsonPath: $0.jsonPath)
            }
            throw GameEditIssue(diagnostics)
        }
        let bytes = try await documentBytes(at: path)
        try await applyDuringOperation(.remove(path: path, before: bytes, referenceUpdates: [],
                                summary: GameEditCopy("Deleted \(path.value)", "已删除 \(path.value)")))
        return AssetDeletePlan(path: path, references: [], diagnostics: [])
    }

    /// Replaces an asset's bytes (import-over-existing).
    public func replaceAsset(at path: GameRelativePath, with contents: Data) async throws {
        try beginOperation(); defer { endOperation() }
        try await applyDuringOperation(.update(path: path, before: try await documentBytes(at: path), after: contents,
                                summary: GameEditCopy("Replaced \(path.value)", "已替换 \(path.value)")))
    }

    /// Imports new files into a project folder. Returns the created paths;
    /// duplicates are rejected up front.
    @discardableResult
    public func importAssets(_ items: [(name: String, bytes: Data)], into folder: String? = nil) async throws -> [GameRelativePath] {
        try beginOperation(); defer { endOperation() }
        var targets: [GameRelativePath] = []
        for item in items {
            let base = folder.map { $0 + "/" + item.name } ?? item.name
            let target = try GameRelativePath(base)
            guard !existingPaths().contains(target), !targets.contains(target) else { throw GameProjectError.destinationExists }
            targets.append(target)
        }
        for (target, item) in zip(targets, items) {
            try await applyDuringOperation(.update(path: target, before: nil, after: item.bytes,
                                    summary: GameEditCopy("Imported \(target.value)", "已导入 \(target.value)")))
        }
        return targets
    }

    /// Creates a tile-map staging document in the working set.
    @discardableResult
    public func createTileMap(at path: GameRelativePath, name: String,
                              tileSize: EditableTileMap.Size, layers: [EditableTileMap.Layer]) async throws -> EditableTileMap {
        try beginOperation(); defer { endOperation() }
        let map = EditableTileMap(name: name, tileSize: tileSize, layers: layers)
        let bytes = try map.encode()
        try await applyDuringOperation(.update(path: path, before: nil, after: bytes,
                                summary: GameEditCopy("Created map \(path.value)", "已创建地图 \(path.value)")))
        return map
    }

    /// Creates a narrative staging document in the working set.
    @discardableResult
    public func createNarrative(at path: GameRelativePath, title: String) async throws -> NarrativeDocument {
        try beginOperation(); defer { endOperation() }
        let document = NarrativeDocument(title: title)
        let bytes = try document.encode()
        try await applyDuringOperation(.update(path: path, before: nil, after: bytes,
                                summary: GameEditCopy("Created narrative \(path.value)",
                                                      "已创建叙事 \(path.value)")))
        return document
    }

    private func lineSuffix(_ line: Int?) -> String {
        guard let line else { return "" }
        return ":\(line)"
    }
}

/// Rewrites string references inside JSON or text bytes. Exact-path matches
/// become the full new path; file-name matches become the new file name.
enum GameReferenceRewriter {
    static func rewrite(bytes: Data, target: GameRelativePath, oldName: String,
                        newName: String, matchedValue: String) -> Data? {
        let newFullPath: String = {
            guard target.value.hasSuffix(oldName) else { return newName }
            return String(target.value.dropLast(oldName.count)) + newName
        }()
        let replacement = matchedValue == target.value ? newFullPath : newName
        guard let root = try? JSONValue.parse(bytes), root.objectValue != nil || root.arrayValue != nil else {
            return rewriteText(bytes: bytes, matchedValue: matchedValue, replacement: replacement)
        }
        var changed = false
        func walk(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let string):
                if string == matchedValue {
                    changed = true
                    return .string(replacement)
                }
                return value
            case .array(let values): return .array(values.map(walk))
            case .object(let values): return .object(values.mapValues(walk))
            default: return value
            }
        }
        let rewritten = walk(root)
        guard changed, let data = try? rewritten.serialized() else { return nil }
        return data
    }

    static func rewriteText(bytes: Data, matchedValue: String, replacement: String) -> Data? {
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        guard text.contains(matchedValue) else { return nil }
        let replaced = text.replacingOccurrences(of: matchedValue, with: replacement)
        return replaced.data(using: .utf8)
    }
}

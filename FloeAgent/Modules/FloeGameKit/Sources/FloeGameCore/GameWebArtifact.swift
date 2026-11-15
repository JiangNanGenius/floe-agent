// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

/// A real, immutable Web-ready source snapshot. Source bytes, including licenses,
/// are copied, hashed and read back. This does not transpile npm/Unity projects.
public struct GameWebArtifactPackage: Sendable {
    public let directory: URL
    public let prepared: GamePreparedArtifact
    public let files: [GameProjectFile]
    public let maximumFileBytes: Int

    private struct ContentManifest: Encodable { let engine: GameEngineID; let files: [GameProjectFile] }

    public static func build(source: GameProjectContext, engine: GameEngineID, entry: GameRelativePath,
                             to target: URL, contentRoot: URL? = nil,
                             limits: GameRepositoryLimits? = nil) throws -> Self {
        let bounds = limits ?? (try! GameRepositoryLimits())
        guard target.isFileURL, !FileManager.default.fileExists(atPath: target.path) else { throw GameProjectError.destinationExists }
        // An adapter may seal a compiled/transformed output directory while keeping
        // the original project identity. The host rechecks source revision and job
        // provenance; imported JSON cannot manufacture this non-Codable context.
        let reader = try GameProjectReader(rootURL: contentRoot ?? source.rootURL, maximumFileBytes: bounds.maximumFileBytes)
        let entries = try reader.tree(maximumEntries: bounds.maximumEntries, excludingNames: GameProjectReader.versionControlNames)
        guard entries.contains(where: { $0.path == entry && !$0.directory }),
              ["html", "htm"].contains((entry.value as NSString).pathExtension.lowercased()) else { throw GameProjectError.invalidArtifact }
        let parent = target.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard !(parent.path + "/").hasPrefix(source.rootURL.path + "/"),
              !(parent.path + "/").hasPrefix(reader.rootURL.path + "/") else { throw GameProjectError.invalidContext }
        try GameFileStorage.directory(parent)
        let stage = parent.appendingPathComponent(".game-artifact-" + UUID().uuidString)
        try GameFileStorage.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        var files: [GameProjectFile] = [], total = 0
        for item in entries {
            try Task.checkCancellation()
            let output = stage.appendingPathComponent(item.path.value)
            if item.directory { try GameFileStorage.directory(output); continue }
            guard let bytes = try reader.read(item.path), total <= bounds.maximumProjectBytes - bytes.count else {
                throw GameProjectError.limitExceeded("artifactBytes")
            }
            total += bytes.count
            let record = try GameProjectFile(path: item.path, sha256: GameDigest.sha256(bytes), bytes: bytes.count, executable: reader.isExecutable(item.path))
            try GameFileStorage.atomicWrite(bytes, to: output)
            if record.executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path) }
            guard try GameFileStorage.read(output, maximum: bounds.maximumFileBytes) == bytes else { throw GameProjectError.corruptStorage }
            files.append(record)
        }
        // Recheck all source bytes before claiming this snapshot belongs to the saved revision.
        // The host also rechecks its authoritative revision/lease after this synchronous operation.
        let finalEntries = try reader.tree(maximumEntries: bounds.maximumEntries, excludingNames: GameProjectReader.versionControlNames)
        guard entries.map(\.path) == finalEntries.map(\.path), entries.map(\.directory) == finalEntries.map(\.directory) else {
            throw GameProjectError.corruptStorage
        }
        for file in files {
            guard let bytes = try reader.read(file.path), GameDigest.sha256(bytes) == file.sha256 else { throw GameProjectError.corruptStorage }
        }
        let digest = try GameDigest.sha256(GameFileStorage.encode(ContentManifest(engine: engine, files: files)))
        try Task.checkCancellation()
        guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw GameProjectError.destinationExists }
            throw GameProjectError.io("publish artifact")
        }
        return try .init(directory: target, prepared: .init(id: UUID(), engine: engine, source: source,
            route: .webKit, sha256: digest, entry: entry), files: files, maximumFileBytes: bounds.maximumFileBytes)
    }

    public func readResource(_ path: GameRelativePath) throws -> Data {
        guard let record = files.first(where: { $0.path == path }) else { throw GameProjectError.unreadableFile(path.value) }
        let reader = try GameProjectReader(rootURL: directory, maximumFileBytes: maximumFileBytes)
        guard let bytes = try reader.read(path), bytes.count == record.bytes,
              GameDigest.sha256(bytes) == record.sha256 else { throw GameProjectError.corruptStorage }
        return bytes
    }

    public func verify() throws { for file in files { _ = try readResource(file.path) } }

    /// The validated preparer supplies the original relative game root. Bytes
    /// remain sealed; only the host-owned save scope differs between nested games.
    public func scoped(toGameRoot root: String) throws -> Self {
        try .init(directory: directory, prepared: .init(id: prepared.id, engine: prepared.engine,
            source: prepared.source, route: prepared.route, sha256: prepared.sha256,
            entry: prepared.entry, gameRoot: root), files: files, maximumFileBytes: maximumFileBytes)
    }

    public static func mimeType(for path: GameRelativePath) -> String {
        var name = path.value.lowercased()
        for suffix in [".br", ".gz", ".unityweb"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return switch (name as NSString).pathExtension {
        case "html", "htm": "text/html"
        case "js", "mjs": "application/javascript"
        case "css": "text/css"
        case "json", "map": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        case "ogg": "audio/ogg"
        case "mp4": "video/mp4"
        case "wasm": "application/wasm"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        default: "application/octet-stream"
        }
    }
}

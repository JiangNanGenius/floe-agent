// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

/// The original tree changed while it was being staged. Discard this attempt;
/// verification failures in the staged copy are reported separately.
public struct GameWebArtifactSourceChanged: Error, Sendable {
    public let path: GameRelativePath?

    public init(path: GameRelativePath? = nil) { self.path = path }
}

/// A real, immutable Web-ready source snapshot. Source bytes, including licenses,
/// are copied, hashed and read back. This does not transpile npm/Unity projects.
public struct GameWebArtifactPackage: Sendable {
    public let directory: URL
    public let prepared: GamePreparedArtifact
    public let files: [GameProjectFile]
    public let maximumFileBytes: Int

    // Only first-hand read-back identities from the sealed local APFS tree.
    // Never accept these hints from a manifest or reuse them for serving bytes.
    private let stagedFingerprints: [GameRelativePath: GameFileFingerprint]
    private let filesByPath: [GameRelativePath: GameProjectFile]

    private init(directory: URL, prepared: GamePreparedArtifact, files: [GameProjectFile],
                 maximumFileBytes: Int, stagedFingerprints: [GameRelativePath: GameFileFingerprint]) {
        self.stagedFingerprints = stagedFingerprints
        self.directory = directory
        self.prepared = prepared
        self.files = files
        self.maximumFileBytes = maximumFileBytes
        self.filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
    }

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
        let staged = try GameProjectReader(rootURL: stage, maximumFileBytes: bounds.maximumFileBytes)
        let sourceDevice = reader.localAPFSDevice, stageDevice = staged.localAPFSDevice
        var sourceFingerprints = [GameRelativePath: GameFileFingerprint]()
        var stagedFingerprints = [GameRelativePath: GameFileFingerprint]()
        var files: [GameProjectFile] = [], total = 0
        for item in entries {
            try Task.checkCancellation()
            let output = stage.appendingPathComponent(item.path.value)
            if item.directory { try GameFileStorage.directory(output); continue }
            let fd = Darwin.open(output.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw GameProjectError.io("stage web artifact") }
            let fingerprint: GameFileFingerprint?
            do {
                fingerprint = try reader.fingerprintWithIdentity(item.path, writeChunk: { chunk in
                    try chunk.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < bytes.count {
                            try Task.checkCancellation()
                            let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                            if n < 0 && errno == EINTR { continue }
                            if n <= 0 && errno == ENOSPC { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
                            guard n > 0 else { throw GameProjectError.io("write web artifact") }
                            offset += n
                        }
                    }
                })
                guard fsync(fd) == 0 else { throw GameProjectError.io("flush web artifact") }
                Darwin.close(fd)
            } catch { Darwin.close(fd); throw error }
            guard let bytes = fingerprint, total <= bounds.maximumProjectBytes - bytes.bytes else {
                throw GameProjectError.limitExceeded("artifactBytes")
            }
            total += bytes.bytes
            let record = GameProjectFile(path: item.path, sha256: bytes.sha256, bytes: bytes.bytes, executable: bytes.executable)
            if record.executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path) }
            guard let saved = try staged.fingerprintWithIdentity(item.path), saved.bytes == record.bytes, saved.sha256 == record.sha256 else { throw GameProjectError.corruptStorage }
            if bytes.device == sourceDevice { sourceFingerprints[item.path] = bytes }
            if saved.device == stageDevice { stagedFingerprints[item.path] = saved }
            files.append(record)
        }
        // Recheck all source bytes before claiming this snapshot belongs to the saved revision.
        // The host also rechecks its authoritative revision/lease after this synchronous operation.
        let finalEntries = try reader.tree(maximumEntries: bounds.maximumEntries, excludingNames: GameProjectReader.versionControlNames)
        guard entries.map(\.path) == finalEntries.map(\.path), entries.map(\.directory) == finalEntries.map(\.directory) else {
            throw GameWebArtifactSourceChanged(path: nil)
        }
        for file in files {
            guard let bytes = try reader.fingerprintWithIdentity(file.path, cached: sourceFingerprints[file.path]), bytes.bytes == file.bytes, bytes.sha256 == file.sha256, bytes.executable == file.executable else {
                throw GameWebArtifactSourceChanged(path: file.path)
            }
        }
        let digest = try GameDigest.sha256(GameFileStorage.encode(ContentManifest(engine: engine, files: files)))
        try Task.checkCancellation()
        guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw GameProjectError.destinationExists }
            throw GameProjectError.io("publish artifact")
        }
        return try .init(directory: target, prepared: .init(id: UUID(), engine: engine, source: source,
            route: .webKit, sha256: digest, entry: entry), files: files, maximumFileBytes: bounds.maximumFileBytes, stagedFingerprints: stagedFingerprints)
    }

    public func readResource(_ path: GameRelativePath) throws -> Data {
        guard let record = filesByPath[path] else { throw GameProjectError.unreadableFile(path.value) }
        let inMemoryLimit = min(maximumFileBytes, 64 * 1_024 * 1_024)
        guard record.bytes <= inMemoryLimit else { throw GameProjectError.limitExceeded(path.value) }
        let reader = try GameProjectReader(rootURL: directory, maximumFileBytes: inMemoryLimit)
        guard let bytes = try reader.read(path), bytes.count == record.bytes,
              GameDigest.sha256(bytes) == record.sha256 else { throw GameProjectError.corruptStorage }
        return bytes
    }

    public func verify() throws {
        let reader = try GameProjectReader(rootURL: directory, maximumFileBytes: maximumFileBytes)
        let localDevice = reader.localAPFSDevice
        for file in files {
            let hint = stagedFingerprints[file.path]
            guard let saved = try reader.fingerprintWithIdentity(file.path, cached: hint?.device == localDevice ? hint : nil), saved.bytes == file.bytes, saved.sha256 == file.sha256 else {
                throw GameProjectError.corruptStorage
            }
        }
    }

    /// The validated preparer supplies the original relative game root. Bytes
    /// remain sealed; only the host-owned save scope differs between nested games.
    public func scoped(toGameRoot root: String) throws -> Self {
        try .init(directory: directory, prepared: .init(id: prepared.id, engine: prepared.engine,
            source: prepared.source, route: prepared.route, sha256: prepared.sha256,
            entry: prepared.entry, gameRoot: root), files: files, maximumFileBytes: maximumFileBytes, stagedFingerprints: stagedFingerprints)
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

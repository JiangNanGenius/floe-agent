// SPDX-License-Identifier: MPL-2.0
//
// Packed/reference-only project manifest for the media exchange qualification.
//
// A packed package owns its media bytes under `media/`; a reference-only
// manifest keeps the original external location and never copies or claims
// ownership. Missing media is reported, never silently replaced. Relinking is
// explicit, revisioned and recorded. Source bytes are hashed before writing.

import Foundation
import CryptoKit

public enum ExchangeProjectStorageMode: String, Codable, Hashable, Sendable {
    case packed
    case referenced
}

public enum ExchangeProjectKind: String, Codable, Hashable, Sendable {
    case image
    case video
}

public enum ExchangeProjectError: Error, Equatable, CustomStringConvertible {
    case invalidManifest(String)
    case duplicateMediaID(String)
    case destinationExists(String)
    case unsupportedStorageMode(String)
    case missingFile(String)
    case notAFile(String)
    case ownershipTransferRequiresExplicitConsent(String)
    case contentHashMismatch(media: String, expected: String, actual: String)
    case byteCountMismatch(media: String, expected: Int64, actual: Int64)
    case relinkTargetIsNotExternal(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case let .invalidManifest(reason): return "invalid project manifest: \(reason)"
        case let .duplicateMediaID(id): return "duplicate media id \(id)"
        case let .destinationExists(path): return "destination already exists: \(path)"
        case let .unsupportedStorageMode(mode): return "unsupported storage mode \(mode)"
        case let .missingFile(path): return "media file is missing: \(path)"
        case let .notAFile(path): return "media path is not a regular file: \(path)"
        case let .ownershipTransferRequiresExplicitConsent(id):
            return "relinking \(id) would transfer media ownership; explicit consent is required"
        case let .contentHashMismatch(media, expected, actual):
            return "content hash mismatch for \(media): expected \(expected), got \(actual)"
        case let .byteCountMismatch(media, expected, actual):
            return "byte count mismatch for \(media): expected \(expected), got \(actual)"
        case let .relinkTargetIsNotExternal(id): return "relink target for \(id) is not an external file URL"
        case let .writeFailed(reason): return "could not write project package: \(reason)"
        }
    }
}

public struct ExchangeRelinkRecord: Codable, Hashable, Sendable {
    public var previousLocation: String
    public var newLocation: String
    public var reason: String
    public var sourceRevisionBefore: UInt64
    public var sourceRevisionAfter: UInt64

    public init(
        previousLocation: String,
        newLocation: String,
        reason: String,
        sourceRevisionBefore: UInt64,
        sourceRevisionAfter: UInt64
    ) {
        self.previousLocation = previousLocation
        self.newLocation = newLocation
        self.reason = reason
        self.sourceRevisionBefore = sourceRevisionBefore
        self.sourceRevisionAfter = sourceRevisionAfter
    }
}

public struct ExchangeManifestMedia: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: ExchangeMediaKind
    public var originalName: String
    public var source: ExchangeMediaSource
    public var contentHash: String?
    public var byteCount: Int64?
    public var relinkHistory: [ExchangeRelinkRecord]

    public init(
        id: String,
        kind: ExchangeMediaKind,
        originalName: String,
        source: ExchangeMediaSource,
        contentHash: String? = nil,
        byteCount: Int64? = nil,
        relinkHistory: [ExchangeRelinkRecord] = []
    ) {
        self.id = id
        self.kind = kind
        self.originalName = originalName
        self.source = source
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.relinkHistory = relinkHistory
    }
}

public struct ExchangeSourceSnapshot: Codable, Hashable, Sendable {
    /// The document revision from which this manifest was created.
    public var sourceRevision: UInt64
    /// SHA-256 of the complete manifest body with the digest field omitted.
    public var manifestDigest: String
    public var capturedAt: Date
    public var note: String

    public init(sourceRevision: UInt64, manifestDigest: String, capturedAt: Date = Date(), note: String = "") {
        self.sourceRevision = sourceRevision
        self.manifestDigest = manifestDigest
        self.capturedAt = capturedAt
        self.note = note
    }
}

public struct ExchangeProjectManifest: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var projectID: String
    public var projectName: String
    public var kind: ExchangeProjectKind
    public var storageMode: ExchangeProjectStorageMode
    public var sourceRevision: UInt64
    public var sourceSnapshot: ExchangeSourceSnapshot
    public var media: [ExchangeManifestMedia]
    public var timeline: ExchangeTimeline?
    public var metadata: [String: String]

    public init(
        projectID: String,
        projectName: String,
        kind: ExchangeProjectKind,
        storageMode: ExchangeProjectStorageMode,
        sourceRevision: UInt64,
        media: [ExchangeManifestMedia],
        timeline: ExchangeTimeline? = nil,
        metadata: [String: String] = [:],
        capturedAt: Date = Date(),
        note: String = ""
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.projectID = projectID
        self.projectName = projectName
        self.kind = kind
        self.storageMode = storageMode
        self.sourceRevision = sourceRevision
        self.media = media
        self.timeline = timeline
        self.metadata = metadata
        self.sourceSnapshot = ExchangeSourceSnapshot(
            sourceRevision: sourceRevision,
            manifestDigest: "",
            capturedAt: Self.normalizedDate(capturedAt),
            note: note
        )
    }

    /// Computes the canonical digest of the manifest body. The snapshot digest
    /// field is excluded so the value is stable across re-serialization.
    public func computedDigest() throws -> String {
        var copy = self
        copy.sourceSnapshot.manifestDigest = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(copy)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public mutating func seal() throws {
        sourceSnapshot.sourceRevision = sourceRevision
        sourceSnapshot.manifestDigest = try computedDigest()
    }

    public func verifyDigest() throws {
        let expected = try computedDigest()
        guard expected == sourceSnapshot.manifestDigest else {
            throw ExchangeProjectError.invalidManifest(
                "manifest digest mismatch: expected \(sourceSnapshot.manifestDigest), computed \(expected)"
            )
        }
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ExchangeProjectError.invalidManifest("unsupported schema version \(schemaVersion)")
        }
        guard !projectID.isEmpty else {
            throw ExchangeProjectError.invalidManifest("project id is empty")
        }
        var seen = Set<String>()
        for entry in media {
            guard !entry.id.isEmpty else {
                throw ExchangeProjectError.invalidManifest("media entry id is empty")
            }
            guard seen.insert(entry.id).inserted else {
                throw ExchangeProjectError.duplicateMediaID(entry.id)
            }
            try entry.source.validate()
            if storageMode == .packed, entry.source.storage != .packed {
                throw ExchangeProjectError.unsupportedStorageMode("mixed packed/reference media")
            }
            if storageMode == .referenced, entry.source.storage != .external {
                throw ExchangeProjectError.unsupportedStorageMode("referenced manifest contains packed media")
            }
        }
        if let timeline {
            try timeline.validate()
            let timelineMedia = Set(timeline.media.map(\.id))
            let manifestMedia = Set(media.map(\.id))
            guard timelineMedia == manifestMedia else {
                throw ExchangeProjectError.invalidManifest(
                    "timeline media ids do not match manifest media ids"
                )
            }
        }
    }

    // MARK: - Creation

    /// Copies the supplied media into `<destination>/media/` and records a
    /// packed manifest. The destination must be new or an empty directory.
    /// Existing user files are never overwritten.
    public static func makePacked(
        projectName: String,
        projectID: String = UUID().uuidString,
        timeline: ExchangeTimeline,
        mediaFiles: [String: URL],
        destination: URL,
        note: String = ""
    ) throws -> ExchangeProjectManifest {
        var timeline = timeline
        var manifestMedia: [ExchangeManifestMedia] = []
        let fileManager = FileManager.default
        let mediaRoot = destination.appendingPathComponent("media", isDirectory: true)
        try prepareDestination(destination)
        try fileManager.createDirectory(at: mediaRoot, withIntermediateDirectories: true)

        for (index, reference) in timeline.media.enumerated() {
            guard let fileURL = mediaFiles[reference.id] else {
                throw ExchangeProjectError.missingFile(reference.id)
            }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw ExchangeProjectError.notAFile(fileURL.path)
            }
            let data = try Data(contentsOf: fileURL)
            let hash = sha256(data)
            let byteCount = Int64(data.count)
            let baseName = safeBaseName(reference.name, fallback: "media-\(index)")
            let relativePath = "media/\(String(format: "%03d", index))-\(baseName)"
            let target = try ExchangePathSafety.resolvePacked(relativePath, in: destination)
            guard !fileManager.fileExists(atPath: target.path) else {
                throw ExchangeProjectError.destinationExists(target.path)
            }
            try data.write(to: target, options: .atomic)
            timeline.media[index].source = try ExchangeMediaSource(packedRelativePath: relativePath)
            timeline.media[index].contentHash = hash
            timeline.media[index].byteCount = byteCount
            manifestMedia.append(ExchangeManifestMedia(
                id: reference.id,
                kind: reference.kind,
                originalName: fileURL.lastPathComponent,
                source: try ExchangeMediaSource(packedRelativePath: relativePath),
                contentHash: hash,
                byteCount: byteCount
            ))
        }

        var manifest = ExchangeProjectManifest(
            projectID: projectID,
            projectName: projectName,
            kind: .video,
            storageMode: .packed,
            sourceRevision: timeline.sourceRevision,
            media: manifestMedia,
            timeline: timeline,
            note: note
        )
        try manifest.seal()
        try manifest.write(to: destination)
        return manifest
    }

    /// Builds a reference-only manifest. No file is copied or opened for
    /// writing; every entry remains externally owned and must be an absolute
    /// file URL. A bookmark is retained when supplied.
    public static func makeReferenced(
        projectName: String,
        projectID: String = UUID().uuidString,
        timeline: ExchangeTimeline,
        externalURLs: [String: URL],
        bookmarks: [String: Data] = [:],
        note: String = ""
    ) throws -> ExchangeProjectManifest {
        var timeline = timeline
        var manifestMedia: [ExchangeManifestMedia] = []
        for index in timeline.media.indices {
            let reference = timeline.media[index]
            guard let url = externalURLs[reference.id] else {
                throw ExchangeProjectError.missingFile(reference.id)
            }
            guard url.isFileURL else {
                throw ExchangeProjectError.relinkTargetIsNotExternal(reference.id)
            }
            let source = try ExchangeMediaSource(
                externalURL: url.absoluteString,
                securityScopedBookmark: bookmarks[reference.id]
            )
            timeline.media[index].source = source
            manifestMedia.append(ExchangeManifestMedia(
                id: reference.id,
                kind: reference.kind,
                originalName: url.lastPathComponent,
                source: source
            ))
        }
        var manifest = ExchangeProjectManifest(
            projectID: projectID,
            projectName: projectName,
            kind: .video,
            storageMode: .referenced,
            sourceRevision: timeline.sourceRevision,
            media: manifestMedia,
            timeline: timeline,
            note: note
        )
        try manifest.seal()
        return manifest
    }

    // MARK: - Read / write

    public func write(to packageRoot: URL) throws {
        try validate()
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            data = try encoder.encode(self)
        } catch {
            throw ExchangeProjectError.writeFailed(String(describing: error))
        }
        let manifestURL = packageRoot.appendingPathComponent("manifest.json")
        do {
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            throw ExchangeProjectError.writeFailed(String(describing: error))
        }
    }

    public static func load(from packageRoot: URL) throws -> ExchangeProjectManifest {
        let manifestURL = packageRoot.appendingPathComponent("manifest.json")
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw ExchangeProjectError.missingFile(manifestURL.path)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let manifest: ExchangeProjectManifest
        do {
            manifest = try decoder.decode(ExchangeProjectManifest.self, from: data)
        } catch {
            throw ExchangeProjectError.invalidManifest(String(describing: error))
        }
        try manifest.verifyDigest()
        try manifest.validate()
        return manifest
    }

    /// Resolves all media without changing the manifest. Missing or changed
    /// files are reported, never replaced. External URLs with bookmarks are
    /// returned separately so the caller owns the security-scope lifetime.
    public func resolveMedia(in packageRoot: URL) -> ExchangeProjectOpenResult {
        var resolved: [String: URL] = [:]
        var missing: [String] = []
        var externalSecurityScoped: [String] = []
        var hashesMismatched: [String] = []
        var byteCountsMismatched: [String] = []
        for entry in media {
            do {
                let url = try entry.source.resolve(in: packageRoot)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    missing.append(entry.id)
                    continue
                }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else {
                    missing.append(entry.id)
                    continue
                }
                resolved[entry.id] = url
                if entry.source.securityScopedBookmark != nil {
                    externalSecurityScoped.append(entry.id)
                }
                let data = try Data(contentsOf: url)
                if let expected = entry.contentHash, Self.sha256(data) != expected {
                    hashesMismatched.append(entry.id)
                }
                if let expected = entry.byteCount, expected != Int64(data.count) {
                    byteCountsMismatched.append(entry.id)
                }
            } catch {
                missing.append(entry.id)
            }
        }
        let warnings = hashesMismatched.map { "media \($0) content hash changed" }
            + byteCountsMismatched.map { "media \($0) byte count changed" }
        return ExchangeProjectOpenResult(
            manifest: self,
            resolvedMedia: resolved,
            missingMedia: missing,
            externalSecurityScopedMedia: externalSecurityScoped,
            warnings: warnings
        )
    }

    /// Relinks one media entry. Packed entries stay packed unless the caller
    /// explicitly consents to an ownership transfer; reference-only entries
    /// stay external. The revision increments and the relink is recorded.
    public mutating func relink(
        mediaID: String,
        to newURL: URL,
        reason: String,
        transferOwnership: Bool = false,
        newPackageRelativePath: String? = nil,
        packageRoot: URL? = nil
    ) throws -> ExchangeRelinkRecord {
        guard let index = media.firstIndex(where: { $0.id == mediaID }) else {
            throw ExchangePathError.missingMediaID(mediaID)
        }
        guard newURL.isFileURL else {
            throw ExchangeProjectError.relinkTargetIsNotExternal(mediaID)
        }
        let values = try newURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw ExchangeProjectError.notAFile(newURL.path)
        }
        let data = try Data(contentsOf: newURL)
        let hash = Self.sha256(data)
        let bytes = Int64(data.count)
        let oldLocation: String
        let newSource: ExchangeMediaSource
        switch media[index].source.storage {
        case .packed:
            guard !transferOwnership else {
                throw ExchangeProjectError.ownershipTransferRequiresExplicitConsent(mediaID)
            }
            guard let relativePath = newPackageRelativePath else {
                throw ExchangeProjectError.ownershipTransferRequiresExplicitConsent(mediaID)
            }
            newSource = try ExchangeMediaSource(packedRelativePath: relativePath)
            oldLocation = media[index].source.relativePath ?? ""
            if let packageRoot {
                let target = try ExchangePathSafety.resolvePacked(relativePath, in: packageRoot)
                if FileManager.default.fileExists(atPath: target.path) {
                    let existing = try Data(contentsOf: target)
                    guard existing == data else {
                        throw ExchangeProjectError.destinationExists(target.path)
                    }
                } else {
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: target, options: .atomic)
                }
            }
        case .external:
            guard !transferOwnership else {
                throw ExchangeProjectError.ownershipTransferRequiresExplicitConsent(mediaID)
            }
            let oldURL = media[index].source.externalURL
            newSource = try ExchangeMediaSource(
                externalURL: newURL.absoluteString,
                securityScopedBookmark: oldURL == newURL.absoluteString
                    ? media[index].source.securityScopedBookmark
                    : nil
            )
            oldLocation = media[index].source.externalURL ?? ""
        }
        let before = sourceRevision
        sourceRevision += 1
        let record = ExchangeRelinkRecord(
            previousLocation: oldLocation,
            newLocation: newURL.absoluteString,
            reason: reason,
            sourceRevisionBefore: before,
            sourceRevisionAfter: sourceRevision
        )
        media[index].source = newSource
        media[index].contentHash = hash
        media[index].byteCount = bytes
        media[index].relinkHistory.append(record)
        if var timeline {
            for index in timeline.media.indices where timeline.media[index].id == mediaID {
                timeline.media[index].source = newSource
                timeline.media[index].contentHash = hash
                timeline.media[index].byteCount = bytes
            }
            timeline.sourceRevision = sourceRevision
            self.timeline = timeline
        }
        try seal()
        return record
    }

    // MARK: - Helpers

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedDate(_ date: Date) -> Date {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    private static func prepareDestination(_ destination: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ExchangeProjectError.destinationExists(destination.path)
            }
            let contents = try fileManager.contentsOfDirectory(atPath: destination.path)
            guard contents.isEmpty else {
                throw ExchangeProjectError.destinationExists(destination.path)
            }
        } else {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        }
    }

    private static func safeBaseName(_ name: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- "))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let candidate = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = candidate.isEmpty ? fallback : candidate
        return String(cleaned.prefix(80))
    }
}

public struct ExchangeProjectOpenResult: Sendable {
    public var manifest: ExchangeProjectManifest
    public var resolvedMedia: [String: URL]
    public var missingMedia: [String]
    public var externalSecurityScopedMedia: [String]
    public var warnings: [String]

    public init(
        manifest: ExchangeProjectManifest,
        resolvedMedia: [String: URL],
        missingMedia: [String],
        externalSecurityScopedMedia: [String],
        warnings: [String]
    ) {
        self.manifest = manifest
        self.resolvedMedia = resolvedMedia
        self.missingMedia = missingMedia
        self.externalSecurityScopedMedia = externalSecurityScopedMedia
        self.warnings = warnings
    }
}

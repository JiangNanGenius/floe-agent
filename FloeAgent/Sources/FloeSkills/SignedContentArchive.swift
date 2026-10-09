// FloeSkills — bounded archive staging and atomic install for signed content.
//
// Extracted in memory first, validated entry-by-entry, then written to a
// fresh staging root; the active install is replaced atomically with a
// recoverable backup. Failed operations always leave the previous install
// reachable.

import Foundation
import Crypto
import ZIPFoundation
import FloeCore

public struct SignedContentArchiveLimits: Sendable, Equatable {
    public var maximumEntries: Int
    public var maximumFileBytes: Int
    public var maximumTotalBytes: Int

    public init(
        maximumEntries: Int = 128,
        maximumFileBytes: Int = 2 * 1_024 * 1_024,
        maximumTotalBytes: Int = 8 * 1_024 * 1_024
    ) {
        self.maximumEntries = maximumEntries
        self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
    }

    public static let content = SignedContentArchiveLimits()
}

public enum SignedContentArchive {
    /// Streams a ZIP from memory with hard entry/file/total bounds and path
    /// validation. On any failure no files are created under `root`.
    public static func extract(
        _ zip: Data,
        at root: URL,
        limits: SignedContentArchiveLimits = .content,
        allowedTopLevel: Set<String>? = nil
    ) throws -> [String: Data] {
        guard zip.count <= limits.maximumTotalBytes,
              !FileManager.default.fileExists(atPath: root.path) else {
            throw SignedContentFailure.archive
        }
        let archive: Archive
        do {
            archive = try Archive(data: zip, accessMode: .read)
        } catch {
            throw SignedContentFailure.archive
        }
        var paths: Set<String> = []
        var files: [String: Data] = [:]
        var total = 0
        var entries = 0
        do {
            for entry in archive {
                try Task.checkCancellation()
                entries += 1
                guard entries <= limits.maximumEntries, entry.type == .file,
                      entry.uncompressedSize <= UInt64(limits.maximumFileBytes) else {
                    throw SignedContentFailure.archive
                }
                try validate(path: entry.path, allowedTopLevel: allowedTopLevel)
                let normalized = entry.path.precomposedStringWithCanonicalMapping.lowercased()
                guard paths.insert(normalized).inserted else { throw SignedContentFailure.archive }
                var data = Data()
                let checksum = try archive.extract(entry, bufferSize: 32_768) { chunk in
                    try Task.checkCancellation()
                    total += chunk.count
                    guard total <= limits.maximumTotalBytes,
                          data.count + chunk.count <= limits.maximumFileBytes else {
                        throw SignedContentFailure.archive
                    }
                    data.append(chunk)
                }
                guard checksum == entry.checksum, data.count == entry.uncompressedSize else {
                    throw SignedContentFailure.archive
                }
                files[entry.path] = data
            }
        } catch let failure as SignedContentFailure {
            throw failure
        } catch {
            throw SignedContentFailure.archive
        }
        guard !files.isEmpty else { throw SignedContentFailure.archive }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (path, bytes) in files {
                let target = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try bytes.write(to: target, options: .atomic)
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw SignedContentFailure.archive
        }
        return files
    }

    static func validate(path: String, allowedTopLevel: Set<String>?) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0"),
              path.utf8.count <= 512,
              !path.split(separator: "/").contains(".."),
              !path.hasPrefix(".") else {
            throw SignedContentFailure.archive
        }
        let topLevel = path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        guard !topLevel.isEmpty else { throw SignedContentFailure.archive }
        if let allowedTopLevel, !allowedTopLevel.contains(topLevel) {
            throw SignedContentFailure.archive
        }
    }

    /// Same length-prefixed canonical digest as the package validator, so a
    /// signed `contentDigest` identifies exact file names and bytes.
    public static func canonicalDigest(_ files: [String: Data]) -> String {
        var hasher = SHA256()
        for name in files.keys.sorted() {
            guard let data = files[name] else { continue }
            let pathBytes = Data(name.utf8)
            var length = UInt64(pathBytes.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: pathBytes)
            var dataLength = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &dataLength) { hasher.update(data: Data($0)) }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A verified, staged content package ready to activate. Files are already on
/// disk under `rootURL`; `canonicalSHA256` matches the signed contentDigest.
public struct StagedSignedContent: Sendable {
    public let entry: SignedContentEntry
    public let rootURL: URL
    public let files: [String: Data]
    public let canonicalSHA256: String

    public init(
        entry: SignedContentEntry,
        rootURL: URL,
        files: [String: Data],
        canonicalSHA256: String
    ) {
        self.entry = entry
        self.rootURL = rootURL
        self.files = files
        self.canonicalSHA256 = canonicalSHA256
    }
}

public enum SignedContentInstaller {
    /// Verifies the signed size/hash, extracts within bounds, checks the
    /// canonical digest and then runs the domain codec's validation. Only a
    /// package that passes every gate is left on disk.
    public static func stage(
        zip: Data,
        entry: SignedContentEntry,
        at root: URL,
        limits: SignedContentArchiveLimits = .content,
        allowedTopLevel: Set<String>? = nil,
        domainValidate: ((SignedContentEntry, [String: Data]) throws -> Void)? = nil
    ) throws -> StagedSignedContent {
        guard zip.count == entry.size else { throw SignedContentFailure.archive }
        guard SignedContentArchive.sha256Hex(zip) == entry.sha256.lowercased() else {
            throw SignedContentFailure.archive
        }
        do {
            let files = try SignedContentArchive.extract(
                zip, at: root, limits: limits, allowedTopLevel: allowedTopLevel
            )
            let digest = SignedContentArchive.canonicalDigest(files)
            guard digest == entry.contentDigest.lowercased() else {
                throw SignedContentFailure.immutableVersion
            }
            try domainValidate?(entry, files)
            return StagedSignedContent(
                entry: entry, rootURL: root, files: files, canonicalSHA256: digest
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    /// Atomically replaces `destination` with the staged package. The previous
    /// install is moved aside first and restored if the swap or the final
    /// verification fails.
    public static func activate(
        _ staged: StagedSignedContent,
        at destination: URL,
        verify: ((StagedSignedContent) throws -> Void)? = nil
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: staged.rootURL.path) else {
            throw SignedContentFailure.archive
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-backup-\(UUID().uuidString)")
        let destinationExisted = fileManager.fileExists(atPath: destination.path)
        if destinationExisted {
            try fileManager.moveItem(at: destination, to: backup)
        }
        do {
            try fileManager.moveItem(at: staged.rootURL, to: destination)
            try verify?(staged)
            if destinationExisted { try? fileManager.removeItem(at: backup) }
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            if destinationExisted, fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }
}

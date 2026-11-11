// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import FloeCore
import FloeTools
import FloeWorkbench

/// Private import copies are bounded, owned by one transaction, and removed
/// by anchored name/inode only until the existing coordinator commits them.
nonisolated final class MediaV2StagedAsset: @unchecked Sendable {
    struct Stamp: Equatable, Sendable {
        let device: Int64, inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanos: Int64, changedSeconds: Int64, changedNanos: Int64
        init(_ value: stat) {
            device = Int64(value.st_dev); inode = UInt64(value.st_ino); size = value.st_size
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
        }
        func sameObject(_ other: Self) -> Bool { device == other.device && inode == other.inode }
    }
    let source: URL, url: URL, byteCount: Int64, sha256: String
    private let sourceStamp: Stamp, destinationStamp: Stamp
    private let sourceParents: [(URL, Stamp)], destinationRoot: (URL, Stamp), assetDirectory: (URL, Stamp)
    private let directoryFD: Int32, fileName: String, scoped: Bool, scopeURL: URL, ephemeralSource: Bool
    private let lock = NSLock()
    private var committed = false

    private init(source: URL, url: URL, sourceStamp: Stamp, destinationStamp: Stamp,
                 sourceParents: [(URL, Stamp)], destinationRoot: (URL, Stamp), assetDirectory: (URL, Stamp),
                 directoryFD: Int32, fileName: String, scoped: Bool, scopeURL: URL, ephemeralSource: Bool, byteCount: Int64, sha256: String) {
        self.source = source; self.url = url; self.sourceStamp = sourceStamp; self.destinationStamp = destinationStamp
        self.sourceParents = sourceParents; self.destinationRoot = destinationRoot; self.assetDirectory = assetDirectory
        self.directoryFD = directoryFD; self.fileName = fileName; self.scoped = scoped; self.scopeURL = scopeURL; self.ephemeralSource = ephemeralSource; self.byteCount = byteCount; self.sha256 = sha256
    }
    deinit {
        lock.lock(); let remove = !committed; lock.unlock()
        if remove {
            var current = stat()
            if fstatat(directoryFD, fileName, &current, AT_SYMLINK_NOFOLLOW) == 0,
               destinationStamp.sameObject(Stamp(current)), (current.st_mode & S_IFMT) == S_IFREG {
                _ = unlinkat(directoryFD, fileName, 0)
            }
        }
        close(directoryFD)
        if scoped { scopeURL.stopAccessingSecurityScopedResource() }
    }
    func keepCommitted() { lock.lock(); committed = true; lock.unlock() }
    private static func stamp(_ url: URL, directory: Bool) throws -> Stamp {
        var value = stat()
        guard lstat(url.path, &value) == 0, (value.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) else {
            throw MediaPreparedCoreError.conflict("import file or parent moved")
        }
        return Stamp(value)
    }
    func validate() throws {
        guard try Self.stamp(url, directory: false) == destinationStamp,
              try Self.stamp(destinationRoot.0, directory: true).sameObject(destinationRoot.1),
              try Self.stamp(assetDirectory.0, directory: true).sameObject(assetDirectory.1) else {
            throw MediaPreparedCoreError.conflict("import source or destination changed")
        }
        if !ephemeralSource {
            guard try Self.stamp(source, directory: false) == sourceStamp else { throw MediaPreparedCoreError.conflict("import source changed") }
        }
        for (parent, expected) in sourceParents {
            guard try Self.stamp(parent, directory: true).sameObject(expected) else {
                throw MediaPreparedCoreError.conflict("import source parent moved")
            }
        }
    }
    static func copy(source originalSource: URL, destinationRoot: URL, token: CancellationToken?, ephemeralSource: Bool,
                     progress: (@Sendable (Int64) -> Void)? = nil) throws -> MediaV2StagedAsset {
        func check() throws { try Task.checkCancellation(); try token?.throwIfCancelled() }
        try check()
        let scoped = originalSource.startAccessingSecurityScopedResource()
        var scopeOwned = true
        defer { if scopeOwned && scoped { originalSource.stopAccessingSecurityScopedResource() } }
        let source = originalSource.resolvingSymlinksInPath().standardizedFileURL, root = destinationRoot.resolvingSymlinksInPath().standardizedFileURL
        let before = try stamp(source, directory: false)
        guard before.size > 0, before.size <= 2_147_483_648 else { throw MediaV2CommandError.invalidInput }
        var parents: [(URL, Stamp)] = []
        var parent = source.deletingLastPathComponent()
        while parent.path != "/" {
            parents.append((parent, try stamp(parent, directory: true))); parent.deleteLastPathComponent()
        }
        let rootStamp = try stamp(root, directory: true)
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw MediaV2CommandError.invalidInput }
        defer { close(rootFD) }
        var openedRoot = stat()
        guard fstat(rootFD, &openedRoot) == 0, Stamp(openedRoot).sameObject(rootStamp) else { throw MediaPreparedCoreError.conflict("import destination parent moved") }
        guard mkdirat(rootFD, "Assets", mode_t(0o700)) == 0 || errno == EEXIST else { throw MediaV2CommandError.invalidInput }
        let assetsFD = openat(rootFD, "Assets", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0)
        guard assetsFD >= 0 else { throw MediaV2CommandError.invalidInput }
        var directoryOwned = true
        defer { if directoryOwned { close(assetsFD) } }
        let assetsURL = root.appendingPathComponent("Assets"), assetsStamp = try stamp(assetsURL, directory: true)
        let suffix = source.pathExtension.lowercased()
        guard !suffix.isEmpty, suffix.utf8.count <= 16, suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw MediaV2CommandError.invalidInput
        }
        let name = UUID().uuidString + "." + suffix
        let output = openat(assetsFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard output >= 0 else { throw MediaV2CommandError.invalidInput }
        var preserve = false
        defer { close(output); if !preserve { _ = unlinkat(assetsFD, name, 0) } }
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw MediaV2CommandError.invalidInput }
        defer { close(input) }
        var initial = stat()
        guard fstat(input, &initial) == 0, Stamp(initial) == before, (initial.st_mode & S_IFMT) == S_IFREG else {
            throw MediaPreparedCoreError.conflict("import source changed before copying")
        }
        var buffer = [UInt8](repeating: 0, count: 1_048_576), count: Int64 = 0, hasher = SHA256()
        while true {
            try check()
            let size = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress!, $0.count) }
            if size < 0 && errno == EINTR { continue }
            guard size >= 0 else { throw MediaV2CommandError.invalidInput }
            if size == 0 { break }
            count += Int64(size)
            guard count <= 2_147_483_648 else { throw MediaV2CommandError.invalidInput }
            let bytes = Data(buffer.prefix(size)); hasher.update(data: bytes)
            try bytes.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try check()
                    let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw MediaV2CommandError.invalidInput }; offset += written
                }
            }
            progress?(count)
        }
        var after = stat(), target = stat()
        guard count == before.size, fstat(input, &after) == 0, Stamp(after) == before,
              fsync(output) == 0, fstat(output, &target) == 0 else { throw MediaPreparedCoreError.conflict("import source changed while copying") }
        let value = MediaV2StagedAsset(source: source, url: assetsURL.appendingPathComponent(name), sourceStamp: before,
            destinationStamp: Stamp(target), sourceParents: parents, destinationRoot: (root, rootStamp), assetDirectory: (assetsURL, assetsStamp),
            directoryFD: assetsFD, fileName: name, scoped: scoped, scopeURL: originalSource, ephemeralSource: ephemeralSource, byteCount: count,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        scopeOwned = false; directoryOwned = false; preserve = true
        try value.validate(); try check()
        return value
    }
}

@MainActor final class MediaV2ImportScope {
    let token: CancellationToken?
    private var staged: [MediaV2StagedAsset] = []
    init(token: CancellationToken?) { self.token = token }
    func add(_ value: MediaV2StagedAsset) { staged.append(value) }
    func validate() throws { try Task.checkCancellation(); try token?.throwIfCancelled(); for value in staged { try value.validate() } }
    func didCommit() { staged.forEach { $0.keepCommitted() } }
    func retainReferenced(in project: MediaProject) { retainReferenced(MediaPreparedAssets.retainedAssets(in: project)) }
    func retainReferenced(_ assets: [MediaAssetReference]) {
        let names = Set(assets.map(\.relativePath))
        for value in staged where names.contains("Assets/" + value.url.lastPathComponent) { value.keepCommitted() }
    }
}

/// The extraction output is a fresh private name. Holding its parent fd
/// makes failure cleanup follow this operation if the work is moved.
nonisolated final class MediaV2ImportTemporaryFile {
    let url: URL
    private let parent: Int32, name: String
    init(root: URL, fileExtension: String = "m4a") throws {
        guard ["m4a","png","wav","mp4"].contains(fileExtension) else { throw MediaV2CommandError.invalidInput }
        let folder = root.resolvingSymlinksInPath().appendingPathComponent("Assets")
        parent = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw MediaV2CommandError.invalidInput }
        name = UUID().uuidString + "." + fileExtension; url = folder.appendingPathComponent(name)
    }
    func write(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 134_217_728 else { throw MediaV2CommandError.invalidInput }
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw MediaV2CommandError.invalidInput }
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(1_048_576, bytes.count-offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw MediaV2CommandError.invalidInput }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw MediaV2CommandError.invalidInput }
    }
    deinit {
        var value = stat()
        if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0, (value.st_mode & S_IFMT) == S_IFREG { _ = unlinkat(parent, name, 0) }
        close(parent)
    }
}

nonisolated enum MediaV2ImportIO {
    static func stage(_ source: URL, root: URL, token: CancellationToken?, ephemeralSource: Bool = false) async throws -> (MediaV2StagedAsset, MediaAssetReference) {
        let work = Task.detached(priority: .userInitiated) {
            let value = try MediaV2StagedAsset.copy(source: source, destinationRoot: root, token: token, ephemeralSource: ephemeralSource)
            let type = UTType(filenameExtension: source.pathExtension)
            let kind: MediaAssetKind
            var metadata: MediaAssetMetadata?
            if type?.conforms(to: .image) == true {
                guard let image = CGImageSourceCreateWithURL(value.url as CFURL, nil), CGImageSourceGetCount(image) > 0,
                      CGImageSourceCopyPropertiesAtIndex(image, 0, nil) != nil else { throw MediaV2CommandError.invalidInput }
                kind = .image
            } else {
                if type?.conforms(to: .audio) == true { kind = .audio }
                else if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { kind = .video }
                else { throw MediaV2CommandError.invalidInput }
                let asset = AVURLAsset(url: value.url)
                let duration = try await asset.load(.duration).seconds
                let audio = try await asset.loadTracks(withMediaType: .audio)
                let video = try await asset.loadTracks(withMediaType: .video)
                guard duration.isFinite, duration > 0, (kind == .audio ? !audio.isEmpty : !video.isEmpty) else { throw MediaV2CommandError.invalidInput }
                metadata = .init(durationSeconds: duration, audioTracks: audio.count)
            }
            try value.validate(); try Task.checkCancellation(); try token?.throwIfCancelled()
            return (value, MediaAssetReference(kind: kind, relativePath: "Assets/" + value.url.lastPathComponent,
                originalName: source.lastPathComponent, byteCount: value.byteCount, contentHash: value.sha256, metadata: metadata))
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
#endif

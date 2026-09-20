// FloeExecution — Linux guest image verification, import and distribution.
//
// A guest image is the one artifact that can silently turn a Linux
// environment into a fake one, so this file answers three separate questions:
//
//  1. Does the image run?  Every artifact must be inside the image directory,
//     be a regular file (never a symlink), match the size and SHA-512 the
//     manifest records, and the manifest must name the qualification run that
//     produced those digests. A hand-written `qualified: true` without
//     digests is rejected.
//  2. May this build distribute/download it?  Only when the archive digest is
//     pinned by this build (LinuxGuestImageDistributionCatalog) *and* the
//     manifest carries provenance (guest source + license obligations).
//     The catalog pins a specific qualified image archive and its public
//     source/notice record; downloaded manifests cannot add catalog entries.
//  3. Import.  An already-downloaded zip archive or an extracted directory
//     can be imported; extraction rejects absolute paths, `..`, symlinks and
//     oversized payloads, and only a fully verified image is promoted into
//     `<root>/<id>`.
//
// Importing a locally built image is deliberately possible (it is how a
// qualification run lands on a device) but it is marked as a local import:
// it never becomes a downloadable Floe image by editing the manifest.

import Foundation
import FloeCore
import FloeTools
import ZIPFoundation

public enum LinuxGuestImageInstallError: Error, LocalizedError, Sendable, Equatable {
    case noDistributableImage(id: String, detail: String)
    case downloadFailed(String)
    case archiveTooLarge(limit: Int64)
    case archiveDigestMismatch(expected: String, actual: String)
    case unsupportedArchive(String)
    case unsafeArchiveEntry(String)
    case extractionLimitExceeded(String)
    case manifestMissing(String)
    case verificationFailed(String)
    case destinationExists(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .noDistributableImage(let id, let detail):
            return "no distributable Floe Linux image '\(id)': \(detail)"
        case .downloadFailed(let detail):
            return "image download failed: \(detail)"
        case .archiveTooLarge(let limit):
            return "image archive exceeds the \(limit) byte import limit"
        case .archiveDigestMismatch(let expected, let actual):
            return "image archive digest mismatch (expected \(expected.prefix(16))…, got \(actual.prefix(16))…)"
        case .unsupportedArchive(let detail):
            return "unsupported image archive: \(detail)"
        case .unsafeArchiveEntry(let path):
            return "image archive contains an unsafe entry: \(path)"
        case .extractionLimitExceeded(let detail):
            return "image archive exceeds extraction limits: \(detail)"
        case .manifestMissing(let path):
            return "image manifest is missing: \(path)"
        case .verificationFailed(let reason):
            return "image verification failed: \(reason)"
        case .destinationExists(let id):
            return "image '\(id)' is already installed; remove it before importing again"
        case .notFound(let id):
            return "image '\(id)' is not installed"
        }
    }
}

/// Limits for one import. Defaults are intentionally generous enough for a
/// Debian userland but bounded so a malformed archive cannot fill the device.
public struct LinuxGuestImageImportLimits: Sendable, Equatable {
    public var maxArchiveBytes: Int64
    public var maxExtractedBytes: Int64
    public var maxEntries: Int

    public init(
        maxArchiveBytes: Int64 = 2 * 1024 * 1024 * 1024,
        maxExtractedBytes: Int64 = 4 * 1024 * 1024 * 1024,
        maxEntries: Int = 128
    ) {
        self.maxArchiveBytes = maxArchiveBytes
        self.maxExtractedBytes = maxExtractedBytes
        self.maxEntries = maxEntries
    }

    public static let standard = LinuxGuestImageImportLimits()
}

/// Digest verification for one image directory. Hashing is the expensive part,
/// so a successful result is cached against the exact file identity (path,
/// size, modification time and the manifest's declared digest); touching any
/// artifact or digest forces a re-hash.
public actor LinuxGuestImageVerifier {
    private struct CacheEntry {
        var fingerprint: String
        var failure: String?
        var verifiedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]

    public init() {}

    /// Verification failure for a manifest in `imageDirectory`, or nil when
    /// the image is startable. Every artifact must resolve inside that
    /// directory.
    public func verificationFailure(image: LinuxGuestImage, imageDirectory: URL) -> String? {
        if let structural = image.qualificationFailure(imageDirectory: imageDirectory) { return structural }
        let fingerprint = Self.fingerprint(image: image, imageDirectory: imageDirectory)
        if let cached = cache[image.id], cached.fingerprint == fingerprint, cached.failure == nil {
            return nil
        }
        let failure = Self.verify(image: image, imageDirectory: imageDirectory)
        cache[image.id] = CacheEntry(fingerprint: fingerprint, failure: failure, verifiedAt: Date())
        return failure
    }
    public func invalidate(id: String) {
        cache[id] = nil
    }

    /// Cheap identity used to decide whether a previous digest check still
    /// describes these files.
    static func fingerprint(image: LinuxGuestImage, imageDirectory: URL) -> String {
        var parts = [image.id, image.qualificationRun ?? "-"]
        for declared in image.declaredArtifacts {
            let digest = image.artifactDigest(role: declared.role)
            parts.append(declared.role.rawValue)
            parts.append(declared.path)
            parts.append(digest?.sha512.lowercased() ?? "-")
            parts.append(String(digest?.bytes ?? -1))
            let url = image.artifactURL(declared.path, imageDirectory: imageDirectory)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            parts.append(String((attributes?[.size] as? NSNumber)?.int64Value ?? -1))
            parts.append(String((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1))
        }
        return FloeDigest.sha256Hex(Data(parts.joined(separator: "\u{1f}").utf8))
    }

    private static func verify(image: LinuxGuestImage, imageDirectory: URL) -> String? {
        let resolvedRoot = imageDirectory.resolvingSymlinksInPath().standardizedFileURL
        // The manifest itself must be a real file inside the image directory.
        let manifest = imageDirectory.appendingPathComponent("manifest.json")
        if let values = try? manifest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
           values.isRegularFile != true || values.isSymbolicLink == true {
            return "image manifest is not a regular file: \(manifest.path)"
        }
        for declared in image.declaredArtifacts {
            guard let digest = image.artifactDigest(role: declared.role) else {
                return "manifest has no \(declared.role.rawValue) digest"
            }
            let url = image.artifactURL(declared.path, imageDirectory: imageDirectory)
            if url.path.contains("\u{0}") { return "artifact path contains NUL" }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path == resolvedRoot.path || resolved.path.hasPrefix(resolvedRoot.path + "/") else {
                return "artifact escapes the image directory: \(declared.path)"
            }
            // Reject symlinks *inside* the image directory (an artifact link
            // could point at bytes that were never verified). Platform
            // ancestors are not ours to police: /var is a symlink on Apple
            // platforms while the app's own container lives below it.
            if url.path.hasPrefix(imageDirectory.path + "/") {
                let relative = String(url.path.dropFirst(imageDirectory.path.count + 1))
                var cursor = imageDirectory
                for component in relative.split(separator: "/") {
                    cursor.appendPathComponent(String(component))
                    if let values = try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]),
                       values.isSymbolicLink == true {
                        return "artifact path uses a symlink: \(cursor.path)"
                    }
                }
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                return "image artifact is missing: \(declared.path)"
            }
            let size = Int64(values.fileSize ?? -1)
            if size != digest.bytes {
                return "\(declared.role.rawValue) size mismatch (\(size) bytes on disk, manifest records \(digest.bytes))"
            }
            let actual: String
            do {
                actual = try FloeDigest.sha512Hex(ofFileAt: url)
            } catch {
                return "cannot hash \(declared.role.rawValue): \(error.localizedDescription)"
            }
            if actual.lowercased() != digest.sha512.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                return "\(declared.role.rawValue) SHA-512 mismatch; the image bytes do not match the qualification record"
            }
        }
        return nil
    }
}

/// One image this build is allowed to download. Pinned here (not in a
/// manifest the user can edit): the archive digest is the trust anchor, and
/// provenance names where the guest source and build configuration live.
/// Empty until a qualified image is produced and its distribution obligations
/// (guest userland licenses, matching source) are published.
public struct LinuxGuestTrustedImage: Sendable, Equatable {
    public var id: String
    public var archiveURL: URL
    public var archiveSHA512: String
    public var provenance: LinuxGuestImageProvenance

    public init(id: String, archiveURL: URL, archiveSHA512: String, provenance: LinuxGuestImageProvenance) {
        self.id = id
        self.archiveURL = archiveURL
        self.archiveSHA512 = archiveSHA512
        self.provenance = provenance
    }
}

public enum LinuxGuestImageDistributionCatalog {
    /// One fixed component release. Keep the App default and download entry aligned.
    public static let defaultImageID = "floe-debian13-riscv64-20260921.1"
    public static let bundled: [LinuxGuestTrustedImage] = [
        LinuxGuestTrustedImage(
            id: defaultImageID,
            archiveURL: URL(string: "https://github.com/JiangNanGenius/floe-agent/releases/download/floe-linux-guest-20260921.1/floe-linux-guest-floe-debian13-riscv64-20260921.1.zip")!,
            archiveSHA512: "060aba24fd6a013075b4decf5c741658dbfabb45c27f05e30bf100bae9b39aa6c319aba818150235f875fb6419500d7c32638934fe3a02a88bbd6caade83f295",
            provenance: LinuxGuestImageProvenance(
                sourceURL: "https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-linux-guest-20260921.1",
                buildConfigurationURL: "https://github.com/JiangNanGenius/floe-agent/tree/floe-linux-guest-20260921.1/FloeAgent/scripts/linux-guest-runner-update",
                license: "Floe runner MPL-2.0; guest userland under its own Debian package licenses; kernel GPL-2.0; bbl BSD-3-Clause; static glibc LGPL-2.1",
                distributionAllowed: true
            )
        )
    ]

    public static func entry(id: String) -> LinuxGuestTrustedImage? {
        bundled.first { $0.id == id }
    }
}

/// Bounded HTTPS download for one image archive. Implemented by the app with
/// URLSession; the package only needs this narrow seam so verification and
/// import stay testable without a network.
public protocol LinuxGuestImageDownloading: Sendable {
    func download(_ url: URL, to destination: URL, maxBytes: Int64) async throws
}

/// Install/remove/status for images under one artifact root.
public actor LinuxGuestImageInstallationService {
    public nonisolated let root: URL
    private let imagesRoot: URL
    private let limits: LinuxGuestImageImportLimits
    private let verifier: LinuxGuestImageVerifier

    public init(
        root: URL,
        limits: LinuxGuestImageImportLimits = .standard,
        verifier: LinuxGuestImageVerifier = LinuxGuestImageVerifier()
    ) {
        self.root = root
        self.imagesRoot = root.appendingPathComponent("LinuxGuest", isDirectory: true).appendingPathComponent("images", isDirectory: true)
        self.limits = limits
        self.verifier = verifier
    }

    public nonisolated var imagesDirectory: URL { imagesRoot }

    public struct ImageStatus: Sendable, Equatable {
        public var id: String
        public var installed: Bool
        public var verificationFailure: String?
        public var image: LinuxGuestImage?
        public var distributable: Bool

        public init(id: String, installed: Bool, verificationFailure: String?, image: LinuxGuestImage?, distributable: Bool) {
            self.id = id
            self.installed = installed
            self.verificationFailure = verificationFailure
            self.image = image
            self.distributable = distributable
        }
    }

    public func status(id: String) async -> ImageStatus {
        let image = loadManifest(id: id)
        var failure: String?
        if let image {
            failure = await verifier.verificationFailure(
                image: image,
                imageDirectory: imagesRoot.appendingPathComponent(id, isDirectory: true)
            )
        }
        let trusted = LinuxGuestImageDistributionCatalog.entry(id: id)
        return ImageStatus(
            id: id,
            installed: image != nil,
            verificationFailure: failure,
            image: image,
            distributable: trusted != nil
        )
    }

    /// Imports an already-downloaded zip archive. The expected SHA-512 must be
    /// supplied out of band (qualification record or pinned catalog); an empty
    /// digest is rejected.
    @discardableResult
    public func importArchive(
        at archiveURL: URL,
        expectedSHA512: String,
        fileManager: FileManager = .default
    ) async throws -> LinuxGuestImage {
        let expected = expectedSHA512.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard expected.count == 128, !expected.contains(where: { !$0.isHexDigit }) else {
            throw LinuxGuestImageInstallError.archiveDigestMismatch(expected: expectedSHA512, actual: "not a SHA-512 hex string")
        }
        let attributes = try fileManager.attributesOfItem(atPath: archiveURL.path)
        let archiveBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard archiveBytes > 0, archiveBytes <= limits.maxArchiveBytes else {
            throw LinuxGuestImageInstallError.archiveTooLarge(limit: limits.maxArchiveBytes)
        }
        let actual = try FloeDigest.sha512Hex(ofFileAt: archiveURL)
        guard actual == expected else {
            throw LinuxGuestImageInstallError.archiveDigestMismatch(expected: expected, actual: actual)
        }
        try fileManager.createDirectory(at: imagesRoot, withIntermediateDirectories: true)
        let staging = imagesRoot.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        switch archiveURL.pathExtension.lowercased() {
        case "zip":
            try extractZip(archiveURL, to: staging, fileManager: fileManager)
        default:
            throw LinuxGuestImageInstallError.unsupportedArchive(
                "\(archiveURL.lastPathComponent): import a zip archive or an extracted image directory"
            )
        }
        return try await promote(from: staging, fileManager: fileManager)
    }

    /// Imports an already-extracted directory that contains `manifest.json`
    /// (either at its root or under `<id>/manifest.json`).
    @discardableResult
    public func importDirectory(
        at sourceURL: URL,
        fileManager: FileManager = .default
    ) async throws -> LinuxGuestImage {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LinuxGuestImageInstallError.notFound(sourceURL.path)
        }
        let staging = imagesRoot.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: imagesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try copyDirectory(sourceURL, into: staging, fileManager: fileManager)
        return try await promote(from: staging, fileManager: fileManager)
    }

    /// Downloads a catalog-pinned image and imports it. This is the only path
    /// that can create a *distributable* image, and it refuses to run while
    /// the pinned catalog is empty.
    @discardableResult
    public func installTrustedImage(
        id: String,
        downloader: any LinuxGuestImageDownloading,
        fileManager: FileManager = .default
    ) async throws -> LinuxGuestImage {
        guard let trusted = LinuxGuestImageDistributionCatalog.entry(id: id) else {
            throw LinuxGuestImageInstallError.noDistributableImage(
                id: id,
                detail: "this build pins no distributable image archive; a runnable image must be built and verified locally, and distribution needs published guest source and license obligations"
            )
        }
        guard trusted.provenance.distributionAllowed,
              trusted.provenance.sourceURL?.isEmpty == false else {
            throw LinuxGuestImageInstallError.noDistributableImage(
                id: id,
                detail: "the pinned image records no published guest source/license provenance"
            )
        }
        guard trusted.archiveURL.scheme?.lowercased() == "https" else {
            throw LinuxGuestImageInstallError.noDistributableImage(id: id, detail: "the pinned archive URL is not HTTPS")
        }
        try fileManager.createDirectory(at: imagesRoot, withIntermediateDirectories: true)
        let stagingArchive = imagesRoot.appendingPathComponent(".download-\(UUID().uuidString).zip")
        defer { try? fileManager.removeItem(at: stagingArchive) }
        do {
            try await downloader.download(trusted.archiveURL, to: stagingArchive, maxBytes: limits.maxArchiveBytes)
        } catch {
            throw LinuxGuestImageInstallError.downloadFailed(error.localizedDescription)
        }
        return try await importArchive(at: stagingArchive, expectedSHA512: trusted.archiveSHA512, fileManager: fileManager)
    }

    public func removeImage(id: String, fileManager: FileManager = .default) async throws {
        let directory = imagesRoot.appendingPathComponent(id, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw LinuxGuestImageInstallError.notFound(id)
        }
        try fileManager.removeItem(at: directory)
        await verifier.invalidate(id: id)
    }

    // MARK: internals

    private func loadManifest(id: String) -> LinuxGuestImage? {
        let manifest = imagesRoot.appendingPathComponent(id, isDirectory: true).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest) else { return nil }
        return try? JSONDecoder().decode(LinuxGuestImage.self, from: data)
    }

    /// Validates the staged tree, verifies digests, then atomically moves the
    /// image directory into place. The previously installed image (if any) is
    /// only removed after the new one passed verification, so a failed import
    /// never destroys a working image.
    private func promote(from staging: URL, fileManager: FileManager) async throws -> LinuxGuestImage {
        let candidate: URL
        if fileManager.fileExists(atPath: staging.appendingPathComponent("manifest.json").path) {
            candidate = staging
        } else {
            let children = (try? fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            guard children.count == 1,
                  let child = children.first,
                  (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  fileManager.fileExists(atPath: child.appendingPathComponent("manifest.json").path) else {
                throw LinuxGuestImageInstallError.manifestMissing(staging.path)
            }
            candidate = child
        }
        let manifestURL = candidate.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let image = try? JSONDecoder().decode(LinuxGuestImage.self, from: data) else {
            throw LinuxGuestImageInstallError.manifestMissing(manifestURL.path)
        }
        // Reject symlinks anywhere in the staged image: an artifact symlink
        // could otherwise make the verified bytes differ from the booted ones.
        if let enumerator = fileManager.enumerator(at: candidate, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey], options: []) {
            var seen = 0
            while let file = enumerator.nextObject() as? URL {
                seen += 1
                if seen > limits.maxEntries {
                    throw LinuxGuestImageInstallError.extractionLimitExceeded("more than \(limits.maxEntries) entries")
                }
                if let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]),
                   values.isSymbolicLink == true {
                    throw LinuxGuestImageInstallError.unsafeArchiveEntry(file.lastPathComponent)
                }
            }
        }
        // The manifest paths must resolve inside the staged image directory;
        // the verifier hashes the actual bytes there, and promotion keeps the
        // same relative paths intact.
        if let failure = await verifier.verificationFailure(image: image, imageDirectory: candidate) {
            throw LinuxGuestImageInstallError.verificationFailed(failure)
        }

        let destination = imagesRoot.appendingPathComponent(image.id, isDirectory: true)
        let trash = imagesRoot.appendingPathComponent(".trash-\(UUID().uuidString)", isDirectory: true)
        let hadPrevious = fileManager.fileExists(atPath: destination.path)
        if hadPrevious { try fileManager.moveItem(at: destination, to: trash) }
        do {
            try fileManager.moveItem(at: candidate, to: destination)
        } catch {
            if hadPrevious { try? fileManager.moveItem(at: trash, to: destination) }
            throw error
        }
        if hadPrevious { try? fileManager.removeItem(at: trash) }
        await verifier.invalidate(id: image.id)
        FloeLogger(category: .tools).info("Linux guest image imported id=\(image.id) qualifiedRun=\(image.qualificationRun ?? "-")")
        return image
    }

    private func extractZip(_ archiveURL: URL, to staging: URL, fileManager: FileManager) throws {
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw LinuxGuestImageInstallError.unsupportedArchive("cannot open \(archiveURL.lastPathComponent): \(error.localizedDescription)")
        }
        let base = staging.resolvingSymlinksInPath().standardizedFileURL
        var entries = 0
        var extractedBytes: Int64 = 0
        for entry in archive {
            entries += 1
            guard entries <= limits.maxEntries else {
                throw LinuxGuestImageInstallError.extractionLimitExceeded("more than \(limits.maxEntries) entries")
            }
            guard let destination = Self.safeEntryURL(entry.path, under: base) else {
                throw LinuxGuestImageInstallError.unsafeArchiveEntry(entry.path)
            }
            switch entry.type {
            case .directory:
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            case .file:
                extractedBytes += Int64(entry.uncompressedSize)
                guard extractedBytes <= limits.maxExtractedBytes else {
                    throw LinuxGuestImageInstallError.extractionLimitExceeded("more than \(limits.maxExtractedBytes) bytes")
                }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) {
                    throw LinuxGuestImageInstallError.unsafeArchiveEntry("duplicate entry \(entry.path)")
                }
                _ = try archive.extract(entry, to: destination)
            case .symlink:
                throw LinuxGuestImageInstallError.unsafeArchiveEntry("symlink \(entry.path)")
            }
        }
    }

    /// Copy a directory tree without following symlinks (import of an
    /// already-extracted image). Hidden files are copied too: archives may
    /// contain them, and skipping silently would corrupt the image.
    private func copyDirectory(_ source: URL, into staging: URL, fileManager: FileManager) throws {
        let base = staging.resolvingSymlinksInPath().standardizedFileURL
        var copiedBytes: Int64 = 0
        var entries = 0
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            options: [],
            errorHandler: nil
        ) else {
            throw LinuxGuestImageInstallError.notFound(source.path)
        }
        for case let file as URL in enumerator {
            entries += 1
            guard entries <= limits.maxEntries else {
                throw LinuxGuestImageInstallError.extractionLimitExceeded("more than \(limits.maxEntries) entries")
            }
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                throw LinuxGuestImageInstallError.unsafeArchiveEntry(file.lastPathComponent)
            }
            let relative = file.path.hasPrefix(source.path + "/") ? String(file.path.dropFirst(source.path.count + 1)) : file.lastPathComponent
            let destination = base.appendingPathComponent(relative)
            if values.isDirectory == true {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            guard values.isRegularFile == true else { continue }
            copiedBytes += Int64(values.fileSize ?? 0)
            guard copiedBytes <= limits.maxExtractedBytes else {
                throw LinuxGuestImageInstallError.extractionLimitExceeded("more than \(limits.maxExtractedBytes) bytes")
            }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                throw LinuxGuestImageInstallError.unsafeArchiveEntry("duplicate entry \(relative)")
            }
            try fileManager.copyItem(at: file, to: destination)
        }
    }

    /// Resolves an archive entry path under `base`, rejecting absolute paths,
    /// `..`, empty names and NUL. Returns nil when the entry is unsafe.
    static func safeEntryURL(_ path: String, under base: URL) -> URL? {
        guard !path.isEmpty, !path.contains("\u{0}"), !path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else { return nil }
        guard !components.contains(where: { $0.isEmpty }) else { return nil }
        let candidate = base.appendingPathComponent(path).standardizedFileURL
        guard candidate.path == base.path || candidate.path.hasPrefix(base.path + "/") else { return nil }
        return candidate
    }
}

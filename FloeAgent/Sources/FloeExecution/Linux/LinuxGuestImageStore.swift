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
    /// Not enough free space on the destination volume.
    case insufficientSpace(required: Int64, available: Int64)
    /// Download or import was cancelled before completion.
    case cancelled

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
        case .insufficientSpace(let required, let available):
            return "not enough free space for the Linux image (\(required) bytes required, \(available) available)"
        case .cancelled:
            return "Linux image download was cancelled"
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

/// Reads real free-space capacity and enforces it before writing, so a
/// download or extraction never fills the device and then reports a generic
/// I/O error.
enum LinuxGuestVolumeSpace {
    /// One import of the catalog-pinned sparse image writes the archive plus
    /// its small members up front; the big disk member is written sparsely
    /// and grows only with its non-zero content, so the honest pre-write
    /// estimate is the archive plus working headroom, not the logical size.
    static let extractionHeadroomBytes: Int64 = 128 * 1024 * 1024

    static func availableImportantBytes(for url: URL) -> Int64 {
        if let capacity = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let value = capacity.volumeAvailableCapacityForImportantUsage, value > 0 {
            return value
        }
        if let capacity = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let value = capacity.volumeAvailableCapacity {
            return Int64(value)
        }
        return -1
    }

    static func requireAvailable(at url: URL, required: Int64) throws {
        let available = availableImportantBytes(for: url)
        guard available >= 0 else { return }
        if available < required {
            throw LinuxGuestImageInstallError.insufficientSpace(required: required, available: available)
        }
    }

    /// Maps a Foundation/Cocoa out-of-space error. Used to wrap extraction
    /// and promotion errors when the pre-check could not predict the need.
    static func outOfSpaceError(_ error: Error, required: Int64) -> LinuxGuestImageInstallError? {
        let ns = error as NSError
        let isOutOfSpace = (ns.domain == NSCocoaErrorDomain && ns.code == 640 /* NSFileWriteOutOfSpaceErrorCode */)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == 28 /* ENOSPC */)
        guard isOutOfSpace else {
            return nil
        }
        let available = availableImportantBytes(
            for: (ns.userInfo[NSFilePathErrorKey] as? String).map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: NSHomeDirectory())
        )
        return .insufficientSpace(required: required, available: max(0, available))
    }
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

/// Bounded failure raised while *transporting* an archive. The cases are the
/// only place that decides whether another source may be tried: a connectivity
/// or server-availability failure can fall through to the next mirror, while
/// anything that could describe content (or local conditions that a mirror
/// cannot change) fails closed and never touches another source.
public enum LinuxGuestImageTransferError: Error, LocalizedError, Sendable, Equatable {
    /// The source could not be reached or the connection broke (DNS, connect,
    /// timeout, connection lost). The only failure class that allows fallback.
    case networkFailure(detail: String)
    /// The source answered, but is temporarily unable to serve the pinned
    /// asset (HTTP 5xx, 408 or 429). Also allows a fallback.
    case serverUnavailable(status: Int?, detail: String)
    /// A definite HTTP answer that is not the pinned asset (4xx other than
    /// 408/429). Retrying another host cannot turn a pinned 404 into the
    /// asset, so it fails closed.
    case responseRejected(status: Int, detail: String)
    /// The payload is not the one described by the catalog (non-HTTP, empty
    /// body, wrong framing). Fails closed.
    case responseInvalid(detail: String)
    /// The local device rejected the transfer before or while writing (size
    /// cap or free space). A mirror cannot change local conditions.
    case localRejection(detail: String)
    /// Transfer was cancelled by the caller; never falls back.
    case cancelled

    /// Only a bounded primary-source *availability* failure may activate the
    /// next mirror. Digest/archive errors never reach this classification,
    /// and local, definite-answer and content-shaped failures stay closed.
    public var allowsNextSource: Bool {
        switch self {
        case .networkFailure, .serverUnavailable:
            return true
        case .responseRejected, .responseInvalid, .localRejection, .cancelled:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .networkFailure(let detail):
            return "network failure reaching the image source: \(detail)"
        case .serverUnavailable(let status, let detail):
            return "image source unavailable (HTTP \(status.map(String.init) ?? "?"): \(detail))"
        case .responseRejected(let status, let detail):
            return "image source refused the pinned archive (HTTP \(status): \(detail))"
        case .responseInvalid(let detail):
            return "image source returned an invalid response: \(detail)"
        case .localRejection(let detail):
            return "the device rejected the image transfer: \(detail)"
        case .cancelled:
            return "image transfer cancelled"
        }
    }
}

/// One verified piece of a sharded mirror archive. Mirrors such as Gitee cap
/// individual attachments (100 MB on Gitee), so an archive larger than the cap
/// is published as fixed-size pieces; the manifest pins every piece's size and
/// SHA-512, exactly the same trust model as the archive itself.
public struct LinuxGuestImageShard: Sendable, Codable, Equatable {
    public var index: Int
    /// Asset path relative to the shard manifest URL's directory.
    public var name: String
    public var bytes: Int
    public var sha512: String

    public init(index: Int, name: String, bytes: Int, sha512: String) {
        self.index = index
        self.name = name
        self.bytes = bytes
        self.sha512 = sha512
    }
}

/// Manifest published beside a sharded mirror archive. It cannot add an image:
/// the install path re-verifies that `archiveSHA512` is the pinned digest and
/// only then downloads the listed, contiguously indexed pieces.
public struct LinuxGuestImageShardManifest: Sendable, Codable, Equatable {
    public static let currentSchema = "floe-image-shard-manifest/v1"
    public static let assetName = "shard-manifest.json"

    public var schema: String
    public var imageID: String
    public var archive: String
    public var archiveBytes: Int
    public var archiveSHA512: String
    public var shards: [LinuxGuestImageShard]

    public init(
        schema: String = currentSchema,
        imageID: String,
        archive: String,
        archiveBytes: Int,
        archiveSHA512: String,
        shards: [LinuxGuestImageShard]
    ) {
        self.schema = schema
        self.imageID = imageID
        self.archive = archive
        self.archiveBytes = archiveBytes
        self.archiveSHA512 = archiveSHA512
        self.shards = shards
    }

    /// Failure unless the manifest describes the exact pinned archive and a
    /// complete, ordered, well-formed shard set.
    public func validationFailure(imageID expectedImageID: String, archiveSHA512 expectedSHA512: String) -> String? {
        guard schema == Self.currentSchema else { return "shard manifest has unknown schema \(schema)" }
        guard imageID == expectedImageID else { return "shard manifest is for a different image \(imageID)" }
        guard archiveSHA512.lowercased() == expectedSHA512.lowercased() else {
            return "shard manifest does not pin the trusted archive digest"
        }
        guard archiveBytes > 0, !shards.isEmpty else { return "shard manifest lists no pieces" }
        guard shards.map(\.index) == Array(0..<shards.count) else {
            return "shard manifest pieces are not contiguous from index 0"
        }
        let totalBytes = shards.reduce(0) { $0 + $1.bytes }
        guard totalBytes == archiveBytes else {
            return "shard piece sizes (\(totalBytes)) do not sum to the archive size (\(archiveBytes))"
        }
        for shard in shards {
            guard shard.bytes > 0, !shard.name.isEmpty, !shard.name.hasPrefix("/"),
                  !shard.name.contains(".."),
                  shard.sha512.count == 128,
                  !shard.sha512.contains(where: { !$0.isHexDigit }) else {
                return "shard #\(shard.index) is malformed"
            }
        }
        return nil
    }
}

/// One public mirror of the pinned archive. `archiveURL` is the direct asset
/// (used when present and within limits) and `shardManifestURL` provides the
/// verified piece set used to reconstruct the exact same bytes.
public struct LinuxGuestImageMirror: Sendable, Equatable {
    public var archiveURL: URL
    public var shardManifestURL: URL

    public init(archiveURL: URL, shardManifestURL: URL) {
        self.archiveURL = archiveURL
        self.shardManifestURL = shardManifestURL
    }
}

/// One image this build is allowed to download. Pinned here (not in a
/// manifest the user can edit): the archive digest is the trust anchor, and
/// provenance names where the guest source and build configuration live.
/// `archiveURL` is the trust-bearing primary source and `mirrors` are ordered
/// public mirrors (e.g. Gitee) that are contacted *only* after a bounded
/// availability failure of every earlier source. Every source serves the
/// exact same bytes: they all verify against one shared `archiveSHA512`.
public struct LinuxGuestTrustedImage: Sendable, Equatable {
    public var id: String
    /// Trust-bearing primary archive URL (GitHub Releases).
    public var archiveURL: URL
    /// Ordered fallback mirrors, tried after the primary fails with a bounded
    /// network/server-availability error.
    public var mirrors: [LinuxGuestImageMirror]
    public var archiveSHA512: String
    public var provenance: LinuxGuestImageProvenance

    public init(
        id: String,
        archiveURL: URL,
        mirrors: [LinuxGuestImageMirror] = [],
        archiveSHA512: String,
        provenance: LinuxGuestImageProvenance
    ) {
        self.id = id
        self.archiveURL = archiveURL
        self.mirrors = mirrors
        self.archiveSHA512 = archiveSHA512
        self.provenance = provenance
    }
}

public enum LinuxGuestImageDistributionCatalog {
    /// One fixed component release. Keep the App default and download entry aligned.
    ///
    /// The default is the verified SMP image (CONFIG_SMP=y / NR_CPUS=2 kernel
    /// plus fresh raw bbl, qualified by component-image-ci run 36330566148 and
    /// distributed as published component release `floe-linux-guest-smp-20260928.1`
    /// with complete corresponding source). The previous single-hart image
    /// stays listed: environments already cloned from it keep their pinned
    /// base until their normal install/preparation flow downloads a new image
    /// — a catalog change never rebases or overwrites an existing disk.
    public static let defaultImageID = "floe-debian13-riscv64-202609202607-basic-r572a77382feb-b36330566148-1"
    public static let bundled: [LinuxGuestTrustedImage] = [
        LinuxGuestTrustedImage(
            id: defaultImageID,
            archiveURL: URL(string: "https://github.com/JiangNanGenius/floe-agent/releases/download/floe-linux-guest-smp-20260928.1/floe-linux-guest-floe-debian13-riscv64-202609202607-basic-r572a77382feb-b36330566148-1.zip")!,
            // The SMP image has no Gitee mirror asset yet; the GitHub release
            // is the only verified source, so no mirror URLs are invented here.
            mirrors: [],
            archiveSHA512: "4f19064f764ed400194a830b38af57236c5cd3145f463f2352834c0c834c90f7d4c6df078cd7d831acf42b6620de09d758c62dc3dbed90694f5ea63ff21d84a8",
            provenance: LinuxGuestImageProvenance(
                sourceURL: "https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-linux-guest-smp-20260928.1",
                buildConfigurationURL: "https://github.com/JiangNanGenius/floe-agent/tree/0ed79ce8d4fe3fe7fef545275e0a0f22ae9d53e4/FloeAgent/ThirdParty/TinyEMU/guest-image",
                license: "Floe runner MPL-2.0; guest userland under its own Debian package licenses; kernel GPL-2.0 (CONFIG_SMP=y); bbl BSD-3-Clause; static glibc LGPL-2.1",
                distributionAllowed: true
            )
        ),
        LinuxGuestTrustedImage(
            id: "floe-debian13-riscv64-20260922.2",
            archiveURL: URL(string: "https://github.com/JiangNanGenius/floe-agent/releases/download/floe-linux-guest-20260922.2/floe-linux-guest-floe-debian13-riscv64-20260922.2.zip")!,
            mirrors: [
                // Public Gitee China mirror. Byte-identical asset; the
                // reconstructed archive is verified against the same pinned
                // SHA-512 before import. Contacted only after the primary
                // fails with a bounded availability error.
                LinuxGuestImageMirror(
                    archiveURL: URL(string: "https://gitee.com/JiangNanGenius/floe-agent/releases/download/floe-linux-guest-20260922.2/floe-linux-guest-floe-debian13-riscv64-20260922.2.zip")!,
                    shardManifestURL: URL(string: "https://gitee.com/JiangNanGenius/floe-agent/releases/download/floe-linux-guest-20260922.2/shard-manifest.json")!
                )
            ],
            archiveSHA512: "bde2b2198bf5f70411b12587b9e6b4b42a183671b5564b90319eae7bbd2ae7eb09f686e0d4009096eba0da3b75a89c65bc7c45ac31ac61146482377fc0bdae04",
            provenance: LinuxGuestImageProvenance(
                sourceURL: "https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-linux-guest-20260922.2",
                buildConfigurationURL: "https://github.com/JiangNanGenius/floe-agent/tree/ba739b71f902507da2382d52ba6393eb6cba5afb/FloeAgent/scripts/linux-guest-runner-update",
                license: "Floe runner MPL-2.0; guest userland under its own Debian package licenses; kernel GPL-2.0; bbl BSD-3-Clause; static glibc LGPL-2.1",
                distributionAllowed: true
            )
        )
    ]

    public static func entry(id: String) -> LinuxGuestTrustedImage? {
        if let bundled = bundled.first(where: { $0.id == id }) {
            return bundled
        }
        // The mutable test registry exists only in debug/test builds; release
        // builds read the compile-time `bundled` pins alone.
        #if DEBUG
        return testEntry(id: id)
        #else
        return nil
        #endif
    }

    // MARK: - Test-only pinned entries
    //
    // Unit tests cannot add compile-time pins; they register throwaway
    // fixtures here instead. The trust shape is identical to `bundled`
    // (an id plus its pinned archive SHA-512 and published provenance), the
    // registry is internal so only `@testable` tests can write it, and the
    // `#if DEBUG` gate keeps it (and the `entry(id:)` fallback) out of
    // release binaries entirely.

    #if DEBUG
    private static let testEntriesLock = NSLock()
    // Guarded by testEntriesLock for every read/write (see the accessors).
    nonisolated(unsafe) private static var testEntries: [String: LinuxGuestTrustedImage] = [:]

    static func registerTestEntry(_ entry: LinuxGuestTrustedImage) {
        testEntriesLock.lock()
        testEntries[entry.id] = entry
        testEntriesLock.unlock()
    }

    static func clearTestEntries() {
        testEntriesLock.lock()
        testEntries.removeAll()
        testEntriesLock.unlock()
    }

    private static func testEntry(id: String) -> LinuxGuestTrustedImage? {
        testEntriesLock.lock()
        defer { testEntriesLock.unlock() }
        return testEntries[id]
    }
    #endif
}

/// Bounded HTTPS fetch for one image archive or a shard manifest. Implemented
/// by the app with URLSession; the package only needs this narrow seam so
/// verification and import stay testable without a network.
///
/// Failures are the typed transfer classification: the package coordinator
/// uses `allowsNextSource` as the *only* switch to a mirror. Digest and
/// archive errors are never thrown here for downloaded bytes (they are checked
/// after the transfer and fail closed), and anything unclassified fails
/// closed as well.
public protocol LinuxGuestImageDownloading: Sendable {
    /// Downloads one bounded asset. `onProgress` reports received bytes and
    /// the expected total (-1 when the server sends no Content-Length). Used
    /// for the primary archive, a mirror's shard manifest and every shard;
    /// per-piece retries, piece verification, stable resume and assembly all
    /// live in the package (`LinuxGuestImageShardFetch`).
    func download(
        _ url: URL,
        to destination: URL,
        maxBytes: Int64,
        onProgress: @escaping @Sendable (_ received: Int64, _ expected: Int64) -> Void
    ) async throws(LinuxGuestImageTransferError)
}

/// Install/remove/status for images under one artifact root.
public actor LinuxGuestImageInstallationService {
    public nonisolated let root: URL
    private let imagesRoot: URL
    private let limits: LinuxGuestImageImportLimits
    private let verifier: LinuxGuestImageVerifier
    /// In-flight trusted installs keyed by image id. Two callers that ask
    /// for the same image while a download is running share one download:
    /// the model tool, shell auto-preparation and the UI can never start
    /// duplicate transfers of the same archive.
    private var installsInFlight: [String: Task<LinuxGuestImage, Error>] = [:]

    /// The largest extraction budget any import may declare. A catalog-pinned
    /// image whose manifest is bound by the pinned archive SHA-512 may raise
    /// its budget up to this ceiling (the 16 GiB logical disk stays far below
    /// it on disk thanks to sparse writes); unknown archives keep the much
    /// smaller `LinuxGuestImageImportLimits.standard` default.
    static let maxDeclaredExtractedBytes: Int64 = 24 * 1024 * 1024 * 1024
    /// Entries at or above this uncompressed size are written sparsely: runs
    /// of zero bytes never touch the disk, which keeps a mostly-empty guest
    /// disk from consuming real blocks during import.
    static let sparseEntryThresholdBytes: Int64 = 64 * 1024 * 1024

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
    ///
    /// Unknown archives extract under the bounded `limits` (4 GiB logical
    /// payload by default). A caller that has already bound the archive bytes
    /// to a pinned manifest — the catalog install path — passes
    /// `expectedImageID`: the manifest is read from inside the digest-verified
    /// archive, its declared artifact total becomes the extraction budget
    /// (capped by `maxDeclaredExtractedBytes`), and its id must match. Sparse
    /// writing keeps a large declared disk from consuming real blocks.
    @discardableResult
    public func importArchive(
        at archiveURL: URL,
        expectedSHA512: String,
        expectedImageID: String? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil,
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
        // The archive bytes are pinned now. Raising the extraction budget
        // beyond the standard unknown-archive limit is a *catalog-trusted*
        // operation, not something any caller gets by naming an id: the id
        // must be a catalog entry and its pinned digest must equal the digest
        // this archive just verified against.
        var extractionBudget = limits.maxExtractedBytes
        if let expectedImageID {
            guard let trusted = LinuxGuestImageDistributionCatalog.entry(id: expectedImageID),
                  trusted.archiveSHA512.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expected else {
                throw LinuxGuestImageInstallError.noDistributableImage(
                    id: expectedImageID,
                    detail: "raising the extraction budget requires the id and archive SHA-512 pinned by this build's catalog"
                )
            }
            let declared = try declaredArtifactBytes(in: archiveURL, expectedID: expectedImageID)
            let (budget, overflow) = declared.addingReportingOverflow(LinuxGuestVolumeSpace.extractionHeadroomBytes)
            guard !overflow, budget > 0, budget <= Self.maxDeclaredExtractedBytes else {
                throw LinuxGuestImageInstallError.extractionLimitExceeded(
                    "declared image payload of \(declared) bytes exceeds the \(Self.maxDeclaredExtractedBytes) byte ceiling"
                )
            }
            extractionBudget = budget
        }
        try fileManager.createDirectory(at: imagesRoot, withIntermediateDirectories: true)
        // Working-set estimate: the archive itself (removed after import) plus
        // the small members; the sparse disk member grows with real content,
        // and a mid-write volume failure is reported as insufficient space.
        let requiredForExtraction = expectedImageID == nil
            ? archiveBytes * 2 + 32 * 1024 * 1024
            : archiveBytes + LinuxGuestVolumeSpace.extractionHeadroomBytes
        try LinuxGuestVolumeSpace.requireAvailable(at: imagesRoot, required: requiredForExtraction)
        let staging = imagesRoot.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            switch archiveURL.pathExtension.lowercased() {
            case "zip":
                try extractZip(archiveURL, to: staging, fileManager: fileManager,
                               extractionBudget: extractionBudget, isCancelled: isCancelled)
            default:
                throw LinuxGuestImageInstallError.unsupportedArchive(
                    "\(archiveURL.lastPathComponent): import a zip archive or an extracted image directory"
                )
            }
            return try await promote(from: staging, fileManager: fileManager)
        } catch let installError as LinuxGuestImageInstallError {
            throw installError
        } catch {
            if let spaceError = LinuxGuestVolumeSpace.outOfSpaceError(error, required: requiredForExtraction) {
                throw spaceError
            }
            throw error
        }
    }

    /// Reads `manifest.json` from inside a zip archive and returns the total
    /// bytes its artifacts declare. The archive must already be digest-verified
    /// by the caller; the id must match `expectedID` and the manifest must be
    /// qualified with a bound artifact list. The manifest member itself is
    /// bounded so a hostile archive cannot stream an unbounded prefix before
    /// the budget check ever runs.
    private func declaredArtifactBytes(in archiveURL: URL, expectedID: String) throws -> Int64 {
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw LinuxGuestImageInstallError.unsupportedArchive("cannot open \(archiveURL.lastPathComponent): \(error.localizedDescription)")
        }
        guard let entry = archive["manifest.json"] else {
            throw LinuxGuestImageInstallError.manifestMissing("manifest.json in \(archiveURL.lastPathComponent)")
        }
        // A Floe image manifest is a few KiB; anything larger is not one.
        // Compare in UInt64 first: an Int64 conversion of a malformed ZIP64
        // size would trap before the limit check ever ran.
        let manifestLimit: Int64 = 4 * 1024 * 1024
        guard entry.type == .file, entry.uncompressedSize <= UInt64(manifestLimit) else {
            throw LinuxGuestImageInstallError.manifestMissing("manifest.json exceeds the \(manifestLimit) byte manifest limit")
        }
        var data = Data()
        do {
            let crc = try archive.extract(entry, bufferSize: 1024 * 1024, skipCRC32: false, progress: nil) { chunk in
                data.append(chunk)
                guard data.count <= manifestLimit else {
                    // The reader only stops on Progress cancellation; flag it.
                    throw LinuxGuestImageInstallError.manifestMissing("manifest.json exceeds the \(manifestLimit) byte manifest limit")
                }
            }
            guard crc == entry.checksum else {
                throw LinuxGuestImageInstallError.manifestMissing("manifest.json failed its CRC-32 check")
            }
        } catch let installError as LinuxGuestImageInstallError {
            throw installError
        } catch {
            throw LinuxGuestImageInstallError.manifestMissing("cannot read manifest.json: \(error.localizedDescription)")
        }
        guard let image = try? JSONDecoder().decode(LinuxGuestImage.self, from: data) else {
            throw LinuxGuestImageInstallError.manifestMissing("manifest.json is not a Floe Linux image manifest")
        }
        guard image.id == expectedID else {
            throw LinuxGuestImageInstallError.verificationFailed(
                "archive manifest id \(image.id) does not match the pinned image \(expectedID)"
            )
        }
        guard image.qualified, let artifacts = image.artifacts, !artifacts.isEmpty else {
            throw LinuxGuestImageInstallError.verificationFailed("archive manifest declares no qualified bound artifacts")
        }
        var total: Int64 = 0
        for artifact in artifacts {
            // Every declared artifact must be positive; overflow fails closed.
            let (sum, overflow) = total.addingReportingOverflow(artifact.bytes)
            guard artifact.bytes > 0, !overflow else {
                throw LinuxGuestImageInstallError.verificationFailed("archive manifest declares an invalid artifact size")
            }
            total = sum
        }
        return total
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
        onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in },
        fileManager: FileManager = .default
    ) async throws -> LinuxGuestImage {
        // Already present and verified: never start a second download.
        let current = await status(id: id)
        if current.installed && current.verificationFailure == nil, let image = current.image {
            return image
        }
        // A second request while a download is running shares the in-flight
        // install instead of fetching the archive again. Its own progress
        // callback stays silent; the originating call reports progress.
        if let inFlight = installsInFlight[id] {
            return try await inFlight.value
        }
        let task = Task<LinuxGuestImage, Error> {
            try await performTrustedInstall(
                id: id,
                downloader: downloader,
                onProgress: onProgress,
                fileManager: fileManager
            )
        }
        installsInFlight[id] = task
        defer { installsInFlight[id] = nil }
        return try await task.value
    }

    private func performTrustedInstall(
        id: String,
        downloader: any LinuxGuestImageDownloading,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void,
        fileManager: FileManager
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
        try fileManager.createDirectory(at: imagesRoot, withIntermediateDirectories: true)
        let stagingArchive = imagesRoot.appendingPathComponent(".download-\(UUID().uuidString).zip")
        defer { try? fileManager.removeItem(at: stagingArchive) }
        try await LinuxGuestImageSourceFetch.fetch(
            image: trusted,
            to: stagingArchive,
            maxBytes: limits.maxArchiveBytes,
            downloader: downloader,
            onProgress: onProgress
        )
        return try await importArchive(
            at: stagingArchive,
            expectedSHA512: trusted.archiveSHA512,
            expectedImageID: trusted.id,
            isCancelled: { Task.isCancelled },
            fileManager: fileManager
        )
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

    private func extractZip(
        _ archiveURL: URL,
        to staging: URL,
        fileManager: FileManager,
        extractionBudget: Int64,
        isCancelled: (@Sendable () -> Bool)?
    ) throws {
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
            if isCancelled?() == true {
                throw LinuxGuestImageInstallError.cancelled
            }
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
                // A malformed ZIP64 size must fail the limit check, not trap
                // on an Int64 conversion; the running total reports overflow
                // instead of wrapping past the budget.
                guard entry.uncompressedSize <= UInt64(Int64.max) else {
                    throw LinuxGuestImageInstallError.extractionLimitExceeded(
                        "archive entry \(entry.path) declares an invalid size"
                    )
                }
                let entrySize = Int64(entry.uncompressedSize)
                let (newTotal, overflow) = extractedBytes.addingReportingOverflow(entrySize)
                guard !overflow, newTotal <= extractionBudget else {
                    throw LinuxGuestImageInstallError.extractionLimitExceeded(
                        "archive declares more than \(extractionBudget) extracted bytes"
                    )
                }
                extractedBytes = newTotal
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) {
                    throw LinuxGuestImageInstallError.unsafeArchiveEntry("duplicate entry \(entry.path)")
                }
                if Int64(entry.uncompressedSize) >= Self.sparseEntryThresholdBytes {
                    try extractSparse(entry, from: archive, to: destination, fileManager: fileManager, isCancelled: isCancelled)
                } else {
                    _ = try archive.extract(entry, to: destination)
                }
            case .symlink:
                throw LinuxGuestImageInstallError.unsafeArchiveEntry("symlink \(entry.path)")
            }
        }
    }

    /// Streams one large file entry to disk, skipping runs of zero bytes so
    /// the extracted file is sparse: the logical length always equals the
    /// entry's uncompressed size, but blocks that are all zeros consume no
    /// real capacity. The reader's returned CRC-32 is compared against the
    /// entry's recorded checksum (the consumer variant does not do that
    /// itself), and cooperative cancellation aborts the write. All file
    /// operations use the throwing Swift APIs so a full volume surfaces as a
    /// mapped `insufficientSpace` error instead of an Objective-C exception.
    private func extractSparse(
        _ entry: Entry,
        from archive: Archive,
        to destination: URL,
        fileManager: FileManager,
        isCancelled: (@Sendable () -> Bool)?
    ) throws {
        guard fileManager.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination) else {
            throw LinuxGuestImageInstallError.verificationFailed("cannot create \(destination.lastPathComponent) for sparse writing")
        }
        defer { try? handle.close() }
        let progress = Progress(totalUnitCount: Int64(entry.uncompressedSize))
        var logicalOffset: UInt64 = 0
        do {
            let crc = try archive.extract(entry, bufferSize: 4 * 1024 * 1024, skipCRC32: false, progress: progress) { chunk in
                if isCancelled?() == true {
                    progress.cancel()
                    return
                }
                if chunk.isEmpty { return }
                if chunk.contains(where: { $0 != 0 }) {
                    let fileOffset = try handle.offset()
                    if fileOffset != logicalOffset {
                        try handle.seek(toOffset: logicalOffset)
                    }
                    try handle.write(contentsOf: chunk)
                }
                logicalOffset += UInt64(chunk.count)
            }
            guard crc == entry.checksum else {
                throw LinuxGuestImageInstallError.verificationFailed("sparse entry \(entry.path) failed its CRC-32 check")
            }
        } catch {
            if let archiveError = error as? Archive.ArchiveError, case .cancelledOperation = archiveError {
                throw LinuxGuestImageInstallError.cancelled
            }
            if let space = LinuxGuestVolumeSpace.outOfSpaceError(error, required: Int64(entry.uncompressedSize)) {
                throw space
            }
            throw error
        }
        guard logicalOffset == entry.uncompressedSize else {
            throw LinuxGuestImageInstallError.verificationFailed(
                "sparse entry \(entry.path) wrote \(logicalOffset) of \(entry.uncompressedSize) bytes"
            )
        }
        // A tail of zeros (or an all-zero member) never had blocks written;
        // extend the file to its logical length, which stays a hole.
        let fileOffset = try handle.offset()
        if fileOffset < entry.uncompressedSize {
            try handle.truncate(atOffset: entry.uncompressedSize)
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

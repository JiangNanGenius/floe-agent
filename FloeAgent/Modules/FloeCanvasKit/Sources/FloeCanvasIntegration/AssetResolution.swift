import Foundation
import Darwin
import FloeCanvasCore

/// Foundation-only cancellation for hosts that do not use Swift
/// concurrency. Explicitly thread it through every bounded resource call;
/// implementations must check it before and after I/O and throw
/// `CanvasKitError.cancelled` without partial effects.
public final class CanvasCancellationToken: Sendable {
    // NSLock-synchronized flag; unchecked Sendable because the lock guards
    // the only mutable state (Foundation-only, no actor needed).
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var cancelled = false
    }
    private let state = State()

    public init() {}

    public func cancel() {
        state.lock.lock()
        state.cancelled = true
        state.lock.unlock()
    }

    public var isCancelled: Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.cancelled
    }

    func throwIfCancelled() throws {
        if isCancelled { throw CanvasKitError.cancelled }
    }
}

// MARK: - Bounded asset resolution (qualification primitive)

public struct CanvasAssetResolveOptions: Sendable, Hashable {
    /// Maximum file size accepted; larger files are refused (never
    /// truncated) so a video/PDF can never be pulled into memory whole.
    public var maxByteCount: Int64
    /// Resolve symlinks and re-verify containment of the resolved path.
    public var followSymlinks: Bool

    public init(
        maxByteCount: Int64 = 64 * 1024 * 1024,
        followSymlinks: Bool = true
    ) {
        self.maxByteCount = maxByteCount
        self.followSymlinks = followSymlinks
    }
}

public struct CanvasResolvedAsset: Hashable, Sendable {
    public var locator: CanvasAssetLocator
    /// Bounded bytes (≤ options.maxByteCount).
    public var data: Data
    /// Actual on-disk size.
    public var fileByteCount: Int64
    public var mimeType: String?
    public var resolvedURL: URL

    public init(
        locator: CanvasAssetLocator,
        data: Data,
        fileByteCount: Int64,
        mimeType: String?,
        resolvedURL: URL
    ) {
        self.locator = locator
        self.data = data
        self.fileByteCount = fileByteCount
        self.mimeType = mimeType
        self.resolvedURL = resolvedURL
    }
}

/// Byte-resolution boundary. UI/Exchange consume bounded results here
/// instead of ever requiring a full video/PDF `Data`.
public protocol CanvasAssetResolving: Sendable {
    func resolve(
        _ locator: CanvasAssetLocator,
        options: CanvasAssetResolveOptions,
        cancellation token: CanvasCancellationToken?
    ) async throws -> CanvasResolvedAsset
}

/// Qualification file-asset resolver against an explicit root: every
/// resolution is containment-checked (path traversal refused), symlink
/// re-checked, size-capped and cancellation-aware.
public actor FileCanvasAssetResolver: CanvasAssetResolving {
    public let root: URL
    private let physicalRootPath: String

    public init(root: URL) throws {
        guard root.isFileURL else {
            throw CanvasKitError.repositoryRootViolation("asset root must be a file URL")
        }
        let physical = try Self.physicalPath(root.path)
        guard physical.split(separator: "/").count > 1 else {
            throw CanvasKitError.repositoryRootViolation(
                "root too broad: \(root.path)")
        }
        self.physicalRootPath = physical
        self.root = URL(fileURLWithPath: physical, isDirectory: true)
    }

    public func resolve(
        _ locator: CanvasAssetLocator,
        options: CanvasAssetResolveOptions,
        cancellation token: CanvasCancellationToken?
    ) async throws -> CanvasResolvedAsset {
        try Task.checkCancellation()
        try token?.throwIfCancelled()
        guard options.maxByteCount >= 0, options.maxByteCount < Int64(Int.max) else {
            throw CanvasKitError.io("invalid asset byte limit")
        }
        guard let relativePath = locator.relativePath, !relativePath.isEmpty,
              !relativePath.hasPrefix("/"), !relativePath.contains("\0"),
              !relativePath.split(separator: "/").contains("..") else {
            throw CanvasKitError.repositoryRootViolation("asset requires a contained relative path")
        }
        // Foundation URL standardization may turn /private/var back into
        // /var on macOS. Keep POSIX realpath strings through descriptor IO.
        let components = relativePath.split(separator: "/").filter { $0 != "." }
        let candidatePath = physicalRootPath + "/" + components.joined(separator: "/")
        let resolvedPath = try Self.physicalPath(candidatePath)
        guard resolvedPath.hasPrefix(physicalRootPath + "/") else {
            throw CanvasKitError.repositoryRootViolation("asset path or symlink escapes resolver root")
        }
        if !options.followSymlinks && candidatePath != resolvedPath {
            throw CanvasKitError.repositoryRootViolation("asset symlinks are disabled")
        }
        // Open every physical component with no-follow semantics. A later
        // symlink replacement cannot redirect this read outside the root.
        let descriptor = try Self.openRegularFile(resolvedPath)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              (initial.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), initial.st_size >= 0 else {
            throw CanvasKitError.io("asset must be a readable regular file")
        }
        guard initial.st_size <= options.maxByteCount else {
            throw CanvasKitError.io("asset is \(initial.st_size) bytes, exceeding the \(options.maxByteCount) byte limit")
        }
        let limit = Int(options.maxByteCount)
        var data = Data()
        while true {
            try Task.checkCancellation()
            try token?.throwIfCancelled()
            let chunk = try handle.read(upToCount: min(65536, limit - data.count + 1)) ?? Data()
            guard !chunk.isEmpty else { break }
            guard chunk.count <= limit - data.count else {
                throw CanvasKitError.io("asset grew beyond the byte limit during reading")
            }
            data.append(chunk)
        }
        var final = stat()
        guard fstat(descriptor, &final) == 0, final.st_size == data.count else {
            throw CanvasKitError.io("asset changed during reading; reload its source revision")
        }
        try Task.checkCancellation()
        try token?.throwIfCancelled()
        return CanvasResolvedAsset(locator: locator, data: data,
            fileByteCount: Int64(data.count), mimeType: locator.mimeType, resolvedURL: URL(fileURLWithPath: resolvedPath))
    }

    private static func physicalPath(_ path: String) throws -> String {
        guard let buffer = path.withCString({ Darwin.realpath($0, nil) }) else {
            throw CanvasKitError.io("asset path is unavailable")
        }
        defer { free(buffer) }
        return String(cString: buffer)
    }

    private static func openRegularFile(_ path: String) throws -> Int32 {
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CanvasKitError.io("asset directory unavailable") }
        do {
            let components = path.split(separator: "/").map(String.init)
            for (index, component) in components.enumerated() {
                let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                    | (index == components.count - 1 ? 0 : O_DIRECTORY)
                let next = component.withCString { openat(descriptor, $0, flags) }
                Darwin.close(descriptor)
                descriptor = next
                guard descriptor >= 0 else {
                    throw CanvasKitError.io("asset component unavailable or changed (\(errno))")
                }
            }
            return descriptor
        } catch {
            if descriptor >= 0 { Darwin.close(descriptor) }
            throw error
        }
    }
}

// MARK: - Explicit metadata cache

public struct CanvasAssetMetadata: Hashable, Sendable {
    public var byteCount: Int64
    public var mimeType: String?
    public var contentHash: String?
    public var lastModified: Date?

    public init(
        byteCount: Int64,
        mimeType: String? = nil,
        contentHash: String? = nil,
        lastModified: Date? = nil
    ) {
        self.byteCount = byteCount
        self.mimeType = mimeType
        self.contentHash = contentHash
        self.lastModified = lastModified
    }
}

/// Small explicit metadata cache; hosts decide policy, eviction and
/// invalidation — the kit keeps no implicit global cache.
public actor CanvasAssetMetadataCache {
    private var entries: [UUID: CanvasAssetMetadata] = [:]

    public init() {}

    public func metadata(for assetID: UUID) -> CanvasAssetMetadata? {
        entries[assetID]
    }

    public func insert(
        _ metadata: CanvasAssetMetadata, for assetID: UUID
    ) {
        entries[assetID] = metadata
    }

    public func remove(for assetID: UUID) {
        entries[assetID] = nil
    }

    public func removeAll() {
        entries.removeAll()
    }
}

// MARK: - Host boundary protocols (UI/Exchange never need full Data)

/// Bounded thumbnail/cover request. `maxPixelSize` bounds the longest
/// edge; the result is bounded bytes plus metadata, never the full source.
public struct CanvasPreviewRequest: Hashable, Sendable {
    public var locator: CanvasAssetLocator
    public var maxPixelSize: Int
    /// Optional host content kind ("image", "video", "pdf", …).
    public var contentKind: String?

    public init(
        locator: CanvasAssetLocator,
        maxPixelSize: Int = 512,
        contentKind: String? = nil
    ) {
        self.locator = locator
        self.maxPixelSize = maxPixelSize
        self.contentKind = contentKind
    }
}

public struct CanvasPreviewResult: Hashable, Sendable {
    public var data: Data
    public var mimeType: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// True when the host could only produce a placeholder cover.
    public var isPlaceholder: Bool
    public var sourceByteCount: Int64
    public var cacheKey: String

    public init(
        data: Data,
        mimeType: String,
        pixelWidth: Int,
        pixelHeight: Int,
        isPlaceholder: Bool,
        sourceByteCount: Int64,
        cacheKey: String
    ) {
        self.data = data
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isPlaceholder = isPlaceholder
        self.sourceByteCount = sourceByteCount
        self.cacheKey = cacheKey
    }
}

/// Cancellable, bounded preview provider implemented by the host media
/// services (thumbnailing lives there; the kit declares the contract only).
public protocol CanvasPreviewProviding: Sendable {
    func preview(
        _ request: CanvasPreviewRequest,
        cancellation token: CanvasCancellationToken?
    ) async throws -> CanvasPreviewResult
}

/// Trusted file lease: the host hands out a sandbox file URL instead of
/// bytes; the lease expires and is revocable.
public struct CanvasFileLease: Hashable, Sendable {
    public var leaseID: UUID
    public var fileURL: URL
    public var byteCount: Int64
    public var mimeType: String?
    public var isReadOnly: Bool
    public var expiresAt: Date?

    public init(
        leaseID: UUID = UUID(),
        fileURL: URL,
        byteCount: Int64,
        mimeType: String? = nil,
        isReadOnly: Bool = true,
        expiresAt: Date? = nil
    ) {
        self.leaseID = leaseID
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.mimeType = mimeType
        self.isReadOnly = isReadOnly
        self.expiresAt = expiresAt
    }
}

public protocol CanvasResourceLeasing: Sendable {
    func leaseFile(
        for locator: CanvasAssetLocator,
        leaseDuration: TimeInterval,
        cancellation token: CanvasCancellationToken?
    ) async throws -> CanvasFileLease
    func releaseLease(_ leaseID: UUID) async throws
}

/// Bounded streaming read for large assets.
public protocol CanvasAssetStream: Sendable {
    var byteCount: Int64 { get }
    /// Returns up to `count` bytes; empty data means end of stream.
    func read(upToByteCount count: Int) async throws -> Data
}

public protocol CanvasAssetStreaming: Sendable {
    func openStream(
        for locator: CanvasAssetLocator,
        byteRange: Range<Int64>?,
        cancellation token: CanvasCancellationToken?
    ) async throws -> CanvasAssetStream
}

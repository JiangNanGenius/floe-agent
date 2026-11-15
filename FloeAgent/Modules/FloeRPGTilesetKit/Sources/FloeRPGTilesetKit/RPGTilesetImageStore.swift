// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import ImageIO
import FloeGameCore
import FloeRPGCore

public enum RPGTilesetImageError: Error, Equatable, Sendable {
    case cancelled
    case emptyData
    case invalidImage(String)
    case oversizedImage(width: Int, height: Int)
    case tooManyCachedImages
}

/// A decoded tileset image. The wrapper is `@unchecked Sendable` because
/// CGImage is immutable after creation; this package never writes into it.
public struct RPGDecodedImage: @unchecked Sendable {
    public let path: String
    public let image: CGImage
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let decodedBytes: Int
    public var size: CGSize { CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)) }

    public init(path: String, image: CGImage, pixelWidth: Int, pixelHeight: Int) {
        self.path = path; self.image = image
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.decodedBytes = pixelWidth * pixelHeight * 4
    }
}

/// Bounded decoded-image cache. All images are keyed by the active
/// project/revision generation; switching generation clears the cache and
/// makes late decodes fail instead of leaking across projects.
public actor RPGTilesetImageStore {
    public struct Limits: Sendable, Equatable {
        public var maximumEncodedBytes: Int
        public var maximumPixelDimension: Int
        public var maximumPixelCount: Int
        public var maximumDecodedBytes: Int
        public var maximumCachedImages: Int
        public var maximumImageDecodedBytes: Int

        public init(maximumEncodedBytes: Int = 32 * 1_024 * 1_024,
                    maximumPixelDimension: Int = 8_192,
                    maximumPixelCount: Int = 16_777_216,
                    maximumDecodedBytes: Int = 64 * 1_024 * 1_024,
                    maximumCachedImages: Int = 64,
                    maximumImageDecodedBytes: Int = 16 * 1_024 * 1_024) {
            self.maximumEncodedBytes = maximumEncodedBytes
            self.maximumPixelDimension = maximumPixelDimension
            self.maximumPixelCount = maximumPixelCount
            self.maximumDecodedBytes = maximumDecodedBytes
            self.maximumCachedImages = maximumCachedImages
            self.maximumImageDecodedBytes = maximumImageDecodedBytes
        }
    }

    public let limits: Limits
    private struct Entry { var image: RPGDecodedImage; var lastAccess: UInt64 }
    private var cache: [String: Entry] = [:]
    private var totalDecodedBytes = 0
    private var accessCounter: UInt64 = 0
    private var generation = UUID()

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public var currentGeneration: UUID { generation }

    /// Starts a new project/revision generation. Old decoded images are no
    /// longer returned and late decodes are rejected by the generation check.
    @discardableResult
    public func activate() -> UUID {
        generation = UUID()
        cache.removeAll(keepingCapacity: true)
        totalDecodedBytes = 0
        return generation
    }

    public func invalidate() {
        _ = activate()
    }

    public var cachedImageCount: Int { cache.count }
    public var cachedBytes: Int { totalDecodedBytes }

    public func image(at path: String, generation requested: UUID,
                      reader: @escaping @Sendable () async throws -> Data) async throws -> RPGDecodedImage {
        try Task.checkCancellation()
        guard generation == requested else { throw RPGTilesetImageError.cancelled }
        let key = "\(requested.uuidString)|\(path)"
        if var entry = cache[key] {
            accessCounter &+= 1
            entry.lastAccess = accessCounter
            cache[key] = entry
            return entry.image
        }
        let data = try await reader()
        try Task.checkCancellation()
        guard generation == requested else { throw RPGTilesetImageError.cancelled }
        let decoded = try Self.decode(data, path: path, limits: limits)
        guard generation == requested else { throw RPGTilesetImageError.cancelled }
        insert(decoded, key: key)
        return decoded
    }

    private func insert(_ image: RPGDecodedImage, key: String) {
        accessCounter &+= 1
        totalDecodedBytes += image.decodedBytes
        cache[key] = Entry(image: image, lastAccess: accessCounter)
        while (cache.count > limits.maximumCachedImages || totalDecodedBytes > limits.maximumDecodedBytes),
              let evict = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            if let removed = cache.removeValue(forKey: evict) {
                totalDecodedBytes = max(0, totalDecodedBytes - removed.image.decodedBytes)
            }
        }
    }

    /// ImageIO dimension check happens before full decode, so a malicious
    /// huge PNG/JPG is rejected without allocating its decoded bitmap.
    nonisolated public static func decode(_ data: Data, path: String, limits: Limits) throws -> RPGDecodedImage {
        guard !data.isEmpty else { throw RPGTilesetImageError.emptyData }
        guard data.count <= limits.maximumEncodedBytes else {
            throw RPGTilesetImageError.oversizedImage(width: 0, height: 0)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw RPGTilesetImageError.invalidImage(path)
        }
        var width = 0
        var height = 0
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        }
        if width > 0 && height > 0 {
            guard width <= limits.maximumPixelDimension, height <= limits.maximumPixelDimension,
                  width * height <= limits.maximumPixelCount,
                  width * height * 4 <= limits.maximumImageDecodedBytes else {
                throw RPGTilesetImageError.oversizedImage(width: width, height: height)
            }
        }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false
        ]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            throw RPGTilesetImageError.invalidImage(path)
        }
        let actualWidth = image.width
        let actualHeight = image.height
        guard actualWidth > 0, actualHeight > 0 else { throw RPGTilesetImageError.invalidImage(path) }
        guard actualWidth <= limits.maximumPixelDimension, actualHeight <= limits.maximumPixelDimension,
              actualWidth * actualHeight <= limits.maximumPixelCount,
              actualWidth * actualHeight * 4 <= limits.maximumImageDecodedBytes else {
            throw RPGTilesetImageError.oversizedImage(width: actualWidth, height: actualHeight)
        }
        return RPGDecodedImage(path: path, image: image, pixelWidth: actualWidth, pixelHeight: actualHeight)
    }
}

/// Bundles the decoded catalog and its image cache for one explicit
/// project/revision. Call `bind` whenever the authoritative session revision
/// changes; old images then cannot leak into the new revision.
public actor RPGTilesetContext {
    public private(set) var catalog: RPGTilesetCatalog
    public private(set) var generation: UUID
    public private(set) var projectID: UUID?
    public private(set) var revision: String?
    public private(set) var boundEngine: RPGEngine
    public let store: RPGTilesetImageStore

    public init(engine: RPGEngine, catalog: RPGTilesetCatalog? = nil,
                store: RPGTilesetImageStore = RPGTilesetImageStore()) {
        self.boundEngine = engine
        self.catalog = catalog ?? RPGTilesetCatalog(engine: engine)
        self.generation = UUID()
        self.store = store
    }

    @discardableResult
    public func bind(projectID: UUID, revision: String) async -> UUID {
        self.projectID = projectID
        self.revision = revision
        self.generation = await store.activate()
        return generation
    }

    public func update(catalog: RPGTilesetCatalog) {
        self.catalog = catalog
        self.boundEngine = catalog.engine
    }

    public func image(at path: String, generation requested: UUID,
                      reader: @escaping @Sendable () async throws -> Data) async throws -> RPGDecodedImage {
        try await store.image(at: path, generation: requested, reader: reader)
    }
}

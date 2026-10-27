// FloeApp — service-owned Skill Hub presentation media (lane file).
//
// SPDX-License-Identifier: MPL-2.0
//
// Demand-driven, bounded reader for the publication-pinned showcase artwork
// (`showcase/skills.json` + `showcase/media/*`) that the curated store views
// render BESIDE the signed catalog facts. It reuses the existing anonymous
// GitHub transport (`SourceControlCenter.skillRepositoryData`), never a
// connector credential, never an arbitrary URL and never a second trust root:
//
//   * everything is read ONLY at the immutable publication commit Y that the
//     verified catalog publication already carries;
//   * bytes are validated against the published contract BEFORE any image
//     object exists (strict path, declared MIME, magic bytes, size bounds);
//   * the native renderer supports png/jpeg/webp rasters only — SVG is never
//     fetched, executed or rasterized natively, so no new web-execution path
//     exists and callers fall back to bundled category artwork;
//   * a small in-memory LRU plus a bounded on-disk cache keyed by commit and
//     path keep scrolling cheap and offline; cached bytes are revalidated on
//     load and a torn or forged entry is dropped, never trusted;
//   * publication identity invalidates the session: binding a new commit
//     cancels shared reads and discards results that complete afterwards
//     (the epoch guard mirrored from the web hub-media contract);
//   * images are presentation only: a failure here NEVER blocks install,
//     update, enable or any other verified CTA.

#if canImport(UIKit)
import ImageIO
import UIKit
import CryptoKit
import FloeSkills

/// The single transport seam: the exact anonymous, bounded, GitHub-only file
/// reader the curated channel already uses. Tests inject a mock; production
/// views resolve the environment's own reader.
@MainActor
protocol SkillHubMediaReading: AnyObject {
    func repositoryData(owner: String, repository: String, ref: String, path: String) async throws -> Data
}

@MainActor
final class SourceControlSkillHubMediaReader: SkillHubMediaReading {
    private let control: SourceControlCenter
    init(control: SourceControlCenter) { self.control = control }
    func repositoryData(owner: String, repository: String, ref: String, path: String) async throws -> Data {
        try await control.skillRepositoryData(owner: owner, repository: repository,
                                              ref: ref, path: path,
                                              usesConnectorCredential: false)
    }
}

/// Bounded raw-bytes disk cache. The CENTER owns all validation; this actor
/// only stores/loads/deletes files by an opaque name under one directory and
/// keeps the directory under a total byte budget by evicting the oldest
/// entries. A torn or over-bound file is refused here too as a cheap guard.
actor SkillHubMediaDiskCache {
    private let root: URL
    private let fileManager = FileManager.default
    let perFileBytes: Int

    init(directory: URL, perFileBytes: Int = SkillHubShowcase.maximumMediaBytes) {
        root = directory
        self.perFileBytes = perFileBytes
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for fileName: String) -> URL { root.appendingPathComponent(fileName, isDirectory: false) }

    func load(fileName: String) -> Data? {
        guard isOpaqueName(fileName), let size = try? url(for: fileName).resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        guard size > 0, size <= perFileBytes, let data = try? Data(contentsOf: url(for: fileName)) else {
            try? fileManager.removeItem(at: url(for: fileName))
            return nil
        }
        return data
    }

    func store(fileName: String, bytes: Data) {
        guard isOpaqueName(fileName), bytes.count <= perFileBytes else { return }
        // `.atomic` writes through a platform temporary and renames, so a
        // crash can never leave a half-written cache entry.
        try? bytes.write(to: url(for: fileName), options: .atomic)
        prune()
    }

    func remove(fileName: String) {
        guard isOpaqueName(fileName) else { return }
        try? fileManager.removeItem(at: url(for: fileName))
    }

    func entryCount() -> Int {
        (try? fileManager.contentsOfDirectory(atPath: root.path))?.count ?? 0
    }

    private func prune() {
        guard let names = try? fileManager.contentsOfDirectory(at: root,
                                                               includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]),
              !names.isEmpty else { return }
        var sized: [(url: URL, size: Int, modified: Date)] = []
        var total = 0
        for fileURL in names {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            total += size
            sized.append((fileURL, size, values?.contentModificationDate ?? .distantPast))
        }
        guard total > maximumDirectoryBytes else { return }
        for entry in sized.sorted(by: { $0.modified < $1.modified }) {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
            if total <= maximumDirectoryBytes { break }
        }
    }

    /// The published session budget is also the disk ceiling for one
    /// checkout; the oldest artwork gives way first.
    static let maximumDirectoryBytes = SkillHubShowcase.maximumSessionBytes
    private var maximumDirectoryBytes: Int { Self.maximumDirectoryBytes }

    private func isOpaqueName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128
            && name.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value) || (97...122).contains(scalar.value)
                    || scalar.value == 45 || scalar.value == 46 || (65...70).contains(scalar.value)
            }
    }
}

@MainActor
final class SkillHubMediaCenter: ObservableObject {
    // MARK: Shared production service

    /// One service per process, like every other long-lived center. Views
    /// resolve the already-injected AppEnvironment in their body and bind its
    /// anonymous GitHub reader once; nothing else may replace it.
    static let shared = SkillHubMediaCenter(reader: nil)

    static func shared(using environment: AppEnvironment) -> SkillHubMediaCenter {
        let center = shared
        center.ensureReader(SourceControlSkillHubMediaReader(control: environment.sourceControlCenter))
        return center
    }

    // MARK: Budgets (published hub-media contract; the transport additionally
    // caps every anonymous read at its own per-path bound)

    struct Budgets: Sendable, Equatable {
        var maximumMemoryEntries = 64
        /// Decoded-bitmap cost bound of the in-memory LRU. Entry count alone
        /// is not a memory bound: a full list of maximum-size downsampled
        /// stills would otherwise retain hundreds of megabytes. Eviction
        /// respects BOTH limits.
        var maximumMemoryDecodedBytes = 64 * 1024 * 1024
        var maximumSessionBytes = SkillHubShowcase.maximumSessionBytes
        var maximumSessionFiles = SkillHubShowcase.maximumSessionFiles
        var perFileBytes = SkillHubShowcase.maximumMediaBytes

        init() {}
        init(maximumMemoryEntries: Int, maximumMemoryDecodedBytes: Int, maximumSessionBytes: Int,
             maximumSessionFiles: Int, perFileBytes: Int) {
            self.maximumMemoryEntries = max(1, maximumMemoryEntries)
            self.maximumMemoryDecodedBytes = max(1, maximumMemoryDecodedBytes)
            self.maximumSessionBytes = max(1, maximumSessionBytes)
            self.maximumSessionFiles = max(1, maximumSessionFiles)
            self.perFileBytes = max(1, perFileBytes)
        }
    }

    // MARK: State

    /// The active immutable publication this service renders. All reads are
    /// pinned to it; binding a different commit invalidates everything.
    private(set) var publicationCommit: String?

    private var reader: (any SkillHubMediaReading)?
    private let disk: SkillHubMediaDiskCache
    private let budgets: Budgets
    private var epoch = 0
    private var showcaseCache: [String: SkillHubShowcase] = [:]
    private var showcaseRequests: [String: Task<SkillHubShowcase?, Never>] = [:]
    private struct MemoryEntry {
        let image: UIImage
        /// Native decoded cost (bytesPerRow × height of the backing CGImage).
        let cost: Int
    }
    private var imageCache: [String: MemoryEntry] = [:]
    private var imageOrder: [String] = []
    private var imageDecodedBytes = 0
    private var imageRequests: [String: Task<UIImage?, Never>] = [:]
    private var sessionBytes = 0
    private var sessionFiles = 0

    init(reader: (any SkillHubMediaReading)?,
         budgets: Budgets = Budgets(),
         diskDirectory: URL? = nil) {
        self.reader = reader
        self.budgets = budgets
        let directory = diskDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FloeSkillHubMedia", isDirectory: true)
        disk = SkillHubMediaDiskCache(directory: directory, perFileBytes: budgets.perFileBytes)
    }

    private func ensureReader(_ candidate: any SkillHubMediaReading) {
        guard reader == nil else { return }
        reader = candidate
    }

    // MARK: Publication identity

    /// Called from the store views whenever the verified publication changes.
    /// A different commit immediately invalidates every cache, every shared
    /// in-flight read and the session budget; completions that arrive after
    /// the switch are discarded by the epoch guard, never republished.
    func bind(publicationCommit commit: String?) {
        let canonical = commit.flatMap { SkillHubShowcase.isCanonicalPublicationCommit($0) ? $0 : nil }
        guard canonical != publicationCommit else { return }
        publicationCommit = canonical
        epoch &+= 1
        showcaseRequests.values.forEach { $0.cancel() }
        showcaseRequests.removeAll()
        imageRequests.values.forEach { $0.cancel() }
        imageRequests.removeAll()
        showcaseCache.removeAll()
        imageCache.removeAll()
        imageOrder.removeAll()
        imageDecodedBytes = 0
        sessionBytes = 0
        sessionFiles = 0
    }

    // MARK: Showcase manifest

    /// The validated per-skill presentation document pinned to commit Y, or
    /// nil when unavailable, unverified or over-bound (callers then show the
    /// honest bundled fallback). One fetch per publication, shared readers.
    func showcase(commit: String) async -> SkillHubShowcase? {
        guard SkillHubShowcase.isCanonicalPublicationCommit(commit) else { return nil }
        if let cached = showcaseCache[commit] { return cached }
        if let inflight = showcaseRequests[commit] { return await inflight.value }
        let demandEpoch = epoch
        let task = Task { [weak self] () -> SkillHubShowcase? in
            guard let self else { return nil }
            let value = await self.loadShowcase(commit: commit, demandEpoch: demandEpoch)
            self.showcaseRequests[commit] = nil
            return value
        }
        showcaseRequests[commit] = task
        return await task.value
    }

    private func loadShowcase(commit: String, demandEpoch: Int) async -> SkillHubShowcase? {
        let name = diskFileName(commit: commit, path: SkillHubShowcase.manifestPath)
        if let cached = await disk.load(fileName: name) {
            if let validated = try? SkillHubShowcase.decode(data: cached) {
                return publishShowcase(validated, commit: commit, demandEpoch: demandEpoch)
            }
            await disk.remove(fileName: name)
        }
        // The publication may have switched while the disk read hopped; an
        // invalidated demand stops before touching the network.
        guard !Task.isCancelled, demandEpoch == epoch else { return nil }
        guard let reader else { return nil }
        do {
            let data = try await reader.repositoryData(owner: CuratedSkillHub.owner,
                                                       repository: CuratedSkillHub.repository,
                                                       ref: commit, path: SkillHubShowcase.manifestPath)
            guard data.count <= SkillHubShowcase.maximumManifestBytes else { return nil }
            let validated = try SkillHubShowcase.decode(data: data)
            // Persisting validated bytes is best-effort: a refused write only
            // costs a later re-fetch, never correctness (web hub-media rule).
            await disk.store(fileName: name, bytes: data)
            return publishShowcase(validated, commit: commit, demandEpoch: demandEpoch)
        } catch {
            return nil
        }
    }

    private func publishShowcase(_ showcase: SkillHubShowcase, commit: String, demandEpoch: Int) -> SkillHubShowcase? {
        guard demandEpoch == epoch, publicationCommit == commit else { return nil }
        showcaseCache[commit] = showcase
        return showcase
    }

    // MARK: Media bytes

    /// Decode one publication-pinned media file into a UIImage, or nil for
    /// ANY problem: non-canonical commit, unsafe or non-raster path, missing
    /// transport, over-bound, forged magic bytes, undecodable payload,
    /// exhausted budget or an invalidated epoch. Every caller keeps its
    /// fallback in place; nothing here can throw into the UI.
    func image(path: String, commit: String) async -> UIImage? {
        guard SkillHubShowcase.isCanonicalPublicationCommit(commit),
              SkillHubShowcase.isSafeMediaPath(path),
              let mime = SkillHubShowcase.mediaMIME(for: path),
              Self.nativelyRenderableMIMEs.contains(mime) else {
            // An SVG (or anything unknown) is never fetched and never
            // executed natively; the honest answer is "use the fallback".
            return nil
        }
        let key = "\(commit):\(path)"
        if let cached = touchMemory(key) { return cached }
        if let inflight = imageRequests[key] { return await inflight.value }
        let demandEpoch = epoch
        let task = Task { [weak self] () -> UIImage? in
            guard let self else { return nil }
            let value = await self.loadImage(path: path, commit: commit, key: key, demandEpoch: demandEpoch)
            self.imageRequests[key] = nil
            return value
        }
        imageRequests[key] = task
        return await task.value
    }

    private static let nativelyRenderableMIMEs: Set<String> = ["image/png", "image/jpeg", "image/webp"]

    private func loadImage(path: String, commit: String, key: String, demandEpoch: Int) async -> UIImage? {
        guard sessionFiles < budgets.maximumSessionFiles else { return nil }
        let name = diskFileName(commit: commit, path: path)
        var bytes: Data?
        var fromNetwork = false
        if let cached = await disk.load(fileName: name) {
            if SkillHubShowcase.bytesMatchPath(cached, path: path) {
                bytes = cached
            } else {
                // A torn or forged disk entry is deleted, never trusted, and
                // the demand re-reads cleanly from the pinned publication.
                await disk.remove(fileName: name)
            }
        }
        if bytes == nil {
            // The publication may have switched while the disk read hopped;
            // an invalidated demand stops before touching the network.
            guard !Task.isCancelled, demandEpoch == epoch else { return nil }
            guard let reader else { return nil }
            do {
                let fetched = try await reader.repositoryData(owner: CuratedSkillHub.owner,
                                                              repository: CuratedSkillHub.repository,
                                                              ref: commit, path: path)
                guard fetched.count <= budgets.perFileBytes,
                      SkillHubShowcase.bytesMatchPath(fetched, path: path) else {
                    return nil
                }
                bytes = fetched
                fromNetwork = true
            } catch {
                return nil
            }
        }
        guard let bytes else { return nil }
        guard !Task.isCancelled, demandEpoch == epoch else { return nil }
        // Rasterization is expensive and must never happen on the main
        // actor: ImageIO reads + bounded downsampling run detached, and the
        // decoded-pixel limits are what actually caps decoded memory
        // (the per-file byte cap alone cannot express pixel dimensions).
        let decoded: SkillHubDecodedMedia? = await Task.detached(priority: .userInitiated) {
            SkillHubMediaDecoder.decode(bytes: bytes)
        }.value
        guard !Task.isCancelled, demandEpoch == epoch else { return nil }
        guard let decoded else {
            // Undecodable under the bounded rasterizer: drop the entry so a
            // later demand re-reads from the pinned publication instead of
            // trusting the same refusal forever.
            await disk.remove(fileName: name)
            return nil
        }
        if fromNetwork {
            // Only bytes that passed BOTH contract validation and a bounded
            // decode are persisted; a refused write only costs a re-fetch.
            await disk.store(fileName: name, bytes: bytes)
        }
        guard demandEpoch == epoch, publicationCommit == commit,
              sessionBytes + bytes.count <= budgets.maximumSessionBytes else {
            return nil
        }
        sessionBytes += bytes.count
        sessionFiles += 1
        publishMemory(key: key, image: decoded.image, cost: decoded.decodedBytes)
        return decoded.image
    }

    // MARK: Memory LRU (bounded by count AND decoded-bitmap cost)

    private func touchMemory(_ key: String) -> UIImage? {
        guard let entry = imageCache[key] else { return nil }
        if let index = imageOrder.firstIndex(of: key) {
            imageOrder.remove(at: index)
        }
        imageOrder.append(key)
        return entry.image
    }

    /// Publishes one decoded still into the LRU. An image whose own decoded
    /// cost exceeds the entire cache budget is NOT retained (the caller still
    /// receives it for the current demand; the bounded disk cache absorbs the
    /// re-read), so the resident total can never breach the budget.
    private func publishMemory(key: String, image: UIImage, cost: Int) {
        guard cost <= budgets.maximumMemoryDecodedBytes else { return }
        if let existing = imageCache.removeValue(forKey: key),
           let index = imageOrder.firstIndex(of: key) {
            imageDecodedBytes -= existing.cost
            imageOrder.remove(at: index)
        }
        imageCache[key] = MemoryEntry(image: image, cost: cost)
        imageOrder.append(key)
        imageDecodedBytes += cost
        while imageOrder.count > budgets.maximumMemoryEntries || imageDecodedBytes > budgets.maximumMemoryDecodedBytes {
            guard let oldest = imageOrder.first else { break }
            imageOrder.removeFirst()
            if let evicted = imageCache.removeValue(forKey: oldest) {
                imageDecodedBytes -= evicted.cost
            }
        }
    }

    /// Test-visible LRU occupancy (both bounds are behavior under test).
    var debugMemoryCacheCount: Int { imageCache.count }
    var debugMemoryDecodedBytes: Int { imageDecodedBytes }

    // MARK: Cache naming

    /// Opaque, collision-resistant and path-safe: a versioned SHA-256 of the
    /// exact identity pair plus the declared extension. Nothing user-supplied
    /// reaches the filesystem directly.
    private func diskFileName(commit: String, path: String) -> String {
        let digest = SHA256.hash(data: Data("floe-skillhub-media-v1|\(commit)|\(path)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? hex : "\(hex).\(ext)"
    }
}

// MARK: - Decoded-pixel-bounded rasterizer

/// One successfully rasterized media file. The image is always the
/// downsampled still; the source dimensions explain what was resized.
/// UIImage itself is safe to hand back to the main actor here because this
/// type crosses exactly once, after construction completes off-main.
struct SkillHubDecodedMedia: @unchecked Sendable {
    let image: UIImage
    let pixelWidth: Int
    let pixelHeight: Int
    let downsampled: Bool
    /// Native retain cost of the decoded bitmap (bytesPerRow × height), used
    /// by the LRU so the in-memory cache is bounded by real memory, not by
    /// compressed file length alone.
    let decodedBytes: Int
}

/// ImageIO decode with bounded DECODED dimensions, executed off the main
/// actor. Byte caps bound the transfer; these bounds bound the bitmap:
///
///   * only single-frame stills are published (an animated container is
///     refused, never silently reduced to one frame);
///   * the source header dimensions are checked against the absolute
///     decoded-pixel limit BEFORE any pixel buffer is allocated, so a
///     small crafted file promising a giant canvas is rejected outright;
///   * anything longer than the native render edge is downsampled during
///     decode (EXIF orientation applied), so the LRU never holds a
///     full-size artwork bitmap.
enum SkillHubMediaDecoder {
    /// Longest native render edge. Published covers (1254 px) and gallery
    /// stills (1280×960) pass untouched; larger sources downsample to this.
    static let maximumPixelSize = 1600
    /// Absolute decoded-pixel ceiling (≈40 MP ≈ 160 MB raw RGBA), enforced
    /// from the ImageIO header before decode. Sources inside it downsample;
    /// sources beyond it are rejected.
    static let maximumDecodedPixels = 40_000_000

    static func decode(bytes: Data) -> SkillHubDecodedMedia? {
        guard !bytes.isEmpty else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(bytes as CFData, sourceOptions) else { return nil }
        // Animated PNG/GIF/WebP containers expose more than one frame; the
        // contract media are stills, and a multi-frame file is refused.
        guard CGImageSourceGetCount(source) == 1 else { return nil }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            return nil
        }
        guard width * height <= maximumDecodedPixels else { return nil }
        let downsampled = max(width, height) > maximumPixelSize
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let raster = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return SkillHubDecodedMedia(image: UIImage(cgImage: raster),
                                    pixelWidth: raster.width, pixelHeight: raster.height,
                                    downsampled: downsampled,
                                    decodedBytes: raster.bytesPerRow * raster.height)
    }
}
#endif

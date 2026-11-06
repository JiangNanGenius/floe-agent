#if canImport(UIKit)
import UIKit
import Combine
import FloeCanvasCore
import FloeCanvasIntegration

/// Bounded, cancellation-aware preview pipeline for media/PDF thumbnails.
///
/// Ownership rules (UI_BRIEF): previews are lightweight and visible-only;
/// the pipeline never pulls whole video/PDF Data — hosts provide bounded
/// bytes through `CanvasPreviewProviding`. Each in-flight request owns a
/// `CanvasCancellationToken`; reuse of a cell/key cancels the previous
/// request. The cache is an explicit NSCache bound, not an implicit global.
@MainActor
public final class CanvasPreviewPipeline: ObservableObject {
    public struct ImageEntry {
        public var image: UIImage
        public var isPlaceholder: Bool
    }

    private let provider: (any CanvasPreviewProviding)?
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: CanvasCancellationToken] = [:]

    /// Cache bound: preview bytes stay lightweight even on the 10k sample.
    public static let defaultCountLimit = 96

    public init(provider: (any CanvasPreviewProviding)?) {
        self.provider = provider
        cache.countLimit = Self.defaultCountLimit
    }
    var hasProvider: Bool { provider != nil }

    /// Returns a cached image or starts a bounded request. `nil` means the
    /// request is in flight or unavailable — callers show the lightweight
    /// placeholder, never a blank sold as rich content.
    public func preview(
        for locator: CanvasAssetLocator,
        contentKind: String?,
        maxPixelSize: Int = 512
    ) async -> ImageEntry? {
        let key = cacheKey(for: locator, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key as NSString) {
            return ImageEntry(image: cached, isPlaceholder: false)
        }
        guard let provider else { return nil }
        let token = CanvasCancellationToken()
        inFlight[key]?.cancel()
        inFlight[key] = token
        defer {
            // A cancelled older request must not remove the newer owner's
            // cancellation token when its provider callback arrives late.
            if inFlight[key] === token { inFlight[key] = nil }
        }
        do {
            let result = try await provider.preview(
                CanvasPreviewRequest(
                    locator: locator,
                    maxPixelSize: maxPixelSize,
                    contentKind: contentKind),
                cancellation: token)
            guard !token.isCancelled,
                  let image = UIImage(data: result.data) else { return nil }
            if !result.isPlaceholder {
                cache.setObject(image, forKey: key as NSString)
            }
            return ImageEntry(image: image, isPlaceholder: result.isPlaceholder)
        } catch {
            return nil
        }
    }

    /// Synchronous cache lookup for draw-loop consumers (the board). Never
    /// starts work; `nil` means "not cached", letting the caller register a
    /// bounded demand instead of blocking the draw pass.
    public func cachedImage(
        for locator: CanvasAssetLocator,
        contentKind: String?,
        maxPixelSize: Int = 512
    ) -> UIImage? {
        cache.object(forKey: cacheKey(for: locator, maxPixelSize: maxPixelSize) as NSString)
    }

    /// Cancels one in-flight request (if any) without touching the cache.
    /// The board uses this when a node leaves the viewport or the page
    /// changes; completed previews stay cached for re-entry.
    public func cancelInFlight(
        for locator: CanvasAssetLocator,
        maxPixelSize: Int = 512
    ) {
        let key = cacheKey(for: locator, maxPixelSize: maxPixelSize)
        inFlight[key]?.cancel()
        inFlight[key] = nil
    }

    /// Missing-resource state is actionable: the caller shows the resolve
    /// affordance and the inspector exposes re-linking (host editor).
    public func cancelAll() {
        for token in inFlight.values { token.cancel() }
        inFlight.removeAll()
    }

    private func cacheKey(for locator: CanvasAssetLocator, maxPixelSize: Int) -> String {
        [
            locator.id.uuidString,
            locator.contentHash ?? "nohash",
            String(maxPixelSize),
        ].joined(separator: "|")
    }

    /// Internal demand identity shared with the board's demand controller so
    /// both sides agree on what "one request" is.
    func demandKey(for locator: CanvasAssetLocator, maxPixelSize: Int) -> String {
        cacheKey(for: locator, maxPixelSize: maxPixelSize)
    }
}
#endif

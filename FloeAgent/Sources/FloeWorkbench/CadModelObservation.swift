// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// Projection requested for a read-only capture. For an ORIGINAL model, nil
/// keeps the viewer's actual current camera type, so existing callers keep
/// their behaviour. For a NATIVE `.floecad` document, nil uses the document's
/// saved scene projection when it has one and perspective otherwise; it never
/// depends on the user's transient orbit camera.
public enum CadModelObservationProjection: String, Codable, Sendable, CaseIterable {
    case perspective
    case orthographic
}

/// Read-only observation of an original model file or a native `.floecad`
/// document. It does not import either model into a CAD package, does not
/// change the user's camera/selection/undo, and never turns image coordinates
/// into topological IDs.
public struct CadModelObservationRequest: Codable, Sendable, Equatable {
    public struct View: Codable, Sendable, Equatable {
        public var azimuthDegrees: Double
        public var elevationDegrees: Double
        public var distanceScale: Double

        public init(azimuthDegrees: Double, elevationDegrees: Double, distanceScale: Double = 1) {
            self.azimuthDegrees = azimuthDegrees
            self.elevationDegrees = elevationDegrees
            self.distanceScale = distanceScale
        }

        enum CodingKeys: String, CodingKey { case azimuthDegrees, elevationDegrees, distanceScale }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            azimuthDegrees = try c.decode(Double.self, forKey: .azimuthDegrees)
            elevationDegrees = try c.decode(Double.self, forKey: .elevationDegrees)
            distanceScale = try c.decodeIfPresent(Double.self, forKey: .distanceScale) ?? 1
        }
    }

    public var views: [View]
    public var width: Int
    public var height: Int
    public var sceneIndex: Int?
    public var cameraIndex: Int?
    public var clipIndex: Int?
    public var timeSeconds: Double?
    /// Optional perspective/orthographic override for actual capture pixels.
    /// Nil preserves the original viewer's current camera type and uses the
    /// native document's saved scene projection (perspective when absent).
    public var projection: CadModelObservationProjection?
    /// For an ORIGINAL model this pins the exact source bytes. For a NATIVE
    /// `.floecad` document it pins the last committed package content SHA-256
    /// (`contentSHA256`), never a digest of unsaved in-memory mesh bytes.
    public var expectedSourceSHA256: String?
    /// NATIVE `.floecad` only: the exact last committed package revision.
    /// Omitted means "whatever revision is current when the observation
    /// starts"; every returned frame still reports the revision it used.
    public var expectedRevision: Int64?
    /// NATIVE `.floecad` only: the exact live in-memory change count. This is
    /// the unsaved-generation pin: a draft edit advances it without changing
    /// the committed revision, so pinning only the revision would let an
    /// observation silently show a different in-memory shape.
    public var expectedChangeCount: Int?
    public var maximumSourceBytes: Int
    public var maximumResources: Int
    public var includeImages: Bool
    public var nodeOffset: Int
    public var nodeLimit: Int

    public init(views: [View] = [.init(azimuthDegrees: 35, elevationDegrees: 20),
                                .init(azimuthDegrees: 125, elevationDegrees: 20),
                                .init(azimuthDegrees: 215, elevationDegrees: 20),
                                .init(azimuthDegrees: 305, elevationDegrees: 20)],
                width: Int = 1024, height: Int = 768, sceneIndex: Int? = nil,
                cameraIndex: Int? = nil, clipIndex: Int? = nil, timeSeconds: Double? = nil,
                projection: CadModelObservationProjection? = nil,
                expectedSourceSHA256: String? = nil,
                expectedRevision: Int64? = nil, expectedChangeCount: Int? = nil,
                maximumSourceBytes: Int = 20 * 1024 * 1024, maximumResources: Int = 32,
                includeImages: Bool = true, nodeOffset: Int = 0, nodeLimit: Int = 200) {
        self.views = views
        self.width = width
        self.height = height
        self.sceneIndex = sceneIndex
        self.cameraIndex = cameraIndex
        self.clipIndex = clipIndex
        self.timeSeconds = timeSeconds
        self.projection = projection
        self.expectedSourceSHA256 = expectedSourceSHA256
        self.expectedRevision = expectedRevision
        self.expectedChangeCount = expectedChangeCount
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumResources = maximumResources
        self.includeImages = includeImages
        self.nodeOffset = nodeOffset
        self.nodeLimit = nodeLimit
    }

    enum CodingKeys: String, CodingKey {
        case views, width, height, sceneIndex, cameraIndex, clipIndex, timeSeconds
        case projection, expectedSourceSHA256, expectedRevision, expectedChangeCount
        case maximumSourceBytes, maximumResources
        case includeImages, nodeOffset, nodeLimit
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        views = try c.decodeIfPresent([View].self, forKey: .views) ?? defaults.views
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? defaults.width
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? defaults.height
        sceneIndex = try c.decodeIfPresent(Int.self, forKey: .sceneIndex)
        cameraIndex = try c.decodeIfPresent(Int.self, forKey: .cameraIndex)
        clipIndex = try c.decodeIfPresent(Int.self, forKey: .clipIndex)
        timeSeconds = try c.decodeIfPresent(Double.self, forKey: .timeSeconds)
        projection = try c.decodeIfPresent(CadModelObservationProjection.self, forKey: .projection)
        expectedSourceSHA256 = try c.decodeIfPresent(String.self, forKey: .expectedSourceSHA256)
        expectedRevision = try c.decodeIfPresent(Int64.self, forKey: .expectedRevision)
        expectedChangeCount = try c.decodeIfPresent(Int.self, forKey: .expectedChangeCount)
        maximumSourceBytes = try c.decodeIfPresent(Int.self, forKey: .maximumSourceBytes) ?? defaults.maximumSourceBytes
        maximumResources = try c.decodeIfPresent(Int.self, forKey: .maximumResources) ?? defaults.maximumResources
        includeImages = try c.decodeIfPresent(Bool.self, forKey: .includeImages) ?? defaults.includeImages
        nodeOffset = try c.decodeIfPresent(Int.self, forKey: .nodeOffset) ?? defaults.nodeOffset
        nodeLimit = try c.decodeIfPresent(Int.self, forKey: .nodeLimit) ?? defaults.nodeLimit
    }

    public func validate() throws {
        let minimumViews = includeImages ? 1 : 0
        guard (minimumViews...4).contains(views.count), (64...2048).contains(width), (64...2048).contains(height),
              views.allSatisfy({ $0.azimuthDegrees.isFinite && $0.elevationDegrees.isFinite
                  && (-90...90).contains($0.elevationDegrees) && $0.distanceScale.isFinite
                  && (0.1...5).contains($0.distanceScale) }),
              [sceneIndex, cameraIndex, clipIndex].allSatisfy({ $0.map { $0 >= 0 } ?? true }),
              timeSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true,
              (1...64 * 1024 * 1024).contains(maximumSourceBytes), (1...128).contains(maximumResources),
              nodeOffset >= 0, (1...1000).contains(nodeLimit) else {
            throw FloeError.validationFailed("observe requires 1...4 finite views for images (0...4 for metadata only), 64...2048 pixels, non-negative scene/camera/clip/time, and at most 64 MiB/128 resources.")
        }
        if let expectedSourceSHA256 {
            guard expectedSourceSHA256.count == 64,
                  expectedSourceSHA256.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
                throw FloeError.validationFailed("expectedSourceSHA256 must be a SHA-256 hex digest.")
            }
        }
        guard expectedRevision.map({ $0 >= 0 }) ?? true,
              expectedChangeCount.map({ $0 >= 0 }) ?? true else {
            throw FloeError.validationFailed(
                "expectedRevision and expectedChangeCount must be non-negative native document pins.")
        }
    }

    /// True when this request carries a pin that only the native live
    /// generation can satisfy. Original-file observation must refuse these
    /// instead of silently ignoring them.
    public var hasNativeGenerationPins: Bool {
        expectedRevision != nil || expectedChangeCount != nil
    }

    /// Native `.floecad` has ONE live scene, no source-scene cameras and no
    /// static timeline. This returns the precise refusal for a selection the
    /// native observer cannot honour, so it can never quietly render a
    /// different scene/camera/frame and label it as the requested one.
    public func nativeSelectionRefusal() -> String? {
        if let sceneIndex, sceneIndex != 0 {
            return "A native .floecad document has one live scene; use sceneIndex 0 or omit it (got \(sceneIndex))."
        }
        if cameraIndex != nil {
            return "A native .floecad document has no source-scene camera selection; omit cameraIndex. "
                + "The workbench camera is user-owned and is not an observation selection."
        }
        if clipIndex != nil {
            return "A native .floecad document does not observe a clip index as a static frame; omit clipIndex. "
                + "Use cad.document action=animation with capture {clip_id,time} for an actual animated frame."
        }
        if let timeSeconds, timeSeconds > 0 {
            return "A native .floecad document does not observe an animation time as a static frame; omit timeSeconds "
                + "(or use 0). Use cad.document action=animation with capture {clip_id,time} for an actual animated frame."
        }
        return nil
    }
}

public struct CadModelObservationFrame: Sendable {
    public var pngData: Data
    public var metadataJSON: String
    public init(pngData: Data, metadataJSON: String) {
        self.pngData = pngData
        self.metadataJSON = metadataJSON
    }
}

public struct CadModelObservationResult: Sendable {
    public var summaryJSON: String
    public var frames: [CadModelObservationFrame]
    public init(summaryJSON: String, frames: [CadModelObservationFrame]) {
        self.summaryJSON = summaryJSON
        self.frames = frames
    }
}

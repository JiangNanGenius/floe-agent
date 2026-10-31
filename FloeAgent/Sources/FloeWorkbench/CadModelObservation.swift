// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// Projection requested for a read-only capture. Nil keeps the viewer's
/// actual current camera type, so existing callers keep their behaviour.
public enum CadModelObservationProjection: String, Codable, Sendable, CaseIterable {
    case perspective
    case orthographic
}

/// Read-only observation of an original model file. It does not import the
/// model into a CAD package or turn image coordinates into topological IDs.
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
    /// Nil preserves the live viewer's current camera type.
    public var projection: CadModelObservationProjection?
    public var expectedSourceSHA256: String?
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
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumResources = maximumResources
        self.includeImages = includeImages
        self.nodeOffset = nodeOffset
        self.nodeLimit = nodeLimit
    }

    enum CodingKeys: String, CodingKey {
        case views, width, height, sceneIndex, cameraIndex, clipIndex, timeSeconds
        case projection, expectedSourceSHA256, maximumSourceBytes, maximumResources
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
        maximumSourceBytes = try c.decodeIfPresent(Int.self, forKey: .maximumSourceBytes) ?? defaults.maximumSourceBytes
        maximumResources = try c.decodeIfPresent(Int.self, forKey: .maximumResources) ?? defaults.maximumResources
        includeImages = try c.decodeIfPresent(Bool.self, forKey: .includeImages) ?? defaults.includeImages
        nodeOffset = try c.decodeIfPresent(Int.self, forKey: .nodeOffset) ?? defaults.nodeOffset
        nodeLimit = try c.decodeIfPresent(Int.self, forKey: .nodeLimit) ?? defaults.nodeLimit
    }

    public func validate() throws {
        guard (1...4).contains(views.count), (64...2048).contains(width), (64...2048).contains(height),
              views.allSatisfy({ $0.azimuthDegrees.isFinite && $0.elevationDegrees.isFinite
                  && (-90...90).contains($0.elevationDegrees) && $0.distanceScale.isFinite
                  && (0.1...5).contains($0.distanceScale) }),
              [sceneIndex, cameraIndex, clipIndex].allSatisfy({ $0.map { $0 >= 0 } ?? true }),
              timeSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true,
              (1...64 * 1024 * 1024).contains(maximumSourceBytes), (1...128).contains(maximumResources),
              nodeOffset >= 0, (1...1000).contains(nodeLimit) else {
            throw FloeError.validationFailed("observe requires 1...4 finite views, 64...2048 pixels, non-negative scene/camera/clip/time, and at most 64 MiB/128 resources.")
        }
        if let expectedSourceSHA256 {
            guard expectedSourceSHA256.count == 64,
                  expectedSourceSHA256.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
                throw FloeError.validationFailed("expectedSourceSHA256 must be a SHA-256 hex digest.")
            }
        }
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

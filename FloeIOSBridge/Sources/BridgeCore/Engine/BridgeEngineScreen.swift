import Foundation

/// The actual coordinate spaces observed for the current screen.
///
/// JSON-RPC x/y values are **points** (the tap space). Screenshot bytes are in
/// pixels. Mixing them silently mis-taps; every conversion in the engine goes
/// through this type.
public struct BridgeEngineScreenMetrics: Equatable, Sendable {
    public let pointWidth: Double
    public let pointHeight: Double
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init?(pointWidth: Double, pointHeight: Double,
                 pixelWidth: Int, pixelHeight: Int) {
        guard pointWidth.isFinite, pointHeight.isFinite,
              pointWidth > 1, pointHeight > 1,
              pixelWidth > 1, pixelHeight > 1 else { return nil }
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var scale: Double {
        let horizontal = Double(pixelWidth) / pointWidth
        let vertical = Double(pixelHeight) / pointHeight
        return max(0.1, min(horizontal, vertical))
    }

    public var rect: BridgeUIRect {
        BridgeUIRect(x: 0, y: 0, width: pointWidth, height: pointHeight)
    }

    /// Converts a pixel-space point to the tap space. Used only when a client
    /// reads a screenshot and asks the bridge to act on a pixel reading.
    public func pointFromPixel(x: Double, y: Double) -> BridgeEnginePoint {
        BridgeEnginePoint(x: x / scale, y: y / scale)
    }
}

public struct BridgeEnginePoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum BridgeEnginePointResolution: Equatable, Sendable {
    case resolved(BridgeEnginePoint)
    case outOfRange(validX: ClosedRange<Double>, validY: ClosedRange<Double>)
}

public enum BridgeEngineGeometry {
    /// JSON coordinates are points. A small tolerance absorbs half-point
    /// rounding from a client that converted pixels; anything further outside
    /// the screen is refused with the actual valid range instead of being
    /// silently clamped to a different target.
    public static let roundingTolerance = 1.0

    public static func resolvePoint(x: Double,
                                    y: Double,
                                    metrics: BridgeEngineScreenMetrics,
                                    tolerance: Double = roundingTolerance) -> BridgeEnginePointResolution {
        guard x.isFinite, y.isFinite else {
            return .outOfRange(validX: 0...metrics.pointWidth,
                               validY: 0...metrics.pointHeight)
        }
        let lower = -max(0, tolerance)
        guard x >= lower, y >= lower,
              x <= metrics.pointWidth + max(0, tolerance),
              y <= metrics.pointHeight + max(0, tolerance) else {
            return .outOfRange(validX: 0...metrics.pointWidth,
                               validY: 0...metrics.pointHeight)
        }
        return .resolved(BridgeEnginePoint(
            x: min(max(x, 0), metrics.pointWidth),
            y: min(max(y, 0), metrics.pointHeight)
        ))
    }

    /// The app-normalized offset for a point inside an app frame. XCTest
    /// accepts normalized offsets and this keeps a coordinate inside its
    /// owning window even when the app does not start at (0,0).
    public static func normalizedOffset(point: BridgeEnginePoint,
                                        in frame: BridgeUIRect) -> (dx: Double, dy: Double)? {
        guard frame.width > 1, frame.height > 1 else { return nil }
        return ((point.x - frame.x) / frame.width,
                (point.y - frame.y) / frame.height)
    }

    public static func center(of frame: BridgeUIRect) -> BridgeEnginePoint {
        BridgeEnginePoint(x: frame.midX, y: frame.midY)
    }

    /// Clamps a screen point into an app frame, leaving a 1-point margin so
    /// edge gestures remain synthesizable. Returns nil for an unusable frame.
    public static func clamped(_ point: BridgeEnginePoint,
                               to frame: BridgeUIRect,
                               margin: Double = 1) -> BridgeEnginePoint? {
        guard frame.width > 2, frame.height > 2 else { return nil }
        let inset = min(max(margin, 0), min(frame.width, frame.height) / 2)
        return BridgeEnginePoint(
            x: min(max(point.x, frame.x + inset), frame.x + frame.width - inset),
            y: min(max(point.y, frame.y + inset), frame.y + frame.height - inset)
        )
    }

    public static func contains(_ frame: BridgeUIRect,
                                point: BridgeEnginePoint,
                                tolerance: Double = 0.5) -> Bool {
        point.x >= frame.x - tolerance &&
            point.y >= frame.y - tolerance &&
            point.x <= frame.x + frame.width + tolerance &&
            point.y <= frame.y + frame.height + tolerance
    }
}

public struct BridgeEngineScreenshotRequest: Equatable, Sendable {
    public enum Format: String, Equatable, Sendable {
        case jpeg
        case png
    }

    public var format: Format
    public var quality: Double
    public var requestedScale: Double

    public init(format: Format, quality: Double, requestedScale: Double) {
        self.format = format
        self.quality = quality
        self.requestedScale = requestedScale
    }
}

public struct BridgeEngineScreenshotPolicy: Equatable, Sendable {
    public static let minimumScale = 0.5
    public static let maximumScale = 3.0
    public static let defaultQuality = 0.6
    public static let minimumQuality = 0.1
    public static let maximumQuality = 1.0
    public static let maximumPixelDimension = 8_192
    public static let maximumEncodedBytes = 12 * 1_024 * 1_024

    /// Clamps user values into the documented range. A requested scale above
    /// the native scale is capped to native: upscaling adds bytes, never
    /// detail, and reporting a fake computed scale would be dishonest.
    public static func request(_ params: BridgeEngineParameters,
                               nativeScale: Double) throws -> BridgeEngineScreenshotRequest {
        let format = try params.option("format", allowed: ["jpeg", "png"], default: "jpeg") ?? "jpeg"
        let quality = try params.number("quality",
                                        default: defaultQuality,
                                        range: minimumQuality...maximumQuality)
        let defaultScale = max(minimumScale, min(2.0, nativeScale))
        let requested = try params.number("scale",
                                          default: defaultScale,
                                          range: minimumScale...maximumScale)
        return BridgeEngineScreenshotRequest(
            format: format == "png" ? .png : .jpeg,
            quality: quality,
            requestedScale: min(requested, max(minimumScale, min(nativeScale, maximumScale)))
        )
    }

    public static func pixelDimensions(metrics: BridgeEngineScreenMetrics,
                                       scale: Double) -> (width: Int, height: Int)? {
        let width = Int((metrics.pointWidth * scale).rounded())
        let height = Int((metrics.pointHeight * scale).rounded())
        guard width > 1, height > 1,
              width <= maximumPixelDimension,
              height <= maximumPixelDimension else { return nil }
        return (width, height)
    }
}

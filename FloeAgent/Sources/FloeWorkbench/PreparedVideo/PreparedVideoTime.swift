// FloeWorkbench — PreparedVideo: exact rational time and frame windows.
//
// This file is deliberately independent of the shared media document model.
// The v2 adapter is the only place allowed to read `MediaPreparedDocument`;
// it resolves the project into the immutable `PreparedVideoPlan` consumed by
// this component. Keeping time exact here is what makes 30000/1001 preview
// frame selection agree with the exported frame boundary.

import Foundation

// MARK: - Errors

/// Structured failures raised by the prepared-video render boundary.
///
/// Cases never contain user text, absolute source paths or secret material.
public enum PreparedVideoError: Error, Sendable, Hashable, LocalizedError {
    case invalidTime(String)
    case invalidPlan(String)
    case emptyTimeline
    case missingAsset(UUID)
    case assetUnreadable(UUID)
    case invalidOutputSettings(String)
    case codecUnavailable(PreparedVideoCodec)
    case renderFailed(String)
    case audioFailure(String)
    case cancelled
    case destinationExists
    case staleRevision
    case superseded
    case cacheLimitExceeded(String)
    case unsupportedCapability(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTime(let detail):
            "Prepared video time is invalid: \(detail)"
        case .invalidPlan(let detail):
            "Prepared video plan is invalid: \(detail)"
        case .emptyTimeline:
            "The prepared video plan has no visible frames."
        case .missingAsset(let id):
            "Prepared video asset \(id.uuidString) is missing."
        case .assetUnreadable(let id):
            "Prepared video asset \(id.uuidString) could not be decoded."
        case .invalidOutputSettings(let detail):
            "Prepared video output settings are invalid: \(detail)"
        case .codecUnavailable(let codec):
            "The \(codec.rawValue.uppercased()) encoder is not available on this device."
        case .renderFailed(let detail):
            "Prepared video rendering failed: \(detail)"
        case .audioFailure(let detail):
            "Prepared video audio mixing failed: \(detail)"
        case .cancelled:
            "Prepared video rendering was cancelled."
        case .destinationExists:
            "A file already exists at the destination; pass overwrite to replace it."
        case .staleRevision:
            "The requested prepared video revision is older than the registered revision."
        case .superseded:
            "The prepared video result was superseded by a newer project revision."
        case .cacheLimitExceeded(let detail):
            "Prepared video proxy request exceeds a bound: \(detail)"
        case .unsupportedCapability(let detail):
            "Prepared video capability is unavailable: \(detail)"
        }
    }
}

// MARK: - Rational time

/// Exact time in `value / timescale` seconds.
///
/// Plans choose one timescale for every timeline value. Using the output frame
/// rate numerator as the timescale makes frame boundaries exact for rational
/// rates such as 30000/1001: one frame is 1001 ticks at 30000 ticks/second.
public struct PreparedVideoTime: Sendable, Hashable, Codable, Comparable {
    public let value: Int64
    public let timescale: Int32

    public init(value: Int64, timescale: Int32) throws {
        guard timescale > 0 else {
            throw PreparedVideoError.invalidTime("timescale must be positive")
        }
        self.value = value
        self.timescale = timescale
    }

    /// Converts seconds with half-away-from-zero rounding at `timescale`.
    /// The rounding policy is explicit; callers that need a frame grid should
    /// use `PreparedVideoFrameRate.time(forFrame:timescale:)` instead.
    public init(seconds: Double, timescale: Int32) throws {
        guard seconds.isFinite, seconds >= 0 else {
            throw PreparedVideoError.invalidTime("seconds must be finite and non-negative")
        }
        guard timescale > 0 else {
            throw PreparedVideoError.invalidTime("timescale must be positive")
        }
        let scaled = seconds * Double(timescale)
        guard scaled.isFinite, scaled <= Double(Int64.max) else {
            throw PreparedVideoError.invalidTime("time exceeds Int64 at timescale \(timescale)")
        }
        self.init(unchecked: Int64(scaled.rounded(.toNearestOrAwayFromZero)), timescale: timescale)
    }

    public var seconds: Double {
        Double(value) / Double(timescale)
    }

    public var isZero: Bool { value == 0 }

    public func adding(_ other: PreparedVideoTime) throws -> PreparedVideoTime {
        guard other.timescale == timescale else {
            throw PreparedVideoError.invalidTime("timescales differ")
        }
        let (sum, overflow) = value.addingReportingOverflow(other.value)
        guard !overflow else {
            throw PreparedVideoError.invalidTime("time addition overflow")
        }
        return PreparedVideoTime(unchecked: sum, timescale: timescale)
    }

    public func subtracting(_ other: PreparedVideoTime) throws -> PreparedVideoTime {
        guard other.timescale == timescale else {
            throw PreparedVideoError.invalidTime("timescales differ")
        }
        let (difference, overflow) = value.subtractingReportingOverflow(other.value)
        guard !overflow else {
            throw PreparedVideoError.invalidTime("time subtraction overflow")
        }
        return PreparedVideoTime(unchecked: difference, timescale: timescale)
    }

    public func scaled(by factor: Int64) throws -> PreparedVideoTime {
        let (product, overflow) = value.multipliedReportingOverflow(by: factor)
        guard !overflow else {
            throw PreparedVideoError.invalidTime("time multiplication overflow")
        }
        return PreparedVideoTime(unchecked: product, timescale: timescale)
    }

    public func clamped(to range: PreparedVideoTimeRange) -> PreparedVideoTime {
        if self < range.start { return range.start }
        let end = (try? range.endTime()) ?? range.start
        if self > end { return end }
        return self
    }

    public static func < (lhs: PreparedVideoTime, rhs: PreparedVideoTime) -> Bool {
        if lhs.timescale == rhs.timescale { return lhs.value < rhs.value }
        let (left, leftOverflow) = lhs.value.multipliedReportingOverflow(by: Int64(rhs.timescale))
        let (right, rightOverflow) = rhs.value.multipliedReportingOverflow(by: Int64(lhs.timescale))
        if !leftOverflow, !rightOverflow { return left < right }
        return lhs.seconds < rhs.seconds
    }

    public static func == (lhs: PreparedVideoTime, rhs: PreparedVideoTime) -> Bool {
        if lhs.timescale == rhs.timescale { return lhs.value == rhs.value }
        let (left, leftOverflow) = lhs.value.multipliedReportingOverflow(by: Int64(rhs.timescale))
        let (right, rightOverflow) = rhs.value.multipliedReportingOverflow(by: Int64(lhs.timescale))
        if !leftOverflow, !rightOverflow { return left == right }
        return lhs.seconds == rhs.seconds
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(seconds)
    }

    fileprivate init(unchecked value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    enum CodingKeys: String, CodingKey { case value, timescale }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Int64.self, forKey: .value)
        let timescale = try container.decode(Int32.self, forKey: .timescale)
        guard timescale > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .timescale, in: container,
                debugDescription: "timescale must be positive")
        }
        self.init(unchecked: value, timescale: timescale)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(timescale, forKey: .timescale)
    }
}

// MARK: - Frame rate

public enum PreparedVideoFrameRounding: Sendable, Hashable {
    case down
    case nearest
    case up
}

/// A positive rational frame rate. `30000/1001` is the canonical 29.97 rate.
public struct PreparedVideoFrameRate: Sendable, Hashable, Codable {
    public let numerator: Int32
    public let denominator: Int32

    public init(numerator: Int32, denominator: Int32) throws {
        guard numerator > 0, denominator > 0 else {
            throw PreparedVideoError.invalidTime("frame rate must be positive")
        }
        guard numerator <= 1_000_000, denominator <= 100_000 else {
            throw PreparedVideoError.invalidTime("frame rate exceeds a supported rational bound")
        }
        self.numerator = numerator
        self.denominator = denominator
    }

    public static let fps24 = try! PreparedVideoFrameRate(numerator: 24, denominator: 1)
    public static let fps25 = try! PreparedVideoFrameRate(numerator: 25, denominator: 1)
    public static let fps30 = try! PreparedVideoFrameRate(numerator: 30, denominator: 1)
    public static let fps60 = try! PreparedVideoFrameRate(numerator: 60, denominator: 1)
    public static let ntsc2398 = try! PreparedVideoFrameRate(numerator: 24_000, denominator: 1_001)
    public static let ntsc2997 = try! PreparedVideoFrameRate(numerator: 30_000, denominator: 1_001)
    public static let ntsc5994 = try! PreparedVideoFrameRate(numerator: 60_000, denominator: 1_001)

    public var fps: Double {
        Double(numerator) / Double(denominator)
    }

    public var description: String { "\(numerator)/\(denominator)" }

    /// Integer frame index containing `time`. Division is exact for the
    /// bounded plan times this component accepts; a floating fallback is only
    /// used if the checked products would overflow.
    public func frameIndex(for time: PreparedVideoTime,
                           rounding: PreparedVideoFrameRounding = .down) -> Int64 {
        let (scaledValue, valueOverflow) = time.value.multipliedReportingOverflow(by: Int64(numerator))
        let (scaledTimeScale, scaleOverflow) = Int64(time.timescale).multipliedReportingOverflow(by: Int64(denominator))
        if !valueOverflow, !scaleOverflow, scaledTimeScale > 0 {
            switch rounding {
            case .down:
                let quotient = scaledValue / scaledTimeScale
                let remainder = scaledValue % scaledTimeScale
                return remainder < 0 ? quotient - 1 : quotient
            case .nearest:
                return Int64((Double(scaledValue) / Double(scaledTimeScale)).rounded(.toNearestOrAwayFromZero))
            case .up:
                let quotient = scaledValue / scaledTimeScale
                let remainder = scaledValue % scaledTimeScale
                return remainder > 0 ? quotient + 1 : quotient
            }
        }
        let value = time.seconds * fps
        switch rounding {
        case .down: return Int64(floor(value))
        case .nearest: return Int64(value.rounded(.toNearestOrAwayFromZero))
        case .up: return Int64(ceil(value))
        }
    }

    /// Exact time of `frame` at a caller-chosen timescale. When the timescale
    /// cannot represent the frame boundary, the value is rounded to the
    /// nearest tick; callers that require exact boundaries use the frame-rate
    /// numerator as the plan timescale.
    public func time(forFrame frame: Int64, timescale: Int32) throws -> PreparedVideoTime {
        guard frame >= 0 else {
            throw PreparedVideoError.invalidTime("frame index must be non-negative")
        }
        guard timescale > 0 else {
            throw PreparedVideoError.invalidTime("timescale must be positive")
        }
        let (frameTicks, frameOverflow) = frame.multipliedReportingOverflow(by: Int64(denominator))
        let (ticks, tickOverflow) = frameTicks.multipliedReportingOverflow(by: Int64(timescale))
        guard !frameOverflow, !tickOverflow else {
            throw PreparedVideoError.invalidTime("frame time exceeds Int64")
        }
        let divisor = Int64(numerator)
        let quotient = ticks / divisor
        let remainder = ticks % divisor
        let value: Int64
        if remainder == 0 {
            value = quotient
        } else {
            let roundUp = remainder * 2 >= divisor
            value = quotient + (roundUp ? 1 : 0)
        }
        return PreparedVideoTime(unchecked: value, timescale: timescale)
    }

    /// Frame duration in the chosen timescale. The value is exact when
    /// `timescale` is the rate numerator.
    public func frameDuration(timescale: Int32) throws -> PreparedVideoTime {
        try time(forFrame: 1, timescale: timescale)
    }

    enum CodingKeys: String, CodingKey { case numerator, denominator }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let numerator = try container.decode(Int32.self, forKey: .numerator)
        let denominator = try container.decode(Int32.self, forKey: .denominator)
        do {
            try self.init(numerator: numerator, denominator: denominator)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .numerator, in: container,
                debugDescription: "frame rate must be positive")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(numerator, forKey: .numerator)
        try container.encode(denominator, forKey: .denominator)
    }
}

// MARK: - Time range

/// Half-open rational interval `[start, start + duration)`.
public struct PreparedVideoTimeRange: Sendable, Hashable, Codable {
    public let start: PreparedVideoTime
    public let duration: PreparedVideoTime

    public init(start: PreparedVideoTime, duration: PreparedVideoTime) throws {
        guard start.timescale == duration.timescale else {
            throw PreparedVideoError.invalidTime("range start and duration must share a timescale")
        }
        guard duration.value >= 0 else {
            throw PreparedVideoError.invalidTime("range duration must be non-negative")
        }
        self.start = start
        self.duration = duration
    }

    public init(startSeconds: Double, durationSeconds: Double, timescale: Int32) throws {
        try self.init(start: PreparedVideoTime(seconds: startSeconds, timescale: timescale),
                      duration: PreparedVideoTime(seconds: durationSeconds, timescale: timescale))
    }

    public var timescale: Int32 { start.timescale }
    public var startSeconds: Double { start.seconds }
    public var durationSeconds: Double { duration.seconds }
    public var endSeconds: Double { startSeconds + durationSeconds }

    public func endTime() throws -> PreparedVideoTime {
        try start.adding(duration)
    }

    public func contains(_ time: PreparedVideoTime, inclusiveEnd: Bool = false) -> Bool {
        guard time >= start else { return false }
        guard let end = try? endTime() else { return false }
        return inclusiveEnd ? time <= end : time < end
    }

    public func intersects(_ other: PreparedVideoTimeRange) -> Bool {
        guard timescale == other.timescale else {
            return startSeconds < other.endSeconds && other.startSeconds < endSeconds
        }
        guard let end = try? endTime(), let otherEnd = try? other.endTime() else { return false }
        return start < otherEnd && other.start < end
    }

    /// Smallest range covering both values. Both must share a timescale.
    public func union(_ other: PreparedVideoTimeRange) throws -> PreparedVideoTimeRange {
        guard timescale == other.timescale else {
            throw PreparedVideoError.invalidTime("range union requires one timescale")
        }
        let low = min(start, other.start)
        let high = max(try endTime(), try other.endTime())
        return try PreparedVideoTimeRange(start: low, duration: high.subtracting(low))
    }

    public func clamped(to limit: PreparedVideoTimeRange) throws -> PreparedVideoTimeRange {
        guard timescale == limit.timescale else {
            throw PreparedVideoError.invalidTime("range clamp requires one timescale")
        }
        let low = max(start, limit.start)
        let high = min(try endTime(), try limit.endTime())
        guard high > low else {
            return try PreparedVideoTimeRange(start: low, duration: PreparedVideoTime(value: 0, timescale: timescale))
        }
        return try PreparedVideoTimeRange(start: low, duration: high.subtracting(low))
    }

    /// Merges overlapping or touching ranges, preserving ascending order.
    public static func merged(_ ranges: [PreparedVideoTimeRange]) -> [PreparedVideoTimeRange] {
        guard !ranges.isEmpty else { return [] }
        let ordered = ranges.sorted { $0.start < $1.start }
        var output: [PreparedVideoTimeRange] = []
        for range in ordered {
            guard let last = output.last else {
                output.append(range)
                continue
            }
            let touches = range.start <= ((try? last.endTime()) ?? last.start)
            if touches, let merged = try? last.union(range) {
                output[output.count - 1] = merged
            } else {
                output.append(range)
            }
        }
        return output
    }

    enum CodingKeys: String, CodingKey { case start, duration }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(PreparedVideoTime.self, forKey: .start)
        let duration = try container.decode(PreparedVideoTime.self, forKey: .duration)
        do {
            try self.init(start: start, duration: duration)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .duration, in: container,
                debugDescription: "range duration must be non-negative and share the start timescale")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(duration, forKey: .duration)
    }
}

// MARK: - Frame window

/// Bounded half-open frame window used by preview proxies and the exporter.
/// The requested time range is expanded to whole frames; `timeRange` is the
/// exact frame-aligned range that was actually rendered.
public struct PreparedVideoFrameWindow: Sendable, Hashable {
    public let startFrame: Int64
    public let endFrame: Int64
    public let frameRate: PreparedVideoFrameRate
    public let timescale: Int32

    public init(startFrame: Int64, endFrame: Int64,
                frameRate: PreparedVideoFrameRate, timescale: Int32) throws {
        guard timescale > 0 else {
            throw PreparedVideoError.invalidTime("window timescale must be positive")
        }
        guard startFrame >= 0, endFrame > startFrame else {
            throw PreparedVideoError.invalidTime("window must contain at least one frame")
        }
        let frameCount = endFrame - startFrame
        guard frameCount <= Int64(Int32.max) else {
            throw PreparedVideoError.invalidTime("window frame count is too large")
        }
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.frameRate = frameRate
        self.timescale = timescale
    }

    public init(range: PreparedVideoTimeRange, frameRate: PreparedVideoFrameRate) throws {
        let startFrame = frameRate.frameIndex(for: range.start, rounding: .down)
        let endFrame = frameRate.frameIndex(for: try range.endTime(), rounding: .up)
        try self.init(startFrame: startFrame, endFrame: endFrame,
                      frameRate: frameRate, timescale: range.timescale)
    }

    public var frameCount: Int { Int(endFrame - startFrame) }

    public func time(forLocalFrame frame: Int64) throws -> PreparedVideoTime {
        guard frame >= 0, frame < Int64(frameCount) else {
            throw PreparedVideoError.invalidTime("local frame \(frame) is outside the window")
        }
        return try frameRate.time(forFrame: startFrame + frame, timescale: timescale)
    }

    public func absoluteFrame(forLocalFrame frame: Int64) throws -> Int64 {
        guard frame >= 0, frame < Int64(frameCount) else {
            throw PreparedVideoError.invalidTime("local frame \(frame) is outside the window")
        }
        return startFrame + frame
    }

    public func timeRange() throws -> PreparedVideoTimeRange {
        let start = try frameRate.time(forFrame: startFrame, timescale: timescale)
        let end = try frameRate.time(forFrame: endFrame, timescale: timescale)
        return try PreparedVideoTimeRange(start: start, duration: end.subtracting(start))
    }

    public var durationSeconds: Double {
        Double(frameCount) * Double(frameRate.denominator) / Double(frameRate.numerator)
    }
}

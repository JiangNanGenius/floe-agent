// SPDX-License-Identifier: MPL-2.0
//
// Format-neutral rational time and frame-rate primitives.
//
// This file deliberately has no AVFoundation/CoreMedia dependency so the same
// value semantics can be used by FCPXML, OpenTimelineIO, the project manifest
// and the drawing geometry layer. The FCPXML adapter maps these values to
// CMTime only at the OpenFCPXMLKit boundary.

import Foundation

public enum ExchangeTimeError: Error, Equatable, CustomStringConvertible {
    case zeroTimescale
    case negativeTimescale
    case negativeTime
    case overflow
    case invalidFrameRate(numerator: Int64, denominator: Int64)
    case mismatch(String)

    public var description: String {
        switch self {
        case .zeroTimescale: return "time timescale must not be zero"
        case .negativeTimescale: return "time timescale must be positive"
        case .negativeTime: return "time value must not be negative"
        case .overflow: return "rational time arithmetic overflowed"
        case let .invalidFrameRate(numerator, denominator):
            return "invalid frame rate \(numerator)/\(denominator)"
        case let .mismatch(message): return message
        }
    }
}

/// Exact rational time in seconds: `value / timescale`.
///
/// The denominator is always positive and numerator/denominator are reduced.
/// A negative value is rejected by the public initializer because clip starts,
/// durations and media durations in the supported exchange subset are
/// non-negative. Signed arithmetic results are represented internally and
/// checked before being exposed.
public struct ExchangeTime: Hashable, Sendable, Comparable, Codable {
    public let value: Int64
    public let timescale: Int64

    public static let zero = ExchangeTime(uncheckedValue: 0, timescale: 1)

    private init(uncheckedValue: Int64, timescale: Int64) {
        self.value = uncheckedValue
        self.timescale = timescale
    }

    public init(value: Int64, timescale: Int64) throws {
        guard timescale != 0 else { throw ExchangeTimeError.zeroTimescale }
        guard timescale > 0 else { throw ExchangeTimeError.negativeTimescale }
        guard value >= 0 else { throw ExchangeTimeError.negativeTime }
        let normalized = ExchangeTime.reduce(value: value, timescale: timescale)
        self.value = normalized.value
        self.timescale = normalized.timescale
    }

    /// Creates a time from a whole number of frames. The frame rate must be
    /// exact (for example 30000/1001), never a rounded Double preset.
    public static func frames(_ count: Int64, rate: ExchangeFrameRate) throws -> ExchangeTime {
        guard count >= 0 else { throw ExchangeTimeError.negativeTime }
        let result = count.multipliedReportingOverflow(by: rate.denominator)
        guard !result.overflow else { throw ExchangeTimeError.overflow }
        return try ExchangeTime(value: result.partialValue, timescale: rate.numerator)
    }

    public var seconds: Double {
        Double(value) / Double(timescale)
    }

    public var isZero: Bool { value == 0 }

    /// FCPXML-compatible rational-time string (`value/timescale s`, or
    /// `value s` when the denominator is one). It never emits a rounded
    /// floating-point duration.
    public var fcpxmlString: String {
        timescale == 1 ? "\(value)s" : "\(value)/\(timescale)s"
    }

    public func adding(_ other: ExchangeTime) throws -> ExchangeTime {
        try ExchangeTime.adding(self, other)
    }

    public func subtracting(_ other: ExchangeTime) throws -> ExchangeTime {
        try ExchangeTime.subtracting(self, other)
    }

    public func multiplied(by multiplier: ExchangeTime) throws -> ExchangeTime {
        let numerator = try ExchangeTime.multiply(value, multiplier.value)
        let denominator = try ExchangeTime.multiply(timescale, multiplier.timescale)
        return try ExchangeTime(value: numerator, timescale: denominator)
    }

    public static func + (lhs: ExchangeTime, rhs: ExchangeTime) throws -> ExchangeTime {
        try adding(lhs, rhs)
    }

    public static func - (lhs: ExchangeTime, rhs: ExchangeTime) throws -> ExchangeTime {
        try subtracting(lhs, rhs)
    }

    public static func < (lhs: ExchangeTime, rhs: ExchangeTime) -> Bool {
        let left = lhs.value.multipliedReportingOverflow(by: rhs.timescale)
        let right = rhs.value.multipliedReportingOverflow(by: lhs.timescale)
        if !left.overflow, !right.overflow {
            return left.partialValue < right.partialValue
        }
        return lhs.seconds < rhs.seconds
    }

    public func isMultiple(of frameDuration: ExchangeTime) -> Bool {
        // value/timescale / (f.value/f.timescale) = value*f.timescale / (timescale*f.value)
        guard frameDuration.value != 0 else { return false }
        let numerator = self.value.multipliedReportingOverflow(by: frameDuration.timescale)
        let denominator = self.timescale.multipliedReportingOverflow(by: frameDuration.value)
        guard !numerator.overflow, !denominator.overflow else { return false }
        return denominator.partialValue != 0 && numerator.partialValue % denominator.partialValue == 0
    }

    // MARK: - Helpers

    private static func adding(_ lhs: ExchangeTime, _ rhs: ExchangeTime) throws -> ExchangeTime {
        let left = try multiply(lhs.value, rhs.timescale)
        let right = try multiply(rhs.value, lhs.timescale)
        let denominator = try multiply(lhs.timescale, rhs.timescale)
        let numerator = try add(left, right)
        return try ExchangeTime(value: numerator, timescale: denominator)
    }

    private static func subtracting(_ lhs: ExchangeTime, _ rhs: ExchangeTime) throws -> ExchangeTime {
        let left = try multiply(lhs.value, rhs.timescale)
        let right = try multiply(rhs.value, lhs.timescale)
        let denominator = try multiply(lhs.timescale, rhs.timescale)
        let numerator = try subtract(left, right)
        guard numerator >= 0 else { throw ExchangeTimeError.negativeTime }
        return try ExchangeTime(value: numerator, timescale: denominator)
    }

    private static func multiply(_ a: Int64, _ b: Int64) throws -> Int64 {
        let result = a.multipliedReportingOverflow(by: b)
        guard !result.overflow else { throw ExchangeTimeError.overflow }
        return result.partialValue
    }

    private static func add(_ a: Int64, _ b: Int64) throws -> Int64 {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow else { throw ExchangeTimeError.overflow }
        return result.partialValue
    }

    private static func subtract(_ a: Int64, _ b: Int64) throws -> Int64 {
        let result = a.subtractingReportingOverflow(b)
        guard !result.overflow else { throw ExchangeTimeError.overflow }
        return result.partialValue
    }

    private static func reduce(value: Int64, timescale: Int64) -> (value: Int64, timescale: Int64) {
        let divisor = greatestCommonDivisor(abs(value), timescale)
        return (value / divisor, timescale / divisor)
    }

    private static func greatestCommonDivisor(_ a: Int64, _ b: Int64) -> Int64 {
        var a = a
        var b = b
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return a == 0 ? 1 : a
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case value
        case timescale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Int64.self, forKey: .value)
        let timescale = try container.decode(Int64.self, forKey: .timescale)
        try self.init(value: value, timescale: timescale)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(timescale, forKey: .timescale)
    }
}

/// Exact frame rate represented as frames per second: `numerator / denominator`.
public struct ExchangeFrameRate: Hashable, Sendable, Codable, CustomStringConvertible {
    public let numerator: Int64
    public let denominator: Int64

    public init(numerator: Int64, denominator: Int64) throws {
        guard numerator > 0, denominator > 0 else {
            throw ExchangeTimeError.invalidFrameRate(numerator: numerator, denominator: denominator)
        }
        let divisor = ExchangeFrameRate.greatestCommonDivisor(numerator, denominator)
        self.numerator = numerator / divisor
        self.denominator = denominator / divisor
    }

    public static let fps24 = try! ExchangeFrameRate(numerator: 24, denominator: 1)
    public static let fps25 = try! ExchangeFrameRate(numerator: 25, denominator: 1)
    public static let fps30 = try! ExchangeFrameRate(numerator: 30, denominator: 1)
    public static let fps60 = try! ExchangeFrameRate(numerator: 60, denominator: 1)
    public static let ntsc24 = try! ExchangeFrameRate(numerator: 24000, denominator: 1001)
    public static let ntsc30 = try! ExchangeFrameRate(numerator: 30000, denominator: 1001)
    public static let ntsc60 = try! ExchangeFrameRate(numerator: 60000, denominator: 1001)

    public var secondsPerFrame: ExchangeTime {
        // Denominator is guaranteed positive, so this cannot throw.
        try! ExchangeTime(value: denominator, timescale: numerator)
    }

    public var nominal: Double {
        Double(numerator) / Double(denominator)
    }

    public var description: String { "\(numerator)/\(denominator)" }

    /// Best rational approximation of a floating-point rate, bounded by
    /// `maxDenominator`. OTIO stores rates as doubles; callers that have the
    /// exact rational value should keep it in metadata instead of relying on
    /// this approximation.
    public static func rationalApproximation(
        of value: Double,
        maxDenominator: Int64 = 1_000_000
    ) throws -> ExchangeFrameRate {
        guard value.isFinite, value > 0, maxDenominator > 0 else {
            throw ExchangeTimeError.invalidFrameRate(numerator: 0, denominator: 0)
        }
        // Continued-fraction convergents. h/k start as 1/0 (previous) and
        // 0/1 (current), matching the standard recurrence.
        var previousNumerator: Int64 = 0
        var previousDenominator: Int64 = 1
        var currentNumerator: Int64 = 1
        var currentDenominator: Int64 = 0
        var current = value
        for _ in 0..<64 {
            let wholeValue = floor(current)
            guard wholeValue.isFinite, wholeValue <= Double(Int64.max) - 1 else { break }
            let whole = Int64(wholeValue)
            let numerator = whole.multipliedReportingOverflow(by: currentNumerator)
            let denominator = whole.multipliedReportingOverflow(by: currentDenominator)
            guard !numerator.overflow, !denominator.overflow else { break }
            let sumNumerator = numerator.partialValue.addingReportingOverflow(previousNumerator)
            let sumDenominator = denominator.partialValue.addingReportingOverflow(previousDenominator)
            guard !sumNumerator.overflow, !sumDenominator.overflow else { break }
            let nextNumerator = sumNumerator.partialValue
            let nextDenominator = sumDenominator.partialValue
            if nextDenominator > maxDenominator || nextDenominator <= 0 {
                break
            }
            previousNumerator = currentNumerator
            previousDenominator = currentDenominator
            currentNumerator = nextNumerator
            currentDenominator = nextDenominator
            if abs(Double(currentNumerator) / Double(currentDenominator) - value) <= 1e-12 {
                break
            }
            let fraction = current - Double(whole)
            if fraction <= 1e-15 { break }
            current = 1 / fraction
        }
        return try ExchangeFrameRate(
            numerator: currentNumerator,
            denominator: max(1, currentDenominator)
        )
    }

    private static func greatestCommonDivisor(_ a: Int64, _ b: Int64) -> Int64 {
        var a = a
        var b = b
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return a == 0 ? 1 : a
    }

    private enum CodingKeys: String, CodingKey {
        case numerator
        case denominator
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            numerator: container.decode(Int64.self, forKey: .numerator),
            denominator: container.decode(Int64.self, forKey: .denominator)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(numerator, forKey: .numerator)
        try container.encode(denominator, forKey: .denominator)
    }
}

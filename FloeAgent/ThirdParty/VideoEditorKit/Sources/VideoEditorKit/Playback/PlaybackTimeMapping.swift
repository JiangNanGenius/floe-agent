import Foundation

public enum PlaybackTimeMapping {

    // MARK: - Public Methods

    public static func timelineTimePreservingSourcePosition(
        timelineTime: Double,
        previousRate: Float,
        newRate: Float,
        newRange: ClosedRange<Double>,
        originalDuration: Double
    ) -> Double {
        let sourceTime = sourceTime(
            forTimelineTime: timelineTime,
            rate: previousRate,
            originalDuration: originalDuration
        )
        let remappedTimelineTime = Self.timelineTime(
            fromSourceTime: sourceTime,
            rate: newRate
        )

        return remappedTimelineTime.clamped(to: newRange)
    }

    public static func scaledTimelineRange(
        sourceRange: ClosedRange<Double>,
        rate: Float,
        originalDuration: Double
    ) -> ClosedRange<Double> {
        let resolvedOriginalDuration = max(originalDuration, .zero)
        let resolvedRate = Double(normalizedRate(rate))
        let clampedLowerBound = sourceRange.lowerBound.clamped(to: 0...resolvedOriginalDuration)
        let clampedUpperBound = sourceRange.upperBound.clamped(
            to: clampedLowerBound...resolvedOriginalDuration
        )

        return (clampedLowerBound / resolvedRate)...(clampedUpperBound / resolvedRate)
    }

    public static func sourceTime(
        forTimelineTime timelineTime: Double,
        rate: Float,
        originalDuration: Double
    ) -> Double {
        let resolvedRate = Double(normalizedRate(rate))
        let resolvedOriginalDuration = max(originalDuration, .zero)
        let sourceTime = max(timelineTime, .zero) * resolvedRate

        return sourceTime.clamped(to: .zero...resolvedOriginalDuration)
    }

    public static func timelineTime(
        fromSourceTime sourceTime: Double,
        rate: Float
    ) -> Double {
        let resolvedRate = Double(normalizedRate(rate))
        return max(sourceTime, .zero) / resolvedRate
    }

    // MARK: - Private Methods

    private static func normalizedRate(_ rate: Float) -> Float {
        guard rate.isFinite, rate > 0 else { return 1 }
        return rate
    }

}

extension Double {

    // MARK: - Internal Methods

    func clamped(
        to range: ClosedRange<Double>
    ) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }

}

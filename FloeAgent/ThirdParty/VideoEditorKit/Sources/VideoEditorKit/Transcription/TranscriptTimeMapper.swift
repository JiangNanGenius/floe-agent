import Foundation

public enum TranscriptTimeMapper {

    // MARK: - Public Methods

    public static func timelineTime(
        fromSourceTime sourceTime: Double,
        rate: Float
    ) -> Double {
        PlaybackTimeMapping.timelineTime(
            fromSourceTime: sourceTime,
            rate: rate
        )
    }

    public static func sourceTime(
        fromTimelineTime timelineTime: Double,
        rate: Float
    ) -> Double {
        max(timelineTime, .zero) * Double(normalizedRate(rate))
    }

    public static func projectedTimelineRange(
        sourceRange: ClosedRange<Double>,
        trimRange: ClosedRange<Double>,
        rate: Float
    ) -> ClosedRange<Double>? {
        let lowerBound = max(sourceRange.lowerBound, trimRange.lowerBound)
        let upperBound = min(sourceRange.upperBound, trimRange.upperBound)

        guard upperBound >= lowerBound else { return nil }

        let projectedLowerBound = timelineTime(
            fromSourceTime: lowerBound,
            rate: rate
        )
        let projectedUpperBound = timelineTime(
            fromSourceTime: upperBound,
            rate: rate
        )

        return projectedLowerBound...projectedUpperBound
    }

    public static func remapped(
        _ mapping: TranscriptTimeMapping,
        trimRange: ClosedRange<Double>,
        rate: Float
    ) -> TranscriptTimeMapping {
        let projectedRange = projectedTimelineRange(
            sourceRange: mapping.sourceRange,
            trimRange: trimRange,
            rate: rate
        )

        var remappedMapping = mapping
        remappedMapping.timelineStartTime = projectedRange?.lowerBound
        remappedMapping.timelineEndTime = projectedRange?.upperBound
        return remappedMapping
    }

    // MARK: - Private Methods

    private static func normalizedRate(_ rate: Float) -> Float {
        guard rate.isFinite, rate > 0 else { return 1 }
        return rate
    }

}

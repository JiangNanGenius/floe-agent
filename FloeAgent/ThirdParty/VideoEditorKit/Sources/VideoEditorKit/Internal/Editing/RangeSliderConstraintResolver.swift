import Foundation

struct RangeSliderConstraintResolver {

    // MARK: - Public Methods

    static func normalizedMaximumDistance(
        _ maximumDistance: Double?,
        totalRange: Double
    ) -> Double? {
        guard let maximumDistance else { return nil }
        guard maximumDistance.isFinite, maximumDistance > 0 else { return nil }

        return min(maximumDistance, max(totalRange, 0))
    }

    static func clampedRange(
        _ range: ClosedRange<Double>,
        bounds: ClosedRange<Double>,
        minimumDistance: Double,
        maximumDistance: Double?
    ) -> ClosedRange<Double> {
        let lowerBound = range.lowerBound.clamped(to: bounds)
        let upperBound = range.upperBound.clamped(to: lowerBound...bounds.upperBound)
        let resolvedMinimumDistance = min(max(minimumDistance, 0), bounds.upperBound - bounds.lowerBound)
        let resolvedMaximumDistance = resolvedMaximumDistance(
            maximumDistance,
            minimumDistance: resolvedMinimumDistance,
            totalRange: bounds.upperBound - bounds.lowerBound
        )

        guard upperBound >= lowerBound else {
            return lowerBound...lowerBound
        }

        var resolvedRange = lowerBound...upperBound

        if resolvedMinimumDistance > 0, resolvedRange.upperBound - resolvedRange.lowerBound < resolvedMinimumDistance {
            let expandedUpperBound = (resolvedRange.lowerBound + resolvedMinimumDistance).clamped(
                to: resolvedRange.lowerBound...bounds.upperBound
            )
            let adjustedLowerBound = (expandedUpperBound - resolvedMinimumDistance).clamped(
                to: bounds.lowerBound...expandedUpperBound
            )

            resolvedRange = adjustedLowerBound...expandedUpperBound
        }

        guard let resolvedMaximumDistance else {
            return resolvedRange
        }

        guard resolvedRange.upperBound - resolvedRange.lowerBound > resolvedMaximumDistance else {
            return resolvedRange
        }

        let limitedUpperBound = min(
            resolvedRange.lowerBound + resolvedMaximumDistance,
            bounds.upperBound
        )

        return resolvedRange.lowerBound...limitedUpperBound
    }

    static func allowedLowerBoundRange(
        for currentRange: ClosedRange<Double>,
        bounds: ClosedRange<Double>,
        minimumDistance: Double,
        maximumDistance: Double?
    ) -> ClosedRange<Double> {
        let resolvedRange = clampedRange(
            currentRange,
            bounds: bounds,
            minimumDistance: minimumDistance,
            maximumDistance: maximumDistance
        )
        let resolvedMaximumDistance = resolvedMaximumDistance(
            maximumDistance,
            minimumDistance: max(minimumDistance, 0),
            totalRange: bounds.upperBound - bounds.lowerBound
        )
        let minimumLowerBound =
            resolvedMaximumDistance.map {
                max(bounds.lowerBound, resolvedRange.upperBound - $0)
            } ?? bounds.lowerBound
        let maximumLowerBound = max(
            bounds.lowerBound,
            resolvedRange.upperBound - max(minimumDistance, 0)
        )

        return minimumLowerBound...maximumLowerBound
    }

    static func allowedUpperBoundRange(
        for currentRange: ClosedRange<Double>,
        bounds: ClosedRange<Double>,
        minimumDistance: Double,
        maximumDistance: Double?
    ) -> ClosedRange<Double> {
        let resolvedRange = clampedRange(
            currentRange,
            bounds: bounds,
            minimumDistance: minimumDistance,
            maximumDistance: maximumDistance
        )
        let resolvedMaximumDistance = resolvedMaximumDistance(
            maximumDistance,
            minimumDistance: max(minimumDistance, 0),
            totalRange: bounds.upperBound - bounds.lowerBound
        )
        let minimumUpperBound = min(
            bounds.upperBound,
            resolvedRange.lowerBound + max(minimumDistance, 0)
        )
        let maximumUpperBound =
            resolvedMaximumDistance.map {
                min(bounds.upperBound, resolvedRange.lowerBound + $0)
            } ?? bounds.upperBound

        return minimumUpperBound...maximumUpperBound
    }

    // MARK: - Private Methods

    private static func resolvedMaximumDistance(
        _ maximumDistance: Double?,
        minimumDistance: Double,
        totalRange: Double
    ) -> Double? {
        guard
            let normalizedMaximumDistance = normalizedMaximumDistance(
                maximumDistance,
                totalRange: totalRange
            )
        else {
            return nil
        }

        return max(normalizedMaximumDistance, minimumDistance)
    }

}

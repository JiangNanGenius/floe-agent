import Foundation
import Testing

@testable import VideoEditorKit

@Suite("RangeSliderConstraintResolverTests")
struct RangeSliderConstraintResolverTests {

    // MARK: - Public Methods

    @Test
    func clampedRangePreservesValidSelectionsWithoutAMaximumDistance() {
        let range = RangeSliderConstraintResolver.clampedRange(
            20...80,
            bounds: 0...100,
            minimumDistance: 1,
            maximumDistance: nil
        )

        #expect(range == 20...80)
    }

    @Test
    func clampedRangeShrinksSelectionsThatExceedTheMaximumDistance() {
        let range = RangeSliderConstraintResolver.clampedRange(
            30...95,
            bounds: 0...120,
            minimumDistance: 1,
            maximumDistance: 45
        )

        #expect(range == 30...75)
    }

    @Test
    func allowedLowerBoundRangeHonorsTheMaximumDistance() {
        let allowedRange = RangeSliderConstraintResolver.allowedLowerBoundRange(
            for: 30...90,
            bounds: 0...120,
            minimumDistance: 1,
            maximumDistance: 45
        )

        #expect(allowedRange == 30...74)
    }

    @Test
    func allowedUpperBoundRangeHonorsTheMaximumDistance() {
        let allowedRange = RangeSliderConstraintResolver.allowedUpperBoundRange(
            for: 30...90,
            bounds: 0...120,
            minimumDistance: 1,
            maximumDistance: 45
        )

        #expect(allowedRange == 31...75)
    }

    @Test
    func clampedRangeKeepsTheMinimumDistanceWhenTheMaximumDistanceIsSmaller() {
        let range = RangeSliderConstraintResolver.clampedRange(
            10...10.4,
            bounds: 0...120,
            minimumDistance: 1,
            maximumDistance: 0.5
        )

        #expect(range == 10...11)
    }

}

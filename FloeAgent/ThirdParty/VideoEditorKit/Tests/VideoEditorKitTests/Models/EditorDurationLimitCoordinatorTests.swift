import Foundation
import Testing

@testable import VideoEditorKit

@Suite("EditorDurationLimitCoordinatorTests")
struct EditorDurationLimitCoordinatorTests {

    // MARK: - Public Methods

    @Test
    func normalizedMaximumDurationDropsNilNonFiniteAndNonPositiveValues() {
        #expect(EditorDurationLimitCoordinator.normalizedMaximumDuration(nil) == nil)
        #expect(EditorDurationLimitCoordinator.normalizedMaximumDuration(0) == nil)
        #expect(EditorDurationLimitCoordinator.normalizedMaximumDuration(-5) == nil)
        #expect(EditorDurationLimitCoordinator.normalizedMaximumDuration(.infinity) == nil)
        #expect(EditorDurationLimitCoordinator.normalizedMaximumDuration(45) == 45)
    }

    @Test
    func clampedTrimRangePreservesTheRangeWhenThereIsNoLimit() {
        let range = EditorDurationLimitCoordinator.clampedTrimRange(
            30...90,
            originalDuration: 120,
            maximumDuration: nil
        )

        #expect(range == 30...90)
    }

    @Test
    func clampedTrimRangeDefaultsToTheConfiguredLimitForFreshSessions() {
        let range = EditorDurationLimitCoordinator.clampedTrimRange(
            0...120,
            originalDuration: 120,
            maximumDuration: 60
        )

        #expect(range == 0...60)
    }

    @Test
    func clampedTrimRangeShrinksTheUpperBoundWhenTheSelectedWindowExceedsTheLimit() {
        let range = EditorDurationLimitCoordinator.clampedTrimRange(
            30...120,
            originalDuration: 180,
            maximumDuration: 60
        )

        #expect(range == 30...90)
    }

    @Test
    func clampedTrimRangeStillRespectsTheSourceDurationNearTheEndOfTheAsset() {
        let range = EditorDurationLimitCoordinator.clampedTrimRange(
            130...220,
            originalDuration: 150,
            maximumDuration: 60
        )

        #expect(range == 130...150)
    }

    @Test
    func resolvedMaximumTrimDurationClampsTheHostLimitToTheSourceDuration() {
        let maximumTrimDuration = EditorDurationLimitCoordinator.resolvedMaximumTrimDuration(
            originalDuration: 40,
            maximumDuration: 60
        )

        #expect(maximumTrimDuration == 40)
    }

}

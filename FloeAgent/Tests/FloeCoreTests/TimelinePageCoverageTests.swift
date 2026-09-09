import Testing
@testable import FloeCore

struct TimelinePageCoverageTests {
    @Test func reconnectGapLoadsBeforeOlderHistory() {
        var coverage = TimelinePageCoverage<Int>()
        coverage.record(first: 51, last: 100, hasEarlier: true)
        coverage.record(first: 251, last: 300, hasEarlier: true)
        #expect(coverage.earlierCursor == 251)
        coverage.record(first: 201, last: 250, before: 251, hasEarlier: true)
        #expect(coverage.earlierCursor == 201)
        coverage.record(first: 151, last: 200, before: 201, hasEarlier: true)
        coverage.record(first: 101, last: 150, before: 151, hasEarlier: true)
        coverage.record(first: 51, last: 100, before: 101, hasEarlier: true)
        #expect(coverage.earlierCursor == 51)
        coverage.record(first: 1, last: 50, before: 51, hasEarlier: false)
        #expect(coverage.earlierCursor == nil)
    }

    @Test func completeOldHistoryDoesNotHideNewGap() {
        var coverage = TimelinePageCoverage<Int>()
        coverage.record(first: 1, last: 5, hasEarlier: false)
        coverage.record(first: 80, last: 100, hasEarlier: true)
        #expect(coverage.earlierCursor == 80)
        coverage.record(first: 5, last: 79, before: 80, hasEarlier: true)
        #expect(coverage.earlierCursor == nil)
    }

    @Test func newSnapshotDuringEarlierPageFetchKeepsBothGaps() {
        var coverage = TimelinePageCoverage<Int>()
        coverage.record(first: 10, last: 20, hasEarlier: true)
        coverage.record(first: 80, last: 100, hasEarlier: true)
        let requestedBefore = coverage.earlierCursor
        coverage.record(first: 200, last: 220, hasEarlier: true)
        coverage.record(first: 20, last: 79, before: requestedBefore, hasEarlier: true)
        #expect(coverage.earlierCursor == 200)
        coverage.record(first: 100, last: 199, before: 200, hasEarlier: true)
        #expect(coverage.earlierCursor == 10)
    }

    @Test func nonConsecutiveKeysAreNotAssumedToBeMissing() {
        var coverage = TimelinePageCoverage<Int>()
        coverage.record(first: 10, last: 100, hasEarlier: true)
        coverage.record(first: 90, last: 300, hasEarlier: true)
        #expect(coverage.earlierCursor == 10)
        coverage.record(first: nil, last: nil, before: 10, hasEarlier: false)
        #expect(coverage.earlierCursor == nil)
        coverage.record(first: 280, last: 400, hasEarlier: true)
        #expect(coverage.earlierCursor == nil)
    }
}

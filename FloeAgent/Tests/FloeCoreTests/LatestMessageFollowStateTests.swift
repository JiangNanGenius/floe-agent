import Testing
@testable import FloeCore

struct LatestMessageFollowStateTests {
    @Test func contentGrowthCannotTurnOffFollow() {
        var state = LatestMessageFollowState()
        state.observe(previousOffset: 0, offset: 500, bottomDistance: 0, userScrolling: false)
        state.observe(previousOffset: 500, offset: 500, bottomDistance: 400, userScrolling: false)
        #expect(state.followsLatest)
    }
    @Test func upwardReadingStopsAndManualBottomRestores() {
        var state = LatestMessageFollowState()
        state.observe(previousOffset: 0, offset: 500, bottomDistance: 0, userScrolling: false)
        state.observe(previousOffset: 500, offset: 350, bottomDistance: 150, userScrolling: true)
        #expect(!state.followsLatest)
        state.observe(previousOffset: 350, offset: 350, bottomDistance: 600, userScrolling: false)
        #expect(!state.followsLatest)
        state.observe(previousOffset: 350, offset: 940, bottomDistance: 10, userScrolling: true)
        #expect(state.followsLatest)
        state.observe(previousOffset: 940, offset: 940, bottomDistance: 250, userScrolling: false)
        #expect(state.followsLatest)
    }
    @Test func returnButtonRestoresIntentBeforeScrollLayoutCompletes() {
        var state = LatestMessageFollowState()
        state.observe(previousOffset: 0, offset: 100, bottomDistance: 0, userScrolling: false)
        state.observe(previousOffset: 100, offset: 0, bottomDistance: 100, userScrolling: true)
        state.returnToLatest()
        state.observe(previousOffset: 0, offset: 0, bottomDistance: 200, userScrolling: false)
        #expect(state.followsLatest)
    }

    @Test func geometryNoiseDoesNotChangeThePublishedFollowState() {
        var state = LatestMessageFollowState()
        state.observe(previousOffset: 100, offset: 105, bottomDistance: 5, userScrolling: false)
        let baseline = state
        for offset in 106..<300 {
            state.observe(previousOffset: Double(offset - 1), offset: Double(offset),
                          bottomDistance: 20, userScrolling: false)
            #expect(state == baseline)
        }
        state.pauseFollowing()
        state.observe(previousOffset: 300, offset: 60, bottomDistance: 240, userScrolling: false)
        #expect(!state.followsLatest)
        #expect(state.isAwayFromLatest)
    }
}

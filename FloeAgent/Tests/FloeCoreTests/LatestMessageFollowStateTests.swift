import Testing
@testable import FloeCore

struct LatestMessageFollowStateTests {
    @Test func contentGrowthCannotTurnOffFollow() {
        var state = LatestMessageFollowState()
        state.observe(offset: 500, bottomDistance: 0, userScrolling: false)
        state.observe(offset: 500, bottomDistance: 400, userScrolling: false)
        #expect(state.followsLatest)
    }
    @Test func upwardReadingStopsAndManualBottomRestores() {
        var state = LatestMessageFollowState()
        state.observe(offset: 500, bottomDistance: 0, userScrolling: false)
        state.observe(offset: 350, bottomDistance: 150, userScrolling: true)
        #expect(!state.followsLatest)
        state.observe(offset: 350, bottomDistance: 600, userScrolling: false)
        #expect(!state.followsLatest)
        state.observe(offset: 940, bottomDistance: 10, userScrolling: true)
        #expect(state.followsLatest)
        state.observe(offset: 940, bottomDistance: 250, userScrolling: false)
        #expect(state.followsLatest)
    }
    @Test func returnButtonRestoresIntentBeforeScrollLayoutCompletes() {
        var state = LatestMessageFollowState()
        state.observe(offset: 100, bottomDistance: 0, userScrolling: false)
        state.observe(offset: 0, bottomDistance: 100, userScrolling: true)
        state.returnToLatest()
        state.observe(offset: 0, bottomDistance: 200, userScrolling: false)
        #expect(state.followsLatest)
    }
}

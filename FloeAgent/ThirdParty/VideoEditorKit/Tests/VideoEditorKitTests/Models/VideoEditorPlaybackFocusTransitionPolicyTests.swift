import Testing

@testable import VideoEditorKit

@Suite("VideoEditorPlaybackFocusTransitionPolicyTests")
struct PlaybackFocusTransitionPolicyTests {

    // MARK: - Public Methods

    @Test
    func usesTheExpectedSharedAnimationDuration() {
        #expect(
            VideoEditorPlaybackFocusTransitionPolicy.animationDuration == 0.24
        )
    }

    @Test
    func usesTheExpectedSharedStageBounce() {
        #expect(
            VideoEditorPlaybackFocusTransitionPolicy.animationExtraBounce == 0.04
        )
    }

}

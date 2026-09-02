import Testing
@testable import FloeCore

@Suite("Background visual surface policy")
struct BackgroundVisualSurfacePolicyTests {
    @Test("manual PiP close survives scene cycles until a new run")
    func dismissalLifetime() {
        var policy = BackgroundVisualSurfacePolicy()
        #expect(policy.allowsVisualSurface(for: .pictureInPicture))
        #expect(policy.allowsVisualSurface(for: .screenShare))

        policy.userClosedPictureInPicture()
        #expect(!policy.allowsVisualSurface(for: .pictureInPicture))
        #expect(!policy.allowsVisualSurface(for: .screenShare))
        #expect(!policy.allowsVisualSurface(for: .standard))

        // Foreground/background transitions deliberately do not mutate the
        // policy. Only a genuinely new run restores PiP eligibility.
        #expect(policy.isSuppressedForCurrentBatch)
        policy.beginNewRun()
        #expect(policy.allowsVisualSurface(for: .pictureInPicture))
    }
}

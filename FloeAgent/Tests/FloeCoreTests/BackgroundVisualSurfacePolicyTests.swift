import Foundation
import Testing
@testable import FloeCore

@Suite("Background visual surface policy")
struct BackgroundVisualSurfacePolicyTests {
    @Test("manual PiP close survives scene cycles and concurrent runs")
    func dismissalLifetime() {
        var policy = BackgroundVisualSurfacePolicy()
        let first = UUID(), concurrent = UUID(), next = UUID()
        policy.beginRun(first, currentlyActiveRunIDs: [])
        #expect(policy.allowsVisualSurface(for: .pictureInPicture))
        #expect(policy.allowsVisualSurface(for: .screenShare))

        policy.userClosedPictureInPicture()
        #expect(!policy.allowsVisualSurface(for: .pictureInPicture))
        #expect(!policy.allowsVisualSurface(for: .screenShare))
        #expect(!policy.allowsVisualSurface(for: .standard))

        policy.recordSceneTransition(at: Date(timeIntervalSince1970: 10))
        #expect(policy.isSuppressedForCurrentBatch)
        policy.beginRun(concurrent, currentlyActiveRunIDs: [first])
        #expect(!policy.allowsVisualSurface(for: .pictureInPicture))
        policy.finishRun(first)
        policy.finishRun(concurrent)
        policy.beginRun(next, currentlyActiveRunIDs: [])
        #expect(policy.allowsVisualSurface(for: .pictureInPicture))
    }

    @Test("cold restored run preserves persisted dismissal")
    func coldRestore() throws {
        let runID = UUID()
        var original = BackgroundVisualSurfacePolicy()
        original.beginRun(runID, currentlyActiveRunIDs: [])
        original.userClosedPictureInPicture()
        var policy = try JSONDecoder().decode(
            BackgroundVisualSurfacePolicy.self,
            from: JSONEncoder().encode(original)
        )
        policy.beginRun(runID, currentlyActiveRunIDs: [])
        #expect(policy.isSuppressedForCurrentBatch)
        #expect(!policy.allowsVisualSurface(for: .pictureInPicture))
    }
}

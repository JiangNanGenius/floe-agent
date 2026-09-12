import SwiftUI
import Testing

@testable import VideoEditorKit

@Suite("EditorAppearanceEditingCoordinatorTests")
struct EditorAppearanceEditingCoordinatorTests {

    // MARK: - Public Methods

    @Test
    @MainActor
    func setAdjustsAppliesAndRemovesTheAdjustsTool() {
        var video = Video.mock

        let didApply = EditorAppearanceEditingCoordinator.setAdjusts(
            .init(brightness: 0.2, contrast: 0.15, saturation: 0.1),
            in: &video
        )

        #expect(didApply == true)
        #expect(abs(video.colorAdjusts.brightness - 0.2) < 0.0001)
        #expect(video.isAppliedTool(for: .adjusts) == true)

        let didReset = EditorAppearanceEditingCoordinator.setAdjusts(
            .init(),
            in: &video
        )

        #expect(didReset == true)
        #expect(video.colorAdjusts == .init())
        #expect(video.isAppliedTool(for: .adjusts) == false)
    }

    @Test
    @MainActor
    func restoreDefaultAdjustsKeepsTheToolAppliedUntilDeferredCleanup() {
        var video = Video.mock
        video.colorAdjusts = .init(brightness: 0.2)
        video.appliedTool(for: .adjusts)

        let didRestore = EditorAppearanceEditingCoordinator.restoreDefaultAdjusts(
            in: &video
        )

        #expect(didRestore == true)
        #expect(video.colorAdjusts == .init())
        #expect(video.isAppliedTool(for: .adjusts) == true)
    }

    @Test
    @MainActor
    func configurationVideoOmitsInactiveFramesButPreservesActiveOnes() {
        var video = Video.mock
        video.videoFrames = .init(
            scaleValue: 0,
            frameColor: .red
        )

        let inactiveConfigurationVideo = EditorAppearanceEditingCoordinator.configurationVideo(
            from: video,
            frames: .init(
                scaleValue: 0,
                frameColor: .red
            )
        )
        let activeConfigurationVideo = EditorAppearanceEditingCoordinator.configurationVideo(
            from: video,
            frames: .init(
                scaleValue: 0.35,
                frameColor: .red
            )
        )

        #expect(inactiveConfigurationVideo.videoFrames == nil)
        #expect(abs((activeConfigurationVideo.videoFrames?.scaleValue ?? 0) - 0.35) < 0.0001)
        #expect(
            SystemColorPalette.matches(
                activeConfigurationVideo.videoFrames?.frameColor ?? .clear,
                .red
            )
        )
    }

}

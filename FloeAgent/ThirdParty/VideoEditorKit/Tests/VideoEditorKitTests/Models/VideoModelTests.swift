import SwiftUI
import Testing

@testable import VideoEditorKit

@MainActor
@Suite("VideoModelTests", .serialized)
struct VideoModelTests {

    // MARK: - Public Methods

    @Test
    func updateRateKeepsSelectedSourceRangeIntact() {
        var video = Video.mock
        video.rangeDuration = 2...8
        video.rate = 1

        video.updateRate(2)

        #expect(abs(video.rangeDuration.lowerBound - 2) < 0.0001)
        #expect(abs(video.rangeDuration.upperBound - 8) < 0.0001)
        #expect(video.rate == 2)
    }

    @Test
    func resetRangeDurationUsesOriginalDurationForCurrentRate() {
        var video = Video.mock

        video.updateRate(2)
        video.resetRangeDuration()

        #expect(abs(video.timelineDuration - 125) < 0.0001)
        #expect(abs(video.rangeDuration.lowerBound) < 0.0001)
        #expect(abs(video.rangeDuration.upperBound - 250) < 0.0001)
    }

    @Test
    func outputRangeDurationReflectsCurrentRate() {
        var video = Video.mock
        video.rangeDuration = 20...80

        video.updateRate(2)

        #expect(abs(video.outputRangeDuration.lowerBound - 10) < 0.0001)
        #expect(abs(video.outputRangeDuration.upperBound - 40) < 0.0001)
        #expect(abs(video.totalDuration - 30) < 0.0001)
    }

    @Test
    func timelineTimePreservingSourcePositionUsesSameSourceTimeAfterRateChange() {
        var video = Video.mock
        let previousRate = video.rate

        video.updateRate(2)

        let remappedTime = video.timelineTimePreservingSourcePosition(60, fromRate: previousRate)

        #expect(abs(remappedTime - 30) < 0.0001)
    }

    @Test
    func rotateCyclesBackToZeroAfterFullTurn() {
        var video = Video.mock

        video.rotate()
        video.rotate()
        video.rotate()
        video.rotate()

        #expect(video.rotation == 0)
    }

    @Test
    func appliedToolAddsOnlyOnce() {
        var video = Video.mock

        video.appliedTool(for: .adjusts)
        video.appliedTool(for: .adjusts)

        #expect(video.toolsApplied == [ToolEnum.adjusts.rawValue])
    }

    @Test
    func removeToolClearsPreviouslyAppliedTool() {
        var video = Video.mock
        video.appliedTool(for: .presets)

        video.removeTool(for: .presets)

        #expect(video.isAppliedTool(for: .presets) == false)
        #expect(video.toolsApplied.isEmpty)
    }

    @Test
    func thumbnailImagePreservesOriginalImageSize() {
        let sourceImage = UIGraphicsImageRenderer(
            size: CGSize(width: 400, height: 200)
        ).image { context in
            UIColor.red.setFill()
            context.fill(
                CGRect(
                    origin: .zero,
                    size: CGSize(width: 400, height: 200)
                )
            )
        }

        let thumbnailImage = ThumbnailImage(image: sourceImage)

        #expect(abs((thumbnailImage.image?.size.width ?? 0) - 400) < 0.0001)
        #expect(abs((thumbnailImage.image?.size.height ?? 0) - 200) < 0.0001)
    }

}

import CoreGraphics
import Foundation

public struct EditorCropEditingState: Equatable, Sendable {

    // MARK: - Public Properties

    public static let initial = Self()

    public var freeformRect: VideoEditingConfiguration.FreeformRect?
    public var socialVideoDestination: VideoEditingConfiguration.SocialVideoDestination?
    public var showsSafeAreaOverlay = false
    public var canvasSnapshot = VideoCanvasSnapshot.initial

    // MARK: - Initializer

    public init(
        freeformRect: VideoEditingConfiguration.FreeformRect? = nil,
        socialVideoDestination: VideoEditingConfiguration.SocialVideoDestination? = nil,
        showsSafeAreaOverlay: Bool = false,
        canvasSnapshot: VideoCanvasSnapshot = .initial
    ) {
        self.freeformRect = freeformRect
        self.socialVideoDestination = socialVideoDestination
        self.showsSafeAreaOverlay = showsSafeAreaOverlay
        self.canvasSnapshot = canvasSnapshot
    }

}

public enum EditorCropEditingCoordinator {

    // MARK: - Public Methods

    public static func selectingCropFormat(
        _ preset: VideoCropFormatPreset,
        from state: EditorCropEditingState,
        referenceSize: CGSize
    ) -> EditorCropEditingState? {
        var nextState = state

        switch preset {
        case .original:
            nextState = .initial
        case .vertical9x16,
            .square1x1,
            .portrait4x5,
            .landscape16x9:
            guard let nextCropRect = preset.makeFreeformRect(for: referenceSize) else { return nil }

            nextState.freeformRect = nextCropRect
            nextState.socialVideoDestination = nil
            nextState.showsSafeAreaOverlay = false

            if preset.isSocialVideoPreset {
                nextState.canvasSnapshot.preset = .story
            } else {
                nextState.canvasSnapshot.preset = canvasPreset(
                    for: preset,
                    socialVideoDestination: nextState.socialVideoDestination
                )
            }

            nextState.canvasSnapshot.transform = .identity
            nextState.canvasSnapshot.showsSafeAreaOverlay = false
        }

        return nextState
    }

    public static func selectingSocialVideoDestination(
        _ destination: VideoEditingConfiguration.SocialVideoDestination,
        from state: EditorCropEditingState,
        referenceSize: CGSize
    ) -> EditorCropEditingState? {
        guard
            let cropRect = VideoCropFormatPreset.vertical9x16.makeFreeformRect(
                for: referenceSize
            )
        else {
            return nil
        }

        var nextState = state

        nextState.socialVideoDestination = destination
        nextState.freeformRect = cropRect
        nextState.showsSafeAreaOverlay = false
        nextState.canvasSnapshot.preset = .social(platform: destination.socialPlatform)
        nextState.canvasSnapshot.showsSafeAreaOverlay = false

        return nextState
    }

    public static func selectedCropPreset(
        from state: EditorCropEditingState,
        referenceSize: CGSize?
    ) -> VideoCropFormatPreset {
        VideoEditingPresentationStateResolver.selectedCropPreset(
            canvasPreset: state.canvasSnapshot.preset,
            freeformRect: state.freeformRect,
            referenceSize: referenceSize
        )
    }

    // MARK: - Private Methods

    private static func canvasPreset(
        for preset: VideoCropFormatPreset,
        socialVideoDestination: VideoEditingConfiguration.SocialVideoDestination?
    ) -> VideoCanvasPreset {
        VideoCanvasPreset.fromLegacySelection(
            preset: preset,
            socialVideoDestination: socialVideoDestination
        )
    }

}

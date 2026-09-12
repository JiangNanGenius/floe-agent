import CoreGraphics
import Foundation

public struct ResolvedVideoEditingPresentationState: Equatable, Sendable {

    // MARK: - Public Properties

    public let cropFreeformRect: VideoEditingConfiguration.FreeformRect?
    public let socialVideoDestination: VideoEditingConfiguration.SocialVideoDestination?
    public let showsSafeAreaOverlay: Bool
    public let canvasSnapshot: VideoCanvasSnapshot
    public let selectedAudioTrack: VideoEditingConfiguration.SelectedTrack
    public let selectedTool: ToolEnum?

    // MARK: - Initializer

    public init(
        cropFreeformRect: VideoEditingConfiguration.FreeformRect?,
        socialVideoDestination: VideoEditingConfiguration.SocialVideoDestination?,
        showsSafeAreaOverlay: Bool,
        canvasSnapshot: VideoCanvasSnapshot,
        selectedAudioTrack: VideoEditingConfiguration.SelectedTrack,
        selectedTool: ToolEnum?
    ) {
        self.cropFreeformRect = cropFreeformRect
        self.socialVideoDestination = socialVideoDestination
        self.showsSafeAreaOverlay = showsSafeAreaOverlay
        self.canvasSnapshot = canvasSnapshot
        self.selectedAudioTrack = selectedAudioTrack
        self.selectedTool = selectedTool
    }

}

public enum VideoEditingPresentationStateResolver {

    // MARK: - Private Properties

    private enum Constants {
        static let numericTolerance = 0.001
    }

    // MARK: - Public Methods

    public static func resolve(
        from configuration: VideoEditingConfiguration,
        referenceSize: CGSize,
        hasRecordedAudioTrack: Bool,
        enabledTools: Set<ToolEnum>
    ) async -> ResolvedVideoEditingPresentationState {
        ResolvedVideoEditingPresentationState(
            cropFreeformRect: configuration.crop.freeformRect,
            socialVideoDestination: configuration.presentation.socialVideoDestination,
            showsSafeAreaOverlay: false,
            canvasSnapshot: await resolveCanvasSnapshot(
                from: configuration,
                referenceSize: referenceSize
            ),
            selectedAudioTrack: resolveSelectedAudioTrack(
                from: configuration,
                hasRecordedAudioTrack: hasRecordedAudioTrack
            ),
            selectedTool: resolveSelectedTool(
                from: configuration,
                enabledTools: enabledTools
            )
        )
    }

    public static func selectedCropPreset(
        canvasPreset: VideoCanvasPreset,
        freeformRect: VideoEditingConfiguration.FreeformRect?,
        referenceSize: CGSize?
    ) -> VideoCropFormatPreset {
        let canvasPreset = selectedCropPreset(from: canvasPreset)
        if canvasPreset != .original {
            return canvasPreset
        }

        guard let referenceSize else {
            return .original
        }

        for preset in VideoCropFormatPreset.editorPresets where preset != .original {
            if preset.matches(freeformRect, in: referenceSize) {
                return preset
            }
        }

        return .original
    }

    public static func selectedCropPreset(
        from canvasPreset: VideoCanvasPreset
    ) -> VideoCropFormatPreset {
        switch canvasPreset {
        case .original,
            .free:
            .original
        case .social,
            .story:
            .vertical9x16
        case .facebookPost:
            .portrait4x5
        case .custom(let width, let height):
            switch normalizedPresetKey(width: width, height: height) {
            case "1:1":
                .square1x1
            case "16:9":
                .landscape16x9
            case "9:16":
                .vertical9x16
            case "4:5":
                .portrait4x5
            default:
                .original
            }
        }
    }

    public static func resolveCanvasSnapshot(
        from configuration: VideoEditingConfiguration,
        referenceSize: CGSize
    ) async -> VideoCanvasSnapshot {
        if configuration.canvas.snapshot != .initial {
            return configuration.canvas.snapshot
        }

        var snapshot = VideoCanvasSnapshot(
            preset: VideoCanvasPreset.fromLegacySelection(
                preset: selectedLegacyCropPreset(
                    from: configuration.crop.freeformRect,
                    referenceSize: referenceSize
                ),
                socialVideoDestination: configuration.presentation.socialVideoDestination
            ),
            showsSafeAreaOverlay: false
        )

        guard referenceSize.width > 0, referenceSize.height > 0 else {
            return snapshot
        }

        let mappingActor = VideoCanvasMappingActor()
        let resolvedPreset = mappingActor.resolvePreset(
            snapshot.preset,
            naturalSize: referenceSize,
            freeCanvasSize: snapshot.freeCanvasSize
        )

        snapshot.freeCanvasSize = resolvedPreset.exportSize
        snapshot.transform = mappingActor.snapshotTransform(
            fromLegacyFreeformRect: configuration.crop.freeformRect,
            referenceSize: referenceSize,
            exportSize: resolvedPreset.exportSize
        )

        return snapshot
    }

    public static func selectedLegacyCropPreset(
        from freeformRect: VideoEditingConfiguration.FreeformRect?,
        referenceSize: CGSize
    ) -> VideoCropFormatPreset {
        guard referenceSize.width > 0, referenceSize.height > 0 else {
            return freeformRect == nil ? .original : .vertical9x16
        }

        guard let freeformRect else { return .original }
        guard
            let cropRect = VideoCropPreviewLayout.resolvedGeometry(
                freeformRect: freeformRect,
                in: referenceSize
            )?.sourceRect,
            cropRect.width > 0,
            cropRect.height > 0
        else {
            return .vertical9x16
        }

        let aspectRatio = cropRect.width / cropRect.height

        for preset in VideoCropFormatPreset.editorPresets {
            guard let presetAspectRatio = preset.aspectRatio else { continue }
            if abs(aspectRatio - presetAspectRatio) < Constants.numericTolerance {
                return preset
            }
        }

        return .vertical9x16
    }

    // MARK: - Private Methods

    private static func resolveSelectedAudioTrack(
        from configuration: VideoEditingConfiguration,
        hasRecordedAudioTrack: Bool
    ) -> VideoEditingConfiguration.SelectedTrack {
        let selectedTrack = configuration.audio.selectedTrack

        if selectedTrack == .recorded, !hasRecordedAudioTrack {
            return .video
        }

        return selectedTrack
    }

    private static func resolveSelectedTool(
        from configuration: VideoEditingConfiguration,
        enabledTools: Set<ToolEnum>
    ) -> ToolEnum? {
        guard let selectedTool = configuration.presentation.selectedTool else {
            return nil
        }

        guard selectedTool != .transcript else {
            return nil
        }

        guard enabledTools.contains(selectedTool) else {
            return nil
        }

        return selectedTool
    }

    private static func normalizedPresetKey(
        width: Int,
        height: Int
    ) -> String {
        let reducedRatio = reducedAspectRatio(width: width, height: height)
        return "\(reducedRatio.width):\(reducedRatio.height)"
    }

    private static func reducedAspectRatio(
        width: Int,
        height: Int
    ) -> (width: Int, height: Int) {
        let divisor = greatestCommonDivisor(width, height)
        guard divisor > 0 else { return (width, height) }
        return (width / divisor, height / divisor)
    }

    private static func greatestCommonDivisor(
        _ lhs: Int,
        _ rhs: Int
    ) -> Int {
        var lhs = abs(lhs)
        var rhs = abs(rhs)

        while rhs != 0 {
            let remainder = lhs % rhs
            lhs = rhs
            rhs = remainder
        }

        return lhs
    }

}

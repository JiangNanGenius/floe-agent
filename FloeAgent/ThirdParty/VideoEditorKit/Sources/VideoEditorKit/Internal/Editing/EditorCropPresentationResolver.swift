//
//  EditorCropPresentationResolver.swift
//  VideoEditorKit
//
//  Created by Codex on 01.04.2026.
//

import CoreGraphics
import Foundation

struct EditorCropPresentationSummary: Equatable, Sendable {

    // MARK: - Public Properties

    let selectedPreset: VideoCropFormatPreset
    let socialVideoDestination: VideoEditingConfiguration.SocialVideoDestination?
    let shouldShowCropOverlay: Bool
    let isCropOverlayInteractive: Bool
    let shouldUseCropPresetSpotlight: Bool
    let shouldShowCropPresetBadge: Bool
    let shouldShowCanvasResetButton: Bool
    let badgeTitle: String
    let badgeDimension: String
    let badgeText: String

    // MARK: - Public Methods

    func isCropFormatSelected(_ preset: VideoCropFormatPreset) -> Bool {
        selectedPreset == preset
    }

    func isSocialVideoDestinationSelected(
        _ destination: VideoEditingConfiguration.SocialVideoDestination
    ) -> Bool {
        socialVideoDestination == destination
    }

}

struct EditorCropPresentationResolver {

    // MARK: - Public Methods

    static func makeSummary(
        state: EditorCropEditingState,
        video: Video?,
        fallbackContainerSize: CGSize,
        isPlaybackFocused: Bool = false
    ) -> EditorCropPresentationSummary {
        let referenceSize = resolvedCropReferenceSize(
            for: video,
            fallbackContainerSize: fallbackContainerSize
        )
        let selectedPreset = EditorCropEditingCoordinator.selectedCropPreset(
            from: state,
            referenceSize: referenceSize
        )
        let shouldShowCropOverlay =
            state.freeformRect != nil
            || state.canvasSnapshot.isIdentity == false
        let isCropOverlayInteractive = true
        let shouldShowCropPresetBadge =
            !isPlaybackFocused
            && selectedPreset != .original
        let shouldUseCropPresetSpotlight = selectedPreset != .original
        let shouldShowCanvasResetButton =
            !isPlaybackFocused
            && state.canvasSnapshot.transform.shouldShowResetButton

        return .init(
            selectedPreset: selectedPreset,
            socialVideoDestination: state.socialVideoDestination,
            shouldShowCropOverlay: shouldShowCropOverlay,
            isCropOverlayInteractive: isCropOverlayInteractive,
            shouldUseCropPresetSpotlight: shouldUseCropPresetSpotlight,
            shouldShowCropPresetBadge: shouldShowCropPresetBadge,
            shouldShowCanvasResetButton: shouldShowCanvasResetButton,
            badgeTitle: badgeTitle(for: selectedPreset),
            badgeDimension: badgeDimension(
                for: selectedPreset,
                video: video
            ),
            badgeText: badgeText(
                for: selectedPreset,
                video: video
            )
        )
    }

    // MARK: - Private Methods

    private static func resolvedCropReferenceSize(
        for video: Video?,
        fallbackContainerSize: CGSize
    ) -> CGSize? {
        guard let video else { return nil }
        return VideoEditorLayoutResolver.resolvedCropReferenceSize(
            for: video,
            fallbackContainerSize: fallbackContainerSize
        )
    }

    private static func badgeTitle(
        for preset: VideoCropFormatPreset
    ) -> String {
        return preset.title
    }

    private static func badgeText(
        for preset: VideoCropFormatPreset,
        video: Video?
    ) -> String {
        let title = badgeTitle(for: preset)
        let dimension = badgeDimension(
            for: preset,
            video: video
        )

        return "\(title) • \(dimension)"
    }

    private static func badgeDimension(
        for preset: VideoCropFormatPreset,
        video: Video?
    ) -> String {
        switch preset {
        case .original:
            let sourceSize = resolvedSourceSizeForBadge(from: video)
            guard sourceSize.width > 0, sourceSize.height > 0 else { return preset.dimensionTitle }
            return "\(Int(sourceSize.width.rounded()))x\(Int(sourceSize.height.rounded()))"
        case .vertical9x16,
            .square1x1,
            .portrait4x5,
            .landscape16x9:
            return preset.dimensionTitle
        }
    }

    private static func resolvedSourceSizeForBadge(
        from video: Video?
    ) -> CGSize {
        if let presentationSize = video?.presentationSize,
            presentationSize.width > 0,
            presentationSize.height > 0
        {
            return presentationSize
        }

        if let geometrySize = video?.geometrySize,
            geometrySize.width > 0,
            geometrySize.height > 0
        {
            return geometrySize
        }

        return .zero
    }

}

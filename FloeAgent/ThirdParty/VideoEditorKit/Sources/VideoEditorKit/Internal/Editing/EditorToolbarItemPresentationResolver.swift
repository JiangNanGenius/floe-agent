//
//  EditorToolbarItemPresentationResolver.swift
//  VideoEditorKit
//
//  Created by Codex on 07.04.2026.
//

import Foundation

struct EditorToolbarItemPresentation: Equatable, Sendable {

    // MARK: - Public Properties

    let title: String
    let image: String
    let subtitle: String?
    let isApplied: Bool

}

struct EditorToolbarItemDraftPresentationState: Equatable {

    // MARK: - Public Properties

    let selectedTool: ToolEnum?
    let draftState: EditorToolDraftState
    let selectedPreset: VideoCropFormatPreset
    let transcriptDraftDocument: TranscriptDocument?

}

struct EditorToolbarItemPresentationResolver {

    // MARK: - Public Methods

    static func resolve(
        for tool: ToolEnum,
        video: Video?,
        cropPresentationSummary: EditorCropPresentationSummary?,
        transcriptDocument: TranscriptDocument?,
        draftPresentationState: EditorToolbarItemDraftPresentationState? = nil
    ) -> EditorToolbarItemPresentation {
        if let draftPresentation = draftPresentation(
            for: tool,
            video: video,
            cropPresentationSummary: cropPresentationSummary,
            transcriptDocument: transcriptDocument,
            draftPresentationState: draftPresentationState
        ) {
            return draftPresentation
        }

        let isApplied = committedAppliedState(
            for: tool,
            video: video,
            cropPresentationSummary: cropPresentationSummary,
            transcriptDocument: transcriptDocument
        )

        return .init(
            title: tool.title,
            image: tool.image,
            subtitle: isApplied
                ? subtitle(
                    for: tool,
                    video: video,
                    cropPresentationSummary: cropPresentationSummary,
                    transcriptDocument: transcriptDocument
                )
                : nil,
            isApplied: isApplied
        )
    }

    // MARK: - Private Methods

    private static func draftPresentation(
        for tool: ToolEnum,
        video: Video?,
        cropPresentationSummary: EditorCropPresentationSummary?,
        transcriptDocument: TranscriptDocument?,
        draftPresentationState: EditorToolbarItemDraftPresentationState?
    ) -> EditorToolbarItemPresentation? {
        guard
            let draftPresentationState,
            draftPresentationState.selectedTool == tool
        else {
            return nil
        }

        switch tool {
        case .speed:
            return speedDraftPresentation(
                draftPresentationState.draftState.speedDraft
            )
        case .presets:
            return presetsDraftPresentation(
                draftPresentationState,
                cropPresentationSummary: cropPresentationSummary
            )
        case .audio:
            return audioDraftPresentation(
                draftPresentationState.draftState.audioDraft,
                video: video
            )
        case .adjusts:
            return adjustsDraftPresentation(
                draftPresentationState.draftState.adjustsDraft
            )
        case .transcript:
            return transcriptDraftPresentation(
                draftPresentationState.transcriptDraftDocument,
                transcriptDocument: transcriptDocument
            )
        case .cut:
            return nil
        }
    }

    private static func speedDraftPresentation(
        _ speedDraft: Double
    ) -> EditorToolbarItemPresentation {
        let rate = Float(speedDraft)
        let isApplied = abs(Double(rate) - 1.0) > 0.001

        return .init(
            title: ToolEnum.speed.title,
            image: ToolEnum.speed.image,
            subtitle: isApplied ? VideoEditorStrings.toolbarSpeedSubtitle(rate) : nil,
            isApplied: isApplied
        )
    }

    private static func presetsDraftPresentation(
        _ draftPresentationState: EditorToolbarItemDraftPresentationState,
        cropPresentationSummary: EditorCropPresentationSummary?
    ) -> EditorToolbarItemPresentation? {
        let presetDraft = draftPresentationState.draftState.presetDraft

        guard presetDraft != draftPresentationState.selectedPreset else {
            return nil
        }

        let isApplied = presetDraft != .original

        return .init(
            title: ToolEnum.presets.title,
            image: ToolEnum.presets.image,
            subtitle: isApplied
                ? presetsDraftSubtitle(
                    presetDraft,
                    cropPresentationSummary: cropPresentationSummary
                )
                : nil,
            isApplied: isApplied
        )
    }

    private static func audioDraftPresentation(
        _ audioDraft: AudioToolDraft,
        video: Video?
    ) -> EditorToolbarItemPresentation {
        let hasRecordedAudio = video?.audio != nil
        let isApplied =
            hasRecordedAudio
            || abs(audioDraft.videoVolume - 1.0) > 0.001
            || (hasRecordedAudio && abs(audioDraft.recordedVolume - 1.0) > 0.001)

        return .init(
            title: ToolEnum.audio.title,
            image: ToolEnum.audio.image,
            subtitle: isApplied ? audioDraftSubtitle(audioDraft, hasRecordedAudio: hasRecordedAudio) : nil,
            isApplied: isApplied
        )
    }

    private static func adjustsDraftPresentation(
        _ adjustsDraft: ColorAdjusts
    ) -> EditorToolbarItemPresentation {
        let appliedAdjustmentsCount = adjustsDraft.appliedAdjustmentsCount
        let isApplied = appliedAdjustmentsCount > 0

        return .init(
            title: ToolEnum.adjusts.title,
            image: ToolEnum.adjusts.image,
            subtitle: isApplied
                ? VideoEditorStrings.toolbarAdjustmentsCount(appliedAdjustmentsCount)
                : nil,
            isApplied: isApplied
        )
    }

    private static func transcriptDraftPresentation(
        _ draftDocument: TranscriptDocument?,
        transcriptDocument: TranscriptDocument?
    ) -> EditorToolbarItemPresentation? {
        guard draftDocument != transcriptDocument else { return nil }

        return .init(
            title: ToolEnum.transcript.title,
            image: ToolEnum.transcript.image,
            subtitle: transcriptSubtitle(draftDocument),
            isApplied: draftDocument != nil
        )
    }

    private static func subtitle(
        for tool: ToolEnum,
        video: Video?,
        cropPresentationSummary: EditorCropPresentationSummary?,
        transcriptDocument: TranscriptDocument?
    ) -> String? {
        switch tool {
        case .speed:
            speedSubtitle(video)
        case .presets:
            presetsSubtitle(cropPresentationSummary)
        case .audio:
            audioSubtitle(video)
        case .adjusts:
            adjustsSubtitle(video)
        case .transcript:
            transcriptSubtitle(transcriptDocument)
        case .cut:
            nil
        }
    }

    private static func committedAppliedState(
        for tool: ToolEnum,
        video: Video?,
        cropPresentationSummary: EditorCropPresentationSummary?,
        transcriptDocument: TranscriptDocument?
    ) -> Bool {
        switch tool {
        case .cut:
            committedCutAppliedState(video)
        case .speed:
            committedSpeedAppliedState(video)
        case .presets:
            committedPresetsAppliedState(cropPresentationSummary)
        case .audio:
            committedAudioAppliedState(video)
        case .adjusts:
            committedAdjustsAppliedState(video)
        case .transcript:
            transcriptDocument != nil
        }
    }

    private static func speedSubtitle(
        _ video: Video?
    ) -> String? {
        guard let rate = video?.rate else { return nil }
        return VideoEditorStrings.toolbarSpeedSubtitle(rate)
    }

    private static func committedCutAppliedState(
        _ video: Video?
    ) -> Bool {
        guard let video else { return false }

        return
            video.rangeDuration.lowerBound > 0
            || abs(video.rangeDuration.upperBound - video.originalDuration) > 0.001
    }

    private static func committedSpeedAppliedState(
        _ video: Video?
    ) -> Bool {
        guard let rate = video?.rate else { return false }
        return abs(Double(rate) - 1.0) > 0.001
    }

    private static func presetsSubtitle(
        _ cropPresentationSummary: EditorCropPresentationSummary?
    ) -> String? {
        guard let cropPresentationSummary else { return nil }

        if cropPresentationSummary.selectedPreset == .original {
            return VideoEditorStrings.toolCustomCrop
        }

        return "\(cropPresentationSummary.badgeTitle) \(cropPresentationSummary.badgeDimension)"
    }

    private static func committedPresetsAppliedState(
        _ cropPresentationSummary: EditorCropPresentationSummary?
    ) -> Bool {
        guard let cropPresentationSummary else { return false }

        return
            cropPresentationSummary.selectedPreset != .original
            || cropPresentationSummary.shouldShowCropOverlay
            || cropPresentationSummary.shouldShowCanvasResetButton
            || cropPresentationSummary.socialVideoDestination != nil
    }

    private static func presetsDraftSubtitle(
        _ preset: VideoCropFormatPreset,
        cropPresentationSummary: EditorCropPresentationSummary?
    ) -> String {
        if cropPresentationSummary?.selectedPreset == preset {
            return presetsSubtitle(cropPresentationSummary) ?? "\(preset.title) \(preset.dimensionTitle)"
        }

        return "\(preset.title) \(preset.dimensionTitle)"
    }

    private static func audioSubtitle(
        _ video: Video?
    ) -> String? {
        guard let video else { return nil }

        if let recordedAudio = video.audio {
            return percentageString(for: recordedAudio.volume)
        }

        return percentageString(for: video.volume)
    }

    private static func audioDraftSubtitle(
        _ audioDraft: AudioToolDraft,
        hasRecordedAudio: Bool
    ) -> String {
        if audioDraft.selectedTrack == .recorded, hasRecordedAudio {
            return percentageString(for: audioDraft.recordedVolume)
        }

        return percentageString(for: audioDraft.videoVolume)
    }

    private static func committedAudioAppliedState(
        _ video: Video?
    ) -> Bool {
        guard let video else { return false }

        return video.audio != nil || abs(video.volume - 1.0) > 0.001
    }

    private static func adjustsSubtitle(
        _ video: Video?
    ) -> String? {
        guard let appliedAdjustmentsCount = video?.colorAdjusts.appliedAdjustmentsCount else {
            return nil
        }

        guard appliedAdjustmentsCount > 0 else { return nil }
        return VideoEditorStrings.toolbarAdjustmentsCount(appliedAdjustmentsCount)
    }

    private static func committedAdjustsAppliedState(
        _ video: Video?
    ) -> Bool {
        guard let appliedAdjustmentsCount = video?.colorAdjusts.appliedAdjustmentsCount else {
            return false
        }

        return appliedAdjustmentsCount > 0
    }

    private static func transcriptSubtitle(
        _ transcriptDocument: TranscriptDocument?
    ) -> String? {
        guard let transcriptDocument else { return nil }

        return
            "\(transcriptDocument.overlayPosition.abbreviation)/\(transcriptDocument.overlaySize.abbreviation)"
    }

    private static func percentageString(
        for value: Float
    ) -> String {
        VideoEditorStrings.toolbarPercentage(value)
    }

}

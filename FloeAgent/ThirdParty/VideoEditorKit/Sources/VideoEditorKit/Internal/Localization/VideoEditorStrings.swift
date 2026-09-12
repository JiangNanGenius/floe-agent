import Foundation

enum VideoEditorStrings {

    // MARK: - Common

    static var apply: String { localized("common.apply", defaultValue: "Apply") }
    static var available: String { localized("common.available", defaultValue: "Available") }
    static var cancel: String { localized("common.cancel", defaultValue: "Cancel") }
    static var close: String { localized("common.close", defaultValue: "Close") }
    static var copy: String { localized("common.copy", defaultValue: "Copy") }
    static var editSegment: String { localized("common.edit-segment", defaultValue: "Edit Segment") }
    static var edited: String { localized("common.edited", defaultValue: "Edited") }
    static var export: String { localized("common.export", defaultValue: "Export") }
    static var locked: String { localized("common.locked", defaultValue: "Locked") }
    static var notSelected: String { localized("common.not-selected", defaultValue: "Not selected") }
    static var ok: String { localized("common.ok", defaultValue: "OK") }
    static var premium: String { localized("common.premium", defaultValue: "Premium") }
    static var ready: String { localized("common.ready", defaultValue: "Ready") }
    static var reset: String { localized("common.reset", defaultValue: "Reset") }
    static var revert: String { localized("common.revert", defaultValue: "Revert") }
    static var retry: String { localized("common.retry", defaultValue: "Retry") }
    static var save: String { localized("common.save", defaultValue: "Save") }
    static var selected: String { localized("common.selected", defaultValue: "Selected") }
    static var tryAgain: String { localized("common.try-again", defaultValue: "Try Again") }
    static var unavailable: String { localized("common.unavailable", defaultValue: "Unavailable") }

    // MARK: - Editor

    static var addVideoTitle: String {
        localized("editor.shell.idle.title", defaultValue: "Add a video to start editing")
    }

    static var addVideoMessage: String {
        localized("editor.shell.idle.message", defaultValue: "Choose a clip to begin a new editing session.")
    }

    static var importingVideoTitle: String {
        localized("editor.shell.loading.title", defaultValue: "Importing video...")
    }

    static var importingVideoMessage: String {
        localized(
            "editor.shell.loading.message",
            defaultValue: "The editor will open as soon as the selected clip is ready."
        )
    }

    static var unableToOpenVideoTitle: String {
        localized("editor.shell.failed.title", defaultValue: "Unable to open the selected video")
    }

    static var resetTransform: String {
        localized("editor.player.reset-transform", defaultValue: "Reset transform")
    }

    static var playerUnknownState: String {
        localized("editor.player.unknown", defaultValue: "Add a video to start editing")
    }

    static var playerFailedState: String {
        localized("editor.player.failed", defaultValue: "Failed to open video")
    }

    static var previewVideoMissingTitle: String {
        localized("editor.preview.missing.title", defaultValue: "Preview video not found")
    }

    static var previewVideoMissingDescription: String {
        localized("editor.preview.missing.message", defaultValue: "Missing resource: preview.mp4")
    }

    static var discardUnsavedChanges: String {
        localized("editor.unsaved-changes.discard", defaultValue: "Discard")
    }

    static var unsavedChangesAlertTitle: String {
        localized("editor.unsaved-changes.title", defaultValue: "Unsaved Changes")
    }

    static var unsavedChangesAlertMessage: String {
        localized(
            "editor.unsaved-changes.message",
            defaultValue: "There are changes that have not been saved yet. Would you like to save them?"
        )
    }

    // MARK: - Export

    static var exportVideoTitle: String {
        localized("editor.export.title", defaultValue: "Export Video")
    }

    static var exportAlertTitle: String {
        localized("editor.export.alert.title", defaultValue: "Unable to export video")
    }

    static var exportChooseQualityMessage: String {
        localized(
            "editor.export.quality.message",
            defaultValue: "Choose the output quality for the rendered file."
        )
    }

    static var exportButtonInProgressHint: String {
        localized("editor.export.button.hint.in-progress", defaultValue: "Export in progress.")
    }

    static var exportButtonReadyHint: String {
        localized("editor.export.button.hint.ready", defaultValue: "Double-tap to export the video.")
    }

    static var exportQualityPremiumHint: String {
        localized(
            "editor.export.quality.hint.premium",
            defaultValue: "Double-tap to learn how to unlock this export quality."
        )
    }

    static var exportQualitySelectHint: String {
        localized(
            "editor.export.quality.hint.select",
            defaultValue: "Double-tap to select this export quality."
        )
    }

    static var exportingPrefix: String {
        localized("editor.export.button.exporting-prefix", defaultValue: "Exporting")
    }

    static var savingVideoExportButtonTitle: String {
        localized("editor.export.button.saving-video", defaultValue: "Saving video...")
    }

    static var exportButtonFallbackMessage: String {
        localized(
            "editor.export.error.fallback",
            defaultValue: "The video could not be exported right now. Please try again."
        )
    }

    static var exporterUnexpectedError: String {
        localized(
            "editor.export.error.unexpected",
            defaultValue: "An unexpected error happened while preparing the export."
        )
    }

    static var exporterCancelledError: String {
        localized(
            "editor.export.error.cancelled",
            defaultValue: "The export was cancelled before the final video was generated."
        )
    }

    static var exporterBackgroundInterruptionError: String {
        localized(
            "editor.export.error.background-interruption",
            defaultValue:
                "The export was cancelled because the app moved to the background. Please try again."
        )
    }

    static var exporterCannotCreateSessionError: String {
        localized(
            "editor.export.error.cannot-create-session",
            defaultValue: "The export session could not be created for this video."
        )
    }

    static var exporterFailedError: String {
        localized(
            "editor.export.error.failed",
            defaultValue: "The video could not be exported. Please try again."
        )
    }

    static func exportButtonTitle(progressText: String) -> String {
        "\(exportingPrefix) \(progressText)"
    }

    static func exportQualityAccessibilityLabel(
        title: String,
        isBlocked: Bool
    ) -> String {
        guard isBlocked else { return title }
        return "\(title), \(premium.lowercased())"
    }

    static func exportButtonAccessibilityValue(progress: Double, isExporting: Bool) -> String {
        guard isExporting else { return ready }
        return "\(Int(progress * 100)) \(localized("editor.export.percent-complete", defaultValue: "percent complete"))"
    }

    // MARK: - Tools

    static var toolCut: String { localized("editor.tool.cut.title", defaultValue: "Cut") }
    static var toolSpeed: String { localized("editor.tool.speed.title", defaultValue: "Speed") }
    static var toolPresets: String { localized("editor.tool.presets.title", defaultValue: "Presets") }
    static var toolAudio: String { localized("editor.tool.audio.title", defaultValue: "Audio") }
    static var toolTranscript: String { localized("editor.tool.transcript.title", defaultValue: "Transcript") }
    static var toolAdjusts: String { localized("editor.tool.adjusts.title", defaultValue: "Adjusts") }

    static var toolLockedHint: String {
        localized("editor.tool.hint.locked", defaultValue: "Double-tap to learn how to unlock this tool.")
    }

    static var toolOpenHint: String {
        localized("editor.tool.hint.open", defaultValue: "Double-tap to open this editing tool.")
    }

    static var toolCustomCrop: String {
        localized("editor.tool.presets.custom-crop", defaultValue: "Custom crop")
    }

    static func toolButtonAccessibilityLabel(
        label: String,
        isBlocked: Bool
    ) -> String {
        guard isBlocked else { return label }
        return "\(label), \(locked.lowercased())"
    }

    static func toolButtonAccessibilityValue(
        subtitle: String?,
        isApplied: Bool,
        isBlocked: Bool
    ) -> String {
        if isBlocked {
            return unavailable
        }

        guard isApplied else {
            return available
        }

        guard let subtitle, subtitle.isEmpty == false else {
            return localized("editor.tool.value.applied", defaultValue: "Applied")
        }

        return "\(localized("editor.tool.value.applied", defaultValue: "Applied")), \(subtitle)"
    }

    static func toolbarAdjustmentsCount(_ count: Int) -> String {
        if count == 1 {
            return "\(count) \(localized("editor.toolbar.adjustments.single", defaultValue: "adjustment"))"
        }

        return "\(count) \(localized("editor.toolbar.adjustments.plural", defaultValue: "adjustments"))"
    }

    static func toolbarSpeedSubtitle(_ rate: Float) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(1))))x"
    }

    static func toolbarPercentage(_ value: Float) -> String {
        "\(Int((Double(value) * 100).rounded()))%"
    }

    static func transcriptOriginalPrefix(_ text: String) -> String {
        "\(localized("editor.transcript.original-prefix", defaultValue: "Original:")) \(text)"
    }

    // MARK: - Transcript

    static var transcriptCreateTitle: String {
        localized("editor.transcript.idle.title", defaultValue: "Create a transcript")
    }

    static var transcriptCreateMessage: String {
        localized(
            "editor.transcript.idle.message",
            defaultValue: "Generate timed text from the current source video and edit it segment by segment."
        )
    }

    static var transcriptUnavailableTitle: String {
        localized("editor.transcript.unavailable.title", defaultValue: "Transcription unavailable")
    }

    static var transcriptUnavailableMessage: String {
        localized(
            "editor.transcript.unavailable.message",
            defaultValue: "No transcription provider is configured for this editor session."
        )
    }

    static var transcriptLoadingTitle: String {
        localized("editor.transcript.loading.title", defaultValue: "Transcribing audio...")
    }

    static var transcriptLoadingMessage: String {
        localized(
            "editor.transcript.loading.message",
            defaultValue: "The transcript will appear here as soon as the provider returns the timed segments."
        )
    }

    static var transcriptLayoutSection: String {
        localized("editor.transcript.layout-section", defaultValue: "Layout")
    }

    static var transcriptNoneTitle: String {
        localized("editor.transcript.empty.title", defaultValue: "No transcript yet")
    }

    static var transcriptNoneMessage: String {
        localized(
            "editor.transcript.empty.message",
            defaultValue: "Run the transcription provider to populate timed segments for this video."
        )
    }

    static var transcriptPosition: String {
        localized("editor.transcript.position", defaultValue: "Position")
    }

    static var transcriptSize: String {
        localized("editor.transcript.size", defaultValue: "Size")
    }

    static var transcriptSectionTitle: String {
        localized("editor.transcript.section-title", defaultValue: "Transcription")
    }

    static var transcriptUnableToTranscribeTitle: String {
        localized("editor.transcript.failed.title", defaultValue: "Unable to transcribe")
    }

    static var transcriptSegmentUnavailableTitle: String {
        localized("editor.transcript.segment-unavailable.title", defaultValue: "Segment unavailable")
    }

    static var transcriptSegmentUnavailableMessage: String {
        localized(
            "editor.transcript.segment-unavailable.message",
            defaultValue: "This transcript segment is no longer available."
        )
    }

    static var transcriptSegmentPlaceholder: String {
        localized("editor.transcript.segment.placeholder", defaultValue: "Transcript segment")
    }

    static var transcriptProviderInvalidSource: String {
        localized(
            "editor.transcript.error.invalid-source",
            defaultValue: "The current video source could not be used for transcription."
        )
    }

    static var transcriptProviderEmptyResult: String {
        localized(
            "editor.transcript.error.empty-result",
            defaultValue: "The transcription provider returned no timed segments."
        )
    }

    static var transcriptProviderCancelled: String {
        localized(
            "editor.transcript.error.cancelled",
            defaultValue: "The transcription request was cancelled before it finished."
        )
    }

    static var transcriptRetry: String {
        localized("editor.transcript.retry", defaultValue: "Transcribe")
    }

    static var transcriptRetryFailure: String {
        localized("editor.transcript.retry-failure", defaultValue: "Try again")
    }

    static var transcriptPreviousRequestFailed: String {
        localized(
            "editor.transcript.previous-request-failed",
            defaultValue: "The previous transcription request failed."
        )
    }

    // MARK: - Crop Presets

    static var cropPresetHelper: String {
        localized(
            "editor.crop.helper",
            defaultValue:
                "Choose a preset. Original also supports drag and pinch. Double tap or use reset to go back to full."
        )
    }

    static var cropOriginalTitle: String { localized("editor.crop.original.title", defaultValue: "Original") }
    static var cropOriginalSubtitle: String {
        localized("editor.crop.original.subtitle", defaultValue: "Keeps the imported framing")
    }
    static var cropOriginalDimension: String { localized("editor.crop.original.dimension", defaultValue: "Source") }
    static var cropSocialTitle: String { localized("editor.crop.social.title", defaultValue: "Social") }
    static var cropSocialSubtitle: String {
        localized("editor.crop.social.subtitle", defaultValue: "Instagram Reels, TikTok, Shorts")
    }
    static var cropSquareTitle: String { localized("editor.crop.square.title", defaultValue: "Square") }
    static var cropSquareSubtitle: String {
        localized("editor.crop.square.subtitle", defaultValue: "Square posts and covers")
    }
    static var cropPortraitTitle: String { localized("editor.crop.portrait.title", defaultValue: "Portrait") }
    static var cropPortraitSubtitle: String {
        localized("editor.crop.portrait.subtitle", defaultValue: "Portrait feed posts")
    }
    static var cropLandscapeTitle: String { localized("editor.crop.landscape.title", defaultValue: "Landscape") }
    static var cropLandscapeSubtitle: String {
        localized("editor.crop.landscape.subtitle", defaultValue: "Landscape players and embeds")
    }

    // MARK: - Canvas

    static var canvasOriginal: String { localized("editor.canvas.original", defaultValue: "Original") }
    static var canvasFree: String { localized("editor.canvas.free", defaultValue: "Free") }
    static var canvasCustom: String { localized("editor.canvas.custom", defaultValue: "Custom") }
    static var canvasStory: String { localized("editor.canvas.story", defaultValue: "Story") }
    static var canvasFacebookPost: String {
        localized("editor.canvas.facebook-post", defaultValue: "Facebook Post")
    }

    // MARK: - Audio

    static var audioTrack: String { localized("editor.audio.track", defaultValue: "Track") }
    static var selectedTrackVideo: String {
        localized("editor.audio.track.video", defaultValue: "Video")
    }
    static var selectedTrackRecorded: String {
        localized("editor.audio.track.recorded", defaultValue: "Recorded")
    }

    // MARK: - Safe Area

    static var safeAreaUniversalTitle: String {
        localized("editor.safe-area.universal.title", defaultValue: "Universal Social Safe Zone")
    }

    static var platformInstagram: String {
        localized("editor.platform.instagram", defaultValue: "Instagram Reels & Stories")
    }

    static var platformTikTok: String {
        localized("editor.platform.tiktok", defaultValue: "TikTok")
    }

    static var platformYouTubeShorts: String {
        localized("editor.platform.youtube-shorts", defaultValue: "YouTube Shorts")
    }

    static var destinationInstagramReels: String {
        localized("editor.destination.instagram-reels", defaultValue: "Instagram Reels")
    }

    static var destinationTikTok: String {
        localized("editor.destination.tiktok", defaultValue: "TikTok")
    }

    static var destinationYouTubeShorts: String {
        localized("editor.destination.youtube-shorts", defaultValue: "YouTube Shorts")
    }

    static var destinationInstagramShort: String {
        localized("editor.destination.instagram-short", defaultValue: "Instagram")
    }

    static var destinationTikTokShort: String {
        localized("editor.destination.tiktok-short", defaultValue: "TikTok")
    }

    static var destinationShortsShort: String {
        localized("editor.destination.shorts-short", defaultValue: "Shorts")
    }

    // MARK: - Adjusts

    static var brightness: String { localized("editor.adjusts.brightness", defaultValue: "Brightness") }
    static var contrast: String { localized("editor.adjusts.contrast", defaultValue: "Contrast") }
    static var saturation: String { localized("editor.adjusts.saturation", defaultValue: "Saturation") }

    // MARK: - Accessibility

    static var trimStart: String { localized("editor.accessibility.trim-start", defaultValue: "Trim start") }
    static var trimEnd: String { localized("editor.accessibility.trim-end", defaultValue: "Trim end") }
    static var unknown: String { localized("common.unknown", defaultValue: "unknown") }

    // MARK: - Transcript Overlays

    static var transcriptPositionTop: String {
        localized("editor.transcript.position.top", defaultValue: "Top")
    }

    static var transcriptPositionCenter: String {
        localized("editor.transcript.position.center", defaultValue: "Center")
    }

    static var transcriptPositionBottom: String {
        localized("editor.transcript.position.bottom", defaultValue: "Bottom")
    }

    static var transcriptPositionTopAbbreviation: String {
        localized("editor.transcript.position.top.abbreviation", defaultValue: "T")
    }

    static var transcriptPositionCenterAbbreviation: String {
        localized("editor.transcript.position.center.abbreviation", defaultValue: "C")
    }

    static var transcriptPositionBottomAbbreviation: String {
        localized("editor.transcript.position.bottom.abbreviation", defaultValue: "B")
    }

    static var transcriptSizeSmall: String {
        localized("editor.transcript.size.small", defaultValue: "Small")
    }

    static var transcriptSizeMedium: String {
        localized("editor.transcript.size.medium", defaultValue: "Medium")
    }

    static var transcriptSizeLarge: String {
        localized("editor.transcript.size.large", defaultValue: "Large")
    }

    static var transcriptSizeSmallAbbreviation: String {
        localized("editor.transcript.size.small.abbreviation", defaultValue: "S")
    }

    static var transcriptSizeMediumAbbreviation: String {
        localized("editor.transcript.size.medium.abbreviation", defaultValue: "M")
    }

    static var transcriptSizeLargeAbbreviation: String {
        localized("editor.transcript.size.large.abbreviation", defaultValue: "L")
    }

    // MARK: - Quality

    static var qualityOriginalTitle: String {
        localized("editor.quality.original.title", defaultValue: "Original")
    }

    static var qualityLowTitle: String { localized("editor.quality.low.title", defaultValue: "qHD - 480") }
    static var qualityMediumTitle: String { localized("editor.quality.medium.title", defaultValue: "HD - 720p") }
    static var qualityHighTitle: String {
        localized("editor.quality.high.title", defaultValue: "Full HD - 1080p")
    }

    static var qualityOriginalSubtitle: String {
        localized(
            "editor.quality.original.subtitle",
            defaultValue: "Preserves the source resolution and frame rate"
        )
    }

    static var qualityLowSubtitle: String {
        localized("editor.quality.low.subtitle", defaultValue: "Fast loading and small size, low quality")
    }

    static var qualityMediumSubtitle: String {
        localized("editor.quality.medium.subtitle", defaultValue: "Optimal size to quality ratio")
    }

    static var qualityHighSubtitle: String {
        localized("editor.quality.high.subtitle", defaultValue: "Ideal for publishing on social networks")
    }

    // MARK: - Errors

    static var extractionInvalidVideoSource: String {
        localized(
            "editor.error.extraction.invalid-source",
            defaultValue: "The transcription source must be a local video file.")
    }

    static var extractionAudioTrackNotFound: String {
        localized(
            "editor.error.extraction.audio-track-not-found",
            defaultValue: "The selected video does not contain an extractable audio track.")
    }

    static var extractionUnableToCreateSession: String {
        localized(
            "editor.error.extraction.unable-to-create-session",
            defaultValue: "Unable to create an audio extraction export session.")
    }

    static var whisperInvalidAudioURL: String {
        localized(
            "editor.error.whisper.invalid-audio-url", defaultValue: "The audio file URL must reference a local file.")
    }

    static var whisperInvalidResponse: String {
        localized(
            "editor.error.whisper.invalid-response",
            defaultValue: "The transcription service returned an invalid response.")
    }

    static func whisperHTTPError(_ statusCode: Int) -> String {
        "\(localized("editor.error.whisper.http-prefix", defaultValue: "The transcription service returned HTTP")) \(statusCode)."
    }

    static var whisperEmptyResponse: String {
        localized(
            "editor.error.whisper.empty-response",
            defaultValue: "The transcription service returned an empty response body.")
    }

    // MARK: - Private Methods

    private static func localized(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        String(
            localized: key,
            defaultValue: defaultValue,
            bundle: .module
        )
    }

}

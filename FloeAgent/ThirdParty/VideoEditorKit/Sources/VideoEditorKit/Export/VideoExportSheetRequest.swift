import Foundation

/// Lightweight source-video metadata that lets the external export sheet render immediately.
public struct VideoExportSheetSourceMetadata: Equatable, Sendable {

    // MARK: - Public Properties

    public let width: Double
    public let height: Double
    public let duration: Double

    // MARK: - Initializer

    public init(
        width: Double,
        height: Double,
        duration: Double
    ) {
        self.width = width
        self.height = height
        self.duration = duration
    }

}

/// Input used by the external export sheet to render a video outside `VideoEditorView`.
public struct VideoExportSheetRequest: Equatable, Identifiable, Sendable {

    // MARK: - Public Properties

    /// Stable identity for SwiftUI sheet presentation.
    public let id: String
    /// Local playable source video URL.
    public let sourceVideoURL: URL
    /// Optional source metadata used to present export choices without reloading the asset first.
    public let sourceMetadata: VideoExportSheetSourceMetadata?
    /// Editing snapshot that should be applied during export.
    public let editingConfiguration: VideoEditingConfiguration
    /// Ready-to-use video that can satisfy an `.original` export without rendering again.
    public let preparedOriginalExportVideo: ExportedVideo?
    /// Editing snapshot used to create `preparedOriginalExportVideo`.
    public let preparedOriginalExportEditingConfiguration: VideoEditingConfiguration?

    // MARK: - Initializer

    public init(
        id: String? = nil,
        sourceVideoURL: URL,
        sourceMetadata: VideoExportSheetSourceMetadata? = nil,
        editingConfiguration: VideoEditingConfiguration = .initial,
        preparedOriginalExportVideo: ExportedVideo? = nil,
        preparedOriginalExportEditingConfiguration: VideoEditingConfiguration? = nil
    ) {
        self.id = id ?? sourceVideoURL.absoluteString
        self.sourceVideoURL = sourceVideoURL
        self.sourceMetadata = sourceMetadata
        self.editingConfiguration = editingConfiguration
        self.preparedOriginalExportVideo = preparedOriginalExportVideo
        self.preparedOriginalExportEditingConfiguration = preparedOriginalExportVideo.map { _ in
            preparedOriginalExportEditingConfiguration ?? editingConfiguration
        }
    }

}

/// Public preparation result used by advanced export-sheet integrations.
public enum VideoExportPreparationResult: Equatable, Sendable {

    // MARK: - Public Properties

    case render
    case usePreparedVideo(ExportedVideo)
    case cancelled

}

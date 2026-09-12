//
//  VideoEditorManualSaveRenderer.swift
//  VideoEditorKit
//
//  Created by Codex on 26.04.2026.
//

import AVFoundation
import Foundation
import SwiftUI

struct VideoEditorManualSaveRenderer {

    struct Dependencies {

        // MARK: - Public Properties

        static let live = Self(
            renderEditedVideo: { video, editingConfiguration, onProgress in
                try await VideoEditor.startRender(
                    video: video,
                    editingConfiguration: editingConfiguration,
                    renderIntent: .saveNative(sourceFrameRate: nil),
                    onProgress: onProgress
                )
            },
            loadSavedMetadata: { url in
                await ExportedVideo.load(from: url)
            },
            makeThumbnailData: { savedVideoURL in
                let asset = AVURLAsset(url: savedVideoURL)
                let image = await asset.generateImage(
                    at: 0,
                    maximumSize: CGSize(width: 720, height: 720),
                    requiresExactFrame: true
                )

                return image?.jpegData(compressionQuality: 0.85)
            }
        )

        let renderEditedVideo:
            @Sendable (Video, VideoEditingConfiguration, VideoEditor.ProgressHandler?) async throws -> URL
        let loadSavedMetadata: @Sendable (URL) async -> ExportedVideo
        let makeThumbnailData: @Sendable (URL) async -> Data?

    }

    // MARK: - Private Properties

    private let dependencies: Dependencies

    // MARK: - Initializer

    init(_ dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    // MARK: - Public Methods

    func save(
        video: Video,
        editingConfiguration: VideoEditingConfiguration,
        originalVideoURL: URL,
        onProgress: VideoEditor.ProgressHandler? = nil
    ) async throws -> SavedVideo {
        let savedVideoURL = try await dependencies.renderEditedVideo(
            video,
            editingConfiguration,
            onProgress
        )
        let metadata = await dependencies.loadSavedMetadata(savedVideoURL)
        let thumbnailData = await dependencies.makeThumbnailData(savedVideoURL)

        return SavedVideo(
            savedVideoURL,
            originalVideoURL: originalVideoURL,
            editingConfiguration: editingConfiguration,
            thumbnailData: thumbnailData,
            metadata: metadata
        )
    }

}

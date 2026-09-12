//
//  VideoEditingThumbnailTimestampResolver.swift
//  VideoEditorKit
//
//  Created by Codex on 02.04.2026.
//

import Foundation

enum VideoEditingThumbnailTimestampResolver {

    // MARK: - Public Methods

    static func sourceAssetTimestamp(
        for editingConfiguration: VideoEditingConfiguration,
        originalDuration: Double
    ) -> Double {
        let resolvedOriginalDuration =
            originalDuration.isFinite
            ? max(originalDuration, 0)
            : 0
        return editingConfiguration.trim.lowerBound.clamped(
            to: 0...resolvedOriginalDuration
        )
    }

    static func exportedAssetTimestamp(
        for editingConfiguration: VideoEditingConfiguration,
        exportedDuration: Double
    ) -> Double {
        _ = editingConfiguration
        _ = exportedDuration
        return 0
    }

}

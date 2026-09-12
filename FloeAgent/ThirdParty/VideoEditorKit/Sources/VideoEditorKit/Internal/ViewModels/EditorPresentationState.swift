//
//  EditorPresentationState.swift
//  VideoEditorKit
//
//  Created by Codex on 01.04.2026.
//

import Observation

@MainActor
@Observable
final class EditorPresentationState {

    // MARK: - Public Properties

    var selectedAudioTrack: VideoEditingConfiguration.SelectedTrack = .video
    var showVideoQualitySheet = false
    var showRecordView = false
    var selectedTool: ToolEnum?

    private(set) var editingConfigurationRevision = 0

    // MARK: - Public Methods

    func markEditingConfigurationChanged() {
        editingConfigurationRevision += 1
    }

}

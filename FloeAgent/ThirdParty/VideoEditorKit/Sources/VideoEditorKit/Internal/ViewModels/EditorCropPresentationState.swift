//
//  EditorCropPresentationState.swift
//  VideoEditorKit
//
//  Created by Codex on 01.04.2026.
//

import Observation

@MainActor
@Observable
final class EditorCropPresentationState {

    // MARK: - Public Properties

    var freeformRect: VideoEditingConfiguration.FreeformRect?
    var socialVideoDestination: VideoEditingConfiguration.SocialVideoDestination?
    var showsSafeAreaOverlay = false
    var canvasEditorState = VideoCanvasEditorState()

    var editingState: EditorCropEditingState {
        EditorCropEditingState(
            freeformRect: freeformRect,
            socialVideoDestination: socialVideoDestination,
            showsSafeAreaOverlay: showsSafeAreaOverlay,
            canvasSnapshot: canvasEditorState.snapshot()
        )
    }

    var shouldShowCropOverlay: Bool {
        freeformRect != nil || canvasEditorState.snapshot().isIdentity == false
    }

    // MARK: - Public Methods

    func apply(_ state: EditorCropEditingState) {
        freeformRect = state.freeformRect
        socialVideoDestination = state.socialVideoDestination
        showsSafeAreaOverlay = state.showsSafeAreaOverlay
        canvasEditorState.restore(state.canvasSnapshot)
    }

}

//
//  HostEditorCropEditingCoordinator.swift
//  VideoEditorKit
//
//  Created by Codex on 08.04.2026.
//

struct HostEditorCropEditingCoordinator {

    // MARK: - Public Methods

    static func shouldApplyPresetTool(
        for video: Video,
        state: EditorCropEditingState
    ) -> Bool {
        let hasRotation =
            abs(video.rotation.truncatingRemainder(dividingBy: 360))
            > 0.001
        let hasMirror = video.isMirror
        let hasFreeformRect = state.freeformRect != nil
        let hasCanvasState = state.canvasSnapshot.isIdentity == false

        return hasRotation || hasMirror || hasFreeformRect || hasCanvasState
    }

}

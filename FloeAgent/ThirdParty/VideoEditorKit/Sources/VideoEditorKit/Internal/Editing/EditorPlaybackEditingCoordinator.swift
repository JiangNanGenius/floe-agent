//
//  EditorPlaybackEditingCoordinator.swift
//  VideoEditorKit
//
//  Created by Codex on 01.04.2026.
//

struct EditorPlaybackEditingCoordinator {

    // MARK: - Public Methods

    static func minimumTrimDuration(
        for originalDuration: Double
    ) -> Double {
        min(1, max(originalDuration, 0))
    }

    static func updateRate(
        _ rate: Float,
        in video: inout Video,
        selectedTool: ToolEnum?
    ) {
        video.updateRate(rate)
        applySelectedToolIfNeeded(selectedTool, to: &video)
    }

    static func syncCutToolState(
        in video: inout Video,
        tolerance: Double
    ) {
        let isTrimmed =
            video.rangeDuration.lowerBound > 0
            || abs(video.rangeDuration.upperBound - video.originalDuration) > tolerance

        if isTrimmed {
            video.appliedTool(for: .cut)
        } else {
            video.removeTool(for: .cut)
        }
    }

    static func resetCut(
        in video: inout Video
    ) {
        video.resetRangeDuration()
        video.removeTool(for: .cut)
    }

    static func restoreDefaultCut(
        in video: inout Video
    ) {
        video.resetRangeDuration()
    }

    static func resetRate(
        in video: inout Video
    ) {
        video.resetRate()
        syncSpeedToolState(for: &video)
    }

    static func restoreDefaultRate(
        in video: inout Video
    ) {
        video.resetRate()
    }

    static func rotate(
        in video: inout Video,
        selectedTool: ToolEnum?
    ) {
        video.rotate()
        applySelectedToolIfNeeded(selectedTool, to: &video)
    }

    static func setRotation(
        _ rotation: Double,
        in video: inout Video,
        selectedTool: ToolEnum?
    ) -> Bool {
        guard video.rotation != rotation else { return false }

        video.rotation = rotation
        applySelectedToolIfNeeded(selectedTool, to: &video)
        return true
    }

    static func toggleMirror(
        in video: inout Video,
        selectedTool: ToolEnum?
    ) {
        video.isMirror.toggle()
        applySelectedToolIfNeeded(selectedTool, to: &video)
    }

    // MARK: - Private Methods

    private static func applySelectedToolIfNeeded(
        _ selectedTool: ToolEnum?,
        to video: inout Video
    ) {
        guard let selectedTool else { return }
        video.appliedTool(for: selectedTool)
    }

    private static func syncSpeedToolState(
        for video: inout Video
    ) {
        if abs(Double(video.rate) - 1.0) > 0.0001 {
            video.appliedTool(for: .speed)
        } else {
            video.removeTool(for: .speed)
        }
    }

}

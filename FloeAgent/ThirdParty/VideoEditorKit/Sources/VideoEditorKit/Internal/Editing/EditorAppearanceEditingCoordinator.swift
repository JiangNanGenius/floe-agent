//
//  EditorAppearanceEditingCoordinator.swift
//  VideoEditorKit
//
//  Created by Codex on 01.04.2026.
//

import SwiftUI

struct EditorAppearanceEditingCoordinator {

    // MARK: - Public Methods

    static func framesState(
        from video: Video?
    ) -> VideoFrames {
        video?.videoFrames ?? VideoFrames()
    }

    static func setFrameColor(
        _ color: Color,
        in frames: inout VideoFrames
    ) -> Bool {
        guard !SystemColorPalette.matches(frames.frameColor, color) else {
            return false
        }

        frames.frameColor = color
        return true
    }

    static func setFrameScale(
        _ scaleValue: Double,
        in frames: inout VideoFrames
    ) -> Bool {
        guard abs(frames.scaleValue - scaleValue) > 0.0001 else {
            return false
        }

        frames.scaleValue = scaleValue
        return true
    }

    static func syncFrames(
        _ frames: VideoFrames,
        into video: inout Video
    ) {
        video.videoFrames = frames
    }

    static func configurationVideo(
        from video: Video,
        frames: VideoFrames
    ) -> Video {
        var configurationVideo = video
        configurationVideo.videoFrames = frames.isActive ? frames : nil
        return configurationVideo
    }

    static func setAdjusts(
        _ adjusts: ColorAdjusts,
        in video: inout Video
    ) -> Bool {
        guard video.colorAdjusts != adjusts else { return false }

        video.colorAdjusts = adjusts

        if adjusts.isIdentity {
            video.removeTool(for: .adjusts)
        } else {
            video.appliedTool(for: .adjusts)
        }

        return true
    }

    static func restoreDefaultAdjusts(
        in video: inout Video
    ) -> Bool {
        guard video.colorAdjusts != .init() else { return false }
        video.colorAdjusts = .init()
        return true
    }

}

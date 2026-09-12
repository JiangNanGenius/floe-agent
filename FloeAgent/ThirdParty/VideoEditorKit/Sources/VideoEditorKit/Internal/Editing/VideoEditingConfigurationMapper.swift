//
//  VideoEditingConfigurationMapper.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 27.03.2026.
//

import Foundation
import SwiftUI

enum VideoEditingConfigurationMapper {

    // MARK: - Public Methods

    static func makeConfiguration(
        from video: Video,
        freeformRect: VideoEditingConfiguration.FreeformRect? = nil,
        canvasSnapshot: VideoCanvasSnapshot = .initial,
        selectedAudioTrack: VideoEditingConfiguration.SelectedTrack = .video,
        transcriptFeatureState: TranscriptFeaturePersistenceState = .idle,
        transcriptDocument: TranscriptDocument? = nil,
        selectedTool: ToolEnum? = nil,
        socialVideoDestination: VideoEditingConfiguration.SocialVideoDestination? = nil,
        showsSafeAreaGuides: Bool = false,
        currentTimelineTime: Double? = nil
    ) -> VideoEditingConfiguration {
        VideoEditingConfiguration(
            trim: .init(
                lowerBound: video.rangeDuration.lowerBound,
                upperBound: video.rangeDuration.upperBound
            ),
            playback: .init(
                rate: video.rate,
                videoVolume: video.volume,
                currentTimelineTime: currentTimelineTime
            ),
            crop: .init(
                rotationDegrees: video.rotation,
                isMirrored: video.isMirror,
                freeformRect: freeformRect
            ),
            canvas: .init(
                snapshot: canvasSnapshot
            ),
            adjusts: .init(
                brightness: video.colorAdjusts.brightness,
                contrast: video.colorAdjusts.contrast,
                saturation: video.colorAdjusts.saturation
            ),
            frame: .init(
                scaleValue: video.videoFrames?.scaleValue ?? 0,
                colorToken: video.videoFrames.map {
                    SerializedColorCodec.encode($0.frameColor)
                }
            ),
            audio: .init(
                recordedClip: video.audio.map {
                    .init(
                        url: $0.url,
                        duration: $0.duration,
                        volume: $0.volume
                    )
                },
                selectedTrack: selectedAudioTrack
            ),
            transcript: .init(
                featureState: persistedTranscriptFeatureState(
                    transcriptFeatureState,
                    document: transcriptDocument
                ),
                document: transcriptDocument
            ),
            presentation: .init(
                persistedPresentationTool(
                    from: selectedTool
                ),
                socialVideoDestination: socialVideoDestination,
                showsSafeAreaGuides: false
            )
        )
    }

    static func apply(
        _ configuration: VideoEditingConfiguration,
        to video: inout Video
    ) {
        video.rangeDuration = configuration.trim.lowerBound...configuration.trim.upperBound
        video.updateRate(configuration.playback.rate)
        video.setVolume(configuration.playback.videoVolume)
        video.rotation = configuration.crop.rotationDegrees
        video.isMirror = configuration.crop.isMirrored
        video.colorAdjusts = ColorAdjusts(
            brightness: configuration.adjusts.brightness,
            contrast: configuration.adjusts.contrast,
            saturation: configuration.adjusts.saturation
        )

        if configuration.frame.scaleValue > 0 {
            video.videoFrames = VideoFrames(
                scaleValue: configuration.frame.scaleValue,
                frameColor: SerializedColorCodec.decode(
                    configuration.frame.colorToken,
                    fallback: Color(uiColor: .systemBackground)
                )
            )
        } else {
            video.videoFrames = nil
        }

        video.audio = configuration.audio.recordedClip.map {
            Audio(
                url: $0.url,
                duration: $0.duration,
                volume: $0.volume
            )
        }

        video.toolsApplied = restoredToolsApplied(
            from: configuration,
            video: video
        )
    }

    static func selectedAudioTrack(
        from configuration: VideoEditingConfiguration
    ) -> VideoEditingConfiguration.SelectedTrack {
        configuration.audio.selectedTrack
    }

    private static func restoredToolsApplied(
        from configuration: VideoEditingConfiguration,
        video: Video
    ) -> [Int] {
        var restoredTools = [ToolEnum]()

        let isTrimmed =
            video.rangeDuration.lowerBound > 0
            || abs(video.rangeDuration.upperBound - video.originalDuration) > 0.001
        if isTrimmed {
            restoredTools.append(.cut)
        }

        if abs(video.rate - 1.0) > 0.001 {
            restoredTools.append(.speed)
        }

        let hasRotation = abs(video.rotation.truncatingRemainder(dividingBy: 360)) > 0.001
        let hasMirror = video.isMirror
        let hasFreeformRect = configuration.crop.freeformRect != nil
        let hasCanvasState = configuration.canvas.snapshot.isIdentity == false
        if hasRotation || hasMirror || hasFreeformRect || hasCanvasState {
            restoredTools.append(.presets)
        }

        let hasRecordedAudio = video.audio != nil
        let hasAdjustedVideoVolume = abs(video.volume - 1.0) > 0.001
        if hasRecordedAudio || hasAdjustedVideoVolume {
            restoredTools.append(.audio)
        }

        if !video.colorAdjusts.isIdentity {
            restoredTools.append(.adjusts)
        }

        if configuration.transcript.featureState == .loaded, configuration.transcript.document != nil {
            restoredTools.append(.transcript)
        }

        return restoredTools.map(\.rawValue)
    }

    private static func persistedPresentationTool(
        from selectedTool: ToolEnum?
    ) -> ToolEnum? {
        guard selectedTool != .transcript else {
            return nil
        }

        return selectedTool
    }

    private static func persistedTranscriptFeatureState(
        _ featureState: TranscriptFeaturePersistenceState,
        document: TranscriptDocument?
    ) -> TranscriptFeaturePersistenceState {
        guard document != nil else {
            return .idle
        }

        return .loaded
    }

}

private enum SerializedColorCodec {

    // MARK: - Public Methods

    static func encode(
        _ color: Color
    ) -> String {
        if let paletteToken = paletteToken(for: color) {
            return "palette:\(paletteToken)"
        }

        return "rgba:\(rgbaHex(for: color))"
    }

    static func decode(
        _ token: String?,
        fallback: Color
    ) -> Color {
        guard let token else { return fallback }

        if token.hasPrefix("palette:") {
            let paletteID = String(token.dropFirst("palette:".count))
            return paletteColor(for: paletteID) ?? fallback
        }

        if token.hasPrefix("rgba:") {
            let rgba = String(token.dropFirst("rgba:".count))
            return color(fromRGBAHex: rgba) ?? fallback
        }

        return fallback
    }

    // MARK: - Private Methods

    private static func paletteToken(
        for color: Color
    ) -> String? {
        SystemColorPalette.frameColors.first(where: { SystemColorPalette.matches($0.color, color) })?.id
    }

    private static func paletteColor(
        for paletteID: String
    ) -> Color? {
        SystemColorPalette.frameColors.first(where: { $0.id == paletteID })?.color
    }

    private static func rgbaHex(
        for color: Color
    ) -> String {
        let resolvedColor = UIColor(color).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .light)
        )

        guard let components = resolvedColor.cgColor.components else {
            return "FFFFFFFF"
        }

        let rgbaComponents: [CGFloat]

        switch components.count {
        case 2:
            rgbaComponents = [components[0], components[0], components[0], components[1]]
        case 4:
            rgbaComponents = components
        default:
            return "FFFFFFFF"
        }

        return
            rgbaComponents
            .map { component in
                let value = Int(round(component * 255))
                let hex = String(value, radix: 16, uppercase: true)
                return hex.count == 1 ? "0\(hex)" : hex
            }
            .joined()
    }

    private static func color(
        fromRGBAHex rgbaHex: String
    ) -> Color? {
        guard rgbaHex.count == 8 else { return nil }

        let scanner = Scanner(string: rgbaHex)
        var rawValue: UInt64 = 0

        guard scanner.scanHexInt64(&rawValue) else { return nil }

        let red = CGFloat((rawValue & 0xFF00_0000) >> 24) / 255
        let green = CGFloat((rawValue & 0x00FF_0000) >> 16) / 255
        let blue = CGFloat((rawValue & 0x0000_FF00) >> 8) / 255
        let alpha = CGFloat(rawValue & 0x0000_00FF) / 255

        return Color(
            uiColor: UIColor(
                red: red,
                green: green,
                blue: blue,
                alpha: alpha
            )
        )
    }

}

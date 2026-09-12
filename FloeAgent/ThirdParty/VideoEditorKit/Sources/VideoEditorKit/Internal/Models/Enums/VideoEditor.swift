//
//  VideoEditor.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import AVFoundation
import CoreImage
import Foundation
import SwiftUI

enum VideoEditor {

    typealias ProgressHandler = @Sendable (_ progress: Double) async -> Void

    // MARK: - Public Methods

    static func startRender(
        video: Video,
        editingConfiguration: VideoEditingConfiguration = .initial,
        videoQuality: VideoQuality,
        watermark: VideoWatermarkRenderRequest? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws -> URL {
        try await startRender(
            video: video,
            editingConfiguration: editingConfiguration,
            renderIntent: .export(videoQuality),
            watermark: watermark,
            onProgress: onProgress
        )
    }

    static func startRender(
        video: Video,
        editingConfiguration: VideoEditingConfiguration = .initial,
        renderIntent: VideoRenderIntent,
        watermark: VideoWatermarkRenderRequest? = nil,
        onProgress: ProgressHandler? = nil
    ) async throws -> URL {
        let resolvedRenderIntent = await resolvedRenderIntent(
            renderIntent,
            asset: video.asset
        )
        let exportProfile = resolvedExportProfile(
            for: video.presentationSize,
            editingConfiguration: editingConfiguration,
            renderIntent: resolvedRenderIntent
        )
        let adjusts = Helpers.createColorAdjustsFilters(
            colorAdjusts: video.colorAdjusts
        )

        let usesAdjustsStage = !adjusts.isEmpty
        let usesTranscriptStage = requiresTranscriptStage(editingConfiguration)
        let usesCanvasStage = requiresCanvasStage(editingConfiguration)
        let usesWatermarkStage = watermark != nil
        let integratesAdjustsIntoBaseStage: Bool

        if usesAdjustsStage {
            integratesAdjustsIntoBaseStage = await canIntegrateAdjustsIntoBaseRender(
                video: video,
                editingConfiguration: editingConfiguration,
                exportProfile: exportProfile
            )
        } else {
            integratesAdjustsIntoBaseStage = false
        }
        let renderStages = resolvedRenderStages(
            usesAdjustsStage: usesAdjustsStage && integratesAdjustsIntoBaseStage == false,
            usesTranscriptStage: usesTranscriptStage,
            usesCropStage: usesCanvasStage,
            usesWatermarkStage: usesWatermarkStage
        )

        var intermediateOutputURLs = [URL]()

        do {
            let url = try await resizeAndLayerOperation(
                video: video,
                editingConfiguration: editingConfiguration,
                exportProfile: exportProfile,
                integratedAdjusts: integratesAdjustsIntoBaseStage ? adjusts : [],
                progressRange: progressRange(
                    for: .base,
                    activeStages: renderStages
                ),
                onProgress: onProgress
            )
            trackIntermediateOutput(
                url,
                trackedURLs: &intermediateOutputURLs
            )

            let adjustedURL = try await applyAdjustsOperation(
                integratesAdjustsIntoBaseStage ? [] : adjusts,
                fromUrl: url,
                exportProfile: exportProfile,
                progressRange: progressRange(
                    for: .adjusts,
                    activeStages: renderStages
                ),
                onProgress: onProgress
            )
            advanceIntermediateOutput(
                from: url,
                to: adjustedURL,
                trackedURLs: &intermediateOutputURLs
            )
            let transcribedURL = try await applyTranscriptOperation(
                editingConfiguration: editingConfiguration,
                fromUrl: adjustedURL,
                exportProfile: exportProfile,
                progressRange: progressRange(
                    for: .transcript,
                    activeStages: renderStages
                ),
                onProgress: onProgress
            )
            advanceIntermediateOutput(
                from: adjustedURL,
                to: transcribedURL,
                trackedURLs: &intermediateOutputURLs
            )
            let watermarkedURL = try await applyWatermarkOperation(
                watermark,
                fromUrl: transcribedURL,
                exportProfile: exportProfile,
                progressRange: progressRange(
                    for: .watermark,
                    activeStages: renderStages
                ),
                onProgress: onProgress
            )
            advanceIntermediateOutput(
                from: transcribedURL,
                to: watermarkedURL,
                trackedURLs: &intermediateOutputURLs
            )
            cleanupIntermediateOutputs(
                intermediateOutputURLs,
                excluding: watermarkedURL
            )
            return watermarkedURL
        } catch {
            cleanupIntermediateOutputs(
                intermediateOutputURLs,
                excluding: nil
            )
            throw error
        }
    }

    private static func resizeAndLayerOperation(
        video: Video,
        editingConfiguration: VideoEditingConfiguration,
        exportProfile: ExportProfile,
        integratedAdjusts: [CIFilter] = [],
        progressRange: ClosedRange<Double>,
        onProgress: ProgressHandler?
    ) async throws -> URL {
        let composition = AVMutableComposition()
        let timeRange = getTimeRange(for: video.timelineDuration, with: video.outputRangeDuration)
        let asset = video.asset

        try await setTimeScaleAndAddTracks(
            to: composition, from: asset, audio: video.audio, timeScale: Float64(video.rate),
            videoVolume: video.volume)

        guard let videoTrack = try await composition.loadTracks(withMediaType: .video).first else {
            throw ExporterError.unknow
        }

        let naturalSize = videoTrack.naturalSize
        let videoTrackPreferredTransform = try await videoTrack.load(.preferredTransform)
        let presentationSize = resolvedPresentationSize(
            naturalSize: naturalSize,
            preferredTransform: videoTrackPreferredTransform
        )
        let outputSize: CGSize
        let layerInstruction: AVVideoCompositionLayerInstruction

        if requiresCanvasStage(editingConfiguration) {
            let renderRequest = await resolvedCanvasRenderRequest(
                naturalSize: naturalSize,
                preferredTransform: videoTrackPreferredTransform,
                sourcePresentationSize: presentationSize,
                editingConfiguration: editingConfiguration,
                exportSize: exportProfile.renderSize
            )
            let mappingActor = VideoCanvasMappingActor()
            let exportMapping = mappingActor.makeExportMapping(
                request: renderRequest
            )
            outputSize = exportMapping.renderSize
            let mutableLayerInstruction = AVMutableVideoCompositionLayerInstruction(
                assetTrack: videoTrack
            )
            mutableLayerInstruction.setTransform(
                exportMapping.contentTransform,
                at: .zero
            )
            layerInstruction = mutableLayerInstruction
        } else {
            outputSize = exportProfile.renderSize

            layerInstruction = videoCompositionInstructionForTrackWithSizeAndTime(
                preferredTransform: videoTrackPreferredTransform,
                naturalSize: naturalSize,
                presentationSize: presentationSize,
                renderSize: outputSize,
                track: videoTrack,
                isMirror: video.isMirror
            )
        }

        let animationTool = createAnimationTool(video.videoFrames, video: video, size: outputSize)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.layerInstructions = [layerInstruction]
        instruction.timeRange = timeRange

        let videoComposition: AVMutableVideoComposition

        if integratedAdjusts.isEmpty {
            videoComposition = AVMutableVideoComposition()
            videoComposition.animationTool = animationTool
            videoComposition.instructions = [instruction]
        } else {
            videoComposition = try await filteredVideoComposition(
                asset: composition,
                filters: integratedAdjusts
            )
        }

        videoComposition.frameDuration = exportProfile.frameDuration
        videoComposition.renderSize = outputSize
        videoComposition.renderScale = 1
        let outputURL = createTempPath()
        let session = try exportSession(
            composition: composition,
            videoComposition: videoComposition,
            outputURL: outputURL,
            timeRange: timeRange,
            exportProfile: exportProfile
        )

        try await export(
            session,
            to: outputURL,
            as: .mp4,
            progressRange: progressRange,
            onProgress: onProgress
        )

        return outputURL
    }

    private static func applyAdjustsOperation(
        _ adjusts: [CIFilter],
        fromUrl: URL,
        exportProfile: ExportProfile,
        progressRange: ClosedRange<Double>,
        onProgress: ProgressHandler?
    ) async throws -> URL {
        if adjusts.isEmpty {
            await reportProgress(progressRange.upperBound, via: onProgress)
            return fromUrl
        }

        let asset = AVURLAsset(url: fromUrl)
        let composition = try await asset.makeVideoComposition(applying: adjusts)
        let outputURL = createTempPath()

        guard
            let session = AVAssetExportSession(
                asset: asset,
                presetName: resolvedExportPresetName(
                    for: exportProfile,
                    appliesVideoComposition: true
                )
            )
        else {
            assertionFailure("Unable to create color adjusts export session.")
            throw ExporterError.cannotCreateExportSession
        }

        session.videoComposition = composition

        try await export(
            session,
            to: outputURL,
            as: .mp4,
            progressRange: progressRange,
            onProgress: onProgress
        )

        return outputURL
    }

    private static func filteredVideoComposition(
        asset: AVAsset,
        filters: [CIFilter]
    ) async throws -> AVMutableVideoComposition {
        let videoComposition = try await asset.makeVideoComposition(applying: filters)

        guard let mutableVideoComposition = videoComposition.mutableCopy() as? AVMutableVideoComposition
        else {
            assertionFailure("Unable to create mutable color adjusts video composition.")
            throw ExporterError.cannotCreateExportSession
        }

        return mutableVideoComposition
    }

    private static func applyTranscriptOperation(
        editingConfiguration: VideoEditingConfiguration,
        fromUrl: URL,
        exportProfile: ExportProfile,
        progressRange: ClosedRange<Double>,
        onProgress: ProgressHandler?
    ) async throws -> URL {
        guard let transcriptDocument = editingConfiguration.transcript.document else {
            await reportProgress(progressRange.upperBound, via: onProgress)
            return fromUrl
        }

        let renderSegments = resolvedTranscriptRenderSegmentsForExport(
            from: transcriptDocument,
            editingConfiguration: editingConfiguration
        )
        guard !renderSegments.isEmpty else {
            await reportProgress(progressRange.upperBound, via: onProgress)
            return fromUrl
        }
        let renderUnits = resolvedTranscriptRenderUnits(
            from: renderSegments
        )
        let asset = AVURLAsset(url: fromUrl)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExporterError.unknow
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let trackTimeRange = try await videoTrack.load(.timeRange)
        let presentationSize = resolvedPresentationSize(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        )
        let instruction = videoCompositionInstructionForTrackWithSizeAndTime(
            preferredTransform: preferredTransform,
            naturalSize: naturalSize,
            presentationSize: presentationSize,
            renderSize: presentationSize,
            track: videoTrack,
            isMirror: false
        )
        let animationContext = await MainActor.run {
            autoreleasepool {
                createTranscriptAnimationContext(
                    transcriptDocument,
                    renderUnits: renderUnits,
                    renderSize: presentationSize
                )
            }
        }
        let videoInstruction = AVMutableVideoCompositionInstruction()
        videoInstruction.layerInstructions = [
            animationContext.overlayInstruction,
            instruction,
        ]
        videoInstruction.timeRange = trackTimeRange
        let videoComposition = AVMutableVideoComposition()
        videoComposition.animationTool = animationContext.animationTool
        videoComposition.frameDuration = exportProfile.frameDuration
        videoComposition.instructions = [videoInstruction]
        videoComposition.renderSize = presentationSize
        let outputURL = createTempPath()

        guard
            let session = AVAssetExportSession(
                asset: asset,
                presetName: resolvedExportPresetName(
                    for: exportProfile,
                    appliesVideoComposition: true
                )
            )
        else {
            assertionFailure("Unable to create transcript export session.")
            throw ExporterError.cannotCreateExportSession
        }

        session.videoComposition = videoComposition

        try await export(
            session,
            to: outputURL,
            as: .mp4,
            progressRange: progressRange,
            onProgress: onProgress
        )

        return outputURL
    }

    private static func applyWatermarkOperation(
        _ watermark: VideoWatermarkRenderRequest?,
        fromUrl: URL,
        exportProfile: ExportProfile,
        progressRange: ClosedRange<Double>,
        onProgress: ProgressHandler?
    ) async throws -> URL {
        guard let watermark else {
            await reportProgress(progressRange.upperBound, via: onProgress)
            return fromUrl
        }

        let asset = AVURLAsset(url: fromUrl)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExporterError.unknow
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let trackTimeRange = try await videoTrack.load(.timeRange)
        let presentationSize = resolvedPresentationSize(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        )
        let instruction = videoCompositionInstructionForTrackWithSizeAndTime(
            preferredTransform: preferredTransform,
            naturalSize: naturalSize,
            presentationSize: presentationSize,
            renderSize: presentationSize,
            track: videoTrack,
            isMirror: false
        )
        let videoInstruction = AVMutableVideoCompositionInstruction()
        videoInstruction.layerInstructions = [instruction]
        videoInstruction.timeRange = trackTimeRange

        let videoComposition = AVMutableVideoComposition()
        videoComposition.animationTool = createWatermarkAnimationTool(
            watermark,
            renderSize: presentationSize
        )
        videoComposition.frameDuration = exportProfile.frameDuration
        videoComposition.instructions = [videoInstruction]
        videoComposition.renderSize = presentationSize

        let outputURL = createTempPath()

        guard
            let session = AVAssetExportSession(
                asset: asset,
                presetName: resolvedExportPresetName(
                    for: exportProfile,
                    appliesVideoComposition: true
                )
            )
        else {
            assertionFailure("Unable to create watermark export session.")
            throw ExporterError.cannotCreateExportSession
        }

        session.videoComposition = videoComposition

        do {
            try await export(
                session,
                to: outputURL,
                as: .mp4,
                progressRange: progressRange,
                onProgress: onProgress
            )
        } catch {
            FileManager.default.removeIfExists(for: outputURL)
            throw error
        }

        return outputURL
    }
}

extension VideoEditor {

    // MARK: - Private Properties

    enum RenderStage: Equatable {
        case base
        case adjusts
        case transcript
        case crop
        case watermark
    }

    struct TranscriptRenderSegment: Equatable {

        // MARK: - Public Properties

        let text: String
        let timeRange: ClosedRange<Double>
        let style: TranscriptStyle
        let words: [TranscriptRenderWord]

    }

    struct TranscriptRenderWord: Equatable {

        // MARK: - Public Properties

        let id: EditableTranscriptWord.ID
        let text: String
        let timeRange: ClosedRange<Double>

    }

    struct TranscriptRenderUnit: Equatable {

        // MARK: - Public Types

        enum Mode: Equatable {
            case block
            case activeWord
        }

        // MARK: - Public Properties

        let text: String
        let timeRange: ClosedRange<Double>
        let style: TranscriptStyle
        let mode: Mode

    }

    struct ExportProfile: Equatable {

        // MARK: - Public Properties

        let quality: VideoQuality
        let renderSize: CGSize
        let frameDuration: CMTime
        let renderPresetName: String
        let passthroughPresetName: String

    }

    enum VideoRenderIntent: Equatable {
        case saveNative(sourceFrameRate: Double?)
        case export(VideoQuality)
    }

    struct RenderProfile: Equatable {

        // MARK: - Public Properties

        let intent: VideoRenderIntent
        let renderSize: CGSize
        let frameDuration: CMTime
        let renderPresetName: String
        let passthroughPresetName: String

    }

    private struct TranscriptAnimationContext {

        // MARK: - Public Properties

        let animationTool: AVVideoCompositionCoreAnimationTool
        let overlayInstruction: AVVideoCompositionLayerInstruction

    }

    struct TranscriptActiveWordTimelineState: Equatable {

        // MARK: - Public Properties

        let time: Double
        let text: String?
        let frame: CGRect
        let textFrame: CGRect
        let fontSize: CGFloat
        let style: TranscriptStyle

        var isHidden: Bool {
            text == nil
        }

    }

    struct TranscriptActiveWordRasterLayout: Equatable {

        // MARK: - Public Properties

        let frame: CGRect
        let textFrame: CGRect

    }

    private struct TranscriptRasterizedFrame {

        // MARK: - Public Properties

        let time: Double
        let frame: CGRect
        let contentsScale: CGFloat
        let image: CGImage

    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
            true
        #else
            false
        #endif
    }

    private static let transcriptOverlayTrackID: CMPersistentTrackID = 9_001
    private static let transcriptLayerBatchSize = 24
    private static let transcriptRenderableUnitsPerBatch = 32
    private static let timelineNormalizationTolerance = 0.0001

    // MARK: - Public Methods

    static func resolvedPresentationSize(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGSize {
        let transformedBounds = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        let resolvedSize = CGSize(
            width: abs(transformedBounds.width),
            height: abs(transformedBounds.height)
        )

        guard resolvedSize.width > 0, resolvedSize.height > 0 else {
            return CGSize(
                width: abs(naturalSize.width),
                height: abs(naturalSize.height)
            )
        }

        return resolvedSize
    }

    static func resolvedRenderSize(
        for sourceSize: CGSize,
        constrainedTo maximumSize: CGSize
    ) -> CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return evenPixelSize(for: maximumSize)
        }

        guard maximumSize.width > 0, maximumSize.height > 0 else {
            return evenPixelSize(for: sourceSize)
        }

        let widthScale = maximumSize.width / sourceSize.width
        let heightScale = maximumSize.height / sourceSize.height
        let scale = min(widthScale, heightScale)
        let fittedSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )

        return evenPixelSize(for: fittedSize)
    }

    static func resolvedBaseRenderSize(
        for sourceSize: CGSize,
        editingConfiguration: VideoEditingConfiguration,
        videoQuality: VideoQuality
    ) -> CGSize {
        let layout = resolvedBaseRenderLayout(
            for: sourceSize,
            editingConfiguration: editingConfiguration
        )

        return resolvedRenderSize(
            for: sourceSize,
            constrainedTo: videoQuality.size(for: layout)
        )
    }

    static func resolvedOutputRenderSize(
        for sourceSize: CGSize,
        editingConfiguration: VideoEditingConfiguration,
        videoQuality: VideoQuality
    ) -> CGSize {
        if let canvasSize = resolvedCanvasRenderSize(
            for: sourceSize,
            editingConfiguration: editingConfiguration,
            videoQuality: videoQuality
        ) {
            return canvasSize
        }

        let layout = resolvedOutputRenderLayout(
            for: sourceSize,
            editingConfiguration: editingConfiguration
        )

        if layout == .portrait {
            return videoQuality.size(for: layout)
        }

        return resolvedRenderSize(
            for: sourceSize,
            constrainedTo: videoQuality.size(for: layout)
        )
    }

    static func resolvedExportProfile(
        for video: Video,
        editingConfiguration: VideoEditingConfiguration,
        videoQuality: VideoQuality,
        isSimulatorEnvironment: Bool = isSimulator
    ) -> ExportProfile {
        resolvedExportProfile(
            for: video.presentationSize,
            editingConfiguration: editingConfiguration,
            videoQuality: videoQuality,
            isSimulatorEnvironment: isSimulatorEnvironment
        )
    }

    static func resolvedExportProfile(
        for sourceSize: CGSize,
        editingConfiguration: VideoEditingConfiguration,
        videoQuality: VideoQuality,
        isSimulatorEnvironment: Bool = isSimulator
    ) -> ExportProfile {
        let renderProfile = resolvedRenderProfile(
            for: sourceSize,
            editingConfiguration: editingConfiguration,
            intent: .export(videoQuality),
            isSimulatorEnvironment: isSimulatorEnvironment
        )

        return ExportProfile(
            quality: videoQuality,
            renderSize: renderProfile.renderSize,
            frameDuration: renderProfile.frameDuration,
            renderPresetName: renderProfile.renderPresetName,
            passthroughPresetName: renderProfile.passthroughPresetName
        )
    }

    static func resolvedExportProfile(
        for sourceSize: CGSize,
        editingConfiguration: VideoEditingConfiguration,
        renderIntent: VideoRenderIntent,
        isSimulatorEnvironment: Bool = isSimulator
    ) -> ExportProfile {
        let renderProfile = resolvedRenderProfile(
            for: sourceSize,
            editingConfiguration: editingConfiguration,
            intent: renderIntent,
            isSimulatorEnvironment: isSimulatorEnvironment
        )

        return ExportProfile(
            quality: fallbackQuality(for: renderIntent),
            renderSize: renderProfile.renderSize,
            frameDuration: renderProfile.frameDuration,
            renderPresetName: renderProfile.renderPresetName,
            passthroughPresetName: renderProfile.passthroughPresetName
        )
    }

    static func resolvedRenderProfile(
        for sourceSize: CGSize,
        editingConfiguration: VideoEditingConfiguration,
        intent: VideoRenderIntent,
        isSimulatorEnvironment: Bool = isSimulator
    ) -> RenderProfile {
        let renderSize: CGSize
        let resolvedFrameDuration: CMTime
        let presetNames:
            (
                renderPresetName: String,
                passthroughPresetName: String
            )

        switch intent {
        case .saveNative(let sourceFrameRate):
            renderSize = resolvedNativeRenderSize(
                for: sourceSize,
                editingConfiguration: editingConfiguration
            )
            resolvedFrameDuration = frameDuration(forSourceFrameRate: sourceFrameRate)
            presetNames = resolvedNativeSavePresetNames(isSimulatorEnvironment: isSimulatorEnvironment)
        case .export(let videoQuality) where videoQuality.isOriginal:
            renderSize = resolvedNativeRenderSize(
                for: sourceSize,
                editingConfiguration: editingConfiguration
            )
            resolvedFrameDuration = frameDuration(forSourceFrameRate: nil)
            presetNames = resolvedNativeSavePresetNames(isSimulatorEnvironment: isSimulatorEnvironment)
        case .export(let videoQuality):
            renderSize = resolvedOutputRenderSize(
                for: sourceSize,
                editingConfiguration: editingConfiguration,
                videoQuality: videoQuality
            )
            resolvedFrameDuration = frameDuration(for: videoQuality)
            presetNames = resolvedExportPresetNames(
                for: videoQuality,
                isSimulatorEnvironment: isSimulatorEnvironment
            )
        }

        return RenderProfile(
            intent: intent,
            renderSize: renderSize,
            frameDuration: resolvedFrameDuration,
            renderPresetName: presetNames.renderPresetName,
            passthroughPresetName: presetNames.passthroughPresetName
        )
    }

    private static func resolvedNativeRenderSize(
        for sourceSize: CGSize,
        editingConfiguration: VideoEditingConfiguration
    ) -> CGSize {
        if let canvasSize = preferredCanvasRenderSize(
            for: sourceSize,
            editingConfiguration: editingConfiguration
        ) {
            return evenPixelSize(for: canvasSize)
        }

        return evenPixelSize(for: sourceSize)
    }

    static func resolvedSourceFrameRate(for asset: AVAsset) async -> Double? {
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }
        guard let nominalFrameRate = try? await videoTrack.load(.nominalFrameRate) else {
            return nil
        }

        let frameRate = Double(nominalFrameRate)
        guard frameRate.isFinite, frameRate > 0 else {
            return nil
        }

        return frameRate
    }

    static func canIntegrateAdjustsIntoBaseRender(
        video: Video,
        editingConfiguration: VideoEditingConfiguration,
        exportProfile: ExportProfile
    ) async -> Bool {
        guard video.videoFrames == nil else { return false }
        guard video.isMirror == false else { return false }
        guard requiresCanvasStage(editingConfiguration) == false else { return false }
        guard let videoTrack = try? await video.asset.loadTracks(withMediaType: .video).first else {
            return false
        }
        guard let naturalSize = try? await videoTrack.load(.naturalSize) else { return false }
        guard let preferredTransform = try? await videoTrack.load(.preferredTransform) else {
            return false
        }
        guard isApproximatelyIdentityTransform(preferredTransform) else { return false }

        let presentationSize = resolvedPresentationSize(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        )
        let nativeRenderSize = evenPixelSize(for: presentationSize)

        return isApproximatelyEqual(nativeRenderSize, exportProfile.renderSize)
    }

    static func resolvedCanvasRenderSize(
        for sourceSize: CGSize,
        editingConfiguration: VideoEditingConfiguration,
        videoQuality: VideoQuality
    ) -> CGSize? {
        guard
            let canvasSize = preferredCanvasRenderSize(
                for: sourceSize,
                editingConfiguration: editingConfiguration
            )
        else {
            return nil
        }

        let layout: VideoQuality.RenderLayout =
            canvasSize.height > canvasSize.width ? .portrait : .landscape
        let maximumSize = videoQuality.size(for: layout)

        if canvasSize.width <= maximumSize.width, canvasSize.height <= maximumSize.height {
            return evenPixelSize(for: canvasSize)
        }

        return resolvedRenderSize(
            for: canvasSize,
            constrainedTo: maximumSize
        )
    }

    static func resolvedCropRect(
        for freeformRect: VideoEditingConfiguration.FreeformRect,
        in presentationSize: CGSize
    ) -> CGRect {
        guard presentationSize.width > 0, presentationSize.height > 0 else {
            return CGRect(origin: .zero, size: evenPixelSize(for: CGSize(width: 2, height: 2)))
        }

        guard
            let cropRect = VideoCropPreviewLayout.resolvedGeometry(
                freeformRect: freeformRect,
                in: presentationSize
            )?.sourceRect
        else {
            return CGRect(origin: .zero, size: evenPixelSize(for: presentationSize))
        }

        let width = max(round(cropRect.width / 2) * 2, 2)
        let height = max(round(cropRect.height / 2) * 2, 2)
        let boundedWidth = min(width, presentationSize.width)
        let boundedHeight = min(height, presentationSize.height)
        let originX = min(
            max(round(cropRect.minX), 0),
            max(presentationSize.width - boundedWidth, 0)
        )
        let originY = min(
            max(round(cropRect.minY), 0),
            max(presentationSize.height - boundedHeight, 0)
        )

        return CGRect(
            x: originX,
            y: originY,
            width: boundedWidth,
            height: boundedHeight
        )
    }

    static func resolvedOutputRenderLayout(
        for sourceSize: CGSize,
        editingConfiguration: VideoEditingConfiguration
    ) -> VideoQuality.RenderLayout {
        if let canvasSize = preferredCanvasRenderSize(
            for: sourceSize,
            editingConfiguration: editingConfiguration
        ) {
            return canvasSize.height > canvasSize.width ? .portrait : .landscape
        }

        if editingConfiguration.presentation.socialVideoDestination != nil {
            return .portrait
        }

        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return .landscape
        }

        guard let freeformRect = editingConfiguration.crop.freeformRect else {
            return .landscape
        }

        guard
            let cropRect = VideoCropPreviewLayout.resolvedGeometry(
                freeformRect: freeformRect,
                in: sourceSize
            )?.sourceRect
        else { return .landscape }

        guard cropRect.width > 0, cropRect.height > 0 else {
            return .landscape
        }

        return cropRect.height > cropRect.width ? .portrait : .landscape
    }

    static func resolvedExportPresetName(
        videoQuality: VideoQuality,
        appliesVideoComposition: Bool,
        isSimulatorEnvironment: Bool
    ) -> String {
        let presetNames = resolvedExportPresetNames(
            for: videoQuality,
            isSimulatorEnvironment: isSimulatorEnvironment
        )

        return appliesVideoComposition
            ? presetNames.renderPresetName
            : presetNames.passthroughPresetName
    }

    static func resolvedExportPresetName(
        for exportProfile: ExportProfile,
        appliesVideoComposition: Bool
    ) -> String {
        appliesVideoComposition
            ? exportProfile.renderPresetName
            : exportProfile.passthroughPresetName
    }

    static func resolvedRenderStages(
        usesAdjustsStage: Bool,
        usesTranscriptStage: Bool,
        usesCropStage: Bool,
        usesWatermarkStage: Bool
    ) -> [RenderStage] {
        var stages: [RenderStage] = [.base]

        if usesAdjustsStage {
            stages.append(.adjusts)
        }

        if usesTranscriptStage {
            stages.append(.transcript)
        }

        _ = usesCropStage

        if usesWatermarkStage {
            stages.append(.watermark)
        }

        return stages
    }

    static func resolvedTranscriptRenderUnits(
        from renderSegments: [TranscriptRenderSegment]
    ) -> [TranscriptRenderUnit] {
        renderSegments.flatMap { segment in
            if segment.words.isEmpty {
                return [
                    TranscriptRenderUnit(
                        text: segment.text,
                        timeRange: segment.timeRange,
                        style: segment.style,
                        mode: .block
                    )
                ]
            }

            return segment.words.map { word in
                TranscriptRenderUnit(
                    text: word.text,
                    timeRange: word.timeRange,
                    style: segment.style,
                    mode: .activeWord
                )
            }
        }
    }

    static func resolvedTranscriptRenderBatches(
        from renderUnits: [TranscriptRenderUnit]
    ) -> [[TranscriptRenderUnit]] {
        guard renderUnits.isEmpty == false else { return [] }

        var batches = [[TranscriptRenderUnit]]()
        var currentBatch = [TranscriptRenderUnit]()

        for renderUnit in renderUnits {
            let shouldStartNewBatch =
                currentBatch.isEmpty == false
                && currentBatch.count >= transcriptRenderableUnitsPerBatch

            if shouldStartNewBatch {
                batches.append(currentBatch)
                currentBatch = []
            }

            currentBatch.append(renderUnit)
        }

        if currentBatch.isEmpty == false {
            batches.append(currentBatch)
        }

        return batches
    }

    static func resolvedTranscriptRenderSegmentsForExport(
        from transcriptDocument: TranscriptDocument,
        editingConfiguration: VideoEditingConfiguration
    ) -> [TranscriptRenderSegment] {
        resolvedTranscriptRenderSegments(
            from: transcriptDocument,
            timelineOffset: resolvedTranscriptExportTimelineOffset(
                editingConfiguration
            )
        )
    }

    private static func requiresCanvasStage(
        _ editingConfiguration: VideoEditingConfiguration
    ) -> Bool {
        let normalizedRotation = editingConfiguration.crop.rotationDegrees
            .truncatingRemainder(dividingBy: 360)

        return editingConfiguration.canvas.snapshot.isIdentity == false
            || editingConfiguration.crop.freeformRect != nil
            || editingConfiguration.crop.isMirrored
            || abs(normalizedRotation) > 0.001
            || editingConfiguration.presentation.socialVideoDestination != nil
    }

    private static func isApproximatelyIdentityTransform(
        _ transform: CGAffineTransform
    ) -> Bool {
        abs(transform.a - 1) <= 0.001
            && abs(transform.b) <= 0.001
            && abs(transform.c) <= 0.001
            && abs(transform.d - 1) <= 0.001
            && abs(transform.tx) <= 0.001
            && abs(transform.ty) <= 0.001
    }

    private static func isApproximatelyEqual(
        _ lhs: CGSize,
        _ rhs: CGSize
    ) -> Bool {
        abs(lhs.width - rhs.width) <= 0.001
            && abs(lhs.height - rhs.height) <= 0.001
    }

    static func requiresTranscriptStage(
        _ editingConfiguration: VideoEditingConfiguration
    ) -> Bool {
        guard editingConfiguration.transcript.featureState == .loaded else { return false }
        guard let transcriptDocument = editingConfiguration.transcript.document else { return false }

        return resolvedTranscriptRenderSegments(
            from: transcriptDocument
        ).isEmpty == false
    }

    private static func preferredCanvasRenderSize(
        for sourceSize: CGSize,
        editingConfiguration: VideoEditingConfiguration
    ) -> CGSize? {
        let preset = resolvedCanvasPreset(
            for: sourceSize,
            editingConfiguration: editingConfiguration
        )

        let shouldPreferCanvasSize =
            editingConfiguration.canvas.snapshot.preset != .original
            || editingConfiguration.presentation.socialVideoDestination != nil
            || editingConfiguration.crop.freeformRect != nil

        guard shouldPreferCanvasSize else { return nil }

        return preset.resolvedExportSize(
            naturalSize: sourceSize,
            freeCanvasSize: editingConfiguration.canvas.snapshot.freeCanvasSize
        )
    }

    private static func resolvedCanvasRenderRequest(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        sourcePresentationSize: CGSize,
        editingConfiguration: VideoEditingConfiguration,
        exportSize: CGSize
    ) async -> VideoCanvasRenderRequest {
        let mappingActor = VideoCanvasMappingActor()
        let source = VideoCanvasSourceDescriptor(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform,
            userRotationDegrees: editingConfiguration.crop.rotationDegrees,
            isMirrored: editingConfiguration.crop.isMirrored
        )
        let snapshot = await resolvedCanvasSnapshot(
            for: sourcePresentationSize,
            editingConfiguration: editingConfiguration,
            exportSize: exportSize,
            mappingActor: mappingActor
        )

        return mappingActor.makeRenderRequest(
            source: source,
            snapshot: snapshot,
            resolvedPreset: VideoCanvasResolvedPreset(
                preset: snapshot.preset,
                exportSize: exportSize
            ),
        )
    }

    private static func resolvedCanvasSnapshot(
        for sourcePresentationSize: CGSize,
        editingConfiguration: VideoEditingConfiguration,
        exportSize: CGSize,
        mappingActor: VideoCanvasMappingActor
    ) async -> VideoCanvasSnapshot {
        let storedSnapshot = editingConfiguration.canvas.snapshot
        if storedSnapshot != .initial {
            return storedSnapshot
        }

        let preset = resolvedCanvasPreset(
            for: sourcePresentationSize,
            editingConfiguration: editingConfiguration
        )

        var snapshot = VideoCanvasSnapshot(
            preset: preset,
            freeCanvasSize: exportSize,
            transform: .identity,
            showsSafeAreaOverlay: false
        )

        snapshot.transform = mappingActor.snapshotTransform(
            fromLegacyFreeformRect: editingConfiguration.crop.freeformRect,
            referenceSize: sourcePresentationSize,
            exportSize: exportSize
        )

        return snapshot
    }

    private static func resolvedCanvasPreset(
        for sourceSize: CGSize,
        editingConfiguration: VideoEditingConfiguration
    ) -> VideoCanvasPreset {
        let storedPreset = editingConfiguration.canvas.snapshot.preset
        if storedPreset != .original {
            return storedPreset
        }

        if let socialVideoDestination = editingConfiguration.presentation.socialVideoDestination {
            return .social(platform: socialVideoDestination.socialPlatform)
        }

        guard let freeformRect = editingConfiguration.crop.freeformRect else {
            return .original
        }

        let clampedAspectRatio = resolvedLegacyCanvasAspectRatio(
            freeformRect: freeformRect,
            sourceSize: sourceSize
        )

        for preset in VideoCropFormatPreset.editorPresets {
            guard let aspectRatio = preset.aspectRatio else { continue }
            guard let clampedAspectRatio else { continue }
            if abs(clampedAspectRatio - aspectRatio) < 0.001 {
                return VideoCanvasPreset.fromLegacySelection(
                    preset: preset,
                    socialVideoDestination: nil
                )
            }
        }

        let cropRect = resolvedCropRect(
            for: freeformRect,
            in: sourceSize
        )

        return .custom(
            width: max(Int(cropRect.width.rounded()), 2),
            height: max(Int(cropRect.height.rounded()), 2)
        )
    }

    private static func resolvedLegacyCanvasAspectRatio(
        freeformRect: VideoEditingConfiguration.FreeformRect,
        sourceSize: CGSize
    ) -> CGFloat? {
        let cropRect = resolvedCropRect(
            for: freeformRect,
            in: sourceSize
        )

        guard cropRect.width > 0, cropRect.height > 0 else { return nil }

        return cropRect.width / cropRect.height
    }

    private static func exportSession(
        composition: AVMutableComposition, videoComposition: AVVideoComposition, outputURL: URL,
        timeRange: CMTimeRange,
        exportProfile: ExportProfile
    ) throws -> AVAssetExportSession {
        guard
            let export = AVAssetExportSession(
                asset: composition,
                presetName: resolvedExportPresetName(
                    for: exportProfile,
                    appliesVideoComposition: true
                )
            )
        else {
            assertionFailure("Unable to create composition export session.")
            throw ExporterError.cannotCreateExportSession
        }

        export.videoComposition = videoComposition
        export.timeRange = timeRange

        return export
    }

    private static func resolvedExportPresetNames(
        for videoQuality: VideoQuality,
        isSimulatorEnvironment: Bool
    ) -> (
        renderPresetName: String,
        passthroughPresetName: String
    ) {
        _ = videoQuality

        guard isSimulatorEnvironment else {
            return (
                renderPresetName: AVAssetExportPresetHighestQuality,
                passthroughPresetName: AVAssetExportPresetHighestQuality
            )
        }

        // `passthrough` ignores videoComposition, which would drop preset/canvas and adjusts renders.
        return (
            renderPresetName: AVAssetExportPresetHighestQuality,
            passthroughPresetName: AVAssetExportPresetPassthrough
        )
    }

    private static func resolvedNativeSavePresetNames(
        isSimulatorEnvironment: Bool
    ) -> (
        renderPresetName: String,
        passthroughPresetName: String
    ) {
        guard isSimulatorEnvironment else {
            return (
                renderPresetName: AVAssetExportPresetHighestQuality,
                passthroughPresetName: AVAssetExportPresetHighestQuality
            )
        }

        return (
            renderPresetName: AVAssetExportPresetHighestQuality,
            passthroughPresetName: AVAssetExportPresetPassthrough
        )
    }

    private static func frameDuration(
        for videoQuality: VideoQuality
    ) -> CMTime {
        CMTime(
            seconds: 1 / max(videoQuality.frameRate, 1),
            preferredTimescale: 600
        )
    }

    private static func frameDuration(
        forSourceFrameRate sourceFrameRate: Double?
    ) -> CMTime {
        guard
            let sourceFrameRate,
            sourceFrameRate.isFinite,
            sourceFrameRate > 0
        else {
            return CMTime(seconds: 1 / 30, preferredTimescale: 600)
        }

        return CMTime(
            seconds: 1 / sourceFrameRate,
            preferredTimescale: 600
        )
    }

    private static func resolvedRenderIntent(
        _ renderIntent: VideoRenderIntent,
        asset: AVAsset
    ) async -> VideoRenderIntent {
        switch renderIntent {
        case .saveNative(.none):
            return .saveNative(
                sourceFrameRate: await resolvedSourceFrameRate(for: asset)
            )
        case .export(let videoQuality) where videoQuality.isOriginal:
            return .saveNative(
                sourceFrameRate: await resolvedSourceFrameRate(for: asset)
            )
        case .saveNative(.some), .export:
            return renderIntent
        }
    }

    private static func fallbackQuality(
        for renderIntent: VideoRenderIntent
    ) -> VideoQuality {
        switch renderIntent {
        case .saveNative:
            .high
        case .export(let videoQuality):
            videoQuality
        }
    }

    private static func createAnimationTool(
        _ videoFrame: VideoFrames?,
        video: Video,
        size: CGSize
    ) -> AVVideoCompositionCoreAnimationTool? {
        guard let videoFrame else { return nil }

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: size)

        let outputLayer = CALayer()
        outputLayer.frame = CGRect(origin: .zero, size: size)

        let scale = videoFrame.scale
        let scaleSize = CGSize(width: size.width * scale, height: size.height * scale)
        let centerPoint = CGPoint(
            x: (size.width - scaleSize.width) / 2,
            y: (size.height - scaleSize.height) / 2
        )

        let bgLayer = CALayer()
        bgLayer.frame = CGRect(origin: .zero, size: size)
        bgLayer.backgroundColor = videoFrame.frameColor.cgColor
        outputLayer.addSublayer(bgLayer)

        videoLayer.frame = CGRect(origin: centerPoint, size: scaleSize)

        outputLayer.addSublayer(videoLayer)

        return AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: outputLayer
        )
    }

    private static func createWatermarkAnimationTool(
        _ watermark: VideoWatermarkRenderRequest,
        renderSize: CGSize
    ) -> AVVideoCompositionCoreAnimationTool {
        let bounds = CGRect(origin: .zero, size: renderSize)

        let videoLayer = CALayer()
        videoLayer.frame = bounds

        let outputLayer = CALayer()
        outputLayer.frame = bounds
        outputLayer.isGeometryFlipped = true
        outputLayer.masksToBounds = true
        outputLayer.addSublayer(videoLayer)

        let watermarkLayer = CALayer()
        watermarkLayer.frame = VideoWatermarkLayout.frame(
            renderSize: renderSize,
            imageSize: watermark.imageSize,
            position: watermark.position
        )
        watermarkLayer.contents = watermark.image
        watermarkLayer.contentsGravity = .resize
        watermarkLayer.contentsScale = watermark.imageScale
        watermarkLayer.opacity = watermark.opacity
        outputLayer.addSublayer(watermarkLayer)

        return AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: outputLayer
        )
    }

    private static func createTranscriptAnimationContext(
        _ transcriptDocument: TranscriptDocument,
        renderUnits: [TranscriptRenderUnit],
        renderSize: CGSize
    ) -> TranscriptAnimationContext {
        let activeWordTimelineStates = resolvedActiveWordTimelineStates(
            from: renderUnits,
            overlayPosition: transcriptDocument.overlayPosition,
            overlaySize: transcriptDocument.overlaySize,
            renderSize: renderSize
        )
        let blockRenderUnits = renderUnits.filter { $0.mode == .block }
        let outputLayer = CALayer()
        outputLayer.frame = CGRect(origin: .zero, size: renderSize)
        outputLayer.masksToBounds = true
        outputLayer.isGeometryFlipped = true

        for batchStartIndex in stride(
            from: 0,
            to: blockRenderUnits.count,
            by: transcriptLayerBatchSize
        ) {
            let batchLayer = CALayer()
            batchLayer.frame = outputLayer.bounds
            batchLayer.allowsEdgeAntialiasing = true

            let batchEndIndex = min(
                batchStartIndex + transcriptLayerBatchSize,
                blockRenderUnits.count
            )

            for renderUnit in blockRenderUnits[batchStartIndex..<batchEndIndex] {
                autoreleasepool {
                    let overlayLayer = makeTranscriptOverlayLayer(
                        for: renderUnit,
                        overlayPosition: transcriptDocument.overlayPosition,
                        overlaySize: transcriptDocument.overlaySize,
                        renderSize: renderSize
                    )
                    batchLayer.addSublayer(overlayLayer)
                }
            }

            outputLayer.addSublayer(batchLayer)
        }

        if let activeWordLayer = makeActiveWordTimelineLayer(
            from: activeWordTimelineStates
        ) {
            outputLayer.addSublayer(activeWordLayer)
        }

        let overlayInstruction = AVMutableVideoCompositionLayerInstruction()
        overlayInstruction.trackID = transcriptOverlayTrackID

        return TranscriptAnimationContext(
            animationTool: AVVideoCompositionCoreAnimationTool(
                additionalLayer: outputLayer,
                asTrackID: transcriptOverlayTrackID
            ),
            overlayInstruction: overlayInstruction
        )
    }

    static func resolvedActiveWordTimelineStates(
        from renderUnits: [TranscriptRenderUnit],
        overlayPosition: TranscriptOverlayPosition,
        overlaySize: TranscriptOverlaySize,
        renderSize: CGSize
    ) -> [TranscriptActiveWordTimelineState] {
        let activeWordUnits =
            renderUnits
            .filter { $0.mode == .activeWord }
            .sorted { lhs, rhs in
                if abs(lhs.timeRange.lowerBound - rhs.timeRange.lowerBound) < timelineNormalizationTolerance {
                    return lhs.timeRange.upperBound < rhs.timeRange.upperBound
                }

                return lhs.timeRange.lowerBound < rhs.timeRange.lowerBound
            }

        guard activeWordUnits.isEmpty == false else { return [] }

        var timelineStates = [TranscriptActiveWordTimelineState]()
        if activeWordUnits[0].timeRange.lowerBound > timelineNormalizationTolerance {
            timelineStates.append(
                TranscriptActiveWordTimelineState(
                    time: 0,
                    text: nil,
                    frame: .zero,
                    textFrame: .zero,
                    fontSize: 0,
                    style: activeWordUnits[0].style
                )
            )
        }

        for (index, renderUnit) in activeWordUnits.enumerated() {
            let layout = TranscriptOverlayLayoutResolver.resolveActiveWordLayout(
                videoWidth: renderSize.width,
                videoHeight: renderSize.height,
                selectedPosition: overlayPosition,
                selectedSize: overlaySize,
                text: renderUnit.text,
                style: renderUnit.style
            )
            timelineStates.append(
                TranscriptActiveWordTimelineState(
                    time: renderUnit.timeRange.lowerBound,
                    text: renderUnit.text,
                    frame: layout.overlayFrame,
                    textFrame: layout.textFrame,
                    fontSize: layout.fontSize,
                    style: renderUnit.style
                )
            )

            let nextStartTime =
                index + 1 < activeWordUnits.count
                ? activeWordUnits[index + 1].timeRange.lowerBound
                : nil
            let shouldInsertGapState =
                nextStartTime == nil
                || (nextStartTime ?? renderUnit.timeRange.upperBound) - renderUnit.timeRange.upperBound
                    > timelineNormalizationTolerance

            if shouldInsertGapState {
                timelineStates.append(
                    TranscriptActiveWordTimelineState(
                        time: renderUnit.timeRange.upperBound,
                        text: nil,
                        frame: .zero,
                        textFrame: .zero,
                        fontSize: 0,
                        style: renderUnit.style
                    )
                )
            }
        }

        return normalizedActiveWordTimelineStates(
            timelineStates
        )
    }

    private static func normalizedActiveWordTimelineStates(
        _ states: [TranscriptActiveWordTimelineState]
    ) -> [TranscriptActiveWordTimelineState] {
        guard states.isEmpty == false else { return [] }

        var normalizedStates = [TranscriptActiveWordTimelineState]()

        for state in states.sorted(by: { $0.time < $1.time }) {
            if let lastState = normalizedStates.last,
                abs(lastState.time - state.time) < timelineNormalizationTolerance
            {
                normalizedStates[normalizedStates.count - 1] = state
            } else {
                normalizedStates.append(state)
            }
        }

        return normalizedStates
    }

    private static func makeActiveWordTimelineLayer(
        from timelineStates: [TranscriptActiveWordTimelineState]
    ) -> CALayer? {
        let rasterizedFrames = rasterizedActiveWordFrames(
            from: timelineStates
        )
        guard rasterizedFrames.isEmpty == false else { return nil }

        let timelineLayer = CALayer()
        timelineLayer.allowsEdgeAntialiasing = true
        timelineLayer.magnificationFilter = .linear
        timelineLayer.minificationFilter = .linear

        applyRasterizedFrame(
            rasterizedFrames[0],
            to: timelineLayer
        )

        guard
            rasterizedFrames.count > 1,
            let finalTimestamp = rasterizedFrames.last?.time,
            finalTimestamp > timelineNormalizationTolerance
        else {
            return timelineLayer
        }

        let keyTimes = rasterizedFrames.map {
            NSNumber(
                value: max(
                    min($0.time / finalTimestamp, 1),
                    0
                )
            )
        }

        let contentsAnimation = CAKeyframeAnimation(keyPath: "contents")
        contentsAnimation.values = rasterizedFrames.map(\.image)
        contentsAnimation.keyTimes = keyTimes
        contentsAnimation.beginTime = AVCoreAnimationBeginTimeAtZero
        contentsAnimation.duration = finalTimestamp
        contentsAnimation.calculationMode = .discrete
        contentsAnimation.isRemovedOnCompletion = false
        contentsAnimation.fillMode = .both

        let boundsAnimation = CAKeyframeAnimation(keyPath: "bounds")
        boundsAnimation.values = rasterizedFrames.map {
            NSValue(cgRect: CGRect(origin: .zero, size: $0.frame.size))
        }
        boundsAnimation.keyTimes = keyTimes
        boundsAnimation.beginTime = AVCoreAnimationBeginTimeAtZero
        boundsAnimation.duration = finalTimestamp
        boundsAnimation.calculationMode = .discrete
        boundsAnimation.isRemovedOnCompletion = false
        boundsAnimation.fillMode = .both

        let positionAnimation = CAKeyframeAnimation(keyPath: "position")
        positionAnimation.values = rasterizedFrames.map {
            NSValue(
                cgPoint: CGPoint(
                    x: $0.frame.midX,
                    y: $0.frame.midY
                )
            )
        }
        positionAnimation.keyTimes = keyTimes
        positionAnimation.beginTime = AVCoreAnimationBeginTimeAtZero
        positionAnimation.duration = finalTimestamp
        positionAnimation.calculationMode = .discrete
        positionAnimation.isRemovedOnCompletion = false
        positionAnimation.fillMode = .both

        timelineLayer.add(contentsAnimation, forKey: "transcript-active-word-contents")
        timelineLayer.add(boundsAnimation, forKey: "transcript-active-word-bounds")
        timelineLayer.add(positionAnimation, forKey: "transcript-active-word-position")

        return timelineLayer
    }

    private static func rasterizedActiveWordFrames(
        from timelineStates: [TranscriptActiveWordTimelineState]
    ) -> [TranscriptRasterizedFrame] {
        timelineStates.compactMap { timelineState in
            autoreleasepool {
                if timelineState.isHidden {
                    return TranscriptRasterizedFrame(
                        time: timelineState.time,
                        frame: .zero,
                        contentsScale: 1,
                        image: transparentTranscriptPixelImage()
                    )
                }

                guard let text = timelineState.text else { return nil }
                guard
                    let rasterLayout = resolvedActiveWordRasterLayout(
                        for: timelineState,
                        text: text
                    )
                else {
                    return nil
                }

                let containerFrame = CGRect(
                    origin: .zero,
                    size: rasterLayout.frame.size
                )
                let relativeTextFrame = CGRect(
                    x: rasterLayout.textFrame.minX - rasterLayout.frame.minX,
                    y: rasterLayout.textFrame.minY - rasterLayout.frame.minY,
                    width: rasterLayout.textFrame.width,
                    height: rasterLayout.textFrame.height
                )
                let contentsScale = TranscriptTextStyleResolver.resolvedTextLayerContentsScale(
                    for: timelineState.fontSize
                )
                let image =
                    makeTranscriptTextImage(
                        text: text,
                        style: timelineState.style,
                        fontSize: timelineState.fontSize,
                        containerFrame: containerFrame,
                        textFrame: relativeTextFrame,
                        alignmentMode: TranscriptTextStyleResolver.resolvedCATextAlignment(
                            for: timelineState.style.textAlignment
                        ),
                        isWrapped: false,
                        contentsScale: contentsScale
                    )
                    ?? transparentTranscriptPixelImage()

                return TranscriptRasterizedFrame(
                    time: timelineState.time,
                    frame: rasterLayout.frame,
                    contentsScale: contentsScale,
                    image: image
                )
            }
        }
    }

    static func resolvedActiveWordRasterLayout(
        for timelineState: TranscriptActiveWordTimelineState,
        text: String
    ) -> TranscriptActiveWordRasterLayout? {
        guard timelineState.isHidden == false else { return nil }
        guard timelineState.frame.isEmpty == false else { return nil }
        guard timelineState.textFrame.isEmpty == false else { return nil }

        let measuredTextWidth = min(
            TranscriptTextStyleResolver.measuredWordWidth(
                text: text,
                style: timelineState.style,
                fontSize: timelineState.fontSize
            ),
            timelineState.textFrame.width
        )
        let measuredTextHeight = min(
            TranscriptTextStyleResolver.resolvedLineHeight(
                style: timelineState.style,
                fontSize: timelineState.fontSize
            ),
            timelineState.textFrame.height
        )
        let strokePadding = resolvedActiveWordStrokePadding(
            for: timelineState.fontSize
        )
        let horizontalInset = min(
            TranscriptWordHighlightStyle.horizontalInset,
            max((timelineState.textFrame.width - measuredTextWidth) / 2, 0)
        )
        let occupiedTextWidth = min(
            measuredTextWidth + (horizontalInset * 2),
            timelineState.textFrame.width
        )
        let textOriginX =
            timelineState.textFrame.minX
            + transcriptHorizontalOffset(
                for: timelineState.style.textAlignment,
                availableWidth: timelineState.textFrame.width,
                occupiedWidth: occupiedTextWidth
            )
            + horizontalInset
        let textRect = CGRect(
            x: textOriginX,
            y: timelineState.textFrame.minY,
            width: measuredTextWidth,
            height: measuredTextHeight
        )
        let expandedFrame = textRect.insetBy(
            dx: -strokePadding,
            dy: -strokePadding
        )
        let containerFrame = expandedFrame.intersection(timelineState.frame)

        guard containerFrame.isNull == false, containerFrame.isEmpty == false else {
            return nil
        }

        let visibleTextFrame = textRect.intersection(containerFrame)

        guard visibleTextFrame.isNull == false, visibleTextFrame.isEmpty == false else {
            return nil
        }

        return TranscriptActiveWordRasterLayout(
            frame: containerFrame,
            textFrame: visibleTextFrame
        )
    }

    private static func applyRasterizedFrame(
        _ frame: TranscriptRasterizedFrame,
        to layer: CALayer
    ) {
        layer.frame = frame.frame
        layer.contentsScale = frame.contentsScale
        layer.contentsGravity = .resize
        layer.contents = frame.image
    }

    private static func transparentTranscriptPixelImage() -> CGImage {
        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.scale = 1
        rendererFormat.opaque = false

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 1, height: 1),
            format: rendererFormat
        )

        if let image = renderer.image(actions: { _ in }).cgImage {
            return image
        }

        assertionFailure("Unable to create a transparent transcript placeholder image.")

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard
            let context = CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ),
            let image = context.makeImage()
        else {
            fatalError("Failed to allocate a fallback transparent transcript image.")
        }

        return image
    }

    private static func setTimeScaleAndAddTracks(
        to composition: AVMutableComposition,
        from asset: AVAsset,
        audio: Audio?,
        timeScale: Float64,
        videoVolume: Float
    ) async throws {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        let oldTimeRange = CMTimeRangeMake(start: CMTime.zero, duration: duration)
        let destinationTimeRange = CMTimeMultiplyByFloat64(duration, multiplier: (1 / timeScale))

        if let audioTrack = audioTracks.first {
            let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: AVMediaType.audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            compositionAudioTrack?.preferredVolume = videoVolume
            try compositionAudioTrack?.insertTimeRange(oldTimeRange, of: audioTrack, at: CMTime.zero)
            compositionAudioTrack?.scaleTimeRange(oldTimeRange, toDuration: destinationTimeRange)

            let audioPreferredTransform = try await audioTrack.load(.preferredTransform)
            compositionAudioTrack?.preferredTransform = audioPreferredTransform
        }

        if let videoTrack = videoTracks.first {
            let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: AVMediaType.video, preferredTrackID: kCMPersistentTrackID_Invalid)

            try compositionVideoTrack?.insertTimeRange(oldTimeRange, of: videoTrack, at: CMTime.zero)
            compositionVideoTrack?.scaleTimeRange(oldTimeRange, toDuration: destinationTimeRange)

            let videoPreferredTransform = try await videoTrack.load(.preferredTransform)
            compositionVideoTrack?.preferredTransform = videoPreferredTransform
        }

        if let audio {
            let asset = AVURLAsset(url: audio.url)
            guard let secondAudioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                return
            }
            let secondAudioDuration = try await asset.load(.duration)
            let secondAudioTimeRange = CMTimeRange(
                start: .zero,
                duration: CMTimeMinimum(duration, secondAudioDuration)
            )

            guard secondAudioTimeRange.duration > .zero else {
                return
            }

            let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: AVMediaType.audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            compositionAudioTrack?.preferredVolume = audio.volume
            try compositionAudioTrack?.insertTimeRange(
                secondAudioTimeRange, of: secondAudioTrack, at: CMTime.zero)
            compositionAudioTrack?.scaleTimeRange(
                secondAudioTimeRange,
                toDuration: CMTimeMultiplyByFloat64(
                    secondAudioTimeRange.duration,
                    multiplier: (1 / timeScale)
                )
            )
        }
    }

    private static func export(
        _ session: AVAssetExportSession,
        to outputURL: URL,
        as fileType: AVFileType,
        progressRange: ClosedRange<Double>,
        onProgress: ProgressHandler?
    ) async throws {
        await reportProgress(progressRange.lowerBound, via: onProgress)
        let sessionBox = UncheckedExportSessionBox(session)

        let progressTask = Task {
            var lastReportedSessionProgress = -1.0

            while !Task.isCancelled {
                let sessionProgress = Double(sessionBox.session.progress)
                    .clamped(to: 0...1)

                if sessionProgress > lastReportedSessionProgress {
                    let mappedProgress =
                        progressRange.lowerBound
                        + (progressRange.upperBound - progressRange.lowerBound) * sessionProgress

                    await reportProgress(mappedProgress, via: onProgress)

                    lastReportedSessionProgress = sessionProgress
                }

                try? await Task.sleep(for: .milliseconds(120))
            }
        }

        defer {
            progressTask.cancel()
        }

        try await withTaskCancellationHandler {
            try await session.export(to: outputURL, as: fileType)
        } onCancel: {
            sessionBox.session.cancelExport()
        }

        try Task.checkCancellation()
        await reportProgress(progressRange.upperBound, via: onProgress)
    }

    private static func reportProgress(
        _ progress: Double,
        via onProgress: ProgressHandler?
    ) async {
        guard let onProgress else { return }
        await onProgress(progress.clamped(to: 0...1))
    }

    private static func transcriptHorizontalOffset(
        for alignment: TranscriptTextAlignment,
        availableWidth: CGFloat,
        occupiedWidth: CGFloat
    ) -> CGFloat {
        switch alignment {
        case .leading:
            0
        case .center:
            max((availableWidth - occupiedWidth) / 2, 0)
        case .trailing:
            max(availableWidth - occupiedWidth, 0)
        }
    }

    private static func resolvedActiveWordStrokePadding(
        for fontSize: CGFloat
    ) -> CGFloat {
        let offsets = TranscriptTextStyleResolver.resolvedStrokeOffsets(
            for: fontSize
        )
        let maximumOffset = offsets.reduce(0 as CGFloat) { currentMaximum, offset in
            max(currentMaximum, max(abs(offset.width), abs(offset.height)))
        }

        return ceil(maximumOffset)
    }

    private static func getTimeRange(for duration: Double, with timeRange: ClosedRange<Double>)
        -> CMTimeRange
    {
        let start = timeRange.lowerBound.clamped(to: 0...duration)
        let end = timeRange.upperBound.clamped(to: start...duration)
        let startTime = CMTimeMakeWithSeconds(start, preferredTimescale: 1000)
        let endTime = CMTimeMakeWithSeconds(end, preferredTimescale: 1000)
        let timeRange = CMTimeRangeFromTimeToTime(start: startTime, end: endTime)
        return timeRange
    }

    private static func progressRange(
        for stage: RenderStage,
        activeStages: [RenderStage]
    ) -> ClosedRange<Double> {
        guard let index = activeStages.firstIndex(of: stage) else { return 1...1 }
        let stageWidth = 1 / Double(activeStages.count)
        let lowerBound = Double(index) * stageWidth
        let upperBound =
            index == activeStages.count - 1
            ? 1
            : Double(index + 1) * stageWidth

        return lowerBound...upperBound
    }

    private static func subprogressRange(
        forBatchAt batchIndex: Int,
        totalBatches: Int,
        within parentRange: ClosedRange<Double>
    ) -> ClosedRange<Double> {
        guard totalBatches > 0 else { return parentRange }

        let clampedBatchIndex = min(
            max(batchIndex, 0),
            totalBatches - 1
        )
        let rangeWidth = parentRange.upperBound - parentRange.lowerBound
        let batchWidth = rangeWidth / Double(totalBatches)
        let lowerBound = parentRange.lowerBound + batchWidth * Double(clampedBatchIndex)
        let upperBound =
            clampedBatchIndex == totalBatches - 1
            ? parentRange.upperBound
            : lowerBound + batchWidth

        return lowerBound...upperBound
    }

    private static func videoCompositionInstructionForTrackWithSizeAndTime(
        preferredTransform: CGAffineTransform,
        naturalSize: CGSize,
        presentationSize: CGSize,
        renderSize: CGSize,
        track: AVAssetTrack,
        isMirror: Bool
    ) -> AVVideoCompositionLayerInstruction {
        let instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let transformedBounds = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        let normalizedTransform = preferredTransform.concatenating(
            CGAffineTransform(
                translationX: -transformedBounds.minX,
                y: -transformedBounds.minY
            )
        )
        let widthScale = renderSize.width / max(presentationSize.width, 1)
        let heightScale = renderSize.height / max(presentationSize.height, 1)
        let scaleFactor = min(widthScale, heightScale)
        let scaledContentSize = CGSize(
            width: presentationSize.width * scaleFactor,
            height: presentationSize.height * scaleFactor
        )
        let centerOffset = CGAffineTransform(
            translationX: (renderSize.width - scaledContentSize.width) / 2,
            y: (renderSize.height - scaledContentSize.height) / 2
        )

        var finalTransform =
            normalizedTransform
            .concatenating(CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))
            .concatenating(centerOffset)

        if isMirror {
            let mirrorTransform = CGAffineTransform(translationX: renderSize.width, y: 0)
                .scaledBy(x: -1, y: 1)
            finalTransform = finalTransform.concatenating(mirrorTransform)
        }

        instruction.setTransform(finalTransform, at: .zero)

        return instruction
    }

    private static func resolvedBaseRenderLayout(
        for sourceSize: CGSize,
        editingConfiguration: VideoEditingConfiguration
    ) -> VideoQuality.RenderLayout {
        let outputLayout = resolvedOutputRenderLayout(
            for: sourceSize,
            editingConfiguration: editingConfiguration
        )

        guard outputLayout == .portrait else {
            return .landscape
        }

        guard let freeformRect = editingConfiguration.crop.freeformRect else {
            return .portrait
        }

        return isFullFrameCrop(freeformRect) ? .portrait : .landscape
    }

    private static func isFullFrameCrop(
        _ freeformRect: VideoEditingConfiguration.FreeformRect
    ) -> Bool {
        abs(freeformRect.x) < 0.0001
            && abs(freeformRect.y) < 0.0001
            && abs(freeformRect.width - 1) < 0.0001
            && abs(freeformRect.height - 1) < 0.0001
    }

    private static func createTempPath() -> URL {
        let fileName = "edited-video-\(UUID().uuidString).mp4"
        let tempURL = URL.temporaryDirectory.appending(path: fileName)
        FileManager.default.removeIfExists(for: tempURL)
        return tempURL
    }

    private static func evenPixelSize(for size: CGSize) -> CGSize {
        CGSize(
            width: max(round(size.width / 2) * 2, 2),
            height: max(round(size.height / 2) * 2, 2)
        )
    }

    static func resolvedTranscriptRenderSegments(
        from transcriptDocument: TranscriptDocument
    ) -> [TranscriptRenderSegment] {
        resolvedTranscriptRenderSegments(
            from: transcriptDocument,
            timelineOffset: .zero
        )
    }

    private static func resolvedTranscriptRenderSegments(
        from transcriptDocument: TranscriptDocument,
        timelineOffset: Double
    ) -> [TranscriptRenderSegment] {
        transcriptDocument.segments.compactMap { segment in
            let trimmedText = segment.editedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedText.isEmpty == false else { return nil }
            guard let timelineRange = segment.timeMapping.timelineRange else { return nil }

            let timeRange = resolvedTranscriptRenderTimeRange(
                timelineRange,
                timelineOffset: timelineOffset
            )

            guard timeRange.upperBound > timeRange.lowerBound else { return nil }

            return TranscriptRenderSegment(
                text: trimmedText,
                timeRange: timeRange,
                style: resolvedTranscriptStyle(for: segment),
                words: resolvedTranscriptRenderWords(
                    from: segment,
                    timelineOffset: timelineOffset
                ) ?? []
            )
        }
    }

    private static func resolvedTranscriptStyle(
        for _: EditableTranscriptSegment
    ) -> TranscriptStyle {
        TranscriptStyle.defaultCaptionStyle
    }

    private static func resolvedTranscriptRenderWords(
        from segment: EditableTranscriptSegment,
        timelineOffset: Double
    ) -> [TranscriptRenderWord]? {
        let renderableWords = TranscriptWordEditingCoordinator.resolvedWords(
            for: segment
        )
        let words: [TranscriptRenderWord] = renderableWords.compactMap { word in
            let trimmedText = word.editedText.trimmingCharacters(in: .whitespacesAndNewlines)

            guard trimmedText.isEmpty == false else { return nil }
            guard let timelineRange = word.timeMapping.timelineRange else { return nil }

            let timeRange = resolvedTranscriptRenderTimeRange(
                timelineRange,
                timelineOffset: timelineOffset
            )

            guard timeRange.upperBound > timeRange.lowerBound else { return nil }

            return TranscriptRenderWord(
                id: word.id,
                text: trimmedText,
                timeRange: timeRange
            )
        }

        guard words.isEmpty == false else { return nil }

        return words
    }

    private static func resolvedTranscriptExportTimelineOffset(
        _ editingConfiguration: VideoEditingConfiguration
    ) -> Double {
        TranscriptTimeMapper.timelineTime(
            fromSourceTime: editingConfiguration.trim.lowerBound,
            rate: editingConfiguration.playback.rate
        )
    }

    private static func resolvedTranscriptRenderTimeRange(
        _ timeRange: ClosedRange<Double>,
        timelineOffset: Double
    ) -> ClosedRange<Double> {
        guard timelineOffset > timelineNormalizationTolerance else {
            return timeRange
        }

        let lowerBound = max(timeRange.lowerBound - timelineOffset, .zero)
        let upperBound = max(timeRange.upperBound - timelineOffset, lowerBound)
        let resolvedLowerBound =
            abs(lowerBound) < timelineNormalizationTolerance ? .zero : lowerBound
        let resolvedUpperBound =
            abs(upperBound - resolvedLowerBound) < timelineNormalizationTolerance
            ? resolvedLowerBound
            : upperBound

        return resolvedLowerBound...resolvedUpperBound
    }

    private static func makeTranscriptOverlayLayer(
        for renderUnit: TranscriptRenderUnit,
        overlayPosition: TranscriptOverlayPosition,
        overlaySize: TranscriptOverlaySize,
        renderSize: CGSize
    ) -> CALayer {
        switch renderUnit.mode {
        case .block:
            let layout = TranscriptOverlayLayoutResolver.resolve(
                videoWidth: renderSize.width,
                videoHeight: renderSize.height,
                selectedPosition: overlayPosition,
                selectedSize: overlaySize,
                text: renderUnit.text,
                style: renderUnit.style
            )
            let textLayer = makeTranscriptTextContentLayer(
                text: renderUnit.text,
                style: renderUnit.style,
                fontSize: layout.fontSize,
                containerFrame: layout.overlayFrame,
                textFrame: CGRect(
                    x: layout.textFrame.minX - layout.overlayFrame.minX,
                    y: layout.textFrame.minY - layout.overlayFrame.minY,
                    width: layout.textFrame.width,
                    height: layout.textFrame.height
                ),
                alignmentMode: TranscriptTextStyleResolver.resolvedCATextAlignment(
                    for: renderUnit.style.textAlignment
                ),
                isWrapped: true
            )
            textLayer.opacity = 0
            textLayer.add(
                resolvedTranscriptVisibilityAnimation(
                    for: renderUnit.timeRange
                ),
                forKey: "transcript-opacity-\(renderUnit.text.hashValue)"
            )

            return textLayer

        case .activeWord:
            let layout = TranscriptOverlayLayoutResolver.resolveActiveWordLayout(
                videoWidth: renderSize.width,
                videoHeight: renderSize.height,
                selectedPosition: overlayPosition,
                selectedSize: overlaySize,
                text: renderUnit.text,
                style: renderUnit.style
            )
            let textLayer = makeTranscriptTextContentLayer(
                text: renderUnit.text,
                style: renderUnit.style,
                fontSize: layout.fontSize,
                containerFrame: layout.overlayFrame,
                textFrame: CGRect(
                    x: layout.textFrame.minX - layout.overlayFrame.minX,
                    y: layout.textFrame.minY - layout.overlayFrame.minY,
                    width: layout.textFrame.width,
                    height: layout.textFrame.height
                ),
                alignmentMode: TranscriptTextStyleResolver.resolvedCATextAlignment(
                    for: renderUnit.style.textAlignment
                ),
                isWrapped: false
            )
            textLayer.opacity = 0
            textLayer.add(
                resolvedTranscriptVisibilityAnimation(
                    for: renderUnit.timeRange
                ),
                forKey: "transcript-word-opacity-\(renderUnit.text.hashValue)"
            )

            return textLayer
        }
    }

    static func resolvedTranscriptVisibilityAnimation(
        for timeRange: ClosedRange<Double>
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.beginTime = AVCoreAnimationBeginTimeAtZero + timeRange.lowerBound
        animation.duration = max(timeRange.upperBound - timeRange.lowerBound, 1 / 30)
        animation.values = [0, 1, 1, 0]
        animation.keyTimes = [0, 0.0001, 0.999, 1]
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        return animation
    }

    private static func makeTranscriptTextContentLayer(
        text: String,
        style: TranscriptStyle,
        fontSize: CGFloat,
        containerFrame: CGRect,
        textFrame: CGRect,
        alignmentMode: CATextLayerAlignmentMode,
        isWrapped: Bool
    ) -> CALayer {
        let containerLayer = CALayer()
        containerLayer.frame = containerFrame
        containerLayer.allowsEdgeAntialiasing = true
        let contentsScale = TranscriptTextStyleResolver.resolvedTextLayerContentsScale(
            for: fontSize
        )
        containerLayer.contentsScale = contentsScale
        containerLayer.contentsGravity = .resize
        containerLayer.magnificationFilter = .linear
        containerLayer.minificationFilter = .linear
        containerLayer.contents = makeTranscriptTextImage(
            text: text,
            style: style,
            fontSize: fontSize,
            containerFrame: containerFrame,
            textFrame: textFrame,
            alignmentMode: alignmentMode,
            isWrapped: isWrapped,
            contentsScale: contentsScale
        )

        return containerLayer
    }

    private static func makeTranscriptTextImage(
        text: String,
        style: TranscriptStyle,
        fontSize: CGFloat,
        containerFrame: CGRect,
        textFrame: CGRect,
        alignmentMode _: CATextLayerAlignmentMode,
        isWrapped: Bool,
        contentsScale: CGFloat
    ) -> CGImage? {
        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.scale = contentsScale
        rendererFormat.opaque = false

        let renderer = UIGraphicsImageRenderer(
            size: containerFrame.size,
            format: rendererFormat
        )
        let image = renderer.image { _ in
            if style.hasStroke, let strokeColor = style.strokeColor {
                let strokeText = TranscriptTextStyleResolver.attributedString(
                    text: text,
                    style: style,
                    fontSize: fontSize,
                    textColorOverride: strokeColor,
                    includesStroke: false,
                    isWrapped: isWrapped
                )

                for offset in TranscriptTextStyleResolver.resolvedStrokeOffsets(for: fontSize) {
                    strokeText.draw(
                        with: textFrame.offsetBy(
                            dx: offset.width,
                            dy: offset.height
                        ),
                        options: [.usesLineFragmentOrigin],
                        context: nil
                    )
                }
            }

            let fillText = TranscriptTextStyleResolver.attributedString(
                text: text,
                style: style,
                fontSize: fontSize,
                includesStroke: false,
                isWrapped: isWrapped
            )
            fillText.draw(
                with: textFrame,
                options: [.usesLineFragmentOrigin],
                context: nil
            )
        }

        return image.cgImage
    }

    private static func trackIntermediateOutput(
        _ outputURL: URL,
        trackedURLs: inout [URL]
    ) {
        guard trackedURLs.contains(outputURL) == false else { return }
        trackedURLs.append(outputURL)
    }

    private static func advanceIntermediateOutput(
        from previousURL: URL,
        to nextURL: URL,
        trackedURLs: inout [URL]
    ) {
        guard previousURL != nextURL else {
            trackIntermediateOutput(
                nextURL,
                trackedURLs: &trackedURLs
            )
            return
        }

        FileManager.default.removeIfExists(for: previousURL)
        trackedURLs.removeAll { $0 == previousURL }
        trackIntermediateOutput(
            nextURL,
            trackedURLs: &trackedURLs
        )
    }

    private static func cleanupIntermediateOutputs(
        _ trackedURLs: [URL],
        excluding retainedURL: URL?
    ) {
        for trackedURL in trackedURLs where trackedURL != retainedURL {
            FileManager.default.removeIfExists(for: trackedURL)
        }
    }

}

private struct UncheckedExportSessionBox: @unchecked Sendable {

    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }

}

enum ExporterError: Error, LocalizedError {
    // MARK: - Public Properties

    case unknow

    case cancelled

    case backgroundInterruption

    case cannotCreateExportSession

    case failed

    var errorDescription: String? {
        switch self {
        case .unknow:
            return VideoEditorStrings.exporterUnexpectedError
        case .cancelled:
            return VideoEditorStrings.exporterCancelledError
        case .backgroundInterruption:
            return VideoEditorStrings.exporterBackgroundInterruptionError
        case .cannotCreateExportSession:
            return VideoEditorStrings.exporterCannotCreateSessionError
        case .failed:
            return VideoEditorStrings.exporterFailedError
        }
    }
}

extension Double {

    // MARK: - Public Properties

    var degTorad: Double {
        return self * .pi / 180
    }

}

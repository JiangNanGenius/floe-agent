//
//  VideoCanvasEditorState.swift
//  VideoEditorKit
//
//  Created by Codex on 31.03.2026.
//

import CoreGraphics
import Foundation
import Observation
import SwiftUI

/// Mutable, observable canvas state used by public preview and export helpers.
@available(iOS 17.0, *)
@MainActor
@Observable
public final class VideoCanvasEditorState {

    // MARK: - Public Properties

    /// Active output preset.
    public var preset: VideoCanvasPreset = .original
    /// Custom free-canvas size used when `preset` is `.free`.
    public var freeCanvasSize = CGSize(width: 1080, height: 1080)
    /// Interactive transform applied to the source content.
    public var transform: VideoCanvasTransform = .identity
    /// Whether safe-area overlays should be shown in preview.
    public var showsSafeAreaOverlay = false

    /// Returns `true` when the current state matches the default snapshot.
    public var isIdentity: Bool {
        snapshot().isIdentity
    }

    /// Returns `true` when host UI should offer a reset action.
    public var shouldShowResetButton: Bool {
        transform.shouldShowResetButton
    }

    // MARK: - Private Properties

    private let mappingActor = VideoCanvasMappingActor()

    // MARK: - Public Methods

    /// Creates a new empty canvas state container.
    public init() {}

    /// Captures the current observable state into a serializable snapshot.
    public func snapshot() -> VideoCanvasSnapshot {
        snapshot(with: transform)
    }

    /// Captures a snapshot using a provided transform instead of the current live value.
    public func snapshot(
        with transform: VideoCanvasTransform
    ) -> VideoCanvasSnapshot {
        VideoCanvasSnapshot(
            preset: preset,
            freeCanvasSize: freeCanvasSize,
            transform: transform,
            showsSafeAreaOverlay: showsSafeAreaOverlay
        )
    }

    /// Restores observable state from a previously captured snapshot.
    public func restore(_ snapshot: VideoCanvasSnapshot) {
        preset = snapshot.preset
        freeCanvasSize = snapshot.freeCanvasSize
        transform = snapshot.transform
        showsSafeAreaOverlay = snapshot.showsSafeAreaOverlay
    }

    /// Resets the interactive transform back to identity.
    public func resetTransform() {
        transform = .identity
    }

    /// Builds a render request for preview or export work.
    public func makeRenderRequest(
        source: VideoCanvasSourceDescriptor,
        canvasSnapshot: VideoCanvasSnapshot? = nil
    ) -> VideoCanvasRenderRequest {
        mappingActor.makeRenderRequest(
            source: source,
            snapshot: canvasSnapshot ?? snapshot()
        )
    }

    /// Resolves preview layout geometry for the current canvas state.
    public func previewLayout(
        source: VideoCanvasSourceDescriptor,
        availableSize: CGSize,
        canvasSnapshot: VideoCanvasSnapshot? = nil
    ) -> VideoCanvasLayout {
        let request = makeRenderRequest(
            source: source,
            canvasSnapshot: canvasSnapshot
        )
        return mappingActor.makePreviewLayout(
            request: request,
            availableSize: availableSize
        )
    }

    /// Resolves export mapping geometry for the current canvas state.
    public func exportMapping(
        source: VideoCanvasSourceDescriptor
    ) -> VideoCanvasExportMapping {
        let request = makeRenderRequest(source: source)
        return mappingActor.makeExportMapping(request: request)
    }

    /// Applies drag interaction to a baseline transform.
    public func dragTransform(
        from baseline: VideoCanvasTransform,
        translation: CGSize,
        previewCanvasSize: CGSize,
        source: VideoCanvasSourceDescriptor
    ) -> VideoCanvasTransform {
        mappingActor.dragTransform(
            from: baseline,
            translation: translation,
            previewCanvasSize: previewCanvasSize,
            source: source,
            preset: preset,
            freeCanvasSize: freeCanvasSize
        )
    }

    /// Applies pinch interaction to a baseline transform.
    public func magnifiedTransform(
        from baseline: VideoCanvasTransform,
        magnification: CGFloat,
        anchor: CGPoint,
        previewCanvasSize: CGSize,
        source: VideoCanvasSourceDescriptor
    ) -> VideoCanvasTransform {
        mappingActor.magnifiedTransform(
            from: baseline,
            magnification: magnification,
            anchor: anchor,
            previewCanvasSize: previewCanvasSize,
            source: source,
            preset: preset,
            freeCanvasSize: freeCanvasSize
        )
    }

    /// Applies rotation interaction to a baseline transform.
    public func rotatedTransform(
        from baseline: VideoCanvasTransform,
        rotation: Angle,
        source: VideoCanvasSourceDescriptor
    ) -> VideoCanvasTransform {
        mappingActor.rotatedTransform(
            from: baseline,
            rotation: rotation,
            source: source,
            preset: preset,
            freeCanvasSize: freeCanvasSize
        )
    }

    /// Applies drag and pinch interaction in a single combined pass.
    public func interactiveTransform(
        from baseline: VideoCanvasTransform,
        translation: CGSize,
        magnification: CGFloat,
        anchor: CGPoint,
        previewCanvasSize: CGSize,
        source: VideoCanvasSourceDescriptor
    ) -> VideoCanvasTransform {
        mappingActor.interactiveTransform(
            from: baseline,
            translation: translation,
            magnification: magnification,
            anchor: anchor,
            previewCanvasSize: previewCanvasSize,
            source: source,
            preset: preset,
            freeCanvasSize: freeCanvasSize
        )
    }

    /// Converts a legacy freeform crop rect into a canvas transform.
    public func snapshotTransform(
        fromLegacyFreeformRect freeformRect: VideoEditingConfiguration.FreeformRect?,
        referenceSize: CGSize
    ) -> VideoCanvasTransform {
        let request = makeRenderRequest(
            source: .init(
                naturalSize: referenceSize,
                preferredTransform: .identity,
                userRotationDegrees: 0,
                isMirrored: false
            )
        )

        return mappingActor.snapshotTransform(
            fromLegacyFreeformRect: freeformRect,
            referenceSize: referenceSize,
            exportSize: request.resolvedPreset.exportSize
        )
    }

}

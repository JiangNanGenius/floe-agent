//
//  VideoCanvasPreviewView.swift
//  VideoEditorKit
//
//  Created by Codex on 31.03.2026.
//

import SwiftUI

public struct VideoCanvasInteractionCancellationPolicy {

    // MARK: - Public Methods

    public static func shouldCancelInteraction(
        isInteractionActive: Bool,
        baselineTransform: VideoCanvasTransform,
        incomingTransform: VideoCanvasTransform
    ) -> Bool {
        isInteractionActive && incomingTransform != baselineTransform
    }

}

public struct VideoCanvasPreviewView<Content: View, Overlay: View>: View {

    // MARK: - Bindables

    @Bindable private var editorState: VideoCanvasEditorState

    // MARK: - States

    @State private var interactionState: InteractionState?

    // MARK: - Public Properties

    private let source: VideoCanvasSourceDescriptor
    private let isInteractive: Bool
    private let cornerRadius: CGFloat
    private let onInteractionStarted: @MainActor () -> Void
    private let onInteractionEnded: @MainActor (VideoCanvasSnapshot) -> Void
    private let onSnapshotChange: @MainActor (VideoCanvasSnapshot) -> Void
    @ViewBuilder
    private var content: () -> Content
    @ViewBuilder
    private var overlayContent: () -> Overlay

    // MARK: - Body

    public var body: some View {
        GeometryReader { proxy in
            let baseLayout = editorState.previewLayout(
                source: source,
                availableSize: proxy.size
            )
            let effectiveSnapshot = resolvedSnapshot(
                previewCanvasSize: baseLayout.previewCanvasSize
            )
            let layout = editorState.previewLayout(
                source: source,
                availableSize: proxy.size,
                canvasSnapshot: effectiveSnapshot
            )

            ZStack {
                if layout.previewCanvasSize.width > 0, layout.previewCanvasSize.height > 0 {
                    canvasView(
                        layout,
                        effectiveSnapshot: effectiveSnapshot
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .onChange(of: editorState.transform) { _, newTransform in
            guard let interactionState else { return }
            guard interactionState.shouldCancel(for: newTransform) else { return }
            self.interactionState = nil
        }
    }

    // MARK: - Private Properties

    @ViewBuilder
    private func canvasView(
        _ layout: VideoCanvasLayout,
        effectiveSnapshot: VideoCanvasSnapshot
    ) -> some View {
        let contentScaleX = layout.isMirrored ? -layout.contentScale : layout.contentScale

        let canvas = ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.black)

            content()
                .frame(
                    width: layout.contentBaseSize.width,
                    height: layout.contentBaseSize.height
                )
                .scaleEffect(x: contentScaleX, y: layout.contentScale)
                .rotationEffect(.radians(layout.totalRotationRadians))
                .position(layout.contentCenter)
        }
        .frame(
            width: layout.previewCanvasSize.width,
            height: layout.previewCanvasSize.height
        )
        .clipShape(.rect(cornerRadius: cornerRadius))
        .contentShape(Rectangle())
        .animation(
            settleAnimation,
            value: effectiveSnapshot
        )
        .animation(
            settleAnimation,
            value: source
        )
        .transaction { transaction in
            if interactionState?.isActive == true {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }

        Group {
            if isInteractive {
                canvas.overlay {
                    VideoCanvasInteractionGestureView(
                        onPanChanged: { translation in
                            updateDrag(translation)
                        },
                        onPanEnded: {
                            endDrag(
                                previewCanvasSize: layout.previewCanvasSize
                            )
                        },
                        onPinchChanged: { magnification, anchor, translation in
                            updateMagnification(
                                magnification: magnification,
                                anchor: anchor,
                                translation: translation
                            )
                        },
                        onPinchEnded: {
                            endMagnification(
                                previewCanvasSize: layout.previewCanvasSize
                            )
                        },
                        onDoubleTap: {
                            resetInteraction()
                        }
                    )
                }
            } else {
                canvas
            }
        }
        .overlay {
            overlayContent()
        }
    }

    // MARK: - Initializer

    public init(
        _ editorState: VideoCanvasEditorState,
        source: VideoCanvasSourceDescriptor,
        isInteractive: Bool,
        cornerRadius: CGFloat = 28,
        onInteractionStarted: @escaping @MainActor () -> Void = {},
        onInteractionEnded: @escaping @MainActor (VideoCanvasSnapshot) -> Void = { _ in },
        onSnapshotChange: @escaping @MainActor (VideoCanvasSnapshot) -> Void = { _ in },
        @ViewBuilder content: @escaping () -> Content
    )
    where Overlay == EmptyView {
        self.editorState = editorState
        self.source = source
        self.isInteractive = isInteractive
        self.cornerRadius = cornerRadius
        self.onInteractionStarted = onInteractionStarted
        self.onInteractionEnded = onInteractionEnded
        self.onSnapshotChange = onSnapshotChange
        self.content = content
        self.overlayContent = { EmptyView() }
    }

    public init(
        _ editorState: VideoCanvasEditorState,
        source: VideoCanvasSourceDescriptor,
        isInteractive: Bool,
        cornerRadius: CGFloat = 28,
        onInteractionStarted: @escaping @MainActor () -> Void = {},
        onInteractionEnded: @escaping @MainActor (VideoCanvasSnapshot) -> Void = { _ in },
        onSnapshotChange: @escaping @MainActor (VideoCanvasSnapshot) -> Void = { _ in },
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder overlay: @escaping () -> Overlay
    ) {
        self.editorState = editorState
        self.source = source
        self.isInteractive = isInteractive
        self.cornerRadius = cornerRadius
        self.onInteractionStarted = onInteractionStarted
        self.onInteractionEnded = onInteractionEnded
        self.onSnapshotChange = onSnapshotChange
        self.content = content
        self.overlayContent = overlay
    }

    // MARK: - Private Methods

    private func updateDrag(
        _ translation: CGSize
    ) {
        let isStartingInteraction = interactionState == nil
        var interactionState =
            interactionState
            ?? .init(
                baselineTransform: editorState.transform
            )
        interactionState.translation = translation
        interactionState.isDragging = true
        self.interactionState = interactionState

        if isStartingInteraction {
            onInteractionStarted()
        }
    }

    private func updateMagnification(
        magnification: CGFloat,
        anchor: CGPoint,
        translation: CGSize
    ) {
        let isStartingInteraction = interactionState == nil
        var interactionState =
            interactionState
            ?? .init(
                baselineTransform: editorState.transform
            )
        interactionState.magnification = magnification
        interactionState.magnificationAnchor = anchor
        interactionState.translation = translation
        interactionState.isMagnifying = true
        self.interactionState = interactionState

        if isStartingInteraction {
            onInteractionStarted()
        }
    }

    private func endDrag(
        previewCanvasSize: CGSize
    ) {
        updateInteractionActivity(
            previewCanvasSize: previewCanvasSize
        ) { interactionState in
            interactionState.isDragging = false
        }
    }

    private func endMagnification(
        previewCanvasSize: CGSize
    ) {
        updateInteractionActivity(
            previewCanvasSize: previewCanvasSize
        ) { interactionState in
            interactionState.isMagnifying = false
        }
    }

    private func updateInteractionActivity(
        previewCanvasSize: CGSize,
        update: (inout InteractionState) -> Void
    ) {
        guard var interactionState else { return }
        update(&interactionState)

        if interactionState.isActive {
            self.interactionState = interactionState
            return
        }

        editorState.transform = interactionState.resolvedTransform(
            editorState: editorState,
            source: source,
            previewCanvasSize: previewCanvasSize
        )
        self.interactionState = nil
        let snapshot = editorState.snapshot()
        onSnapshotChange(snapshot)
        onInteractionEnded(snapshot)
    }

    private func resetInteraction() {
        onInteractionStarted()
        withAnimation(settleAnimation) {
            interactionState = nil
            editorState.resetTransform()
        }
        let snapshot = editorState.snapshot()
        onSnapshotChange(snapshot)
        onInteractionEnded(snapshot)
    }

    private var settleAnimation: Animation {
        VideoEditorPlaybackFocusTransitionPolicy.stageAnimation
    }

    private func resolvedSnapshot(
        previewCanvasSize: CGSize
    ) -> VideoCanvasSnapshot {
        guard let interactionState else {
            return editorState.snapshot()
        }

        return editorState.snapshot(
            with: interactionState.resolvedTransform(
                editorState: editorState,
                source: source,
                previewCanvasSize: previewCanvasSize
            )
        )
    }

}

#Preview {
    VideoCanvasPreviewView(
        VideoCanvasEditorState(),
        source: VideoCanvasSourceDescriptor(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity,
            userRotationDegrees: 0,
            isMirrored: false
        ),
        isInteractive: true
    ) {
        Rectangle()
            .fill(.blue)
    }
    .frame(height: 400)
}

private struct InteractionState {

    // MARK: - Public Properties

    let baselineTransform: VideoCanvasTransform
    var translation: CGSize = .zero
    var magnification: CGFloat = 1
    var magnificationAnchor = CGPoint(x: 0.5, y: 0.5)
    var isDragging = false
    var isMagnifying = false

    var isActive: Bool {
        isDragging || isMagnifying
    }

    // MARK: - Public Methods

    func shouldCancel(
        for transform: VideoCanvasTransform
    ) -> Bool {
        VideoCanvasInteractionCancellationPolicy.shouldCancelInteraction(
            isInteractionActive: isActive,
            baselineTransform: baselineTransform,
            incomingTransform: transform
        )
    }

    @MainActor
    func resolvedTransform(
        editorState: VideoCanvasEditorState,
        source: VideoCanvasSourceDescriptor,
        previewCanvasSize: CGSize
    ) -> VideoCanvasTransform {
        editorState.interactiveTransform(
            from: baselineTransform,
            translation: translation,
            magnification: magnification,
            anchor: magnificationAnchor,
            previewCanvasSize: previewCanvasSize,
            source: source
        )
    }

}

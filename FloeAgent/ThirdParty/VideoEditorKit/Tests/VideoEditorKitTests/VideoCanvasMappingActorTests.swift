import CoreGraphics
import Testing

@testable import VideoEditorKit

@Suite("VideoCanvasMappingActorTests")
struct VideoCanvasMappingActorTests {

    // MARK: - Private Properties

    private let widescreenSource = VideoCanvasSourceDescriptor(
        naturalSize: CGSize(width: 1920, height: 1080),
        preferredTransform: .identity,
        userRotationDegrees: 0,
        isMirrored: false
    )
    private let squareSource = VideoCanvasSourceDescriptor(
        naturalSize: CGSize(width: 1000, height: 1000),
        preferredTransform: .identity,
        userRotationDegrees: 0,
        isMirrored: false
    )
    private let squareCanvasSize = CGSize(width: 1080, height: 1080)

    // MARK: - Public Methods

    @Test
    func previewLayoutFitsThePresetCanvasIntoTheAvailablePreviewSpace() {
        let actor = VideoCanvasMappingActor()
        let request = actor.makeRenderRequest(
            source: widescreenSource,
            snapshot: VideoCanvasSnapshot(
                preset: .social(platform: .instagram),
                transform: .identity,
                showsSafeAreaOverlay: true
            )
        )

        let layout = actor.makePreviewLayout(
            request: request,
            availableSize: CGSize(width: 320, height: 360)
        )

        #expect(abs(layout.previewCanvasSize.width - 202.5) < 0.0001)
        #expect(abs(layout.previewCanvasSize.height - 360) < 0.0001)
        #expect(abs(layout.contentBaseSize.width - 360) < 0.0001)
        #expect(abs(layout.contentBaseSize.height - 202.5) < 0.0001)
        #expect(abs(layout.contentScale - 1.7777777778) < 0.0001)
    }

    @Test
    func exportMappingUsesTheResolvedPresetRenderSizeAndCanvasOffset() {
        let actor = VideoCanvasMappingActor()
        let request = actor.makeRenderRequest(
            source: VideoCanvasSourceDescriptor(
                naturalSize: CGSize(width: 1920, height: 1080),
                preferredTransform: .identity,
                userRotationDegrees: 90,
                isMirrored: true
            ),
            snapshot: VideoCanvasSnapshot(
                preset: .facebookPost,
                transform: .init(
                    normalizedOffset: CGPoint(x: 0.15, y: -0.1),
                    zoom: 1.5,
                    rotationRadians: 0.25
                ),
                showsSafeAreaOverlay: false
            )
        )

        let mapping = actor.makeExportMapping(request: request)

        #expect(mapping.renderSize == CGSize(width: 1080, height: 1350))
        #expect(mapping.orientedSourceSize == CGSize(width: 1920, height: 1080))
        #expect(mapping.aspectFillScale > 1.8)
        #expect(mapping.totalRotationRadians > 1.8)
    }

    @Test
    func previewLayoutUsesTheSameZoomedScaleAsTheExportMapping() {
        let actor = VideoCanvasMappingActor()
        let request = actor.makeRenderRequest(
            source: widescreenSource,
            snapshot: VideoCanvasSnapshot(
                preset: .facebookPost,
                transform: .init(
                    normalizedOffset: CGPoint(x: 0.12, y: -0.08),
                    zoom: 1.5,
                    rotationRadians: 0.18
                ),
                showsSafeAreaOverlay: false
            )
        )

        let layout = actor.makePreviewLayout(
            request: request,
            availableSize: CGSize(width: 320, height: 400)
        )
        let mapping = actor.makeExportMapping(request: request)

        #expect(abs(layout.contentScale - mapping.aspectFillScale) < 0.0001)
    }

    @Test
    func makeRenderRequestClampsAnInvalidStoredTransformToThePresetCoverage() {
        let actor = VideoCanvasMappingActor()
        let request = actor.makeRenderRequest(
            source: widescreenSource,
            snapshot: VideoCanvasSnapshot(
                preset: .story,
                transform: .init(
                    normalizedOffset: CGPoint(x: 1.8, y: -0.9),
                    zoom: 0.3,
                    rotationRadians: 0
                ),
                showsSafeAreaOverlay: false
            )
        )

        #expect(abs(request.snapshot.transform.zoom - 1) < 0.001)
        #expect(abs(request.snapshot.transform.normalizedOffset.x) < 1.8)
        #expect(abs(request.snapshot.transform.normalizedOffset.y) < 0.9)
        assertCanvasIsCovered(
            actor: actor,
            source: widescreenSource,
            snapshot: request.snapshot
        )
    }

    @Test
    func dragTransformClampsOffsetToKeepThePresetFullyCovered() {
        let actor = VideoCanvasMappingActor()
        let transform = actor.dragTransform(
            from: .identity,
            translation: CGSize(width: 800, height: -640),
            previewCanvasSize: CGSize(width: 202.5, height: 360),
            source: widescreenSource,
            preset: .story,
            freeCanvasSize: squareCanvasSize
        )

        #expect(abs(transform.normalizedOffset.x) < (800.0 / 202.5))
        #expect(abs(transform.normalizedOffset.y) < (640.0 / 360.0))
        assertCanvasIsCovered(
            actor: actor,
            source: widescreenSource,
            snapshot: VideoCanvasSnapshot(
                preset: .story,
                freeCanvasSize: squareCanvasSize,
                transform: transform,
                showsSafeAreaOverlay: false
            )
        )
    }

    @Test
    func magnifiedTransformClampsZoomOutBeforeThePresetExposesEmptySpace() {
        let actor = VideoCanvasMappingActor()
        let transform = actor.magnifiedTransform(
            from: .identity,
            magnification: 0.4,
            anchor: CGPoint(x: 150, y: 90),
            previewCanvasSize: CGSize(width: 202.5, height: 360),
            source: widescreenSource,
            preset: .story,
            freeCanvasSize: squareCanvasSize
        )

        #expect(abs(transform.zoom - 1) < 0.001)
        assertCanvasIsCovered(
            actor: actor,
            source: widescreenSource,
            snapshot: VideoCanvasSnapshot(
                preset: .story,
                freeCanvasSize: squareCanvasSize,
                transform: transform,
                showsSafeAreaOverlay: false
            )
        )
    }

    @Test
    func rotatedTransformRaisesZoomWhenNeededToKeepASquareCanvasCovered() {
        let actor = VideoCanvasMappingActor()
        let transform = actor.rotatedTransform(
            from: .identity,
            rotation: .degrees(45),
            source: squareSource,
            preset: .custom(width: 1080, height: 1080),
            freeCanvasSize: squareCanvasSize
        )

        #expect(transform.zoom > 1.4)
        assertCanvasIsCovered(
            actor: actor,
            source: squareSource,
            snapshot: VideoCanvasSnapshot(
                preset: .custom(width: 1080, height: 1080),
                freeCanvasSize: squareCanvasSize,
                transform: transform,
                showsSafeAreaOverlay: false
            )
        )
    }

    @Test
    func interactiveTransformKeepsTheCanvasCoveredWhileIgnoringGestureRotation() {
        let actor = VideoCanvasMappingActor()
        let baseline = VideoCanvasTransform(
            normalizedOffset: .zero,
            zoom: 1,
            rotationRadians: 0.12
        )
        let combined = actor.interactiveTransform(
            from: baseline,
            translation: CGSize(width: 180, height: -120),
            magnification: 1.6,
            anchor: CGPoint(x: 210, y: 80),
            previewCanvasSize: CGSize(width: 300, height: 300),
            source: squareSource,
            preset: .custom(width: 1080, height: 1080),
            freeCanvasSize: squareCanvasSize
        )

        #expect(combined.zoom >= 1.6)
        #expect(abs(combined.rotationRadians - baseline.rotationRadians) < 0.0001)
        #expect(abs(combined.normalizedOffset.x) > 0.01 || abs(combined.normalizedOffset.y) > 0.01)
        assertCanvasIsCovered(
            actor: actor,
            source: squareSource,
            snapshot: VideoCanvasSnapshot(
                preset: .custom(width: 1080, height: 1080),
                freeCanvasSize: squareCanvasSize,
                transform: combined,
                showsSafeAreaOverlay: false
            )
        )
    }

    @Test
    func interactiveTransformAppliesPinchCentroidTranslationAfterAnchoredZoom() {
        let actor = VideoCanvasMappingActor()
        let baseline = VideoCanvasTransform(
            normalizedOffset: .zero,
            zoom: 1,
            rotationRadians: 0
        )
        let combined = actor.interactiveTransform(
            from: baseline,
            translation: CGSize(width: 45, height: -30),
            magnification: 1.5,
            anchor: CGPoint(x: 150, y: 150),
            previewCanvasSize: CGSize(width: 300, height: 300),
            source: squareSource,
            preset: .custom(width: 1080, height: 1080),
            freeCanvasSize: squareCanvasSize
        )

        #expect(combined.zoom >= 1.5)
        #expect(combined.normalizedOffset.x > 0.1)
        #expect(combined.normalizedOffset.y < -0.05)
        #expect(abs(combined.rotationRadians) < 0.0001)
        assertCanvasIsCovered(
            actor: actor,
            source: squareSource,
            snapshot: VideoCanvasSnapshot(
                preset: .custom(width: 1080, height: 1080),
                freeCanvasSize: squareCanvasSize,
                transform: combined,
                showsSafeAreaOverlay: false
            )
        )
    }

    // MARK: - Private Methods

    private func assertCanvasIsCovered(
        actor: VideoCanvasMappingActor,
        source: VideoCanvasSourceDescriptor,
        snapshot: VideoCanvasSnapshot,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        let request = actor.makeRenderRequest(
            source: source,
            snapshot: snapshot
        )
        let mapping = actor.makeExportMapping(request: request)
        let contentPolygon = contentPolygon(from: mapping)
        let renderRect = CGRect(origin: .zero, size: mapping.renderSize)

        for corner in renderRectCorners(of: renderRect) {
            #expect(
                point(corner, isInsideConvexPolygon: contentPolygon),
                sourceLocation: .init(
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column
                )
            )
        }
    }

    private func contentPolygon(
        from mapping: VideoCanvasExportMapping
    ) -> [CGPoint] {
        renderRectCorners(
            of: CGRect(origin: .zero, size: mapping.orientedSourceSize)
        )
        .map { $0.applying(mapping.contentTransform) }
    }

    private func renderRectCorners(
        of rect: CGRect
    ) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
    }

    private func point(
        _ point: CGPoint,
        isInsideConvexPolygon polygon: [CGPoint]
    ) -> Bool {
        guard polygon.count >= 3 else { return false }

        var hasPositiveCrossProduct = false
        var hasNegativeCrossProduct = false

        for index in polygon.indices {
            let edgeStart = polygon[index]
            let edgeEnd = polygon[(index + 1) % polygon.count]
            let crossProduct =
                (edgeEnd.x - edgeStart.x) * (point.y - edgeStart.y)
                - (edgeEnd.y - edgeStart.y) * (point.x - edgeStart.x)

            if crossProduct > 0.001 {
                hasPositiveCrossProduct = true
            } else if crossProduct < -0.001 {
                hasNegativeCrossProduct = true
            }

            if hasPositiveCrossProduct && hasNegativeCrossProduct {
                return false
            }
        }

        return true
    }

}

import CoreGraphics
import Foundation
import SwiftUI

/// Stateless geometry mapper used by the package to keep canvas preview and export calculations
/// aligned.
public struct VideoCanvasMappingActor {

    // MARK: - Private Properties

    private enum Constants {
        static let minimumZoom: CGFloat = 0.25
        static let maximumZoom: CGFloat = 8
    }

    // MARK: - Public Methods

    public init() {}

    // MARK: - Public Methods

    /// Builds a render request from a source descriptor and persisted snapshot.
    public func makeRenderRequest(
        source: VideoCanvasSourceDescriptor,
        snapshot: VideoCanvasSnapshot
    ) -> VideoCanvasRenderRequest {
        let resolvedPreset = resolvePreset(
            snapshot.preset,
            naturalSize: source.resolvedPresentationSize,
            freeCanvasSize: snapshot.freeCanvasSize
        )
        return makeRenderRequest(
            source: source,
            snapshot: snapshot,
            resolvedPreset: resolvedPreset
        )
    }

    /// Builds a render request from pre-resolved preset information.
    public func makeRenderRequest(
        source: VideoCanvasSourceDescriptor,
        snapshot: VideoCanvasSnapshot,
        resolvedPreset: VideoCanvasResolvedPreset
    ) -> VideoCanvasRenderRequest {
        var normalizedSnapshot = snapshot
        normalizedSnapshot.transform = clampedTransform(
            snapshot.transform,
            source: source,
            renderSize: resolvedPreset.exportSize
        )

        return VideoCanvasRenderRequest(
            source: source,
            snapshot: normalizedSnapshot,
            resolvedPreset: resolvedPreset
        )
    }

    /// Resolves the preset and snaps the target size to an even-pixel export size.
    public func resolvePreset(
        _ preset: VideoCanvasPreset,
        naturalSize: CGSize,
        freeCanvasSize: CGSize
    ) -> VideoCanvasResolvedPreset {
        VideoCanvasResolvedPreset(
            preset: preset,
            exportSize: evenPixelSize(
                for: preset.resolvedExportSize(
                    naturalSize: naturalSize,
                    freeCanvasSize: freeCanvasSize
                )
            )
        )
    }

    /// Produces preview layout geometry for a given render request and available SwiftUI size.
    public func makePreviewLayout(
        request: VideoCanvasRenderRequest,
        availableSize: CGSize
    ) -> VideoCanvasLayout {
        let exportMapping = makeExportMapping(request: request)
        let previewCanvasSize = fittedAspectSize(
            exportMapping.renderSize,
            in: availableSize
        )
        let previewScale = scaleFactor(
            from: exportMapping.renderSize,
            to: previewCanvasSize
        )
        let normalizedOffset = request.snapshot.transform.normalizedOffset

        return VideoCanvasLayout(
            previewCanvasSize: previewCanvasSize,
            exportCanvasSize: exportMapping.renderSize,
            previewScale: previewScale,
            contentBaseSize: CGSize(
                width: exportMapping.orientedSourceSize.width * previewScale,
                height: exportMapping.orientedSourceSize.height * previewScale
            ),
            contentScale: exportMapping.aspectFillScale,
            contentCenter: CGPoint(
                x: previewCanvasSize.width / 2 + normalizedOffset.x * previewCanvasSize.width,
                y: previewCanvasSize.height / 2 + normalizedOffset.y * previewCanvasSize.height
            ),
            totalRotationRadians: exportMapping.totalRotationRadians,
            isMirrored: request.source.isMirrored
        )
    }

    /// Produces export geometry that the renderer can apply to the source content.
    public func makeExportMapping(
        request: VideoCanvasRenderRequest
    ) -> VideoCanvasExportMapping {
        let normalizedTransform = normalizedPreferredTransform(for: request.source)
        let orientedSourceSize = request.source.resolvedPresentationSize
        let renderSize = request.resolvedPreset.exportSize
        let aspectFillScale =
            max(
                renderSize.width / max(orientedSourceSize.width, 1),
                renderSize.height / max(orientedSourceSize.height, 1)
            ) * request.snapshot.transform.zoom
        let contentOffset = CGPoint(
            x: request.snapshot.transform.normalizedOffset.x * renderSize.width,
            y: request.snapshot.transform.normalizedOffset.y * renderSize.height
        )
        let totalRotationRadians =
            CGFloat(request.source.userRotationDegrees) * .pi / 180
            + request.snapshot.transform.rotationRadians

        let centeredTransform = CGAffineTransform(
            translationX: -orientedSourceSize.width / 2,
            y: -orientedSourceSize.height / 2
        )
        .concatenating(
            CGAffineTransform(scaleX: aspectFillScale, y: aspectFillScale)
        )
        .concatenating(
            request.source.isMirrored
                ? CGAffineTransform(scaleX: -1, y: 1)
                : .identity
        )
        .concatenating(
            CGAffineTransform(rotationAngle: totalRotationRadians)
        )
        .concatenating(
            CGAffineTransform(
                translationX: renderSize.width / 2 + contentOffset.x,
                y: renderSize.height / 2 + contentOffset.y
            )
        )

        return VideoCanvasExportMapping(
            renderSize: renderSize,
            orientedSourceSize: orientedSourceSize,
            aspectFillScale: aspectFillScale,
            contentTransform: normalizedTransform.concatenating(centeredTransform),
            totalRotationRadians: totalRotationRadians
        )
    }

    /// Applies a drag gesture to a baseline transform while respecting package constraints.
    public func dragTransform(
        from baseline: VideoCanvasTransform,
        translation: CGSize,
        previewCanvasSize: CGSize,
        source: VideoCanvasSourceDescriptor,
        preset: VideoCanvasPreset,
        freeCanvasSize: CGSize
    ) -> VideoCanvasTransform {
        guard previewCanvasSize.width > 0, previewCanvasSize.height > 0 else {
            return clampedInteractiveTransform(
                baseline,
                source: source,
                preset: preset,
                freeCanvasSize: freeCanvasSize
            )
        }

        var nextTransform = baseline
        nextTransform.normalizedOffset.x =
            baseline.normalizedOffset.x + translation.width / previewCanvasSize.width
        nextTransform.normalizedOffset.y =
            baseline.normalizedOffset.y + translation.height / previewCanvasSize.height

        return clampedInteractiveTransform(
            nextTransform,
            source: source,
            preset: preset,
            freeCanvasSize: freeCanvasSize
        )
    }

    /// Applies magnification using a centered anchor.
    public func magnifiedTransform(
        from baseline: VideoCanvasTransform,
        magnification: CGFloat,
        source: VideoCanvasSourceDescriptor,
        preset: VideoCanvasPreset,
        freeCanvasSize: CGSize
    ) -> VideoCanvasTransform {
        magnifiedTransform(
            from: baseline,
            magnification: magnification,
            anchor: CGPoint(x: 0.5, y: 0.5),
            previewCanvasSize: CGSize(width: 1, height: 1),
            source: source,
            preset: preset,
            freeCanvasSize: freeCanvasSize
        )
    }

    /// Applies magnification using an explicit anchor point in preview coordinates.
    public func magnifiedTransform(
        from baseline: VideoCanvasTransform,
        magnification: CGFloat,
        anchor: CGPoint,
        previewCanvasSize: CGSize,
        source: VideoCanvasSourceDescriptor,
        preset: VideoCanvasPreset,
        freeCanvasSize: CGSize
    ) -> VideoCanvasTransform {
        guard magnification.isFinite, magnification > 0 else { return baseline }

        let baselineZoom = min(
            max(baseline.zoom, Constants.minimumZoom),
            Constants.maximumZoom
        )
        let nextZoom = min(
            max(baselineZoom * magnification, Constants.minimumZoom),
            Constants.maximumZoom
        )

        var nextTransform = baseline
        nextTransform.zoom = nextZoom

        guard previewCanvasSize.width > 0, previewCanvasSize.height > 0 else {
            return clampedInteractiveTransform(
                nextTransform,
                source: source,
                preset: preset,
                freeCanvasSize: freeCanvasSize
            )
        }

        let resolvedMagnification = nextZoom / max(baselineZoom, 0.0001)
        let clampedAnchor = CGPoint(
            x: min(max(anchor.x, 0), previewCanvasSize.width),
            y: min(max(anchor.y, 0), previewCanvasSize.height)
        )
        let baselineCenter = CGPoint(
            x: previewCanvasSize.width / 2 + baseline.normalizedOffset.x * previewCanvasSize.width,
            y: previewCanvasSize.height / 2 + baseline.normalizedOffset.y * previewCanvasSize.height
        )
        let anchoredCenter = CGPoint(
            x: baselineCenter.x + (1 - resolvedMagnification) * (clampedAnchor.x - baselineCenter.x),
            y: baselineCenter.y + (1 - resolvedMagnification) * (clampedAnchor.y - baselineCenter.y)
        )

        nextTransform.normalizedOffset = CGPoint(
            x: (anchoredCenter.x - previewCanvasSize.width / 2) / previewCanvasSize.width,
            y: (anchoredCenter.y - previewCanvasSize.height / 2) / previewCanvasSize.height
        )

        return clampedInteractiveTransform(
            nextTransform,
            source: source,
            preset: preset,
            freeCanvasSize: freeCanvasSize
        )
    }

    public func rotatedTransform(
        from baseline: VideoCanvasTransform,
        rotation: Angle,
        source: VideoCanvasSourceDescriptor,
        preset: VideoCanvasPreset,
        freeCanvasSize: CGSize
    ) -> VideoCanvasTransform {
        var nextTransform = baseline
        nextTransform.rotationRadians = baseline.rotationRadians + rotation.radians
        return clampedInteractiveTransform(
            nextTransform,
            source: source,
            preset: preset,
            freeCanvasSize: freeCanvasSize
        )
    }

    public func interactiveTransform(
        from baseline: VideoCanvasTransform,
        translation: CGSize,
        magnification: CGFloat,
        anchor: CGPoint,
        previewCanvasSize: CGSize,
        source: VideoCanvasSourceDescriptor,
        preset: VideoCanvasPreset,
        freeCanvasSize: CGSize
    ) -> VideoCanvasTransform {
        let magnifiedTransform = rawMagnifiedTransform(
            from: baseline,
            magnification: magnification,
            anchor: anchor,
            previewCanvasSize: previewCanvasSize
        )
        let draggedTransform = rawDragTransform(
            from: magnifiedTransform,
            translation: translation,
            previewCanvasSize: previewCanvasSize
        )

        return clampedInteractiveTransform(
            draggedTransform,
            source: source,
            preset: preset,
            freeCanvasSize: freeCanvasSize
        )
    }

    public func snapshotTransform(
        fromLegacyFreeformRect freeformRect: VideoEditingConfiguration.FreeformRect?,
        referenceSize: CGSize,
        exportSize: CGSize
    ) -> VideoCanvasTransform {
        guard
            let freeformRect,
            let geometry = VideoCropPreviewLayout.resolvedGeometry(
                freeformRect: freeformRect,
                in: referenceSize
            )
        else {
            return .identity
        }

        let visibleRect = geometry.sourceRect
        let currentScale = max(
            exportSize.width / max(visibleRect.width, 1),
            exportSize.height / max(visibleRect.height, 1)
        )
        let baseScale = max(
            exportSize.width / max(referenceSize.width, 1),
            exportSize.height / max(referenceSize.height, 1)
        )
        let contentSize = CGSize(
            width: referenceSize.width * currentScale,
            height: referenceSize.height * currentScale
        )
        let contentOrigin = CGPoint(
            x: -visibleRect.minX * currentScale,
            y: -visibleRect.minY * currentScale
        )
        let contentCenter = CGPoint(
            x: contentOrigin.x + contentSize.width / 2,
            y: contentOrigin.y + contentSize.height / 2
        )
        let normalizedOffset = CGPoint(
            x: (contentCenter.x - exportSize.width / 2) / max(exportSize.width, 1),
            y: (contentCenter.y - exportSize.height / 2) / max(exportSize.height, 1)
        )

        return VideoCanvasTransform(
            normalizedOffset: normalizedOffset,
            zoom: currentScale / max(baseScale, 0.0001),
            rotationRadians: 0
        )
    }

    // MARK: - Private Methods

    private func normalizedPreferredTransform(
        for source: VideoCanvasSourceDescriptor
    ) -> CGAffineTransform {
        let transformedBounds = CGRect(origin: .zero, size: source.naturalSize)
            .applying(source.preferredTransform)
            .standardized

        return source.preferredTransform.concatenating(
            CGAffineTransform(
                translationX: -transformedBounds.minX,
                y: -transformedBounds.minY
            )
        )
    }

    private func fittedAspectSize(
        _ size: CGSize,
        in bounds: CGSize
    ) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        let widthScale = bounds.width / size.width
        let heightScale = bounds.height / size.height
        let scale = min(widthScale, heightScale)

        return CGSize(
            width: size.width * scale,
            height: size.height * scale
        )
    }

    private func scaleFactor(
        from originalSize: CGSize,
        to fittedSize: CGSize
    ) -> CGFloat {
        guard originalSize.width > 0, originalSize.height > 0 else { return 1 }
        guard fittedSize.width > 0, fittedSize.height > 0 else { return 1 }

        return min(
            fittedSize.width / originalSize.width,
            fittedSize.height / originalSize.height
        )
    }

    private func evenPixelSize(
        for size: CGSize
    ) -> CGSize {
        CGSize(
            width: max(round(size.width / 2) * 2, 2),
            height: max(round(size.height / 2) * 2, 2)
        )
    }

    private func rawDragTransform(
        from baseline: VideoCanvasTransform,
        translation: CGSize,
        previewCanvasSize: CGSize
    ) -> VideoCanvasTransform {
        guard previewCanvasSize.width > 0, previewCanvasSize.height > 0 else {
            return baseline
        }

        var nextTransform = baseline
        nextTransform.normalizedOffset.x =
            baseline.normalizedOffset.x + translation.width / previewCanvasSize.width
        nextTransform.normalizedOffset.y =
            baseline.normalizedOffset.y + translation.height / previewCanvasSize.height
        return nextTransform
    }

    private func rawMagnifiedTransform(
        from baseline: VideoCanvasTransform,
        magnification: CGFloat,
        anchor: CGPoint,
        previewCanvasSize: CGSize
    ) -> VideoCanvasTransform {
        guard magnification.isFinite, magnification > 0 else { return baseline }

        let baselineZoom = min(
            max(baseline.zoom, Constants.minimumZoom),
            Constants.maximumZoom
        )
        let nextZoom = min(
            max(baselineZoom * magnification, Constants.minimumZoom),
            Constants.maximumZoom
        )

        var nextTransform = baseline
        nextTransform.zoom = nextZoom

        guard previewCanvasSize.width > 0, previewCanvasSize.height > 0 else {
            return nextTransform
        }

        let resolvedMagnification = nextZoom / max(baselineZoom, 0.0001)
        let clampedAnchor = CGPoint(
            x: min(max(anchor.x, 0), previewCanvasSize.width),
            y: min(max(anchor.y, 0), previewCanvasSize.height)
        )
        let baselineCenter = CGPoint(
            x: previewCanvasSize.width / 2 + baseline.normalizedOffset.x * previewCanvasSize.width,
            y: previewCanvasSize.height / 2 + baseline.normalizedOffset.y * previewCanvasSize.height
        )
        let anchoredCenter = CGPoint(
            x: baselineCenter.x + (1 - resolvedMagnification) * (clampedAnchor.x - baselineCenter.x),
            y: baselineCenter.y + (1 - resolvedMagnification) * (clampedAnchor.y - baselineCenter.y)
        )

        nextTransform.normalizedOffset = CGPoint(
            x: (anchoredCenter.x - previewCanvasSize.width / 2) / previewCanvasSize.width,
            y: (anchoredCenter.y - previewCanvasSize.height / 2) / previewCanvasSize.height
        )
        return nextTransform
    }

    private func clampedInteractiveTransform(
        _ transform: VideoCanvasTransform,
        source: VideoCanvasSourceDescriptor,
        preset: VideoCanvasPreset,
        freeCanvasSize: CGSize
    ) -> VideoCanvasTransform {
        let resolvedPreset = resolvePreset(
            preset,
            naturalSize: source.resolvedPresentationSize,
            freeCanvasSize: freeCanvasSize
        )

        return clampedTransform(
            transform,
            source: source,
            renderSize: resolvedPreset.exportSize
        )
    }

    private func clampedTransform(
        _ transform: VideoCanvasTransform,
        source: VideoCanvasSourceDescriptor,
        renderSize: CGSize
    ) -> VideoCanvasTransform {
        guard
            renderSize.width > 0,
            renderSize.height > 0,
            source.resolvedPresentationSize.width > 0,
            source.resolvedPresentationSize.height > 0
        else {
            return transform
        }

        var nextTransform = transform
        let totalRotationRadians =
            CGFloat(source.userRotationDegrees) * .pi / 180
            + transform.rotationRadians
        let requestedZoom = min(
            max(transform.zoom, Constants.minimumZoom),
            Constants.maximumZoom
        )
        let resolvedZoom = minimumValidZoom(
            requestedZoom: requestedZoom,
            sourceSize: source.resolvedPresentationSize,
            renderSize: renderSize,
            rotationRadians: totalRotationRadians
        )

        nextTransform.zoom = resolvedZoom

        guard
            let validCenterPolygon = validCenterPolygon(
                sourceSize: source.resolvedPresentationSize,
                renderSize: renderSize,
                zoom: resolvedZoom,
                rotationRadians: totalRotationRadians
            )
        else {
            nextTransform.normalizedOffset = .zero
            return nextTransform
        }

        let desiredCenter = CGPoint(
            x: renderSize.width / 2 + nextTransform.normalizedOffset.x * renderSize.width,
            y: renderSize.height / 2 + nextTransform.normalizedOffset.y * renderSize.height
        )
        let resolvedCenter = clampedPoint(
            desiredCenter,
            to: validCenterPolygon
        )

        nextTransform.normalizedOffset = CGPoint(
            x: (resolvedCenter.x - renderSize.width / 2) / renderSize.width,
            y: (resolvedCenter.y - renderSize.height / 2) / renderSize.height
        )

        return nextTransform
    }

    private func minimumValidZoom(
        requestedZoom: CGFloat,
        sourceSize: CGSize,
        renderSize: CGSize,
        rotationRadians: CGFloat
    ) -> CGFloat {
        let clampedRequestedZoom = min(
            max(requestedZoom, Constants.minimumZoom),
            Constants.maximumZoom
        )

        guard
            hasValidCenterRegion(
                sourceSize: sourceSize,
                renderSize: renderSize,
                zoom: Constants.maximumZoom,
                rotationRadians: rotationRadians
            )
        else {
            return clampedRequestedZoom
        }

        var lowerBound = Constants.minimumZoom
        var upperBound = Constants.maximumZoom

        for _ in 0..<32 {
            let midpoint = (lowerBound + upperBound) / 2

            if hasValidCenterRegion(
                sourceSize: sourceSize,
                renderSize: renderSize,
                zoom: midpoint,
                rotationRadians: rotationRadians
            ) {
                upperBound = midpoint
            } else {
                lowerBound = midpoint
            }
        }

        return min(
            max(clampedRequestedZoom, upperBound),
            Constants.maximumZoom
        )
    }

    private func hasValidCenterRegion(
        sourceSize: CGSize,
        renderSize: CGSize,
        zoom: CGFloat,
        rotationRadians: CGFloat
    ) -> Bool {
        validCenterPolygon(
            sourceSize: sourceSize,
            renderSize: renderSize,
            zoom: zoom,
            rotationRadians: rotationRadians
        ) != nil
    }

    private func validCenterPolygon(
        sourceSize: CGSize,
        renderSize: CGSize,
        zoom: CGFloat,
        rotationRadians: CGFloat
    ) -> [CGPoint]? {
        guard
            let contentHalfSize = contentHalfSize(
                sourceSize: sourceSize,
                renderSize: renderSize,
                zoom: zoom
            )
        else {
            return nil
        }

        let renderRect = CGRect(origin: .zero, size: renderSize)
        let canvasCorners = rectCorners(of: renderRect)
        guard
            var intersectionPolygon = canvasCorners.first.map({
                rotatedRect(
                    centeredAt: $0,
                    halfSize: contentHalfSize,
                    rotationRadians: rotationRadians
                )
            })
        else {
            return nil
        }

        for corner in canvasCorners.dropFirst() {
            let allowedPolygon = rotatedRect(
                centeredAt: corner,
                halfSize: contentHalfSize,
                rotationRadians: rotationRadians
            )
            intersectionPolygon = intersectConvexPolygons(
                intersectionPolygon,
                allowedPolygon
            )

            if intersectionPolygon.isEmpty {
                return nil
            }
        }

        return intersectionPolygon
    }

    private func contentHalfSize(
        sourceSize: CGSize,
        renderSize: CGSize,
        zoom: CGFloat
    ) -> CGSize? {
        guard
            sourceSize.width > 0,
            sourceSize.height > 0,
            renderSize.width > 0,
            renderSize.height > 0
        else {
            return nil
        }

        let aspectFillScale =
            max(
                renderSize.width / sourceSize.width,
                renderSize.height / sourceSize.height
            ) * zoom

        return CGSize(
            width: sourceSize.width * aspectFillScale / 2,
            height: sourceSize.height * aspectFillScale / 2
        )
    }

    private func rectCorners(
        of rect: CGRect
    ) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
    }

    private func rotatedRect(
        centeredAt center: CGPoint,
        halfSize: CGSize,
        rotationRadians: CGFloat
    ) -> [CGPoint] {
        let cosine = cos(rotationRadians)
        let sine = sin(rotationRadians)
        let localCorners = [
            CGPoint(x: -halfSize.width, y: -halfSize.height),
            CGPoint(x: halfSize.width, y: -halfSize.height),
            CGPoint(x: halfSize.width, y: halfSize.height),
            CGPoint(x: -halfSize.width, y: halfSize.height),
        ]

        return localCorners.map { point in
            let rotatedX = point.x * cosine - point.y * sine
            let rotatedY = point.x * sine + point.y * cosine
            return CGPoint(
                x: center.x + rotatedX,
                y: center.y + rotatedY
            )
        }
    }

    private func intersectConvexPolygons(
        _ subjectPolygon: [CGPoint],
        _ clipPolygon: [CGPoint]
    ) -> [CGPoint] {
        guard subjectPolygon.isEmpty == false, clipPolygon.count >= 3 else {
            return []
        }

        let clipOrientation = polygonOrientation(of: clipPolygon)
        var output = subjectPolygon

        for index in clipPolygon.indices {
            let edgeStart = clipPolygon[index]
            let edgeEnd = clipPolygon[(index + 1) % clipPolygon.count]
            let input = output
            output = []

            guard input.isEmpty == false else { return [] }

            var previousPoint = input[input.count - 1]

            for currentPoint in input {
                let currentInside = isInside(
                    currentPoint,
                    edgeStart: edgeStart,
                    edgeEnd: edgeEnd,
                    orientation: clipOrientation
                )
                let previousInside = isInside(
                    previousPoint,
                    edgeStart: edgeStart,
                    edgeEnd: edgeEnd,
                    orientation: clipOrientation
                )

                if currentInside {
                    if previousInside == false,
                        let intersectionPoint = lineIntersection(
                            from: previousPoint,
                            to: currentPoint,
                            edgeStart: edgeStart,
                            edgeEnd: edgeEnd
                        )
                    {
                        output.append(intersectionPoint)
                    }

                    output.append(currentPoint)
                } else if previousInside,
                    let intersectionPoint = lineIntersection(
                        from: previousPoint,
                        to: currentPoint,
                        edgeStart: edgeStart,
                        edgeEnd: edgeEnd
                    )
                {
                    output.append(intersectionPoint)
                }

                previousPoint = currentPoint
            }
        }

        return normalizedPolygon(output)
    }

    private func polygonOrientation(
        of polygon: [CGPoint]
    ) -> CGFloat {
        guard polygon.count >= 3 else { return 1 }

        var signedArea: CGFloat = 0

        for index in polygon.indices {
            let currentPoint = polygon[index]
            let nextPoint = polygon[(index + 1) % polygon.count]
            signedArea += currentPoint.x * nextPoint.y - nextPoint.x * currentPoint.y
        }

        return signedArea >= 0 ? 1 : -1
    }

    private func isInside(
        _ point: CGPoint,
        edgeStart: CGPoint,
        edgeEnd: CGPoint,
        orientation: CGFloat
    ) -> Bool {
        let crossProduct =
            (edgeEnd.x - edgeStart.x) * (point.y - edgeStart.y)
            - (edgeEnd.y - edgeStart.y) * (point.x - edgeStart.x)

        return orientation * crossProduct >= -0.001
    }

    private func lineIntersection(
        from start: CGPoint,
        to end: CGPoint,
        edgeStart: CGPoint,
        edgeEnd: CGPoint
    ) -> CGPoint? {
        let segmentDelta = CGPoint(
            x: end.x - start.x,
            y: end.y - start.y
        )
        let edgeDelta = CGPoint(
            x: edgeEnd.x - edgeStart.x,
            y: edgeEnd.y - edgeStart.y
        )
        let denominator = segmentDelta.x * edgeDelta.y - segmentDelta.y * edgeDelta.x

        guard abs(denominator) > 0.0001 else { return nil }

        let startToEdge = CGPoint(
            x: edgeStart.x - start.x,
            y: edgeStart.y - start.y
        )
        let parameter =
            (startToEdge.x * edgeDelta.y - startToEdge.y * edgeDelta.x)
            / denominator

        return CGPoint(
            x: start.x + segmentDelta.x * parameter,
            y: start.y + segmentDelta.y * parameter
        )
    }

    private func normalizedPolygon(
        _ polygon: [CGPoint]
    ) -> [CGPoint] {
        guard polygon.isEmpty == false else { return [] }

        var normalized: [CGPoint] = []

        for point in polygon {
            if let lastPoint = normalized.last,
                squaredDistance(from: lastPoint, to: point) < 0.0001
            {
                continue
            }

            normalized.append(point)
        }

        if normalized.count >= 2,
            let firstPoint = normalized.first,
            let lastPoint = normalized.last,
            squaredDistance(from: firstPoint, to: lastPoint) < 0.0001
        {
            normalized.removeLast()
        }

        return normalized
    }

    private func clampedPoint(
        _ point: CGPoint,
        to polygon: [CGPoint]
    ) -> CGPoint {
        let normalized = normalizedPolygon(polygon)

        switch normalized.count {
        case 0:
            return point
        case 1:
            return normalized[0]
        case 2:
            return closestPoint(
                onSegmentFrom: normalized[0],
                to: normalized[1],
                point: point
            )
        default:
            if pointInsideConvexPolygon(point, polygon: normalized) {
                return point
            }

            var bestPoint = normalized[0]
            var bestDistance = squaredDistance(from: point, to: bestPoint)

            for index in normalized.indices {
                let segmentStart = normalized[index]
                let segmentEnd = normalized[(index + 1) % normalized.count]
                let candidatePoint = closestPoint(
                    onSegmentFrom: segmentStart,
                    to: segmentEnd,
                    point: point
                )
                let candidateDistance = squaredDistance(
                    from: point,
                    to: candidatePoint
                )

                if candidateDistance < bestDistance {
                    bestDistance = candidateDistance
                    bestPoint = candidatePoint
                }
            }

            return bestPoint
        }
    }

    private func pointInsideConvexPolygon(
        _ point: CGPoint,
        polygon: [CGPoint]
    ) -> Bool {
        let orientation = polygonOrientation(of: polygon)

        for index in polygon.indices {
            let edgeStart = polygon[index]
            let edgeEnd = polygon[(index + 1) % polygon.count]

            if isInside(
                point,
                edgeStart: edgeStart,
                edgeEnd: edgeEnd,
                orientation: orientation
            ) == false {
                return false
            }
        }

        return true
    }

    private func closestPoint(
        onSegmentFrom start: CGPoint,
        to end: CGPoint,
        point: CGPoint
    ) -> CGPoint {
        let delta = CGPoint(
            x: end.x - start.x,
            y: end.y - start.y
        )
        let segmentLengthSquared = delta.x * delta.x + delta.y * delta.y

        guard segmentLengthSquared > 0.0001 else { return start }

        let projection =
            ((point.x - start.x) * delta.x + (point.y - start.y) * delta.y)
            / segmentLengthSquared
        let clampedProjection = min(max(projection, 0), 1)

        return CGPoint(
            x: start.x + delta.x * clampedProjection,
            y: start.y + delta.y * clampedProjection
        )
    }

    private func squaredDistance(
        from start: CGPoint,
        to end: CGPoint
    ) -> CGFloat {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        return deltaX * deltaX + deltaY * deltaY
    }

}

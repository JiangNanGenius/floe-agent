// FloeApp — Image workbench preview: direct manipulation, crop overlay and
// freehand drawing. All gestures commit through the shared edit commands.

import SwiftUI
import FloeCore
import FloeWorkbench
#if canImport(UIKit)
import UIKit
#endif

struct WorkbenchImagePreview: View {
    @ObservedObject var center: WorkbenchCenter

    @State private var dragTranslation: CGSize = .zero
    @State private var liveScale: Double?
    @State private var liveRotation: Double?
    @State private var freehandPoints: [CGPoint] = []
    @State private var cropGestureStart: NormalizedRect?

    private var selectedLayer: ImageLayer? {
        center.project?.imageLayers.first { $0.id == center.selectedLayerID }
    }

    var body: some View {
        GeometryReader { geometry in
            let display = displayRect(in: geometry.size)
            ZStack {
                if center.compareWithSource, let reference = center.sourcePreviewImage {
                    Image(decorative: reference, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .overlay(alignment: .topLeading) {
                            Text(WorkbenchText.t("原图", "Original"))
                                .font(.caption.bold())
                                .padding(6)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(8)
                        }
                } else if let image = center.previewImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    ProgressView()
                }

                if center.isDrawingFreehand {
                    Path { path in
                        guard let first = freehandPoints.first else { return }
                        path.move(to: first)
                        for point in freehandPoints.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }

                if center.isCropping, let crop = center.cropRect {
                    cropOverlay(crop: crop, display: display)
                        .gesture(cropMoveGesture(display: display))
                } else if let layer = selectedLayer, !center.isDrawingFreehand {
                    selectionOverlay(layer: layer, display: display)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(display: display))
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in liveScale = selectedLayer.map { $0.transform.scale * Double(value) } }
                    .onEnded { value in
                        defer { liveScale = nil }
                        guard let layer = selectedLayer else { return }
                        let scale = min(max(layer.transform.scale * Double(value), 0.1), 5)
                        center.apply(.updateLayer(id: layer.id,
                                                  transform: ImageLayerTransform(centerX: layer.transform.centerX,
                                                                                 centerY: layer.transform.centerY,
                                                                                 scale: scale,
                                                                                 rotationDegrees: layer.transform.rotationDegrees),
                                                  opacity: nil, isHidden: nil, isLocked: nil,
                                                  adjustment: nil, text: nil, crop: .unchanged))
                    }
            )
            .simultaneousGesture(
                RotationGesture()
                    .onChanged { value in liveRotation = selectedLayer.map { $0.transform.rotationDegrees + value.degrees } }
                    .onEnded { value in
                        defer { liveRotation = nil }
                        guard let layer = selectedLayer else { return }
                        var degrees = (layer.transform.rotationDegrees + value.degrees).truncatingRemainder(dividingBy: 360)
                        if degrees < 0 { degrees += 360 }
                        center.apply(.updateLayer(id: layer.id,
                                                  transform: ImageLayerTransform(centerX: layer.transform.centerX,
                                                                                 centerY: layer.transform.centerY,
                                                                                 scale: layer.transform.scale,
                                                                                 rotationDegrees: degrees),
                                                  opacity: nil, isHidden: nil, isLocked: nil,
                                                  adjustment: nil, text: nil, crop: .unchanged))
                    }
            )
            .onTapGesture { location in
                selectLayer(at: location, display: display)
            }
        }
        .accessibilityIdentifier("workbench.preview.image")
    }

    // MARK: Geometry

    private func displayRect(in size: CGSize) -> CGRect {
        guard let project = center.project, let canvas = project.canvas, canvas.width > 0, canvas.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = min(size.width / CGFloat(canvas.width), size.height / CGFloat(canvas.height))
        let width = CGFloat(canvas.width) * scale
        let height = CGFloat(canvas.height) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    // MARK: Gestures

    private func dragGesture(display: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if center.isDrawingFreehand {
                    let point = value.location
                    guard display.contains(point) else { return }
                    freehandPoints.append(point)
                } else if center.isCropping {
                    // Movement handled by the crop overlay gesture.
                } else {
                    dragTranslation = value.translation
                }
            }
            .onEnded { value in
                if center.isDrawingFreehand {
                    commitFreehand(display: display)
                    return
                }
                defer { dragTranslation = .zero }
                guard let layer = selectedLayer, display.width > 0, display.height > 0 else { return }
                let dx = value.translation.width / display.width
                let dy = value.translation.height / display.height
                guard abs(dx) > 0.001 || abs(dy) > 0.001 else { return }
                center.apply(.updateLayer(id: layer.id,
                                          transform: ImageLayerTransform(
                                            centerX: min(max(layer.transform.centerX + dx, 0), 1),
                                            centerY: min(max(layer.transform.centerY + dy, 0), 1),
                                            scale: layer.transform.scale,
                                            rotationDegrees: layer.transform.rotationDegrees),
                                          opacity: nil, isHidden: nil, isLocked: nil,
                                          adjustment: nil, text: nil, crop: .unchanged))
            }
    }

    private func commitFreehand(display: CGRect) {
        defer { freehandPoints = [] }
        guard display.width > 0, display.height > 0, freehandPoints.count >= 2 else { return }
        let points = freehandPoints.map { point in
            ImageFreehandStroke.Point(x: min(max((point.x - display.minX) / display.width, 0), 1),
                                      y: min(max((point.y - display.minY) / display.height, 0), 1))
        }
        let stroke = ImageFreehandStroke(points: points, width: 4, colorHex: "#FF3B30")
        let layer = ImageLayer(kind: .freehand, name: WorkbenchText.t("手绘", "Freehand"),
                               freehand: ImageFreehandContent(strokes: [stroke]))
        if center.apply(.addImageLayer(layer)) {
            center.selectedLayerID = layer.id
        }
        center.isDrawingFreehand = false
    }

    private func cropMoveGesture(display: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard display.width > 0, let current = center.cropRect else { return }
                if cropGestureStart == nil { cropGestureStart = current }
                guard let start = cropGestureStart else { return }
                let dx = value.translation.width / display.width
                let dy = value.translation.height / display.height
                let x = min(max(start.x + dx, 0), 1 - start.width)
                let y = min(max(start.y + dy, 0), 1 - start.height)
                center.cropRect = NormalizedRect(x: x, y: y, width: start.width, height: start.height)
            }
            .onEnded { _ in cropGestureStart = nil }
    }

    private func selectLayer(at point: CGPoint, display: CGRect) {
        guard let project = center.project, display.width > 0 else { return }
        let normalized = CGPoint(x: (point.x - display.minX) / display.width,
                                 y: (point.y - display.minY) / display.height)
        // Topmost visible, unlocked layer whose center region contains the tap.
        let candidates = project.imageLayers.reversed().filter { !$0.isHidden }
        for layer in candidates {
            let radius = 0.32 * max(layer.transform.scale, 0.2)
            let dx = normalized.x - layer.transform.centerX
            let dy = normalized.y - layer.transform.centerY
            if (dx * dx + dy * dy).squareRoot() <= radius {
                center.selectedLayerID = layer.id
                return
            }
        }
        center.selectedLayerID = candidates.last?.id
    }

    // MARK: Overlays

    @ViewBuilder
    private func selectionOverlay(layer: ImageLayer, display: CGRect) -> some View {
        let centerPoint = CGPoint(
            x: display.minX + CGFloat(layer.transform.centerX + dragTranslation.width / max(display.width, 1)) * display.width,
            y: display.minY + CGFloat(layer.transform.centerY + dragTranslation.height / max(display.height, 1)) * display.height)
        let size = CGSize(width: display.width * 0.5 * CGFloat(liveScale ?? layer.transform.scale),
                          height: display.height * 0.5 * CGFloat(liveScale ?? layer.transform.scale))
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .frame(width: size.width, height: size.height)
                .rotationEffect(.degrees(liveRotation ?? layer.transform.rotationDegrees))
                .position(centerPoint)
            Image(systemName: layer.isLocked ? "lock.fill" : "move.3d")
                .foregroundStyle(Color.accentColor)
                .position(x: centerPoint.x, y: centerPoint.y - size.height / 2 - 16)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func cropOverlay(crop: NormalizedRect, display: CGRect) -> some View {
        let rect = CGRect(x: display.minX + CGFloat(crop.x) * display.width,
                          y: display.minY + CGFloat(crop.y) * display.height,
                          width: CGFloat(crop.width) * display.width,
                          height: CGFloat(crop.height) * display.height)
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .reverseMask {
                    Rectangle().frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            cornerHandle(position: CGPoint(x: rect.maxX, y: rect.maxY), display: display,
                         anchor: .bottomTrailing)
            cornerHandle(position: CGPoint(x: rect.minX, y: rect.minY), display: display,
                         anchor: .topLeading)
            cornerHandle(position: CGPoint(x: rect.maxX, y: rect.minY), display: display,
                         anchor: .topTrailing)
            cornerHandle(position: CGPoint(x: rect.minX, y: rect.maxY), display: display,
                         anchor: .bottomLeading)
        }
    }

    @ViewBuilder
    private func cornerHandle(position: CGPoint, display: CGRect, anchor: CropAnchor) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 22, height: 22)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
            .position(position)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard let start = cropGestureStart ?? center.cropRect else { return }
                        cropGestureStart = start
                        let dx = value.translation.width / max(display.width, 1)
                        let dy = value.translation.height / max(display.height, 1)
                        center.cropRect = anchor.resized(start, dx: dx, dy: dy)
                    }
                    .onEnded { _ in cropGestureStart = nil }
            )
    }
}

enum CropAnchor {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    func resized(_ rect: NormalizedRect, dx: Double, dy: Double) -> NormalizedRect {
        let minSize = 0.05
        var x = rect.x, y = rect.y, width = rect.width, height = rect.height
        switch self {
        case .topLeading:
            let newX = min(max(x + dx, 0), x + width - minSize)
            let newY = min(max(y + dy, 0), y + height - minSize)
            width += (x - newX); height += (y - newY); x = newX; y = newY
        case .topTrailing:
            let newY = min(max(y + dy, 0), y + height - minSize)
            width = min(max(width + dx, minSize), 1 - x)
            height += (y - newY); y = newY
        case .bottomLeading:
            let newX = min(max(x + dx, 0), x + width - minSize)
            width += (x - newX); x = newX
            height = min(max(height + dy, minSize), 1 - y)
        case .bottomTrailing:
            width = min(max(width + dx, minSize), 1 - x)
            height = min(max(height + dy, minSize), 1 - y)
        }
        return NormalizedRect(x: x, y: y, width: width, height: height)
    }
}

extension View {
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .center) {
                    mask().blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}

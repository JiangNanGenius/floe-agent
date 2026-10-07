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
    @State private var freehandPressures: [Double] = []
    @State private var freehandWidths: [Double] = []
    @State private var selectionPoints: [CGPoint] = []
    @State private var cropGestureStart: NormalizedRect?

    private var selectedLayer: ImageLayer? {
        center.project?.imageLayers.first { $0.id == center.selectedLayerID }
    }

    private var isInkTool: Bool {
        center.imageTool == .brush || center.imageTool == .eraser
    }

    var body: some View {
        GeometryReader { geometry in
            let display = displayRect(in: geometry.size)
            ZStack {
                if center.showsCheckerboard {
                    CheckerboardBackground()
                        .frame(width: display.width, height: display.height)
                        .position(x: display.midX, y: display.midY)
                }
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

                // Vector selection overlay (project-level selection), visible
                // for the marquee tool and whenever a selection exists.
                if center.imageTool == .marquee || !(center.project?.imageSelection?.isEmpty ?? true) {
                    selectionMaskOverlay(display: display)
                        .allowsHitTesting(false)
                }

                // Live marquee draft.
                if !selectionPoints.isEmpty, center.imageTool == .marquee {
                    marqueeDraftPath()
                        .stroke(Color.white.opacity(0.9),
                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }

                if center.isDrawingFreehand {
                    Path { path in
                        guard let first = freehandPoints.first else { return }
                        path.move(to: first)
                        for point in freehandPoints.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(center.imageTool == .eraser ? Color.white : WorkbenchPreviewColor.color(center.brushColorHex),
                            style: StrokeStyle(lineWidth: max(1, center.brushWidth * 0.5),
                                               lineCap: .round, lineJoin: .round))
                    .opacity(center.imageTool == .eraser ? 0.7 : center.brushOpacity)
                }

                if center.isCropping, let crop = center.cropRect {
                    cropOverlay(crop: crop, display: display)
                        .gesture(cropMoveGesture(display: display))
                } else if let layer = selectedLayer, !center.isDrawingFreehand,
                          center.imageTool == .move {
                    selectionOverlay(layer: layer, display: display)
                }

                // Pencil pressure capture for brush/eraser (finger strokes have
                // no pressure and stay fixed width).
                if isInkTool {
                    WorkbenchPressureSurface(
                        onChanged: { point, pressure in
                            guard display.contains(point) else { return }
                            if freehandPoints.isEmpty {
                                freehandPoints = [point]
                                freehandPressures = [pressure]
                                freehandWidths = [max(0.15, pressure)]
                            } else {
                                freehandPoints.append(point)
                                freehandPressures.append(pressure)
                                freehandWidths.append(max(0.15, pressure))
                            }
                        },
                        onEnded: {
                            commitInkStroke(display: display)
                        })
                    .frame(width: display.width, height: display.height)
                    .position(x: display.midX, y: display.midY)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(display: display))
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in liveScale = selectedLayer.map { $0.transform.scale * Double(value) } }
                    .onEnded { value in
                        defer { liveScale = nil }
                        guard center.imageTool == .move, let layer = selectedLayer else { return }
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
                        guard center.imageTool == .move, let layer = selectedLayer else { return }
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
                handleTap(at: location, display: display)
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
                if isInkTool { return } // pressure surface owns ink gestures
                if center.imageTool == .marquee {
                    guard display.contains(value.location) else { return }
                    if selectionPoints.isEmpty {
                        selectionPoints = [value.location, value.location]
                    } else {
                        selectionPoints[selectionPoints.count - 1] = value.location
                    }
                } else if center.isCropping {
                    // Movement handled by the crop overlay gesture.
                } else if center.imageTool == .move {
                    dragTranslation = value.translation
                }
            }
            .onEnded { value in
                if isInkTool { return }
                if center.imageTool == .marquee {
                    commitMarquee(display: display, end: value.location)
                    return
                }
                defer { dragTranslation = .zero }
                guard center.imageTool == .move,
                      let layer = selectedLayer, display.width > 0, display.height > 0 else { return }
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

    private func normalizedPoint(_ point: CGPoint, display: CGRect) -> ImageFreehandStroke.Point {
        ImageFreehandStroke.Point(
            x: min(max((point.x - display.minX) / max(display.width, 1), 0), 1),
            y: min(max((point.y - display.minY) / max(display.height, 1), 0), 1))
    }

    private func commitMarquee(display: CGRect, end: CGPoint) {
        defer { selectionPoints = [] }
        guard display.width > 0, display.height > 0, selectionPoints.count >= 2 else { return }
        var points = selectionPoints
        points[points.count - 1] = end
        let normalized = points.map { normalizedPoint($0, display: display) }
        switch center.selectionKind {
        case .rectangle, .ellipse:
            guard let first = normalized.first, let last = normalized.last else { return }
            center.commitSelectionShape(kind: center.selectionKind,
                                        operation: center.selectionOperation,
                                        points: [first, last])
        case .lasso:
            guard normalized.count >= 3 else { return }
            center.commitSelectionShape(kind: .lasso, operation: center.selectionOperation,
                                        points: normalized)
        }
    }

    private func commitInkStroke(display: CGRect) {
        defer {
            freehandPoints = []
            freehandPressures = []
            freehandWidths = []
        }
        guard display.width > 0, display.height > 0, freehandPoints.count >= 2 else { return }
        let points = freehandPoints.enumerated().map { index, point -> ImageFreehandStroke.Point in
            let p = normalizedPoint(point, display: display)
            let pressure = center.brushUsesPressure
                ? (index < freehandPressures.count ? freehandPressures[index] : nil)
                : nil
            return ImageFreehandStroke.Point(x: p.x, y: p.y, pressure: pressure)
        }
        if center.imageTool == .eraser {
            center.commitMaskStroke(ImageMaskStroke(points: points,
                                                    width: center.brushWidth,
                                                    hardness: center.brushHardness,
                                                    restore: center.maskRestore))
            return
        }
        let stroke = ImageFreehandStroke(points: points,
                                         width: center.brushWidth,
                                         colorHex: center.brushColorHex,
                                         hardness: center.brushHardness,
                                         opacity: center.brushOpacity)
        center.commitBrushStroke(stroke)
    }

    private func handleTap(at point: CGPoint, display: CGRect) {
        switch center.imageTool {
        case .eyedropper:
            guard display.contains(point) else { return }
            let normalized = normalizedPoint(point, display: display)
            if let hex = center.sampleColor(atNormalized: CGPoint(x: normalized.x, y: normalized.y)) {
                center.brushColorHex = hex
                center.imageTool = .brush
                center.isDrawingFreehand = true
            }
        case .move:
            selectLayer(at: point, display: display)
        case .marquee, .brush, .eraser:
            break
        }
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

    private func selectionMaskOverlay(display: CGRect) -> some View {
        let selection = center.project?.imageSelection
        return ZStack {
            if let selection, !selection.isEmpty {
                SelectionShapePath(shapes: selection.shapes, display: display, inverted: selection.inverted)
                    .fill(Color.white.opacity(0.18))
                SelectionShapePath(shapes: selection.shapes, display: display, inverted: selection.inverted)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
        }
    }

    private func marqueeDraftPath() -> Path {
        Path { path in
            guard selectionPoints.count >= 2 else { return }
            switch center.selectionKind {
            case .rectangle, .ellipse:
                let rect = CGRect(x: min(selectionPoints[0].x, selectionPoints[selectionPoints.count - 1].x),
                                  y: min(selectionPoints[0].y, selectionPoints[selectionPoints.count - 1].y),
                                  width: abs(selectionPoints[selectionPoints.count - 1].x - selectionPoints[0].x),
                                  height: abs(selectionPoints[selectionPoints.count - 1].y - selectionPoints[0].y))
                if center.selectionKind == .ellipse {
                    path.addEllipse(in: rect)
                } else {
                    path.addRect(rect)
                }
            case .lasso:
                path.move(to: selectionPoints[0])
                for point in selectionPoints.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
            }
        }
    }

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

/// Draws vector selection shapes in normalized coordinates mapped onto the
/// preview's display rect.
struct SelectionShapePath: Shape {
    var shapes: [ImageSelectionShape]
    var display: CGRect
    var inverted: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func map(_ point: ImageFreehandStroke.Point) -> CGPoint {
            CGPoint(x: display.minX + CGFloat(point.x) * display.width,
                    y: display.minY + CGFloat(point.y) * display.height)
        }
        for shape in shapes {
            switch shape.kind {
            case .rectangle, .ellipse:
                guard shape.points.count == 2 else { continue }
                let a = map(shape.points[0]); let b = map(shape.points[1])
                let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                 width: abs(b.x - a.x), height: abs(b.y - a.y))
                if shape.kind == .ellipse {
                    path.addEllipse(in: box)
                } else {
                    path.addRect(box)
                }
            case .lasso:
                guard shape.points.count >= 3 else { continue }
                path.move(to: map(shape.points[0]))
                for point in shape.points.dropFirst() { path.addLine(to: map(point)) }
                path.closeSubpath()
            }
        }
        if inverted {
            // Visual marker for an inverted selection: full-canvas outline.
            path.addRect(display)
        }
        return path
    }
}

/// Checkerboard transparency backdrop so transparent pixels are visible.
struct CheckerboardBackground: View {
    var square: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            let columns = Int(ceil(size.width / square))
            let rows = Int(ceil(size.height / square))
            for row in 0..<rows {
                for column in 0..<columns {
                    let isDark = (row + column) % 2 == 0
                    let rect = CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square,
                                      width: square, height: square)
                    context.fill(Path(rect), with: .color(isDark ? Color(white: 0.82) : Color(white: 0.94)))
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Minimal hex → Color parser for preview strokes.
enum WorkbenchPreviewColor {
    static func color(_ hex: String) -> Color {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let int = UInt32(value, radix: 16) else { return .accentColor }
        return Color(red: Double((int >> 16) & 0xFF) / 255,
                     green: Double((int >> 8) & 0xFF) / 255,
                     blue: Double(int & 0xFF) / 255)
    }
}

#if canImport(UIKit)
/// Captures Pencil/finger touches with `force` for brush/eraser strokes. The
/// pressure is 0 for fingers/unsupported input, and the model never
/// synthesizes pressure where none was measured.
struct WorkbenchPressureSurface: UIViewRepresentable {
    var onChanged: (CGPoint, Double) -> Void
    var onEnded: () -> Void

    func makeUIView(context: Context) -> PressureTouchView {
        let view = PressureTouchView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = false
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateUIView(_ uiView: PressureTouchView, context: Context) {
        uiView.onChanged = onChanged
        uiView.onEnded = onEnded
    }

    final class PressureTouchView: UIView {
        var onChanged: ((CGPoint, Double) -> Void)?
        var onEnded: (() -> Void)?
        private var activeTouch: UITouch?
        private var hasMoved = false

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first else { return }
            activeTouch = touch
            hasMoved = false
            onChanged?(touch.location(in: self), normalizedForce(touch))
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first, touch === activeTouch else { return }
            hasMoved = true
            // Coalesced touches give the full Pencil sample rate.
            if let coalesced = event?.coalescedTouches(for: touch), !coalesced.isEmpty {
                for sample in coalesced {
                    onChanged?(sample.location(in: self), normalizedForce(sample))
                }
            } else {
                onChanged?(touch.location(in: self), normalizedForce(touch))
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            activeTouch = nil
            onEnded?()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            activeTouch = nil
            onEnded?()
        }

        private func normalizedForce(_ touch: UITouch) -> Double {
            guard touch.type == .pencil, touch.maximumPossibleForce > 0 else { return 0 }
            return min(max(Double(touch.force / touch.maximumPossibleForce), 0), 1)
        }
    }
}
#endif


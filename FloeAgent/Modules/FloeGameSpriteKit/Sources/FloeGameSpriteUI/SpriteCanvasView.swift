// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import CoreGraphics
import FloeGameCore
import FloeGameEditingCore
import FloeGameEditingUI
import FloeGameSpriteCore

/// Integer-pixel mapping between the viewport and the sprite image. All
/// coordinates use a top-left origin, matching the stored pixel rows.
struct SpriteCanvasTransform {
    static let minimumZoom: CGFloat = 0.5
    static let maximumZoom: CGFloat = 32

    let viewSize: CGSize
    let imageSize: SpritePixelSize
    let zoom: CGFloat
    let pan: CGSize

    var fitScale: CGFloat {
        let availableWidth = max(viewSize.width - 32, 1)
        let availableHeight = max(viewSize.height - 32, 1)
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return min(availableWidth / CGFloat(imageSize.width),
                   availableHeight / CGFloat(imageSize.height))
    }

    var scale: CGFloat { max(0.001, fitScale * min(max(zoom, Self.minimumZoom), Self.maximumZoom)) }

    var imageRect: CGRect {
        let width = CGFloat(imageSize.width) * scale
        let height = CGFloat(imageSize.height) * scale
        return CGRect(x: (viewSize.width - width) / 2 + pan.width,
                      y: (viewSize.height - height) / 2 + pan.height,
                      width: width, height: height)
    }

    func pixelPoint(from viewPoint: CGPoint) -> SpritePixelPoint? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let x = Int(floor((viewPoint.x - imageRect.minX) / scale))
        let y = Int(floor((viewPoint.y - imageRect.minY) / scale))
        guard x >= 0, y >= 0, x < imageSize.width, y < imageSize.height else { return nil }
        return SpritePixelPoint(x: x, y: y)
    }

    func imagePoint(from viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: (viewPoint.x - imageRect.minX) / scale,
                y: (viewPoint.y - imageRect.minY) / scale)
    }

    func screenPoint(_ point: SpritePixelPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + (CGFloat(point.x) + 0.5) * scale,
                y: imageRect.minY + (CGFloat(point.y) + 0.5) * scale)
    }

    func screenRect(_ rect: SpritePixelRect) -> CGRect {
        CGRect(x: imageRect.minX + CGFloat(rect.x) * scale,
               y: imageRect.minY + CGFloat(rect.y) * scale,
               width: CGFloat(rect.width) * scale,
               height: CGFloat(rect.height) * scale)
    }

    func pixelRect(for screenRect: CGRect) -> SpritePixelRect {
        let minX = Int(floor((screenRect.minX - imageRect.minX) / scale))
        let minY = Int(floor((screenRect.minY - imageRect.minY) / scale))
        let maxX = Int(ceil((screenRect.maxX - imageRect.minX) / scale))
        let maxY = Int(ceil((screenRect.maxY - imageRect.minY) / scale))
        let clippedX = min(max(minX, 0), imageSize.width)
        let clippedY = min(max(minY, 0), imageSize.height)
        let clippedMaxX = min(max(maxX, clippedX), imageSize.width)
        let clippedMaxY = min(max(maxY, clippedY), imageSize.height)
        return SpritePixelRect(x: clippedX, y: clippedY,
                               width: clippedMaxX - clippedX,
                               height: clippedMaxY - clippedY)
    }

    static func clampedPan(_ pan: CGSize, viewSize: CGSize, imageSize: SpritePixelSize,
                           zoom: CGFloat) -> CGSize {
        let base = SpriteCanvasTransform(viewSize: viewSize, imageSize: imageSize,
                                         zoom: zoom, pan: .zero)
        let width = base.imageRect.width
        let height = base.imageRect.height
        let maxX = max(0, (width - viewSize.width) / 2 + 32)
        let maxY = max(0, (height - viewSize.height) / 2 + 32)
        return CGSize(width: min(max(pan.width, -maxX), maxX),
                      height: min(max(pan.height, -maxY), maxY))
    }

    func focusing(_ frame: SpritePixelRect) -> SpriteCanvasTransform {
        guard frame.width > 0, frame.height > 0, imageSize.width > 0, imageSize.height > 0 else { return self }
        let desiredScale = min(max(viewSize.width - 32, 1) / CGFloat(frame.width),
                               max(viewSize.height - 32, 1) / CGFloat(frame.height))
        let newZoom = min(max(desiredScale / max(fitScale, 0.001), Self.minimumZoom), Self.maximumZoom)
        let actualScale = fitScale * newZoom
        let centered = CGSize(width: (CGFloat(imageSize.width) / 2 - CGFloat(frame.x) - CGFloat(frame.width) / 2) * actualScale,
                              height: (CGFloat(imageSize.height) / 2 - CGFloat(frame.y) - CGFloat(frame.height) / 2) * actualScale)
        return .init(viewSize: viewSize, imageSize: imageSize, zoom: newZoom,
            pan: Self.clampedPan(centered, viewSize: viewSize, imageSize: imageSize, zoom: newZoom))
    }
}

struct SpriteCanvasWorkspace: View {
    @ObservedObject var model: SpriteEditorDocument
    @Environment(\.gameEditLocale) private var locale
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var viewportSize: CGSize = .zero
    @State private var macDragActive = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { proxy in
                let transform = SpriteCanvasTransform(
                    viewSize: proxy.size,
                    imageSize: model.image?.size ?? SpritePixelSize(width: 1, height: 1),
                    zoom: zoom, pan: pan)
                ZStack {
                    Color(.sRGB, white: 0.12, opacity: 1)
                    Canvas { context, size in
                        draw(context: &context, viewSize: size, transform: transform)
                    }
                    .contentShape(Rectangle())
                    .accessibilityElement()
                    .accessibilityLabel(locale == .chinese ? "精灵画布" : "Sprite canvas")
                    .accessibilityValue(canvasAccessibilityValue)
                    .accessibilityIdentifier("game.sprite.canvas")
                    #if os(iOS)
                    SpriteCanvasGestureOverlay(
                        fingerDrawingEnabled: model.fingerDrawingEnabled,
                        onDrawBegan: { point in
                            guard let pixel = transform.pixelPoint(from: point) else { return false }
                            return model.beginStroke(at: pixel)
                        },
                        onDrawMoved: { point in
                            guard let pixel = transform.pixelPoint(from: point) else { return }
                            model.continueStroke(to: pixel)
                        },
                        onDrawEnded: { point in
                            if let pixel = transform.pixelPoint(from: point) {
                                model.continueStroke(to: pixel)
                            }
                            Task { await model.endStroke() }
                        },
                        onDrawCancelled: { model.cancelStroke() },
                        onPan: { delta in
                            pan = SpriteCanvasTransform.clampedPan(
                                CGSize(width: pan.width + delta.width, height: pan.height + delta.height),
                                viewSize: proxy.size,
                                imageSize: model.image?.size ?? SpritePixelSize(width: 1, height: 1),
                                zoom: zoom)
                        },
                        onZoom: { factor, center in
                            applyZoom(factor, anchor: center, viewSize: proxy.size)
                        })
                    .accessibilityHidden(true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(!model.isLoading && !model.isCommitting)
                    #else
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(macDrawGesture(transform))
                        .simultaneousGesture(MagnifyGesture()
                            .onEnded { value in
                                applyZoom(value.magnification,
                                          anchor: CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2),
                                          viewSize: proxy.size)
                            })
                    #endif
                    if model.isLoading {
                        ProgressView().controlSize(.large)
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .clipped()
                .onAppear { viewportSize = proxy.size }
                .onChange(of: proxy.size) { _, size in
                    viewportSize = size
                    pan = SpriteCanvasTransform.clampedPan(
                        pan, viewSize: size,
                        imageSize: model.image?.size ?? SpritePixelSize(width: 1, height: 1),
                        zoom: zoom)
                }
            }
            if let status = model.status {
                Text(status.text(locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial)
                    .accessibilityIdentifier("game.sprite.status")
            }
        }
    }

    // MARK: - Toolbar

    private var canvasAccessibilityValue: String {
        let frame = model.selectedFrame?.title(locale) ?? ""
        let mode: String
        if model.fingerDrawingEnabled {
            mode = locale == .chinese ? "手指绘制" : "Finger drawing"
        } else {
            mode = locale == .chinese ? "手指移动" : "Finger navigation"
        }
        return "\(frame) · \(mode) · \(Int(zoom * 100))%"
    }

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Picker("", selection: $model.tool) {
                    ForEach(SpriteTool.allCases, id: \.self) { item in
                        Label(item.title.text(locale), systemImage: item.symbolName)
                        .labelStyle(.iconOnly)
                        .accessibilityLabel(item.title.text(locale))
                        .tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 208, height: 44)
                .accessibilityLabel(SpriteUICopy.tools.text(locale))
                .accessibilityIdentifier("game.sprite.tool")

                Divider().frame(height: 24)

                HStack(spacing: 2) {
                    Button {
                        applyZoom(1 / 1.5, anchor: .zero, viewSize: viewportSize, useCenter: true)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("game.sprite.zoomOut")
                    Text("\(Int((zoom * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 48, minHeight: 44)
                    Button {
                        applyZoom(1.5, anchor: .zero, viewSize: viewportSize, useCenter: true)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("game.sprite.zoomIn")
                    Button {
                        zoom = 1
                        pan = .zero
                    } label: {
                        Text(SpriteUICopy.fit.text(locale))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("game.sprite.fit")
                    Button {
                        guard let image = model.image, let frame = model.selectedFrameRect else { return }
                        let focused = SpriteCanvasTransform(viewSize: viewportSize, imageSize: image.size,
                            zoom: zoom, pan: pan).focusing(frame)
                        zoom = focused.zoom
                        pan = focused.pan
                    } label: {
                        Label(locale == .chinese ? "聚焦选中帧" : "Focus selected frame", systemImage: "scope")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("game.sprite.focusFrame")
                    .disabled(model.selectedFrameRect == nil)
                }

                EditButton {
                    model.showsGrid.toggle()
                } label: {
                    Label {
                        Text(SpriteUICopy.grid.text(locale))
                    } icon: {
                        Image(systemName: model.showsGrid ? "grid" : "square")
                    }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("game.sprite.grid")
                .help(SpriteUICopy.grid.text(locale))
                .accessibilityValue(model.showsGrid ? (locale == .chinese ? "开启" : "On") : (locale == .chinese ? "关闭" : "Off"))
                .foregroundStyle(model.showsGrid ? Color.accentColor : Color.secondary)

                EditButton {
                    model.fingerDrawingEnabled.toggle()
                } label: {
                    Label {
                        Text(SpriteUICopy.fingerDrawing.text(locale))
                    } icon: {
                        Image(systemName: model.fingerDrawingEnabled ? "hand.draw.fill" : "hand.draw")
                    }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("game.sprite.fingerDrawing")
                .help(SpriteUICopy.fingerDrawingHelp.text(locale))
                .accessibilityValue(model.fingerDrawingEnabled ? (locale == .chinese ? "开启" : "On") : (locale == .chinese ? "关闭" : "Off"))
                .foregroundStyle(model.fingerDrawingEnabled ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("game.sprite.canvas.tools")
    }

    // MARK: - Drawing

    private func draw(context: inout GraphicsContext, viewSize: CGSize,
                      transform: SpriteCanvasTransform) {
        let imageRect = transform.imageRect
        guard imageRect.width > 0, imageRect.height > 0 else { return }
        drawCheckerboard(context: &context, imageRect: imageRect, viewSize: viewSize)

        if let image = model.renderedImage {
            drawImage(image, in: &context, viewSize: viewSize, transform: transform)
        }
        if let fill = model.fillPreviewImage {
            drawImage(fill, in: &context, viewSize: viewSize, transform: transform)
        }
        if model.showsGrid, let layout = model.layout {
            drawGrid(layout, in: &context, viewSize: viewSize, transform: transform)
        }
        if let selected = model.selectedFrameRectInPlayback {
            let rect = transform.screenRect(selected)
            context.stroke(Path(rect), with: .color(Color.accentColor), lineWidth: 2)
        }
        drawStrokePreview(in: &context, transform: transform)
    }

    private func drawCheckerboard(context: inout GraphicsContext, imageRect: CGRect,
                                  viewSize: CGSize) {
        let visible = imageRect.intersection(CGRect(origin: .zero, size: viewSize))
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }
        let square: CGFloat = 12
        context.fill(Path(visible), with: .color(Color(.sRGB, white: 0.42, opacity: 1)))
        var path = Path()
        let startColumn = Int(floor((visible.minX - imageRect.minX) / square))
        let endColumn = Int(ceil((visible.maxX - imageRect.minX) / square))
        let startRow = Int(floor((visible.minY - imageRect.minY) / square))
        let endRow = Int(ceil((visible.maxY - imageRect.minY) / square))
        for row in startRow..<endRow {
            for column in startColumn..<endColumn where (row + column).isMultiple(of: 2) {
                let rect = CGRect(x: imageRect.minX + CGFloat(column) * square,
                                  y: imageRect.minY + CGFloat(row) * square,
                                  width: square, height: square).intersection(visible)
                if !rect.isNull { path.addRect(rect) }
            }
        }
        context.fill(path, with: .color(Color(.sRGB, white: 0.58, opacity: 1)))
    }

    private func drawImage(_ image: CGImage, in context: inout GraphicsContext,
                           viewSize: CGSize, transform: SpriteCanvasTransform) {
        let visible = transform.imageRect.intersection(CGRect(origin: .zero, size: viewSize))
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }
        let pixels = transform.pixelRect(for: visible)
        guard pixels.width > 0, pixels.height > 0,
              let cropped = image.cropping(to: pixels.cgRect) else { return }
        let destination = transform.screenRect(pixels)
        context.draw(Image(decorative: cropped, scale: 1).interpolation(.none), in: destination)
    }

    private func drawGrid(_ layout: SpriteSheetLayout, in context: inout GraphicsContext,
                          viewSize: CGSize, transform: SpriteCanvasTransform) {
        let imageRect = transform.imageRect
        let visible = imageRect.intersection(CGRect(origin: .zero, size: viewSize))
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }
        var path = Path()
        for column in 0...layout.columns {
            let x = imageRect.minX + CGFloat(column) * CGFloat(layout.frameWidth) * transform.scale
            guard x >= visible.minX, x <= visible.maxX else { continue }
            path.move(to: CGPoint(x: x, y: visible.minY))
            path.addLine(to: CGPoint(x: x, y: visible.maxY))
        }
        for row in 0...layout.rows {
            let y = imageRect.minY + CGFloat(row) * CGFloat(layout.frameHeight) * transform.scale
            guard y >= visible.minY, y <= visible.maxY else { continue }
            path.move(to: CGPoint(x: visible.minX, y: y))
            path.addLine(to: CGPoint(x: visible.maxX, y: y))
        }
        context.stroke(path, with: .color(Color.white.opacity(0.16)), lineWidth: 1)
    }

    private func drawStrokePreview(in context: inout GraphicsContext,
                                   transform: SpriteCanvasTransform) {
        guard let stroke = model.activeStroke, stroke.tool != .fill else { return }
        var preview = context
        preview.clip(to: Path(transform.screenRect(stroke.clip)))
        let color = stroke.tool == .eraser
            ? Color.pink.opacity(0.45)
            : SpriteColorBridge.color(stroke.color)
        let lineWidth = CGFloat(stroke.clampedBrushSize) * transform.scale
        guard let first = stroke.points.first else { return }
        var path = Path()
        path.move(to: transform.screenPoint(first))
        for point in stroke.points.dropFirst() {
            path.addLine(to: transform.screenPoint(point))
        }
        preview.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .square, lineJoin: .miter))
        let start = transform.screenPoint(first)
        let half = lineWidth / 2
        preview.fill(Path(CGRect(x: start.x - half, y: start.y - half,
                                 width: lineWidth, height: lineWidth)),
                     with: .color(color))
    }

    // MARK: - Zoom / pan

    private func applyZoom(_ factor: CGFloat, anchor: CGPoint, viewSize: CGSize,
                           useCenter: Bool = false) {
        guard factor.isFinite, factor > 0 else { return }
        let imageSize = model.image?.size ?? SpritePixelSize(width: 1, height: 1)
        let actualViewSize = viewSize.width > 0 && viewSize.height > 0
            ? viewSize : CGSize(width: 1, height: 1)
        let oldTransform = SpriteCanvasTransform(viewSize: actualViewSize, imageSize: imageSize,
                                                 zoom: zoom, pan: pan)
        let imagePoint = useCenter
            ? CGPoint(x: CGFloat(imageSize.width) / 2, y: CGFloat(imageSize.height) / 2)
            : oldTransform.imagePoint(from: anchor)
        let newZoom = min(max(zoom * factor, SpriteCanvasTransform.minimumZoom),
                          SpriteCanvasTransform.maximumZoom)
        let newScale = max(0.001, oldTransform.fitScale * newZoom)
        let centeredOrigin = CGPoint(
            x: (actualViewSize.width - CGFloat(imageSize.width) * newScale) / 2,
            y: (actualViewSize.height - CGFloat(imageSize.height) * newScale) / 2)
        let anchorPoint = useCenter
            ? CGPoint(x: actualViewSize.width / 2, y: actualViewSize.height / 2)
            : anchor
        let desiredOrigin = CGPoint(x: anchorPoint.x - imagePoint.x * newScale,
                                    y: anchorPoint.y - imagePoint.y * newScale)
        zoom = newZoom
        pan = SpriteCanvasTransform.clampedPan(
            CGSize(width: desiredOrigin.x - centeredOrigin.x,
                   height: desiredOrigin.y - centeredOrigin.y),
            viewSize: actualViewSize, imageSize: imageSize, zoom: newZoom)
    }

    #if os(macOS)
    private func macDrawGesture(_ transform: SpriteCanvasTransform) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let pixel = transform.pixelPoint(from: value.location)
                if !macDragActive {
                    guard let pixel, model.beginStroke(at: pixel) else { return }
                    macDragActive = true
                } else if let pixel {
                    model.continueStroke(to: pixel)
                }
            }
            .onEnded { value in
                guard macDragActive else { return }
                macDragActive = false
                if let pixel = transform.pixelPoint(from: value.location) {
                    model.continueStroke(to: pixel)
                }
                Task { await model.endStroke() }
            }
    }
    #endif
}

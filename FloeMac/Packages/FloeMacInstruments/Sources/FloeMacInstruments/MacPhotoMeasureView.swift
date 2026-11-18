// SPDX-License-Identifier: MPL-2.0
//
// Mac toolbox — photo measurement view.
//
// The canvas shows the actual decoded image with measurement annotations in
// image-pixel coordinates. The sidebar holds calibration and results; no
// control floats over the image.

import AppKit
import SwiftUI
import FloeToolboxUtilities
import UniformTypeIdentifiers

public struct MacPhotoMeasureView: View {
    @Environment(\.locale) private var locale
    @State private var model: MacPhotoMeasureModel
    @State private var activeHandle: UUID?
    @State private var lastDragLocation: CGPoint?
    @State private var didDrag = false

    public init(activity: MacInstrumentActivityCoordinator? = nil) {
        _model = State(initialValue: MacPhotoMeasureModel(activity: activity))
    }

    public init(model: MacPhotoMeasureModel) { _model = State(initialValue: model) }

    public var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
            let wide = geometry.size.width >= 820
            VStack(spacing: 0) {
                topBar
                Divider()
                if wide {
                    HStack(alignment: .top, spacing: 0) {
                        canvas
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        ScrollView {
                            sidePanel
                                .padding(18)
                        }
                        .frame(width: 340)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            canvas.frame(height: max(380, geometry.size.height * 0.55))
                            sidePanel
                        }
                        .padding(16)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(macToolboxText("图片测量", "Photo measure", locale))
        .alert(macToolboxText("导出", "Export", locale),
               isPresented: Binding(get: { model.lastExportError != nil },
                                    set: { if !$0 { model.clearExportError() } })) {
            Button(macToolboxText("好", "OK", locale), role: .cancel) { model.clearExportError() }
        } message: {
            Text(model.lastExportError?.text(locale) ?? "")
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Label(statusText, systemImage: statusSymbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("mac.toolbox.photo.status")
            Spacer(minLength: 8)
            Button(action: chooseImage) {
                Label(macToolboxText("选择图片", "Choose image", locale), systemImage: "photo.on.rectangle.angled")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("mac.toolbox.photo.pick")
            Button { model.resetZoom() } label: {
                Label(macToolboxText("适合窗口", "Fit", locale), systemImage: "arrow.up.left.and.arrow.down.right")
                    .labelStyle(.iconOnly)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(model.transform == nil)
            .help(macToolboxText("适合窗口", "Fit to window", locale))
            .accessibilityLabel(macToolboxText("适合窗口", "Fit to window", locale))
            Button(action: exportImage) {
                Label(macToolboxText("导出标注 PNG", "Export annotated PNG", locale), systemImage: "square.and.arrow.up")
                    .frame(minHeight: 44)
            }
            .disabled(!model.canExport)
            .accessibilityIdentifier("mac.toolbox.photo.export")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var statusText: String {
        switch model.phase {
        case .empty: macToolboxText("尚未选择图片", "No image selected", locale)
        case .importing: macToolboxText("正在载入图片…", "Importing image…", locale)
        case .failed: macToolboxText("图片载入失败", "Image failed to load", locale)
        case .ready:
            if !model.isCalibrated {
                macToolboxText("参照校准：已放置 \(model.referencePointCount)/2 个点",
                               "Calibrate: \(model.referencePointCount)/2 reference points placed", locale)
            } else {
                macToolboxText("\(model.readout.pointCount) 个测量点", "\(model.readout.pointCount) measurement points", locale)
            }
        }
    }

    private var statusSymbol: String {
        switch model.phase {
        case .empty: "photo"
        case .importing: "arrow.down.circle"
        case .failed: "exclamationmark.triangle"
        case .ready: model.isCalibrated ? "ruler" : "dot.scope"
        }
    }

    private var canvas: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                if let image = model.image, let transform = model.transform {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: model.imagePixels.x * transform.scale,
                               height: model.imagePixels.y * transform.scale)
                        .offset(x: transform.offset.x, y: transform.offset.y)
                    MacPhotoAnnotationOverlay(
                        primitives: model.screenPrimitives,
                        map: { point in
                            let view = transform.viewPoint(fromImage: point)
                            return CGPoint(x: view.x, y: view.y)
                        },
                        lineWidth: 2,
                        fontSize: 13)
                    .allowsHitTesting(false)
                } else {
                    placeholder
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture(size: proxy.size))
            .onAppear { model.setViewSize(proxy.size) }
            .onChange(of: proxy.size) { _, value in model.setViewSize(value) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mac.toolbox.photo.canvas")
        }
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.badge.plus").font(.system(size: 42)).foregroundStyle(.secondary)
            Text(macToolboxText("图片比例测量", "Photo measure", locale)).font(.title2.weight(.semibold))
            Text(macToolboxText("选择一张图片，用两个已知长度的参照点确定比例，然后测量长度、面积或角度。",
                               "Choose an image, set the scale from two reference points of a known length, then measure length, area or angle.", locale))
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(action: chooseImage) {
                Label(macToolboxText("选择图片", "Choose image", locale), systemImage: "photo.on.rectangle.angled")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            if let hint = model.hint {
                Text(hint.text(locale)).font(.callout).foregroundStyle(.orange)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if activeHandle == nil, lastDragLocation == nil {
                    activeHandle = model.handleHitTest(value.startLocation)
                    lastDragLocation = value.startLocation
                }
                if let activeHandle {
                    model.moveHandle(id: activeHandle, to: value.location)
                    didDrag = true
                } else if let previous = lastDragLocation {
                    let delta = CGSize(width: value.location.x - previous.x,
                                       height: value.location.y - previous.y)
                    if abs(delta.width) + abs(delta.height) > 0.5 {
                        model.pan(delta: delta)
                        didDrag = true
                    }
                    lastDragLocation = value.location
                }
            }
            .onEnded { value in
                if activeHandle == nil, !didDrag {
                    model.tap(at: value.location)
                }
                activeHandle = nil
                lastDragLocation = nil
                didDrag = false
            }
    }

    private func magnifyGesture(size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let anchor = CGPoint(x: value.startAnchor.x * size.width,
                                     y: value.startAnchor.y * size.height)
                model.zoom(factor: Double(value.magnification), anchor: anchor)
            }
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let hint = model.hint {
                Label(hint.text(locale), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.wasDownsampled {
                Text(macToolboxText("图片已缩小到 2000 万像素以内；测量仍按载入后的像素坐标计算。",
                                    "The image was downsampled to under 20 million pixels; measurements use the loaded pixel coordinates.", locale))
                    .font(.caption).foregroundStyle(.secondary)
            }

            calibrationCard
            measurementCard
            pointsCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(macToolboxText("尺度标定", "Scale", locale), systemImage: "ruler").font(.headline)
            if model.image == nil {
                Text(macToolboxText("先选择一张图片。", "Choose an image first.", locale))
                    .font(.callout).foregroundStyle(.secondary)
            } else if !model.isCalibrated {
                Text(macToolboxText("在图片上点两个参照点，输入它们之间的真实长度，然后应用。",
                                   "Place two reference points on the image, enter their real length, then apply.", locale))
                    .font(.callout).foregroundStyle(.secondary)
                Text(macToolboxText("已放置 \(model.referencePointCount)/2 个参照点", "\(model.referencePointCount)/2 reference points placed", locale))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                HStack {
                    TextField(macToolboxText("参考长度", "Reference length", locale), text: $model.referenceValueText)
                        .font(.body.monospaced())
                        .accessibilityIdentifier("mac.toolbox.photo.referenceLength")
                    Text(model.unit.symbol).foregroundStyle(.secondary)
                }
                Button {
                    model.applyCalibration()
                } label: {
                    Label(macToolboxText("应用尺度", "Apply scale", locale), systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canApplyCalibration)
                .accessibilityIdentifier("mac.toolbox.photo.applyScale")
                Button(macToolboxText("清除参照点", "Clear reference points", locale)) {
                    model.recalibrate()
                }
                .font(.callout)
                .disabled(model.allPoints.isEmpty)
            } else if let calibration = model.store.calibration {
                LabeledContent(macToolboxText("每像素", "Per pixel", locale)) {
                    Text(String(format: "%.5f mm", locale: Locale(identifier: "en_US_POSIX"),
                                calibration.metersPerPixel * 1000))
                        .monospacedDigit()
                }
                .font(.callout)
                Text(macToolboxText("参照长度 \(Self.formatMillimetres(calibration.lengthMeters)) 毫米",
                                    "Reference length \(Self.formatMillimetres(calibration.lengthMeters)) mm", locale))
                    .font(.caption).foregroundStyle(.secondary)
                Button(macToolboxText("重新标定", "Recalibrate", locale)) {
                    model.recalibrate()
                }
                .font(.callout)
                .accessibilityIdentifier("mac.toolbox.photo.recalibrate")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("mac.toolbox.photo.calibration")
    }

    private var measurementCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(macToolboxText("测量", "Measurement", locale), systemImage: "ruler.fill").font(.headline)
            Picker(macToolboxText("方式", "Mode", locale), selection: $model.mode) {
                Text(macToolboxText("长度", "Length", locale)).tag(PhotoMeasureMode.length)
                Text(macToolboxText("面积", "Area", locale)).tag(PhotoMeasureMode.area)
                Text(macToolboxText("角度", "Angle", locale)).tag(PhotoMeasureMode.angle)
            }
            .pickerStyle(.segmented)
            .disabled(!model.isCalibrated)
            .accessibilityIdentifier("mac.toolbox.photo.mode")

            Picker(macToolboxText("单位", "Unit", locale), selection: $model.unit) {
                ForEach(PhotoUnit.allCases, id: \.self) { unit in
                    Text(unitTitle(unit)).tag(unit)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("mac.toolbox.photo.unit")

            if !model.isCalibrated {
                Text(macToolboxText("应用尺度后可选择测量方式。", "Apply a scale to choose a measurement mode.", locale))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                readoutRows
            }

            HStack {
                Button { model.undo() } label: {
                    Label(macToolboxText("撤销", "Undo", locale), systemImage: "arrow.uturn.backward")
                        .frame(minHeight: 44)
                }
                .disabled(model.allPoints.isEmpty)
                .accessibilityIdentifier("mac.toolbox.photo.undo")
                Button { model.clearMeasurements() } label: {
                    Label(macToolboxText("清除测量点", "Clear points", locale), systemImage: "trash")
                        .frame(minHeight: 44)
                }
                .disabled(model.readout.pointCount == 0)
                .accessibilityIdentifier("mac.toolbox.photo.clear")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("mac.toolbox.photo.measurement")
    }

    @ViewBuilder private var readoutRows: some View {
        switch model.mode {
        case .length:
            LabeledContent(macToolboxText("总长度", "Total length", locale)) {
                Text(model.readout.total > 0 ? model.unit.format(model.readout.total) : "—")
                    .font(.body.monospacedDigit().weight(.medium))
            }
            .font(.callout)
            .accessibilityIdentifier("mac.toolbox.photo.readout.length")
            ForEach(Array(model.readout.segmentLengths.enumerated()), id: \.offset) { index, meters in
                LabeledContent("\(macToolboxText("线段", "Segment", locale)) \(index + 1)") {
                    Text(model.unit.format(meters)).font(.caption.monospacedDigit())
                }
                .font(.caption)
            }
        case .area:
            LabeledContent(macToolboxText("面积", "Area", locale)) {
                Text(model.readout.area.map { model.unit.areaFormat($0) } ?? "—")
                    .font(.body.monospacedDigit().weight(.medium))
            }
            .font(.callout)
            .accessibilityIdentifier("mac.toolbox.photo.readout.area")
            Text(macToolboxText("至少放置 3 个测量点形成闭合多边形。",
                               "Place at least 3 measurement points to form a closed polygon.", locale))
                .font(.caption).foregroundStyle(.secondary)
        case .angle:
            if model.readout.angles.isEmpty {
                Label(macToolboxText("每 3 个点测量一个角度。", "Each 3 points measure one angle.", locale),
                      systemImage: "angle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.readout.angles.enumerated()), id: \.offset) { index, degrees in
                    LabeledContent("\(macToolboxText("角度", "Angle", locale)) \(index + 1)") {
                        Text(String(format: "%.1f°", locale: Locale(identifier: "en_US_POSIX"), degrees))
                            .font(.body.monospacedDigit().weight(.medium))
                    }
                    .font(.callout)
                }
                .accessibilityIdentifier("mac.toolbox.photo.readout.angle")
            }
        }
    }

    private var pointsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(macToolboxText("测量点", "Points", locale), systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            Text(macToolboxText("单击图片添加点；拖动已放置的点可调整。拖动空白区域可平移，双指捏合可缩放。",
                               "Click the image to add a point; drag a placed point to adjust it. Drag empty space to pan, pinch to zoom.", locale))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(macToolboxText("\(model.readout.pointCount) 个测量点 · \(model.referencePointCount) 个参照点",
                               "\(model.readout.pointCount) measurement points · \(model.referencePointCount) reference points", locale))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityIdentifier("mac.toolbox.photo.pointCount")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private static func formatMillimetres(_ meters: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), meters * 1000)
    }

    private func unitTitle(_ unit: PhotoUnit) -> String {
        switch unit {
        case .millimeter: macToolboxText("毫米", "Millimeters", locale)
        case .centimeter: macToolboxText("厘米", "Centimeters", locale)
        case .meter: macToolboxText("米", "Meters", locale)
        case .inch: macToolboxText("英寸", "Inches", locale)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .gif, .bmp, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importImage(from: url)
    }

    private func exportImage() {
        guard model.canExport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "floe-photo-measure.png"
        panel.canCreateDirectories = true
        panel.message = macToolboxText("请选择新文件名，不会覆盖已有文件。目前仅支持与系统临时目录位于同一磁盘且支持克隆的存储位置。", "Choose a new filename; existing files cannot be replaced. The destination must be on the same clone-capable volume as the system temporary directory.", locale)
        panel.prompt = macToolboxText("导出新文件", "Export New File", locale)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportAnnotatedPNG(to: url)
    }
}

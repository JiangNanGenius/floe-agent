import SwiftUI
import FloeToolboxUtilities

/// Calibrated measurement on a still image: the user picks an image through
/// the host, defines a scale from two reference points with a known real
/// length, then measures segment lengths, planar polygon area and angles.
/// All values derive from image pixel coordinates, so zooming and panning
/// never change a measurement.
public struct ToolboxPhotoMeasureView: View {
    @StateObject private var model: PhotoMeasureModel
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var dragHandleID: UUID?
    @State private var isPanning = false
    @State private var lastPanTranslation: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1

    public init(importImage: @escaping @MainActor () async throws -> Data?,
                exportImage: @escaping @MainActor (Data) -> Void) {
        _model = StateObject(wrappedValue: PhotoMeasureModel(importImage: importImage,
                                                              exportImage: exportImage))
    }

    private func t(_ zh: String, _ en: String) -> String { workbenchText(zh, en, locale) }

    /// Grouped panel fill that stays native on both UIKit and AppKit.
    private var cardBackground: Color {
        #if canImport(UIKit)
        Color(.secondarySystemBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    public var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 720 && !typeSize.isAccessibilitySize
            Group {
                if wide {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) { topBar; canvasArea; modeBar }
                        Divider()
                        ScrollView { sidePanel.padding(20) }.frame(width: 320)
                    }
                } else {
                    VStack(spacing: 0) {
                        topBar
                        canvasArea
                        Divider()
                        ScrollView { compactPanel.padding(.horizontal, 16).padding(.vertical, 12) }
                        modeBar
                    }
                }
            }
        }
        .background(.background)
        .navigationTitle(t("图片比例测量", "Photo Measure"))
        .onDisappear { model.cancelImport() }
    }

    // MARK: - Chrome

    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                statusLabel.font(.subheadline)
                Spacer(minLength: 8)
                Button { Task { await model.importFromHost() } } label: {
                    Image(systemName: "photo.on.rectangle.angled").frame(width: 44, height: 44)
                }
                .accessibilityLabel(t("选择图片", "Choose image"))
                .accessibilityIdentifier("toolbox.photo.pick")
                Button { model.resetZoom() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
                }
                .disabled(model.transform == nil)
                .accessibilityLabel(t("重置缩放", "Reset zoom"))
            }
            VStack(alignment: .leading, spacing: 4) {
                statusLabel.font(.subheadline)
                HStack(spacing: 12) {
                    Button { Task { await model.importFromHost() } } label: {
                        Label(t("选择图片", "Choose image"), systemImage: "photo.on.rectangle.angled")
                            .frame(minHeight: 44)
                    }
                    Spacer(minLength: 4)
                    Button { model.resetZoom() } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
                    }
                    .disabled(model.transform == nil)
                    .accessibilityLabel(t("重置缩放", "Reset zoom"))
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .background(.bar)
    }

    private var statusLabel: some View {
        Label {
            Text(statusText)
        } icon: {
            Image(systemName: statusSymbol)
        }
        .foregroundStyle(.secondary)
    }

    private var statusText: String {
        switch model.phase {
        case .empty: return t("尚未选择图片", "No image selected")
        case .importing: return t("正在载入图片…", "Importing image…")
        case .failed: return t("图片载入失败", "Image failed to load")
        case .ready:
            if !model.isCalibrated {
                return t("参照校准：已放置 \(model.referencePointCount)/2 点", "Calibrate: \(model.referencePointCount)/2 reference points placed")
            }
            return t("\(model.readout.pointCount) 个测量点", "\(model.readout.pointCount) measurement points")
        }
    }

    private var statusSymbol: String {
        switch model.phase {
        case .empty: return "photo"
        case .importing: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle"
        case .ready: return model.isCalibrated ? "ruler" : "dot.scope"
        }
    }

    private var modeBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                modePicker.frame(width: 220)
                unitMenu
                Spacer(minLength: 8)
                editControls
                exportButton
            }
            VStack(spacing: 8) {
                HStack(spacing: 12) { modePicker; unitMenu; Spacer(minLength: 4) }
                HStack(spacing: 12) { editControls; Spacer(minLength: 4); exportButton }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var modePicker: some View {
        Picker(t("测量方式", "Mode"), selection: $model.mode) {
            Text(t("长度", "Length")).tag(PhotoMeasureMode.length)
            Text(t("面积", "Area")).tag(PhotoMeasureMode.area)
            Text(t("角度", "Angle")).tag(PhotoMeasureMode.angle)
        }
        .pickerStyle(.segmented)
        .disabled(!model.isCalibrated)
        .accessibilityIdentifier("toolbox.photo.mode")
    }

    private var unitMenu: some View {
        Menu {
            Picker(t("显示单位", "Display unit"), selection: $model.unit) {
                ForEach(PhotoUnit.allCases, id: \.self) { option in
                    Text(unitTitle(option)).tag(option)
                }
            }
        } label: {
            Text(model.unit.symbol).frame(minHeight: 44).frame(minWidth: 44)
        }
        .accessibilityIdentifier("toolbox.photo.unit")
    }

    private func unitTitle(_ unit: PhotoUnit) -> String {
        switch unit {
        case .millimeter: return t("毫米", "Millimeters")
        case .centimeter: return t("厘米", "Centimeters")
        case .meter: return t("米", "Meters")
        case .inch: return t("英寸", "Inches")
        }
    }

    @ViewBuilder private var editControls: some View {
        Button { model.undo() } label: {
            Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44)
        }
        .disabled(model.allPoints.isEmpty)
        .accessibilityLabel(t("撤销上一点", "Undo last point"))
        .accessibilityIdentifier("toolbox.photo.undo")
        Button { model.clearMeasurements() } label: {
            Image(systemName: "trash").frame(width: 44, height: 44)
        }
        .disabled(model.readout.pointCount == 0)
        .accessibilityLabel(t("清除测量点", "Clear measurement points"))
        .accessibilityIdentifier("toolbox.photo.clear")
    }

    private var exportButton: some View {
        Button { model.exportAnnotatedPNG() } label: {
            Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
        }
        .disabled(!model.canExport)
        .accessibilityLabel(t("导出标注图片", "Export annotated image"))
        .accessibilityIdentifier("toolbox.photo.export")
    }

    // MARK: - Canvas

    @ViewBuilder private var canvasArea: some View {
        switch model.phase {
        case .empty:
            placeholder(symbol: "photo",
                        title: t("图片比例测量", "Photo Measure"),
                        description: t("选择一张图片，用两个已知长度的参照点确定比例，然后测量长度、面积或角度。",
                                       "Choose an image, set the scale from two reference points of a known length, then measure length, area or angle.")) {
                Button { Task { await model.importFromHost() } } label: {
                    Label(t("选择图片", "Choose image"), systemImage: "photo.on.rectangle.angled")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("toolbox.photo.choose")
            }
        case .importing:
            VStack(spacing: 12) {
                ProgressView()
                Text(t("正在载入图片…", "Importing image…")).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            placeholder(symbol: "exclamationmark.triangle",
                        title: t("无法载入图片", "Unable to load image"),
                        description: message) {
                Button { Task { await model.importFromHost() } } label: {
                    Label(t("重试", "Try again"), systemImage: "arrow.clockwise").frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
        case .ready:
            readyCanvas
        }
    }

    private var readyCanvas: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { model.setViewSize(proxy.size) }
                .onChange(of: proxy.size) { _, size in model.setViewSize(size) }
            if let image = model.image, let transform = model.transform {
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: model.imagePixels.x * transform.scale,
                               height: model.imagePixels.y * transform.scale)
                        .offset(x: transform.offset.x, y: transform.offset.y)
                    PhotoMeasureAnnotationOverlay(
                        primitives: model.screenPrimitives,
                        map: { point in
                            let mapped = transform.viewPoint(fromImage: point)
                            return CGPoint(x: mapped.x, y: mapped.y)
                        },
                        lineWidth: 2, fontSize: 13)
                    .allowsHitTesting(false)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .simultaneousGesture(magnifyGesture)
                .onTapGesture { location in model.tap(at: location) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(canvasSummary)
                .accessibilityIdentifier("toolbox.photo.canvas")
                .overlay(alignment: .bottom) {
                    if model.wasDownsampled {
                        Text(t("图片已按上限缩小显示，测量基于缩小后的像素。",
                               "The image was downsampled to the display limit; measurements use the downsampled pixels."))
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.bar, in: .capsule)
                            .padding(.bottom, 10)
                            .accessibilityIdentifier("toolbox.photo.downsampled")
                    }
                }
                .overlay(alignment: .top) {
                    if !model.isCalibrated, model.referencePointCount > 0 {
                        Text(model.referencePointCount == 1
                             ? t("已放置参照起点，再点击参照终点。", "Reference start placed. Tap the reference end point.")
                             : t("两点已就位，请在下方输入真实长度。", "Both points placed. Enter the real length below."))
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.bar, in: .capsule)
                            .padding(.top, 10)
                    }
                }
            }
        }
        .background(.background)
        .clipped()
    }

    private var canvasSummary: String {
        guard let calibration = model.store.calibration else {
            return t("图片已载入，尚未完成参照校准。", "Image loaded. Calibration is not complete yet.")
        }
        let scaleText = String(format: "%.2f", calibration.metersPerPixel)
        return t("已校准：每像素 \(scaleText) 米，共 \(model.readout.pointCount) 个测量点。",
                 "Calibrated at \(scaleText) meters per pixel with \(model.readout.pointCount) measurement points.")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if !isPanning && dragHandleID == nil {
                    if let hit = model.handleHitTest(value.startLocation) {
                        dragHandleID = hit
                    } else {
                        isPanning = true
                        lastPanTranslation = .zero
                    }
                }
                if let dragHandleID {
                    model.moveHandle(id: dragHandleID, to: value.location)
                } else if isPanning {
                    let delta = CGSize(width: value.translation.width - lastPanTranslation.width,
                                       height: value.translation.height - lastPanTranslation.height)
                    model.pan(by: delta)
                    lastPanTranslation = value.translation
                }
            }
            .onEnded { _ in
                dragHandleID = nil
                isPanning = false
                lastPanTranslation = .zero
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let factor = Double(value.magnification / lastMagnification)
                guard factor.isFinite, factor > 0 else { return }
                // startLocation is stable for the whole gesture, so the zoom
                // anchor never drifts while the user pinches.
                model.zoom(by: factor, anchor: value.startLocation)
                lastMagnification = value.magnification
            }
            .onEnded { _ in lastMagnification = 1 }
    }

    // MARK: - Panels

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            calibrationCard
            if model.isCalibrated { readoutCard }
            scopeNote
            if let hint = model.hint {
                Text(hint).font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.lastExportError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            calibrationCard
            if model.isCalibrated { readoutCard }
            scopeNote
            if let hint = model.hint {
                Text(hint).font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.lastExportError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var scopeNote: some View {
        Label(t("近似均匀比例：适用于正对同一平面的图片，不声明透视或三维精度。",
                "Approximate uniform scale for front-facing, same-plane images. No perspective or 3D accuracy is claimed."),
              systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Calibration

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(t("参照校准", "Reference calibration"), systemImage: "dot.scope")
                .font(.headline)
            if let calibration = model.store.calibration {
                LabeledContent(t("比例", "Scale")) {
                    Text("\(model.unit.format(calibration.lengthMeters)) = \(pixelText(calibration.pixelDistance))")
                        .monospacedDigit()
                }
                .font(.callout)
                Button { model.recalibrate() } label: {
                    Label(t("重新校准", "Recalibrate"), systemImage: "arrow.triangle.2.circlepath")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("toolbox.photo.recalibrate")
            } else {
                Text(t("在图片上点击两个点，输入它们之间的真实长度。",
                       "Tap two points on the image and enter the real distance between them."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.store.hasReferencePair {
                    HStack(spacing: 12) {
                        TextField(t("真实长度", "Real length"), text: $model.referenceValueText)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .frame(maxWidth: 160)
                            .accessibilityIdentifier("toolbox.photo.referenceValue")
                        Text(model.unit.symbol).font(.body).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button { model.applyCalibration() } label: {
                            Label(t("设定比例", "Set scale"), systemImage: "checkmark.circle")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canApplyCalibration)
                        .accessibilityIdentifier("toolbox.photo.apply")
                    }
                }
            }
        }
        .padding(16)
        .background(cardBackground, in: .rect(cornerRadius: 14))
    }

    // MARK: Readouts

    private var readoutCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(t("测量结果", "Measurements"), systemImage: "ruler")
                .font(.headline)
            summaryRows
            switch model.mode {
            case .length:
                if !model.readout.segmentLengths.isEmpty {
                    segmentList
                }
            case .area:
                EmptyView()
            case .angle:
                if !model.readout.angles.isEmpty {
                    angleList
                }
            }
        }
        .padding(16)
        .background(cardBackground, in: .rect(cornerRadius: 14))
        .accessibilityIdentifier("toolbox.photo.readout")
    }

    /// Short numeric readings pair into two columns when width and text size
    /// allow; long content and accessibility sizes reflow into one column.
    private var summaryRows: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { totalRow; secondaryRow }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 28) { totalRow; secondaryRow }
                    VStack(alignment: .leading, spacing: 8) { totalRow; secondaryRow }
                }
            }
        }
        .font(.callout)
    }

    private var totalRow: some View {
        LabeledContent(t("总长", "Total length")) {
            Text(model.unit.format(model.readout.total))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var secondaryRow: some View {
        switch model.mode {
        case .length:
            LabeledContent(t("段数", "Segments")) {
                Text("\(model.readout.segmentLengths.count)").monospacedDigit()
            }
        case .area:
            if let area = model.readout.area {
                LabeledContent(t("面积", "Area")) {
                    Text(model.unit.areaFormat(area)).monospacedDigit()
                }
            } else {
                LabeledContent(t("面积", "Area")) { Text("—") }
            }
        case .angle:
            LabeledContent(t("角度数", "Angles")) {
                Text("\(model.readout.angles.count)").monospacedDigit()
            }
        }
    }

    private var segmentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.readout.segmentLengths.enumerated()), id: \.offset) { index, physical in
                HStack {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                    Text(model.unit.format(physical))
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    Text(pixelText(model.readout.segmentLengthsPixels[index]))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityLabel(t("分段长度", "Segment lengths"))
    }

    private var angleList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.readout.angles.enumerated()), id: \.offset) { index, angle in
                HStack {
                    Text("∠\(index + 1).")
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f°", angle))
                        .monospacedDigit()
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityLabel(t("角度", "Angles"))
    }

    private func pixelText(_ pixels: Double) -> String {
        pixels.formatted(.number.precision(.fractionLength(0...1))) + " px"
    }

    // MARK: - Placeholder

    private func placeholder<Actions: View>(symbol: String, title: String, description: String,
                                            @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

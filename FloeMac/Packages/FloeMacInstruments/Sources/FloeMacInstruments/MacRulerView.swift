// SPDX-License-Identifier: MPL-2.0
//
// Mac toolbox — ruler view.
//
// Desktop layout: a thin control bar, the measured canvas, and grouped readout
// and calibration cards outside the canvas. No control floats over the ruler.

import AppKit
import SwiftUI

public struct MacRulerInstrumentView: View {
    @Environment(\.locale) private var locale
    @State private var model: MacRulerModel
    @State private var mode: Mode = .distance
    @State private var unit: ReadoutUnit = .millimeters
    @State private var loadedDisplay: MacDisplayIdentity?
    @State private var displayToken = UUID()
    @State private var copied = false
    @State private var cleanupConfirmation = false
    @State private var reviewedObsoleteIDs: Set<String> = []
    @Namespace private var canvasSpace

    public init(activity: MacInstrumentActivityCoordinator? = nil,
                store: MacRulerCalibrationStore = MacRulerModel.defaultStore) {
        _model = State(initialValue: MacRulerModel(store: store, activity: activity))
    }

    public init(model: MacRulerModel) { _model = State(initialValue: model) }

    private enum Mode: String, CaseIterable, Identifiable {
        case distance, angle
        var id: String { rawValue }
    }

    private enum ReadoutUnit: String, CaseIterable, Identifiable {
        case millimeters, inches
        var id: String { rawValue }
    }

    public var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760
            VStack(spacing: 0) {
                controlBar
                Divider()
                if wide {
                    HStack(alignment: .top, spacing: 16) {
                        canvas(geometry.size)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        ScrollView {
                            VStack(spacing: 14) {
                                readoutCard
                                calibrationCard
                                displayCard
                            }
                            .padding(.trailing, 16)
                            .padding(.bottom, 16)
                        }
                        .frame(width: 320)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            canvas(geometry.size)
                                .frame(height: max(320, geometry.size.height * 0.5))
                            readoutCard
                            calibrationCard
                            displayCard
                        }
                        .padding(16)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(macToolboxText("标尺", "Ruler", locale))
        .overlay(alignment: .topLeading) {
            MacScreenReader { screen in
                let identity = screen.flatMap(MacDisplayIdentity.init(screen:))
                guard identity != loadedDisplay else { return }
                loadedDisplay = identity
                model.invalidateDisplay()
                let token = UUID()
                displayToken = token
                Task {
                    guard displayToken == token else { return }
                    await model.load(display: identity)
                }
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onChange(of: mode) { _, _ in copied = false }
        .confirmationDialog(macToolboxText("清理旧临时校准？", "Remove old temporary calibrations?", locale),
                            isPresented: $cleanupConfirmation, titleVisibility: .visible) {
            Button(macToolboxText("清理已选择的旧校准", "Remove reviewed calibrations", locale), role: .destructive) {
                model.requestRemoveObsoleteUnverified(expected: reviewedObsoleteIDs)
            }
            Button(macToolboxText("取消", "Cancel", locale), role: .cancel) { }
        } message: {
            Text(macToolboxText("将清理 \(reviewedObsoleteIDs.count) 条旧拓扑的临时校准。可靠身份、当前显示器及无法确认的记录会保留。",
                                "Remove \(reviewedObsoleteIDs.count) temporary calibrations from older display sessions. Verified, current and uncertain records are kept.", locale))
        }
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Picker(macToolboxText("模式", "Mode", locale), selection: $mode) {
                Text(macToolboxText("直尺", "Ruler", locale)).tag(Mode.distance)
                Text(macToolboxText("角度", "Angle", locale)).tag(Mode.angle)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .accessibilityIdentifier("mac.toolbox.ruler.mode")

            if mode == .distance {
                Picker(macToolboxText("单位", "Units", locale), selection: $unit) {
                    Text("mm").tag(ReadoutUnit.millimeters)
                    Text("in").tag(ReadoutUnit.inches)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .accessibilityIdentifier("mac.toolbox.ruler.unit")
            }

            Spacer(minLength: 8)

            Button {
                model.resetMarks()
            } label: {
                Label(macToolboxText("重置", "Reset", locale), systemImage: "arrow.counterclockwise")
                    .labelStyle(.iconOnly)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .help(macToolboxText("重置标记位置", "Reset mark positions", locale))
            .accessibilityLabel(macToolboxText("重置标记位置", "Reset mark positions", locale))
            .accessibilityIdentifier("mac.toolbox.ruler.reset")

            Button {
                if let text = copyText() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
            } label: {
                Label(copied ? macToolboxText("已复制", "Copied", locale) : macToolboxText("复制", "Copy", locale),
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(copyText() == nil)
            .help(macToolboxText("复制读数", "Copy reading", locale))
            .accessibilityLabel(macToolboxText("复制读数", "Copy reading", locale))
            .accessibilityIdentifier("mac.toolbox.ruler.copy")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func canvas(_ size: CGSize) -> some View {
        GeometryReader { proxy in
            let bounds = proxy.size
            ZStack {
                Color.clear.contentShape(Rectangle())
                if mode == .distance {
                    distanceCanvas(bounds)
                } else {
                    angleCanvas(bounds)
                }
            }
            .coordinateSpace(name: canvasSpace)
            .onAppear { model.placeMarks(in: bounds) }
            .onChange(of: bounds) { _, value in model.clampMarks(in: value) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mac.toolbox.ruler.canvas")
        }
    }

    private func distanceCanvas(_ bounds: CGSize) -> some View {
        let stripHeight: CGFloat = min(110, max(84, bounds.height * 0.3))
        let trackY = MacRulerModel.distanceTrackY(in: bounds)
        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                drawRulerStrip(context: context, size: size, stripHeight: stripHeight)
            }
            .frame(height: stripHeight)
            Canvas { context, _ in
                drawMeasurementLine(context: context, midY: trackY)
            }
            handle(at: $model.markA, y: trackY, in: bounds,
                   name: macToolboxText("标记 A", "Mark A", locale), identifier: "a")
            handle(at: $model.markB, y: trackY, in: bounds,
                   name: macToolboxText("标记 B", "Mark B", locale), identifier: "b")
        }
    }

    private func angleCanvas(_ bounds: CGSize) -> some View {
        ZStack {
            Canvas { context, _ in drawAngleScene(context: context, bounds: bounds) }
            pointHandle($model.vertex, in: bounds, name: macToolboxText("顶点", "Vertex", locale),
                        identifier: "vertex", color: .indigo)
            pointHandle($model.armEnd1, in: bounds, name: macToolboxText("射线端点 1", "Ray endpoint 1", locale),
                        identifier: "arm1", color: .blue)
            pointHandle($model.armEnd2, in: bounds, name: macToolboxText("射线端点 2", "Ray endpoint 2", locale),
                        identifier: "arm2", color: .blue)
        }
    }

    private func handle(at position: Binding<CGPoint>, y: CGFloat, in bounds: CGSize,
                        name: String, identifier: String) -> some View {
        Circle()
            .fill(.blue)
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 1, y: 1)
            .frame(width: MacRulerModel.handleHitSize, height: MacRulerModel.handleHitSize)
            .contentShape(Rectangle())
            .position(CGPoint(x: position.wrappedValue.x, y: y))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(canvasSpace))
                    .onChanged { value in
                        guard MacRulerModel.isUsableBounds(bounds) else { return }
                        let inset = MacRulerModel.handleHitSize / 2
                        position.wrappedValue = CGPoint(
                            x: min(max(value.location.x, inset), bounds.width - inset), y: y)
                    }
            )
            .accessibilityLabel(name)
            .accessibilityIdentifier("mac.toolbox.ruler.handle.\(identifier)")
    }

    private func pointHandle(_ position: Binding<CGPoint>, in bounds: CGSize, name: String,
                             identifier: String, color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 1, y: 1)
            .frame(width: MacRulerModel.handleHitSize, height: MacRulerModel.handleHitSize)
            .contentShape(Rectangle())
            .position(position.wrappedValue)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(canvasSpace))
                    .onChanged { value in
                        guard MacRulerModel.isUsableBounds(bounds) else { return }
                        let inset = MacRulerModel.handleHitSize / 2
                        position.wrappedValue = CGPoint(
                            x: min(max(value.location.x, inset), bounds.width - inset),
                            y: min(max(value.location.y, inset), bounds.height - inset))
                    }
            )
            .accessibilityLabel(name)
            .accessibilityIdentifier("mac.toolbox.ruler.handle.\(identifier)")
    }

    private func drawRulerStrip(context: GraphicsContext, size: CGSize, stripHeight: CGFloat) {
        let track = CGRect(origin: .zero, size: CGSize(width: size.width, height: stripHeight))
        context.fill(Path(track), with: .color(.secondary.opacity(0.08)))
        context.stroke(Path(track), with: .color(.secondary.opacity(0.25)), lineWidth: 1)
        guard let pointsPerMillimeter = model.pointsPerMillimeter,
              pointsPerMillimeter.isFinite, pointsPerMillimeter > 0 else {
            context.draw(Text(macToolboxText("此显示器尚未校准。放置参考物后完成校准，才会显示真实毫米和英寸刻度。",
                                             "This display is not calibrated. Place a reference and finish calibration to show true millimetre and inch ticks.", locale))
                .font(.callout).foregroundColor(.secondary),
                at: CGPoint(x: size.width / 2, y: stripHeight / 2))
            return
        }
        let visibleMillimetres = size.width / pointsPerMillimeter
        let millimetreLimit = min(visibleMillimetres, 1500)
        var millimetre: CGFloat = 0
        while millimetre <= millimetreLimit {
            let x = millimetre * pointsPerMillimeter
            let centimetre = millimetre.truncatingRemainder(dividingBy: 10) == 0
            let halfCentimetre = !centimetre && millimetre.truncatingRemainder(dividingBy: 5) == 0
            let length: CGFloat = centimetre ? 20 : halfCentimetre ? 13 : 7
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: length))
            context.stroke(path, with: .color(.primary.opacity(centimetre ? 0.9 : 0.45)),
                           lineWidth: centimetre ? 1.4 : 0.8)
            if centimetre, millimetre > 0 {
                context.draw(Text("\(Int(millimetre / 10))").font(.caption2.monospacedDigit()).foregroundColor(.secondary),
                            at: CGPoint(x: x + 3, y: 24), anchor: .leading)
            }
            millimetre += 1
        }
        let pointsPerInch = pointsPerMillimeter * 25.4
        let visibleInches = size.width / pointsPerInch
        let step: CGFloat = visibleInches > 60 ? 1 : 1.0 / 8.0
        var fraction: CGFloat = 0
        while fraction <= visibleInches + step {
            let x = fraction * pointsPerInch
            let whole = fraction.truncatingRemainder(dividingBy: 1) == 0
            let half = !whole && fraction.truncatingRemainder(dividingBy: 0.5) == 0
            let quarter = !whole && !half && fraction.truncatingRemainder(dividingBy: 0.25) == 0
            let length: CGFloat = whole ? 20 : half ? 14 : quarter ? 10 : 6
            var path = Path()
            path.move(to: CGPoint(x: x, y: stripHeight))
            path.addLine(to: CGPoint(x: x, y: stripHeight - length))
            context.stroke(path, with: .color(.primary.opacity(whole ? 0.9 : 0.4)),
                           lineWidth: whole ? 1.4 : 0.8)
            if whole, fraction > 0 {
                context.draw(Text("\(Int(fraction))\"")
                    .font(.caption2.monospacedDigit()).foregroundColor(.secondary),
                    at: CGPoint(x: x + 3, y: stripHeight - 24), anchor: .leading)
            }
            fraction += step
        }
    }

    private func drawMeasurementLine(context: GraphicsContext, midY: CGFloat) {
        var line = Path()
        line.move(to: CGPoint(x: model.markA.x, y: midY))
        line.addLine(to: CGPoint(x: model.markB.x, y: midY))
        context.stroke(line, with: .color(.blue), lineWidth: 2)
        for point in [model.markA, model.markB] {
            var cap = Path()
            cap.move(to: CGPoint(x: point.x, y: midY - 10))
            cap.addLine(to: CGPoint(x: point.x, y: midY + 10))
            context.stroke(cap, with: .color(.blue), lineWidth: 2)
        }
    }

    private func drawAngleScene(context: GraphicsContext, bounds: CGSize) {
        let vertex = model.vertex
        for end in [model.armEnd1, model.armEnd2] {
            let ray = raySegment(from: vertex, through: end, bounds: bounds)
            var path = Path()
            path.move(to: ray.0)
            path.addLine(to: ray.1)
            context.stroke(path, with: .color(.blue.opacity(0.85)), lineWidth: 2)
        }
        guard let degrees = model.angleDegrees() else { return }
        let radius: CGFloat = 44
        let angle1 = atan2(model.armEnd1.y - vertex.y, model.armEnd1.x - vertex.x)
        let angle2 = atan2(model.armEnd2.y - vertex.y, model.armEnd2.x - vertex.x)
        var sweep = angle2 - angle1
        while sweep > .pi { sweep -= 2 * .pi }
        while sweep < -.pi { sweep += 2 * .pi }
        var arc = Path()
        arc.addArc(center: vertex, radius: radius, startAngle: Angle(radians: angle1),
                   endAngle: Angle(radians: angle1 + sweep), clockwise: false)
        context.stroke(arc, with: .color(.indigo), lineWidth: 2)
        let mid = angle1 + sweep / 2
        context.draw(Text(String(format: "%.1f°", locale: Locale(identifier: "en_US_POSIX"), degrees))
            .font(.callout.monospacedDigit().weight(.semibold)).foregroundColor(.indigo),
            at: CGPoint(x: vertex.x + cos(mid) * (radius + 18), y: vertex.y + sin(mid) * (radius + 18)))
    }

    private func raySegment(from origin: CGPoint, through towards: CGPoint, bounds: CGSize) -> (CGPoint, CGPoint) {
        let dx = towards.x - origin.x
        let dy = towards.y - origin.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1e-6, length.isFinite else { return (origin, towards) }
        let direction = CGPoint(x: dx / length, y: dy / length)
        var scale = CGFloat.greatestFiniteMagnitude
        if direction.x > 1e-9 { scale = min(scale, (bounds.width - origin.x) / direction.x) }
        if direction.x < -1e-9 { scale = min(scale, -origin.x / direction.x) }
        if direction.y > 1e-9 { scale = min(scale, (bounds.height - origin.y) / direction.y) }
        if direction.y < -1e-9 { scale = min(scale, -origin.y / direction.y) }
        guard scale.isFinite, scale > 0 else { return (origin, towards) }
        return (origin, CGPoint(x: origin.x + direction.x * scale, y: origin.y + direction.y * scale))
    }

    private var readoutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mode == .distance {
                Label(macToolboxText("间距", "Distance", locale), systemImage: "ruler").font(.headline)
                if let pointsPerMillimeter = model.pointsPerMillimeter {
                    let points = abs(model.markB.x - model.markA.x)
                    let millimetres = points / pointsPerMillimeter
                    let inches = millimetres / 25.4
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(number(millimetres, precision: 1))
                            .font(.system(.title, design: .monospaced)).fontWeight(.semibold)
                        Text("mm").foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("mac.toolbox.ruler.readout.mm")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(number(inches, precision: 2)).font(.system(.title3, design: .monospaced))
                        Text("in").foregroundStyle(.secondary)
                        Spacer()
                        Text("\(number(points, precision: 0)) pt")
                            .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .accessibilityIdentifier("mac.toolbox.ruler.readout.in")
                } else {
                    Label(macToolboxText("尚未校准，仅显示屏幕点距离。",
                                         "Not calibrated. Only the on-screen point distance is shown.", locale),
                          systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("mac.toolbox.ruler.readout.uncalibrated")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(number(abs(model.markB.x - model.markA.x), precision: 0))
                            .font(.system(.title, design: .monospaced)).fontWeight(.semibold)
                        Text("pt").foregroundStyle(.secondary)
                    }
                }
            } else {
                Label(macToolboxText("夹角", "Angle", locale), systemImage: "angle").font(.headline)
                if let degrees = model.angleDegrees() {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(number(degrees, precision: 1))
                            .font(.system(.title, design: .monospaced)).fontWeight(.semibold)
                        Text("°").foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("mac.toolbox.ruler.readout.angle")
                    Text(macToolboxText("范围 0–180°", "Range 0–180°", locale))
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    Label(macToolboxText("拖动顶点与两个端点形成夹角。",
                                         "Drag the vertex and both endpoints to form an angle.", locale),
                          systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(macToolboxText("校准", "Calibration", locale), systemImage: "checkmark.circle").font(.headline)
                Spacer()
                if model.calibration != nil {
                    Button(macToolboxText("重新校准", "Recalibrate", locale)) {
                        model.beginRecalibration()
                    }
                    .font(.callout)
                    .accessibilityIdentifier("mac.toolbox.ruler.calibration.redo")
                }
            }
            if let failure = model.storageFailure {
                Label(storageFailureText(failure), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .accessibilityIdentifier("mac.toolbox.ruler.calibration.error")
                if failure == .save || failure == .clear {
                    Button(macToolboxText("重新读取并确认", "Reload and acknowledge", locale)) {
                        Task { await model.acknowledgeStorageFailureAfterReload() }
                    }
                }
                if failure == .capacity {
                    if !model.obsoleteUnverifiedIDs.isEmpty {
                        Button(macToolboxText("检查可清理的旧校准", "Review old calibrations", locale)) {
                            reviewedObsoleteIDs = model.obsoleteUnverifiedIDs
                            cleanupConfirmation = true
                        }
                    }
                    Button(macToolboxText("暂不保存", "Continue without saving", locale)) {
                        model.acknowledgeCapacityWithoutSaving()
                    }
                }
            }
            if model.calibration == nil {
                Text(macToolboxText("把参考物放在屏幕上，拖动两个蓝色标记对齐两端，然后完成校准。校准只对当前显示器有效。",
                                   "Place a reference on screen, drag the two blue marks to its edges, then finish calibrating. The calibration applies only to this display.", locale))
                    .font(.callout).foregroundStyle(.secondary)
                Text(macToolboxText("无法可靠识别的显示器在重新连接或打开应用后需要重新校准。",
                                    "Displays without a reliable identity need recalibration after reconnecting or reopening the app.", locale))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(macToolboxText("参考物", "Reference", locale), selection: $model.referencePreset) {
                    ForEach(MacRulerReferencePreset.allCases) { preset in
                        Text(preset.title(locale)).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("mac.toolbox.ruler.calibration.reference")
                if model.referencePreset == .custom {
                    HStack {
                        TextField(macToolboxText("参考长度（毫米）", "Reference length (mm)", locale),
                                  text: $model.customReferenceMillimeters)
                            .font(.body.monospaced())
                            .accessibilityIdentifier("mac.toolbox.ruler.calibration.custom")
                        Text("mm").foregroundStyle(.secondary)
                    }
                }
                Button {
                    model.requestCalibration(separation: abs(model.markB.x - model.markA.x))
                } label: {
                    Label(macToolboxText("完成校准", "Finish calibration", locale), systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.storageIsReady || model.referenceMillimetres == nil || abs(model.markB.x - model.markA.x) < 10)
                .accessibilityIdentifier("mac.toolbox.ruler.calibration.finish")
            } else if let calibration = model.calibration {
                LabeledContent(macToolboxText("每毫米", "Per millimetre", locale)) {
                    Text("\(number(calibration.pointsPerMillimeter, precision: 2)) pt").monospacedDigit()
                }
                .font(.callout)
                LabeledContent(macToolboxText("显示器", "Display", locale)) {
                    Text(calibration.displayName)
                }
                .font(.callout)
                LabeledContent(macToolboxText("校准时间", "Calibrated", locale)) {
                    Text(calibration.timestamp.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.callout)
                Button(role: .destructive) {
                    model.requestClearCalibration()
                } label: {
                    Text(macToolboxText("清除此显示器的校准", "Clear this display's calibration", locale))
                }
                .font(.callout)
                .accessibilityIdentifier("mac.toolbox.ruler.calibration.clear")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac.toolbox.ruler.calibration.card")
    }

    private var displayCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(macToolboxText("当前显示器", "Current display", locale)).font(.caption).foregroundStyle(.secondary)
            if let display = model.display {
                Text(display.name).font(.callout.weight(.medium))
                Text(macToolboxText("\(Int(display.widthPoints)) × \(Int(display.heightPoints)) 点 · \(String(format: "%.1f", display.nativeScale))×",
                                    "\(Int(display.widthPoints)) × \(Int(display.heightPoints)) pt · \(String(format: "%.1f", display.nativeScale))×", locale))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text(macToolboxText("正在读取显示器…", "Reading the display…", locale))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("mac.toolbox.ruler.display")
    }

    private func storageFailureText(_ failure: MacRulerStorageFailure) -> String {
        switch failure {
        case .load: macToolboxText("校准数据读取失败，可重新校准；原文件未被覆盖。",
                                   "Calibration could not be loaded. You can calibrate again; the original file was not overwritten.", locale)
        case .corrupt: macToolboxText("校准文件已损坏，原数据已保留；重新校准仅在本次界面有效。",
                                      "The calibration file is corrupted and preserved; recalibration applies only in this session.", locale)
        case .save: macToolboxText("无法确认校准是否保存，数据可能已写入。请检查后再决定是否重试。",
                                   "Calibration may have been saved, but the result could not be confirmed. Check before retrying.", locale)
        case .clear: macToolboxText("无法确认校准是否清除，数据可能已更改。请检查后再决定是否重试。",
                                    "The removal could not be confirmed. The data may have changed; check before retrying.", locale)
        case .invalid: macToolboxText("校准输入无效，请检查参考长度和标记距离。",
                                      "The calibration input is invalid. Check the reference length and mark distance.", locale)
        case .capacity: macToolboxText("校准记录已满。请检查可清理的旧临时校准，或暂不保存。",
                                       "Calibration storage is full. Review old temporary calibrations or continue without saving.", locale)
        }
    }

    private func copyText() -> String? {
        switch mode {
        case .distance:
            guard let pointsPerMillimeter = model.pointsPerMillimeter else { return nil }
            let millimetres = abs(model.markB.x - model.markA.x) / pointsPerMillimeter
            switch unit {
            case .millimeters: return "\(number(millimetres, precision: 1)) mm"
            case .inches: return "\(number(millimetres / 25.4, precision: 2)) in"
            }
        case .angle:
            guard let degrees = model.angleDegrees() else { return nil }
            return "\(number(degrees, precision: 1))°"
        }
    }

    private func number(_ value: Double, precision: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = precision
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

@MainActor
private struct MacScreenReader: NSViewRepresentable {
    let onChange: @MainActor (NSScreen?) -> Void

    func makeNSView(context: Context) -> ScreenTrackingView {
        let view = ScreenTrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ScreenTrackingView, context: Context) {
        nsView.onChange = onChange
        nsView.refresh()
    }
}

@MainActor
private final class ScreenTrackingView: NSView {
    var onChange: ((NSScreen?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged(_:)),
                                                   name: NSWindow.didChangeScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged(_:)),
                                                   name: NSWindow.didMoveNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged(_:)),
                                                   name: NSWindow.didResizeNotification, object: window)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        refresh()
    }

    func refresh() {
        guard let window, let screen = window.screen, screen.frame.contains(window.frame) else {
            onChange?(nil)
            return
        }
        onChange?(screen)
    }

    @objc private func screenChanged(_ notification: Notification) {
        if notification.name == NSApplication.didChangeScreenParametersNotification {
            MacDisplayIdentity.invalidateTopology()
        }
        refresh()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

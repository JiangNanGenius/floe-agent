import Foundation
import SwiftUI
import FloeToolboxCore
import FloeToolboxUtilities
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A screen ruler and angle gauge. Physical sizes are shown only from an
/// explicit user calibration bound to the current display scale and viewport;
/// points are never presented as millimetres and no DPI is inferred from the
/// device model. All drawing is stateless Canvas output with drag gestures —
/// no timers, no background sampling to stop.
public struct ToolboxRulerView: View {
    public init() {}

    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @StateObject private var model = EverydayRulerModel()
    @Namespace private var canvasCoordinateSpace

    private enum Mode: String, CaseIterable, Identifiable {
        case distance, angle
        var id: String { rawValue }
    }
    private enum ReadoutUnit: String, CaseIterable, Identifiable {
        case millimeters, inches
        var id: String { rawValue }
    }

    @State private var mode: Mode = .distance
    @State private var readoutUnit: ReadoutUnit = .millimeters
    @State private var copied = false

    public var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 700 && !dynamicTypeSize.isAccessibilitySize
            VStack(spacing: 0) {
                controls.padding(.horizontal, 16).padding(.vertical, 10)
                if wide {
                    HStack(alignment: .top, spacing: 16) {
                        canvas(geometry.size).frame(maxWidth: .infinity, maxHeight: .infinity)
                        VStack(spacing: 16) { readoutCard; calibrationCard }.frame(width: 300).padding(.trailing, 16).padding(.bottom, 16)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            canvas(geometry.size).frame(height: max(320, geometry.size.height * 0.52))
                            readoutCard
                            calibrationCard
                        }.padding(.horizontal, 16).padding(.bottom, 16)
                    }
                }
            }
        }
        .background(Color.secondary.opacity(0.04))
        .navigationTitle(workbenchText("直尺", "Ruler", locale))
        .task { await model.load(displayScale: Double(displayScale)) }
        .onChange(of: mode) { _, _ in copied = false }
    }

    // MARK: Controls (kept outside the visualization, no floating capsules)

    private var controls: some View {
        HStack(spacing: 12) {
            Picker(workbenchText("模式", "Mode", locale), selection: $mode) {
                Text(workbenchText("直尺", "Ruler", locale)).tag(Mode.distance)
                Text(workbenchText("角度", "Angle", locale)).tag(Mode.angle)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .accessibilityIdentifier("toolbox.ruler.mode")
            if mode == .distance {
                Picker(workbenchText("单位", "Units", locale), selection: $readoutUnit) {
                    Text("mm").tag(ReadoutUnit.millimeters)
                    Text("in").tag(ReadoutUnit.inches)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .accessibilityIdentifier("toolbox.ruler.unit")
            }
            Spacer(minLength: 8)
            Button {
                model.resetMarks()
            } label: {
                Label(workbenchText("重置", "Reset", locale), systemImage: "arrow.counterclockwise").labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .accessibilityLabel(workbenchText("重置位置", "Reset positions", locale))
            .accessibilityIdentifier("toolbox.ruler.reset")
            Button {
                if let text = copyText() { everydayRulerCopy(text); copied = true }
            } label: {
                Label(copied ? workbenchText("已复制", "Copied", locale) : workbenchText("复制", "Copy", locale),
                      systemImage: copied ? "checkmark" : "doc.on.doc").labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .disabled(copyText() == nil)
            .accessibilityLabel(workbenchText("复制读数", "Copy reading", locale))
            .accessibilityIdentifier("toolbox.ruler.copy")
        }
    }

    // MARK: Canvas

    private func canvas(_ size: CGSize) -> some View {
        GeometryReader { canvasGeometry in
            let bounds = canvasGeometry.size
            ZStack {
                Color.clear.contentShape(Rectangle())
                if mode == .distance {
                    distanceCanvas(bounds)
                } else {
                    angleCanvas(bounds)
                }
            }
            .coordinateSpace(name: canvasCoordinateSpace)
            .onAppear { model.placeMarks(in: bounds, displayScale: Double(displayScale)) }
            .onChange(of: bounds) { _, newValue in model.placeMarks(in: newValue, displayScale: Double(displayScale)) }
            .onChange(of: displayScale) { _, newValue in model.placeMarks(in: bounds, displayScale: Double(newValue)) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("toolbox.ruler.canvas")
        }
    }

    private func distanceCanvas(_ bounds: CGSize) -> some View {
        let stripHeight: CGFloat = min(110, max(84, bounds.height * 0.3))
        let trackMidY = EverydayRulerModel.distanceTrackY(in: bounds)
        return ZStack(alignment: .topLeading) {
            Canvas { context, size in
                drawRulerStrip(context: context, size: size, stripHeight: stripHeight)
            }
            .frame(height: stripHeight)
            Canvas { context, _ in
                drawMeasurementLine(context: context, midY: trackMidY)
            }
            handle(at: $model.markA, midY: trackMidY, in: bounds, name: workbenchText("标记 A", "Mark A", locale), identifier: "a")
            handle(at: $model.markB, midY: trackMidY, in: bounds, name: workbenchText("标记 B", "Mark B", locale), identifier: "b")
        }
    }

    private func angleCanvas(_ bounds: CGSize) -> some View {
        ZStack {
            Canvas { context, _ in
                drawAngleScene(context: context, bounds: bounds)
            }
            handle(at: $model.vertex, in: bounds, name: workbenchText("顶点", "Vertex", locale), identifier: "vertex", tint: .indigo)
            handle(at: $model.armEnd1, in: bounds, name: workbenchText("射线端点 1", "Ray endpoint 1", locale), identifier: "arm1", tint: .blue)
            handle(at: $model.armEnd2, in: bounds, name: workbenchText("射线端点 2", "Ray endpoint 2", locale), identifier: "arm2", tint: .blue)
        }
    }

    // MARK: Handles

    private func handle(at position: Binding<CGPoint>, midY: CGFloat, in bounds: CGSize, name: String, identifier: String) -> some View {
        Circle().fill(.blue).frame(width: 18, height: 18)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 1, y: 1)
            .frame(width: EverydayRulerModel.handleHitSize, height: EverydayRulerModel.handleHitSize)
            .contentShape(Rectangle())
            .position(CGPoint(x: position.wrappedValue.x, y: midY))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(canvasCoordinateSpace))
                    .onChanged { value in
                        guard EverydayRulerModel.isUsableBounds(bounds) else { return }
                        let inset = EverydayRulerModel.handleHitSize / 2
                        let x = min(max(value.location.x, inset), bounds.width - inset)
                        position.wrappedValue = CGPoint(x: x, y: midY)
                    }
            )
            .accessibilityLabel(name)
            .accessibilityIdentifier("toolbox.ruler.handle.\(identifier)")
    }

    private func handle(at position: Binding<CGPoint>, in bounds: CGSize, name: String, identifier: String, tint: Color) -> some View {
        Circle().fill(tint).frame(width: 18, height: 18)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 1, y: 1)
            .frame(width: EverydayRulerModel.handleHitSize, height: EverydayRulerModel.handleHitSize)
            .contentShape(Rectangle())
            .position(position.wrappedValue)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(canvasCoordinateSpace))
                    .onChanged { value in
                        guard EverydayRulerModel.isUsableBounds(bounds) else { return }
                        let inset = EverydayRulerModel.handleHitSize / 2
                        position.wrappedValue = CGPoint(
                            x: min(max(value.location.x, inset), bounds.width - inset),
                            y: min(max(value.location.y, inset), bounds.height - inset))
                    }
            )
            .accessibilityLabel(name)
            .accessibilityIdentifier("toolbox.ruler.handle.\(identifier)")
    }

    // MARK: Drawing

    private func drawRulerStrip(context: GraphicsContext, size: CGSize, stripHeight: CGFloat) {
        let track = CGRect(origin: .zero, size: CGSize(width: size.width, height: stripHeight))
        context.fill(Path(track), with: .color(.secondary.opacity(0.08)))
        context.stroke(Path(track), with: .color(.secondary.opacity(0.25)), lineWidth: 1)
        guard let pmm = model.pointsPerMillimeter, pmm.isFinite, pmm > 0 else {
            context.draw(Text(workbenchText("校准后显示真实毫米与英寸刻度", "Calibrate to show true millimetre and inch ticks", locale))
                .font(.callout).foregroundColor(.secondary), at: CGPoint(x: size.width / 2, y: stripHeight / 2))
            return
        }
        let visibleMillimetres = size.width / pmm
        // Millimetre / centimetre ticks along the top edge.
        let millimetreLimit = min(visibleMillimetres, 1500)
        var millimetre: CGFloat = 0
        while millimetre <= millimetreLimit {
            let x = millimetre * pmm
            let centimetre = (millimetre.truncatingRemainder(dividingBy: 10) == 0)
            let halfCentimetre = !centimetre && millimetre.truncatingRemainder(dividingBy: 5) == 0
            let length: CGFloat = centimetre ? 20 : halfCentimetre ? 13 : 7
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: length))
            context.stroke(path, with: .color(.primary.opacity(centimetre ? 0.9 : 0.45)), lineWidth: centimetre ? 1.4 : 0.8)
            if centimetre, millimetre > 0 {
                let label = Text("\(Int(millimetre / 10))").font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                context.draw(label, at: CGPoint(x: x + 3, y: 24), anchor: .leading)
            }
            millimetre += 1
        }
        // Inch ticks along the bottom edge (25.4 mm per inch).
        let pointsPerInch = pmm * 25.4
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
            context.stroke(path, with: .color(.primary.opacity(whole ? 0.9 : 0.4)), lineWidth: whole ? 1.4 : 0.8)
            if whole, fraction > 0 {
                let label = Text("\(Int(fraction))\"").font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                context.draw(label, at: CGPoint(x: x + 3, y: stripHeight - 24), anchor: .leading)
            }
            fraction += step
        }
    }

    private func drawMeasurementLine(context: GraphicsContext, midY: CGFloat) {
        let a = model.markA, b = model.markB
        var line = Path()
        line.move(to: CGPoint(x: a.x, y: midY))
        line.addLine(to: CGPoint(x: b.x, y: midY))
        context.stroke(line, with: .color(.blue), lineWidth: 2)
        for point in [a, b] {
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
        if let degrees = model.angleDegrees() {
            let radius: CGFloat = 44
            let angle1 = atan2(model.armEnd1.y - vertex.y, model.armEnd1.x - vertex.x)
            let angle2 = atan2(model.armEnd2.y - vertex.y, model.armEnd2.x - vertex.x)
            var sweep = angle2 - angle1
            while sweep > .pi { sweep -= 2 * .pi }
            while sweep < -.pi { sweep += 2 * .pi }
            var arc = Path()
            arc.addArc(center: vertex, radius: radius, startAngle: Angle(radians: angle1), endAngle: Angle(radians: angle1 + sweep), clockwise: false)
            context.stroke(arc, with: .color(.indigo), lineWidth: 2)
            let mid = angle1 + sweep / 2
            let labelPoint = CGPoint(x: vertex.x + cos(mid) * (radius + 18), y: vertex.y + sin(mid) * (radius + 18))
            let label = Text(String(format: "%.1f\u{00B0}", locale: Locale(identifier: "en_US_POSIX"), degrees))
                .font(.callout.monospacedDigit().weight(.semibold)).foregroundColor(.indigo)
            context.draw(label, at: labelPoint, anchor: .center)
        }
    }

    /// Clips the infinite ray from `origin` through `towards` to the canvas.
    private func raySegment(from origin: CGPoint, through towards: CGPoint, bounds: CGSize) -> (CGPoint, CGPoint) {
        let dx = towards.x - origin.x, dy = towards.y - origin.y
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

    // MARK: Readout card (grouped, outside the canvas)

    private var readoutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mode == .distance {
                Label(workbenchText("间距", "Distance", locale), systemImage: "ruler").font(.headline)
                if let pmm = model.pointsPerMillimeter {
                    let points = abs(model.markB.x - model.markA.x)
                    let millimetres = points / pmm
                    let inches = millimetres / 25.4
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.number(millimetres, precision: 1))
                            .font(.system(.title, design: .monospaced)).fontWeight(.semibold)
                        Text("mm").foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("toolbox.ruler.readout.mm")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.number(inches, precision: 2))
                            .font(.system(.title3, design: .monospaced))
                        Text("in").foregroundStyle(.secondary)
                        Spacer()
                        Text(workbenchText("\(Self.number(points, precision: 0)) pt", "\(Self.number(points, precision: 0)) pt", locale))
                            .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    .accessibilityIdentifier("toolbox.ruler.readout.in")
                } else {
                    Label(workbenchText("尚未校准，仅显示屏幕点距离。", "Not calibrated yet. Only the on-screen point distance is shown.", locale),
                          systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("toolbox.ruler.readout.uncalibrated")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.number(abs(model.markB.x - model.markA.x), precision: 0))
                            .font(.system(.title, design: .monospaced)).fontWeight(.semibold)
                        Text("pt").foregroundStyle(.secondary)
                    }
                }
            } else {
                Label(workbenchText("夹角", "Angle", locale), systemImage: "angle").font(.headline)
                if let degrees = model.angleDegrees() {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.number(degrees, precision: 1))
                            .font(.system(.title, design: .monospaced)).fontWeight(.semibold)
                        Text("\u{00B0}").foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("toolbox.ruler.readout.angle")
                    Text(workbenchText("范围 0–180\u{00B0}", "Range 0–180°", locale))
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    Label(workbenchText("拖动顶点与两个端点形成夹角。", "Drag the vertex and both endpoints to form an angle.", locale),
                          systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Calibration card

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(workbenchText("校准", "Calibration", locale), systemImage: "checkmark.circle").font(.headline)
                Spacer()
                if model.calibration != nil, !model.calibrationInvalid {
                    Button(workbenchText("重新校准", "Recalibrate", locale)) { model.beginRecalibration() }
                        .font(.callout)
                        .accessibilityIdentifier("toolbox.ruler.calibration.redo")
                }
            }
            if let failure = model.storageFailure {
                Label(calibrationFailureText(failure, locale), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .accessibilityIdentifier("toolbox.ruler.calibration.error")
            }
            if model.calibrationInvalid {
                Label(workbenchText("显示环境已变化，请重新校准。", "The display environment changed. Calibrate again.", locale),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .accessibilityIdentifier("toolbox.ruler.calibration.invalid")
            }
            if model.calibration == nil || model.calibrationInvalid {
                Text(workbenchText("把参考物放在屏幕上，拖动两个蓝色标记对齐它的两端，然后完成校准。",
                                   "Place a reference on screen, drag the two blue marks onto its edges, then finish calibrating.", locale))
                    .font(.callout).foregroundStyle(.secondary)
                Picker(workbenchText("参考物", "Reference", locale), selection: $model.referencePreset) {
                    ForEach(EverydayRulerModel.ReferencePreset.allCases) { preset in
                        Text(preset.title(locale)).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("toolbox.ruler.calibration.reference")
                if model.referencePreset == .custom {
                    HStack {
                        TextField(workbenchText("参考长度（毫米）", "Reference length (mm)", locale), text: $model.customReferenceMillimetres)
                            .font(.body.monospaced())
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .accessibilityIdentifier("toolbox.ruler.calibration.custom")
                        Text("mm").foregroundStyle(.secondary)
                    }
                }
                Button {
                    model.calibrate(withMarkSeparation: abs(model.markB.x - model.markA.x), displayScale: Double(displayScale))
                } label: {
                    Label(workbenchText("完成校准", "Finish calibration", locale), systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.referenceMillimetres == nil || abs(model.markB.x - model.markA.x) < 10)
                .accessibilityIdentifier("toolbox.ruler.calibration.finish")
            } else if let calibration = model.calibration {
                LabeledContent(workbenchText("每毫米", "Per millimetre", locale)) {
                    Text("\(Self.number(calibration.pointsPerMillimeter, precision: 2)) pt").monospacedDigit()
                }
                .font(.callout)
                LabeledContent(workbenchText("校准时间", "Calibrated", locale)) {
                    Text(calibration.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.callout)
                }
                Button(workbenchText("清除校准", "Clear calibration", locale), role: .destructive) {
                    model.clearCalibration()
                }
                .font(.callout)
                .accessibilityIdentifier("toolbox.ruler.calibration.clear")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolbox.ruler.calibration.card")
    }

    private func copyText() -> String? {
        switch mode {
        case .distance:
            guard let pmm = model.pointsPerMillimeter else { return nil }
            let points = abs(model.markB.x - model.markA.x)
            let millimetres = points / pmm
            switch readoutUnit {
            case .millimeters: return "\(Self.number(millimetres, precision: 1)) mm"
            case .inches: return "\(Self.number(millimetres / 25.4, precision: 2)) in"
            }
        case .angle:
            guard let degrees = model.angleDegrees() else { return nil }
            return "\(Self.number(degrees, precision: 1))°"
        }
    }

    private static func number(_ value: Double, precision: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = precision
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

private func everydayRulerCopy(_ value: String) {
    #if os(iOS)
    UIPasteboard.general.string = value
    #elseif os(macOS)
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    #endif
}

private func calibrationFailureText(_ failure: String, _ locale: Locale) -> String {
    let zh = locale.language.languageCode?.identifier == "zh"
    switch failure {
    case "calibration corrupt":
        return zh ? "校准文件已损坏，原有数据未改动；请重新校准。" : "The calibration file is corrupted. Existing data was left untouched; calibrate again."
    case "calibration load":
        return zh ? "校准数据读取失败，可立即重新校准。" : "Calibration could not be loaded. You can calibrate again now."
    case "calibration save":
        return zh ? "校准保存失败，本次校准仅对当前界面生效。" : "Calibration could not be saved. It applies only in this session."
    case "calibration clear":
        return zh ? "校准清除失败，请重试。" : "Calibration could not be cleared. Try again."
    default:
        return zh ? "校准数据暂不可用" : "Calibration is temporarily unavailable"
    }
}

// MARK: - Model

@MainActor public final class EverydayRulerModel: ObservableObject {
    @Published public var markA: CGPoint = CGPoint(x: 90, y: 200)
    @Published public var markB: CGPoint = CGPoint(x: 300, y: 200)
    @Published public var vertex: CGPoint = CGPoint(x: 200, y: 240)
    @Published public var armEnd1: CGPoint = CGPoint(x: 120, y: 170)
    @Published public var armEnd2: CGPoint = CGPoint(x: 290, y: 160)
    @Published public var calibration: EverydayRulerCalibration?
    @Published public var calibrationInvalid = false
    @Published public var referencePreset: ReferencePreset = .creditCard
    @Published public var customReferenceMillimetres = "100"
    /// Stable identifier for localized storage errors ("calibration
    /// load/save/clear/corrupt"); calibration stays usable in memory when set.
    @Published public private(set) var storageFailure: String?

    public enum ReferencePreset: String, CaseIterable, Identifiable {
        case creditCard, idCard, a4, custom
        public var id: String { rawValue }
        func title(_ locale: Locale) -> String {
            let zh = locale.language.languageCode?.identifier == "zh"
            switch self {
            case .creditCard: return zh ? "信用卡或银行卡（85.60 毫米）" : "Credit or debit card (85.60 mm)"
            case .idCard: return zh ? "身份证（85.60 毫米）" : "ID card (85.60 mm)"
            case .a4: return zh ? "A4 纸短边（210 毫米）" : "A4 paper short edge (210 mm)"
            case .custom: return zh ? "自定义长度" : "Custom length"
            }
        }
    }

    public let store: EverydayRulerCalibrationStore
    public init(store: EverydayRulerCalibrationStore = EverydayRulerModel.defaultStore) {
        self.store = store
    }

    public static let defaultStoreURL: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("FloeToolbox/Everyday/RulerCalibration.json")
    }()
    public static let defaultStore = EverydayRulerCalibrationStore(url: defaultStoreURL)

    public var referenceMillimetres: Double? {
        let value: String
        switch referencePreset {
        case .creditCard, .idCard: return 85.60
        case .a4: return 210
        case .custom: value = customReferenceMillimetres
        }
        let canonical = EverydayNumberText.canonical(value.trimmingCharacters(in: .whitespacesAndNewlines))
        return Double(canonical).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// Calibration only applies to the display environment it was measured on.
    public var pointsPerMillimeter: Double? {
        guard let calibration, !calibrationInvalid else { return nil }
        return calibration.pointsPerMillimeter
    }

    public func angleDegrees() -> Double? {
        try? EverydayRulerGeometry.angleDegrees(vertex: vertex, first: armEnd1, second: armEnd2)
    }

    public func placeMarks(in bounds: CGSize, displayScale: Double) {
        guard Self.isUsableBounds(bounds) else { return }
        if !hasPlacedMarks {
            let y = Self.distanceTrackY(in: bounds)
            markA = CGPoint(x: bounds.width * 0.25, y: y)
            markB = CGPoint(x: bounds.width * 0.75, y: y)
            vertex = CGPoint(x: bounds.width / 2, y: bounds.height * 0.55)
            armEnd1 = CGPoint(x: bounds.width * 0.2, y: bounds.height * 0.3)
            armEnd2 = CGPoint(x: bounds.width * 0.8, y: bounds.height * 0.32)
            hasPlacedMarks = true
        }
        clampMarks(in: bounds, displayScale: displayScale)
    }

    private var hasPlacedMarks = false

    static let handleHitSize: CGFloat = 44

    static func isUsableBounds(_ bounds: CGSize) -> Bool {
        bounds.width.isFinite && bounds.height.isFinite
            && bounds.width >= handleHitSize * 2 && bounds.height >= handleHitSize * 2
    }

    static func distanceTrackY(in bounds: CGSize) -> CGFloat {
        let stripHeight: CGFloat = min(110, max(84, bounds.height * 0.3))
        let inset = handleHitSize / 2
        return min(max(stripHeight + (bounds.height - stripHeight) / 2, inset), max(inset, bounds.height - inset))
    }

    public func clampMarks(in bounds: CGSize, displayScale: Double) {
        guard Self.isUsableBounds(bounds) else { return }
        guard hasPlacedMarks else {
            placeMarks(in: bounds, displayScale: displayScale)
            return
        }
        let inset = Self.handleHitSize / 2
        let clamp: (CGPoint) -> CGPoint = {
            CGPoint(x: min(max($0.x, inset), bounds.width - inset),
                    y: min(max($0.y, inset), bounds.height - inset))
        }
        // Shift the distance pair together on resize, preserving its span when
        // it fits. Independent clamping can collapse both marks onto one edge.
        let forward = markB.x >= markA.x
        let span = min(abs(markB.x - markA.x), bounds.width - inset * 2)
        let start = min(max(min(markA.x, markB.x), inset), bounds.width - inset - span)
        let y = Self.distanceTrackY(in: bounds)
        markA = CGPoint(x: forward ? start : start + span, y: y)
        markB = CGPoint(x: forward ? start + span : start, y: y)
        vertex = clamp(vertex); armEnd1 = clamp(armEnd1); armEnd2 = clamp(armEnd2)
        refreshCompatibility(for: bounds, displayScale: displayScale)
    }

    public func resetMarks() {
        hasPlacedMarks = false
        if let bounds = lastBounds, let scale = lastDisplayScale { placeMarks(in: bounds, displayScale: scale) }
    }

    public func calibrate(withMarkSeparation separation: CGFloat, displayScale: Double) {
        guard let millimetres = referenceMillimetres, let bounds = lastBounds else { return }
        let key = Self.viewportKey(for: bounds)
        do {
            let value = try EverydayRulerGeometry.calibrate(knownMillimeters: millimetres, measuredPoints: Double(separation), nativeScale: displayScale, viewportKey: key)
            calibration = value; calibrationInvalid = false
            Task {
                do { try await store.save(value); self.storageFailure = nil }
                catch { self.storageFailure = "calibration save" }
            }
        } catch {
            storageFailure = nil
        }
    }

    public func beginRecalibration() {
        calibration = nil
    }

    public func clearCalibration() {
        Task {
            do {
                try await store.clear()
                calibration = nil; calibrationInvalid = false; storageFailure = nil
            } catch {
                storageFailure = "calibration clear"
            }
        }
    }

    public func load(displayScale: Double) async {
        lastDisplayScale = displayScale
        do {
            calibration = try await store.load()
            storageFailure = nil
        } catch is CancellationError {
        } catch ToolboxError.corruptStore {
            calibration = nil; storageFailure = "calibration corrupt"
        } catch {
            calibration = nil; storageFailure = "calibration load"
        }
        if let bounds = lastBounds { refreshCompatibility(for: bounds, displayScale: displayScale) }
    }

    private var lastBounds: CGSize?
    private var lastDisplayScale: Double?
    private func refreshCompatibility(for bounds: CGSize, displayScale: Double) {
        lastBounds = bounds
        lastDisplayScale = displayScale
        guard let calibration else { return }
        calibrationInvalid = !calibration.isCompatible(nativeScale: displayScale, viewportKey: Self.viewportKey(for: bounds))
    }

    /// Viewport identity banded at 128 pt so minor resizes keep calibration
    /// while orientation, split-view and display changes invalidate it.
    static func viewportKey(for bounds: CGSize) -> String {
        "\(Int(bounds.width / 128))x\(Int(bounds.height / 128))"
    }
}

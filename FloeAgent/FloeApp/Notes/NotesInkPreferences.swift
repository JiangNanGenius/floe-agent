// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import PencilKit
import Observation

import FloeCore
enum NotesBrushKind: String, CaseIterable, Codable {
    case pen, fountainPen, monoline, pencil, crayon, watercolor, reed, marker

    var title: String {
        switch self {
        case .pen: FloeL10n.l("notes.notes_ink_preferences.ballpoint_pen")
        case .fountainPen: FloeL10n.l("notes.notes_ink_preferences.fountain_pen")
        case .monoline: FloeL10n.l("notes.notes_ink_preferences.fine_liner")
        case .pencil: FloeL10n.l("notes.notes_ink_preferences.pencil")
        case .crayon: FloeL10n.l("notes.notes_ink_preferences.crayon")
        case .watercolor: FloeL10n.l("notes.notes_ink_preferences.watercolor")
        case .reed: FloeL10n.l("notes.notes_ink_preferences.calligraphy_pen")
        case .marker: FloeL10n.l("notes.notes_ink_preferences.highlighter")
        }
    }


    /// Same label as `title` but as a SwiftUI `LocalizedStringKey`.
    var keyTitle: LocalizedStringKey {
        switch self {
        case .pen: "notes.notes_ink_preferences.ballpoint_pen"
        case .fountainPen: "notes.notes_ink_preferences.fountain_pen"
        case .monoline: "notes.notes_ink_preferences.fine_liner"
        case .pencil: "notes.notes_ink_preferences.pencil"
        case .crayon: "notes.notes_ink_preferences.crayon"
        case .watercolor: "notes.notes_ink_preferences.watercolor"
        case .reed: "notes.notes_ink_preferences.calligraphy_pen"
        case .marker: "notes.notes_ink_preferences.highlighter"
        }
    }
    var inkType: PKInkingTool.InkType {
        switch self {
        case .pen: .pen
        case .fountainPen: .fountainPen
        case .monoline: .monoline
        case .pencil: .pencil
        case .crayon: .crayon
        case .watercolor: .watercolor
        case .reed: .reed
        case .marker: .marker
        }
    }
    var icon: String {
        switch self {
        case .pencil, .crayon: "pencil"
        case .marker: "highlighter"
        case .watercolor: "paintbrush.pointed"
        default: "pencil.tip"
        }
    }
    var widthRange: ClosedRange<Double> {
        Double(inkType.validWidthRange.lowerBound)...Double(inkType.validWidthRange.upperBound)
    }
}

@MainActor @Observable final class NotesInkPreferences {
    static let shared = NotesInkPreferences()
    static let storageKey = "notes.ink.preferences.v1"
    struct Configuration: Codable, Equatable, Hashable {
        var color: String
        var width: Double
        // Optional keeps snapshots from earlier builds readable.
        var opacity: Double? = nil
    }
    private struct Snapshot: Codable {
        var selectedPen: NotesBrushKind
        var brushes: [String: Configuration]
    }
    private(set) var selectedPen: NotesBrushKind = .pen
    private var brushes: [String: Configuration] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            selectedPen = snapshot.selectedPen == .marker ? .pen : snapshot.selectedPen
            brushes = snapshot.brushes
        } else {
            // Keep pre-upgrade color and width choices; leave their original keys
            // intact for recovery by an older application version.
            for kind in [NotesBrushKind.pen, .marker] {
                let prefix = kind == .marker ? "notes.marker" : "notes.pen"
                let fallback = configuration(for: kind)
                brushes[kind.rawValue] = Configuration(
                    color: defaults.string(forKey: prefix + ".color") ?? fallback.color,
                    width: (defaults.object(forKey: prefix + ".width") as? Double) ?? fallback.width)
            }
        }
    }

    func configuration(for kind: NotesBrushKind) -> Configuration {
        let fallback = Configuration(color: kind == .marker ? "#FACC15" : "#18181B",
                                     width: kind == .pen ? 3 : kind == .marker ? 20 : Double(kind.inkType.defaultWidth))
        let stored = brushes[kind.rawValue] ?? fallback
        return Configuration(color: Self.validColor(stored.color) ? stored.color : fallback.color,
                             width: min(kind.widthRange.upperBound, max(kind.widthRange.lowerBound,
                                      stored.width.isFinite ? stored.width : fallback.width)),
                             opacity: Self.clampedOpacity(stored.opacity, for: kind))
    }

    func select(_ kind: NotesBrushKind) {
        guard kind != .marker else { return }
        selectedPen = kind
        persist()
    }
    func setColor(_ color: String, for kind: NotesBrushKind) {
        guard Self.validColor(color) else { return }
        var value = configuration(for: kind); value.color = color.uppercased()
        brushes[kind.rawValue] = value; persist()
    }
    func setWidth(_ width: Double, for kind: NotesBrushKind) {
        guard width.isFinite else { return }
        var value = configuration(for: kind)
        value.width = min(kind.widthRange.upperBound, max(kind.widthRange.lowerBound, width))
        brushes[kind.rawValue] = value; persist()
    }
    func setOpacity(_ opacity: Double, for kind: NotesBrushKind) {
        guard opacity.isFinite else { return }
        var value = configuration(for: kind)
        value.opacity = Self.clampedOpacity(opacity, for: kind)
        brushes[kind.rawValue] = value; persist()
    }
    private static func clampedOpacity(_ opacity: Double?, for kind: NotesBrushKind) -> Double {
        let fallback = kind == .marker ? 0.45 : 1.0
        let value = opacity ?? fallback
        return value.isFinite ? min(1, max(0, value)) : fallback
    }
    func inkingTool(for kind: NotesBrushKind) -> PKInkingTool {
        let value = configuration(for: kind)
        let rgb = UInt32(value.color.dropFirst(), radix: 16) ?? 0x18181B
        let color = UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                            green: CGFloat((rgb >> 8) & 255) / 255,
                            blue: CGFloat(rgb & 255) / 255, alpha: value.opacity ?? 1)
        return PKInkingTool(kind.inkType, color: color, width: value.width)
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(Snapshot(selectedPen: selectedPen, brushes: brushes)) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
    private static func validColor(_ value: String) -> Bool {
        value.count == 7 && value.first == "#" && UInt32(value.dropFirst(), radix: 16) != nil
    }
}

/// A compact tool rack, with the current stroke preview above it in the panel.
struct NotesBrushPicker: View {
    let selected: NotesBrushKind
    let select: (NotesBrushKind) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let columns = dynamicTypeSize.isAccessibilitySize ? 2 : 4
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
            ForEach(NotesBrushKind.allCases, id: \.self) { kind in
                Button { select(kind) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: kind.icon).font(.title3)
                            .frame(width: 32, height: 30)
                            .background(selected == kind ? Color.accentColor.opacity(0.14) : .clear, in: Circle())
                        Text(kind.title).font(.caption2.weight(selected == kind ? .semibold : .regular))
                    }
                    .foregroundStyle(selected == kind ? Color.accentColor : .primary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(kind.title)
                    .accessibilityAddTraits(selected == kind ? .isSelected : [])
                    .accessibilityIdentifier("notes.ink.brush.\(kind.rawValue)")
            }
        }
    }
}

/// The editor and qualification host use exactly the same parameter controls.
struct NotesInkOptionsPanel: View {
    let selected: NotesBrushKind
    let preferences: NotesInkPreferences
    let select: (NotesBrushKind) -> Void
    let close: () -> Void
    var doneIdentifier = "notes.ink.done"
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var config: NotesInkPreferences.Configuration { preferences.configuration(for: selected) }
    private var width: Binding<Double> {
        Binding(get: { config.width }, set: { preferences.setWidth($0, for: selected) })
    }
    private var transparency: Binding<Double> {
        Binding(get: { 1 - (config.opacity ?? 1) }, set: { preferences.setOpacity(1 - $0, for: selected) })
    }
    /// Five common widths around the brush's native default. The old
    /// hairline/standard/bold choices are preserved at 0.5x, 1x and 2x; the
    /// two additions sit between them. Every value is clamped to PencilKit's
    /// real legal range. Existing saved widths are read unchanged; only a dot
    /// or the slider writes a new value.
    static func widths(for kind: NotesBrushKind) -> [Double] {
        let range = kind.widthRange
        let nativeDefault = Double(kind.inkType.defaultWidth)
        let defaultWidth = min(range.upperBound, max(range.lowerBound, nativeDefault))
        let clamps: (Double) -> Double = { min(range.upperBound, max(range.lowerBound, ($0 * 100).rounded() / 100)) }
        let values = [0.5, 0.75, 1, 1.5, 2].map { clamps(defaultWidth * $0) }
        if Set(values.map { Int(($0 * 100).rounded()) }).count == 5 {
            return values
        }
        // Native defaults that sit at the thin end (pencil, monoline) collapse
        // the default-centered factors. Those brushes get five ordered values
        // across their real range instead; the slider still covers every width.
        guard range.lowerBound > 0, range.upperBound > range.lowerBound else { return values }
        let ratio = pow(range.upperBound / range.lowerBound, 1.0 / 4.0)
        return (0..<5).map { index in
            if index == 4 { return range.upperBound }
            return clamps(range.lowerBound * pow(ratio, Double(index)))
        }
    }
    static func formattedWidth(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
    private static let dotDiameters: [CGFloat] = [6, 10, 14, 18, 22]
    private static func widthPresetLabel(_ value: Double) -> String {
        FloeL10n.l("notes.notes_ink_preferences.points",
                   FloeL10n.l("notes.notes_ink_preferences.brush_thickness"),
                   formattedWidth(value))
    }
    private func isSelectedWidth(_ value: Double) -> Bool {
        abs(config.width - value) < 0.01
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(selected.title).font(.headline)
                Spacer(minLength: 8)
                Button("workspace.workspace_canvas_view.done", action: close)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier(doneIdentifier)
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // White paper keeps selected black and white inks truthful in dark mode.
                    NotesBrushSample(kind: selected, configuration: config)
                        .frame(maxWidth: .infinity)
                        .frame(height: NotesBrushSample.previewHeight(for: selected))
                        .background(Color(uiColor: .white), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("notes.notes_ink_preferences.brush_thickness")
                        .accessibilityValue("\(Self.formattedWidth(config.width)) pt · \(Int(((config.opacity ?? 1) * 100).rounded()))%")
                        .accessibilityIdentifier("notes.ink.preview")
                    NotesBrushPicker(selected: selected, select: select)
                    Divider()
                    widthControls
                    Divider()
                    transparencyControls
                    colorControls
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 12)
            }.accessibilityIdentifier("notes.ink.parameters")
        }
        .frame(width: 320)
        .frame(idealHeight: 500, maxHeight: 540)
    }

    private var widthControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("workspace.workspace_canvas_view.width").font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text("\(Self.formattedWidth(config.width)) pt")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("notes.ink.width.value")
            }
            HStack(spacing: 4) {
                ForEach(Array(Self.widths(for: selected).enumerated()), id: \.offset) { index, value in
                    widthPresetButton(index: index, value: value)
                }
            }
            Slider(value: width, in: selected.widthRange)
                .accessibilityLabel("notes.notes_ink_preferences.brush_thickness")
                .accessibilityValue("\(Self.formattedWidth(config.width)) pt")
                .accessibilityIdentifier("notes.ink.width.slider")
        }
    }

    private func widthPresetButton(index: Int, value: Double) -> some View {
        let chosen = isSelectedWidth(value)
        let diameter = Self.dotDiameters[index]
        return Button { width.wrappedValue = value } label: {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(chosen ? 0.12 : 0))
                    .frame(width: 38, height: 38)
                Circle()
                    .fill(Color(uiColor: Self.color(config.color)).opacity(config.opacity ?? 1))
                    .frame(width: diameter, height: diameter)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.16), lineWidth: 0.5))
                if chosen {
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: diameter + 10, height: diameter + 10)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.widthPresetLabel(value))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("notes.ink.width.preset.\(index)")
    }

    private var transparencyControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("notes.ink.transparency").font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    transparencyValue
                }
                transparencySlider
            } else {
                HStack(spacing: 8) {
                    Text("notes.ink.transparency").font(.subheadline.weight(.medium)).fixedSize()
                    transparencySlider
                    transparencyValue.frame(minWidth: 44, alignment: .trailing)
                }
                .frame(minHeight: 44)
            }
        }
    }
    private var transparencySlider: some View {
        Slider(value: transparency, in: 0...1)
            .accessibilityLabel("notes.ink.transparency")
            .accessibilityIdentifier("notes.ink.opacity.slider")
    }
    private var transparencyValue: some View {
        Text("\(Int(((1 - (config.opacity ?? 1)) * 100).rounded()))%")
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private var colorControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("notes.notes_ink_preferences.color").font(.subheadline.weight(.medium))
                Spacer()
                ColorPicker(FloeL10n.l("notes.notes_ink_preferences.custom_color"), selection: customColor, supportsOpacity: false).labelsHidden()
                    .accessibilityLabel("notes.notes_ink_preferences.custom_brush_color")
            }
            .frame(minHeight: 44)
            HStack(spacing: 0) {
                ForEach(["#18181B", "#2563EB", "#DC2626", "#16A34A", "#9333EA", "#FACC15"], id: \.self) { hex in
                    Button { preferences.setColor(hex, for: selected) } label: {
                        Circle().fill(Color(uiColor: Self.color(hex)))
                            .frame(width: 25, height: 25)
                            .overlay { if config.color == hex { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(hex == "#FACC15" ? .black : .white) } }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.plain).accessibilityLabel(FloeL10n.l("notes.notes_ink_preferences.color_2", hex))
                        .accessibilityIdentifier("notes.ink.color.\(hex.dropFirst())")
                }
            }
        }
    }
    private var customColor: Binding<Color> {
        Binding(get: { Color(uiColor: Self.color(config.color)) }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            if UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) {
                preferences.setColor(String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255)), for: selected)
            }
        })
    }
    static func color(_ hex: String) -> UIColor {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0x18181B
        return UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

@MainActor
struct NotesBrushSample: View {
    let kind: NotesBrushKind
    var configuration: NotesInkPreferences.Configuration? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var sample: UIImage?

    /// The visible preview paper is compact and identical for every brush.
    /// Strokes are authored with their real native width in a viewport measured
    /// from the widest legal sample, then the finished image is uniformly
    /// scaled into this paper. A brush keeps the same zoom while the user drags
    /// the slider; only the source width changes.
    static let paperWidth: CGFloat = 288
    static let paperHeight: CGFloat = 60
    static func previewHeight(for kind: NotesBrushKind) -> CGFloat { paperHeight }
    static func previewRect(for kind: NotesBrushKind) -> CGRect { layout(for: kind).rect }
    static func renderScale(for kind: NotesBrushKind) -> CGFloat { layout(for: kind).renderScale }

    private struct PreviewLayout {
        var rect: CGRect
        var nativeLength: CGFloat
        var rasterZoom: CGFloat
        var renderScale: CGFloat
    }
    private static var layouts: [NotesBrushKind: PreviewLayout] = [:]
    /// A short reference stroke only exists to measure the texture expansion of
    /// the thickest legal nib. The final path is lengthened or shortened so the
    /// viewport matches the paper's aspect ratio.
    private static let referenceLength: CGFloat = 100
    private static let paperPadding: CGFloat = 2
    /// PencilKit drops point widths below roughly 1.8 points from its raster
    /// output, even when the image scale is raised. Enlarging the sample
    /// uniformly to this width keeps a half-point monoline visible without
    /// clamping a thin setting to a fake minimum. Two points is also the
    /// canonical width at which monoline and its serialized pen alias render
    /// identical pixels.
    private static let minimumRasterWidth: CGFloat = 2.0
    private static let maximumRasterZoom: CGFloat = 6
    static func previewZoom(for kind: NotesBrushKind) -> CGFloat { layout(for: kind).rasterZoom }

    private static func layout(for kind: NotesBrushKind) -> PreviewLayout {
        if let cached = layouts[kind] { return cached }
        let minWidth = CGFloat(kind.widthRange.lowerBound)
        let maxWidth = CGFloat(kind.widthRange.upperBound)
        // The vector zoom and the viewport are both fixed per brush. Fitting
        // the enlarged viewport back into the 60-point paper cancels the zoom
        // visually, so the displayed proportions stay native and constant for
        // the same brush. Only the rasterization happens above the cutoff.
        let rasterZoom = min(maximumRasterZoom, max(1, minimumRasterWidth / max(0.01, minWidth)))
        let reference = stroke(kind: kind, color: .black, width: maxWidth,
                               length: referenceLength, zoom: rasterZoom)
        let referenceBounds = renderedBounds(of: reference)
        let scaledExpansion = max(0, referenceBounds.width - referenceLength * rasterZoom)
        let contentWidth = max(1, (paperWidth / paperHeight)
                                  * (referenceBounds.height + paperPadding * 2)
                                  - paperPadding * 2)
        let nativeLength = max(8, (contentWidth - scaledExpansion) / rasterZoom)
        // Include the minimum and every width dot in the fixed viewport as
        // well as the maximum so no legal selection can be cropped.
        var sampledWidths: [CGFloat] = [minWidth, maxWidth]
        sampledWidths.append(contentsOf: NotesInkOptionsPanel.widths(for: kind).map { CGFloat($0) })
        let fullBounds = sampledWidths.reduce(CGRect.null) { union, width in
            let drawing = stroke(kind: kind, color: .black, width: Double(width),
                                 length: nativeLength, zoom: rasterZoom)
            return renderedBounds(of: drawing).union(union)
        }
        let rect = (fullBounds.isNull || fullBounds.isEmpty
            ? CGRect(x: 0, y: 0, width: contentWidth, height: referenceBounds.height)
            : fullBounds).insetBy(dx: -paperPadding, dy: -paperPadding)
        let fit = min(paperWidth / max(1, rect.width), paperHeight / max(1, rect.height))
        let renderScale = min(6, max(2, (fit * 2).rounded(.up)))
        let layout = PreviewLayout(rect: rect, nativeLength: nativeLength,
                                   rasterZoom: rasterZoom, renderScale: renderScale)
        layouts[kind] = layout
        return layout
    }

    private static func renderedBounds(of drawing: PKDrawing) -> CGRect {
        drawing.strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
    }

    static func image(kind: NotesBrushKind, color: UIColor, width: Double? = nil) -> UIImage {
        let layout = layout(for: kind)
        return previewDrawing(kind: kind, color: color, width: width)
            .image(from: layout.rect, scale: layout.renderScale)
    }

    /// The native sample keeps the real requested width and the same path
    /// geometry for every width. Tests use it for width and serialization
    /// checks; the on-screen preview uses the uniformly enlarged copy below.
    static func drawing(kind: NotesBrushKind, color: UIColor, width requestedWidth: Double? = nil) -> PKDrawing {
        let layout = layout(for: kind)
        return stroke(kind: kind, color: color, width: requestedWidth,
                      length: layout.nativeLength)
    }

    /// Uniformly enlarged sample used only for rasterization. Its stroke widths
    /// and path are scaled by the same fixed factor, and the viewport stores the
    /// matching render bounds.
    static func previewDrawing(kind: NotesBrushKind, color: UIColor,
                               width requestedWidth: Double? = nil) -> PKDrawing {
        let layout = layout(for: kind)
        return stroke(kind: kind, color: color, width: requestedWidth,
                      length: layout.nativeLength, zoom: layout.rasterZoom)
    }

    /// Applies the same fixed raster zoom to an already serialized sample, so
    /// save/reopen rendering can be compared in the real preview viewport.
    static func previewDrawing(kind: NotesBrushKind, from drawing: PKDrawing) -> PKDrawing {
        let zoom = layout(for: kind).rasterZoom
        guard zoom != 1 else { return drawing }
        let strokes = drawing.strokes.map { stroke -> PKStroke in
            let points = stroke.path.map { point in
                PKStrokePoint(location: CGPoint(x: point.location.x * zoom,
                                                y: point.location.y * zoom),
                              timeOffset: point.timeOffset,
                              size: CGSize(width: point.size.width * zoom,
                                           height: point.size.height * zoom),
                              opacity: point.opacity, force: point.force,
                              azimuth: point.azimuth, altitude: point.altitude)
            }
            return PKStroke(ink: stroke.ink,
                            path: PKStrokePath(controlPoints: points,
                                               creationDate: Date(timeIntervalSince1970: 0)),
                            transform: stroke.transform, mask: stroke.mask,
                            randomSeed: stroke.randomSeed)
        }
        return PKDrawing(strokes: strokes)
    }

    private static func stroke(kind: NotesBrushKind, color: UIColor,
                               width requestedWidth: Double?, length: CGFloat,
                               zoom: CGFloat = 1) -> PKDrawing {
        let brushWidth = min(kind.widthRange.upperBound,
                             max(kind.widthRange.lowerBound,
                                 requestedWidth ?? Double(kind.inkType.defaultWidth)))
        let points = (0...40).map { index -> PKStrokePoint in
            let fraction = Double(index) / 40
            let pressureScale = kind == .monoline ? 1 : (0.6 + 0.4 * sin(fraction * .pi))
            let pointWidth = CGFloat(brushWidth * pressureScale) * zoom
            return PKStrokePoint(location: CGPoint(x: CGFloat(fraction) * max(8, length) * zoom,
                                                   y: CGFloat(2 * sin(fraction * .pi * 2)) * zoom),
                                 timeOffset: fraction,
                                 size: CGSize(width: pointWidth, height: pointWidth),
                                 opacity: 1, force: 0.7,
                                 azimuth: -.pi / 4, altitude: .pi / 3)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        // Ask the native writing tool for its stroke ink. Brush modes such as
        // monoline need not have a distinct serialized PKInk identifier.
        let ink = PKInkingTool(kind.inkType, color: color).ink
        return PKDrawing(strokes: [PKStroke(ink: ink, path: path)])
    }

    var body: some View {
        Group {
            if let sample { Image(uiImage: sample).resizable().scaledToFit() }
            else { Color.clear }
        }
        .accessibilityHidden(true)
        .task(id: "\(kind.rawValue)-\(String(describing: configuration))-\(colorScheme)") {
            let color = configuration.map { NotesInkOptionsPanel.color($0.color).withAlphaComponent($0.opacity ?? 1) }
                ?? (colorScheme == .dark ? UIColor.white : UIColor.black)
            sample = Self.image(kind: kind, color: color, width: configuration?.width)
        }
    }
}
#endif

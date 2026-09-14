// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import PencilKit
import Observation

enum NotesBrushKind: String, CaseIterable, Codable {
    case pen, fountainPen, monoline, pencil, crayon, watercolor, reed, marker

    var title: String {
        switch self {
        case .pen: "圆珠笔"
        case .fountainPen: "钢笔"
        case .monoline: "单线笔"
        case .pencil: "铅笔"
        case .crayon: "蜡笔"
        case .watercolor: "水彩"
        case .reed: "书法笔"
        case .marker: "荧光笔"
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
        return value.isFinite ? min(1, max(0.1, value)) : fallback
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

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
            ForEach(NotesBrushKind.allCases, id: \.self) { kind in
                Button { select(kind) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: kind.icon).font(.title3)
                            .frame(width: 32, height: 30)
                            .background(selected == kind ? Color.accentColor.opacity(0.14) : .clear, in: Circle())
                        Text(kind.title).font(.caption2.weight(selected == kind ? .semibold : .regular))
                    }
                    .foregroundStyle(selected == kind ? Color.accentColor : .primary)
                    .frame(maxWidth: .infinity, minHeight: 52)
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
    private var config: NotesInkPreferences.Configuration { preferences.configuration(for: selected) }
    private var width: Binding<Double> {
        Binding(get: { config.width }, set: { preferences.setWidth($0, for: selected) })
    }
    private var opacity: Binding<Double> {
        Binding(get: { config.opacity ?? 1 }, set: { preferences.setOpacity($0, for: selected) })
    }
    static func widths(for kind: NotesBrushKind) -> [Double] {
        let middle = Double(kind.inkType.defaultWidth)
        return [0.5, 1.0, 2.0].map { min(kind.widthRange.upperBound, max(kind.widthRange.lowerBound, middle * $0)) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(selected.title).font(.headline)
                Spacer()
                Button("完成", action: close).frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier(doneIdentifier)
            }.padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // White paper keeps selected black and white inks truthful in dark mode.
                    NotesBrushSample(kind: selected, configuration: config)
                        .frame(height: 50).frame(maxWidth: .infinity)
                        .background(Color(uiColor: .white), in: RoundedRectangle(cornerRadius: 8))
                    NotesBrushPicker(selected: selected, select: select)
                    Divider()
                    HStack {
                        Text("粗细").font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(config.width, specifier: "%.1f") pt").monospacedDigit().foregroundStyle(.secondary)
                            .accessibilityIdentifier("notes.ink.width.value")
                    }
                    HStack(spacing: 8) {
                        ForEach(Array(Self.widths(for: selected).enumerated()), id: \.offset) { index, value in
                            Button { width.wrappedValue = value } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(.primary).frame(width: min(16, max(2, value)), height: min(16, max(2, value)))
                                    Text(["细", "中", "粗"][index]).font(.caption)
                                }.frame(maxWidth: .infinity, minHeight: 44)
                                    .background(abs(config.width - value) < 0.01 ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: Capsule())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("\(["细", "中", "粗"][index])，\(value.formatted(.number.precision(.fractionLength(1)))) 点")
                                .accessibilityIdentifier("notes.ink.width.preset.\(index)")
                        }
                    }
                    Slider(value: width, in: selected.widthRange).accessibilityLabel("画笔粗细")
                        .accessibilityIdentifier("notes.ink.width.slider")
                    HStack {
                        Text("不透明度").font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(Int((config.opacity ?? 1) * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: opacity, in: 0.1...1).accessibilityLabel("画笔不透明度")
                        .accessibilityIdentifier("notes.ink.opacity.slider")
                    Divider()
                    HStack {
                        Text("颜色").font(.subheadline.weight(.medium))
                        Spacer()
                        ColorPicker("自定颜色", selection: customColor, supportsOpacity: false).labelsHidden()
                            .accessibilityLabel("自定画笔颜色")
                    }
                    HStack(spacing: 0) {
                        ForEach(["#18181B", "#2563EB", "#DC2626", "#16A34A", "#9333EA", "#FACC15"], id: \.self) { hex in
                            Button { preferences.setColor(hex, for: selected) } label: {
                                Circle().fill(Color(uiColor: Self.color(hex)))
                                    .frame(width: 25, height: 25)
                                    .overlay { if config.color == hex { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(hex == "#FACC15" ? .black : .white) } }
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.plain).accessibilityLabel("颜色 \(hex)")
                                .accessibilityIdentifier("notes.ink.color.\(hex.dropFirst())")
                        }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }.accessibilityIdentifier("notes.ink.parameters")
        }.frame(width: 320).frame(idealHeight: 540, maxHeight: 540)
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

struct NotesBrushSample: View {
    let kind: NotesBrushKind
    var configuration: NotesInkPreferences.Configuration? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var sample: UIImage?
    var body: some View {
        Group {
            if let sample { Image(uiImage: sample).resizable().scaledToFit() }
            else { Color.clear }
        }
        .accessibilityHidden(true)
        .task(id: "\(kind.rawValue)-\(String(describing: configuration))-\(colorScheme)") {
            let color = configuration.map { NotesInkOptionsPanel.color($0.color).withAlphaComponent($0.opacity ?? 1) }
                ?? (colorScheme == .dark ? UIColor.white : UIColor.black)
            sample = Self.drawing(kind: kind, color: color, width: configuration?.width)
                .image(from: CGRect(x: 0, y: 0, width: 110, height: 32).insetBy(dx: -(configuration?.width ?? 0) / 2, dy: -(configuration?.width ?? 0) / 2), scale: 2)
        }
    }
    static func drawing(kind: NotesBrushKind, color: UIColor, width requestedWidth: Double? = nil) -> PKDrawing {
        let points = (0...40).map { index in
            let fraction = Double(index) / 40
            let pressureScale = kind == .monoline ? 1 : (0.6 + 0.4 * sin(fraction * .pi))
            let width = (requestedWidth ?? min(12, max(2, kind.inkType.defaultWidth))) * pressureScale
            return PKStrokePoint(location: CGPoint(x: 8 + fraction * 94, y: 16 + 5 * sin(fraction * .pi * 2)),
                                 timeOffset: fraction, size: CGSize(width: width, height: width),
                                 opacity: 1, force: 0.7,
                                 azimuth: -.pi / 4, altitude: .pi / 3)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        // Ask the native writing tool for its stroke ink. Brush modes such as
        // monoline need not have a distinct serialized PKInk identifier.
        let ink = PKInkingTool(kind.inkType, color: color).ink
        return PKDrawing(strokes: [PKStroke(ink: ink, path: path)])
    }
}
#endif

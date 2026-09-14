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
    struct Configuration: Codable, Equatable {
        var color: String
        var width: Double
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
                                      stored.width.isFinite ? stored.width : fallback.width)))
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
    func inkingTool(for kind: NotesBrushKind) -> PKInkingTool {
        let value = configuration(for: kind)
        let rgb = UInt32(value.color.dropFirst(), radix: 16) ?? 0x18181B
        let color = UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                            green: CGFloat((rgb >> 8) & 255) / 255,
                            blue: CGFloat(rgb & 255) / 255, alpha: kind == .marker ? 0.45 : 1)
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

/// Native rendered samples show texture and stroke character, not just an icon.
struct NotesBrushPicker: View {
    let selected: NotesBrushKind
    let select: (NotesBrushKind) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(NotesBrushKind.allCases, id: \.self) { kind in
                Button { select(kind) } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(kind.title).font(.caption.weight(.medium))
                            Spacer(minLength: 2)
                            if selected == kind { Image(systemName: "checkmark").font(.caption2.bold()) }
                        }
                        NotesBrushSample(kind: kind).frame(height: 28)
                    }
                    .padding(.horizontal, 10).frame(height: 58)
                    .background(selected == kind ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
                    .accessibilityLabel(kind.title)
                    .accessibilityAddTraits(selected == kind ? .isSelected : [])
                    .accessibilityIdentifier("notes.ink.brush.\(kind.rawValue)")
            }
        }
    }
}

struct NotesBrushSample: View {
    let kind: NotesBrushKind
    @Environment(\.colorScheme) private var colorScheme
    @State private var sample: UIImage?
    var body: some View {
        Group {
            if let sample { Image(uiImage: sample).resizable().scaledToFit() }
            else { Color.clear }
        }
        .accessibilityHidden(true)
        .task(id: colorScheme) {
            sample = Self.drawing(kind: kind, color: colorScheme == .dark ? .white : .black)
                .image(from: CGRect(x: 0, y: 0, width: 110, height: 32), scale: 2)
        }
    }
    static func drawing(kind: NotesBrushKind, color: UIColor) -> PKDrawing {
        let points = (0...40).map { index in
            let fraction = Double(index) / 40
            let width = min(12, max(2, kind.inkType.defaultWidth)) * (0.6 + 0.4 * sin(fraction * .pi))
            return PKStrokePoint(location: CGPoint(x: 8 + fraction * 94, y: 16 + 5 * sin(fraction * .pi * 2)),
                                 timeOffset: fraction, size: CGSize(width: width, height: width),
                                 opacity: kind == .marker ? 0.45 : 1, force: 0.7,
                                 azimuth: -.pi / 4, altitude: .pi / 3)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        return PKDrawing(strokes: [PKStroke(ink: PKInk(kind.inkType, color: color), path: path)])
    }
}
#endif

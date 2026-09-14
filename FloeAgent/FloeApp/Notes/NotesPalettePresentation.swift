// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

extension View {
    func notesPencilPalette<Palette: View>(
        isPresented: Binding<Bool>, point: CGPoint,
        @ViewBuilder content: @escaping () -> Palette
    ) -> some View {
        // Keep the wheel in the page coordinate space. A system popover adds
        // rectangular chrome and can retain its modal host after rapid reuse.
        overlay {
            GeometryReader { geometry in
                if isPresented.wrappedValue {
                    let size = geometry.size
                    let extent: CGFloat = 232
                    let x = point.x.isFinite ? min(1, max(0, point.x)) : 0.5
                    let y = point.y.isFinite ? min(1, max(0, point.y)) : 0.15
                    let scale = min(1, min(size.width, size.height) / (extent + 16))
                    let half = extent * scale / 2 + 8
                    ZStack(alignment: .topLeading) {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { isPresented.wrappedValue = false }
                            .accessibilityHidden(true)
                        content()
                            .scaleEffect(scale)
                            .position(x: min(size.width - half, max(half, size.width * x)),
                                      y: min(size.height - half, max(half, size.height * y)))
                    }
                }
            }
        }
    }
}

// The label owns the hit region, not an outside layout-only frame. Keep
// identifiers on individual controls; a stack identifier masks its children.
struct NotesToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.35)
    }
}

enum NotesInkTool: String, CaseIterable {
    case pen = "笔", marker = "荧光笔", eraser = "橡皮", lasso = "套索", region = "AI 选区"
    var icon: String {
        switch self {
        case .pen: "pencil.tip"
        case .marker: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        case .region: "viewfinder"
        }
    }
}

/// Stored by stable keys so display-name changes do not reset the preference.
enum NotesPencilArcPlacement: String, CaseIterable {
    case above, upperLeft, upperRight

    static let preferenceKey = "notes.pencil.arcPlacement"
    var title: String {
        switch self {
        case .above: "正上方"
        case .upperLeft: "左上方"
        case .upperRight: "右上方"
        }
    }
    var startAngle: Double {
        switch self {
        case .above: -180
        case .upperLeft: -225
        case .upperRight: -135
        }
    }
}

/// Squeeze toggles a compact ring around the tip. Movement only previews;
/// an explicit tool tap commits the selection and returns to the page.
struct NotesPencilToolWheel: View {
    let tool: NotesInkTool
    let select: (NotesInkTool) -> Void
    let close: () -> Void
    @AppStorage(NotesPencilArcPlacement.preferenceKey) private var placement: NotesPencilArcPlacement = .above
    @State private var inkPreferences = NotesInkPreferences.shared
    @State private var preview: NotesInkTool?
    private let diameter: CGFloat = 220
    private let radius: CGFloat = 84

    var body: some View {
        ZStack {
            Path { path in
                path.addArc(center: CGPoint(x: diameter / 2, y: diameter / 2),
                            radius: radius, startAngle: .degrees(placement.startAngle), endAngle: .degrees(placement.startAngle + 180), clockwise: false)
            }.stroke(.regularMaterial, style: StrokeStyle(lineWidth: 50, lineCap: .round))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                .allowsHitTesting(false)
            ForEach(Array(NotesInkTool.allCases.enumerated()), id: \.element) { index, value in
                let angle = Double(index) * 45 + placement.startAngle
                toolButton(value)
                    .position(x: diameter / 2 + radius * cos(angle * .pi / 180),
                              y: diameter / 2 + radius * sin(angle * .pi / 180))
            }
            Button(action: close) {
                // The open center stays visually empty and behaves like other
                // blank page space; it remains a named close action for VoiceOver.
                Color.clear.frame(width: 44, height: 44)
            }.accessibilityLabel("关闭工具环，继续书写")
                .accessibilityIdentifier("notes.pencil.quickMenu.close")
            Text(preview == .pen ? inkPreferences.selectedPen.title : preview?.rawValue ?? "")
                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                .lineLimit(1).frame(width: 92)
                .position(x: diameter / 2 - 30 * cos((placement.startAngle + 90) * .pi / 180),
                          y: diameter / 2 - 30 * sin((placement.startAngle + 90) * .pi / 180))
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .highPriorityGesture(DragGesture(minimumDistance: 8)
            .onChanged { preview = toolNear($0.location) })
        .simultaneousGesture(SpatialTapGesture().onEnded { tap in
            let isTool = NotesInkTool.allCases.indices.contains { index in
                let angle = (Double(index) * 45 + placement.startAngle) * .pi / 180
                let center = CGPoint(x: diameter / 2 + radius * cos(angle),
                                     y: diameter / 2 + radius * sin(angle))
                return CGRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44).contains(tap.location)
            }
            if !isTool { close() }
        })
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): preview = toolNear(location)
            case .ended: preview = nil
            }
        }
        .onChange(of: placement) { _, _ in preview = nil }
        .padding(6)
        .buttonStyle(NotesToolbarButtonStyle())
    }

    private func toolButton(_ value: NotesInkTool) -> some View {
        let isSelected = tool == value
        let isPreviewed = preview == value
        let highlightOpacity: Double = isSelected ? 0.16 : (isPreviewed ? 0.08 : 0)
        let foreground: Color = isSelected || isPreviewed ? .accentColor : .primary
        let icon = value == .pen ? inkPreferences.selectedPen.icon : value.icon
        let title = value == .pen ? inkPreferences.selectedPen.title : value.rawValue
        return Button { select(value) } label: {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 44, height: 44)
                .background {
                    Circle()
                        .fill(Color.accentColor.opacity(highlightOpacity))
                        .padding(2)
                }
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier("notes.pencil.quickMenu.\(value.icon)")
        .accessibilityValue(isPreviewed ? "预览，轻触选择" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func toolNear(_ point: CGPoint) -> NotesInkTool? {
        let dx = point.x - diameter / 2, dy = point.y - diameter / 2
        let distance = hypot(dx, dy)
        let startAngle = placement.startAngle
        let middle = (startAngle + 90) * .pi / 180
        let towardArc = dx * cos(middle) + dy * sin(middle)
        guard distance.isFinite, distance >= 56, distance <= diameter / 2 + 24, towardArc >= -24 else { return nil }
        let nearest = NotesInkTool.allCases.enumerated().min { lhs, rhs in
            func squaredDistance(_ index: Int) -> CGFloat {
                let angle = (Double(index) * 45 + startAngle) * .pi / 180
                return pow(dx - radius * cos(angle), 2) + pow(dy - radius * sin(angle), 2)
            }
            return squaredDistance(lhs.offset) < squaredDistance(rhs.offset)
        }
        return nearest?.element
    }
}
#endif

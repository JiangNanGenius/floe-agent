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
                    let extent: CGFloat = 292
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

/// Squeeze opens a spatial tool selector; selecting a tool immediately returns
/// to the page. Ink customization stays in the persistent writing toolbar.
struct NotesPencilToolWheel: View {
    let tool: NotesInkTool
    let select: (NotesInkTool) -> Void
    let close: () -> Void
    private let diameter: CGFloat = 280
    private let radius: CGFloat = 92

    var body: some View {
        ZStack {
            Circle().fill(.regularMaterial).allowsHitTesting(false)
            Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1).allowsHitTesting(false)
            ForEach(Array(NotesInkTool.allCases.enumerated()), id: \.element) { index, value in
                let angle = Double(index) * 72 - 90
                NotesToolWheelSector(angle: angle)
                    .fill(tool == value ? Color.accentColor.opacity(0.14) : Color.clear)
                    .accessibilityHidden(true).allowsHitTesting(false)
                Button { select(value) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: value.icon).font(.system(size: 23, weight: .medium))
                        Text(value.rawValue).font(.caption2.weight(.medium))
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }.foregroundStyle(tool == value ? Color.accentColor : .primary)
                        .frame(width: 64, height: 64).contentShape(Circle())
                }
                .accessibilityLabel(value.rawValue)
                .accessibilityIdentifier("notes.pencil.quickMenu.\(value.icon)")
                .accessibilityAddTraits(tool == value ? .isSelected : [])
                .position(x: diameter / 2 + radius * cos(angle * .pi / 180),
                          y: diameter / 2 + radius * sin(angle * .pi / 180))
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, height: 64)
                    .background(Color.primary.opacity(0.05), in: Circle())
                    .contentShape(Circle())
            }.accessibilityLabel("取消，继续书写")
                .accessibilityIdentifier("notes.pencil.quickMenu.close")
        }
        .frame(width: diameter, height: diameter)
        .padding(6)
        .buttonStyle(NotesToolbarButtonStyle())
        .shadow(color: .black.opacity(0.16), radius: 14, y: 4)
    }
}

private struct NotesToolWheelSector: Shape {
    let angle: Double
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2 - 5
        let inner: CGFloat = 40
        let start = Angle.degrees(angle - 33)
        let end = Angle.degrees(angle + 33)
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.addLine(to: CGPoint(x: center.x + inner * cos(end.radians), y: center.y + inner * sin(end.radians)))
        path.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}
#endif

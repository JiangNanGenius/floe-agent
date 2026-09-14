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

/// Squeeze toggles a compact ring around the tip. Movement only previews;
/// an explicit tool tap commits the selection and returns to the page.
struct NotesPencilToolWheel: View {
    let tool: NotesInkTool
    let select: (NotesInkTool) -> Void
    let close: () -> Void
    @State private var preview: NotesInkTool?
    private let diameter: CGFloat = 220
    private let radius: CGFloat = 84

    var body: some View {
        ZStack {
            Circle().strokeBorder(.regularMaterial, lineWidth: 50)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                .allowsHitTesting(false)
            ForEach(Array(NotesInkTool.allCases.enumerated()), id: \.element) { index, value in
                let angle = Double(index) * 72 - 90
                Button { select(value) } label: {
                    Image(systemName: value.icon)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(tool == value || preview == value ? Color.accentColor : .primary)
                        .frame(width: 44, height: 44)
                        .background {
                            Circle().fill(Color.accentColor.opacity(tool == value ? 0.16 : preview == value ? 0.08 : 0))
                                .padding(2)
                        }
                }
                .accessibilityLabel(value.rawValue)
                .accessibilityIdentifier("notes.pencil.quickMenu.\(value.icon)")
                .accessibilityValue(preview == value ? "预览，轻触选择" : "")
                .accessibilityAddTraits(tool == value ? .isSelected : [])
                .position(x: diameter / 2 + radius * cos(angle * .pi / 180),
                          y: diameter / 2 + radius * sin(angle * .pi / 180))
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: 44, height: 44)
            }.accessibilityLabel("关闭工具环，继续书写")
                .accessibilityIdentifier("notes.pencil.quickMenu.close")
            Text(preview?.rawValue ?? "")
                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                .lineLimit(1).frame(width: 92)
                .position(x: diameter / 2, y: diameter / 2 + 30)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .highPriorityGesture(DragGesture(minimumDistance: 8)
            .onChanged { preview = toolNear($0.location) })
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): preview = toolNear(location)
            case .ended: preview = nil
            }
        }
        .padding(6)
        .buttonStyle(NotesToolbarButtonStyle())
    }

    private func toolNear(_ point: CGPoint) -> NotesInkTool? {
        let dx = point.x - diameter / 2, dy = point.y - diameter / 2
        let distance = hypot(dx, dy)
        guard distance.isFinite, distance >= 56, distance <= diameter / 2 + 24 else { return nil }
        let angle = (atan2(dy, dx) * 180 / .pi + 450).truncatingRemainder(dividingBy: 360)
        let index = Int((angle / 72).rounded()) % NotesInkTool.allCases.count
        return NotesInkTool.allCases[index]
    }
}
#endif

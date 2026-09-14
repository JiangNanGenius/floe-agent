// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

extension View {
    func notesPencilPalette<Palette: View>(
        isPresented: Binding<Bool>, point: CGPoint,
        @ViewBuilder content: @escaping () -> Palette
    ) -> some View {
        // Anchor directly to the visible canvas. A positioned 1-point overlay
        // expands its layout bounds and can put the popover above the window.
        popover(isPresented: isPresented,
                attachmentAnchor: .point(UnitPoint(
                    x: point.x.isFinite ? min(0.95, max(0.05, point.x)) : 0.5,
                    y: point.y.isFinite ? min(0.95, max(0.05, point.y)) : 0.15
                )), arrowEdge: nil) {
            content().presentationCompactAdaptation(.popover)
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

/// A small, stable-height palette at the Pencil tip. Detailed settings stay in
/// the main toolbar; all quick controls remain 44 points even on an iPhone.
struct NotesPencilQuickPalette: View {
    let tool: NotesInkTool
    @Binding var color: String
    @Binding var width: Double
    let canUndo: Bool
    let canRedo: Bool
    let select: (NotesInkTool) -> Void
    let undo: () -> Void
    let redo: () -> Void
    let close: () -> Void
    private let colors = ["#18181B", "#2563EB", "#DC2626", "#16A34A", "#9333EA", "#FACC15"]
    private let colorNames = ["黑色", "蓝色", "红色", "绿色", "紫色", "黄色"]
    private var widths: [Double] { tool == .marker ? [8, 20, 32] : [1, 3, 6] }
    private var usesInk: Bool { tool == .pen || tool == .marker }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(NotesInkTool.allCases, id: \.self) { value in
                    Button { select(value) } label: {
                        Image(systemName: value.icon).font(.title3)
                            .frame(width: 44, height: 44)
                            .background(tool == value ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }.accessibilityLabel(value.rawValue)
                        .accessibilityIdentifier("notes.pencil.quickMenu.\(value.icon)")
                        .accessibilityAddTraits(tool == value ? .isSelected : [])
                }
                Button(action: close) { Image(systemName: "xmark").font(.callout).frame(width: 44, height: 44) }
                    .accessibilityLabel("继续书写").accessibilityIdentifier("notes.pencil.quickMenu.close")
            }
            Divider()
            HStack(spacing: 2) {
                ForEach(Array(colors.enumerated()), id: \.element) { index, hex in
                    Button { color = hex } label: {
                        Circle().fill(swatch(hex)).frame(width: 25, height: 25)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                            .overlay {
                                if color.uppercased() == hex {
                                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(index == 5 ? .black : .white)
                                }
                            }.frame(width: 44, height: 44)
                    }.accessibilityLabel(colorNames[index])
                        .accessibilityIdentifier("notes.pencil.quickMenu.color.\(index)")
                        .accessibilityAddTraits(color.uppercased() == hex ? .isSelected : [])
                }
            }.disabled(!usesInk)
            HStack(spacing: 2) {
                ForEach(widths, id: \.self) { value in
                    Button { width = value } label: {
                        Capsule().fill(.primary).frame(width: 22, height: min(9, max(2, value / (tool == .marker ? 4 : 1))))
                            .frame(width: 44, height: 44)
                            .background(abs(width - value) < 0.25 ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }.accessibilityLabel("粗细 \(value.formatted())")
                        .accessibilityIdentifier("notes.pencil.quickMenu.width.\(Int(value))")
                        .accessibilityAddTraits(abs(width - value) < 0.25 ? .isSelected : [])
                        .disabled(!usesInk)
                }
                Spacer(minLength: 0)
                Button(action: undo) { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }
                    .accessibilityLabel("撤销").disabled(!canUndo)
                Button(action: redo) { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44) }
                    .accessibilityLabel("重做").disabled(!canRedo)
            }
        }.padding(10).frame(width: 294)
            .buttonStyle(NotesToolbarButtonStyle())
    }

    private func swatch(_ hex: String) -> Color {
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return Color(red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}
#endif

// FloeApp — Persistent IDE activity bar (VS Code-style left rail).
//
// SPDX-License-Identifier: MPL-2.0
//
// A narrow, always-present rail on regular widths that switches the
// collapsible sidebar between files, search and source control, and toggles
// the bottom panel. Source control is reached from here (never from the
// top toolbar), so the editor stays one tap away from the real pinned
// workspace's Git surface.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

struct IDEActivityBar: View {
    @Binding var mode: IDESidebarMode?
    @Binding var panelVisible: Bool
    var disabled: Bool = false

    private func isActive(_ candidate: IDESidebarMode) -> Bool { mode == candidate }

    var body: some View {
        VStack(spacing: 4) {
            railButton(
                icon: IDESidebarMode.files.systemImage,
                label: IDESidebarMode.files.title,
                identifier: "workspace.ide.files",
                active: isActive(.files)
            ) {
                toggle(.files)
            }
            railButton(
                icon: IDESidebarMode.search.systemImage,
                label: IDESidebarMode.search.title,
                identifier: "workspace.ide.search",
                active: isActive(.search)
            ) {
                toggle(.search)
            }
            railButton(
                icon: IDESidebarMode.sourceControl.systemImage,
                label: IDESidebarMode.sourceControl.title,
                identifier: "workspace.ide.sourceControl",
                active: isActive(.sourceControl)
            ) {
                toggle(.sourceControl)
            }
            Spacer(minLength: 0)
            railButton(
                icon: "terminal",
                label: IDELanguageRunText.t("终端", "Terminal"),
                identifier: "workspace.ide.terminal",
                active: panelVisible
            ) {
                panelVisible.toggle()
            }
        }
        .padding(.vertical, 8)
        .frame(width: 52)
        .background(FloeTheme.sidebarSurface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
        }
        // Keep each icon an independent accessibility element: a container
        // identifier alone can make XCTest collapse the rail into one node,
        // hiding `workspace.ide.terminal` (the glyph is visible but not a
        // queryable button).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.ide.activityBar")
    }

    private func toggle(_ candidate: IDESidebarMode) {
        withAnimation(.snappy(duration: 0.18)) {
            mode = (mode == candidate) ? nil : candidate
        }
    }

    @ViewBuilder
    private func railButton(
        icon: String,
        label: String,
        identifier: String,
        active: Bool,
        badge: Int? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .frame(width: 30, height: 24)
                Text(label)
                    .font(.system(size: 9.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(active ? FloeTheme.primary : Color.secondary)
            .frame(width: 48, height: FloeTheme.minimumTarget)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? FloeTheme.primary.opacity(0.14) : Color.clear)
            )
            .overlay(alignment: .topTrailing) {
                if let badge, badge > 0 {
                    Text("\(min(badge, 99))")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 4)
                        .frame(minHeight: 14)
                        .background(Capsule().fill(FloeTheme.primary))
                        .foregroundStyle(.white)
                        .padding(.top, 2).padding(.trailing, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
        .accessibilityValue(active ? IDELanguageRunText.t("已选中", "Selected") : "")
        .accessibilityIdentifier(identifier)
    }
}
#endif

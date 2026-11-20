// SPDX-License-Identifier: MPL-2.0

import SwiftUI

struct FloeWorkbenchProjectRow<Content: View, AddControl: View>: View {
    let workspaceID: UUID
    let name: String
    @Binding var isExpanded: Bool
    let openWorkspace: () -> Void
    #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
    var onOpenFrame: ((CGRect) -> Void)? = nil
    var onDisclosureFrame: ((CGRect) -> Void)? = nil
    #endif
    @ViewBuilder var addControl: () -> AddControl
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Button { isExpanded.toggle() } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(disclosureTitle)
                .help(disclosureTitle)
                .accessibilityIdentifier("sidebar.workspace.disclosure.\(workspaceID.uuidString)")
                #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { frame in onDisclosureFrame?(frame) })
                #endif
                Button(action: openWorkspace) {
                    Label { Text(verbatim: name).lineLimit(1) } icon: { Image(systemName: "folder") }
                        .font(.body)
                        .frame(minWidth: FloeTheme.minimumTarget, maxWidth: .infinity, minHeight: FloeTheme.minimumTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(name)
                .accessibilityIdentifier("sidebar.workspace.open.\(workspaceID.uuidString)")
                #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { frame in onOpenFrame?(frame) })
                #endif
                addControl()
            }
            .onKeyPress(.leftArrow) {
                guard isExpanded else { return .ignored }
                isExpanded = false
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard !isExpanded else { return .ignored }
                isExpanded = true
                return .handled
            }
            if isExpanded {
                content().padding(.leading, 16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.workspace.\(workspaceID.uuidString)")
        #else
        DisclosureGroup(isExpanded: $isExpanded, content: content) {
            HStack(spacing: 8) {
                Button(action: openWorkspace) {
                    Label(name, systemImage: "folder")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.workspace.open.\(workspaceID.uuidString)")
                Spacer(minLength: 4)
                addControl()
            }
        }
        .accessibilityIdentifier("sidebar.workspace.\(workspaceID.uuidString)")
        #endif
    }

    #if os(macOS)
    private var disclosureTitle: String {
        if Locale.preferredLanguages.first?.hasPrefix("zh") == true {
            return isExpanded ? "收起\(name)" : "展开\(name)"
        }
        return isExpanded ? "Collapse \(name)" : "Expand \(name)"
    }
    #endif
}

// SPDX-License-Identifier: MPL-2.0

import SwiftUI

struct FloeWorkbenchProjectRow<Content: View, AddControl: View>: View {
    let workspaceID: UUID
    let name: String
    @Binding var isExpanded: Bool
    let openWorkspace: () -> Void
    #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
    var onOpenFrame: ((CGRect) -> Void)? = nil
    #endif
    @ViewBuilder var addControl: () -> AddControl
    @ViewBuilder var content: () -> Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded, content: content) {
            HStack(spacing: 8) {
                Button(action: openWorkspace) {
                    Label(name, systemImage: "folder")
                        #if os(macOS)
                        .lineLimit(1)
                        .help(name)
                        #endif
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.workspace.open.\(workspaceID.uuidString)")
                #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { frame in onOpenFrame?(frame) })
                #endif
                Spacer(minLength: 4)
                addControl()
            }
        }
        .accessibilityIdentifier("sidebar.workspace.\(workspaceID.uuidString)")
    }
}

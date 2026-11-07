// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCAD

/// One host bridge serves the inline Building page in Space, task previews
/// and full-screen CAD. It presents the existing native services for the
/// exact live document, without creating a replacement editor or task.
@MainActor
struct CADBuildingProfessionalEntry: ViewModifier {
    let document: FloeCADDocument
    var root: URL? = nil
    var workspaceID: UUID? = nil
    var conversationID: UUID? = nil
    var onCoverChange: ((Bool) -> Void)? = nil
    @Environment(\.cadWorkbenchTransientlyCovered) private var alreadyCovered
    @State private var selection: CADBuildingProfessionalAction?

    func body(content: Content) -> some View {
        content
            .environment(\.cadBuildingProfessionalPresenter, CADBuildingProfessionalPresenter(retainNavigation: { incoming in
                guard incoming === document, !document.isClosed else { return nil }
                let lease = CADFilePresentationLease()
                lease.attach(incoming)
                return lease
            }, navigationHost: { incoming, page in
                guard incoming === document, !document.isClosed else { return page }
                // The pushed page owns its professional sheet. The original
                // CAD leaf may be retained but hidden by this destination.
                return AnyView(page.modifier(CADBuildingProfessionalEntry(document: document, root: root,
                    workspaceID: workspaceID, conversationID: conversationID)))
            }) { incoming, action in
                guard incoming === document, !document.isClosed else { return }
                onCoverChange?(true)
                selection = action
            })
            .environment(\.cadWorkbenchTransientlyCovered, alreadyCovered || selection != nil)
            .sheet(item: $selection, onDismiss: { onCoverChange?(false) }) { action in
                CADBuildingProfessionalView(document: document, action: action, root: root,
                                            workspaceID: workspaceID, conversationID: conversationID)
            }
            .onChange(of: ObjectIdentifier(document)) { _, _ in selection = nil; onCoverChange?(false) }
    }
}
#endif

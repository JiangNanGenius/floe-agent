// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCAD

/// Architecture owns its tools while reusing the live native CAD session.
/// A professional job outlives this cover through the existing jobs service.
struct CADBuildingWorkspaceView:View {
    let document:FloeCADDocument
    var incomingPlan:CADSketchTransferEnvelope? = nil
    var root:URL? = nil
    var workspaceID:UUID? = nil
    var conversationID:UUID? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var professional:CADBuildingProfessionalAction?
    @State private var saving=false
    @State private var error:String?
    var body:some View {
        NavigationStack {
            FloeBuildingWorkbenchView(document:document,incomingPlan:incomingPlan) { professional=$0 }
                .modifier(CADOfflineRenderEntry(document:document,root:root,workspaceID:workspaceID,conversationID:conversationID))
                .navigationTitle(FloeCADStrings.text("cad.building.title","Building Design"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.topBarLeading) {
                        Button(FloeCADStrings.text("cad.building.done","Done")) { save(close:true) }
                            .disabled(saving).accessibilityIdentifier("building.close")
                    }
                    ToolbarItem(placement:.topBarTrailing) {
                        Button { save(close:false) } label:{ Label(FloeCADStrings.text("cad.host.save","Save"),systemImage:"tray.and.arrow.down") }
                            .disabled(saving).accessibilityIdentifier("building.save")
                    }
                }
        }
        .sheet(item:$professional) { action in
            CADBuildingProfessionalView(document:document,action:action,root:root,workspaceID:workspaceID,conversationID:conversationID)
        }
        .alert(FloeCADStrings.text("cad.building.saveFailed","The building could not be saved"),isPresented:Binding(get:{error != nil},set:{if !$0 {error=nil}})) {
            Button(FloeCADStrings.text("cad.building.done","Done")) { error=nil }
        } message:{ Text(error ?? "") }
        .interactiveDismissDisabled(saving)
    }
    private func save(close:Bool) {
        guard !saving else { return };saving=true
        Task { @MainActor in
            let outcome=await document.save();saving=false
            if let failure=outcome.error { error=failure }
            else if close { dismiss() }
        }
    }
}
#endif

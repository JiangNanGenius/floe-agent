// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCAD

/// Architecture owns its tools while reusing the live native CAD session.
/// A professional job outlives this cover through the existing jobs service.
/// This view is the single Save owner for the embedded native editor: its
/// background flush and Close/Save buttons replace the editor's partial
/// project save, so the same document is never committed by two owners.
struct CADBuildingWorkspaceView:View {
    let document:FloeCADDocument
    var incomingPlan:CADSketchTransferEnvelope? = nil
    var root:URL? = nil
    var workspaceID:UUID? = nil
    var conversationID:UUID? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var professional:CADBuildingProfessionalAction?
    @State private var saving=false
    @State private var error:String?
    var body:some View {
        NavigationStack {
            FloeBuildingWorkbenchView(document:document,incomingPlan:incomingPlan,hostOwnsProjectSave:true) { professional=$0 }
                .modifier(CADOfflineRenderEntry(document:document,root:root,workspaceID:workspaceID,conversationID:conversationID))
                .modifier(CADBuildingProjectEntry(document:document,root:root,blocked:saving))
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
        .onChange(of:scenePhase) { _, phase in
            // The embedded editor no longer flushes on its own when this host
            // owns the project save. Preserve the previous data safety here.
            guard phase != .active,!saving,!document.isClosed,document.hasUnsavedChanges else { return }
            Task { _ = await document.save() }
        }
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

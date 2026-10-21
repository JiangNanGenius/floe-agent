// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation

/// Navigation identity only. Editor state, content and undo remain in Notes.
struct DocumentIntakeRouteSnapshot: Equatable {
    var selection: AppDestination
    var sidebar: SidebarSelection?
    var workbench: WorkbenchSelection
    var morePath: [MoreDestination]
    var settingsPresented: Bool
    var canvasID: UUID?
    var canvasPresented: Bool

    init(selection: AppDestination = .home, sidebar: SidebarSelection? = nil,
         workbench: WorkbenchSelection = .newTask(workspaceID: nil),
         morePath: [MoreDestination] = [], settingsPresented: Bool = false,
         canvasID: UUID? = nil, canvasPresented: Bool = false) {
        self.selection = selection
        self.sidebar = sidebar
        self.workbench = workbench
        self.morePath = morePath
        self.settingsPresented = settingsPresented
        self.canvasID = canvasID
        self.canvasPresented = canvasPresented
    }

    @MainActor
    init(router: AppRouter) {
        selection = router.selection
        sidebar = router.sidebarSelection
        workbench = router.workbenchSelection
        morePath = router.morePath
        settingsPresented = router.presentedSettings
        canvasID = router.presentedCanvasID
        canvasPresented = router.presentsCanvas
    }

    var isNotes: Bool {
        sidebar == .more(.notes) || (selection == .more && morePath.last == .notes)
    }
}

/// Bounded, scene-bound eligibility for an automatic import completion.
/// Missing/cold/retired origins require an explicit Open instead of guessing.
@MainActor
final class DocumentIntakeRoutingRegistry {
    static let shared = DocumentIntakeRoutingRegistry()
    private struct Scene {
        var active = false
        var noteID: UUID?
        var knowsNoteSelection = false
    }
    private struct Origin {
        let sceneID: String
        let route: DocumentIntakeRouteSnapshot
        let noteID: UUID?
        let knowsNoteSelection: Bool
    }
    private var scenes: [String: Scene] = [:]
    private var origins: [UUID: Origin] = [:]
    private var order: [UUID] = []

    func setActive(_ active: Bool, sceneID: String) {
        guard scenes[sceneID] != nil || scenes.count < 32 else { return }
        var scene = scenes[sceneID] ?? Scene()
        scene.active = active
        scenes[sceneID] = scene
    }

    func noteSelectionChanged(_ documentID: UUID?, sceneID: String) {
        guard scenes[sceneID] != nil || scenes.count < 32 else { return }
        var scene = scenes[sceneID] ?? Scene()
        scene.noteID = documentID
        scene.knowsNoteSelection = true
        scenes[sceneID] = scene
    }

    func removeScene(_ sceneID: String) { scenes.removeValue(forKey: sceneID) }

    func capture(_ route: DocumentIntakeRouteSnapshot, sceneID: String, eventID: UUID) {
        order.removeAll { $0 == eventID }
        if origins[eventID] == nil, origins.count >= 64, let oldest = order.first {
            origins.removeValue(forKey: oldest)
            order.removeFirst()
        }
        let scene = scenes[sceneID]
        origins[eventID] = Origin(sceneID: sceneID, route: route,
                                  noteID: scene?.noteID,
                                  knowsNoteSelection: scene?.knowsNoteSelection == true)
        order.append(eventID)
    }

    func canPresent(_ presentation: DocumentIntakePresentation,
                    currentRoute: DocumentIntakeRouteSnapshot) -> Bool {
        guard let origin = origins[presentation.id],
              presentation.sceneID == origin.sceneID else { return false }
        origins.removeValue(forKey: presentation.id)
        order.removeAll { $0 == presentation.id }
        guard let scene = scenes[origin.sceneID], scene.active,
              origin.route == currentRoute else { return false }
        if origin.route.isNotes {
            return origin.knowsNoteSelection && scene.knowsNoteSelection && origin.noteID == scene.noteID
        }
        return true
    }
}
#endif

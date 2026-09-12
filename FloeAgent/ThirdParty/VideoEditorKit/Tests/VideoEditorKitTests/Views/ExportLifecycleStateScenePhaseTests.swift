import SwiftUI
import Testing

@testable import VideoEditorKit

@Suite("ExportLifecycleStateScenePhaseTests")
struct ExportLifecycleStateScenePhaseTests {

    // MARK: - Public Methods

    @Test
    func scenePhaseMapsToExportLifecycleState() {
        #expect(ExportLifecycleState(scenePhase: .active) == .active)
        #expect(ExportLifecycleState(scenePhase: .inactive) == .inactive)
        #expect(ExportLifecycleState(scenePhase: .background) == .background)
    }

}

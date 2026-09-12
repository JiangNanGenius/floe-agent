import Testing

@testable import VideoEditorKit

@Suite("EditorPresentationStateTests")
struct EditorPresentationStateTests {

    // MARK: - Public Methods

    @Test
    @MainActor
    func markEditingConfigurationChangedAdvancesTheRevision() {
        let state = EditorPresentationState()

        #expect(state.editingConfigurationRevision == 0)

        state.markEditingConfigurationChanged()

        #expect(state.editingConfigurationRevision == 1)
    }

}

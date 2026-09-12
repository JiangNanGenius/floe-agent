import Testing

@testable import VideoEditorKit

@Suite("EditorToolSelectionCoordinatorTests")
struct EditorToolSelectionCoordinatorTests {

    // MARK: - Public Methods

    @Test
    func enabledToolsOnlyKeepsTheAvailableEntries() {
        let enabledTools = EditorToolSelectionCoordinator.enabledTools(
            from: [
                .init(.adjusts),
                .init(.speed, access: .blocked),
                .init(.audio),
            ]
        )

        #expect(enabledTools == Set([.adjusts, .audio]))
    }

    @Test
    func resolvedSelectionClearsUnavailableTools() {
        let selection = EditorToolSelectionCoordinator.resolvedSelection(
            currentSelection: .speed,
            enabledTools: Set([.adjusts, .audio])
        )

        #expect(selection == nil)
    }

    @Test
    func selectToolRejectsUnavailableEntries() {
        let selectedTool = EditorToolSelectionCoordinator.selectTool(
            .speed,
            enabledTools: Set([.adjusts, .audio])
        )

        #expect(selectedTool == nil)
        #expect(EditorToolSelectionCoordinator.closeSelectedTool() == nil)
    }

}

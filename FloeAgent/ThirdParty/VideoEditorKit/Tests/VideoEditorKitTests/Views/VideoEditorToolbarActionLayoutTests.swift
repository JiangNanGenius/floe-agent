import Testing

@testable import VideoEditorKit

@Suite("VideoEditorToolbarActionLayoutTests")
struct VideoEditorToolbarActionLayoutTests {

    // MARK: - Public Methods

    @Test
    func saveAppearsAfterExportWithANativeToolbarSeparator() {
        #expect(VideoEditorToolbarActionLayout.savePlacement == .primaryAction)
        #expect(VideoEditorToolbarActionLayout.exportPlacement == .primaryAction)
        #expect(VideoEditorToolbarActionLayout.separatorPlacement == .primaryAction)
        #expect(VideoEditorToolbarActionLayout.usesNativeActionSeparator)
        #expect(VideoEditorToolbarActionLayout.usesSystemSaveButtonStyle)
        #expect(VideoEditorToolbarActionLayout.saveButtonStyle == .borderedProminent)
        #expect(VideoEditorToolbarActionLayout.exportButtonStyle == .plainToolbarItem)
    }

}

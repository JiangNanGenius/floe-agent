import Testing

@testable import VideoEditorKit

@Suite("VideoEditorToolSheetPresentationPolicyTests")
struct ToolSheetPolicyTests {

    // MARK: - Public Methods

    @Test
    func transcriptToolUsesTheTallestInitialSheetHeight() {
        #expect(VideoEditorToolSheetPresentationPolicy.initialSheetHeight(for: .transcript) == 520)
        #expect(VideoEditorToolSheetPresentationPolicy.initialSheetHeight(for: .audio) == 300)
    }

    @Test
    func onlyTranscriptStillRequiresAnExplicitApplyAction() {
        #expect(!VideoEditorToolSheetPresentationPolicy.requiresExplicitApply(.cut))
        #expect(!VideoEditorToolSheetPresentationPolicy.requiresExplicitApply(.adjusts))
        #expect(!VideoEditorToolSheetPresentationPolicy.requiresExplicitApply(.audio))
        #expect(!VideoEditorToolSheetPresentationPolicy.requiresExplicitApply(.presets))
        #expect(!VideoEditorToolSheetPresentationPolicy.requiresExplicitApply(.speed))
        #expect(VideoEditorToolSheetPresentationPolicy.requiresExplicitApply(.transcript))
    }

}

import Foundation
import Testing

@testable import VideoEditorKit

@MainActor
@Suite("VideoEditorShellViewTests")
struct VideoEditorShellViewTests {

    // MARK: - Public Methods

    @Test
    func navigationTitleIsHiddenUntilTheEditorContentIsLoaded() {
        let url = URL(fileURLWithPath: "/tmp/video.mp4")

        #expect(
            VideoEditorShellView.navigationTitle(
                "Editor",
                bootstrapState: .idle
            ).isEmpty
        )
        #expect(
            VideoEditorShellView.navigationTitle(
                "Editor",
                bootstrapState: .loading
            ).isEmpty
        )
        #expect(
            VideoEditorShellView.navigationTitle(
                "Editor",
                bootstrapState: .loaded(url)
            ) == "Editor"
        )
    }

}

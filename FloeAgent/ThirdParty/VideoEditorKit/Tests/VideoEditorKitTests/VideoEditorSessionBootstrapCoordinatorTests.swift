import Foundation
import Testing

@testable import VideoEditorKit

@Suite("VideoEditorSessionBootstrapCoordinatorTests")
struct EditorSessionBootstrapTests {

    // MARK: - Public Methods

    @Test
    func initialStateIsIdleWhenThereIsNoSource() {
        let state = VideoEditorSessionBootstrapCoordinator.initialState(
            for: nil
        )

        #expect(state == .idle)
    }

    @Test
    func initialStateIsLoadedForFileURLSources() {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mp4")

        let state = VideoEditorSessionBootstrapCoordinator.initialState(
            for: .fileURL(sourceURL)
        )

        #expect(state == .loaded(sourceURL))
    }

    @Test
    func initialStateIsLoadingForImportedSources() {
        let state = VideoEditorSessionBootstrapCoordinator.initialState(
            for: .importedFile(
                .init(taskIdentifier: "picker:test") {
                    URL(fileURLWithPath: "/tmp/source.mp4")
                }
            )
        )

        #expect(state == .loading)
    }

    @Test
    func resolveStateReturnsLoadedWhenTheImportedSourceResolves() async {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mp4")

        let state = await VideoEditorSessionBootstrapCoordinator.resolveState(
            for: .importedFile(
                .init(taskIdentifier: "picker:test") {
                    sourceURL
                }
            )
        )

        #expect(state == .loaded(sourceURL))
    }

    @Test
    func resolveStateReturnsFailureWhenTheImportedSourceThrows() async {
        struct ImportFailure: LocalizedError {

            var errorDescription: String? {
                "Import failed."
            }

        }

        let state = await VideoEditorSessionBootstrapCoordinator.resolveState(
            for: .importedFile(
                .init(taskIdentifier: "picker:test") {
                    throw ImportFailure()
                }
            )
        )

        #expect(state == .failed("Import failed."))
    }

}

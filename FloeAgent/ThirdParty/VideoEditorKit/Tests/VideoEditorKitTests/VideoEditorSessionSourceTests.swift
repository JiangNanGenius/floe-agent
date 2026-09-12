import Foundation
import Testing

@testable import VideoEditorKit

@Suite("VideoEditorSessionSourceTests")
struct VideoEditorSessionSourceTests {

    // MARK: - Public Methods

    @Test
    func fileURLSourceExposesTheResolvedFileURLAndStableIdentifier() {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mp4")
        let source = VideoEditorSessionSource.fileURL(sourceURL)

        #expect(source.fileURL == sourceURL)
        #expect(source.taskIdentifier == "file:\(sourceURL.absoluteString)")
    }

    @Test
    func importedFileSourceUsesItsOwnTaskIdentifierForEqualityAndBootstrapTracking() {
        let lhs = VideoEditorImportedFileSource(
            taskIdentifier: "picker:test"
        ) {
            URL(fileURLWithPath: "/tmp/first.mp4")
        }
        let rhs = VideoEditorImportedFileSource(
            taskIdentifier: "picker:test"
        ) {
            URL(fileURLWithPath: "/tmp/second.mp4")
        }
        let source = VideoEditorSessionSource.importedFile(lhs)

        #expect(lhs == rhs)
        #expect(source.fileURL == nil)
        #expect(source.taskIdentifier == "imported:picker:test")
    }

}

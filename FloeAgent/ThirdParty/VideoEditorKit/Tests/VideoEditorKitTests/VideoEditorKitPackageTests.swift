import Testing

@testable import VideoEditorKit

@Suite("VideoEditorKit Package")
struct VideoEditorKitPackageTests {

    @Test("Package scaffold exposes the expected package name")
    func packageName() {
        #expect(
            VideoEditorKitPackage.packageName == "VideoEditorKit"
        )
    }

}

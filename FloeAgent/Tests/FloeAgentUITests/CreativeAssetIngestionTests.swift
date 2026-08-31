#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("FloeApp.CreativeAssetIngestion")
struct CreativeAssetIngestionTests {
    @Test("Remote reference import rejects local and private destinations")
    func rejectsPrivateDestinations() {
        #expect(!CreativeAssetIngestionService.isSafePublicHTTPSURL(
            URL(string: "http://example.com/image.png")!
        ))
        #expect(!CreativeAssetIngestionService.isSafePublicHTTPSURL(
            URL(string: "https://localhost/image.png")!
        ))
        #expect(!CreativeAssetIngestionService.isSafePublicHTTPSURL(
            URL(string: "https://127.0.0.1/image.png")!
        ))
        #expect(!CreativeAssetIngestionService.isSafePublicHTTPSURL(
            URL(string: "https://192.168.1.2/image.png")!
        ))
        #expect(!CreativeAssetIngestionService.isSafePublicHTTPSURL(
            URL(string: "https://user:secret@example.com/image.png")!
        ))
    }

    @Test("Reference import failures are actionable")
    func errorsAreLocalized() {
        #expect(CreativeAssetIngestionError.missingLocalFile.localizedDescription
            .contains("重新导入"))
        #expect(CreativeAssetIngestionError.payloadTooLarge.localizedDescription
            .contains("20 MiB"))
    }
}
#endif

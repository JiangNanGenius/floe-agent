// FloeAppTests — Canvas media-generation image batch contract.
//
// Pure decisions only: exact commit cardinality, partial-success preservation
// and the honest terminal error for a paid batch that produced fewer than its
// reserved result slots.

#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders
@testable import FloeApp

@Suite("FloeApp.MediaGenerationImageBatchContract")
struct MediaGenerationImageBatchContractTests {
    private func images(_ count: Int) -> [Data] {
        (0..<count).map { Data([UInt8($0)]) }
    }

    @Test("Full Canvas commit still requires the exact reserved count")
    func exactCommitCardinality() throws {
        let four = images(4)
        #expect(try MediaGenerationImageBatchContract.validatedImages(
            four, requestedOutputCount: 4) == four)
        #expect(throws: FloeError.self) {
            _ = try MediaGenerationImageBatchContract.validatedImages(
                Array(four.prefix(3)), requestedOutputCount: 4)
        }
        #expect(throws: FloeError.self) {
            _ = try MediaGenerationImageBatchContract.validatedImages(
                four + [Data([0xFF])], requestedOutputCount: 4)
        }
    }

    @Test("Partial success keeps every produced image but not extra bytes")
    func partialValidation() throws {
        let two = images(2)
        #expect(try MediaGenerationImageBatchContract.validatedPartialImages(
            two, requestedOutputCount: 4) == two)
        #expect(try MediaGenerationImageBatchContract.validatedPartialImages(
            [], requestedOutputCount: 4) == [])
        #expect(throws: FloeError.self) {
            _ = try MediaGenerationImageBatchContract.validatedPartialImages(
                images(5), requestedOutputCount: 4)
        }
        #expect(throws: FloeError.self) {
            _ = try MediaGenerationImageBatchContract.validatedPartialImages(
                [Data(count: MediaGenerationImageBatchContract.maximumImageBytes + 1)],
                requestedOutputCount: 4)
        }
    }


    @Test("Canvas asset paths use the sniffed extension, not a false jpg")
    func generatedAssetPathUsesRealExtension() {
        let id = UUID()
        #expect(MediaGenerationAssetReusePolicy.generatedRelativePath(
            assetID: id, fileExtension: "webp")
            == "Materials/\(id.uuidString)-generated.webp")
    }

    @Test("Partial terminal error names the missing slots and preserved images")
    func partialFailureCopy() {
        let report = ImageGenerationBatchReport(metadata: [
            "requestedModel": "doubao-seedream-5-0-pro",
            "actualModel": "doubao-seedream-5-0-pro",
            "requestedProvider": "Volcengine Agent Plan",
            "actualProvider": "Volcengine Agent Plan",
            "requestedCount": "4",
            "completedCount": "2",
            "failedCount": "2",
            "slotStatuses": "succeeded,succeeded,failed,notAttempted",
            "cancelled": "false",
            "partialFailure": "true",
        ])
        let failure = MediaGenerationImageBatchFailure(
            report: report,
            requestedOutputCount: 4,
            preservedCount: 2,
            persistenceFailedCount: 0)
        let copy = failure.errorDescription ?? ""
        #expect(copy.isEmpty == false)
        #expect(failure.preservedCount == 2)
        #expect(report.isComplete == false)
        #expect(report.missingSlotNumbers == [3, 4])
    }
}
#endif

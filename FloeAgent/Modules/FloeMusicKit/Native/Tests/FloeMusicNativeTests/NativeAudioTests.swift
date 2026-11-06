import XCTest
import FloeMusicCore
@testable import FloeMusicNative

final class NativeAudioTests: XCTestCase {
    func testInvalidatedRenderCannotCommitOrValidate() throws {
        let document = try MusicDocument(name: "lease")
        let lease = try MusicRenderLease(document: document, ownerToken: "render")
        try lease.validate(document: document)
        lease.invalidate()
        XCTAssertThrowsError(try lease.validate(document: document))
    }

    func testLeaseCannotBeReusedForAnotherRevisionOrProject() throws {
        let document = try MusicDocument(name: "original")
        let lease = try MusicRenderLease(document: document, ownerToken: "render")
        var changed = document
        changed.revision = 1
        XCTAssertThrowsError(try lease.validate(document: changed))
        changed = try MusicDocument(name: "another")
        XCTAssertThrowsError(try lease.validate(document: changed))
    }
}

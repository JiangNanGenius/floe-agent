#if canImport(UIKit)
import XCTest
@testable import FloeApp

@MainActor final class ScreenShareGuidanceContractTests: XCTestCase {
    func testTextOnlyGuidanceDoesNotInventACenterTap() {
        XCTAssertTrue(ScreenShareCenter.guideHints(from:"Open the settings menu first.").isEmpty)
    }
    func testNormalizedHintsStayOnTheAnalyzedImageAndRejectInvalidCoordinates() throws {
        let hints=ScreenShareCenter.guideHints(from:#"[{"label":"Settings","instruction":"Open settings","x":0.2,"y":0.8},{"label":"bad","instruction":"bad","x":2,"y":0.5}]"#)
        XCTAssertEqual(hints.count,1)
        XCTAssertEqual(try XCTUnwrap(hints.first).tapPoint.x,0.2,accuracy:1e-8)
    }
}
#endif

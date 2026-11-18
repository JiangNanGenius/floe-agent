import XCTest
@testable import FloeMacMediaSystem

@MainActor
final class MacScannerPanelAdmissionTests: XCTestCase {
    func testRevokedSelectionDoesNotReadChosenFile() throws {
        var permitted = true
        var reads = 0
        let selected = URL(fileURLWithPath: "/synthetic-never-read")
        // Models the modal panel returning after the surface disappeared.
        permitted = false
        let result: Data? = try MacImageImportService.readSelection(selected, isStillAuthorized: { permitted }) { _ in
            reads += 1
            return Data("unexpected".utf8)
        }
        XCTAssertNil(result)
        XCTAssertEqual(reads, 0)
    }
}

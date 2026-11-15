// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeBuildingWorkspace

final class BuildingNumericInputTests:XCTestCase {
    func testSignedDecimalAndScientificInputs() throws {
        XCTAssertEqual(try BuildingNumericInput.parse(" -10.5 "),-10.5)
        XCTAssertEqual(try BuildingNumericInput.parse(".5"),0.5)
        XCTAssertEqual(try BuildingNumericInput.parse("3e-4"),0.0003)
        XCTAssertEqual(try BuildingNumericInput.parse("1,25",decimalSeparator:","),1.25)
    }
    func testPartialMalformedAndNonfiniteAreNotSilentlyCoerced() {
        for text in ["","-",".","12abc","1,234","1.2.3","NaN","inf","1e500","3 m"] {
            XCTAssertThrowsError(try BuildingNumericInput.parse(text),text)
        }
        XCTAssertThrowsError(try BuildingNumericInput.parse("1.2,3",decimalSeparator:","))
        XCTAssertThrowsError(try BuildingNumericInput.parse(String(repeating:"1",count:121)))
    }
}

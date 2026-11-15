// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeGameBuildKit

final class GameArtifactKindDecodingTests: XCTestCase {
    func testPublishedCatalogAliasesDecodeAndEncodeAsStableWireValues() throws {
        for (value, expected, encoded) in [("webBundle", GameArtifactValidationKind.webBundle, "web"),
                                            ("nativeZip", .nativeZip, "zip"),
                                            ("web", .webBundle, "web"), ("zip", .nativeZip, "zip")] {
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(GameArtifactValidationKind.self, from: data), expected)
            XCTAssertEqual(try JSONDecoder().decode(String.self, from: JSONEncoder().encode(expected)), encoded)
        }
    }
    func testUnknownValidationKindIsRejected() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(GameArtifactValidationKind.self,
            from: Data("\"unverified-installer\"".utf8)))
    }
}

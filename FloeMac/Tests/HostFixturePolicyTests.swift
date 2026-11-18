// SPDX-License-Identifier: MPL-2.0
import XCTest

final class HostFixturePolicyTests: XCTestCase {
    func testEachKnownFixtureEnvironmentDisablesBothFeatures() {
        XCTAssertEqual(HostFixturePolicy.isolatedEnvironmentKeys.count, 8)
        for key in HostFixturePolicy.isolatedEnvironmentKeys {
            XCTAssertTrue(HostFixturePolicy.isIsolatedEnvironment([key: "fixture"]), key)
        }
    }

    func testEmptyOrUnrelatedEnvironmentDoesNotDisableNormalHost() {
        XCTAssertFalse(HostFixturePolicy.isIsolatedEnvironment([:]))
        XCTAssertFalse(HostFixturePolicy.isIsolatedEnvironment(["XCTestBundlePath": ""]))
        XCTAssertFalse(HostFixturePolicy.isIsolatedEnvironment(["UNRELATED": "value"]))
    }
}

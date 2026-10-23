import Foundation
import XCTest
@testable import FloeAndroidShellTools

final class LinuxShellRecoveryStrictMetadataTests: XCTestCase {
    private func clean() -> [String: Any] {
        ["sessionKey": String(repeating: "a", count: 32),
         "runID": "A1B2C3D4-0000-4000-9000-000000000005",
         "import": ["outcome": "clean", "created": 0, "replacedSynced": 0,
                    "preservedUnsynced": 0, "unchanged": 0, "appliedBytes": 0],
         "export": ["result": "synced"]]
    }

    func testBooleanFractionalAndOverflowCountersAreUnavailable() {
        for value in [true, 1.5, NSNumber(value: UInt64.max)] as [Any] {
            var object = clean()
            var imported = object["import"] as! [String: Any]
            imported["created"] = value
            object["import"] = imported
            XCTAssertNil(LinuxShellWorkspaceRecovery.parse(object))
        }
        var object = clean()
        var imported = object["import"] as! [String: Any]
        imported["created"] = 1.0
        object["import"] = imported
        XCTAssertEqual(LinuxShellWorkspaceRecovery.parse(object)?.created, 1)
    }

    func testPreservedCopyPathsStayRelativeAndByteCountsExact() {
        for path in ["", "/absolute", "../outside", "a/../b", "a//b", "a/./b", "bad\nline"] {
            XCTAssertNil(LinuxShellWorkspaceRecovery.parse(preserved(path: path, bytes: 1)))
        }
        XCTAssertNil(LinuxShellWorkspaceRecovery.parse(preserved(path: "a.txt", bytes: true)))
        XCTAssertNil(LinuxShellWorkspaceRecovery.parse(preserved(path: "a.txt", bytes: 1.25)))
        XCTAssertNotNil(LinuxShellWorkspaceRecovery.parse(preserved(path: "文件/a.txt", bytes: 1)))
    }

    func testOversizeSupplementaryObjectIsDroppedWithoutChangingRelease() {
        var object = clean()
        object["padding"] = String(repeating: "x", count: 8_192)
        XCTAssertNil(LinuxShellWorkspaceRecovery.parse(object))
        XCTAssertNil(LinuxShellWorkspaceRecovery.parse(nil))
    }

    private func preserved(path: String, bytes: Any) -> [String: Any] {
        var object = clean()
        var imported = object["import"] as! [String: Any]
        imported["outcome"] = "swappedPreserved"
        imported["preservedUnsynced"] = 1
        imported["preserved"] = [["path": path, "action": "swappedPreserved",
                                   "preservedSha256": String(repeating: "b", count: 64),
                                   "installedBaselineSha256": String(repeating: "c", count: 64),
                                   "preservedBytes": bytes, "installedBaselineBytes": 1]]
        object["import"] = imported
        return object
    }
}

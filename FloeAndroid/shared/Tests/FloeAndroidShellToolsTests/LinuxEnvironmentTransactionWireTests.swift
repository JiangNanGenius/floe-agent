import XCTest
@testable import FloeAndroidShellTools

final class LinuxEnvironmentTransactionWireTests: XCTestCase {
    private let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private func wire(_ bytes: Any = 1024, outcome: String = "rolledBack") -> [String: Any] {
        ["id": id, "outcome": outcome, "snapshotBytes": bytes]
    }
    func testExactPhysicalReceiptAndBoundaries() {
        for outcome in ["committed", "rolledBack"] {
            let value = LinuxEnvironmentTransactionReceipt(wire: wire(outcome: outcome))
            XCTAssertEqual(value?.id, id)
            XCTAssertEqual(value?.outcome.rawValue, outcome)
            XCTAssertEqual(value?.snapshotBytes, 1024)
        }
        XCTAssertNotNil(LinuxEnvironmentTransactionReceipt(wire: wire(Int64(4) * 1024 * 1024 * 1024)))
    }
    func testNonIntegralBooleanNegativeAndOversizedCountsAreNotProof() {
        for invalid in [true, "1024", 1.25, -1, Int64(4) * 1024 * 1024 * 1024 + 1] as [Any] {
            XCTAssertNil(LinuxEnvironmentTransactionReceipt(wire: wire(invalid)))
        }
    }
    func testUnknownMissingAndPathShapedReceiptsRemainUnknown() {
        XCTAssertNil(LinuxEnvironmentTransactionReceipt(wire: nil))
        XCTAssertNil(LinuxEnvironmentTransactionReceipt(wire: [String: Any]()))
        XCTAssertNil(LinuxEnvironmentTransactionReceipt(wire: wire(outcome: "success")))
        var invalid = wire(); invalid["id"] = "/files/snapshot"
        XCTAssertNil(LinuxEnvironmentTransactionReceipt(wire: invalid))
        invalid = wire(); invalid["path"] = "/arbitrary"
        XCTAssertNil(LinuxEnvironmentTransactionReceipt(wire: invalid))
    }
}

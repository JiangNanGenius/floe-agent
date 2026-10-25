import Foundation
import XCTest
@testable import FloeAndroidCore

final class FacadeEventPumpSettleRecoveryTests: XCTestCase {
    func testDegradedOverflowPreservesOldUnattachedTargetsRecoverySignal() {
        let pump = FacadeEventPump()
        let oldest = UUID()
        pump.markSettlePublicationDegraded(runID: oldest, expectedSequence: nil)
        let initial = pump.pollDurable(runID: oldest, afterSequence: 0,
                                       budgetBytes: 65_536)
        XCTAssertEqual(initial["windowState"] as? String, "notAttached")
        XCTAssertEqual(initial["resyncRequired"] as? Bool, true)

        // Exceed the real bounded degraded capacity. The oldest unresolved
        // target must still reach the existing wire recovery signal after
        // its individual entry is evicted; no unbounded retention is needed.
        for _ in 0...FacadeEventPump.Limits.maximumWindows {
            pump.markSettlePublicationDegraded(runID: UUID(), expectedSequence: nil)
        }
        XCTAssertTrue(pump.isSettleOverflowResyncLatched)
        let overflowed = pump.pollDurable(runID: oldest, afterSequence: 0,
                                          budgetBytes: 65_536)
        XCTAssertEqual(overflowed["windowState"] as? String, "notAttached")
        XCTAssertEqual(overflowed["resyncRequired"] as? Bool, true)

        // Clearing an individual target must not discard the conservative
        // overflow recovery signal for an evicted unresolved target.
        pump.clearSettlePublicationDegraded(runID: oldest)
        XCTAssertEqual(pump.pollDurable(runID: oldest, afterSequence: 0,
                                        budgetBytes: 65_536)["resyncRequired"] as? Bool, true)
    }
}

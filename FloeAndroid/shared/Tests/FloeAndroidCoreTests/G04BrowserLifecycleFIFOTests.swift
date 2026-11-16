import Foundation
import XCTest
@testable import FloeAndroidCore
import FloeBrowser

private actor LifecycleOrderRecorder {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}

private actor LifecycleLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async { if isOpen { return }; await withCheckedContinuation { continuation = $0 } }
    func open() { isOpen = true; continuation?.resume(); continuation = nil }
}

final class G04BrowserLifecycleFIFOTests: XCTestCase {
    func testGlobalSaturationFencesEpochWithoutCreatingGapTasks() async {
        let fifo = G04BrowserLifecycleFIFO(maximumLanes: 1, maximumPendingPerLane: 1)
        let latch = LifecycleLatch()
        let otherTab = UUID()
        let unexpectedGap = expectation(description: "no per-tab overflow task")
        unexpectedGap.isInverted = true
        XCTAssertTrue(fifo.enqueue(epoch: 7890, tabID: UUID()) { await latch.wait() })
        for _ in 0..<1_000 {
            XCTAssertFalse(fifo.enqueue(epoch: 7890, tabID: UUID(), onOverflow: { unexpectedGap.fulfill() }) {})
        }
        XCTAssertTrue(BrowserLifecycleHealth.shared.hasGap(epoch: 7890, tabID: otherTab))
        XCTAssertTrue(BrowserLifecycleHealth.shared.epochIsSaturated(7890))
        XCTAssertFalse(BrowserLifecycleHealth.shared.hasGap(epoch: 7891, tabID: otherTab))
        await latch.open()
        await fulfillment(of: [unexpectedGap], timeout: 0.1)
    }

    func testOverflowFencesBeforeReturnAndDeliversGapAfterQueuedEvents() async {
        let fifo = G04BrowserLifecycleFIFO(maximumPendingPerLane: 1)
        let tab = UUID()
        let latch = LifecycleLatch()
        let recorder = LifecycleOrderRecorder()
        let gapDelivered = expectation(description: "gap delivered")
        XCTAssertTrue(fifo.enqueue(epoch: 77, tabID: tab) {
            await latch.wait()
            await recorder.append(1)
        })
        XCTAssertFalse(fifo.enqueue(epoch: 77, tabID: tab, onOverflow: {
            await recorder.append(2)
            gapDelivered.fulfill()
        }) { await recorder.append(99) })
        XCTAssertTrue(BrowserLifecycleHealth.shared.hasGap(epoch: 77, tabID: tab))
        XCTAssertFalse(BrowserLifecycleHealth.shared.hasGap(epoch: 78, tabID: tab))
        await latch.open()
        await fulfillment(of: [gapDelivered], timeout: 5)
        let values = await recorder.values
        XCTAssertEqual(values, [1, 2])
    }

    func testCallbacksForOneTabKeepArrivalOrder() async {
        let fifo = G04BrowserLifecycleFIFO()
        let tab = UUID()
        let recorder = LifecycleOrderRecorder()
        let finished = expectation(description: "all callbacks completed")
        finished.expectedFulfillmentCount = 40
        for index in 0..<40 {
            XCTAssertTrue(fifo.enqueue(epoch: 7, tabID: tab) {
                if index == 0 { try? await Task.sleep(for: .milliseconds(50)) }
                await recorder.append(index)
                finished.fulfill()
            })
        }
        await fulfillment(of: [finished], timeout: 5)
        let values = await recorder.values
        XCTAssertEqual(values, Array(0..<40))
    }
}

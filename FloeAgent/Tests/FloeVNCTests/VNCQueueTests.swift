import Foundation
import Dispatch
import Testing
@testable import RoyalVNCKit

@Suite("RFB concurrent input queue")
struct QueueTests {
    @Test func concurrentProducersAndConsumerPreserveMessages() async {
        let queue = Queue<Int>()
        let count = 4_000
        let producer = Task.detached {
            DispatchQueue.concurrentPerform(iterations: count) { queue.enqueue($0) }
        }
        var received = Set<Int>()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while received.count < count && ContinuousClock.now < deadline {
            if let value = queue.dequeue() { received.insert(value) }
            else { await Task.yield() }
        }
        await producer.value
        #expect(received == Set(0..<count))
        #expect(queue.isEmpty)
    }

    @Test func clearPeekAndDequeueAreAtomic() {
        let queue = Queue<Int>()
        DispatchQueue.concurrentPerform(iterations: 8_000) { index in
            switch index % 4 {
            case 0: queue.enqueue(index)
            case 1: _ = queue.dequeue()
            case 2: queue.clear()
            default: _ = queue.peek()
            }
        }
        queue.clear()
        #expect(queue.dequeue() == nil)
        #expect(queue.peek() == nil)
    }
}

// SPDX-License-Identifier: MPL-2.0
// Pending operations yield to native slices. A full console never blocks peers.
import Foundation
import FloeARM64Engine

struct ARM64IOOperation: Sendable {
    let generation: UInt64
    let lane: UInt32?
    let step: @Sendable (floe_ae_handle) -> Bool
    let fail: @Sendable (Error) -> Void
    init(generation: UInt64, lane: UInt32? = nil,
         fail: @escaping @Sendable (Error) -> Void,
         step: @escaping @Sendable (floe_ae_handle) -> Bool) {
        self.generation = generation; self.lane = lane; self.fail = fail; self.step = step
    }
}

final class ARM64IOQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [ARM64IOOperation] = []
    // Includes operations temporarily drained by the worker. Requeueing a
    // partial write must not create capacity for unlimited new waiters.
    private var outstanding = 0
    private var activeGeneration: UInt64?
    func begin(generation: UInt64) { lock.withLock { activeGeneration = generation } }
    func enqueue(_ operation: ARM64IOOperation) {
        let refusal: ARM64MachineError? = lock.withLock {
            guard activeGeneration == operation.generation else { return .notRunning }
            guard outstanding < 256 else { return .engineBusy("machine operation queue is full") }
            outstanding += 1
            operations.append(operation)
            return nil
        }
        if let refusal { operation.fail(refusal) }
    }
    func completed() { lock.withLock { outstanding -= 1 } }
    func drain() -> [ARM64IOOperation] {
        lock.withLock { let result = operations; operations.removeAll(keepingCapacity: true); return result }
    }
    func prepend(_ pending: [ARM64IOOperation]) {
        guard !pending.isEmpty else { return }
        lock.withLock { operations.insert(contentsOf: pending, at: 0) }
    }
    func failAll(_ error: Error) {
        // Fence admission before taking the final batch. A caller that read
        // `running` just before stop must not enqueue behind the exited worker.
        lock.withLock { activeGeneration = nil }
        for operation in drain() { operation.fail(error); completed() }
    }
}

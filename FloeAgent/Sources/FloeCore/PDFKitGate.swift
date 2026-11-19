// SPDX-License-Identifier: MPL-2.0

#if canImport(Darwin)
import Dispatch

/// Serialize PDFKit work across the agent and native document surfaces.
/// Nested calls on the same queue can re-enter without deadlocking.
public enum PDFKitGate {
    private static let queueKey = DispatchSpecificKey<Void>()
    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "org.floeagent.pdfkit", qos: .userInitiated)
        queue.setSpecific(key: queueKey, value: ())
        return queue
    }()

    public static func run<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try work()
        }
        return try queue.sync { try work() }
    }
}
#endif

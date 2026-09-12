// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore

/// Process-wide gate for PDFKit, which is not thread-safe: agent-loop tools
/// parse/draw/serialize while the main-thread reader displays its own
/// document, and thread migration of PDFKit objects crashes. Every PDFKit
/// touch runs on one dedicated serial queue (thread affinity), and nested
/// calls re-enter directly. Never await while holding it.
enum PDFKitGate {
    private static let queueKey = DispatchSpecificKey<Void>()
    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "org.floeagent.pdfkit", qos: .userInitiated)
        queue.setSpecific(key: queueKey, value: ())
        return queue
    }()

    static func run<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try work()
        }
        return try queue.sync { try work() }
    }
}


/// Runs PDFKit mutations through the ObjC exception boundary so an engine
/// `NSException` (invalid indices, widget/form internals, KVC keys, malformed
/// documents) becomes an ordinary tool error instead of a process crash.
func withPDFExceptionGuard<T>(_ work: @escaping () throws -> T) throws -> T {
    var outcome: Result<T, Error>?
    let failure = FloePDFExceptionGuard.run {
        do { outcome = .success(try work()) }
        catch { outcome = .failure(error) }
    }
    if let outcome { return try outcome.get() }
    throw FloeError.internalError(
        failure ?? "PDF engine raised an unexpected internal exception"
    )
}
#endif

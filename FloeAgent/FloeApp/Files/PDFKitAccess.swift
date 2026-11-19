// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore

typealias PDFKitGate = FloeCore.PDFKitGate

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

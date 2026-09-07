import Foundation
import FloeCore
import FloeTools

/// Foundation values cross the worker boundary only as immutable Data.
enum PDFContentEditor {
    struct Result: Sendable {
        let data: Data
        let replacements: Int
    }

    static func replace(in data: Data, rulesJSON: Data, cancellation: CancellationToken) async throws -> Result {
        try Task.checkCancellation()
        let result = try await Task.detached(priority: .userInitiated) {
            let output = try FloePDFiumBridge.rewrite(data, operationsJSON: rulesJSON, cancelled: { cancellation.isCancelled })
            guard let bytes = output["data"] as? Data,
                  let count = output["replacements"] as? Int else {
                throw FloeError.internalError("Native PDF editing returned no verified document")
            }
            return Result(data: bytes, replacements: count)
        }.value
        try Task.checkCancellation()
        return result
    }
}

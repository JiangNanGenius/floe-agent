// SPDX-License-Identifier: MPL-2.0
// FloeApp — Shared Documents export adapter (S5 C4).
//
// Thin, real adapter between existing export flows and the Shared Documents
// location. Callers hand over an ALREADY-produced file (e.g. the committed
// bytes from DocumentExportService or a run-output file); the adapter
// streams it into the store and returns a truthful receipt or an actionable
// bilingual error. It fabricates nothing and never triggers task/model
// behavior from file content.
//
// Optional primary-side hook (proposal, not applied by this lane): a
// "Save to Shared Documents" action can call
// `SharedDocumentsExportAdapter.export(url:displayName:)` next to the
// existing TaskExportShareSheet; the standard share sheet already reaches
// the location through "Save to Files" once the domain is mounted.

#if canImport(UIKit)
import Foundation
import FloeCore
import FloePersistence

enum SharedDocumentsExportAdapter {
    enum Outcome: Sendable, Equatable {
        case exported(SharedDocumentsExportReceipt)
        case failed(String)
    }

    @MainActor
    static func export(
        url: URL,
        displayName: String,
        center: SharedDocumentsCenter = .shared
    ) async -> Outcome {
        do {
            let receipt = try await center.exportFile(sourceURL: url, name: displayName)
            return .exported(receipt)
        } catch let error as SharedDocumentsCenterError {
            return .failed(error.localizedDescription)
        } catch {
            return .failed(SharedDocumentsCopy.exportFailedMessage(String(describing: error)))
        }
    }

    /// Confirmation line for UI surfaces after a successful export.
    static func confirmation(for receipt: SharedDocumentsExportReceipt) -> String {
        "\(SharedDocumentsCopy.exportedConfirmation) · \(receipt.name)"
    }
}
#endif

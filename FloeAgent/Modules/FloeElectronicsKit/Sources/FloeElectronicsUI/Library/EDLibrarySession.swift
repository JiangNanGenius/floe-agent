// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeElectronicsCore

extension EDWorkbenchSession {
    /// User gestures and AI adapters call the same native original transaction.
    @discardableResult public func placeLibrary(_ selection: EDALibraryPlacementSelection, context: EDADocumentContext,
        position: EDAPoint, angle: Double = 0, mirrored: Bool = false, expectedRevision: UInt64, cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> EDALibraryPlacementReceipt {
        var receipt: EDALibraryPlacementReceipt?
        try await transaction(expectedRevision: expectedRevision, cancelBeforeCommit: true, cancelled: cancelled) { project in
            switch context {
            case .schematic(let id):
                receipt = try EDALibraryProject.place(selection.snapshot, into: &project, sheetID: id, position: position, unit: selection.unit,
                    angle: angle, mirrored: mirrored, existingComponentID: selection.existingComponentID)
            case .board(let id):
                receipt = try EDALibraryProject.place(selection.snapshot, into: &project, boardID: id, position: position,
                    angle: angle, mirrored: mirrored, existingComponentID: selection.existingComponentID)
            default: throw EDAError.invalid("choose a schematic or PCB for library placement")
            }
        }
        guard let receipt else { throw EDAError.invalid("library placement receipt") }
        self.selection = .init(context: context, objectIDs: [receipt.objectID])
        await library?.recordUse(selection.snapshot)
        return receipt
    }
    public func replaceLibrary(_ plan: EDALibraryReplacementPlan, acceptedDifferences: Set<String>, cancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        try await transaction(expectedRevision: plan.sourceRevision, cancelBeforeCommit: true, cancelled: cancelled) { project in
            try EDALibraryProject.replace(plan, acceptedDifferences: acceptedDifferences, in: &project)
        }
        await library?.recordUse(plan.snapshot)
    }
}

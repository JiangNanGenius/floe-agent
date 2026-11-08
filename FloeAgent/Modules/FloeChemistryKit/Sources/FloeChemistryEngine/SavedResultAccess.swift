// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeChemistryCore

extension ChemistryService {
    /// The service actor compares the actual immutable run value, keeping
    /// a potentially large result equality walk off the App's main actor.
    public func savedResultMatchesForRead(_ id: UUID, run: ChemistryRun) async throws -> Bool {
        try await project(id).runs.first(where: { $0.id == run.id }) == run
    }
    public func savedResultMatchesForExport(_ id: UUID, run: ChemistryRun) async throws -> Bool {
        try await savedResultForExport(id, runID: run.id) == run
    }
    /// A saved result export is an export access, not merely a project read.
    /// It never starts a backend or requires the old environment to be running.
    public func savedResultForExport(_ id: UUID, runID: UUID) async throws -> ChemistryRun {
        try await access(id, .export)
        guard let run = try await store.load(id).runs.first(where: { $0.id == runID }),
              run.status == .succeeded, run.result != nil else {
            throw ChemistryError.invalid("No successful saved result exists for this calculation.")
        }
        try await access(id, .export)
        return run
    }
}

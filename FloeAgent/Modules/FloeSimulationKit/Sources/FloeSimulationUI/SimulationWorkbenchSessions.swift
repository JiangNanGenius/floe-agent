import Foundation
import FloeSimulationCore
import FloeSimulationRuntime
import FloeSimulationGeometry

/// The App owns one registry for its saved projects. Editor panels and Studio
/// tools borrow the same model; dismissing a panel does not end its jobs.
@MainActor public final class SimulationWorkbenchSessions {
    private var models: [String:SimulationWorkbenchModel] = [:]
    private var opening: [String:Task<SimulationWorkbenchModel,any Error>] = [:]
    private var closing = Set<String>()
    public init() {}
    public func open(initial: SimulationWorkspaceDocument, directory: URL, additionalBackends: [any SimulationBackend] = [], geometryProvider: SimulationGeometryProvider? = nil) async throws -> SimulationWorkbenchModel {
        let key = try key(directory)
        guard !closing.contains(key) else { throw SimulationError.invalidInput("Wait for this simulation workspace to close.") }
        let model: SimulationWorkbenchModel
        if let current = models[key] { model = current }
        else if let pending = opening[key] { model = try await pending.value }
        else {
            guard models.count+opening.count < 16 else { throw SimulationError.resourceLimit("Close another simulation workspace before opening this one.") }
            let pending = Task { @MainActor in
                try await SimulationWorkbenchFactory.openOrCreate(initial:initial,directory:directory,additionalBackends:additionalBackends,geometryProvider:geometryProvider)
            }
            opening[key] = pending
            defer { opening.removeValue(forKey:key) }
            model = try await pending.value
        }
        guard !closing.contains(key), !model.isClosed else { throw SimulationError.invalidInput("This simulation workspace is closing.") }
        guard model.document.source.projectID == initial.source.projectID, model.document.source.documentID == initial.source.documentID else { throw SimulationError.staleSource }
        if model.document.source != initial.source {
            guard await model.refreshSource(initial.source) else { throw SimulationError.staleSource }
        }
        models[key] = model; return model
    }
    public func close(directory: URL) async throws {
        let key = try key(directory)
        guard closing.insert(key).inserted else { throw SimulationError.invalidInput("This simulation workspace is already closing.") }
        defer { closing.remove(key) }
        if let pending = opening[key], let model = try? await pending.value { await model.close() }
        if let model = models[key] { await model.close(); models.removeValue(forKey:key) }
    }
    private func key(_ directory: URL) throws -> String {
        guard directory.isFileURL else { throw SimulationError.invalidInput("Use this project's saved simulation directory.") }
        return directory.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

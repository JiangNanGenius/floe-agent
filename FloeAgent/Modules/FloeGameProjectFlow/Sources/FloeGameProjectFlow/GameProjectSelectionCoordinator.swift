// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameAuthoring
import FloeGameCore
import FloeGameStarterKit
import FloeGameWebKit

/// Owner/project/environment/root-bound selection coordinator. It composes the
/// existing repository, discovery inspector, starter catalog and host context
/// service. It does not run, build, install or translate an engine.
public actor GameProjectSelectionCoordinator {
    nonisolated public let scaffolder: GameStarterScaffolder
    nonisolated public let repository: FileGameProjectRepository
    nonisolated public let catalog: GameStarterCatalog

    let contexts: any GameAuthoringContextHost & GameRunContextHost
    let store: any GameProjectSelectionStore
    let recommender: GameProjectSelectionRecommendationHandler?
    let capabilityProbe: (any GameProjectSelectionCapabilityProbe)?
    let maximumRoots: Int

    /// One write generation per selection identity. A slow automatic refresh
    /// never overwrites a newer explicit choice for the same project.
    private var writeGenerations: [GameProjectSelectionKey: UInt64] = [:]

    // Discovery is reusable only for this exact live tree and saved revision.
    private var lastDiscovery: GameProjectSelectionSnapshot?

    public init(scaffolder: GameStarterScaffolder,
                contexts: any GameAuthoringContextHost & GameRunContextHost,
                store: any GameProjectSelectionStore,
                recommender: GameProjectSelectionRecommendationHandler? = nil,
                capabilityProbe: (any GameProjectSelectionCapabilityProbe)? = nil,
                maximumRoots: Int = 64) throws {
        guard (1...256).contains(maximumRoots) else {
            throw GameProjectFlowError.invalidContext
        }
        self.scaffolder = scaffolder
        self.repository = scaffolder.repository
        self.catalog = scaffolder.catalog
        self.contexts = contexts
        self.store = store
        self.recommender = recommender
        self.capabilityProbe = capabilityProbe
        self.maximumRoots = maximumRoots
    }

    /// Catalog-declared capabilities for the create-from-zero picker. No host
    /// probe is involved: every prerequisite is explicitly `.unverified`.
    nonisolated public func creationCapabilities() throws -> [GameProjectEngineCapability] {
        catalog.engines.map { descriptor in
            let starterSource: GameProjectEngineStarterSource
            switch descriptor.templateKind {
            case .static: starterSource = .bundledTemplate
            case .delegated: starterSource = .delegatedProvider
            case .runtimePack: starterSource = .preparedRuntimePack
            case .importOnly: starterSource = .importOnly
            }
            return GameProjectEngineCapability(
                engine: descriptor.engine,
                displayName: descriptor.displayName,
                starterReadiness: descriptor.readiness,
                starterSource: starterSource,
                prerequisites: descriptor.prerequisites.map {
                    GameProjectPrerequisiteState(kind: $0.kind, name: $0.name,
                                                 version: $0.version,
                                                 requiredFor: $0.requiredFor,
                                                 host: .unverified)
                },
                recognizedEvidence: [],
                recognizedMarkerPaths: [],
                preparedRuntimePackPresent: descriptor.runtimePack == nil
                    ? nil : scaffolder.resources.pack(for: descriptor.engine) != nil,
                sourceLicense: descriptor.sourceLicense,
                engineLicense: descriptor.engineLicense)
        }
    }

    /// Re-discovers the live root and validates any persisted choice against the
    /// current revision. A single unambiguous engine is selected and persisted;
    /// multiple roots/engines require an explicit `select`.
    public func refresh(project: GameStoredProject,
                        context: GameProjectContext) async throws
        -> GameProjectSelectionSnapshot {
        try Task.checkCancellation()
        let key = try selectionKey(context)
        let observedGeneration = writeGenerations[key] ?? 0
        let loaded = try await loadRecord(key: key)
        let resolution = try await resolver().resolve(
            project: project, context: context, loadedRecord: loaded.record, intent: nil)
        let snapshot = resolution.snapshot.withDiagnostics(
            loaded.diagnostics + resolution.snapshot.diagnostics)
        let adjusted = GameProjectSelectionResolution(
            snapshot: snapshot, shouldPersist: resolution.shouldPersist,
            shouldRemove: resolution.shouldRemove)
        try Task.checkCancellation()
        let result = try await applyPersistence(adjusted, context: context, key: key,
                                          observedGeneration: observedGeneration,
                                          mandatory: false)
        if (writeGenerations[key] ?? 0) == observedGeneration { lastDiscovery = result }
        return result
    }

    /// Explicit user choice. The exact root must exist in fresh discovery and
    /// the engine must be recognized there. AI recommendations are advisory and
    /// may be overridden by calling this method with another recognized engine.
    public func select(root: GameRelativePath?, engine: GameEngineID,
                       context: GameProjectContext) async throws
        -> GameProjectSelectionSnapshot {
        try Task.checkCancellation()
        let key = try selectionKey(context)
        let token = beginWrite(key)
        let project = try await openProject(id: context.projectID, owner: context.owner)
        try GameProjectSelectionValidation.project(project, context: context)
        let snapshot: GameProjectSelectionSnapshot
        if let discovery = lastDiscovery, discovery.matches(context),
           discovery.engines(forRoot: root).contains(where: { $0.engine == engine }) {
            // repository.open above checked the live file inventory. The marker
            // evidence already displayed belongs to that exact revision.
            try await GameProjectSelectionValidation.currentContext(context, contexts: contexts)
            snapshot = discovery.confirming(root: root, engine: engine)
        } else {
            let resolution = try await resolver().resolve(
                project: project, context: context, loadedRecord: nil,
                intent: GameProjectSelectionIntent(root: root, engine: engine))
            guard resolution.shouldPersist else { throw GameProjectFlowError.selectionRequired }
            snapshot = resolution.snapshot
        }
        try requireWrite(key, token)
        try Task.checkCancellation()
        let record: GameProjectSelectionRecord
        do {
            record = try GameProjectSelectionRecord(context: context,
                                                    snapshot: snapshot)
        } catch {
            throw GameProjectFlowError.selectionRequired
        }
        do {
            try await store.save(record, for: key)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GameProjectFlowError.persistenceFailed(
                GameProjectSelectionText.bounded(error))
        }
        try requireWrite(key, token)
        return snapshot.withPersistence(true)
    }

    /// Explicit manual choice for an imported tree whose engine is not
    /// recognized deterministically. The host UI must only call this after the
    /// user acknowledged that no marker evidence exists. The choice is
    /// persisted with `.manualUnverified`, remains readable/editable, and
    /// deliberately does not produce a run selection.
    public func selectManual(root: GameRelativePath?, engine: GameEngineID,
                             context: GameProjectContext,
                             acknowledgingUnverified: Bool) async throws
        -> GameProjectSelectionSnapshot {
        guard acknowledgingUnverified else {
            throw GameProjectFlowError.manualSelectionNotAcknowledged
        }
        try Task.checkCancellation()
        let key = try selectionKey(context)
        let token = beginWrite(key)
        let project = try await openProject(id: context.projectID, owner: context.owner)
        let resolution = try await resolver().resolve(
            project: project, context: context, loadedRecord: nil, intent: nil,
            manualIntent: .init(root: root, engine: engine))
        try requireWrite(key, token)
        try Task.checkCancellation()
        let snapshot = try await applyPersistence(resolution, context: context,
                                                  key: key, observedGeneration: token,
                                                  mandatory: true)
        return snapshot.withPersistence(true)
    }

    /// Advisory proposal from the current project assistant. This never saves
    /// a selection; only `confirmProposal` after a real user confirmation can.
    public func proposeSelection(root: GameRelativePath?, engine: GameEngineID,
                                 evidencePaths: [GameRelativePath],
                                 rationale: String, generatedBy: String,
                                 context: GameProjectContext) async throws
        -> GameProjectSelectionProposal {
        try Task.checkCancellation()
        let project = try await openProject(id: context.projectID, owner: context.owner)
        return try await resolver().proposal(project: project, context: context,
                                             root: root, engine: engine,
                                             evidencePaths: evidencePaths,
                                             rationale: rationale,
                                             generatedBy: generatedBy)
    }

    /// Persists a proposal only when the caller represents the user's explicit
    /// confirmation in the project setup surface. The exact revision, owner,
    /// environment, root and fresh recognition are revalidated first.
    public func confirmProposal(_ proposal: GameProjectSelectionProposal,
                                context: GameProjectContext,
                                userConfirmed: Bool) async throws
        -> GameProjectSelectionSnapshot {
        guard userConfirmed else { throw GameProjectFlowError.proposalNotConfirmed }
        try Task.checkCancellation()
        guard proposal.projectID == context.projectID,
              proposal.owner == context.owner,
              proposal.environmentID == context.environmentID else {
            throw GameProjectFlowError.proposalStale
        }
        let project = try await openProject(id: context.projectID, owner: context.owner)
        let canonicalRoot = context.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard proposal.rootURL.standardizedFileURL.resolvingSymlinksInPath() == canonicalRoot,
              proposal.baseRevision == project.revision else {
            throw GameProjectFlowError.proposalStale
        }
        let currentPaths = Set(project.files.map(\.path))
        for path in proposal.evidencePaths where !currentPaths.contains(path) {
            throw GameProjectFlowError.proposalStale
        }
        switch proposal.verification {
        case .evidenceMatched:
            return try await select(root: proposal.selectedRoot,
                                    engine: proposal.selectedEngine,
                                    context: context)
        case .manualUnverified:
            return try await selectManual(root: proposal.selectedRoot,
                                          engine: proposal.selectedEngine,
                                          context: context,
                                          acknowledgingUnverified: true)
        }
    }

    /// Exact engine/root pair for `ExistingWorkspaceGameIDEHost`
    /// `ideRunExtension(engine:gameRoot:)`. It refreshes first, so a stale
    /// snapshot or newly ambiguous tree cannot launch a previous choice.
    public func currentRunSelection(project: GameStoredProject,
                                    context: GameProjectContext) async throws
        -> GameProjectRunSelection {
        let snapshot = try await refresh(project: project, context: context)
        return try snapshot.requireRunSelection()
    }

    public func currentRunSelection(context: GameProjectContext) async throws
        -> GameProjectRunSelection {
        let project = try await openProject(id: context.projectID, owner: context.owner)
        return try await currentRunSelection(project: project, context: context)
    }

    // MARK: - Internal services used by lifecycle operations

    func selectionKey(_ context: GameProjectContext) throws -> GameProjectSelectionKey {
        do {
            return try GameProjectSelectionKey(context: context)
        } catch {
            throw GameProjectFlowError.invalidContext
        }
    }

    func beginWrite(_ key: GameProjectSelectionKey) -> UInt64 {
        let next = (writeGenerations[key] ?? 0) &+ 1
        writeGenerations[key] = next
        return next
    }

    func requireWrite(_ key: GameProjectSelectionKey, _ token: UInt64) throws {
        guard (writeGenerations[key] ?? 0) == token else {
            throw GameProjectFlowError.superseded
        }
    }

    func openProject(id: UUID, owner: GameProjectOwner) async throws -> GameStoredProject {
        do {
            return try await repository.open(id, owner: owner)
        } catch let error as GameProjectError {
            throw GameProjectSelectionValidation.mapProject(error)
        } catch {
            throw GameProjectFlowError.project(
                .io(GameProjectSelectionText.bounded(error)))
        }
    }

    func resolver() -> GameProjectSelectionResolver {
        .init(repository: repository, catalog: catalog,
              resources: scaffolder.resources, contexts: contexts,
              recommender: recommender, capabilityProbe: capabilityProbe,
              maximumRoots: maximumRoots)
    }

    private func loadRecord(key: GameProjectSelectionKey) async throws
        -> (record: GameProjectSelectionRecord?,
            diagnostics: [GameProjectSelectionDiagnostic]) {
        do {
            let record = try await store.load(for: key)
            return (record: record, diagnostics: [])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (record: nil, diagnostics: [
                .init(.store, GameProjectSelectionText.bounded(error))
            ])
        }
    }

    /// Persist/remove a resolved record. Refresh, create and import are
    /// best-effort about the store so a read-only project still opens; an
    /// explicit `select` uses its own mandatory save above.
    func applyPersistence(_ resolution: GameProjectSelectionResolution,
                                  context: GameProjectContext,
                                  key: GameProjectSelectionKey,
                                  observedGeneration: UInt64,
                                  mandatory: Bool) async throws
        -> GameProjectSelectionSnapshot {
        var snapshot = resolution.snapshot
        var diagnostics = snapshot.diagnostics

        // A replacement record overwrites the same key; removing first would
        // create a window where a concurrent explicit choice could be lost.
        if resolution.shouldRemove, !resolution.shouldPersist {
            guard (writeGenerations[key] ?? 0) == observedGeneration else {
                if mandatory { throw GameProjectFlowError.superseded }
                diagnostics.append(.init(.coordination,
                    "A newer selection operation kept its choice."))
                return snapshot.withDiagnostics(diagnostics)
            }
            do {
                try Task.checkCancellation()
                try await store.remove(for: key)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if mandatory { throw GameProjectFlowError.persistenceFailed(
                    GameProjectSelectionText.bounded(error)) }
                diagnostics.append(.init(.store, GameProjectSelectionText.bounded(error)))
            }
        }

        guard resolution.shouldPersist else {
            return snapshot.withDiagnostics(diagnostics)
        }
        guard (writeGenerations[key] ?? 0) == observedGeneration else {
            if mandatory { throw GameProjectFlowError.superseded }
            diagnostics.append(.init(.coordination,
                "A newer selection operation replaced this automatic choice."))
            return snapshot.withDiagnostics(diagnostics)
        }
        let record: GameProjectSelectionRecord
        do {
            record = try GameProjectSelectionRecord(context: context, snapshot: snapshot)
        } catch {
            if mandatory { throw GameProjectFlowError.selectionRequired }
            diagnostics.append(.init(.store,
                "The automatic selection did not contain an engine."))
            return snapshot.withDiagnostics(diagnostics)
        }
        try Task.checkCancellation()
        do {
            try await store.save(record, for: key)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if mandatory { throw GameProjectFlowError.persistenceFailed(
                GameProjectSelectionText.bounded(error)) }
            diagnostics.append(.init(.store, GameProjectSelectionText.bounded(error)))
            return snapshot.withDiagnostics(diagnostics)
        }
        snapshot = snapshot.withPersistence(true)
        return snapshot.withDiagnostics(diagnostics)
    }
}

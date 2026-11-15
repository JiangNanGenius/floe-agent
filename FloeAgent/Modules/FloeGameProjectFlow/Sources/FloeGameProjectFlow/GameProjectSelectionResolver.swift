// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameAuthoring
import FloeGameCore
import FloeGameRunKit
import FloeGameStarterKit
import FloeGameWebKit

struct GameProjectSelectionIntent: Sendable {
    let root: GameRelativePath?
    let engine: GameEngineID
}

/// Explicit manual choice. The caller has already acknowledged, at the host UI
/// boundary, that no recognized marker may exist for this root/engine pair.
struct GameProjectManualSelectionIntent: Sendable {
    let root: GameRelativePath?
    let engine: GameEngineID
}

struct GameProjectSelectionResolution: Sendable {
    let snapshot: GameProjectSelectionSnapshot
    let shouldPersist: Bool
    let shouldRemove: Bool
}

/// Composes the existing discovery, inspection and starter catalog. It owns no
/// execution, build, provider or file-writing behavior.
struct GameProjectSelectionResolver: Sendable {
    let repository: FileGameProjectRepository
    let catalog: GameStarterCatalog
    let resources: GameStarterResources
    let contexts: any GameAuthoringContextHost & GameRunContextHost
    let recommender: GameProjectSelectionRecommendationHandler?
    let capabilityProbe: (any GameProjectSelectionCapabilityProbe)?
    let maximumRoots: Int
    private let rank: [GameEngineID: Int]

    init(repository: FileGameProjectRepository, catalog: GameStarterCatalog,
         resources: GameStarterResources,
         contexts: any GameAuthoringContextHost & GameRunContextHost,
         recommender: GameProjectSelectionRecommendationHandler?,
         capabilityProbe: (any GameProjectSelectionCapabilityProbe)?,
         maximumRoots: Int) {
        self.repository = repository
        self.catalog = catalog
        self.resources = resources
        self.contexts = contexts
        self.recommender = recommender
        self.capabilityProbe = capabilityProbe
        self.maximumRoots = maximumRoots
        self.rank = Dictionary(uniqueKeysWithValues: catalog.engines.enumerated().map {
            ($0.element.engine, $0.offset)
        })
    }

    func resolve(project capturedProject: GameStoredProject,
                 context: GameProjectContext,
                 loadedRecord: GameProjectSelectionRecord?,
                 intent: GameProjectSelectionIntent?,
                 manualIntent: GameProjectManualSelectionIntent? = nil)
        async throws -> GameProjectSelectionResolution {
        try Task.checkCancellation()
        try GameProjectSelectionValidation.project(capturedProject, context: context)
        try await GameProjectSelectionValidation.currentContext(context, contexts: contexts)
        try await GameProjectSelectionValidation.currentProject(capturedProject,
                                                               repository: repository)

        let project = capturedProject
        let discovered = try await makeChoices(project: project, context: context)
        var diagnostics = discovered.diagnostics
        let probed = try await applyProbe(choices: discovered.choices, context: context)
        diagnostics += probed.diagnostics
        try Task.checkCancellation()

        let isEmpty = project.files.isEmpty && project.directories.isEmpty
        let recommendation = try await aiRecommendation(
            project: project, choices: probed.choices, isEmptyProject: isEmpty)
        diagnostics += recommendation.diagnostics
        let ai = recommendation.recommendation
        try Task.checkCancellation()
        let heuristic = heuristicRecommendation(choices: probed.choices,
                                                isEmptyProject: isEmpty)

        let selection: Selection
        if let manualIntent {
            guard intent == nil else {
                throw GameProjectFlowError.proposalInvalid(
                    "A manual choice and a recognized choice cannot be combined.")
            }
            selection = try resolveManualSelection(project: project,
                                                   choices: probed.choices,
                                                   loadedRecord: loadedRecord,
                                                   intent: manualIntent)
        } else {
            selection = try resolveSelection(project: project, choices: probed.choices,
                                             loadedRecord: loadedRecord, intent: intent)
        }

        try await GameProjectSelectionValidation.currentProject(project,
                                                               repository: repository)
        try await GameProjectSelectionValidation.currentContext(context, contexts: contexts)
        try Task.checkCancellation()

        let snapshot = GameProjectSelectionSnapshot(
            projectID: project.projectID,
            owner: project.owner,
            environmentID: context.environmentID,
            rootURL: context.rootURL,
            baseRevision: project.revision,
            recordedEngine: project.engine,
            fileCount: project.files.count,
            directoryCount: project.directories.count,
            isEmptyProject: isEmpty,
            choices: probed.choices,
            state: selection.state,
            selectedRoot: selection.root,
            selectedEngine: selection.engine,
            selectionSource: selection.source,
            selectionVerification: selection.verification,
            ambiguities: selection.ambiguities,
            aiRecommendation: ai,
            heuristicRecommendation: heuristic,
            diagnostics: diagnostics,
            persisted: selection.source == .restored)
        return .init(snapshot: snapshot,
                     shouldPersist: selection.shouldPersist,
                     shouldRemove: selection.shouldRemove)
    }

    // MARK: - Discovery and recognition

    private func makeChoices(project: GameStoredProject,
                             context: GameProjectContext)
        async throws -> (choices: [GameProjectSelectionChoice],
                         diagnostics: [GameProjectSelectionDiagnostic]) {
        var diagnostics: [GameProjectSelectionDiagnostic] = []
        let discovered: [GameRunProjectRoot]
        do {
            discovered = try await GameRunProjectDiscovery(contexts: contexts,
                                                          maximumRoots: maximumRoots)
                .discover(context: context, files: project.files)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GameProjectError {
            throw GameProjectSelectionValidation.mapProject(error)
        } catch {
            throw GameProjectFlowError.discovery(
                GameProjectSelectionText.bounded(error))
        }

        var result: [GameProjectSelectionChoice] = []
        for discoveredRoot in discovered {
            try Task.checkCancellation()
            var capabilities: [GameProjectEngineCapability] = []
            var diagnostic = discoveredRoot.diagnostic
            if let discoveryDiagnostic = discoveredRoot.diagnostic {
                diagnostics.append(.init(.discovery, discoveryDiagnostic))
            }
            do {
                let rootURL = try resolvedRootURL(for: discoveredRoot.root,
                                                  projectRoot: context.rootURL)
                let inspection = try GameProjectInspector().inspect(rootURL: rootURL)
                var catalogDiagnostic: String?
                for candidate in inspection.candidates {
                    do {
                        let descriptor = try catalog.descriptor(for: candidate.engine)
                        // Inspection evidence is relative to the selected root.
                        // The snapshot and AI tools promise project-relative
                        // paths, so rebase it before exposing the capability.
                        let evidence = try rebasedEvidence(candidate.evidence,
                                                           root: discoveredRoot.root)
                        capabilities.append(capability(for: candidate.engine,
                                                       evidence: evidence,
                                                       descriptor: descriptor))
                    } catch {
                        catalogDiagnostic = GameProjectSelectionText.bounded(error)
                    }
                }
                if let catalogDiagnostic = catalogDiagnostic {
                    diagnostic = catalogDiagnostic
                    diagnostics.append(.init(.inspection, catalogDiagnostic))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let message = GameProjectSelectionText.bounded(error)
                diagnostic = message
                diagnostics.append(.init(.inspection, message))
            }

            // Discovery already observed these engines. If the second bounded
            // inspection was interrupted by a transient root error, retain the
            // observation instead of silently dropping the user's choices.
            if capabilities.isEmpty, !discoveredRoot.engines.isEmpty {
                for engine in discoveredRoot.engines {
                    guard let descriptor = try? catalog.descriptor(for: engine) else { continue }
                    capabilities.append(capability(for: engine, evidence: [],
                                                   descriptor: descriptor))
                }
            }
            capabilities.sort {
                (rank[$0.engine] ?? Int.max) < (rank[$1.engine] ?? Int.max)
            }
            result.append(.init(root: discoveredRoot.root, engines: capabilities,
                                diagnostic: diagnostic))
        }
        return (choices: result, diagnostics: diagnostics)
    }

    private func rebasedEvidence(_ evidence: [GameEngineEvidence],
                                 root: GameRelativePath?) throws
        -> [GameEngineEvidence] {
        guard let root else { return evidence }
        return try evidence.map { item in
            GameEngineEvidence(
                path: try GameRelativePath(root.value + "/" + item.path.value),
                kind: item.kind, versionHint: item.versionHint)
        }
    }

    private func resolvedRootURL(for root: GameRelativePath?,
                                 projectRoot: URL) throws -> URL {
        let canonical = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard let root = root else { return canonical }
        var componentURL = canonical
        for component in root.value.split(separator: "/") {
            componentURL.appendPathComponent(String(component), isDirectory: true)
            let values = try? componentURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else {
                throw GameProjectFlowError.rootNotAvailable(root)
            }
        }
        let candidate = canonical.appendingPathComponent(root.value, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path == canonical.path
                || candidate.path.hasPrefix(canonical.path + "/") else {
            throw GameProjectFlowError.rootNotAvailable(root)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path,
                                             isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GameProjectFlowError.rootNotAvailable(root)
        }
        return candidate
    }

    private func capability(for engine: GameEngineID,
                            evidence: [GameEngineEvidence],
                            descriptor: GameStarterDescriptor)
        -> GameProjectEngineCapability {
        let starterSource: GameProjectEngineStarterSource
        switch descriptor.templateKind {
        case .static: starterSource = .bundledTemplate
        case .delegated: starterSource = .delegatedProvider
        case .runtimePack: starterSource = .preparedRuntimePack
        }
        let prerequisites = descriptor.prerequisites.map {
            GameProjectPrerequisiteState(kind: $0.kind, name: $0.name,
                                         version: $0.version,
                                         requiredFor: $0.requiredFor,
                                         host: .unverified)
        }
        let paths = Array(Set(evidence.map(\.path))).sorted { $0.value < $1.value }
        let boundedEvidence = Array(evidence.prefix(64))
        return .init(engine: engine,
                     displayName: descriptor.displayName,
                     starterReadiness: descriptor.readiness,
                     starterSource: starterSource,
                     prerequisites: prerequisites,
                     recognizedEvidence: boundedEvidence,
                     recognizedMarkerPaths: paths,
                     preparedRuntimePackPresent: descriptor.runtimePack == nil
                        ? nil : resources.pack(for: engine) != nil,
                     sourceLicense: descriptor.sourceLicense,
                     engineLicense: descriptor.engineLicense)
    }

    // MARK: - Host capability and recommendations

    private func applyProbe(choices: [GameProjectSelectionChoice],
                            context: GameProjectContext)
        async throws -> (choices: [GameProjectSelectionChoice],
                         diagnostics: [GameProjectSelectionDiagnostic]) {
        guard let capabilityProbe = self.capabilityProbe else {
            return (choices: choices, diagnostics: [])
        }
        let engines = Array(Set(choices.flatMap { $0.engines.map(\.engine) }))
            .sorted { (rank[$0] ?? Int.max) < (rank[$1] ?? Int.max) }
        guard !engines.isEmpty else {
            return (choices: choices, diagnostics: [])
        }
        let reports: [GameEngineID: [GameProjectHostPrerequisiteReport]]
        do {
            reports = try await capabilityProbe.reports(engines: engines, context: context)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (choices: choices, diagnostics: [
                .init(.capabilityProbe, GameProjectSelectionText.bounded(error))
            ])
        }
        let updated = choices.map { choice in
            GameProjectSelectionChoice(
                root: choice.root,
                engines: choice.engines.map { capability in
                    capability.applying(reports[capability.engine] ?? [])
                },
                diagnostic: choice.diagnostic)
        }
        return (choices: updated, diagnostics: [])
    }

    private func aiRecommendation(project: GameStoredProject,
                                  choices: [GameProjectSelectionChoice],
                                  isEmptyProject: Bool)
        async throws -> (recommendation: GameProjectAIEngineRecommendation?,
                         diagnostics: [GameProjectSelectionDiagnostic]) {
        guard let recommender = self.recommender else {
            return (recommendation: nil, diagnostics: [])
        }
        let request = GameProjectSelectionRecommendationRequest(
            projectTitle: project.title,
            baseRevision: project.revision,
            recordedEngine: project.engine,
            isEmptyProject: isEmptyProject,
            choices: choices.map {
                GameProjectSelectionChoiceSummary(
                    root: $0.root, engines: $0.engines.map(\.engine))
            })
        let raw: GameProjectAIEngineRecommendation?
        do {
            raw = try await recommender(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (recommendation: nil, diagnostics: [
                .init(.recommendation, GameProjectSelectionText.bounded(error))
            ])
        }
        guard let raw = raw else { return (recommendation: nil, diagnostics: []) }
        guard GameProjectSelectionText.validIdentifier(raw.generatedBy),
              !raw.rationale.isEmpty,
              raw.rationale.utf8.count <= 4_096,
              (try? catalog.descriptor(for: raw.engine)) != nil else {
            return (recommendation: nil, diagnostics: [.init(.recommendation,
                "The host recommendation did not identify a supported engine, root and source.")])
        }
        if isEmptyProject {
            guard raw.root == nil else {
                return (recommendation: nil, diagnostics: [.init(.recommendation,
                    "The host recommended a root that does not exist in an empty project.")])
            }
        } else {
            guard let choice = choices.first(where: { $0.root == raw.root }),
                  choice.engines.contains(where: { $0.engine == raw.engine }) else {
                return (recommendation: nil, diagnostics: [.init(.recommendation,
                    "The host recommendation was not among the recognized roots/engines.")])
            }
        }
        return (recommendation: GameProjectAIEngineRecommendation(
            engine: raw.engine, root: raw.root,
            rationale: GameProjectSelectionText.bounded(raw.rationale, maximum: 4_096),
            generatedBy: GameProjectSelectionText.bounded(raw.generatedBy)), diagnostics: [])
    }

    private func heuristicRecommendation(choices: [GameProjectSelectionChoice],
                                         isEmptyProject: Bool)
        -> GameProjectHeuristicRecommendation? {
        guard !isEmptyProject else { return nil }
        var entries: [(engine: GameEngineID, root: GameRelativePath?,
                       count: Int)] = []
        for choice in choices {
            for capability in choice.engines {
                entries.append((capability.engine, choice.root,
                                capability.recognizedMarkerPaths.count))
            }
        }
        guard let maximum = entries.map({ $0.count }).max() else { return nil }
        let best = entries.filter { $0.count == maximum }.sorted {
            let left = rank[$0.engine] ?? Int.max
            let right = rank[$1.engine] ?? Int.max
            if left != right { return left < right }
            return ($0.root?.value ?? ".") < ($1.root?.value ?? ".")
        }
        guard let first = best.first else { return nil }
        let tied = best.count > 1 ? best.map({ $0.engine }) : []
        return .init(engine: first.engine, root: first.root,
                     evidenceCount: first.count, tiedEngines: tied,
                     reason: tied.isEmpty ? .strongestEvidence : .tieByCatalogOrder)
    }

    // MARK: - Selection state

    private struct Selection {
        let state: GameProjectSelectionState
        let root: GameRelativePath?
        let engine: GameEngineID?
        let source: GameProjectSelectionSource?
        let verification: GameProjectSelectionVerification?
        let ambiguities: [GameProjectSelectionAmbiguity]
        let shouldPersist: Bool
        let shouldRemove: Bool
    }

    private func resolveSelection(project: GameStoredProject,
                                  choices: [GameProjectSelectionChoice],
                                  loadedRecord: GameProjectSelectionRecord?,
                                  intent: GameProjectSelectionIntent?
                                  ) throws -> Selection {
        var ambiguities: [GameProjectSelectionAmbiguity] = []

        if let intent = intent {
            guard let choice = choices.first(where: { $0.root == intent.root }) else {
                throw GameProjectFlowError.rootNotAvailable(intent.root)
            }
            guard choice.engines.contains(where: { $0.engine == intent.engine }) else {
                throw GameProjectFlowError.engineNotRecognized(
                    root: intent.root, engine: intent.engine)
            }
            guard (try? catalog.descriptor(for: intent.engine)) != nil else {
                throw GameProjectFlowError.unknownEngine(intent.engine)
            }
            return .init(state: .confirmed, root: intent.root, engine: intent.engine,
                         source: .explicit, verification: .evidenceMatched,
                         ambiguities: ambiguities,
                         shouldPersist: true, shouldRemove: loadedRecord != nil)
        }

        var shouldRemove = false
        if let record = loadedRecord {
            let recognized = choices.first(where: { $0.root == record.selectedRoot })?
                .engines.contains(where: { $0.engine == record.selectedEngine }) == true
            if record.effectiveVerification == .manualUnverified {
                let rootStillReal = Self.rootExists(project: project, root: record.selectedRoot)
                let engineStillKnown = (try? catalog.descriptor(for: record.selectedEngine)) != nil
                if rootStillReal, engineStillKnown {
                    // Keep the user's manual choice readable/editable. If the
                    // tree later gains a real marker, upgrade the record.
                    let verification: GameProjectSelectionVerification =
                        recognized ? .evidenceMatched : .manualUnverified
                    var restoredAmbiguities: [GameProjectSelectionAmbiguity] = []
                    if verification == .manualUnverified {
                        restoredAmbiguities.append(.manualSelectionUnverified(
                            root: record.selectedRoot, engine: record.selectedEngine))
                    }
                    return .init(state: .confirmed, root: record.selectedRoot,
                                 engine: record.selectedEngine, source: .restored,
                                 verification: verification,
                                 ambiguities: restoredAmbiguities,
                                 shouldPersist: record.baseRevision != project.revision
                                     || verification != record.effectiveVerification,
                                 shouldRemove: false)
                }
            } else if recognized {
                return .init(state: .confirmed, root: record.selectedRoot,
                             engine: record.selectedEngine, source: .restored,
                             verification: .evidenceMatched,
                             ambiguities: [],
                             shouldPersist: record.baseRevision != project.revision,
                             shouldRemove: false)
            }
            shouldRemove = true
            ambiguities.append(.persistedSelectionInvalidated(
                root: record.selectedRoot, engine: record.selectedEngine))
        }

        let isEmpty = project.files.isEmpty && project.directories.isEmpty
        if isEmpty {
            return .init(state: .empty, root: nil, engine: nil, source: nil,
                         verification: nil, ambiguities: ambiguities,
                         shouldPersist: false, shouldRemove: shouldRemove)
        }

        guard !choices.isEmpty else {
            ambiguities.append(.noEngineRecognized(root: nil))
            return .init(state: .unresolved, root: nil, engine: nil, source: nil,
                         verification: nil, ambiguities: ambiguities,
                         shouldPersist: false, shouldRemove: shouldRemove)
        }

        if choices.count > 1 {
            ambiguities.append(.multipleRoots(roots: choices.map(\.root)))
            for choice in choices where choice.engines.count > 1 {
                ambiguities.append(.multipleEngines(
                    root: choice.root, engines: choice.engines.map(\.engine)))
            }
            if choices.allSatisfy({ $0.engines.isEmpty }) {
                ambiguities.append(.noEngineRecognizedAnywhere)
            }
            return .init(state: .ambiguous, root: nil, engine: nil, source: nil,
                         verification: nil, ambiguities: ambiguities,
                         shouldPersist: false, shouldRemove: shouldRemove)
        }

        let only = choices[0]
        if only.engines.count == 1, let engine = only.engines.first?.engine {
            return .init(state: .automatic, root: only.root, engine: engine,
                         source: .automatic, verification: .evidenceMatched,
                         ambiguities: ambiguities,
                         shouldPersist: true, shouldRemove: shouldRemove)
        }
        if only.engines.count > 1 {
            ambiguities.append(.multipleEngines(
                root: only.root, engines: only.engines.map(\.engine)))
            return .init(state: .ambiguous, root: nil, engine: nil, source: nil,
                         verification: nil, ambiguities: ambiguities,
                         shouldPersist: false, shouldRemove: shouldRemove)
        }
        ambiguities.append(.noEngineRecognized(root: only.root))
        return .init(state: .unresolved, root: nil, engine: nil, source: nil,
                     verification: nil, ambiguities: ambiguities,
                     shouldPersist: false, shouldRemove: shouldRemove)
    }

    /// Explicit manual choice. It never pretends recognition: a root without a
    /// catalog marker is recorded as `.manualUnverified` and remains readable
    /// and editable, but `runSelection` stays nil.
    private func resolveManualSelection(project: GameStoredProject,
                                        choices: [GameProjectSelectionChoice],
                                        loadedRecord: GameProjectSelectionRecord?,
                                        intent: GameProjectManualSelectionIntent)
        throws -> Selection {
        guard !project.files.isEmpty || !project.directories.isEmpty else {
            throw GameProjectFlowError.emptyProjectSelection
        }
        try Self.validateRoot(project: project, root: intent.root)
        guard (try? catalog.descriptor(for: intent.engine)) != nil else {
            throw GameProjectFlowError.unknownEngine(intent.engine)
        }
        let recognized = choices.contains { choice in
            choice.root == intent.root
                && choice.engines.contains(where: { $0.engine == intent.engine })
        }
        var ambiguities: [GameProjectSelectionAmbiguity] = []
        if choices.count > 1 {
            ambiguities.append(.multipleRoots(roots: choices.map(\.root)))
        }
        let verification: GameProjectSelectionVerification =
            recognized ? .evidenceMatched : .manualUnverified
        if verification == .manualUnverified {
            ambiguities.append(.manualSelectionUnverified(
                root: intent.root, engine: intent.engine))
        }
        return .init(state: .confirmed, root: intent.root, engine: intent.engine,
                     source: .explicit, verification: verification,
                     ambiguities: ambiguities,
                     shouldPersist: true, shouldRemove: loadedRecord != nil)
    }

    /// Builds an advisory proposal. It performs the same ownership, revision
    /// and discovery validation as a selection, but writes nothing.
    func proposal(project capturedProject: GameStoredProject,
                  context: GameProjectContext,
                  root: GameRelativePath?,
                  engine: GameEngineID,
                  evidencePaths: [GameRelativePath],
                  rationale: String,
                  generatedBy: String) async throws
        -> GameProjectSelectionProposal {
        try Task.checkCancellation()
        try GameProjectSelectionValidation.project(capturedProject, context: context)
        try await GameProjectSelectionValidation.currentContext(context, contexts: contexts)
        try await GameProjectSelectionValidation.currentProject(capturedProject,
                                                               repository: repository)
        let resolution = try await resolve(project: capturedProject, context: context,
                                           loadedRecord: nil, intent: nil)
        let snapshot = resolution.snapshot
        guard !snapshot.isEmptyProject else {
            throw GameProjectFlowError.emptyProjectSelection
        }
        try Self.validateRoot(project: capturedProject, root: root)
        guard (try? catalog.descriptor(for: engine)) != nil else {
            throw GameProjectFlowError.unknownEngine(engine)
        }
        let cleanRationale = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanRationale.isEmpty,
              GameProjectSelectionText.validIdentifier(cleanRationale, maximum: 4_096),
              GameProjectSelectionText.validIdentifier(generatedBy) else {
            throw GameProjectFlowError.proposalInvalid(
                "The proposal needs a bounded rationale and a host-supplied identity.")
        }
        guard evidencePaths.count <= 32 else {
            throw GameProjectFlowError.proposalInvalid(
                "A proposal may cite at most 32 project files.")
        }
        let knownPaths = Set(capturedProject.files.map(\.path))
        for path in evidencePaths where !knownPaths.contains(path) {
            throw GameProjectFlowError.proposalEvidenceInvalid(path)
        }
        let capability = snapshot.choices.first { $0.root == root }?.engines
            .first { $0.engine == engine }
        if let capability {
            let actual = Set(capability.recognizedEvidence.map(\.path))
            for path in evidencePaths where !actual.contains(path) {
                throw GameProjectFlowError.proposalEvidenceInvalid(path)
            }
        }
        let effectiveEvidence: [GameRelativePath]
        if evidencePaths.isEmpty, let capability {
            effectiveEvidence = Array(capability.recognizedEvidence.prefix(16).map(\.path))
        } else {
            effectiveEvidence = evidencePaths
        }
        return .init(projectID: capturedProject.projectID, owner: capturedProject.owner,
                     environmentID: context.environmentID, rootURL: context.rootURL,
                     baseRevision: capturedProject.revision,
                     selectedRoot: root, selectedEngine: engine,
                     verification: capability == nil ? .manualUnverified : .evidenceMatched,
                     rationale: GameProjectSelectionText.bounded(cleanRationale,
                                                                 maximum: 4_096),
                     generatedBy: GameProjectSelectionText.bounded(generatedBy),
                     evidencePaths: effectiveEvidence)
    }

    static func rootExists(project: GameStoredProject, root: GameRelativePath?) -> Bool {
        guard let root else { return true }
        return project.directories.contains(root)
    }

    static func validateRoot(project: GameStoredProject, root: GameRelativePath?) throws {
        guard rootExists(project: project, root: root) else {
            throw GameProjectFlowError.rootNotAvailable(root)
        }
    }
}

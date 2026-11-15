// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Complete AI edit -> atomic revision -> validate -> playtest -> repair loop.
/// Each session stays pinned to its owner, root, environment and current revision.
/// Source history is durable in the repository; a failure never erases a revision.
public actor GameAIEditingService {
    private let repository: FileGameProjectRepository
    private let contexts: any GameAuthoringContextHost
    private let provider: any GameAIEditProvider
    private let validators: [any GameAuthoringValidator]
    private let playback: (any GameAuthoringPlaytestHost)?
    private var leases: [UUID: UUID] = [:]

    public init(repository: FileGameProjectRepository, contexts: any GameAuthoringContextHost,
                provider: any GameAIEditProvider, validators: [any GameAuthoringValidator],
                playback: (any GameAuthoringPlaytestHost)? = nil) {
        self.repository = repository; self.contexts = contexts; self.provider = provider
        self.validators = validators; self.playback = playback
    }

    public func edit(goal: String, context: GameProjectContext, sourcePaths: [GameRelativePath],
                     maximumRepairs: Int = 3, playtest: Bool = true) async throws -> GameAuthoringResult {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, goal.utf8.count <= 65_536,
              (0...8).contains(maximumRepairs), !sourcePaths.isEmpty, sourcePaths.count <= 32,
              Set(sourcePaths).count == sourcePaths.count else { throw GameAuthoringError.invalidSourceSelection }
        guard leases[context.projectID] == nil else { throw GameAuthoringError.busy }
        let lease = UUID(); leases[context.projectID] = lease
        defer { if leases[context.projectID] == lease { leases.removeValue(forKey: context.projectID) } }
        var current = context, revisions: [GameAuthoringRevision] = []
        var diagnostics: [GameAuthoringDiagnostic] = [], observation: GameAuthoringPlaytest?
        for attempt in 0...maximumRepairs {
            try await check(current, lease: lease)
            let before = try await repository.open(current.projectID, owner: current.owner)
            guard before.revision == current.savedRevision else { throw GameProjectError.conflict(expected: current.savedRevision, actual: before.revision) }
            var files: [GameRelativePath: Data] = [:], total = 0
            for path in sourcePaths {
                let bytes = try await repository.read(current.projectID, owner: current.owner, revision: current.savedRevision, path: path)
                guard bytes.count <= 262_144, total <= 2_097_152 - bytes.count else { throw GameProjectError.limitExceeded("AISourceSelection") }
                total += bytes.count; files[path] = bytes
            }
            try await check(current, lease: lease)
            let proposal = try await provider.propose(.init(goal: goal, context: current, files: files,
                diagnostics: diagnostics, playtest: observation, repairAttempt: attempt))
            try await check(current, lease: lease)
            guard proposal.baseRevision == current.savedRevision else { throw GameProjectError.conflict(expected: current.savedRevision, actual: proposal.baseRevision) }
            let saved = try await repository.commit(current.projectID, owner: current.owner, expectedRevision: current.savedRevision, changes: proposal.changes)
            let revised = try await committedContext(saved, previous: current)
            // A committed version remains recoverable even if the host navigated
            // away during the commit; late validation/results cannot target another project.
            try await check(revised, lease: lease)
            revisions.append(.init(before: before.revision, after: saved.revision, summary: proposal.summary,
                differences: Self.diff(before: before, after: saved)))
            current = revised
            let source = source(context: current, project: saved)
            diagnostics = []
            for validator in validators {
                diagnostics += try await validator.validate(source)
                try await check(current, lease: lease)
                guard diagnostics.count <= 1_000 else { throw GameProjectError.limitExceeded("gameDiagnostics") }
            }
            observation = nil
            if playtest, let playback, !diagnostics.contains(where: { $0.severity == .error }) {
                observation = try await playback.playtest(source)
                try await check(current, lease: lease)
                diagnostics += observation?.diagnostics ?? []
            }
            if !diagnostics.contains(where: { $0.severity == .error }) || attempt == maximumRepairs {
                return .init(project: saved, context: current, revisions: revisions, diagnostics: diagnostics, playtest: observation)
            }
        }
        throw GameAuthoringError.repairLimitReached
    }

    public func cancel(projectID: UUID) async {
        leases.removeValue(forKey: projectID)
        await playback?.cancel(projectID: projectID)
    }

    public func rollback(context: GameProjectContext, to revision: String) async throws -> GameStoredProject {
        guard leases[context.projectID] == nil else { throw GameAuthoringError.busy }
        let lease = UUID(); leases[context.projectID] = lease
        defer { if leases[context.projectID] == lease { leases.removeValue(forKey: context.projectID) } }
        try await check(context, lease: lease)
        let saved = try await repository.restore(context.projectID, owner: context.owner, expectedRevision: context.savedRevision, historicalRevision: revision)
        let revised = try await committedContext(saved, previous: context)
        try await check(revised, lease: lease)
        return saved
    }

    /// The ordinary AI tool chain may propose file moves after import. Binary
    /// assets stay in verified storage; organization is reversible as one revision.
    public func organize(context: GameProjectContext, moves: [GameFileRelocation],
                         removeEmptyDirectories: Bool = false) async throws -> GameAuthoringResult {
        guard leases[context.projectID] == nil else { throw GameAuthoringError.busy }
        let lease = UUID(); leases[context.projectID] = lease
        defer { if leases[context.projectID] == lease { leases.removeValue(forKey: context.projectID) } }
        try await check(context, lease: lease)
        let before = try await repository.open(context.projectID, owner: context.owner)
        try await check(context, lease: lease)
        let saved = try await repository.relocateFiles(context.projectID, owner: context.owner,
            expectedRevision: context.savedRevision, moves: moves, removeEmptyDirectories: removeEmptyDirectories)
        let revised = try await committedContext(saved, previous: context)
        try await check(revised, lease: lease)
        return .init(project: saved, context: revised,
            revisions: [.init(before: before.revision, after: saved.revision, summary: "Organize project files", differences: Self.diff(before: before, after: saved))], diagnostics: [], playtest: nil)
    }

    private func check(_ context: GameProjectContext, lease: UUID) async throws {
        try Task.checkCancellation()
        guard leases[context.projectID] == lease else { throw GameAuthoringError.staleSession }
        let actual = try await contexts.currentContext(for: context)
        guard leases[context.projectID] == lease else { throw GameAuthoringError.staleSession }
        try context.validate(current: actual)
    }
    private func committedContext(_ project: GameStoredProject, previous: GameProjectContext) async throws -> GameProjectContext {
        let current = try await contexts.contextAfterCommit(project, previous: previous)
        guard current.projectID == previous.projectID, current.owner == previous.owner,
              current.environmentID == previous.environmentID, current.savedRevision == project.revision,
              project.projectID == current.projectID, project.owner == current.owner else { throw GameProjectError.invalidContext }
        return current
    }
    private func source(context: GameProjectContext, project: GameStoredProject) -> GameAuthoringSource {
        let repository = repository
        return .init(context: context, project: project, read: { path in
            try await repository.read(context.projectID, owner: context.owner, revision: context.savedRevision, path: path)
        })
    }
    public static func diff(before: GameStoredProject, after: GameStoredProject) -> [GameAuthoringDiff] {
        let a = Dictionary(uniqueKeysWithValues: before.files.map { ($0.path, $0) }), b = Dictionary(uniqueKeysWithValues: after.files.map { ($0.path, $0) })
        return Set(a.keys).union(b.keys).sorted { $0.value < $1.value }.compactMap { path in
            guard a[path] != b[path] else { return nil }
            return .init(path: path, beforeSHA256: a[path]?.sha256, afterSHA256: b[path]?.sha256,
                         beforeBytes: a[path]?.bytes, afterBytes: b[path]?.bytes)
        }
    }
}

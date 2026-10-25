#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSkills

struct SkillAuthoringDraft: Sendable {
    var text: String
    var attachments: [AttachmentRef]
    var revision: Int
}

@MainActor
protocol SkillAuthoringDraftManaging: AnyObject {
    func authoringDraft(for id: UUID) -> SkillAuthoringDraft
    func saveAuthoringDraft(_ text: String, attachments: [AttachmentRef], id: UUID) throws -> Int
    func flushAuthoringDrafts() -> Bool
}

extension ComposerDraftStore: SkillAuthoringDraftManaging {
    func authoringDraft(for id: UUID) -> SkillAuthoringDraft {
        let value = entry(for: id)
        return SkillAuthoringDraft(text: value?.text ?? "", attachments: value?.attachments ?? [], revision: value?.revision ?? 0)
    }
    func saveAuthoringDraft(_ text: String, attachments: [AttachmentRef], id: UUID) throws -> Int {
        guard let revision = save(text: text, attachments: attachments, conversationID: id) else {
            throw SkillAuthoringFlowError.draftUnavailable
        }
        return revision
    }
    func flushAuthoringDrafts() -> Bool { flushAndWait() }
}

struct SkillAuthoringModelRoute: Sendable {
    let provider: ProviderProfile
    let model: ModelProfile
    var label: String { model.displayName }
}

struct SkillAuthoringExecutionObservation: Sendable {
    enum State: Sendable { case active, needsUser, paused, terminal, unavailable }
    let state: State
}

@MainActor
protocol SkillAuthoringBackend: AnyObject {
    func resolveAuxiliaryRoute() throws -> SkillAuthoringModelRoute
    func startGeneration(ownerID: UUID, runID: UUID, prompt: String, route: SkillAuthoringModelRoute,
                         attachments: [AttachmentRef]) async throws -> StartedConversationRun
    func prepareImport(urlText: String) async throws -> SkillsCenter.PreparedImport
    func finalBody(ownerID: UUID, runID: UUID) async throws -> String
    func observe(runID: UUID) async throws -> SkillAuthoringExecutionObservation
    func cancel(runID: UUID) async
    func liveRunIDs() async throws -> Set<UUID>
    func installReviewedPackage(_ package: SkillAuthoringPackageDescriptor, at root: URL,
                                modelID: UUID?) async throws -> SkillWorkspaceInstallCommit
}

enum SkillAuthoringFlowError: Error, Equatable {
    case missingOperation, draftUnavailable, auxiliaryUnavailable, sourceUnavailable
    case noFinalReply, runFailed, packageUnavailable, installationMismatch, staleOperation

    var messageKey: String {
        switch self {
        case .missingOperation, .staleOperation: "skills.authoring.error.changed"
        case .draftUnavailable: "skills.authoring.error.draft"
        case .auxiliaryUnavailable: "skills.authoring.error.model"
        case .sourceUnavailable: "skills.authoring.error.source"
        case .noFinalReply, .runFailed: "skills.authoring.error.generation"
        case .packageUnavailable: "skills.authoring.error.package"
        case .installationMismatch: "skills.authoring.error.install"
        }
    }
}

@MainActor
final class SkillAuthoringAppBackend: SkillAuthoringBackend {
    private weak var environment: AppEnvironment?
    init(environment: AppEnvironment) { self.environment = environment }

    func resolveAuxiliaryRoute() throws -> SkillAuthoringModelRoute {
        guard let pair = environment?.conversationCenter.generalAuxiliaryProviderAndModel(),
              pair.0.isEnabled, pair.1.isEnabled, pair.1.supportsGeneralAuxiliaryLLM else {
            throw SkillAuthoringFlowError.auxiliaryUnavailable
        }
        return SkillAuthoringModelRoute(provider: pair.0, model: pair.1)
    }

    func startGeneration(ownerID: UUID, runID: UUID, prompt: String, route: SkillAuthoringModelRoute,
                         attachments: [AttachmentRef]) async throws -> StartedConversationRun {
        guard let environment else { throw SkillAuthoringFlowError.auxiliaryUnavailable }
        try Task.checkCancellation()
        // Both objects were resolved before reserveAttempt. A settings change
        // while launch awaits never swaps the provider or incurs a fallback.
        return try await environment.conversationCenter.startRun(
            goal: prompt, in: ownerID, provider: route.provider, model: route.model,
            attachments: attachments, executionMode: .chat, newRunID: runID,
            startOrigin: .explicitUserAction
        )
    }

    func prepareImport(urlText: String) async throws -> SkillsCenter.PreparedImport {
        guard let environment else { throw SkillAuthoringFlowError.sourceUnavailable }
        return try await environment.skillsCenter.prepareImportForReview(urlText: urlText)
    }

    func finalBody(ownerID: UUID, runID: UUID) async throws -> String {
        guard let environment,
              let run = try await environment.runStore.run(id: runID),
              run.conversationID == ownerID, run.state == "completed" else {
            throw SkillAuthoringFlowError.runFailed
        }
        let events = try await environment.runStore.recentEvents(runID: runID, limit: 32)
        guard let terminal = events.last(where: { $0.kind == .terminal }),
              let payload = try JSONSerialization.jsonObject(with: Data(terminal.payloadJSON.utf8)) as? [String: String],
              let reason = payload["stopReason"],
              [AgentEvent.StopReason.endTurn.rawValue, AgentEvent.StopReason.stopSequence.rawValue].contains(reason),
              let raw = payload["finalMessageID"], let messageID = UUID(uuidString: raw),
              let body = try await SQLiteRunReplyReader(database: environment.database).provenFinalReplyText(
                runID: runID, conversationID: ownerID, messageID: messageID), !body.isEmpty else {
            throw SkillAuthoringFlowError.noFinalReply
        }
        return body
    }

    func observe(runID: UUID) async throws -> SkillAuthoringExecutionObservation {
        guard let environment, let run = try await environment.runStore.run(id: runID) else { return .init(state: .unavailable) }
        switch run.state {
        case "preparing", "streamingModel", "executingTool", "committingResults", "compacting", "verifying", "reconnecting":
            return .init(state: .active)
        case "waitingApproval", "waitingUser", "reviewingApproval": return .init(state: .needsUser)
        case "paused", "awaitingDependency", "waitingDependency": return .init(state: .paused)
        default: return .init(state: RunStateLocalizer.isTerminal(run.state) ? .terminal : .unavailable)
        }
    }

    func cancel(runID: UUID) async { await environment?.conversationCenter.cancel(runID: runID) }

    func liveRunIDs() async throws -> Set<UUID> {
        guard let environment else { return [] }
        let runs = try await environment.runStore.nonTerminalRuns()
        return Set(runs.filter { environment.conversationCenter.hasLiveOwner(runID: $0.id) }.map(\.id))
    }

    func installReviewedPackage(_ package: SkillAuthoringPackageDescriptor, at root: URL,
                                modelID: UUID?) async throws -> SkillWorkspaceInstallCommit {
        guard let environment else { throw SkillAuthoringFlowError.installationMismatch }
        let scheme = package.origin == .imported ? "floe-folder" : "floe-creator"
        let source = package.origin == .imported
            ? package.sourceURL ?? URL(string: "\(scheme)://authoring/\(package.ownerID.uuidString)/\(package.snapshotID.uuidString)")!
            : URL(string: "\(scheme)://authoring/\(package.ownerID.uuidString)/\(package.snapshotID.uuidString)")!
        let originalDigest: String?
        if let originalID = package.parentSnapshotID {
            let storage = SkillAuthoringPackageStorage(root: root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
            originalDigest = try storage.descriptor(ownerID: package.ownerID, id: originalID).digest
        } else { originalDigest = package.origin == .imported ? package.digest : nil }
        return try await environment.skillsCenter.installReviewedAuthoringPackage(
            at: root, sourceURL: source, expectedCanonicalDigest: package.digest,
            originalCanonicalDigest: originalDigest,
            authoringModelID: package.origin == .imported ? nil : modelID,
            gitHubBinding: package.origin == .imported ? package.gitHubBinding : nil
        )
    }
}
#endif

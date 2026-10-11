// FloeAppTests — T5 shared design AI tools: REAL tool → T3 service contract.
//
// These tests drive the PRODUCTION tool runners (`design.*`, registered by
// `registerDesignAgentTools`) against the REAL `DesignTargetService`,
// `DesignOwnerWorkflow` and `DesignWorkflowEngine`. Only the boundary ports
// (workspace file access, chat attachment storage, owner source commit,
// result publication destination) are deterministic in-memory doubles —
// the workflow, validation, authorization, idempotency, CAS, outbox and
// publication-settlement code is the shipping implementation.
//
// Coverage: permitted/denied targets, spoofed provenance (model-supplied
// origin, cross-task chat owner), revision-bound freeze/propose/compare,
// trusted single-use confirmation (mode + exact candidate/base/revision),
// duplicate operations, late manual edits, source deletion, in-place
// save/reopen, original-task-only notification, cross-run adoption,
// canvas compatibility pointers and the legacy canvas.design* wrappers.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp
import FloeCore
import FloeTools

// MARK: - Deterministic boundary doubles (ports only)

private final class RunTaskMap: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: UUID] = [:]

    func bind(run: UUID, task: UUID) {
        lock.lock(); defer { lock.unlock() }
        tasks[run] = task
    }

    func task(for run: UUID) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return tasks[run]
    }
}

private struct SeededFile {
    let data: Data
    let name: String
}

private final class FileOwnerFixture: @unchecked Sendable {
    let workspaceID = UUID()
    private let lock = NSLock()
    private var files: [String: SeededFile] = [:]
    private var runWorkspaces: [UUID: UUID] = [:]

    func seed(_ reference: String, data: Data, name: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        files[reference] = SeededFile(
            data: data, name: name ?? (reference as NSString).lastPathComponent)
    }

    func overwrite(_ reference: String, data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard let current = files[reference] else { return }
        files[reference] = SeededFile(data: data, name: current.name)
    }

    func remove(_ reference: String) {
        lock.lock(); defer { lock.unlock() }
        files[reference] = nil
    }

    func read(_ reference: String) -> SeededFile? {
        lock.lock(); defer { lock.unlock() }
        return files[reference]
    }

    func bind(run: UUID, workspace: UUID) {
        lock.lock(); defer { lock.unlock() }
        runWorkspaces[run] = workspace
    }

    func workspace(forRun run: UUID) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return runWorkspaces[run]
    }
}

private struct FixtureWorkspaceFilePort: DesignWorkspaceFilePort {
    let fixture: FileOwnerFixture

    private func format(_ reference: String) -> String {
        (reference as NSString).pathExtension.lowercased()
    }

    func resolve(
        workspaceID: String, reference: String,
        environmentID: String?, runID: UUID?
    ) async throws -> DesignResolvedFile {
        guard let workspaceUUID = UUID(uuidString: workspaceID),
              fixture.workspace(forRun: runID ?? UUID()) == workspaceUUID else {
            throw DesignTargetError.notAuthorized("the run's task does not own this workspace")
        }
        guard let file = fixture.read(reference) else {
            throw DesignTargetError.notFound("workspace file '\(reference)' does not exist")
        }
        let sha = FloeDigest.sha256Hex(file.data)
        return DesignResolvedFile(
            data: file.data,
            format: format(reference),
            displayName: file.name,
            contentSHA256: sha,
            baseRevisionToken: "workspace:\(workspaceID.lowercased()):sha:\(sha):mtime:1",
            allowsInPlaceUpdate: true)
    }

    func isAuthorized(
        workspaceID: String, reference: String,
        environmentID: String?, runID: UUID?
    ) async -> Bool {
        guard let workspaceUUID = UUID(uuidString: workspaceID),
              let bound = fixture.workspace(forRun: runID ?? UUID()),
              bound == workspaceUUID,
              (try? DesignTargetValidation.relativeReference(reference)) != nil else {
            return false
        }
        return true
    }

    func exists(workspaceID: String, reference: String, environmentID: String?) async -> Bool {
        fixture.read(reference) != nil
    }
}

private struct FixtureCommitPort: DesignOwnerCommitPort {
    let fixture: FileOwnerFixture

    static func frozenSHA(from token: String) -> String? {
        let components = token.components(separatedBy: ":")
        guard let index = components.firstIndex(of: "sha"), index + 1 < components.count else {
            return nil
        }
        return components[index + 1]
    }

    private func token(_ workspaceID: String, _ sha: String) -> String {
        "workspace:\(workspaceID.lowercased()):sha:\(sha):mtime:2"
    }

    func canCommit(_ target: DesignTarget) -> Bool {
        target.kind == .fileDocument
    }

    func commit(
        target: DesignTarget, reference: String, bytes: Data,
        format: String, baseRevisionToken: String
    ) async throws -> String {
        let proposed = FloeDigest.sha256Hex(bytes)
        guard let current = fixture.read(reference)?.data else {
            throw DesignOwnerCommitError.notWritten("the workspace file moved or was deleted")
        }
        let currentSHA = FloeDigest.sha256Hex(current)
        if currentSHA == proposed {
            return token(target.ownerID, proposed)
        }
        guard let frozen = Self.frozenSHA(from: baseRevisionToken),
              frozen.lowercased() == currentSHA else {
            throw DesignOwnerCommitError.notWritten(
                "workspace file changed since the frozen base")
        }
        fixture.overwrite(reference, data: bytes)
        guard let readback = fixture.read(reference)?.data,
              FloeDigest.sha256Hex(readback) == proposed else {
            throw DesignOwnerCommitError.unknown(
                "workspace readback did not verify the proposed bytes")
        }
        return token(target.ownerID, proposed)
    }

    func verify(
        target: DesignTarget, reference: String,
        proposedContentSHA256: String, baseRevisionToken: String
    ) async throws -> DesignCommitVerification {
        guard let current = fixture.read(reference)?.data else { return .missing }
        let sha = FloeDigest.sha256Hex(current)
        if sha == proposedContentSHA256.lowercased() { return .matchesProposed }
        if let frozen = Self.frozenSHA(from: baseRevisionToken),
           frozen.lowercased() == sha {
            return .matchesBase
        }
        return .diverged(actualSHA256: sha)
    }
}

private final class ChatFixture: @unchecked Sendable {
    let conversationID: UUID
    let messageID = UUID()
    let attachmentID = "att-original"
    private let lock = NSLock()
    private var data: Data = Data("# Original\n".utf8)
    private var runTasks: [UUID: UUID] = [:]

    /// The chat fixture's task identity MUST be the same durable task the
    /// tool-level run→task lookup returns: `authorizedTarget` rejects a chat
    /// owner that is not the live run task, and the attachment port then
    /// re-checks the same identity.
    init(conversationID: UUID = UUID()) {
        self.conversationID = conversationID
    }

    func bind(run: UUID, task: UUID) {
        lock.lock(); defer { lock.unlock() }
        runTasks[run] = task
    }

    func task(for run: UUID) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return runTasks[run]
    }

    func bytes() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

private struct FixtureChatAttachmentPort: DesignChatAttachmentPort {
    let fixture: ChatFixture
    static let format = "md"

    private func authorized(
        conversationID: String, messageID: String, attachmentID: String, runID: UUID?
    ) -> Bool {
        // Trusted in-app UI (nil run) skips ONLY the run→task binding; the
        // attachment ownership checks below still apply. A run must be bound
        // to the attachment's own task.
        if let runID {
            guard let task = fixture.task(for: runID),
                  task.uuidString.caseInsensitiveCompare(conversationID) == .orderedSame else {
                return false
            }
        }
        guard conversationID.caseInsensitiveCompare(fixture.conversationID.uuidString) == .orderedSame else {
            return false
        }
        if !messageID.isEmpty,
           messageID.caseInsensitiveCompare(fixture.messageID.uuidString) != .orderedSame {
            return false
        }
        return attachmentID == fixture.attachmentID
    }

    func resolveAttachment(
        conversationID: String, messageID: String, attachmentID: String, runID: UUID?
    ) async throws -> DesignChatAttachment {
        guard authorized(
            conversationID: conversationID, messageID: messageID,
            attachmentID: attachmentID, runID: runID
        ) else {
            throw DesignTargetError.notAuthorized(
                "attachment is not owned by the run's task")
        }
        let data = fixture.bytes()
        let sha = FloeDigest.sha256Hex(data)
        return DesignChatAttachment(
            data: data,
            format: Self.format,
            displayName: "brief.md",
            contentSHA256: sha,
            baseRevisionToken: "attachment:\(attachmentID):sha:\(sha)",
            conversationID: conversationID)
    }

    func attachmentIsAccessible(
        conversationID: String, messageID: String, attachmentID: String, runID: UUID?
    ) async -> Bool {
        authorized(conversationID: conversationID, messageID: messageID,
                   attachmentID: attachmentID, runID: runID)
    }
}

/// Idempotent destination stub for an immutable owner's adopted result. The
/// SAME `publicationKey` always returns the same receipt and never records a
/// second destination identity (mirrors the production port's contract).
private final class RecordingPublicationPort: DesignResultPublicationPort, @unchecked Sendable {
    private let lock = NSLock()
    private var receipts: [String: DesignResultPublicationReceipt] = [:]
    private var publications: [DesignResultPublication] = []

    var publicationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return publications.count
    }

    var uniqueReceiptCount: Int {
        lock.lock(); defer { lock.unlock() }
        return receipts.count
    }

    var lastPublication: DesignResultPublication? {
        lock.lock(); defer { lock.unlock() }
        return publications.last
    }

    func publish(
        _ publication: DesignResultPublication
    ) async throws -> DesignResultPublicationReceipt {
        lock.withLock {
            publications.append(publication)
            if let existing = receipts[publication.publicationKey] {
                return existing
            }
            let receipt = DesignResultPublicationReceipt(
                identifier: "result-\(publication.publicationKey.prefix(12))",
                destination: "\(publication.target.kind.rawValue):\(publication.target.ownerID)",
                contentSHA256: publication.contentSHA256)
            receipts[publication.publicationKey] = receipt
            return receipt
        }
    }
}

private final class RecordingDecisionSink: @unchecked Sendable {
    struct Event: Sendable {
        let conversationID: UUID
        let candidateID: UUID
        let decision: String
    }

    private let lock = NSLock()
    private var events: [Event] = []

    var recorded: [Event] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    func record(_ conversationID: UUID, _ candidateID: UUID, _ decision: String) {
        lock.lock(); defer { lock.unlock() }
        events.append(Event(
            conversationID: conversationID, candidateID: candidateID, decision: decision))
    }
}

// MARK: - Harness

@Suite("Design typed owner tools", .serialized)
@MainActor
struct DesignAgentToolTests {
    private struct Harness {
        let environment: AppEnvironment
        let fixture: FileOwnerFixture
        let chat: ChatFixture
        let runTasks: RunTaskMap
        let targets: DesignTargetService
        let workflow: DesignOwnerWorkflow
        let registry: ToolRunnerRegistry
        let grants: DesignOwnerAuthorization
        let sink: RecordingDecisionSink
        let publication: RecordingPublicationPort
        let runID: UUID
        let conversationID: UUID
    }

    private func makeHarness() async throws -> Harness {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let fixture = FileOwnerFixture()
        let runID = UUID()
        let conversationID = UUID()
        let chat = ChatFixture(conversationID: conversationID)
        let runTasks = RunTaskMap()
        let sink = RecordingDecisionSink()
        let publication = RecordingPublicationPort()
        let grants = DesignOwnerAuthorization()
        runTasks.bind(run: runID, task: conversationID)
        fixture.bind(run: runID, workspace: fixture.workspaceID)
        chat.bind(run: runID, task: conversationID)
        let targets = DesignTargetService(adapters: [
            DesignFileOwnerAdapter(port: FixtureWorkspaceFilePort(fixture: fixture)),
            DesignChatAttachmentOwnerAdapter(port: FixtureChatAttachmentPort(fixture: chat))
        ])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t5-design-\(UUID().uuidString.lowercased())", isDirectory: true)
        let outbox = DesignDecisionOutbox(fileURL: root.appendingPathComponent("outbox.json"))
        let workflow = DesignOwnerWorkflow(
            targets: targets,
            store: ArtifactDesignOwnerStore(root: root),
            payloads: ArtifactOwnerPayloadStore(root: root),
            commitPorts: [.fileDocument: FixtureCommitPort(fixture: fixture)],
            outbox: outbox,
            defaultSink: { conversation, candidate, decision, _, _ in
                sink.record(conversation, candidate, decision)
            },
            defaultPublication: publication)
        let registry = ToolRunnerRegistry()
        registerDesignAgentTools(
            capabilities: { environment.designAdapterCenter.capabilityRegistry() },
            adapters: environment.designAdapterCenter,
            environment: environment,
            authorize: { _, _ in false },
            decisionSink: { conversation, candidate, decision, _, _ in
                sink.record(conversation, candidate, decision)
            },
            decisionOutbox: outbox,
            targets: targets,
            ownerWorkflow: workflow,
            ownerAdoptionGrants: grants,
            runTask: { run in runTasks.task(for: run) },
            registry: registry)
        return Harness(
            environment: environment, fixture: fixture, chat: chat, runTasks: runTasks,
            targets: targets, workflow: workflow, registry: registry, grants: grants,
            sink: sink, publication: publication,
            runID: runID, conversationID: conversationID)
    }

    // MARK: helpers

    private func run(
        _ harness: Harness, tool: String, arguments: [String: Any],
        runID: UUID? = nil, conversationID: UUID? = nil
    ) async throws -> ToolExecutionOutput {
        let runner = try #require(harness.registry.runner(named: tool))
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        let context = ToolContext(
            runID: runID ?? harness.runID,
            cancellation: CancellationToken(),
            conversationID: conversationID ?? harness.conversationID)
        return try await runner.run(data, context)
    }

    private func json(_ output: ToolExecutionOutput) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(output.summary.utf8))
        return try #require(object as? [String: Any])
    }

    private func fileTarget(_ harness: Harness, _ reference: String) -> [String: Any] {
        [
            "kind": "fileDocument",
            "ownerID": harness.fixture.workspaceID.uuidString.lowercased(),
            "sourceID": reference
        ]
    }

    private func chatTarget(_ harness: Harness, owner: UUID? = nil) -> [String: Any] {
        [
            "kind": "chatAttachment",
            "ownerID": (owner ?? harness.chat.conversationID).uuidString.lowercased(),
            "documentID": harness.chat.messageID.uuidString,
            "sourceID": harness.chat.attachmentID
        ]
    }

    private func writeArtifactText(_ text: String, ext: String = "md") throws -> String {
        let root = try FloeArtifactStore.root()
        let name = "ChangeArtifacts/t5-\(UUID().uuidString.lowercased()).\(ext)"
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        return name
    }

    private func stableKey(_ kind: DesignTargetKind, owner: String, document: String, source: String) -> String {
        DesignTarget(
            kind: kind, ownerID: owner, documentID: document, sourceID: source).stableKey
    }

    // MARK: 1. permitted / denied targets

    @Test func resolveTargetPermitsScopedFileAndRejectsAbsoluteOrTraversal() async throws {
        let harness = try await makeHarness()
        harness.fixture.seed("specs/home.md", data: Data("# Home\n".utf8))
        // Permitted: workspace-relative, run bound to the workspace.
        let output = try await run(harness, tool: "design.resolveTarget",
                                   arguments: ["target": fileTarget(harness, "specs/home.md")])
        #expect(output.exitStatus == 0)
        let payload = try json(output)
        #expect(payload["contentType"] as? String == DesignContentType.notes.rawValue)
        #expect(payload["format"] as? String == "md")
        #expect((payload["baseRevisionToken"] as? String)?.isEmpty == false)
        #expect(payload["contains"] as? Bool == true)
        // Denied: absolute path and traversal are never file authority.
        for bad in ["/etc/passwd", "../secret.md", "a//b"] {
            let denied = try await run(harness, tool: "design.resolveTarget",
                                       arguments: ["target": fileTarget(harness, bad)])
            #expect(denied.exitStatus == 2)
            let deniedJSON = try json(denied)
            #expect(deniedJSON["contains"] as? Bool == false)
        }
        // Denied: a run whose task does not own the workspace.
        let otherRun = UUID()
        let unauthorized = try await run(
            harness, tool: "design.resolveTarget",
            arguments: ["target": fileTarget(harness, "specs/home.md")],
            runID: otherRun, conversationID: UUID())
        #expect(unauthorized.exitStatus == 2)
    }

    @Test func modelSuppliedOriginCannotWidenTheTask() async throws {
        let harness = try await makeHarness()
        harness.fixture.seed("specs/home.md", data: Data("# Home\n".utf8))
        var spoofed = fileTarget(harness, "specs/home.md")
        spoofed["originConversationID"] = UUID().uuidString.lowercased()
        await #expect(throws: (any Error).self) {
            _ = try await run(harness, tool: "design.resolveTarget", arguments: ["target": spoofed])
        }
        // A chat target whose owner is not the run's task is rejected, even
        // with the correct message/attachment shape.
        let foreignOwner = UUID()
        await #expect(throws: (any Error).self) {
            _ = try await run(
                harness, tool: "design.resolveTarget",
                arguments: ["target": chatTarget(harness, owner: foreignOwner)])
        }
    }

    // MARK: 2. freeze → propose → compare → trusted adoption (chat / immutable)

    @Test func chatCyclePublishesOnlyWithTrustedConfirmationAndIdempotently() async throws {
        let harness = try await makeHarness()
        let target = chatTarget(harness)
        let stable = stableKey(
            .chatAttachment, owner: harness.chat.conversationID.uuidString.lowercased(),
            document: harness.chat.messageID.uuidString, source: harness.chat.attachmentID)

        // freeze
        var output = try await run(harness, tool: "design.freezeInput", arguments: [
            "target": target, "operationID": "chat-freeze"
        ])
        #expect(output.exitStatus == 0)
        var payload = try json(output)
        var design = try #require(payload["design"] as? [String: Any])
        var artifacts = try #require(design["artifacts"] as? [[String: Any]])
        let artifactID = try #require(artifacts.first?["artifactID"] as? String)
        let ownerRevisionAfterFreeze = try #require(payload["ownerRevision"] as? Int64)

        // propose from real app-storage bytes
        let proposePath = try writeArtifactText("# Adopted\n")
        output = try await run(harness, tool: "design.propose", arguments: [
            "target": target,
            "operationID": "chat-propose",
            "expectedOwnerRevision": ownerRevisionAfterFreeze,
            "artifactID": artifactID,
            "payloadRelativePath": proposePath,
            "summary": "adopt the improved brief"
        ])
        #expect(output.exitStatus == 0)
        payload = try json(output)
        let candidateID = try #require(payload["candidateID"] as? String)
        let proposedRevisionID = try #require(payload["proposedRevisionID"] as? String)
        let baseRevisionID = try #require(payload["baseRevisionID"] as? String)
        let ownerRevisionAfterPropose = try #require(payload["ownerRevision"] as? Int64)

        // compare: bounded diff honesty fields are present
        output = try await run(harness, tool: "design.compare", arguments: [
            "target": target, "candidateID": candidateID
        ])
        let comparison = try json(output)
        #expect(comparison["changed"] as? Bool == true)
        #expect(comparison["diffTruncated"] is Bool)
        #expect(comparison["diffNote"] is String)
        #expect((comparison["diff"] as? [String])?.isEmpty == false)

        // adopt WITHOUT a user confirmation: rejected before any state change
        let unmintedGrant = UUID().uuidString.lowercased()
        await #expect(throws: (any Error).self) {
            _ = try await run(harness, tool: "design.adopt", arguments: [
                "target": target, "operationID": "chat-adopt",
                "expectedOwnerRevision": ownerRevisionAfterPropose,
                "candidateID": candidateID, "grantID": unmintedGrant
            ])
        }
        #expect(harness.publication.publicationCount == 0)

        // user confirms the EXACT candidate/base/proposed revision/mode
        let grantID = await harness.grants.issueOwnerAdoption(
            targetStableKey: stable, candidateID: candidateID,
            baselineRevisionID: baseRevisionID, proposedRevisionID: proposedRevisionID,
            mode: .updateOriginal, scope: .aiTool)

        output = try await run(harness, tool: "design.adopt", arguments: [
            "target": target, "operationID": "chat-adopt",
            "expectedOwnerRevision": ownerRevisionAfterPropose,
            "candidateID": candidateID, "grantID": grantID
        ])
        #expect(output.exitStatus == 0)
        payload = try json(output)
        #expect(payload["operationReplayed"] as? Bool == false)
        #expect(payload["resultPublication"] as? String == "published")
        #expect(payload["decisionDelivery"] as? String == "delivered")
        let receipt = try #require(payload["resultReceipt"] as? [String: Any])
        #expect((receipt["destination"] as? String)?
            .hasPrefix("chatAttachment:\(harness.chat.conversationID.uuidString.lowercased())") == true)
        #expect(harness.publication.uniqueReceiptCount == 1)
        // The original attachment is untouched.
        #expect(harness.chat.bytes() == Data("# Original\n".utf8))
        // The durable event went to the ORIGINATING task only.
        #expect(harness.sink.recorded.count == 1)
        #expect(harness.sink.recorded.first?.conversationID == harness.chat.conversationID)
        #expect(harness.sink.recorded.first?.decision == "adopted")

        // replay: same recorded result, no second publication, no second event,
        // and the burned grant is not required again.
        output = try await run(harness, tool: "design.adopt", arguments: [
            "target": target, "operationID": "chat-adopt",
            "expectedOwnerRevision": ownerRevisionAfterPropose,
            "candidateID": candidateID, "grantID": grantID
        ])
        payload = try json(output)
        #expect(payload["operationReplayed"] as? Bool == true)
        #expect(harness.publication.uniqueReceiptCount == 1)
        #expect(harness.sink.recorded.count == 1)
        let grantStillValid = await harness.grants.validateOwnerAdoption(
            grantID: grantID, targetStableKey: stable, candidateID: candidateID,
            baselineRevisionID: baseRevisionID, proposedRevisionID: proposedRevisionID,
            mode: .updateOriginal, scope: .aiTool)
        #expect(grantStillValid == false)
    }

    @Test func grantBindsExactModeAndCallerScope() async throws {
        let harness = try await makeHarness()
        let target = chatTarget(harness)
        let stable = stableKey(
            .chatAttachment, owner: harness.chat.conversationID.uuidString.lowercased(),
            document: harness.chat.messageID.uuidString, source: harness.chat.attachmentID)
        _ = try await run(harness, tool: "design.freezeInput", arguments: [
            "target": target, "operationID": "mode-freeze"
        ])
        var output = try await run(harness, tool: "design.getState", arguments: ["target": target])
        var payload = try json(output)
        var design = try #require(payload["design"] as? [String: Any])
        var artifacts = try #require(design["artifacts"] as? [[String: Any]])
        let artifactID = try #require(artifacts.first?["artifactID"] as? String)
        let ownerRevision = try #require(payload["ownerRevision"] as? Int64)
        let proposePath = try writeArtifactText("# Mode\n")
        output = try await run(harness, tool: "design.propose", arguments: [
            "target": target, "operationID": "mode-propose",
            "expectedOwnerRevision": ownerRevision, "artifactID": artifactID,
            "payloadRelativePath": proposePath, "summary": "mode probe"
        ])
        payload = try json(output)
        let candidateID = try #require(payload["candidateID"] as? String)
        let proposedRevisionID = try #require(payload["proposedRevisionID"] as? String)
        let baseRevisionID = try #require(payload["baseRevisionID"] as? String)
        let ownerRevisionAfterPropose = try #require(payload["ownerRevision"] as? Int64)

        // A grant minted for updateOriginal cannot be replayed as a variant.
        let grantID = await harness.grants.issueOwnerAdoption(
            targetStableKey: stable, candidateID: candidateID,
            baselineRevisionID: baseRevisionID, proposedRevisionID: proposedRevisionID,
            mode: .updateOriginal, scope: .aiTool)
        await #expect(throws: (any Error).self) {
            _ = try await run(harness, tool: "design.adopt", arguments: [
                "target": target, "operationID": "mode-adopt",
                "expectedOwnerRevision": ownerRevisionAfterPropose,
                "candidateID": candidateID, "mode": "variant", "grantID": grantID
            ])
        }
        #expect(harness.publication.publicationCount == 0)
        let originalModeGrantValid = await harness.grants.validateOwnerAdoption(
            grantID: grantID, targetStableKey: stable, candidateID: candidateID,
            baselineRevisionID: baseRevisionID, proposedRevisionID: proposedRevisionID,
            mode: .updateOriginal, scope: .aiTool)
        #expect(originalModeGrantValid == true)

        // A trustedUI-scoped confirmation is a different caller surface.
        let uiGrant = await harness.grants.issueOwnerAdoption(
            targetStableKey: stable, candidateID: candidateID,
            baselineRevisionID: baseRevisionID, proposedRevisionID: proposedRevisionID,
            mode: .updateOriginal, scope: .trustedUI)
        await #expect(throws: (any Error).self) {
            _ = try await run(harness, tool: "design.adopt", arguments: [
                "target": target, "operationID": "mode-adopt",
                "expectedOwnerRevision": ownerRevisionAfterPropose,
                "candidateID": candidateID, "grantID": uiGrant
            ])
        }
        #expect(harness.publication.publicationCount == 0)
    }

    // MARK: 3. file owner: in-place cycle, late edit, duplicates, deletion

    @Test func fileInPlaceAdoptionCommitsAndSaveReopenVerifies() async throws {
        let harness = try await makeHarness()
        harness.fixture.seed("docs/spec.md", data: Data("# Base\n".utf8))
        let target = fileTarget(harness, "docs/spec.md")

        var output = try await run(harness, tool: "design.freezeInput", arguments: [
            "target": target, "operationID": "file-freeze"
        ])
        var payload = try json(output)
        var design = try #require(payload["design"] as? [String: Any])
        var artifacts = try #require(design["artifacts"] as? [[String: Any]])
        let artifactID = try #require(artifacts.first?["artifactID"] as? String)
        var ownerRevision = try #require(payload["ownerRevision"] as? Int64)
        // In-place adoption must carry the frozen base token from the freeze
        // (the optimistic gate); the tool never invents one.
        let frozenBaseToken = try #require(
            (payload["source"] as? [String: Any])?["baseRevisionToken"] as? String)
        var adoptTarget = target
        adoptTarget["revision"] = frozenBaseToken

        let proposed = Data("# Adopted\n".utf8)
        let proposePath = try writeArtifactText(String(decoding: proposed, as: UTF8.self))
        output = try await run(harness, tool: "design.propose", arguments: [
            "target": target, "operationID": "file-propose",
            "expectedOwnerRevision": ownerRevision, "artifactID": artifactID,
            "payloadRelativePath": proposePath, "summary": "adopt spec"
        ])
        payload = try json(output)
        let candidateID = try #require(payload["candidateID"] as? String)
        let proposedRevisionID = try #require(payload["proposedRevisionID"] as? String)
        let baseRevisionID = try #require(payload["baseRevisionID"] as? String)
        ownerRevision = try #require(payload["ownerRevision"] as? Int64)

        let stable = stableKey(
            .fileDocument, owner: harness.fixture.workspaceID.uuidString.lowercased(),
            document: "", source: "docs/spec.md")
        let grantID = await harness.grants.issueOwnerAdoption(
            targetStableKey: stable, candidateID: candidateID,
            baselineRevisionID: baseRevisionID, proposedRevisionID: proposedRevisionID,
            mode: .updateOriginal, scope: .aiTool)

        output = try await run(harness, tool: "design.adopt", arguments: [
            "target": adoptTarget, "operationID": "file-adopt",
            "expectedOwnerRevision": ownerRevision, "candidateID": candidateID,
            "grantID": grantID
        ])
        payload = try json(output)
        #expect(payload["resultPublication"] as? String == "notRequired")
        #expect((payload["committedRevisionToken"] as? String)?.isEmpty == false)
        #expect(payload["decisionDelivery"] as? String == "delivered")
        // The authorized original file was updated in place, verified.
        #expect(harness.fixture.read("docs/spec.md")?.data == proposed)
        // Save/reopen: export re-verifies retained bytes with the real parser.
        design = try #require(payload["design"] as? [String: Any])
        artifacts = try #require(design["artifacts"] as? [[String: Any]])
        let artifact = try #require(artifacts.first { ($0["artifactID"] as? String) == artifactID })
        let currentRevisionID = try #require(artifact["currentRevisionID"] as? String)
        output = try await run(harness, tool: "design.exportVerified", arguments: [
            "target": target, "artifactID": artifactID, "revisionID": currentRevisionID
        ])
        #expect(output.exitStatus == 0)
        let export = try json(output)
        #expect(export["exported"] as? Bool == true)
        #expect(export["contentSHA256"] as? String == FloeDigest.sha256Hex(proposed))
        let path = try #require(export["path"] as? String)
        let exportedURL = try FloeArtifactStore.root().appendingPathComponent(path)
        #expect(try Data(contentsOf: exportedURL) == proposed)
    }

    @Test func lateManualEditInvalidatesPendingCandidate() async throws {
        let harness = try await makeHarness()
        harness.fixture.seed("docs/spec.md", data: Data("# Base\n".utf8))
        let target = fileTarget(harness, "docs/spec.md")
        var output = try await run(harness, tool: "design.freezeInput", arguments: [
            "target": target, "operationID": "late-freeze"
        ])
        var payload = try json(output)
        var design = try #require(payload["design"] as? [String: Any])
        var artifacts = try #require(design["artifacts"] as? [[String: Any]])
        let artifactID = try #require(artifacts.first?["artifactID"] as? String)
        let inputRevisionID = try #require(payload["inputRevisionID"] as? String)
        var ownerRevision = try #require(payload["ownerRevision"] as? Int64)
        let frozenBaseToken = try #require(
            (payload["source"] as? [String: Any])?["baseRevisionToken"] as? String)
        var adoptTarget = target
        adoptTarget["revision"] = frozenBaseToken

        let proposePath = try writeArtifactText("# Candidate\n")
        output = try await run(harness, tool: "design.propose", arguments: [
            "target": target, "operationID": "late-propose",
            "expectedOwnerRevision": ownerRevision, "artifactID": artifactID,
            "payloadRelativePath": proposePath, "summary": "candidate"
        ])
        payload = try json(output)
        let candidateID = try #require(payload["candidateID"] as? String)
        let proposedRevisionID = try #require(payload["proposedRevisionID"] as? String)
        let baseRevisionID = try #require(payload["baseRevisionID"] as? String)
        ownerRevision = try #require(payload["ownerRevision"] as? Int64)

        // The user edits the file manually through the shared edit path:
        // the workspace bytes change AND the edit is recorded as a revision
        // (the real manual-save path does both).
        let manual = Data("# Manual\n".utf8)
        harness.fixture.overwrite("docs/spec.md", data: manual)
        let manualPath = try writeArtifactText("# Manual\n")
        output = try await run(harness, tool: "design.registerEdit", arguments: [
            "target": target, "operationID": "late-edit",
            "expectedOwnerRevision": ownerRevision, "artifactID": artifactID,
            "payloadRelativePath": manualPath, "origin": "edit",
            "expectedArtifactRevisionID": inputRevisionID
        ])
        #expect(output.exitStatus == 0)
        let editJSON = try json(output)
        ownerRevision = try #require(editJSON["ownerRevision"] as? Int64)

        let stable = stableKey(
            .fileDocument, owner: harness.fixture.workspaceID.uuidString.lowercased(),
            document: "", source: "docs/spec.md")
        let grantID = await harness.grants.issueOwnerAdoption(
            targetStableKey: stable, candidateID: candidateID,
            baselineRevisionID: baseRevisionID, proposedRevisionID: proposedRevisionID,
            mode: .updateOriginal, scope: .aiTool)
        // update-original adoption of the stale candidate must not overwrite
        // the newer manual edit.
        do {
            _ = try await run(harness, tool: "design.adopt", arguments: [
                "target": adoptTarget, "operationID": "late-adopt",
                "expectedOwnerRevision": ownerRevision, "candidateID": candidateID,
                "grantID": grantID
            ])
            Issue.record("stale candidate adoption must fail")
        } catch let error as DesignWorkflowError {
            guard case .revisionConflict = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(harness.fixture.read("docs/spec.md")?.data == manual)
    }

    @Test func duplicateOperationReplaysRecordedCandidate() async throws {
        let harness = try await makeHarness()
        harness.fixture.seed("docs/spec.md", data: Data("# Base\n".utf8))
        let target = fileTarget(harness, "docs/spec.md")
        var output = try await run(harness, tool: "design.freezeInput", arguments: [
            "target": target, "operationID": "dup-freeze"
        ])
        var payload = try json(output)
        var design = try #require(payload["design"] as? [String: Any])
        var artifacts = try #require(design["artifacts"] as? [[String: Any]])
        let artifactID = try #require(artifacts.first?["artifactID"] as? String)
        let ownerRevision = try #require(payload["ownerRevision"] as? Int64)
        let proposePath = try writeArtifactText("# Once\n")
        let first = try await run(harness, tool: "design.propose", arguments: [
            "target": target, "operationID": "dup-propose",
            "expectedOwnerRevision": ownerRevision, "artifactID": artifactID,
            "payloadRelativePath": proposePath, "summary": "once"
        ])
        let firstJSON = try json(first)
        let firstCandidate = try #require(firstJSON["candidateID"] as? String)
        let replay = try await run(harness, tool: "design.propose", arguments: [
            "target": target, "operationID": "dup-propose",
            "expectedOwnerRevision": ownerRevision, "artifactID": artifactID,
            "payloadRelativePath": proposePath, "summary": "once"
        ])
        let replayJSON = try json(replay)
        let replayCandidate = try #require(replayJSON["candidateID"] as? String)
        #expect(replayCandidate == firstCandidate)
        output = try await run(harness, tool: "design.getState", arguments: ["target": target])
        payload = try json(output)
        design = try #require(payload["design"] as? [String: Any])
        let candidates = try #require(design["candidates"] as? [[String: Any]])
        #expect(candidates.count == 1)
    }

    @Test func sourceDeletionFailsClosed() async throws {
        let harness = try await makeHarness()
        harness.fixture.seed("docs/spec.md", data: Data("# Base\n".utf8))
        let target = fileTarget(harness, "docs/spec.md")
        _ = try await run(harness, tool: "design.freezeInput", arguments: [
            "target": target, "operationID": "del-freeze"
        ])
        harness.fixture.remove("docs/spec.md")
        let probe = try await run(harness, tool: "design.resolveTarget", arguments: [
            "target": target
        ])
        #expect(probe.exitStatus == 2)
        await #expect(throws: (any Error).self) {
            _ = try await run(harness, tool: "design.freezeInput", arguments: [
                "target": target, "operationID": "del-freeze-2"
            ])
        }
    }

    // MARK: 4. cross-run adoption still notifies the ORIGINAL task only

    @Test func crossRunAdoptionNotifiesOriginalTaskOnly() async throws {
        let harness = try await makeHarness()
        harness.fixture.seed("docs/spec.md", data: Data("# Base\n".utf8))
        let target = fileTarget(harness, "docs/spec.md")
        var output = try await run(harness, tool: "design.freezeInput", arguments: [
            "target": target, "operationID": "switch-freeze"
        ])
        var payload = try json(output)
        var design = try #require(payload["design"] as? [String: Any])
        var artifacts = try #require(design["artifacts"] as? [[String: Any]])
        let artifactID = try #require(artifacts.first?["artifactID"] as? String)
        let ownerRevision = try #require(payload["ownerRevision"] as? Int64)
        let frozenBaseToken = try #require(
            (payload["source"] as? [String: Any])?["baseRevisionToken"] as? String)
        var adoptTarget = target
        adoptTarget["revision"] = frozenBaseToken
        let proposePath = try writeArtifactText("# Switched\n")
        output = try await run(harness, tool: "design.propose", arguments: [
            "target": target, "operationID": "switch-propose",
            "expectedOwnerRevision": ownerRevision, "artifactID": artifactID,
            "payloadRelativePath": proposePath, "summary": "switch"
        ])
        payload = try json(output)
        let candidateID = try #require(payload["candidateID"] as? String)
        let proposedRevisionID = try #require(payload["proposedRevisionID"] as? String)
        let baseRevisionID = try #require(payload["baseRevisionID"] as? String)
        let ownerRevisionAfterPropose = try #require(payload["ownerRevision"] as? Int64)

        // A LATER run (same task-owned workspace) adopts; the durable event
        // must still go to the task that proposed the candidate.
        let laterRun = UUID()
        let laterConversation = UUID()
        harness.runTasks.bind(run: laterRun, task: laterConversation)
        harness.fixture.bind(run: laterRun, workspace: harness.fixture.workspaceID)
        let stable = stableKey(
            .fileDocument, owner: harness.fixture.workspaceID.uuidString.lowercased(),
            document: "", source: "docs/spec.md")
        let grantID = await harness.grants.issueOwnerAdoption(
            targetStableKey: stable, candidateID: candidateID,
            baselineRevisionID: baseRevisionID, proposedRevisionID: proposedRevisionID,
            mode: .updateOriginal, scope: .aiTool)
        output = try await run(
            harness, tool: "design.adopt", arguments: [
                "target": adoptTarget, "operationID": "switch-adopt",
                "expectedOwnerRevision": ownerRevisionAfterPropose, "candidateID": candidateID,
                "grantID": grantID
            ], runID: laterRun, conversationID: laterConversation)
        #expect(output.exitStatus == 0)
        #expect(harness.sink.recorded.count == 1)
        #expect(harness.sink.recorded.first?.conversationID == harness.conversationID)
        #expect(harness.sink.recorded.contains { $0.conversationID == laterConversation } == false)
    }

    // MARK: 5. creative runtime-approval gate

    @Test func creativeToolsRequireRuntimeApprovalForAgentRuns() async throws {
        let harness = try await makeHarness()
        let target: [String: Any] = [
            "kind": "creativeDocument",
            "ownerID": UUID().uuidString.lowercased(),
            "sourceID": "creation-\(UUID().uuidString.lowercased())",
            "requestedOutputKind": "image"
        ]
        let arguments = try JSONSerialization.data(withJSONObject: [
            "target": target, "operationID": "creative-gate-1", "goal": "hero shot"
        ], options: [.sortedKeys])
        // Without the runtime's approval for THIS call the tool fails before
        // any service or port access (no private grant store, no allow).
        do {
            _ = try await run(harness, tool: "design.creativeBegin", arguments: [
                "target": target, "operationID": "creative-gate-1", "goal": "hero shot"
            ])
            Issue.record("creativeBegin must fail without a runtime approval grant")
        } catch {
            #expect(String(describing: error).contains("runtime approval"))
        }
        // With the runtime grant attached, the approval gate passes; the
        // missing creative owner adapter then fails honestly at the live
        // ownership boundary (never an always-allow).
        let runner = try #require(harness.registry.runner(named: "design.creativeBegin"))
        let context = ToolContext(
            runID: harness.runID,
            toolCallID: "call-1",
            approvalGrantID: UUID(),
            cancellation: CancellationToken(),
            conversationID: harness.conversationID)
        do {
            _ = try await runner.run(arguments, context)
            Issue.record("creativeBegin must fail without a linked creative target")
        } catch {
            #expect(String(describing: error).contains("runtime approval") == false)
        }
    }

    // MARK: 6. canvas compatibility + legacy wrappers

    @Test func canvasTypedMutationReturnsCompatibleCanvasTool() async throws {
        let harness = try await makeHarness()
        let canvasID = UUID()
        let nodeID = UUID()
        let output = try await run(harness, tool: "design.propose", arguments: [
            "target": [
                "kind": "canvasNode",
                "ownerID": canvasID.uuidString.lowercased(),
                "sourceID": nodeID.uuidString.lowercased()
            ],
            "operationID": "canvas-typed-propose",
            "artifactID": "art",
            "payloadRelativePath": "Attachments/never-read.md",
            "summary": "must route to canvas"
        ])
        #expect(output.exitStatus == 2)
        let payload = try json(output)
        #expect(payload["migrationError"] as? Bool == true)
        #expect(payload["compatibleTool"] as? String == "canvas.designPropose")
    }

    @Test func legacyCanvasToolsRemainRegisteredAndDecodable() async throws {
        let harness = try await makeHarness()
        for name in [
            "canvas.designGetState", "canvas.designCapabilities", "canvas.designCreate",
            "canvas.designUpdateBrief", "canvas.designUpdateSpec", "canvas.designPropose",
            "canvas.designAdopt", "canvas.designReject", "canvas.designRestore",
            "canvas.designExportRevision", "canvas.designUseCurrentNode"
        ] {
            #expect(harness.registry.runner(named: name) != nil, "missing legacy tool \(name)")
        }
        // Legacy argument shapes still decode+validate unchanged.
        let getState = try #require(harness.registry.runner(named: "canvas.designGetState"))
        let canvasID = UUID().uuidString
        let nodeID = UUID().uuidString
        let arguments = try JSONSerialization.data(
            withJSONObject: ["canvasID": canvasID, "nodeID": nodeID], options: [.sortedKeys])
        try getState.validateArguments(arguments)
        // Typed tools are registered alongside, with the shared target schema.
        let typed = try #require(harness.registry.runner(named: "design.resolveTarget"))
        #expect(typed.descriptor.parametersJSON.contains("chatAttachment"))
        #expect(typed.descriptor.parametersJSON.contains("creativeDocument"))
        #expect(typed.descriptor.parametersJSON.contains("canvasNode"))
    }

    // MARK: 7. service-level replay + atomic claim semantics (T5 correction)

    @Test func changedProposeArgumentsUnderSameOperationAreRefusedByTheService() async throws {
        let harness = try await makeHarness()
        harness.fixture.seed("docs/spec.md", data: Data("# Base\n".utf8))
        let target = fileTarget(harness, "docs/spec.md")
        var output = try await run(harness, tool: "design.freezeInput", arguments: [
            "target": target, "operationID": "svc-freeze"
        ])
        var payload = try json(output)
        var design = try #require(payload["design"] as? [String: Any])
        var artifacts = try #require(design["artifacts"] as? [[String: Any]])
        let artifactID = try #require(artifacts.first?["artifactID"] as? String)
        let ownerRevision = try #require(payload["ownerRevision"] as? Int64)
        let path = try writeArtifactText("# One\n")
        _ = try await run(harness, tool: "design.propose", arguments: [
            "target": target, "operationID": "svc-propose",
            "expectedOwnerRevision": ownerRevision, "artifactID": artifactID,
            "payloadRelativePath": path, "summary": "first"
        ])
        // The shared service (not a tool wrapper) refuses changed semantic
        // inputs under the same operationID before staging anything.
        do {
            _ = try await run(harness, tool: "design.propose", arguments: [
                "target": target, "operationID": "svc-propose",
                "expectedOwnerRevision": ownerRevision, "artifactID": artifactID,
                "payloadRelativePath": path, "summary": "changed"
            ])
            Issue.record("changed summary under the same operation must be refused")
        } catch let error as DesignOwnerWorkflowError {
            guard case .replayMismatch = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
        output = try await run(harness, tool: "design.getState", arguments: ["target": target])
        payload = try json(output)
        design = try #require(payload["design"] as? [String: Any])
        let candidates = try #require(design["candidates"] as? [[String: Any]])
        #expect(candidates.count == 1)
    }

    @Test func adoptionClaimIsConsumedBeforeWriteAndZeroWriteFailureNeedsFreshConfirmation() async throws {
        let harness = try await makeHarness()
        harness.fixture.seed("docs/spec.md", data: Data("# Base\n".utf8))
        let target = fileTarget(harness, "docs/spec.md")
        var output = try await run(harness, tool: "design.freezeInput", arguments: [
            "target": target, "operationID": "claim-freeze"
        ])
        var payload = try json(output)
        var design = try #require(payload["design"] as? [String: Any])
        var artifacts = try #require(design["artifacts"] as? [[String: Any]])
        let artifactID = try #require(artifacts.first?["artifactID"] as? String)
        let ownerRevision = try #require(payload["ownerRevision"] as? Int64)
        let path = try writeArtifactText("# Proposed\n")
        output = try await run(harness, tool: "design.propose", arguments: [
            "target": target, "operationID": "claim-propose",
            "expectedOwnerRevision": ownerRevision, "artifactID": artifactID,
            "payloadRelativePath": path, "summary": "claim probe"
        ])
        payload = try json(output)
        let candidateID = try #require(payload["candidateID"] as? String)
        let proposedRevisionID = try #require(payload["proposedRevisionID"] as? String)
        let baseRevisionID = try #require(payload["baseRevisionID"] as? String)
        let ownerRevisionAfterPropose = try #require(payload["ownerRevision"] as? Int64)
        let stable = stableKey(
            .fileDocument, owner: harness.fixture.workspaceID.uuidString.lowercased(),
            document: "", source: "docs/spec.md")
        let grantID = await harness.grants.issueOwnerAdoption(
            targetStableKey: stable, candidateID: candidateID,
            baselineRevisionID: baseRevisionID, proposedRevisionID: proposedRevisionID,
            mode: .updateOriginal, scope: .aiTool)
        // The file moves OUTSIDE the workflow so the in-place commit proves
        // notWritten only AFTER the atomic claim.
        harness.fixture.overwrite("docs/spec.md", data: Data("# Manual\n".utf8))
        await #expect(throws: (any Error).self) {
            _ = try await run(harness, tool: "design.adopt", arguments: [
                "target": target, "operationID": "claim-adopt",
                "expectedOwnerRevision": ownerRevisionAfterPropose,
                "candidateID": candidateID, "grantID": grantID
            ])
        }
        // The claim was consumed: the SAME grant cannot authorize a retry.
        await #expect(throws: (any Error).self) {
            _ = try await run(harness, tool: "design.adopt", arguments: [
                "target": target, "operationID": "claim-adopt",
                "expectedOwnerRevision": ownerRevisionAfterPropose,
                "candidateID": candidateID, "grantID": grantID
            ])
        }
        // A FRESH concrete confirmation still works (variant never writes
        // the source, so the divergent manual edit is preserved).
        let variantGrant = await harness.grants.issueOwnerAdoption(
            targetStableKey: stable, candidateID: candidateID,
            baselineRevisionID: baseRevisionID, proposedRevisionID: proposedRevisionID,
            mode: .variant, scope: .aiTool)
        output = try await run(harness, tool: "design.adopt", arguments: [
            "target": target, "operationID": "claim-adopt-variant",
            "expectedOwnerRevision": ownerRevisionAfterPropose,
            "candidateID": candidateID, "mode": "variant", "grantID": variantGrant
        ])
        #expect(output.exitStatus == 0)
        #expect(harness.fixture.read("docs/spec.md")?.data == Data("# Manual\n".utf8))
    }
}
#endif

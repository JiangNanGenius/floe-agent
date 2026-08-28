import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeModels
import FloeTestSupport

@Suite("FloeAgentRuntime.HarnessInvariants")
struct HarnessInvariantTests {
    @Test("Provider dispatch requires a complete committed one-to-one tool pair")
    func providerBoundaryRequiresCommittedPair() throws {
        let call = try TestFixtures.toolCall(id: "paired-call")
        let result = ToolResult(
            callID: call.id,
            status: .ok,
            outputSummary: "done",
            outputDigest: "digest"
        )

        let missingLifecycle = HarnessInvariantRegistry.validateProviderBoundary(
            calls: [call],
            results: [result],
            lifecycleByCallID: [:]
        )
        #expect(missingLifecycle.contains { $0.name == "provider.lifecycleMissing" })

        let valid = HarnessInvariantRegistry.validateProviderBoundary(
            calls: [call],
            results: [result],
            lifecycleByCallID: [call.id: AgentToolLifecycleEntry(
                callID: call.id,
                toolName: call.toolName,
                phase: .resultCommitted
            )]
        )
        #expect(valid.isEmpty)
    }

    @Test("Checkpoint rejects a result that is not lifecycle committed")
    func checkpointRejectsUncommittedResult() throws {
        let call = try TestFixtures.toolCall(id: "uncommitted-result")
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(.init(goal: "test")),
            messages: [ConversationMessage(role: "user", content: "test")],
            pendingToolCalls: [call],
            pendingToolResults: [ToolResult(
                callID: call.id,
                status: .ok,
                outputSummary: "done",
                outputDigest: "digest"
            )],
            toolLifecycleEntries: [AgentToolLifecycleEntry(
                callID: call.id,
                toolName: call.toolName,
                phase: .dispatched
            )]
        )

        let violations = HarnessInvariantRegistry.validateCheckpoint(checkpoint)
        #expect(violations.contains { $0.name == "checkpoint.uncommittedResult" })
    }

    @Test("Provider dispatch preserves assistant tool-call order")
    func providerBoundaryRejectsReorderedResults() throws {
        let first = try TestFixtures.toolCall(id: "first")
        let second = try TestFixtures.toolCall(id: "second")
        let results = [second, first].map {
            ToolResult(
                callID: $0.id,
                status: .ok,
                outputSummary: "done",
                outputDigest: "digest"
            )
        }
        let lifecycle = Dictionary(uniqueKeysWithValues: [first, second].map {
            ($0.id, AgentToolLifecycleEntry(
                callID: $0.id,
                toolName: $0.toolName,
                phase: .resultCommitted
            ))
        })

        let violations = HarnessInvariantRegistry.validateProviderBoundary(
            calls: [first, second],
            results: results,
            lifecycleByCallID: lifecycle
        )
        #expect(violations.contains { $0.name == "provider.callResultPairing" })
    }

    @Test("Checkpoint rejects duplicate and orphan open lifecycle entries")
    func checkpointRejectsInvalidLifecycleSet() throws {
        let call = try TestFixtures.toolCall(id: "pending")
        let duplicate = AgentToolLifecycleEntry(
            callID: call.id,
            toolName: call.toolName,
            phase: .recorded
        )
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(.init(goal: "test")),
            messages: [ConversationMessage(role: "user", content: "test")],
            pendingToolCalls: [call],
            toolLifecycleEntries: [
                duplicate,
                duplicate,
                AgentToolLifecycleEntry(
                    callID: "orphan",
                    toolName: call.toolName,
                    phase: .dispatched
                )
            ]
        )

        let violations = HarnessInvariantRegistry.validateCheckpoint(checkpoint)
        #expect(violations.contains { $0.name == "checkpoint.duplicateLifecycleID" })
        #expect(violations.contains { $0.name == "checkpoint.orphanOpenLifecycle" })
    }

    @Test("Checkpoint rejects an incomplete provider dispatch envelope")
    func checkpointRejectsInvalidDispatchEnvelope() {
        let checkpoint = AgentCheckpoint(
            runID: UUID(),
            conversationID: UUID(),
            state: .preparing(.init(goal: "test")),
            messages: [ConversationMessage(role: "user", content: "test")],
            providerDispatchEnvelope: ProviderDispatchEnvelope(
                providerID: UUID(),
                providerKind: "openAICompatible",
                wireProtocol: "responsesAPI",
                modelID: UUID(),
                remoteModelID: "model",
                conversationMode: "agent",
                messagesDigest: "",
                toolSchemasDigest: "schema",
                pendingCallIDs: ["first"],
                pendingResultCallIDs: ["second"]
            )
        )

        let violations = HarnessInvariantRegistry.validateCheckpoint(checkpoint)
        #expect(violations.contains { $0.name == "checkpoint.dispatchDigestMissing" })
        #expect(violations.contains { $0.name == "checkpoint.dispatchPairingMismatch" })
    }
}

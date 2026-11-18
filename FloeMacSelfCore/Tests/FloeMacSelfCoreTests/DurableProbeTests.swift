// SPDX-License-Identifier: MPL-2.0
//
// Strict durable terminal proof regressions. These write real upstream
// run/message/event rows into an isolated SQLite database and verify that a
// terminal receipt is confirmed only with the exact run/state/message
// evidence. No provider, tool, UI or user database is involved.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeSecurity
import FloePersistence
import FloeAgentRuntime
@testable import FloeMacSelfCore

@Suite("Mac self-core durable terminal probe")
struct DurableTerminalProbeTests {

    private struct Environment: Sendable {
        let database: DatabaseManager
        let launch: SQLiteRunLaunchStore
        let conversations: SQLiteConversationStore
        let runs: SQLiteRunStore
        let admissions: FloeMacSelfAdmissionStore
        let workspaceID: UUID
        let provider: FloeMacSelfProviderBinding
    }

    private func makeEnvironment(root: URL) async throws -> Environment {
        let databaseURL = root.appendingPathComponent("probe.sqlite")
        let seeded = try await makeSeededDatabase(at: databaseURL)
        let workspaceID = UUID()
        try await seeded.workspace.saveWorkspace(WorkspaceRecord(
            id: workspaceID,
            name: "Probe workspace",
            rootBookmark: Data(),
            kind: .project
        ))
        let (binding, _) = SelfCoreFixture.makeProviderBinding(scripts: [])
        return Environment(
            database: seeded.database,
            launch: seeded.launch,
            conversations: SQLiteConversationStore(database: seeded.database),
            runs: SQLiteRunStore(database: seeded.database),
            admissions: FloeMacSelfAdmissionStore(database: seeded.database, authorityLock: nil),
            workspaceID: workspaceID,
            provider: binding
        )
    }

    private func prepareRun(
        _ environment: Environment,
        conversationID: UUID,
        runID: UUID,
        goal: String
    ) async throws -> PreparedRun {
        try await environment.launch.prepare(RunLaunchRequest(
            newConversationID: conversationID,
            conversationTitle: "Probe",
            runID: runID,
            goal: goal,
            workspaceID: environment.workspaceID,
            conversationMode: "chat",
            providerName: environment.provider.provider.displayName,
            modelName: environment.provider.model.displayName,
            providerProfile: environment.provider.provider,
            modelProfile: environment.provider.model,
            startedAt: Date()
        ))
    }

    @discardableResult
    private func appendAssistant(
        _ environment: Environment,
        conversationID: UUID,
        runID: UUID?,
        text: String
    ) async throws -> UUID {
        let id = UUID()
        try await environment.conversations.appendMessage(PersistedMessage(
            id: id,
            conversationID: conversationID,
            role: "assistant",
            content: text,
            createdAt: Date(),
            parts: [MessagePart(
                messageID: id,
                partIndex: 0,
                kind: .text,
                text: text
            )],
            runID: runID
        ))
        return id
    }

    @Test("A bare terminal event has no final-answer proof and stays unconfirmed")
    func bareTerminalIsUnconfirmed() async throws {
        try await withSelfCoreTempDirectory { root in
            let environment = try await makeEnvironment(root: root)
            let conversationID = UUID()
            let runID = UUID()
            let prepared = try await prepareRun(
                environment,
                conversationID: conversationID,
                runID: runID,
                goal: "Bare terminal"
            )
            try await environment.runs.updateRunState(
                id: runID,
                state: "completed",
                endedAt: Date()
            )
            try await environment.runs.appendEvent(
                runID: runID,
                kind: .terminal,
                payloadJSON: #"{"stopReason":"endTurn"}"#
            )
            let receipt = try await environment.admissions.terminalReceipt(
                conversationID: conversationID,
                runID: runID,
                expectedUserMessageID: prepared.userMessage.id
            )
            #expect(!receipt.confirmed)
            #expect(receipt.unconfirmedReason == "final_message_proof_missing")
            try await environment.database.close()
        }
    }

    @Test("A final message id that does not match the exact run is rejected")
    func mismatchedFinalMessageIsRejected() async throws {
        try await withSelfCoreTempDirectory { root in
            let environment = try await makeEnvironment(root: root)
            let conversationID = UUID()
            let runID = UUID()
            let prepared = try await prepareRun(
                environment,
                conversationID: conversationID,
                runID: runID,
                goal: "Mismatched final message"
            )
            // A real assistant row in the same conversation but not owned by
            // this run. It must never be accepted as this run's answer.
            let foreignMessageID = try await appendAssistant(
                environment,
                conversationID: conversationID,
                runID: nil,
                text: "Foreign answer"
            )
            try await environment.runs.updateRunState(
                id: runID,
                state: "completed",
                endedAt: Date()
            )
            try await environment.runs.appendEvent(
                runID: runID,
                kind: .terminal,
                payloadJSON: #"{"stopReason":"endTurn","finalMessageID":"\#(foreignMessageID.uuidString)"}"#
            )
            let receipt = try await environment.admissions.terminalReceipt(
                conversationID: conversationID,
                runID: runID,
                expectedUserMessageID: prepared.userMessage.id
            )
            #expect(!receipt.confirmed)
            #expect(receipt.unconfirmedReason == "final_message_mismatch")

            // A missing message id is also unconfirmed.
            let missingConversationID = UUID()
            let missingRunID = UUID()
            let missingPrepared = try await prepareRun(
                environment,
                conversationID: missingConversationID,
                runID: missingRunID,
                goal: "Missing final message"
            )
            try await environment.runs.updateRunState(
                id: missingRunID,
                state: "completed",
                endedAt: Date()
            )
            try await environment.runs.appendEvent(
                runID: missingRunID,
                kind: .terminal,
                payloadJSON: #"{"stopReason":"endTurn","finalMessageID":"\#(UUID().uuidString)"}"#
            )
            let missing = try await environment.admissions.terminalReceipt(
                conversationID: missingConversationID,
                runID: missingRunID,
                expectedUserMessageID: missingPrepared.userMessage.id
            )
            #expect(!missing.confirmed)
            #expect(missing.unconfirmedReason == "final_message_missing")
            try await environment.database.close()
        }
    }

    @Test("Exact final assistant identity confirms completion; a later status contradicts it")
    func exactFinalMessageConfirmsAndLaterStatusContradicts() async throws {
        try await withSelfCoreTempDirectory { root in
            let environment = try await makeEnvironment(root: root)
            let conversationID = UUID()
            let runID = UUID()
            let prepared = try await prepareRun(
                environment,
                conversationID: conversationID,
                runID: runID,
                goal: "Exact final answer"
            )
            let finalMessageID = try await appendAssistant(
                environment,
                conversationID: conversationID,
                runID: runID,
                text: "The exact final answer"
            )
            try await environment.runs.updateRunState(
                id: runID,
                state: "completed",
                endedAt: Date()
            )
            try await environment.runs.appendEvent(
                runID: runID,
                kind: .terminal,
                payloadJSON: #"{"stopReason":"endTurn","finalMessageID":"\#(finalMessageID.uuidString)"}"#
            )
            let receipt = try await environment.admissions.terminalReceipt(
                conversationID: conversationID,
                runID: runID,
                expectedUserMessageID: prepared.userMessage.id
            )
            #expect(receipt.confirmed)
            #expect(receipt.outcome == .completed)
            #expect(receipt.durableRunState == "completed")
            #expect(receipt.finalMessageID == finalMessageID)
            #expect(receipt.finalMessageVerified)
            #expect(receipt.terminalEventSequence != nil)

            let wrongUserMessage = try await environment.admissions.terminalReceipt(
                conversationID: conversationID,
                runID: runID,
                expectedUserMessageID: UUID()
            )
            #expect(!wrongUserMessage.confirmed)
            #expect(wrongUserMessage.unconfirmedReason == "user_message_mismatch")

            // A status row appended after the terminal marker makes the
            // completion contradictory; it must not stay confirmed.
            try await environment.runs.appendEvent(
                runID: runID,
                kind: .status,
                payloadJSON: #"{"state":"completed"}"#
            )
            let contradicted = try await environment.admissions.terminalReceipt(
                conversationID: conversationID,
                runID: runID,
                expectedUserMessageID: prepared.userMessage.id
            )
            #expect(!contradicted.confirmed)
            #expect(contradicted.unconfirmedReason == "terminal_state_conflict")
            try await environment.database.close()
        }
    }

    @Test("The explicit no-final-text marker confirms termination without claiming a successful answer")
    func noFinalTextMarkerConfirmsWithoutFinalAnswer() async throws {
        try await withSelfCoreTempDirectory { root in
            let environment = try await makeEnvironment(root: root)
            let conversationID = UUID()
            let runID = UUID()
            let prepared = try await prepareRun(
                environment,
                conversationID: conversationID,
                runID: runID,
                goal: "No final text"
            )
            try await environment.runs.updateRunState(
                id: runID,
                state: "completed",
                endedAt: Date()
            )
            try await environment.runs.appendEvent(
                runID: runID,
                kind: .error,
                payloadJSON: #"{"message":"noFinalText"}"#
            )
            try await environment.runs.appendEvent(
                runID: runID,
                kind: .terminal,
                payloadJSON: #"{"stopReason":"endTurn"}"#
            )
            let receipt = try await environment.admissions.terminalReceipt(
                conversationID: conversationID,
                runID: runID,
                expectedUserMessageID: prepared.userMessage.id
            )
            #expect(receipt.confirmed)
            #expect(receipt.outcome == .unknown)
            #expect(receipt.completionStopReason == .endTurn)
            #expect(receipt.finalMessageID == nil)
            #expect(!receipt.finalMessageVerified)
            try await environment.database.close()
        }
    }

    @Test("Limited and tool-use terminal boundaries preserve partial output without claiming completion")
    func limitedStopReasonsPreserveTerminalAndOutput() async throws {
        try await withSelfCoreTempDirectory { root in
            let environment = try await makeEnvironment(root: root)
            for reason in ["maxTokens", "budgetLimited", "noProgress", "toolUse", "stopSequence"] {
                let conversationID = UUID(), runID = UUID()
                let prepared = try await prepareRun(environment, conversationID: conversationID,
                                                    runID: runID, goal: "Synthetic limited run")
                let finalID = try await appendAssistant(environment, conversationID: conversationID,
                                                        runID: runID, text: "Synthetic partial answer")
                try await environment.runs.updateRunState(id: runID, state: "completed", endedAt: Date())
                try await environment.runs.appendEvent(runID: runID, kind: .terminal,
                    payloadJSON: #"{"stopReason":"\#(reason)","finalMessageID":"\#(finalID.uuidString)"}"#)
                let receipt = try await environment.admissions.terminalReceipt(
                    conversationID: conversationID, runID: runID, expectedUserMessageID: prepared.userMessage.id)
                #expect(receipt.confirmed)
                #expect(receipt.durableRunState == "completed")
                #expect(receipt.outcome == (reason == "stopSequence" ? .completed : .unknown))
                #expect(receipt.completionStopReason?.rawValue == reason)
                #expect(receipt.finalMessageVerified)
                #expect(receipt.finalMessageID == finalID)
                let saved = try await environment.conversations.message(id: finalID, conversationID: conversationID)
                #expect(saved?.content == "Synthetic partial answer")
            }
            try await environment.database.close()
        }
    }

    @Test("Checkpointed status confirms interruption, a mismatched status does not")
    func checkpointedAndContradictoryStatus() async throws {
        try await withSelfCoreTempDirectory { root in
            let environment = try await makeEnvironment(root: root)

            let checkpointConversationID = UUID()
            let checkpointRunID = UUID()
            let checkpointPrepared = try await prepareRun(
                environment,
                conversationID: checkpointConversationID,
                runID: checkpointRunID,
                goal: "Checkpointed"
            )
            try await environment.runs.updateRunState(
                id: checkpointRunID,
                state: "checkpointed",
                endedAt: Date()
            )
            try await environment.runs.appendEvent(
                runID: checkpointRunID,
                kind: .status,
                payloadJSON: #"{"state":"checkpointed","reason":""}"#
            )
            let checkpointReceipt = try await environment.admissions.terminalReceipt(
                conversationID: checkpointConversationID,
                runID: checkpointRunID,
                expectedUserMessageID: checkpointPrepared.userMessage.id
            )
            #expect(checkpointReceipt.confirmed)
            #expect(checkpointReceipt.outcome == .interrupted)
            #expect(checkpointReceipt.durableRunState == "checkpointed")

            let failedConversationID = UUID()
            let failedRunID = UUID()
            let failedPrepared = try await prepareRun(
                environment,
                conversationID: failedConversationID,
                runID: failedRunID,
                goal: "Contradictory status"
            )
            try await environment.runs.updateRunState(
                id: failedRunID,
                state: "failed",
                endedAt: Date()
            )
            try await environment.runs.appendEvent(
                runID: failedRunID,
                kind: .status,
                payloadJSON: #"{"state":"checkpointed","reason":"wrong"}"#
            )
            let failedReceipt = try await environment.admissions.terminalReceipt(
                conversationID: failedConversationID,
                runID: failedRunID,
                expectedUserMessageID: failedPrepared.userMessage.id
            )
            #expect(!failedReceipt.confirmed)
            #expect(failedReceipt.unconfirmedReason == "terminal_state_conflict")

            // A terminal row without ended_at is not confirmable even with a
            // matching terminal event.
            let noEndConversationID = UUID()
            let noEndRunID = UUID()
            let noEndPrepared = try await prepareRun(
                environment,
                conversationID: noEndConversationID,
                runID: noEndRunID,
                goal: "No ended at"
            )
            try await environment.runs.updateRunState(
                id: noEndRunID,
                state: "completed",
                endedAt: nil
            )
            try await environment.runs.appendEvent(
                runID: noEndRunID,
                kind: .terminal,
                payloadJSON: #"{"stopReason":"endTurn"}"#
            )
            let noEndReceipt = try await environment.admissions.terminalReceipt(
                conversationID: noEndConversationID,
                runID: noEndRunID,
                expectedUserMessageID: noEndPrepared.userMessage.id
            )
            #expect(!noEndReceipt.confirmed)
            #expect(noEndReceipt.unconfirmedReason == "run_ended_at_missing")

            try await environment.database.close()
        }
    }
}

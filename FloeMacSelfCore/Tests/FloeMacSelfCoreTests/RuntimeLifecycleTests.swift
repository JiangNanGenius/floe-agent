// SPDX-License-Identifier: MPL-2.0
//
// Real-runtime lifecycle tests: the existing SQLiteRunLaunchStore prepares
// the run, ConversationRunService.startPrepared executes it, and receipts are
// read back from the durable database rather than inferred from events.

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

@Suite("Mac self-owned runtime lifecycle")
struct RuntimeLifecycleTests {

    @Test("Migration is mandatory before stores, and bootstrap is idempotent")
    func bootstrapMigratesBeforeStores() async throws {
        try await withSelfCoreFixture(bootstrap: false) { fixture in
            let (binding, _) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "unused")),
                .completed(.init(stopReason: .endTurn)),
            ]])
            let request = fixture.newConversationRequest(goal: "Hello before bootstrap")

            let error = await selfCoreError {
                _ = try await fixture.runtime.startSession(request, provider: binding)
            }
            #expect(error?.code == "notBootstrapped")

            let first = try await fixture.runtime.bootstrap()
            #expect(first.schemaVersion >= DatabaseManager.currentSchemaVersion)
            #expect(first.appliedMigrationCount > 0)

            let runsAfterFailedStart = try await fixture.runtime.nonTerminalRuns()
            #expect(runsAfterFailedStart.isEmpty)

            let second = try await fixture.runtime.bootstrap()
            #expect(second.schemaVersion == first.schemaVersion)
            #expect(second.appliedMigrationCount == first.appliedMigrationCount)
        }
    }

    @Test("Prepared identities reach the service, real events flow, and completion is durably confirmed")
    func preparedIdentitiesAndDurableCompletion() async throws {
        try await withSelfCoreFixture { fixture in
            let (binding, adapter) = fixture.makeProvider(
                scripts: [[
                    .textDelta(.init(text: "Hello ")),
                    .textDelta(.init(text: "from the Mac composition.")),
                    .completed(.init(stopReason: .endTurn)),
                ]],
                holdFirstEvent: true
            )
            let request = fixture.newConversationRequest(goal: "Hello from the Mac composition")
            let handle = try await fixture.runtime.startSession(request, provider: binding)
            let (collector, collectorTask) = startEventCollector(handle)
            defer { collectorTask.cancel() }

            // The durable launch committed before the handle was returned.
            let preparedRun = try #require(try await handle.durableRun())
            #expect(preparedRun.id == handle.identity.runID)
            #expect(preparedRun.conversationID == handle.identity.conversationID)
            #expect(preparedRun.providerID == binding.provider.id)
            #expect(preparedRun.modelID == binding.model.id)
            #expect(preparedRun.conversationMode == "chat")

            let preparedMessages = try await handle.durableMessages()
            let userMessage = try #require(preparedMessages.first { $0.id == handle.identity.userMessageID })
            #expect(userMessage.role == "user")
            #expect(userMessage.content == request.goal)
            #expect(userMessage.runID == handle.identity.runID)
            #expect(userMessage.conversationID == handle.identity.conversationID)

            await adapter.openGate()
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            #expect(terminal.durableRunState == "completed")
            #expect(terminal.terminalEventSequence != nil)
            #expect(terminal.durableEndedAt != nil)
            #expect(terminal.runID == handle.identity.runID)
            #expect(terminal.conversationID == handle.identity.conversationID)
            #expect(terminal.finalMessageID != nil)
            #expect(terminal.finalMessageVerified)

            let harnessEvents = await collector.harnessEvents()
            #expect(harnessEvents.contains { event in
                if case .answerDelta = event { return true }
                return false
            })
            #expect(harnessEvents.contains { event in
                if case .terminal(let terminal) = event { return terminal == .completed }
                return false
            })
            let ended = await eventually {
                await collector.hasEnded()
            }
            #expect(ended)

            let finalMessages = try await handle.durableMessages()
            #expect(finalMessages.contains { $0.role == "assistant" && $0.content.contains("Mac composition") })
            #expect(finalMessages.filter { $0.role == "user" }.count == 1)

            let close = try await handle.close()
            #expect(close.terminalConfirmed)
            #expect(close.preservedUnconfirmedRun == false)
            #expect(close.durableAdmissionRetained == false)
        }
    }

    @Test("Durable terminal confirmation does not depend on receiving the event stream")
    func durableTerminalWithoutEventConsumer() async throws {
        try await withSelfCoreFixture { fixture in
            let (binding, _) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "No observer required.")),
                .completed(.init(stopReason: .endTurn)),
            ]])
            let request = fixture.newConversationRequest(goal: "Complete without an event subscriber")
            let handle = try await fixture.runtime.startSession(request, provider: binding)

            // Deliberately do not call handle.events().
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            #expect(terminal.durableRunState == "completed")

            let durableEvents = try await handle.durableEvents()
            #expect(durableEvents.contains { $0.kind == .terminal })
            #expect(durableEvents.contains { $0.kind == .assistantText })

            let close = try await handle.close()
            #expect(close.terminalConfirmed)
        }
    }

    @Test("Closing and relaunching the host reads the completed history back from SQLite")
    func relaunchReadsDurableHistory() async throws {
        try await withSelfCoreFixture { fixture in
            let (binding, _) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "Persisted across relaunch.")),
                .completed(.init(stopReason: .endTurn)),
            ]])
            let request = fixture.newConversationRequest(goal: "Persist this turn")
            let handle = try await fixture.runtime.startSession(request, provider: binding)
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)

            let conversationID = handle.identity.conversationID
            let runID = handle.identity.runID
            _ = try await handle.close()
            let firstShutdown = try await fixture.shutdown(cancelActive: false)
            #expect(firstShutdown.databaseClosed)

            let secondProvenance = try makeHostProvenance(databaseURL: fixture.databaseURL)
            let secondRuntime = try FloeMacSelfRuntime(
                databaseURL: fixture.databaseURL,
                owner: FloeMacSelfHostIdentity(displayName: "FloeMacSelfCoreRelaunchFixture"),
                provenance: secondProvenance
            )
            let secondBootstrap = try await secondRuntime.bootstrap()
            #expect(secondBootstrap.schemaVersion >= DatabaseManager.currentSchemaVersion)

            let durableRun = try await secondRuntime.runRecord(runID: runID)
            #expect(durableRun?.state == "completed")
            #expect(durableRun?.conversationID == conversationID)

            let messages = try await secondRuntime.conversationMessages(conversationID: conversationID)
            #expect(messages.contains { $0.id == handle.identity.userMessageID })
            #expect(messages.contains { $0.role == "assistant" })

            let events = try await secondRuntime.runEvents(runID: runID)
            #expect(events.contains { $0.kind == .terminal })

            let secondShutdown = try await secondRuntime.shutdown(cancelActive: false)
            #expect(secondShutdown.databaseClosed)
        }
    }

    @Test("Saved tasks archive, restore and delete through the canonical store")
    func savedTaskManagementPersists() async throws {
        try await withSelfCoreFixture { fixture in
            let (provider, _) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "Saved reply.")),
                .completed(.init(stopReason: .endTurn)),
            ]])
            let handle = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "Saved task"), provider: provider
            )
            let id = handle.identity.conversationID
            let terminal = try #require(await handle.waitForTerminal())
            #expect(terminal.confirmed)
            _ = try await handle.close()

            try await fixture.runtime.changeConversationMetadata(id: id, change: .archive(true))
            #expect(try await fixture.runtime.conversations().isEmpty)
            let archived = try await fixture.runtime.conversations(includeArchived: true)
            #expect(archived.first?.id == id && archived.first?.archivedAt != nil)

            try await fixture.runtime.changeConversationMetadata(id: id, change: .archive(false))
            let restored = try await fixture.runtime.conversations()
            #expect(restored.first?.id == id && restored.first?.archivedAt == nil)
            #expect(try await fixture.runtime.conversationMessages(conversationID: id).count == 2)

            try await fixture.runtime.changeConversationMetadata(id: id, change: .delete)
            #expect(try await fixture.runtime.conversations(includeArchived: true).isEmpty)
        }
    }

    @Test("Missing Goal criteria, missing Plan tools and malformed requests fail before a durable write")
    func incompleteModeInputsAndRequestsFailClosed() async throws {
        try await withSelfCoreFixture { fixture in
            let (binding, _) = fixture.makeProvider(scripts: [])
            let goalRequest = FloeMacSelfSessionRequest(goal: "Goal work", mode: .goal)
            let goalError = await selfCoreError {
                _ = try await fixture.runtime.startSession(goalRequest, provider: binding)
            }
            #expect(goalError?.code == "invalidRequest")

            let planRequest = FloeMacSelfSessionRequest(goal: "Plan work", mode: .plan)
            let planError = await selfCoreError {
                _ = try await fixture.runtime.startSession(planRequest, provider: binding)
            }
            #expect(planError?.code == "toolCapabilityUnavailable")

            let emptyRequest = FloeMacSelfSessionRequest(goal: "   ")
            let emptyError = await selfCoreError {
                _ = try await fixture.runtime.startSession(emptyRequest, provider: binding)
            }
            #expect(emptyError?.code == "invalidRequest")

            let bothCredentials = FloeMacSelfSessionRequest(
                conversationID: UUID(),
                newConversationID: UUID(),
                goal: "Both"
            )
            let bothError = await selfCoreError {
                _ = try await fixture.runtime.startSession(bothCredentials, provider: binding)
            }
            #expect(bothError?.code == "invalidRequest")

            let runs = try await fixture.runtime.nonTerminalRuns()
            #expect(runs.isEmpty)
        }
    }

    @Test("Invalid database locations and foreign-process owners fail closed")
    func invalidLocationsAndOwnersFailClosed() async throws {
        try await withSelfCoreFixture { fixture in
            let currentPID = ProcessInfo.processInfo.processIdentifier

            let directoryError = await selfCoreError {
                _ = try FloeMacSelfRuntime(databaseURL: fixture.root, owner: fixture.owner)
            }
            #expect(directoryError?.code == "invalidDatabaseLocation")

            let missingParent = fixture.root
                .appendingPathComponent("missing", isDirectory: true)
                .appendingPathComponent("db.sqlite")
            let missingParentError = await selfCoreError {
                _ = try FloeMacSelfRuntime(databaseURL: missingParent, owner: fixture.owner)
            }
            #expect(missingParentError?.code == "invalidDatabaseLocation")

            let foreignOwner = FloeMacSelfHostIdentity(
                processIdentifier: currentPID &+ 1,
                displayName: "Foreign"
            )
            let foreignError = await selfCoreError {
                _ = try FloeMacSelfRuntime(databaseURL: fixture.root.appendingPathComponent("foreign.sqlite"), owner: foreignOwner)
            }
            #expect(foreignError?.code == "invalidOwner")

            let emptyNameOwner = FloeMacSelfHostIdentity(displayName: "   ")
            let emptyOwnerError = await selfCoreError {
                _ = try FloeMacSelfRuntime(databaseURL: fixture.root.appendingPathComponent("empty.sqlite"), owner: emptyNameOwner)
            }
            #expect(emptyOwnerError?.code == "invalidOwner")
        }
    }
}

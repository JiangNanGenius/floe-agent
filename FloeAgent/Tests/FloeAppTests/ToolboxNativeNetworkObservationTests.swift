// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && DEBUG
import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeSecurity
import FloeTools
import FloeToolboxCore
@testable import FloeApp

@Suite("Registered native Wi-Fi and roaming observation", .serialized)
@MainActor struct ToolboxNativeNetworkObservationTests {
    private func invoke(_ args: [String: Any], context: ToolContext) async throws -> [String: Any] {
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: "toolbox.network.observe"))
        let output = try await runner.execute(argumentsJSON: JSONSerialization.data(withJSONObject: args), context: context)
        let bytes = Data((output.capturedOutput ?? output.summary).utf8)
        #expect(StudioToolOutput.hash(bytes) == output.fullOutputSHA256)
        return try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    private func withTask(_ body: @MainActor (AppEnvironment, ToolContext) async throws -> Void) async throws {
        let app = try await appQualificationEnvironment(); try await app.ensureDurableAutomationReady()
        let task = UUID(), run = UUID(), now = Date()
        try await app.conversationStore.saveConversation(.init(id: task, title: "N13 native WiFi contract", createdAt: now, updatedAt: now))
        try await app.conversationStore.setArchived(id: task, archived: true)
        try await app.runStore.saveRun(.init(id: run, conversationID: task, state: "executing", goal: "Read native network state", startedAt: now))
        let names = ToolboxCenter.toolNames
        var context = ToolContext(runID: run, toolCallID: "native-network-read", allowedToolNames: names,
            cancellation: CancellationToken(), conversationID: task)
        context.frozenEffectiveCatalogNames = names
        // No workspace/environment/grant is invented for this native read.
        do { try await body(app, context); try await app.conversationStore.deleteConversation(id: task) }
        catch { try? await app.conversationStore.deleteConversation(id: task); throw error }
    }

    @Test func registeredNativeReadIsDiscoverableWithoutLinuxAndDoesNotCreateTraceOrConnection() async throws {
        try await withTask { app, context in
            let available = try await app.toolboxCenter.freeze(runID: context.runID, conversationID: context.conversationID!)
            #expect(available.contains(ToolboxNetworkObserveTool.name))
            #expect(FloeTools.ToolCatalog.descriptor(named: ToolboxNetworkObserveTool.name)?.isSideEffecting == false)
            let sessionCount = app.toolboxCenter.taskSessions.activeSessionCount, running = app.toolboxDiagnostics.tracing
            let result = try await invoke(["action": "current"], context: context)
            let permission = try #require(result["permission"] as? [String: Any]), wifi = try #require(result["currentWiFi"] as? [String: Any])
            #expect(permission["requestedPermission"] as? Bool == false)
            #expect(["wifi", "notWiFi", "unavailable", "notObserved"].contains(wifi["status"] as? String ?? ""))
            #expect(result["startedAt"] is String && result["completedAt"] is String)
            if permission["canReadIdentity"] as? Bool == false {
                #expect(wifi["ssid"] == nil && wifi["bssid"] == nil && wifi["signalDBM"] == nil)
            }
            #expect(app.toolboxCenter.taskSessions.activeSessionCount == sessionCount && app.toolboxDiagnostics.tracing == running)
            let status = try await invoke(["action": "roamingStatus"], context: context)
            #expect(status["currentWiFi"] == nil && status["gateway"] == nil, "Status must not claim a fresh native AP read")
            var temporary = context; temporary.temporaryReadOnly = true
            var foreign = context; foreign.conversationID = UUID()
            var cancelled = context; cancelled.cancellation = CancellationToken(); cancelled.cancellation.cancel()
            for owner in [temporary, foreign, cancelled] {
                do { _ = try await invoke(["action": "current"], context: owner); Issue.record("An unowned/temporary/cancelled native read was accepted") } catch {}
            }
            for invalid in [["action": "start"], ["action": "current", "mayReadIdentity": true], ["action": "roamingStatus", "target": "192.0.2.1"]] as [[String: Any]] {
                do { _ = try await invoke(invalid, context: context); Issue.record("A model permission or control argument was accepted") } catch {}
            }
            #expect(app.toolboxCenter.taskSessions.activeSessionCount == sessionCount && app.toolboxDiagnostics.tracing == running)
        }
    }

    @Test func registeredSessionStatusReadsTheCurrentRunWithoutOpeningOrApprovingAConnection() async throws {
        #expect(OrdinaryDocumentActionProfile.role(forToolName: "toolbox.session", arguments: ["action": "status"]) == .readOnly)
        let unclassified: [[String: Any]] = [["action": "open"], ["action": "close"], ["action": "status", "host": "example.com"], ["action": "unknown"]]
        for args in unclassified {
            #expect(OrdinaryDocumentActionProfile.role(forToolName: "toolbox.session", arguments: args) == nil)
        }
        try await withTask { app, context in
            let before = app.toolboxCenter.taskSessions.activeSessionCount
            let runner = try #require(ToolRunnerRegistry.shared.runner(named: "toolbox.session"))
            let output = try await runner.execute(argumentsJSON: Data(#"{"action":"status"}"#.utf8), context: context)
            #expect(!output.summary.isEmpty)
            #expect(app.toolboxCenter.taskSessions.activeSessionCount == before)
        }
    }

    @Test func actualCoreTraceProjectionDropsOldGenerationAndNeverExposesIdentityHistory() throws {
        let a = "02:11:22:33:44:55", b = "02:11:22:33:44:66", date = Date(timeIntervalSince1970: 1_800_000_000)
        var trace = try RoamingTrace(configuration: .init(target: "192.0.2.10"))
        _ = try trace.append(.init(timestamp: date, uptime: 10, status: .wifi, ssid: "Fixture WiFi", bssid: a, probe: .reply(milliseconds: 10)))
        _ = try trace.append(.init(timestamp: date.addingTimeInterval(1), uptime: 11, status: .wifi, ssid: "Fixture WiFi", bssid: b, probe: .timeout))
        let snapshot = trace.snapshot
        let pending = ToolboxNativeNetworkObservation.roaming(.init(running: true, latestAttemptFailed: false,
            hasRetainedSnapshot: true, snapshotIsCurrentAttempt: false, snapshot: snapshot), mayReadIdentity: true)
        #expect(pending.snapshotState == "startingWithoutCurrentSamples" && pending.retainedSampleCount == nil && pending.accessPointChanges == nil)
        let current = ToolboxNativeNetworkObservation.roaming(.init(running: true, latestAttemptFailed: false,
            hasRetainedSnapshot: true, snapshotIsCurrentAttempt: true, snapshot: snapshot), mayReadIdentity: true)
        #expect(current.retainedSampleCount == 2 && current.accessPointChanges == 1 && current.packetLoss == 0.5)
        let redacted = ToolboxNativeNetworkObservation.roaming(.init(running: false, latestAttemptFailed: false,
            hasRetainedSnapshot: true, snapshotIsCurrentAttempt: false, snapshot: snapshot), mayReadIdentity: false)
        #expect(redacted.snapshotState == "retainedSnapshotNotLive" && redacted.accessPointChanges == nil)
        let text = String(decoding: try StudioToolOutput.data(current), as: UTF8.self)
        #expect(!text.contains(a) && !text.contains(b) && !text.contains("Fixture WiFi") && !text.contains("192.0.2.10"))
    }
}
#endif

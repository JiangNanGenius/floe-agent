// X34-R3 — REAL pinned-MLX → REAL cad.document → REAL native CAD geometry.
//
// Opt-in App-hosted qualification source. It does not run on Simulator.
// Build the App test host, install the exact pinned `qwen3.5-4b-mlx4` snapshot,
// and run the selectors below on a supported NON-Simulator destination:
//
//   * My Mac (Designed for iPad) — `platform=macOS,arch=arm64,variant=Designed
//     for [iPad,iPhone]`; or
//   * a physical iPad.
//
// Why not the Simulator: `MLXTextEngine.requireSupportedRuntime()` deliberately
// refuses the Simulator (a real previous attempt aborted inside libc++/Metal).
// This file keeps that refusal; it does not weaken or bypass it.
//
// Why not a native macOS CLI: `ThirdParty/FloeCADKit` declares `.iOS(.v26)`
// and its OCCT XCFramework contains only ios-arm64 / ios-arm64-simulator
// slices, so a macOS executable cannot link the real CAD kernel. The App-hosted
// test is the only route that runs real MLX and real OCCT in one process.
//
// What actually runs (no fixture, no echo provider, no hand-written package):
//   1. production `LocalModelStore` / `LocalModelRuntime` / `LocalProviderAdapter`
//      load the exact pinned snapshot and emit the tool protocol the product
//      uses (Qwen JSON envelope; no provider-specific stripped CAD subset);
//   2. the production `ConversationRunService` authorizes and dispatches
//      `cad.document` under an automatic task policy limited to that one tool;
//   3. `FloeCAD3DBridge` / `CadDocumentCenter` build a real OCCT B-rep part;
//   4. the test re-opens the saved package independently, measures the exact
//      analytic volume, checks the restored Ø6 circle, and verifies that a real
//      `parameters` undo restored the pre-edit canonical model identity.
//
//   The live selector is split into four bounded turns (plate, hole, radius
//   edit, native undo) so a 4B model is never asked to chain ten calls at once.
//
// A skip is not live evidence. A prose answer without a tool call is a failure.
// The model never receives an image and never needs one: this qualification is
// text-only and uses deterministic measurement, never visual inspection.

#if canImport(UIKit) && DEBUG && !targetEnvironment(simulator)
import Foundation
import XCTest
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
import FloeWorkbench
import FloeAgentRuntime
import FloeLocalModelCatalog
@testable import FloeLocalModels
@testable import FloeApp
import FloeCAD

@MainActor
final class LocalMLXRealCADQualificationTests: XCTestCase {

    private static let modelID = "qwen3.5-4b-mlx4"
    private static let pinnedRevision = "32f3e8ecf65426fc3306969496342d504bfa13f3"
    private static let pinnedRepository = "mlx-community/Qwen3.5-4B-MLX-4bit"
    private static let pinnedTotalBytes: Int64 = 3_061_129_077
    private static let pinnedWeightBytes: UInt64 = 3_034_300_695

    /// 80 × 50 × 10 mm plate, then a Ø6 through-hole (radius 3).
    private static let expectedPlateVolume = 40_000.0
    private static let expectedVolumeDiameter6 = 39_717.256_661
    /// Same plate with the hole circle edited to radius 4.
    private static let expectedVolumeDiameter8 = 39_497.345_175
    private static let volumeTolerance = 1.0

    private var environment: AppEnvironment!
    private var provider: ProviderProfile!
    private var model: ModelProfile!
    private var conversationID: UUID?
    private var workspaceURL: URL?
    private var documentURL: URL?
    private var services: [ConversationRunService] = []
    private var documentName = ""

    // MARK: - 1. Installed snapshot + host admission (no opt-in required)

    func testPinnedSnapshotIsInstalledAndAdmittedByTheProductionPreflight() async throws {
        environment = try await appQualificationEnvironment()
        provider = LocalProviderAdapter.providerProfile

        let available = LocalInferenceResourcePolicy.availableMemoryBytes()
        let physical = ProcessInfo.processInfo.physicalMemory
        let residentReserved = ResidentMemoryReservations.totalBytes()
        let storeRootForReport = await environment.localModelStore.root
        let hostFacts = "isiOSAppOnMac=\(ProcessInfo.processInfo.isiOSAppOnMac) "
            + "availableMemoryBytes=\(available) physicalMemoryBytes=\(physical) "
            + "residentReserved=\(residentReserved) store=\(storeRootForReport.path)"
        attach("x34-r3-host-memory.txt", hostFacts)

        let configured = try await environment.configurationStore.models(providerID: provider.id)
        guard let model = configured.first(where: { $0.remoteModelID == Self.modelID }) else {
            throw XCTSkip(
                "\(Self.modelID) is not configured. Install the verified snapshot, relaunch the App, "
                    + "and enable the model in Settings > Local Models before rerunning. \(hostFacts)"
            )
        }
        self.model = model

        let installed = await environment.localModelStore.isInstalled(id: Self.modelID)
        guard installed,
              let weightBytes = await environment.localModelStore.installedWeightBytes(id: Self.modelID)
        else {
            throw XCTSkip(
                "No verified \(Self.modelID) snapshot in the App's LocalModelStore. "
                    + "Copy the verified snapshot (see ROOT_QUALIFICATION.md) or download it in "
                    + "Settings > Local Models, then rerun. \(hostFacts)"
            )
        }

        let storeRoot = storeRootForReport
        let directory = storeRoot.appendingPathComponent(Self.modelID, isDirectory: true)
        try assertPinnedManifest(in: directory)

        let canLoad = LocalInferenceResourcePolicy.canLoad(
            mappedBytes: weightBytes,
            physicalMemoryBytes: available,
            reservedBytes: residentReserved
        )
        let preflight = "model=\(Self.modelID) revision=\(Self.pinnedRevision) "
            + "weightBytes=\(weightBytes) " + hostFacts + " canLoad=\(canLoad)"
        attach("x34-r3-host-preflight.txt", preflight)
        XCTAssertTrue(
            canLoad,
            "The production local-model preflight refuses this host: availableMemoryBytes=\(available), "
                + "physicalMemoryBytes=\(physical), weightBytes=\(weightBytes), "
                + "isiOSAppOnMac=\(ProcessInfo.processInfo.isiOSAppOnMac). "
                + "If availableMemoryBytes is 0 on a Designed-for-iPad Mac, the macOS libSystem "
                + "os_proc_available_memory implementation returned 0; run the physical-iPad selector "
                + "instead or treat real MLX as blocked pending a reviewed production change. "
                + "Do not lower the safety rule."
        )
        XCTAssertEqual(weightBytes, Self.pinnedWeightBytes)
        guard canLoad else { return }

        do {
            try await environment.localModelRuntime.preload(modelID: Self.modelID)
        } catch let error as LocalInferenceError {
            if case .runtimeUnavailable(let reason) = error {
                throw XCTSkip("MLX is unavailable on this host: \(reason)")
            }
            throw error
        } catch {
            throw error
        }
        await environment.localModelRuntime.unload(modelID: Self.modelID)
    }

    // MARK: - 2. Real inference → real CAD → measure / undo / save / reopen

    func testActualPinnedMLXModelCreatesMeasuresUndoesAndReopensRealNativeCADDocument() async throws {
        let optIn = try readOptIn()
        let maxSecondsPerTurn = optIn.maxSecondsPerTurn ?? 900
        environment = try await appQualificationEnvironment()
        provider = LocalProviderAdapter.providerProfile
        let configured = try await environment.configurationStore.models(providerID: provider.id)
        guard let model = configured.first(where: { $0.remoteModelID == Self.modelID }) else {
            throw XCTSkip("\(Self.modelID) is not configured/enabled in Settings > Local Models.")
        }
        self.model = model
        XCTAssertEqual(provider.id, ProviderProfile.onDeviceProviderID)
        XCTAssertEqual(model.providerID, ProviderProfile.onDeviceProviderID,
                       "The qualification must run on the on-device provider, never a paid/cloud fallback.")
        XCTAssertEqual(model.remoteModelID, Self.modelID)
        XCTAssertTrue(model.isEnabled, "\(Self.modelID) must be enabled before this selector runs.")
        XCTAssertTrue(model.capabilities.contains(.tools), "The pinned MLX model must be tool-capable.")
        XCTAssertFalse(model.capabilities.contains(.vision), "The pinned Qwen snapshot is text-only.")
        guard await environment.localModelStore.isInstalled(id: Self.modelID) else {
            throw XCTSkip("No verified \(Self.modelID) snapshot in the App's LocalModelStore.")
        }
        let storeRoot = await environment.localModelStore.root
        try assertPinnedManifest(in: storeRoot.appendingPathComponent(Self.modelID, isDirectory: true))
        await environment.localModelsCenter.refresh()
        XCTAssertTrue(environment.localModelsCenter.installedIDs.contains(Self.modelID))
        XCTAssertTrue(environment.localModelsCenter.isEnabled(remoteModelID: Self.modelID))

        do {
            try await environment.localModelRuntime.preload(modelID: Self.modelID)
        } catch let error as LocalInferenceError {
            if case .runtimeUnavailable(let reason) = error {
                throw XCTSkip("MLX is unavailable on this host: \(reason)")
            }
            throw error
        }

        documentName = "x34-r3-local-mlx-\(UUID().uuidString.prefix(8)).floecad"
        var succeeded = false
        do {
            // Turn 1 — plate only. Keeps each real-model turn small enough for
            // the guaranteed local window instead of asking a 4B model to
            // chain ten tool calls at once.
            let firstGoal = firstTurnGoal()
            try assertCanonicalSchemaIsAdmitted(for: firstGoal)
            let firstEvents = try await runTurn(goal: firstGoal, firstTurn: true, maxSeconds: maxSecondsPerTurn)
            let firstReceipt = try assertCADTurn(firstEvents, label: "plate/create/save")
            XCTAssertTrue(firstReceipt.actions.contains("create"), "turn 1: \(firstReceipt.actions)")
            XCTAssertTrue(firstReceipt.actions.contains("propose") || firstReceipt.actions.contains("apply"),
                          "turn 1: \(firstReceipt.actions)")
            XCTAssertTrue(firstReceipt.actions.contains("measure"), "turn 1: \(firstReceipt.actions)")
            XCTAssertTrue(firstReceipt.actions.contains("save"), "turn 1: \(firstReceipt.actions)")

            let url = try findDocument()
            documentURL = url
            let afterPlate = try await inspectDocument(at: url)
            XCTAssertEqual(afterPlate.bodyCount, 1, "The created package must contain one analytic body.")
            XCTAssertTrue(afterPlate.bodyIsAnalytic, "The created body must be an analytic B-rep.")
            XCTAssertEqual(afterPlate.circles.count, 0, "The plate turn must not create a hole circle.")
            XCTAssertEqual(afterPlate.volume, Self.expectedPlateVolume, accuracy: Self.volumeTolerance)
            XCTAssertNotNil(afterPlate.modelSHA256,
                            "The package did not expose the additive canonical model identity.")
            attach("x34-r3-after-plate.txt", afterPlate.description)

            // Turn 2 — Ø6 through-hole on the SAME plate body.
            let secondGoal = secondTurnGoal(bodyID: afterPlate.bodyID)
            let secondEvents = try await runTurn(goal: secondGoal, firstTurn: false, maxSeconds: maxSecondsPerTurn)
            let secondReceipt = try assertCADTurn(secondEvents, label: "hole/measure/save")
            XCTAssertTrue(secondReceipt.actions.contains("propose") || secondReceipt.actions.contains("apply"),
                          "turn 2: \(secondReceipt.actions)")
            XCTAssertTrue(secondReceipt.actions.contains("measure"), "turn 2: \(secondReceipt.actions)")
            XCTAssertTrue(secondReceipt.actions.contains("save"), "turn 2: \(secondReceipt.actions)")

            let afterHole = try await inspectDocument(at: url)
            XCTAssertEqual(afterHole.bodyCount, 1)
            XCTAssertTrue(afterHole.bodyIsAnalytic, "The cut body must remain an analytic B-rep.")
            XCTAssertEqual(afterHole.circles.count, 1, "The package must contain the Ø6 hole circle.")
            let createCircle = try XCTUnwrap(afterHole.circles.first)
            XCTAssertEqual(createCircle.radius, 3, accuracy: 1e-6)
            XCTAssertEqual(afterHole.volume, Self.expectedVolumeDiameter6, accuracy: Self.volumeTolerance)
            XCTAssertGreaterThan(afterHole.revision, afterPlate.revision)
            XCTAssertNotNil(afterHole.modelSHA256)
            XCTAssertNotEqual(afterHole.modelSHA256, afterPlate.modelSHA256,
                              "The hole must change the canonical CAD model identity.")
            attach("x34-r3-after-hole.txt", afterHole.description)

            // Turn 3 — edit the SAME hole circle 3 → 4 and save.
            let thirdGoal = thirdTurnGoal(bodyID: afterHole.bodyID)
            let thirdEvents = try await runTurn(goal: thirdGoal, firstTurn: false, maxSeconds: maxSecondsPerTurn)
            let thirdReceipt = try assertCADTurn(thirdEvents, label: "edit/measure/save")
            XCTAssertTrue(thirdReceipt.actions.contains("parameters"), "turn 3: \(thirdReceipt.actions)")
            XCTAssertTrue(thirdReceipt.actions.contains("save"), "turn 3: \(thirdReceipt.actions)")

            let afterEdit = try await inspectDocument(at: url)
            XCTAssertEqual(afterEdit.bodyCount, 1)
            XCTAssertTrue(afterEdit.bodyIsAnalytic)
            XCTAssertEqual(afterEdit.bodyID, afterHole.bodyID,
                           "Editing the hole must keep the same body identity.")
            XCTAssertEqual(afterEdit.circles.count, 1, "The edit must keep exactly one hole circle.")
            let editCircle = try XCTUnwrap(afterEdit.circles.first)
            XCTAssertEqual(editCircle.radius, 4, accuracy: 1e-6)
            XCTAssertEqual(editCircle.sketchID, createCircle.sketchID,
                           "The edit must reuse the same hole sketch.")
            XCTAssertEqual(editCircle.entityID, createCircle.entityID,
                           "The edit must reuse the same circle entity.")
            XCTAssertEqual(afterEdit.volume, Self.expectedVolumeDiameter8, accuracy: Self.volumeTolerance)
            XCTAssertGreaterThan(afterEdit.revision, afterHole.revision, "The edit turn must commit a newer revision.")
            XCTAssertNotNil(afterEdit.modelSHA256)
            XCTAssertNotEqual(afterEdit.modelSHA256, afterHole.modelSHA256,
                              "The edit must change the canonical CAD model identity.")
            attach("x34-r3-after-edit.txt", afterEdit.description)

            // Turn 4 — real native undo of the radius edit, then save.
            let fourthGoal = fourthTurnGoal(bodyID: afterHole.bodyID)
            let fourthEvents = try await runTurn(goal: fourthGoal, firstTurn: false, maxSeconds: maxSecondsPerTurn)
            let fourthReceipt = try assertCADTurn(fourthEvents, label: "undo/measure/save")
            XCTAssertTrue(fourthReceipt.actions.contains("parameters"), "turn 4: \(fourthReceipt.actions)")
            XCTAssertTrue(fourthReceipt.undoRequests > 0,
                          "turn 4 did not send the real parameters undo payload: \(fourthReceipt.actions)")
            XCTAssertTrue(fourthReceipt.actions.contains("save"), "turn 4: \(fourthReceipt.actions)")

            let afterUndo = try await inspectDocument(at: url)
            XCTAssertEqual(afterUndo.bodyCount, 1)
            XCTAssertTrue(afterUndo.bodyIsAnalytic)
            XCTAssertEqual(afterUndo.bodyID, afterHole.bodyID)
            XCTAssertEqual(afterUndo.circles.count, 1)
            let undoCircle = try XCTUnwrap(afterUndo.circles.first)
            XCTAssertEqual(undoCircle.radius, 3, accuracy: 1e-6,
                           "The native undo must restore the Ø6 circle.")
            XCTAssertEqual(undoCircle.sketchID, createCircle.sketchID)
            XCTAssertEqual(undoCircle.entityID, createCircle.entityID)
            XCTAssertEqual(afterUndo.volume, Self.expectedVolumeDiameter6, accuracy: Self.volumeTolerance,
                           "The native undo must restore the plate-minus-Ø6 geometry.")
            XCTAssertGreaterThan(afterUndo.revision, afterEdit.revision,
                                 "The undo turn must commit a newer revision than the edited state.")
            XCTAssertNotNil(afterUndo.modelSHA256)
            XCTAssertEqual(afterUndo.modelSHA256, afterHole.modelSHA256,
                           "Native undo must restore the exact pre-edit canonical model identity.")
            attach("x34-r3-after-undo.txt", afterUndo.description)

            // Owner close/reopen: the live instance must be replaced, the saved
            // canonical identity must survive, and the geometry must still be
            // the undo-restored Ø6 part.
            let liveBeforeClose = try await FloeCAD3DBridge.shared.openDocument(at: url)
            XCTAssertEqual(liveBeforeClose.revision, afterUndo.revision)
            XCTAssertEqual(liveBeforeClose.modelSHA256, afterUndo.modelSHA256 ?? "")
            let previousInstance = ObjectIdentifier(liveBeforeClose)
            await FloeCAD3DBridge.shared.releaseDocument(at: url)
            let reopened = try await FloeCAD3DBridge.shared.openDocument(at: url)
            XCTAssertNotEqual(previousInstance, ObjectIdentifier(reopened),
                              "The owner close/reopen must replace the live document instance.")
            XCTAssertFalse(reopened.isReadOnly)
            XCTAssertGreaterThanOrEqual(reopened.revision, afterUndo.revision)
            XCTAssertEqual(reopened.modelSHA256, afterUndo.modelSHA256 ?? "",
                           "Close/reopen must not change the undo-restored canonical model identity.")

            let afterReopen = try await inspectDocument(at: url)
            XCTAssertEqual(afterReopen.bodyCount, 1)
            XCTAssertTrue(afterReopen.bodyIsAnalytic)
            XCTAssertEqual(afterReopen.circles.count, 1)
            XCTAssertEqual(afterReopen.bodyID, afterHole.bodyID)
            let reopenCircle = try XCTUnwrap(afterReopen.circles.first)
            XCTAssertEqual(reopenCircle.radius, 3, accuracy: 1e-6)
            XCTAssertEqual(reopenCircle.sketchID, createCircle.sketchID)
            XCTAssertEqual(reopenCircle.entityID, createCircle.entityID)
            XCTAssertEqual(afterReopen.volume, Self.expectedVolumeDiameter6, accuracy: Self.volumeTolerance,
                           "The reopened package must retain the real undo-restored geometry.")
            XCTAssertEqual(afterReopen.modelSHA256, afterUndo.modelSHA256,
                           "The reopened package must match the verified undo state.")
            XCTAssertEqual(afterReopen.revision, reopened.revision)
            XCTAssertEqual(afterReopen.contentSHA256, reopened.contentSHA256)
            attach("x34-r3-after-reopen.txt", afterReopen.description)
            attach("x34-r3-qualification-summary.txt",
                   "model=\(Self.modelID) revisionPin=\(Self.pinnedRevision) "
                       + "plateRevision=\(afterPlate.revision) holeRevision=\(afterHole.revision) "
                       + "editRevision=\(afterEdit.revision) undoRevision=\(afterUndo.revision) "
                       + "reopenRevision=\(afterReopen.revision) "
                       + "volumePlate=\(afterPlate.volume) volumeHole=\(afterHole.volume) "
                       + "volumeEdit=\(afterEdit.volume) volumeUndo=\(afterUndo.volume) "
                       + "volumeReopen=\(afterReopen.volume) "
                       + "modelSHAStableAfterUndo=\(afterUndo.modelSHA256 == afterHole.modelSHA256) "
                       + "turnSecondsCeiling=\(Int(maxSecondsPerTurn))")
            // XCTest assertions record failures without throwing. Retain this
            // owned task and its native document whenever any assertion failed.
            succeeded = testRun.map { $0.totalFailureCount == 0 } ?? false
        } catch {
            await cleanup(deleteConversation: false)
            throw error
        }
        await cleanup(deleteConversation: succeeded)
    }

    // MARK: - Turn execution (production App run service)

    private struct TurnReceipt {
        var actions: [String]
        var undoRequests: Int
        var requestCount: Int
    }

    private func runTurn(goal: String, firstTurn: Bool, maxSeconds: Double) async throws -> [RunEventRecord] {
        let runID = UUID()
        let conversation = firstTurn ? (conversationID ?? UUID()) : conversationID!
        let prepared = try await environment.runLaunchStore.prepare(RunLaunchRequest(
            conversationID: firstTurn ? nil : conversation,
            newConversationID: firstTurn ? conversation : nil,
            conversationTitle: "X34 R3 local MLX CAD",
            runID: runID,
            goal: goal,
            workspaceID: firstTurn ? nil : workspaceRecordID,
            conversationMode: ConversationMode.chat.rawValue,
            initialPolicy: DraftTaskPolicy(approvalMode: .automatic),
            providerID: provider.id,
            modelID: model.id,
            providerName: provider.displayName ?? "On-device",
            modelName: model.displayName,
            providerProfile: provider,
            modelProfile: model
        ))
        if firstTurn {
            conversationID = conversation
            workspaceRecordID = prepared.workspace.id
            workspaceURL = try workspaceRoot(for: prepared.workspace, conversationID: conversation)
        }
        try await saveOwnedPolicy(conversationID: conversation)
        let history = try await ConversationHistoryAssembler(store: environment.conversationStore)
            .build(conversationID: conversation, excludingMessageID: prepared.userMessage.id)
        let service = try await environment.conversationCenter.runService(
            for: conversation,
            provider: provider,
            model: model,
            runID: runID,
            executionMode: .agent,
            runSurface: .ordinary,
            workspaceID: prepared.workspace.id,
            memoryQuery: "",
            conversationHistory: history,
            automaticReasoningEffortIngress: .continuation
        )
        services.append(service)
        do {
            try await service.startPrepared(goal: goal)
            try await awaitTerminal(service: service, timeout: maxSeconds)
        } catch {
            await service.cancel()
            throw error
        }
        return try await environment.runStore.events(runID: runID)
    }

    private func saveOwnedPolicy(conversationID: UUID) async throws {
        let policy = TaskPolicy(
            conversationID: conversationID,
            approvalMode: TaskApprovalMode.automatic.rawValue,
            allowedToolNames: Set([CadDocumentTool.name]),
            filePaths: [],
            networkAllowed: false,
            browserControlAllowed: false,
            uploadAllowed: false,
            credentialsAllowed: false,
            remoteExecutionAllowed: false,
            recoveryPolicy: .safePoint,
            notificationPolicy: .stages
        )
        try await SQLiteWorkspaceStore(database: environment.database).saveTaskPolicy(policy)
    }

    private func awaitTerminal(service: ConversationRunService, timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var snapshot = await service.snapshot()
        while !snapshot.isTerminal, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
            snapshot = await service.snapshot()
        }
        XCTAssertTrue(
            snapshot.isTerminal,
            "The local-model run did not reach a terminal state within \(Int(timeout)) s "
                + "(last state \(snapshot.stateName))."
        )
        XCTAssertEqual(snapshot.stateName, "completed",
                       "The local-model run ended in state \(snapshot.stateName).")
        XCTAssertNil(snapshot.pendingApproval,
                     "A cad.document call waited for interactive approval under an automatic policy.")
    }

    // MARK: - Evidence assertions

    private func assertCADTurn(_ events: [RunEventRecord], label: String) throws -> TurnReceipt {
        var requests: [[String: Any]] = []
        var statuses: [String] = []
        var approvals = 0
        for event in events {
            guard let payload = jsonObject(event.payloadJSON) else { continue }
            if event.kind == .approval { approvals += 1 }
            let toolName = payload["tool"] as? String
            let discoveryTool = toolName == "tools.search" || toolName == "tools.list"
            if event.kind == .toolRequest, let toolName,
               toolName != CadDocumentTool.name, !discoveryTool {
                XCTFail("\(label): the model requested non-CAD, non-discovery tool '\(toolName)'.")
            }
            guard toolName == CadDocumentTool.name else { continue }
            if event.kind == .toolRequest {
                let input = payload["input"] as? String ?? "{}"
                if let arguments = jsonObject(input) {
                    requests.append(arguments)
                } else {
                    XCTFail("\(label): cad.document arguments were not a JSON object: \(input.prefix(200))")
                    requests.append([:])
                }
            } else if event.kind == .toolResult {
                statuses.append(payload["status"] as? String ?? "")
            }
        }
        XCTAssertEqual(approvals, 0, "\(label): the automatic policy must not ask for approval.")
        XCTAssertFalse(requests.isEmpty, "\(label): no cad.document call was requested. Prose is not execution.")
        XCTAssertFalse(statuses.isEmpty, "\(label): no cad.document result was recorded.")
        XCTAssertTrue(statuses.contains("ok"),
                      "\(label): every cad.document call failed: \(statuses)")
        XCTAssertFalse(statuses.contains("needsUser"),
                       "\(label): a cad.document call stopped for interactive user input.")
        XCTAssertFalse(
            requests.contains { request in
                guard let grant = request["grant_id"] as? String else { return false }
                return !grant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            },
            "\(label): the model supplied a grant_id; automatic apply must use runtime authority."
        )
        let undoRequests = requests.filter { request in
            guard (request["action"] as? String) == "parameters",
                  let payload = request["payload"] as? String,
                  let payloadObject = jsonObject(payload) else { return false }
            return (payloadObject["action"] as? String) == "undo"
        }.count
        let alias = [
            "three_d_propose": "propose",
            "three_d_apply": "apply",
            "three_d_measure": "measure",
            "three_d_snapshot": "read",
            "three_d_assembly": "assembly",
            "three_d_drawing": "drawing",
        ]
        return TurnReceipt(
            actions: requests.compactMap { $0["action"] as? String }.map { alias[$0] ?? $0 },
            undoRequests: undoRequests,
            requestCount: requests.count
        )
    }

    private func assertCanonicalSchemaIsAdmitted(for goal: String) throws {
        let descriptor = ToolSchemaDescriptor(
            name: CadDocumentTool.name,
            description: CadDocumentTool.toolDescription,
            parametersJSON: CadDocumentTool.parametersJSON
        )
        let build = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [("user", goal)],
            toolSchemas: [descriptor],
            allToolNames: [descriptor.name]
        ))
        let admitted = build.selectedTools.contains { $0.name == CadDocumentTool.name }
        let note = "model=\(Self.modelID) contextTokens=\(model.limits.contextTokens) "
            + "maxOutputTokens=\(model.limits.maxOutputTokens) "
            + "windowPromptTokens=\(build.windowPromptTokenBudget) "
            + "estimatedPromptTokens=\(build.estimatedPromptTokens) "
            + "cadSelected=\(admitted) "
            + "cadFallback=\(build.fallbackTools.contains { $0.name == CadDocumentTool.name }) "
            + "schemaDescriptionBytes=\(CadDocumentTool.toolDescription.utf8.count) "
            + "schemaParametersBytes=\(CadDocumentTool.parametersJSON.utf8.count)"
        attach("x34-r3-cad-admission.txt", note)
        XCTAssertTrue(
            admitted,
            "The complete canonical cad.document schema was not admitted for this model window. "
                + "The runtime must never be asked to run a schema-only or sliced CAD contract. "
                + "\(note)"
        )
    }

    private func assertPinnedManifest(in directory: URL) throws {
        let manifestURL = directory.appendingPathComponent(LocalModelStore.installManifestName)
        let data = try Data(contentsOf: manifestURL)
        let json = try JSONSerialization.jsonObject(with: data)
        let object = try XCTUnwrap(json as? [String: Any],
                                   "The install manifest is not a JSON object.")
        XCTAssertEqual(object["modelID"] as? String, Self.modelID)
        XCTAssertEqual(object["repository"] as? String, Self.pinnedRepository)
        XCTAssertEqual(object["revision"] as? String, Self.pinnedRevision,
                       "The installed snapshot is not the approved immutable revision.")
        XCTAssertEqual(object["format"] as? String, "mlx")
        let artifacts = try XCTUnwrap(object["artifacts"] as? [[String: Any]])
        XCTAssertEqual(artifacts.count, 10, "The pinned snapshot has 10 allowlisted artifacts.")
        let total = artifacts.reduce(Int64(0)) { sum, artifact in
            sum + ((artifact["byteCount"] as? NSNumber)?.int64Value ?? 0)
        }
        XCTAssertEqual(total, Self.pinnedTotalBytes)
        let weights = directory.appendingPathComponent("model.safetensors")
        let weightFileSize = try weights.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        XCTAssertEqual(weightFileSize, Int(Self.pinnedWeightBytes))
    }

    // MARK: - Independent document inspection (real FloeCAD, no model prose)

    private struct HoleCircle {
        var sketchID: String
        var entityID: String
        var radius: Double
    }

    private struct DocumentState {
        var revision: Int
        var contentSHA256: String
        var modelSHA256: String?
        var bodyCount: Int
        var sketchCount: Int
        var featureCount: Int
        var bodyID: String
        var bodyIsAnalytic: Bool
        var volume: Double
        var circles: [HoleCircle]

        var description: String {
            "revision=\(revision) contentSHA256=\(contentSHA256.prefix(16)) "
                + "modelSHA256=\((modelSHA256 ?? "nil").prefix(16)) bodies=\(bodyCount) "
                + "sketches=\(sketchCount) features=\(featureCount) analytic=\(bodyIsAnalytic) "
                + "volumeMM3=\(volume) circleRadii=\(circles.map(\.radius))"
        }
    }

    private func inspectDocument(at url: URL) async throws -> DocumentState {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "The package is missing: \(url.path)")
        let manifest = url.appendingPathComponent("manifest.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path),
                      "The versioned package has no manifest.json.")
        let storedOptional = await FloeCADDocument.storedIdentity(at: url)
        let stored = try XCTUnwrap(
            storedOptional,
            "The versioned store rejected the package identity."
        )
        let document = try await FloeCADDocument.open(at: url)
        defer { document.close() }
        let summary = document.summary()
        let bodies = try rows(document, scope: "bodies")
        let body = try XCTUnwrap(bodies.first, "The package has no body.")
        let bodyID = try XCTUnwrap(body["id"] as? String, "The body row has no id.")
        let isAnalytic = (body["analyticBRep"] as? Bool) == true
        let outcome = document.measureJSON(["kind": "body", "bodyID": bodyID])
        XCTAssertTrue(outcome.isOK, "measure body failed: \(outcome.errorCode ?? "unknown") \(outcome.message ?? "")")
        let measure = try XCTUnwrap(jsonObject(outcome.payload), "measure body payload is not JSON.")
        let volume = try XCTUnwrap(number(measure["volumeMM3"]), "measure body has no volumeMM3.")
        var circles: [HoleCircle] = []
        for sketch in try rows(document, scope: "sketches") {
            guard let sketchID = sketch["id"] as? String,
                  let entityRows = sketch["entityRows"] as? [[String: Any]] else { continue }
            for row in entityRows {
                guard (row["kind"] as? String) == "circle",
                      (row["construction"] as? Bool) != true,
                      let entityID = row["id"] as? String,
                      let radius = number(row["radius"]) else { continue }
                circles.append(HoleCircle(sketchID: sketchID, entityID: entityID, radius: radius))
            }
        }
        return DocumentState(
            revision: stored.revision,
            contentSHA256: stored.contentSHA256,
            modelSHA256: stored.modelSHA256,
            bodyCount: summary.bodyCount,
            sketchCount: summary.sketchCount,
            featureCount: summary.featureCount,
            bodyID: bodyID,
            bodyIsAnalytic: isAnalytic,
            volume: volume,
            circles: circles
        )
    }

    private func rows(_ document: FloeCADDocument, scope: String) throws -> [[String: Any]] {
        let outcome = document.nativeQueryJSON(["scope": scope])
        guard outcome.isOK else {
            throw NSError(domain: "X34R3", code: 10, userInfo: [
                NSLocalizedDescriptionKey:
                    "query \(scope) failed: \(outcome.errorCode ?? "unknown") \(outcome.message ?? "")"
            ])
        }
        let object = try XCTUnwrap(jsonObject(outcome.payload), "query \(scope) payload is not JSON.")
        return (object["rows"] as? [[String: Any]]) ?? []
    }

    // MARK: - Prompts (exact, small, text-only; no images)

    private func firstTurnGoal() -> String {
        """
        Use only the cad.document tool. Work in the current task workspace; never write package bytes by hand. Every cad.document call uses path "\(documentName)".

        Build one real native plate at "\(documentName)" by calling the tool for every step:
        1. action "create", path "\(documentName)", name "X34 R3 local MLX plate".
        2. action "propose", op "sketch.create", args {"name":"plate"}; then action "apply" with the exact proposal_id it returned. Omit grant_id.
        3. action "propose", op "sketch.addEntities", args {"sketchID":"<id returned by step 2>","entities":[{"kind":"rect","min":[0,0],"max":[80,50]}]}; apply it.
        4. action "propose", op "feature.extrude", args {"sketchID":"<same sketch id>","seedPoint":[40,25],"distance":10}; apply it.
        5. action "save" with the same path.
        6. action "query", kind "bodies"; keep the plate body id.
        7. action "measure", kind "body", handles ["body:<plate body id>"].
        Apply every proposal and do not skip a step. Report only values the tool replies actually returned and do not claim success without a tool result.
        """
    }

    private func secondTurnGoal(bodyID: String) -> String {
        """
        The same native CAD document "\(documentName)" is open and saved. Cut one Ø6 through-hole at [40,25] through the existing plate body. Every cad.document call uses path "\(documentName)".
        1. action "query", kind "bodies" to confirm the plate body id.
        2. action "propose", op "sketch.create", args {"name":"hole"}; apply it.
        3. action "propose", op "sketch.addEntities", args {"sketchID":"<hole sketch id>","entities":[{"kind":"circle","center":[40,25],"radius":3}]}; apply it.
        4. action "propose", op "feature.extrude", args {"sketchID":"<hole sketch id>","seedPoint":[40,25],"distance":40,"symmetric":true,"boolean":"subtract","booleanTargets":["\(bodyID)"]}; apply it.
        5. action "save" with the same path.
        6. action "query", kind "bodies"; read the CURRENT body id from the reply.
        7. action "measure", kind "body", handles ["body:<current body id from step 6>"].
        8. action "query", kind "sketches" and kind "features".
        Do not create a second plate or a second hole, and do not use any tool other than cad.document. Report only values the tool returned.
        """
    }

    private func thirdTurnGoal(bodyID: String) -> String {
        """
        The same native CAD document "\(documentName)" is open and saved. Change only the existing Ø6 hole circle to radius 4 (Ø8). Every cad.document call uses path "\(documentName)".
        1. action "query", kind "sketches". Find the single non-construction circle in the hole sketch; keep its sketch id, entity id and current radius 3.
        2. action "parameters", payload {"action":"updateSketchEntity","sketch_id":"<id>","entity_id":"<id>","radius":4,"expected_radius":3}.
        3. action "measure", kind "body", handles ["body:\(bodyID)"].
        4. action "save" with the same path.
        Do not create a new hole, sketch or body, and do not use any tool other than cad.document. Report only values the tool returned.
        """
    }

    private func fourthTurnGoal(bodyID: String) -> String {
        """
        The same native CAD document "\(documentName)" is open. The last edit changed the hole circle radius from 3 to 4. Undo exactly that edit with the real native undo command, then save and read back. Every cad.document call uses path "\(documentName)".
        1. action "parameters", payload {"action":"undo"}.
        2. action "query", kind "sketches" and kind "features".
        3. action "measure", kind "body", handles ["body:\(bodyID)"].
        4. action "save" with the same path.
        Do not run redo, do not edit geometry, and do not create anything. Report only values the tool returned.
        """
    }

    // MARK: - Opt-in / paths / cleanup

    private struct OptIn: Decodable {
        var modelID: String
        var maxSecondsPerTurn: Double?
    }

    private func readOptIn() throws -> OptIn {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloeLocalMLXCADQualification/opt-in.json")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip(
                "No opt-in file at \(url.path). Write {\"modelID\":\"\(Self.modelID)\","
                    + "\"maxSecondsPerTurn\":900} to run this live selector."
            )
        }
        let optIn = try JSONDecoder().decode(OptIn.self, from: data)
        guard optIn.modelID == Self.modelID else {
            throw XCTSkip("The opt-in names \(optIn.modelID); this qualification is pinned to \(Self.modelID).")
        }
        return optIn
    }

    private var workspaceRecordID: UUID!

    private func workspaceRoot(for workspace: WorkspaceRecord, conversationID: UUID) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let relative = workspace.internalRelativePath ?? "PrivateTasks/\(conversationID.uuidString)"
        return support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relative, isDirectory: true)
    }

    private func findDocument() throws -> URL {
        let root = try XCTUnwrap(workspaceURL, "The task workspace root is unknown.")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            throw NSError(domain: "X34R3", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "The task workspace could not be enumerated."
            ])
        }
        var matches: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "floecad" else { continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                matches.append(url)
            }
        }
        guard let match = matches.first(where: {
            $0.deletingPathExtension().lastPathComponent == documentName
                .replacingOccurrences(of: ".floecad", with: "")
        }) else {
            throw NSError(domain: "X34R3", code: 12, userInfo: [
                NSLocalizedDescriptionKey:
                    "The model reported a create but no .floecad package exists in the task workspace."
            ])
        }
        return match
    }

    private func cleanup(deleteConversation: Bool) async {
        for service in services {
            await service.cancel()
        }
        for service in services {
            var snapshot = await service.snapshot()
            for _ in 0..<50 where !snapshot.isTerminal {
                try? await Task.sleep(for: .milliseconds(100))
                snapshot = await service.snapshot()
            }
        }
        services.removeAll()
        if let ownedDocument = documentURL {
            await FloeCAD3DBridge.shared.releaseDocument(at: ownedDocument)
        }
        if deleteConversation, let ownedConversation = conversationID {
            try? await environment.conversationCenter.deleteConversation(id: ownedConversation)
            if let ownedWorkspace = workspaceURL,
               FileManager.default.fileExists(atPath: ownedWorkspace.path) {
                XCTFail("The owned task workspace still exists after conversation deletion: \(ownedWorkspace.path)")
            }
        }
        await environment.localModelRuntime.unload(modelID: Self.modelID)
    }

    // MARK: - Small helpers

    private func attach(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Int { return Double(value) }
        return nil
    }
}
#endif

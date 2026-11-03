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
// Original creation selector (no fixture, no echo provider, no hand-written package):
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
@testable import FloeCAD

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

    // MARK: - X34 reachability, distinct from the original creation workflow

    // These selectors supply a TEST-CREATED native fixture. They prove tool
    // reachability, not model-generated geometry or visual understanding.
    func testActualPinnedMLXCanQueryEditUndoSaveAndColdReopenSuppliedNativeCADFixture() async throws {
        let optIn = try readReachabilityOptIn(provider: "mlx", modelID: Self.modelID)
        environment = try await appQualificationEnvironment()
        provider = LocalProviderAdapter.providerProfile
        try await selectConfiguredReachabilityModel(Self.modelID)
        guard await environment.localModelStore.isInstalled(id: Self.modelID) else {
            throw reachabilityFailure("The pinned MLX snapshot is not installed.")
        }
        let storeRoot = await environment.localModelStore.root
        try assertPinnedManifest(in: storeRoot.appendingPathComponent(Self.modelID, isDirectory: true))
        // Production admission/preflight errors remain real failures, never a
        // skip, reduced safety threshold, substitute model or cloud fallback.
        do {
            try await environment.localModelRuntime.preload(modelID: Self.modelID)
            try await runSuppliedDocumentReachability(label: "mlx", maxSeconds: optIn.maxSecondsPerTurn ?? 240)
        } catch {
            attach("x34-reachability-mlx-error.txt", String(describing: error))
            await cleanup(deleteConversation: false)
            throw error
        }
    }

    func testFoundationAvailabilityAndAdvertisedCapabilitiesAreTruthful() async throws {
        environment = try await appQualificationEnvironment()
        provider = LocalProviderAdapter.providerProfile
        _ = try await assertFoundationAvailabilityAndCapabilities()
    }

    func testActualFoundationCanQueryEditUndoSaveAndColdReopenSuppliedNativeCADFixture() async throws {
        environment = try await appQualificationEnvironment()
        provider = LocalProviderAdapter.providerProfile
        _ = try await assertFoundationAvailabilityAndCapabilities()
        let optIn = try readReachabilityOptIn(
            provider: "foundation", modelID: AppleFoundationModelIdentity.remoteModelID)
        try await selectConfiguredReachabilityModel(AppleFoundationModelIdentity.remoteModelID)
        do {
            try await runSuppliedDocumentReachability(
                label: "foundation", maxSeconds: optIn.maxSecondsPerTurn ?? 240)
        } catch {
            attach("x34-reachability-foundation-error.txt", String(describing: error))
            await cleanup(deleteConversation: false)
            throw error
        }
    }

    private func selectConfiguredReachabilityModel(_ remoteID: String) async throws {
        let configured = try await environment.configurationStore.models(providerID: provider.id)
        guard let selected = configured.first(where: { $0.remoteModelID == remoteID }) else {
            throw reachabilityFailure("The actual on-device model row is not configured: \(remoteID).")
        }
        model = selected
        let facts = "providerID=\(provider.id) modelID=\(selected.id) remoteID=\(remoteID) "
            + "enabled=\(selected.isEnabled) text=\(selected.capabilities.contains(.text)) "
            + "tools=\(selected.capabilities.contains(.tools)) vision=\(selected.capabilities.contains(.vision)) "
            + "qualificationInput=text-only visualInferenceTested=false cloudFallback=false"
        attach("x34-reachability-selected-model.txt", facts)
        guard provider.id == ProviderProfile.onDeviceProviderID,
              selected.providerID == provider.id, selected.isEnabled,
              selected.capabilities.contains(.text), selected.capabilities.contains(.tools) else {
            throw reachabilityFailure("Selected on-device model is disabled or lacks tools. \(facts)")
        }
        // Neither this selector nor the availability check writes model settings.
        // Explicit user capability overrides are recorded, never silently reset.
        if remoteID == Self.modelID {
            XCTAssertFalse(selected.capabilities.contains(.vision), "The pinned MLX snapshot is text-only.")
        }
    }

    @discardableResult
    private func assertFoundationAvailabilityAndCapabilities() async throws -> AppleFoundationModelAvailability {
        let availability = await AppleFoundationModelRuntime.shared.availability()
        let adapter = LocalProviderAdapter(runtime: environment.localModelRuntime, store: environment.localModelStore)
        let advertised = try await adapter.listModels(provider: provider, credentials: ProviderCredentials())
        let row = try XCTUnwrap(advertised.first { $0.id == AppleFoundationModelIdentity.profileID },
                               "The system-model row must remain visible even when unavailable.")
        let configured = try await environment.configurationStore.models(providerID: provider.id)
            .first { $0.remoteModelID == AppleFoundationModelIdentity.remoteModelID }
        let reason = AppleFoundationModelRuntime.unavailableMessage(for: availability)
        attach("x34-foundation-availability-capabilities.txt",
               "sdkIntegrationCompiled=\(AppleFoundationModelRuntime.sdkIntegrationCompiled) "
                + "availability=\(String(describing: availability)) reason=\(reason) "
                + "displayName=\(row.displayName) text=\(row.capabilities.contains(.text)) "
                + "tools=\(row.capabilities.contains(.tools)) directVision=\(row.capabilities.contains(.vision)) "
                + "configuredEnabled=\(configured?.isEnabled.description ?? "absent") "
                + "configuredTools=\(configured?.capabilities.contains(.tools).description ?? "absent") "
                + "configuredVision=\(configured?.capabilities.contains(.vision).description ?? "absent") "
                + "qualificationInput=text-only visualInferenceTested=false cloudFallback=false")
        XCTAssertEqual(row.providerID, ProviderProfile.onDeviceProviderID)
        XCTAssertEqual(row.remoteModelID, AppleFoundationModelIdentity.remoteModelID)
        XCTAssertTrue(row.capabilities.contains(.text))
        XCTAssertFalse(row.capabilities.contains(.vision), "Production UI must not promise unqualified direct vision.")
        if case .available(let tokens, _, let tools, _) = availability {
            XCTAssertEqual(row.limits.contextTokens, tokens)
            XCTAssertEqual(row.capabilities.contains(.tools), tools)
            guard tools else { throw reachabilityFailure("Foundation is available but tool calling is unavailable.") }
        } else {
            XCTAssertFalse(row.capabilities.contains(.tools))
            XCTAssertTrue(row.displayName.contains(reason), "The visible row must include the actual unavailable reason.")
            throw reachabilityFailure("Foundation is not ready: \(reason); \(availability). No system setting changed.")
        }
        return availability
    }

    private struct ReachabilityState {
        var bodyID: String
        var featureIDs: [String]
        var sketchIDs: [String]
        var circle: HoleCircle
        var volume: Double
        var undoDepth: Int
        var redoDepth: Int
        var modelSHA256: String
        var revision: Int
    }

    private func reachabilityState(_ document: FloeCADDocument) throws -> ReachabilityState {
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty, "\(document.session.lastEvalErrors)")
        let bodies = try rows(document, scope: "bodies")
        XCTAssertEqual(bodies.count, 1)
        let bodyRow = try XCTUnwrap(bodies.first)
        XCTAssertEqual(bodyRow["analyticBRep"] as? Bool, true)
        let bodyID = try XCTUnwrap(bodyRow["id"] as? String)
        let body = try XCTUnwrap(document.session.document.bodies.first {
            $0.id.raw.uuidString.caseInsensitiveCompare(bodyID) == .orderedSame
        })
        // Independent OCCT BRep measurement, not the model/tool's volume text.
        let shape = try XCTUnwrap(body.brep, "The supplied document must contain a real native BRep.")
        let volume = abs(OCCTKernel.volume(shape))
        XCTAssertTrue(volume.isFinite)
        let sketches = try rows(document, scope: "sketches")
        var circles: [HoleCircle] = []
        for sketch in sketches {
            for entity in sketch["entityRows"] as? [[String: Any]] ?? [] {
                if entity["kind"] as? String == "circle", entity["construction"] as? Bool != true {
                    circles.append(HoleCircle(sketchID: try XCTUnwrap(sketch["id"] as? String),
                                              entityID: try XCTUnwrap(entity["id"] as? String),
                                              radius: try XCTUnwrap(number(entity["radius"]))))
                }
            }
        }
        XCTAssertEqual(circles.count, 1)
        return ReachabilityState(
            bodyID: bodyID, featureIDs: try rows(document, scope: "features").compactMap { $0["id"] as? String },
            sketchIDs: sketches.compactMap { $0["id"] as? String }, circle: try XCTUnwrap(circles.first),
            volume: volume, undoDepth: document.session.undoStack.undoCommands.count,
            redoDepth: document.session.undoStack.redoCommands.count,
            modelSHA256: document.modelSHA256, revision: document.revision)
    }

    private func assertReachabilityState(_ state: ReachabilityState, sameIDs baseline: ReachabilityState,
                                        radius: Double, volume: Double, undo: Int) {
        XCTAssertEqual(state.bodyID, baseline.bodyID)
        XCTAssertEqual(state.featureIDs, baseline.featureIDs, "The edit must reuse every existing FeatureID.")
        XCTAssertEqual(state.sketchIDs, baseline.sketchIDs)
        XCTAssertEqual(state.circle.sketchID, baseline.circle.sketchID)
        XCTAssertEqual(state.circle.entityID, baseline.circle.entityID)
        XCTAssertEqual(state.circle.radius, radius, accuracy: 1e-8)
        XCTAssertEqual(state.volume, volume, accuracy: Self.volumeTolerance)
        XCTAssertEqual(state.undoDepth, undo, "Only the requested native transaction may enter undo history.")
    }

    private func makeSuppliedNativeFixture(at url: URL) async throws -> ReachabilityState {
        let document = try await FloeCADDocument.create(at: url, name: "TEST FIXTURE — not model generated")
        defer { document.close() }
        func command(_ object: [String: Any]) throws -> [String: Any] {
            let result = document.executeJSON(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            guard result.isOK else {
                throw reachabilityFailure("Native fixture command failed: \(result.errorCode ?? "") \(result.message ?? "")")
            }
            return try XCTUnwrap(jsonObject(result.payload))
        }
        let plateSketch = try XCTUnwrap(command(["op": "sketch.create", "args": ["name": "Fixture plate"]])["sketchID"] as? String)
        _ = try command(["op": "sketch.addEntities", "args": ["sketchID": plateSketch,
            "entities": [["kind": "rect", "min": [0, 0], "max": [80, 50]]]]])
        let plate = try command(["op": "feature.extrude", "args": ["sketchID": plateSketch,
            "seedPoint": [40, 25], "distance": 10]])
        let bodyID = try XCTUnwrap((plate["producedBodyIDs"] as? [String])?.first
            ?? (plate["changedBodyIDs"] as? [String])?.first)
        let holeSketch = try XCTUnwrap(command(["op": "sketch.create", "args": ["name": "Fixture hole"]])["sketchID"] as? String)
        _ = try command(["op": "sketch.addEntities", "args": ["sketchID": holeSketch,
            "entities": [["kind": "circle", "center": [40, 25], "radius": 3]]]])
        _ = try command(["op": "feature.extrude", "args": ["sketchID": holeSketch,
            "seedPoint": [40, 25], "distance": 40, "symmetric": true,
            "boolean": "subtract", "booleanTargets": [bodyID]]])
        let saved = await document.save()
        guard saved.succeeded else { throw reachabilityFailure("Fixture save failed: \(saved.error ?? "")") }
        let state = try reachabilityState(document)
        XCTAssertEqual(state.volume, Self.expectedVolumeDiameter6, accuracy: Self.volumeTolerance)
        XCTAssertEqual(state.circle.radius, 3, accuracy: 1e-8)
        XCTAssertFalse(state.featureIDs.isEmpty)
        XCTAssertFalse(state.modelSHA256.isEmpty)
        guard state.volume.isFinite, abs(state.volume - Self.expectedVolumeDiameter6) <= Self.volumeTolerance,
              abs(state.circle.radius - 3) <= 1e-8, !state.featureIDs.isEmpty, !state.modelSHA256.isEmpty else {
            throw reachabilityFailure("Native fixture geometry/identity is invalid; no model turn was started.")
        }
        return state
    }

    private func runSuppliedDocumentReachability(label: String, maxSeconds: Double) async throws {
        documentName = "x34-supplied-\(label)-\(UUID().uuidString.prefix(8)).floecad"
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("X34SuppliedFixture-\(UUID())")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let sourceURL = staging.appendingPathComponent(documentName)
        attach("x34-\(label)-owned-fixture-path.txt", "Test-owned staging retained on failure: \(sourceURL.path)")
        var succeeded = false
        defer { if succeeded { try? FileManager.default.removeItem(at: staging) } }
        let source = try await makeSuppliedNativeFixture(at: sourceURL)
        attach("x34-\(label)-fixture-origin.txt",
               "TEST-CREATED fixture, NOT model-generated. Saved by real typed native commands before inference. "
                + "staging=\(sourceURL.path) body=\(source.bodyID) sketch=\(source.circle.sketchID) "
                + "entity=\(source.circle.entityID) features=\(source.featureIDs) volumeMM3=\(source.volume) "
                + "modelSHA256=\(source.modelSHA256) model=\(model.remoteModelID) no image input.")
        let path = documentName
        let editPayload = try wireJSON(["action": "updateSketchEntity", "sketch_id": source.circle.sketchID,
            "entity_id": source.circle.entityID, "radius": 4, "expected_radius": 3])
        let undoPayload = try wireJSON(["action": "undo"])
        let calls: [[[String: Any]]] = [
            [["action": "query", "path": path, "kind": "sketches"]],
            [["action": "parameters", "path": path, "payload": editPayload],
             ["action": "measure", "path": path, "kind": "body", "handles": ["body:\(source.bodyID)"]]],
            [["action": "parameters", "path": path, "payload": undoPayload]],
            [["action": "save", "path": path]],
        ]
        let instructions = ["Query the supplied sketch. Do not edit anything.",
                            "Change the SAME circle radius 3 to 4, then measure the SAME body.",
                            "Undo exactly the last radius edit through the real native undo tool.",
                            "Save the undo-restored native document. Do not edit anything."]
        var baseline: ReachabilityState?
        var previousInstance: ObjectIdentifier?
        for turn in 0..<4 {
            let examples = try calls[turn].map {
                try wireJSON(["tool_call": ["name": CadDocumentTool.name, "arguments": $0]])
            }.joined(separator: "\n")
            let goal = """
            Text-only tool reachability check. This is an existing TEST-CREATED fixture, NOT geometry you generated. Use only cad.document in the current task workspace. No images or visual inference.
            Source path=\(path), bodyID=\(source.bodyID), hole sketchID=\(source.circle.sketchID), circle entityID=\(source.circle.entityID), FeatureIDs=\(source.featureIDs.joined(separator: ",")).
            Round \(turn + 1)/4: \(instructions[turn])
            Emit exactly these complete JSON tool_call objects, one per line, in order. No prose, Markdown fences or bare arguments objects. After real tool results return, stop and report only returned results:
            \(examples)
            Wire contract: tool_call.name is "cad.document"; tool_call.arguments is an OBJECT. Inside that arguments object, args and payload, when present, are JSON STRING fields, never nested objects. Omit args and payload when absent from the exact calls above. Do not create, propose, apply, import or replace geometry. Do not claim execution without a real tool result.
            """
            attach("x34-\(label)-round-\(turn + 1)-goal.txt", goal)
            try assertCanonicalSchemaIsAdmitted(for: goal)
            let events = try await runTurn(goal: goal, firstTurn: turn == 0, maxSeconds: maxSeconds,
                                           stagedFixture: turn == 0 ? sourceURL : nil)
            try await assertReachabilityTurn(events, expected: calls[turn], label: "\(label)-\(turn + 1)")
            let url = try XCTUnwrap(documentURL)
            let document = try await FloeCAD3DBridge.shared.openDocument(at: url)
            let state = try reachabilityState(document)
            if turn == 0 {
                baseline = state
                previousInstance = ObjectIdentifier(document)
                assertReachabilityState(state, sameIDs: source, radius: 3,
                                        volume: Self.expectedVolumeDiameter6, undo: 0)
                XCTAssertEqual(state.modelSHA256, source.modelSHA256)
            } else {
                let initial = try XCTUnwrap(baseline)
                XCTAssertEqual(ObjectIdentifier(document), previousInstance,
                               "All four turns must use the same live owner and undo history.")
                assertReachabilityState(state, sameIDs: initial, radius: turn == 1 ? 4 : 3,
                                        volume: turn == 1 ? Self.expectedVolumeDiameter8 : Self.expectedVolumeDiameter6,
                                        undo: initial.undoDepth + (turn == 1 ? 1 : 0))
                if turn == 1 {
                    XCTAssertGreaterThan(state.revision, initial.revision)
                    XCTAssertNotEqual(state.modelSHA256, initial.modelSHA256)
                } else {
                    XCTAssertEqual(state.modelSHA256, initial.modelSHA256,
                                   "Real undo must restore the exact canonical pre-edit model.")
                    XCTAssertEqual(state.redoDepth, 1)
                }
            }
            attach("x34-\(label)-round-\(turn + 1)-native.txt",
                   "volumeMM3=\(state.volume) radius=\(state.circle.radius) undo=\(state.undoDepth) "
                    + "redo=\(state.redoDepth) revision=\(state.revision) modelSHA256=\(state.modelSHA256)")
        }
        let url = try XCTUnwrap(documentURL)
        let initial = try XCTUnwrap(baseline)
        let ownerBeforeClose = try await FloeCAD3DBridge.shared.openDocument(at: url)
        XCTAssertEqual(ObjectIdentifier(ownerBeforeClose), previousInstance)
        await FloeCAD3DBridge.shared.releaseDocument(at: url)
        // The model's save is the last write; the test only closes/reopens and
        // inspects. A fresh instance must reconstruct the saved native shape.
        let reopened = try await FloeCAD3DBridge.shared.openDocument(at: url)
        // Retain the old object through this assertion; allocator address reuse
        // after deallocation is not evidence that owner close/reopen failed.
        XCTAssertNotEqual(ObjectIdentifier(reopened), ObjectIdentifier(ownerBeforeClose))
        XCTAssertFalse(reopened.isReadOnly)
        let cold = try reachabilityState(reopened)
        assertReachabilityState(cold, sameIDs: initial, radius: 3,
                                volume: Self.expectedVolumeDiameter6, undo: 0)
        XCTAssertEqual(cold.modelSHA256, initial.modelSHA256)
        let disk = try await inspectDocument(at: url)
        XCTAssertEqual(disk.modelSHA256, initial.modelSHA256)
        XCTAssertEqual(disk.bodyID, initial.bodyID)
        XCTAssertTrue(disk.bodyIsAnalytic)
        XCTAssertEqual(disk.volume, cold.volume, accuracy: 1e-6)
        attach("x34-\(label)-cold-reopen.txt", disk.description)
        succeeded = testRun.map { $0.totalFailureCount == 0 } ?? false
        await cleanup(deleteConversation: succeeded)
    }

    private func assertReachabilityTurn(_ events: [RunEventRecord], expected: [[String: Any]],
                                        label: String) async throws {
        attach("x34-\(label)-owned-events.txt", events.map { "\($0.kind): \($0.payloadJSON)" }.joined(separator: "\n"))
        _ = try assertCADTurn(events, label: label)
        let service = try XCTUnwrap(services.last)
        let snapshot = await service.snapshot()
        let runOptional = try await environment.runStore.run(id: snapshot.runID)
        let run = try XCTUnwrap(runOptional)
        XCTAssertEqual(run.providerID, ProviderProfile.onDeviceProviderID)
        XCTAssertEqual(run.providerID, provider.id)
        XCTAssertEqual(run.modelID, model.id)
        attach("x34-\(label)-provider.txt",
               "providerID=\(provider.id) modelID=\(model.id) remoteModelID=\(model.remoteModelID) "
                + "runID=\(snapshot.runID) state=\(snapshot.stateName) "
                + "providerActivity=\(snapshot.hasProviderActivity) "
                + "attempt=\(String(describing: snapshot.providerAttempt)) allowedTool=cad.document cloudFallback=false")
        guard snapshot.isTerminal, snapshot.stateName == "completed", snapshot.pendingApproval == nil,
              snapshot.hasProviderActivity else {
            await service.cancel()
            throw reachabilityFailure("\(label): no completed actual-provider turn: \(snapshot.stateName).")
        }
        var requests: [(String, [String: Any])] = []
        var results: [String: String] = [:]
        for event in events {
            guard let payload = jsonObject(event.payloadJSON), payload["tool"] as? String == CadDocumentTool.name else { continue }
            let id = payload["id"] as? String ?? ""
            if event.kind == .toolRequest {
                let request = try XCTUnwrap((payload["input"] as? String).flatMap(jsonObject))
                for field in ["args", "payload"] where request[field] != nil {
                    guard request[field] is String else {
                        throw reachabilityFailure("\(label): \(field) must be a JSON STRING; actual=\(type(of: request[field]!)).")
                    }
                }
                requests.append((id, request))
            } else if event.kind == .toolResult {
                results[id] = payload["status"] as? String ?? "missing"
            }
        }
        guard requests.count == expected.count else {
            throw reachabilityFailure("\(label): expected \(expected.count) exact CAD calls, got \(requests.count). See owned events.")
        }
        for (index, request) in requests.enumerated() {
            guard !request.0.isEmpty, results[request.0] == "ok" else {
                throw reachabilityFailure("\(label): CAD call \(index) has no matching successful real result.")
            }
            guard request.1["grant_id"] == nil else {
                throw reachabilityFailure("\(label): model-authored grant_id is not permitted.")
            }
            for (key, value) in expected[index] {
                let actual = try XCTUnwrap(request.1[key], "Missing expected wire field \(key)")
                let matches: Bool
                if key == "payload", let lhs = actual as? String, let rhs = value as? String {
                    matches = try wireJSON(try XCTUnwrap(jsonObject(lhs))) == wireJSON(try XCTUnwrap(jsonObject(rhs)))
                } else {
                    matches = try JSONSerialization.data(withJSONObject: actual, options: [.fragmentsAllowed, .sortedKeys])
                        == JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
                }
                guard matches else { throw reachabilityFailure("\(label): unexpected \(key) in call \(index).") }
            }
        }
    }

    private func wireJSON(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func reachabilityFailure(_ message: String) -> NSError {
        XCTFail(message)
        return NSError(domain: "X34Reachability", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func readReachabilityOptIn(provider name: String, modelID: String) throws -> OptIn {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloeLocalCADReachability/opt-in-\(name).json")
        guard let data = try? Data(contentsOf: url) else {
            throw reachabilityFailure("Missing explicit live opt-in at \(url.path). Expected {\"modelID\":\"\(modelID)\",\"maxSecondsPerTurn\":240}.")
        }
        let value = try JSONDecoder().decode(OptIn.self, from: data)
        guard value.modelID == modelID, (30...900).contains(value.maxSecondsPerTurn ?? 240) else {
            throw reachabilityFailure("Opt-in must name \(modelID) and a finite 30...900 second turn limit.")
        }
        return value
    }

    // MARK: - Turn execution (production App run service)

    private struct TurnReceipt {
        var actions: [String]
        var undoRequests: Int
        var requestCount: Int
    }

    private func runTurn(goal: String, firstTurn: Bool, maxSeconds: Double,
                         stagedFixture: URL? = nil) async throws -> [RunEventRecord] {
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
            if let stagedFixture {
                let root = try XCTUnwrap(workspaceURL)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let destination = root.appendingPathComponent(documentName)
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw reachabilityFailure("The owned fixture destination already exists.")
                }
                // Staging an already saved TEST fixture is not model execution.
                // No tool result, CAD edit, save or undo is synthesized here.
                try FileManager.default.copyItem(at: stagedFixture, to: destination)
                documentURL = destination
            }
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
        let note = "model=\(model.remoteModelID) contextTokens=\(model.limits.contextTokens) "
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
        if model?.remoteModelID == Self.modelID {
            await environment.localModelRuntime.unload(modelID: Self.modelID)
        }
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

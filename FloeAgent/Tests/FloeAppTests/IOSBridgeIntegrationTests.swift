// FloeAppTests — local iOS Bridge App integration contracts.
//
// These are source-level contracts for the App adapter: the pairing update
// decision, compiled action/parameter validation, discoverability gating,
// task-authority binding and screenshot artifact projection. They do not
// contact a real Bridge, install the App or replace device/UI acceptance.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import XCTest
import GRDB
import FloeCore
import FloeIOSAutomation
import FloeModels
@testable import FloePersistence
import FloeSkills
import FloeSync
import FloeTools
@testable import FloeApp

@Suite("FloeApp.IOSBridgeIntegration")
@MainActor
struct IOSBridgeIntegrationTests {
    @Test("Every authenticated device surface respects the task credential ceiling")
    func authenticatedToolsDeclareCredentialUse() {
        #expect(IOSBridgeStatusTool.riskLabels.contains(.accessesCredentials))
        #expect(IOSBridgePairTool.riskLabels.contains(.accessesCredentials))
        #expect(IOSBridgeObserveTool.riskLabels.contains(.accessesCredentials))
        #expect(IOSBridgeControlTool.riskLabels.contains(.accessesCredentials))
    }

    @Test("Self UI protection follows the installed Floe bundle identity")
    func protectsResignedFloeIdentity() {
        let policy = IOSBridgeIntegration.protectionPolicy(floeBundleIdentifier: "org.example.FloeResigned")
        #expect(policy.protectedMutationBundleIdentifiers.contains("org.example.floeresigned"))
        #expect(policy.protectedMutationBundleIdentifiers.contains("org.floeagent.iosbridge"))
        #expect(policy.protectedMutationBundleIdentifiers.contains("org.floeagent.ios"))
    }

    @Test("Installing the optional Skill needs compiled capability, never prior pairing")
    func configurationCapabilitiesFollowActualPlatform() {
        #expect(SkillsCenter.configurationCapabilities(platform: .iOSDevice) == [.credentials, .deviceObserve, .deviceInteract])
        for platform in [LocalBridgePlatform.nativeMac, .iOSAppOnMac, .macCatalyst, .iOSSimulator, .unsupported] {
            #expect(SkillsCenter.configurationCapabilities(platform: platform) == [.credentials])
        }
    }

    // MARK: - Pairing update decision

    @Test("Same token/key refreshes; a new key rekeys; no record is initial setup")
    func pairingUpdateDecision() throws {
        let granted = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Data(repeating: 7, count: 32)
        let record = try IOSBridgePairingRecord(
            tokenID: IOSBridgeEnvelope.tokenID(for: key),
            clientName: "Floe on iPhone",
            grantedAt: granted,
            lastVerifiedAt: granted,
            expiresAt: granted.addingTimeInterval(30 * 24 * 60 * 60),
            protocolVersion: 1,
            keyMaterial: key
        )
        let refreshed = try IOSBridgePairingRecord(
            tokenID: record.tokenID,
            clientName: record.clientName,
            grantedAt: record.grantedAt,
            lastVerifiedAt: record.lastVerifiedAt.addingTimeInterval(60),
            expiresAt: record.expiresAt,
            protocolVersion: 1,
            keyMaterial: key
        )
        let newKey = Data(repeating: 9, count: 32)
        let rekeyed = try IOSBridgePairingRecord(
            tokenID: IOSBridgeEnvelope.tokenID(for: newKey),
            clientName: "Floe on iPhone",
            grantedAt: granted,
            lastVerifiedAt: granted,
            expiresAt: granted.addingTimeInterval(30 * 24 * 60 * 60),
            protocolVersion: 1,
            keyMaterial: newKey
        )

        #expect(IOSBridgePairingStoreAdapter.updateDecision(existing: record, new: refreshed) == .refresh)
        #expect(IOSBridgePairingStoreAdapter.updateDecision(existing: record, new: rekeyed) == .rekey)
        #expect(IOSBridgePairingStoreAdapter.updateDecision(existing: nil, new: refreshed) == .initialSetup)
    }

    // MARK: - Argument contract

    @Test("Observe/control action arguments use the compiled surface and parameter contract")
    func actionArgumentValidation() throws {
        func decode(_ object: [String: Any]) throws -> IOSBridgeToolArguments {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(IOSBridgeToolArguments.self, from: data)
        }

        do {
            try decode(["action": "screenshot", "scale": 2.0]).validate(surface: .observe)
            try decode(["action": "find_element", "element_id": "e1"]).validate(surface: .observe)
            try decode(["action": "tap", "x": 10, "y": 20]).validate(surface: .control)
            try decode(["action": "type", "text": "hello"]).validate(surface: .control)
            try decode(["action": "open_url", "url": "https://example.com"]).validate(surface: .control)
        } catch {
            Issue.record("Unexpected rejection: \(error)")
        }

        #expect(throws: FloeError.self) {
            try decode(["action": "launch_app"]).validate(surface: .control)
        }
        #expect(throws: FloeError.self) {
            try decode(["action": "type", "text": 42]).validate(surface: .control)
        }
        #expect(throws: FloeError.self) {
            try decode(["action": "tap", "credential": "x"]).validate(surface: .control)
        }
        #expect(throws: FloeError.self) {
            try decode(["action": "config"]).validate(surface: .observe)
        }
    }

    // MARK: - Discoverability projection

    @Test("Only installed/enabled/authorized/validated connections expose device actions")
    func discoverabilityProjection() {
        let ready = IOSBridgeSkillActivation(
            installed: true,
            enabled: true,
            grantsAllowed: true,
            configurationAllowed: true,
            sourceChanged: false,
            hasConnectionField: true,
            readiness: .ready
        )
        let disabled = IOSBridgeSkillActivation(
            installed: true,
            enabled: false,
            grantsAllowed: true,
            configurationAllowed: true,
            sourceChanged: false,
            hasConnectionField: true,
            readiness: .ready
        )
        let setup = IOSBridgeSkillActivation(
            installed: true,
            enabled: true,
            grantsAllowed: true,
            configurationAllowed: true,
            sourceChanged: false,
            hasConnectionField: true,
            readiness: .needsSetup
        )
        let unverified = IOSBridgeSkillActivation(
            installed: true,
            enabled: true,
            grantsAllowed: false,
            configurationAllowed: false,
            sourceChanged: false,
            hasConnectionField: true,
            readiness: .sourceUnverified
        )

        let readyTools = IOSBridgeIntegration.toolAvailability(for: ready)
        #expect(readyTools.status)
        #expect(readyTools.pair)
        #expect(readyTools.observeControl)

        let disabledTools = IOSBridgeIntegration.toolAvailability(for: disabled)
        #expect(!disabledTools.status)
        #expect(!disabledTools.pair)
        #expect(!disabledTools.observeControl)

        let setupTools = IOSBridgeIntegration.toolAvailability(for: setup)
        #expect(setupTools.status)
        #expect(setupTools.pair)
        #expect(!setupTools.observeControl)

        let unverifiedTools = IOSBridgeIntegration.toolAvailability(for: unverified)
        #expect(unverifiedTools.status)
        #expect(!unverifiedTools.pair)
        #expect(!unverifiedTools.observeControl)
    }

    // MARK: - Validator dispatch

    @Test("The native validator rejects another Skill without reading its secret")
    func validatorRejectsForeignSkill() async throws {
        let request = SkillConfigurationValidationRequest(
            skillID: "another-skill",
            installationID: "installation",
            profile: IOSBridgeIntegration.defaultProfile,
            target: IOSBridgeIntegration.nativeTarget,
            revision: 1,
            fieldKey: IOSBridgeIntegration.connectionFieldKey,
            connectionKind: IOSBridgeIntegration.connectionKind,
            variables: [:],
            environment: [:],
            secretEnvironment: [],
            readSecret: {
                Issue.record("The validator must not read a secret for a foreign Skill.")
                return Data()
            }
        )
        let result = try await IOSBridgeSkillConnectionValidator().validate(request)
        if case .unsupported = result {
            // Expected: only the fixed optional local-automation Skill uses
            // this compiled connection kind.
        } else {
            Issue.record("Unexpected validator result: \(result)")
        }
    }

    // MARK: - Screenshot artifact

    @Test("Screenshot bytes become a verified artifact and never a model-visible base64 body")
    func screenshotArtifactProjection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-bridge-artifact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let result = IOSBridgeJSONValue.object([
            "data": .string(png.base64EncodedString()),
            "format": .string("png"),
            "bytes": .int(png.count),
            "pixel_width": .int(1),
            "pixel_height": .int(1),
            "point_width": .double(1),
            "point_height": .double(1),
            "scale": .double(1),
            "scope": .string("screen"),
            "hint": .string("Tap coordinates are POINTS.")
        ])
        let made = try IOSBridgeScreenshotArtifact.make(from: result, root: root)
        let fileURL = root.appendingPathComponent(made.artifact.relativePath)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(made.artifact.mimeType == "image/png")
        #expect(made.artifact.sha256 == FloeDigest.sha256Hex(png))
        #expect(made.artifact.relativePath.hasPrefix(IOSBridgeScreenshotArtifact.namespace + "/"))
        #expect(made.metadata["data"] == nil)
        #expect(made.metadata["imageAttached"] as? Bool == true)
        #expect(VerifiedToolImageArtifact.namespaces.contains(IOSBridgeScreenshotArtifact.namespace))
    }

    // MARK: - Authority

    @Test("Temporary read-only control is denied before any device authority")
    func temporaryControlDenied() async {
        let runID = UUID()
        let context = ToolContext(
            runID: runID,
            toolCallID: "call-1",
            toolIdempotencyKey: "idem-1",
            approvalGrantID: UUID(),
            scope: .local,
            allowedToolNames: [IOSBridgeToolNames.control],
            cancellation: CancellationToken(),
            temporaryReadOnly: true
        )
        let binding = RuntimeAuthorityBinding(
            runID: runID,
            taskID: nil,
            environmentBinding: "task:-|ws:*",
            canonicalTarget: "workspace:*",
            toolName: IOSBridgeToolNames.control,
            operation: "apply",
            operationID: "call-1",
            idempotencyKey: "idem-1",
            baseRevision: nil,
            payloadDigest: "digest"
        )
        let authority = IOSBridgeToolAuthority(
            toolContext: context,
            surface: .control,
            binding: binding,
            authorityConsumed: true,
            liveCheck: { true }
        )
        let call = IOSAutomationCallContext(
            taskID: runID,
            taskGeneration: 0,
            toolCallID: "call-1",
            toolIdempotencyKey: "idem-1",
            operationID: "call-1",
            executionWindow: .foreground()
        )
        let decision = await authority.authorize(.init(
            action: .tap,
            effect: .mutating,
            declaredTarget: .init(),
            foregroundBundleIdentifier: "com.example.app",
            context: call
        ))
        if case .denied = decision {
            // Expected.
        } else {
            Issue.record("Temporary control must be denied.")
        }
    }

    @Test("A read-only observation does not require a mutation authority token")
    func readObservationAuthority() async {
        let runID = UUID()
        let context = ToolContext(
            runID: runID,
            toolCallID: "call-2",
            toolIdempotencyKey: "idem-2",
            approvalGrantID: nil,
            scope: .local,
            allowedToolNames: [IOSBridgeToolNames.observe],
            cancellation: CancellationToken(),
            temporaryReadOnly: true
        )
        let binding = RuntimeAuthorityBinding(
            runID: runID,
            taskID: nil,
            environmentBinding: "task:-|ws:*",
            canonicalTarget: "workspace:*",
            toolName: IOSBridgeToolNames.observe,
            operation: "apply",
            operationID: "call-2",
            idempotencyKey: "idem-2",
            baseRevision: nil,
            payloadDigest: "digest"
        )
        let authority = IOSBridgeToolAuthority(
            toolContext: context,
            surface: .observe,
            binding: binding,
            authorityConsumed: false,
            liveCheck: { true }
        )
        let call = IOSAutomationCallContext(
            taskID: runID,
            taskGeneration: 0,
            toolCallID: "call-2",
            toolIdempotencyKey: "idem-2",
            operationID: "call-2",
            executionWindow: .foreground()
        )
        let decision = await authority.authorize(.init(
            action: .screenshot,
            effect: .readOnly,
            declaredTarget: .init(),
            foregroundBundleIdentifier: "com.example.app",
            context: call
        ))
        #expect(decision == .allowed)
    }

    // MARK: - Sensitive text credential policy

    private func credentialRecord(
        owner: CredentialOwner = .vault,
        kind: CredentialKind = .websitePassword,
        hostID: UUID? = nil,
        origin: String? = nil,
        deviceBound: Bool = false
    ) -> CredentialRecord {
        CredentialRecord(
            kind: kind,
            owner: owner,
            hostID: hostID,
            origin: origin,
            label: "Synthetic test credential",
            keychainAccount: "test.\(UUID().uuidString)",
            synchronizable: false,
            deviceBound: deviceBound
        )
    }

    @Test("type.text accepts only an exact control-call capture or an ordinary unbound vault card")
    func textCredentialPolicy() {
        let runID = UUID()
        let exactOrigin = CredentialCaptureReference.origin(
            toolName: "ios.bridge.control",
            fieldPath: "text",
            runID: runID
        )

        #expect(IOSBridgeTextCredentialPolicy.allows(
            record: credentialRecord(origin: exactOrigin),
            runID: runID,
            bindingCount: 0
        ))

        // A Skill binding (including the local Bridge pairing credential) is
        // never a text-input source, even when the origin happens to match.
        #expect(!IOSBridgeTextCredentialPolicy.allows(
            record: credentialRecord(origin: exactOrigin),
            runID: runID,
            bindingCount: 1
        ))

        // Other run, tool or path.
        #expect(!IOSBridgeTextCredentialPolicy.allows(
            record: credentialRecord(origin: exactOrigin),
            runID: UUID(),
            bindingCount: 0
        ))
        #expect(!IOSBridgeTextCredentialPolicy.allows(
            record: credentialRecord(origin: CredentialCaptureReference.origin(
                toolName: "vnc.observe",
                fieldPath: "text",
                runID: runID
            )),
            runID: runID,
            bindingCount: 0
        ))
        #expect(!IOSBridgeTextCredentialPolicy.allows(
            record: credentialRecord(origin: CredentialCaptureReference.origin(
                toolName: "ios.bridge.control",
                fieldPath: "password",
                runID: runID
            )),
            runID: runID,
            bindingCount: 0
        ))

        // Device-bound / host-bound / Skill origin is never ordinary.
        #expect(!IOSBridgeTextCredentialPolicy.allows(
            record: credentialRecord(origin: exactOrigin, deviceBound: true),
            runID: runID,
            bindingCount: 0
        ))
        #expect(!IOSBridgeTextCredentialPolicy.allows(
            record: credentialRecord(hostID: UUID(), origin: exactOrigin),
            runID: runID,
            bindingCount: 0
        ))
        #expect(!IOSBridgeTextCredentialPolicy.allows(
            record: credentialRecord(
                origin: "skill-connection:install:profile:target:bridge"
            ),
            runID: runID,
            bindingCount: 0
        ))

        // Ordinary unbound vault cards are allowed; non-vault owners and
        // input-incompatible kinds are not.
        #expect(IOSBridgeTextCredentialPolicy.allows(
            record: credentialRecord(origin: nil),
            runID: runID,
            bindingCount: 0
        ))
        #expect(IOSBridgeTextCredentialPolicy.allows(
            record: credentialRecord(kind: .genericToken, origin: nil),
            runID: runID,
            bindingCount: 0
        ))
        #expect(IOSBridgeTextCredentialPolicy.allows(
            record: credentialRecord(kind: .providerAPIKey, origin: nil),
            runID: runID,
            bindingCount: 0
        ))
        #expect(!IOSBridgeTextCredentialPolicy.allows(
            record: credentialRecord(owner: .conversation(UUID()), origin: nil),
            runID: runID,
            bindingCount: 0
        ))
        #expect(!IOSBridgeTextCredentialPolicy.allows(
            record: credentialRecord(kind: .sshPrivateKey, origin: nil),
            runID: runID,
            bindingCount: 0
        ))
    }

    @Test("Whole-profile or empty config mutations fence the bridge; unrelated fields do not")
    func configurationMutationScope() {
        #expect(IOSBridgeIntegration.configurationMutationAffectsBridge(fieldKeys: nil))
        #expect(IOSBridgeIntegration.configurationMutationAffectsBridge(fieldKeys: []))
        #expect(IOSBridgeIntegration.configurationMutationAffectsBridge(fieldKeys: ["bridge"]))
        #expect(!IOSBridgeIntegration.configurationMutationAffectsBridge(fieldKeys: ["apiKey"]))
    }

    @Test("Projection bounds only display JSON and retains the full admitted result")
    func projectionBound() throws {
        let retained = String(repeating: "x", count: 8 * 1_024)
        let retainedProjection = try IOSBridgeToolOutput.boundedProjection([
            "status": "ok",
            "action": "page_source",
            "operationID": "op-1",
            "result": ["tree": retained]
        ])
        #expect(!retainedProjection.omitted)
        #expect(retainedProjection.data.count > 4 * 1_024)
        #expect(retainedProjection.data.count <= 64 * 1_024)
        let retainedObject = try #require(
            JSONSerialization.jsonObject(with: retainedProjection.data) as? [String: Any]
        )
        #expect(retainedObject["result"] != nil)
        #expect((retainedObject["result"] as? [String: Any])?["tree"] as? String == retained)

        let omitted = String(repeating: "y", count: 80 * 1_024)
        let omittedProjection = try IOSBridgeToolOutput.boundedProjection([
            "status": "ok",
            "action": "page_source",
            "operationID": "op-2",
            "result": ["tree": omitted]
        ])
        #expect(omittedProjection.omitted)
        #expect(omittedProjection.data.count <= 64 * 1_024)
        let omittedObject = try #require(
            JSONSerialization.jsonObject(with: omittedProjection.data) as? [String: Any]
        )
        #expect(omittedObject["result"] == nil)
        #expect(omittedObject["resultOmitted"] as? Bool == true)
        #expect(omittedObject["resultByteCount"] as? Int == omittedProjection.originalByteCount)
        #expect((omittedObject["note"] as? String)?.isEmpty == false)
        let fullObject = try #require(JSONSerialization.jsonObject(with: omittedProjection.fullData) as? [String: Any])
        #expect((fullObject["result"] as? [String: Any])?["tree"] as? String == omitted)
        #expect(omittedProjection.fullData.count == omittedProjection.originalByteCount)
    }

    @Test("Large actual action output reaches the existing full capture and digest path")
    func actionOutputKeepsFullCapture() throws {
        let tree = "START_OF_TREE:" + String(repeating: "页面内容", count: 24_000) + ":END_OF_TREE"
        let receipt = IOSAutomationReceipt(action: .pageSource, effect: .readOnly,
            operationID: "full-tree-receipt", outcome: .succeeded,
            result: .object(["tree": .string(tree)]), startedAt: Date(),
            completedAt: Date(), usedInputLease: false)
        let output = try IOSBridgeToolOutput.make(receipt: receipt, action: .pageSource)
        #expect(output.summary.utf8.count <= 64 * 1_024)
        #expect(output.summaryTruncated)
        #expect(!output.capturedOutputTruncated)
        let capture = try #require(output.capturedOutput)
        let data = Data(capture.utf8)
        #expect(data.count > 64 * 1_024)
        let full = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((full["result"] as? [String: Any])?["tree"] as? String == tree)
        #expect(output.fullOutputSHA256 == FloeDigest.sha256Hex(data))
        #expect(output.ephemeralSensitiveOutput == nil)
    }
}


/// File-backed released v58 schema → the production v59 migrator. This
/// touches synthetic fixtures only, never the App's shared database/Keychain.
@MainActor
final class SkillConfigurationMigrationAppTests: XCTestCase {
    private var directory: URL!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloeV59Migration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func version58File(_ path: URL, collision: Bool = false) throws {
        let queue = try DatabaseQueue(path: path.path)
        defer { try? queue.close() }
        var migrator = DatabaseMigrator()
        // Frozen released baseline. Use the real historical registrations;
        // never create an "old" fixture by deleting tables from v59.
        V1Initial.register(into: &migrator)
        V2ConfigSync.register(into: &migrator)
        V3AgentDaily.register(into: &migrator)
        V4ModelPreferences.register(into: &migrator)
        V5Workspace.register(into: &migrator)
        V6AppSettings.register(into: &migrator)
        V7WorkbenchIntelligence.register(into: &migrator)
        V8TaskOwnership.register(into: &migrator)
        V9HarnessAndPermissions.register(into: &migrator)
        V10ConversationContinuity.register(into: &migrator)
        V11ArchiveCredentials.register(into: &migrator)
        V12RunningInputs.register(into: &migrator)
        V13PersonalizationMemory.register(into: &migrator)
        V14PlanGoalControls.register(into: &migrator)
        V15ProviderDisplayName.register(into: &migrator)
        V16ProviderCompatibilityAndPackageReview.register(into: &migrator)
        V17ModelReasoningEffort.register(into: &migrator)
        V18RunUsageDimensions.register(into: &migrator)
        V19DetailedRunUsage.register(into: &migrator)
        V20RunResponseTiming.register(into: &migrator)
        V21MemoryLifecycle.register(into: &migrator)
        V22RemoteDevices.register(into: &migrator)
        V23ModelPickerVisibility.register(into: &migrator)
        V24VideoModelRouting.register(into: &migrator)
        V25DeferredSyncPayloads.register(into: &migrator)
        V26CreativeMediaJobs.register(into: &migrator)
        V27CloudReleaseModes.register(into: &migrator)
        V28CanvasModelRouting.register(into: &migrator)
        V29ModelUseSurfaces.register(into: &migrator)
        V30MemoryOrganization.register(into: &migrator)
        V31TimelinePerformance.register(into: &migrator)
        V32CanvasRunContexts.register(into: &migrator)
        V33GeneratedAssetReservations.register(into: &migrator)
        V34RunConversationModes.register(into: &migrator)
        V35GeneralAuxiliaryLLM.register(into: &migrator)
        V36LocalWorkspaceCleanup.register(into: &migrator)
        V37TaskChecklists.register(into: &migrator)
        V38ImageAutonomy.register(into: &migrator)
        V39BackgroundJobs.register(into: &migrator)
        V40ExecutionEnvironments.register(into: &migrator)
        V41ConversationPurpose.register(into: &migrator)
        V42MediaJobOwners.register(into: &migrator)
        V43MediaJobIdempotency.register(into: &migrator)
        V44ConversationSearchIndexRepair.register(into: &migrator)
        V45AssetReferenceOps.register(into: &migrator)
        V46TaskLifecycle.register(into: &migrator)
        V47ShortcutInbox.register(into: &migrator)
        V48SystemAlarms.register(into: &migrator)
        V49ChildRunCheckpoints.register(into: &migrator)
        V50ScheduleCleanupReminders.register(into: &migrator)
        V51ChatPreferences.register(into: &migrator)
        V52PersonalizationRetention.register(into: &migrator)
        V53ConversationVisibility.register(into: &migrator)
        V54JobAdvisoryGroups.register(into: &migrator)
        V55ConversationPinning.register(into: &migrator)
        V56UserQuestions.register(into: &migrator)
        V57SchedulePresentation.register(into: &migrator)
        V58TaskExecutionBindings.register(into: &migrator)
        try migrator.migrate(queue)
        try queue.write { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA user_version"), 58)
            XCTAssertFalse(try db.tableExists("skill_config_profiles"))
            try db.execute(sql: """
                INSERT INTO skills (id,name,version,status,skill_markdown,manifest_json,
                    source_url,source_digest,rewritten_digest,rewrite_model_id,created_at,updated_at)
                VALUES ('v58-skill','Saved name','1.2.3','enabled','synthetic fixture','{}',
                    'https://github.com/example/skills/blob/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/sample/SKILL.md',
                    'v58-source','v58-reviewed','v58-reviewer','2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z')
                """)
            try db.execute(sql: """
                INSERT INTO credential_records (id,kind,owner_kind,label,keychain_account,
                    synchronizable,device_bound,created_at,updated_at)
                VALUES ('00000000-0000-0000-0000-000000000001','genericToken','vault',
                    'Synthetic reference only','synthetic.v58.migration',0,0,
                    '2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z')
                """)
            if collision { try db.execute(sql: "CREATE TABLE skill_config_entries (sentinel TEXT)") }
        }
    }

    func testReleasedV58FileRetainsSkillsAndCredentialReferencesAfterV59AndReopen() async throws {
        let path = directory.appendingPathComponent("upgrade.sqlite")
        try version58File(path)
        let database = try DatabaseManager(path: path)
        try await database.migrate()
        let store = SkillConfigurationStore(database: database, officialSources: [])
        let saved = try await store.saveVariables(
            skillID: "v58-skill", values: ["endpoint": "https://example.invalid"], expectedRevision: nil)
        XCTAssertEqual(saved.revision, 1)
        try await database.migrate()
        let reopened = try DatabaseManager(path: path)
        try await reopened.migrate()
        let row = try await reopened.reader { db in
            (try Int.fetchOne(db, sql: "PRAGMA user_version"),
             try String.fetchOne(db, sql: "SELECT name FROM skills WHERE id='v58-skill'"),
             try String.fetchOne(db, sql: "SELECT keychain_account FROM credential_records"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM skill_config_profiles"),
             try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count)
        }
        XCTAssertEqual(row.0, 59)
        XCTAssertEqual(row.1, "Saved name")
        XCTAssertEqual(row.2, "synthetic.v58.migration")
        XCTAssertEqual(row.3, 1)
        XCTAssertEqual(row.4, 0)
        let snapshot = try await SkillConfigurationStore(database: reopened, officialSources: []).snapshot(skillID: "v58-skill")
        XCTAssertEqual(snapshot.profile?.revision, 1)
        XCTAssertEqual(snapshot.entries.first?.value, "https://example.invalid")
    }

    func testRealV59DDLFailureRollsBackAndCanResumeWithoutDataLoss() async throws {
        let path = directory.appendingPathComponent("rollback.sqlite")
        try version58File(path, collision: true)
        let database = try DatabaseManager(path: path)
        do {
            try await database.migrate()
            XCTFail("The deliberate entries-table collision must fail the real v59 transaction")
        } catch {
            XCTAssertTrue(String(describing: error).contains("already exists"), "\(error)")
        }
        let failed = try await database.reader { db in
            (try Int.fetchOne(db, sql: "PRAGMA user_version"),
             try db.tableExists("skill_config_installations"), try db.tableExists("skill_config_profiles"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier='v59_skill_configuration'"),
             try String.fetchOne(db, sql: "SELECT name FROM skills WHERE id='v58-skill'"))
        }
        XCTAssertEqual(failed.0, 58)
        XCTAssertFalse(failed.1)
        XCTAssertFalse(failed.2)
        XCTAssertEqual(failed.3, 0)
        XCTAssertEqual(failed.4, "Saved name")
        // Repair only the injected synthetic collision; migration must resume
        // without half-created profiles or any loss of old metadata.
        try await database.writer { db in try db.execute(sql: "DROP TABLE skill_config_entries") }
        try await database.migrate()
        let repaired = try await database.reader { db in
            (try Int.fetchOne(db, sql: "PRAGMA user_version"),
             try db.tableExists("skill_config_installations"),
             try String.fetchOne(db, sql: "SELECT keychain_account FROM credential_records"))
        }
        XCTAssertEqual(repaired.0, 59)
        XCTAssertTrue(repaired.1)
        XCTAssertEqual(repaired.2, "synthetic.v58.migration")
    }
}

#endif

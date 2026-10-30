// SPDX-License-Identifier: MPL-2.0
//
// FloeAppTests — OPT-IN, App-hosted, REAL-LLM native CAD acceptance.
//
// This is source preparation only in the current worker. The primary must
// register the file in `FloeAgent/project.yml`, freeze the source, compile the
// App test host once and run this ONE selector on the canonical iPad
// Simulator after that compile. No App/SPM build, test execution, Simulator,
// paid model call or credential read outside the App was performed while
// writing this file.
//
// What the test proves WHEN IT ACTUALLY RUNS
// ------------------------------------------
// One synthetic, task-owned native `.floecad` bracket flows through the real
// configured chat model, the real App tool catalog (`cad.document`) and the
// real `ConversationRunService`, across three ordinary turns:
//
//   1. create the native package, a 80 × 50 × 10 mm plate and a Ø6 through
//      hole, then save;
//   2. edit the EXISTING hole circle (same sketch/entity identity) from
//      Ø6 to exactly Ø8, add a 2 mm fillet on the vertical corner edge(s),
//      then save;
//   3. read the actual parameters back, capture a real engineering viewport
//      PNG and save the document again.
//
// The assertions read the bytes on disk with an independent `FloeCADDocument`
// reopen: body identity, analytic B-rep, hole diameter, fillet radius/edge
// count, exact plate-minus-hole-minus-fillet volume, revision growth and the
// capture PNG. Model prose is never evidence. A tool success string alone is
// never evidence.
//
// Opt-in and credential policy
// ----------------------------
// The test is DISABLED unless a coordinator/primary writes this non-secret
// cache file for the simulator App container:
//
//   <Caches>/FloeNativeCADLiveQualification/opt-in.json
//
// See the private handoff for the exact schema. The file contains policy
// metadata only (optional provider/model UUID pins, an explicit acceptance of
// the ordinary App run context, token/cost/time ceilings, and an optional
// prepaid budget basis). It NEVER contains an API key. An optional
// owned-route.json contains only test provider metadata. If the coordinator
// explicitly forwards a test-runner credential, the owned-route helper puts it
// in a random non-syncing App Keychain account, removes its own
// provider/account after the run and never changes an existing provider or
// default. Otherwise it asks the App's own
// `ConversationCenter.resolveCredentials`
// whether the selected provider has a usable key and then hands the run to the
// same production `ConversationCenter.runService` the UI uses. A missing file,
// missing cheap/tool-capable cloud model, missing App credential or missing
// pricing metadata is an explicit `XCTSkip` and a handoff blocker — never a
// live pass.
//
// The opt-in may instead declare `prepaidBudgetBasis: true` for the one
// reviewed owned Agent Plan route. That mode is accepted only with the exact
// reserved provider/model UUIDs, the exact Agent Plan base URL, the exact
// remote model ID, no usable model pricing metadata, no unpinned/fallback
// selection and explicit zero input/output increments. Usage is then reported
// as prepaid-plan consumption with the ordinary token and wall-clock ceilings;
// it is never described as free market pricing and never becomes a generic
// zero-price model path.
//
// Cost/data bounding and approval policy
// --------------------------------------
// The synthetic task gets its OWN durable task policy:
//   * `approvalMode = automatic` (the real App policy; native CAD document
//     edits are deterministically exempt, so no approval popup or approval
//     model is required);
//   * the executable tool ceiling is exactly `cad.document` (no browser,
//     shell, Linux guest, Python, filesystem-wide, network or external-send
//     tool can be called);
//   * the workspace is the conversation's own private task workspace.
// No fake approval grant is minted or supplied. The model's apply calls must
// omit `grant_id`; the runtime-issued authority for the exact call is the only
// path exercised. The test asserts there is no approval event and no pending
// approval.
//
// A watchdog polls the durable usage records and cancels the run if the
// computed model cost, an individual token dimension or the reported aggregate
// token budget exceeds the opt-in ceiling. Every run also has a wall-clock
// deadline. Those are hard stops, not claims that a skipped/failed turn passed.
//
// The token budget is ONE aggregate cap across all three model turns:
// `maxTotalTokens` counts uncached input + cache read + output, summed over
// every run. Reasoning tokens are already inside the provider's output count
// and cache-write tokens are already inside its input count, so neither is
// added again. `maxInputTokens` and `maxOutputTokens` may each be 1,000,000,
// but the aggregate guard still stops the combined reported total at the cap.
// The reviewed prepaid basis requires `maxTotalTokens`; a legacy metered
// opt-in that omits it keeps the previous separate input/output caps only.
//
// Isolation and cleanup
// ---------------------
// The test creates a fresh conversation UUID, lets `RunLaunchStore` create its
// private task workspace atomically, and deliberately calls
// `ConversationCenter.runService` + `ConversationRunService.startPrepared`
// instead of `startTask`/`startRun`. That is the same production service the
// UI constructs, but it does not run the conversation-center post-run
// personalization/title/memory-dream hooks for a synthetic goal. It does NOT
// strip the ordinary App's bounded personalization context from the provider
// prompt; the opt-in must explicitly acknowledge that real-App context. Empty
// `memoryQuery` avoids the embedding write path.
//
// Cleanup removes ONLY this task's conversation/workspace, the three run IDs'
// content snapshots, skill run snapshots and CAD viewport artifact
// directories, plus the bridge's live document. The App's saved provider
// configuration, global default model, personalization documents and memory
// are never written by this test. The durable CAD proposal store keeps the
// settled proposal record(s) for the deleted synthetic document (the product
// store has no delete-settled API; it prunes oldest settled records at its
// bound). That bounded, non-secret residue is disclosed in the handoff.
//
// Integration (primary)
// ---------------------
// 1. Add `Tests/FloeAppTests/NativeCADLiveLLMTests.swift` to the FloeAppTests
//    sources in `FloeAgent/project.yml` and regenerate the project.
// 2. Compile the App test host once in the normal batch.
// 3. Write the private opt-in file into the launched App's Caches directory.
// 4. Run only:
//      FloeAppTests/NativeCADLiveLLMTests/
//        testRealModelCreatesEditsHoleFilletsCapturesAndReopensNativeBracket
//    on the canonical reused iPad Simulator, with parallel testing disabled.
// 5. A skip is zero live evidence. Do not report this acceptance as passed
//    from a skip or from this source-only handoff.
//
// The exact scenario, ceilings and cleanup limitations are documented in
// `Local/Private/native-browser-cad-context-20261030/continuation/
// native-cad-llm-acceptance/`.

#if canImport(UIKit) && DEBUG && targetEnvironment(simulator)
import Foundation
import XCTest
import CoreGraphics
import ImageIO
import FloeCore
import FloeModels
import FloePersistence
import GRDB
import FloeProviders
import FloeTools
import FloeWorkbench
import FloeAgentRuntime
import FloeEnvironments
import FloeSecurity
import FloeCAD
@testable import FloeApp

@MainActor
final class NativeCADLiveLLMTests: XCTestCase {

    func testRealModelCreatesEditsHoleFilletsCapturesAndReopensNativeBracket() async throws {
        let optIn = try NativeCADLiveOptIn.load()
        executionTimeAllowance = optIn.executionTimeAllowance
        continueAfterFailure = true

        // Joins the ACTUAL launched App graph (same database, provider list,
        // tool registry, CAD host and credential resolution). Never creates a
        // second environment or a replacement provider.
        let environment = try await appQualificationEnvironment()
        let center = environment.conversationCenter

        // Optional coordinator-owned route: non-secret metadata plus an
        // explicitly forwarded test-runner credential. The App still stores
        // and resolves the credential through its ordinary Keychain service.
        let installed = try await NativeCADLiveOwnedRoute.installIfRequested(environment: environment)
        do {
            let route = try NativeCADLiveRoute.select(optIn: optIn, center: center)
            try NativeCADLivePreflight.requireNativeCADCapabilities()
            let session = NativeCADLiveSession(
                environment: environment, center: center, route: route, optIn: optIn)
            do { try await session.runAll() }
            catch {
                session.recordFailure(error)
                await session.cleanup()
                throw error
            }
            await session.cleanup()
        } catch {
            try await installed?.remove(environment: environment)
            throw error
        }
        try await installed?.remove(environment: environment)
    }
}

/// Non-paid accounting tests for the one aggregate CAD budget. They exercise
/// the same ledger the live acceptance uses, but never touch the App graph, a
/// provider, a credential, an opt-in file, the network or a model request.
@MainActor
final class NativeCADLiveBudgetTests: XCTestCase {

    /// Synthetic, test-only pricing. The metered basis uses positive exact
    /// integers; the prepaid basis stays on the reviewed exact-route shape.
    private func makeLedger(
        basis: NativeCADLiveBudgetBasis = .prepaidAgentPlan,
        maxInput: Int = 1_000_000,
        maxOutput: Int = 1_000_000,
        maxTotal: Int?
    ) -> NativeCADLiveLedger {
        let pricing: NativeCADLivePricing
        switch basis {
        case .prepaidAgentPlan:
            pricing = NativeCADLivePricing(
                inputPerMillion: .zero,
                outputPerMillion: .zero,
                basis: .prepaidAgentPlan
            )
        case .meteredUSD:
            pricing = NativeCADLivePricing(
                inputPerMillion: Decimal(1),
                outputPerMillion: Decimal(2),
                basis: .meteredUSD
            )
        }
        return NativeCADLiveLedger(
            pricing: pricing,
            maxCost: Decimal(10),
            maxInputTokens: maxInput,
            maxOutputTokens: maxOutput,
            maxTotalTokens: maxTotal
        )
    }

    private func record(
        _ runID: UUID,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        reasoning: Int = 0
    ) -> RunUsageRecord {
        RunUsageRecord(
            runID: runID,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            reasoningTokens: reasoning
        )
    }

    func testReportedAggregateCountsEachDimensionOnce() async {
        let runID = UUID()
        let ledger = makeLedger(maxTotal: 1_000_000)
        let totals = await ledger.update(runID: runID, records: [
            record(
                runID,
                input: 500_000,
                output: 80_000,
                cacheRead: 400_000,
                cacheWrite: 50_000,
                reasoning: 70_000
            ),
        ])
        XCTAssertEqual(totals.inputTokens, 500_000)
        XCTAssertEqual(totals.outputTokens, 80_000)
        XCTAssertEqual(totals.cacheReadTokens, 400_000)
        XCTAssertEqual(
            totals.reportedTotalTokens,
            980_000,
            "The aggregate must be uncached input + cache read + output; cache write is already "
                + "inside provider input and reasoning is already inside output."
        )
        XCTAssertTrue(totals.hasUsage)
        XCTAssertFalse(totals.exceeds)
        XCTAssertEqual(totals.cost, Decimal.zero)
    }

    func testCacheReadOnlyUsageCountsAsReportedUsage() async {
        let runID = UUID()
        let ledger = makeLedger(maxTotal: 1_000_000)
        let totals = await ledger.update(runID: runID, records: [
            record(runID, input: 0, output: 0, cacheRead: 750_000),
        ])
        XCTAssertEqual(totals.inputTokens, 0)
        XCTAssertEqual(totals.outputTokens, 0)
        XCTAssertEqual(totals.cacheReadTokens, 750_000)
        XCTAssertEqual(totals.reportedTotalTokens, 750_000)
        XCTAssertTrue(
            totals.hasUsage,
            "A fully cached prompt with no new output is still reported token usage."
        )
        XCTAssertFalse(totals.exceeds)
    }

    func testAggregateBoundaryIsInclusiveAndOneTokenOverFails() async {
        let runID = UUID()
        let ledger = makeLedger(maxTotal: 1_000_000)
        let atBoundary = await ledger.update(runID: runID, records: [
            record(runID, input: 500_000, output: 100_000, cacheRead: 400_000),
        ])
        XCTAssertEqual(atBoundary.reportedTotalTokens, 1_000_000)
        XCTAssertFalse(atBoundary.exceeds, "Exactly the aggregate cap is allowed.")

        let over = await ledger.update(runID: runID, records: [
            record(runID, input: 500_001, output: 100_000, cacheRead: 400_000),
        ])
        XCTAssertEqual(over.reportedTotalTokens, 1_000_001)
        XCTAssertTrue(over.exceeds, "One token over the aggregate cap must stop the run.")
    }

    func testRepeatedWatcherSnapshotsReplaceInsteadOfAppend() async {
        let runID = UUID()
        let ledger = makeLedger(maxTotal: 1_000_000)
        _ = await ledger.update(runID: runID, records: [
            record(runID, input: 600_000, output: 50_000),
        ])
        let second = await ledger.update(runID: runID, records: [
            record(runID, input: 600_000, output: 50_000),
            record(runID, input: 200_000, output: 20_000),
        ])
        XCTAssertEqual(
            second.reportedTotalTokens,
            870_000,
            "The durable snapshot for one run contains exactly its own requests."
        )

        let repeated = await ledger.update(runID: runID, records: [
            record(runID, input: 600_000, output: 50_000),
            record(runID, input: 200_000, output: 20_000),
        ])
        XCTAssertEqual(
            repeated.reportedTotalTokens,
            870_000,
            "Polling the same watcher snapshot again must replace, never append, the run's usage."
        )
    }

    func testAggregateSumsEveryOwnedRunID() async {
        let ledger = makeLedger(maxTotal: 1_000_000)
        let first = UUID()
        let second = UUID()
        let third = UUID()
        _ = await ledger.update(runID: first, records: [
            record(first, input: 300_000, output: 20_000),
        ])
        _ = await ledger.update(runID: second, records: [
            record(second, input: 300_000, output: 20_000),
        ])
        let all = await ledger.update(runID: third, records: [
            record(third, input: 300_000, output: 60_000),
        ])
        XCTAssertEqual(all.inputTokens, 900_000)
        XCTAssertEqual(all.outputTokens, 100_000)
        XCTAssertEqual(all.reportedTotalTokens, 1_000_000)
        XCTAssertFalse(all.exceeds, "All three owned runs at exactly the aggregate cap are allowed.")

        let over = await ledger.update(runID: third, records: [
            record(third, input: 300_001, output: 60_000),
        ])
        XCTAssertEqual(over.reportedTotalTokens, 1_000_001)
        XCTAssertTrue(over.exceeds, "The aggregate must include every owned run ID.")
    }

    func testLegacyMeteredOptInWithoutTotalKeepsSeparateCaps() async {
        let runID = UUID()
        let ledger = makeLedger(
            basis: .meteredUSD,
            maxInput: 600_000,
            maxOutput: 100_000,
            maxTotal: nil
        )
        let within = await ledger.update(runID: runID, records: [
            record(runID, input: 600_000, output: 50_000, cacheRead: 500_000),
        ])
        XCTAssertEqual(within.reportedTotalTokens, 1_150_000)
        XCTAssertFalse(
            within.exceeds,
            "A legacy metered opt-in without maxTotalTokens keeps only its separate input/output "
                + "caps; cache reads must not create an unrequested aggregate cap."
        )

        let inputOver = await ledger.update(runID: runID, records: [
            record(runID, input: 600_001, output: 50_000, cacheRead: 500_000),
        ])
        XCTAssertTrue(inputOver.exceeds)

        let outputOver = await ledger.update(runID: runID, records: [
            record(runID, input: 1, output: 100_001),
        ])
        XCTAssertTrue(outputOver.exceeds)
    }
}

/// The one reviewed prepaid route this test may account as zero incremental
/// USD. These are test-only constants: they do not change production provider
/// configuration or enable any generic free-model path.
private enum NativeCADLivePrepaidRoute {
    static let providerID = UUID(uuidString: "A3060000-0000-4000-8000-000000000001")!
    static let modelID = UUID(uuidString: "A3060000-0000-4000-8000-000000000002")!
    static let baseURL = URL(string: "https://ark.cn-beijing.volces.com/api/plan/v3")!
    static let remoteModelID = "deepseek-v4-flash"
    static let maxInputTokens = 1_000_000
    static let maxOutputTokens = 1_000_000
    static let maxTotalTokens = 1_000_000
    static let maxPerRunSeconds: Double = 900
    static let maxTotalSeconds: Double = 2_700

    /// Exact profile shape created by `NativeCADLiveOwnedRoute` for the
    /// reserved IDs above. No opt-in pin alone can authorize another base or
    /// model as a zero-increment route.
    static func matches(provider: ProviderProfile, model: ModelProfile) -> Bool {
        provider.id == providerID
            && model.id == modelID
            && model.providerID == provider.id
            && provider.isEnabled
            && provider.kind == .openAI
            && provider.wireProtocol == .openAIChatCompletions
            && provider.baseURL == baseURL
            && provider.baseURL.user == nil
            && provider.baseURL.password == nil
            && provider.baseURL.query == nil
            && provider.baseURL.fragment == nil
            && provider.displayName == "Native CAD qualification"
            && provider.toolNameCompatibility
            && provider.secretRef?.synchronizable == false
            && provider.secretRef?.keychainAccount.hasPrefix("native-cad-qualification.") == true
            && model.remoteModelID == remoteModelID
            && model.displayName == "Native CAD qualification"
            && model.isHiddenFromPrimaryPicker == true
            && model.pricing == nil
            && model.capabilities.contains(.text)
            && model.capabilities.contains(.tools)
            && !model.capabilities.contains(.vision)
    }
}

/// A qualification-only configuration, isolated from existing providers and
/// defaults. No API key is accepted in the metadata file or attachment output.
@MainActor
private struct NativeCADLiveOwnedRoute {
    struct Metadata: Decodable {
        var providerID: UUID
        var modelID: UUID
        var baseURL: URL
        var remoteModelID: String
        var contextTokens: Int
        var maxOutputTokens: Int
        var supportsVision: Bool?
    }
    static let providerID = NativeCADLivePrepaidRoute.providerID
    static let modelID = NativeCADLivePrepaidRoute.modelID
    let provider: ProviderProfile
    let account: String

    static func installIfRequested(environment: AppEnvironment) async throws -> Self? {
        guard let key = ProcessInfo.processInfo.environment["FLOE_NATIVE_CAD_LIVE_KEY"],
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(NativeCADLiveOptIn.directoryName)
        let metadata = try JSONDecoder().decode(Metadata.self,
            from: Data(contentsOf: root.appendingPathComponent("owned-route.json")))
        guard metadata.providerID == providerID, metadata.modelID == modelID,
              metadata.baseURL.absoluteString == ProcessInfo.processInfo.environment["FLOE_NATIVE_CAD_LIVE_BASE_URL"],
              metadata.remoteModelID == ProcessInfo.processInfo.environment["FLOE_NATIVE_CAD_LIVE_MODEL"],
              metadata.baseURL.scheme == "https", metadata.baseURL.host != nil,
              metadata.baseURL.user == nil, metadata.baseURL.password == nil,
              metadata.baseURL.query == nil,
              (16_384...1_000_000).contains(metadata.contextTokens),
              (1_024...32_768).contains(metadata.maxOutputTokens),
              !metadata.remoteModelID.isEmpty else {
            throw FloeError.validationFailed("Invalid owned qualification route metadata")
        }
        let existing = try await environment.configurationStore.provider(id: providerID)
        let existingModel = try await environment.configurationStore.model(id: modelID)
        guard existing == nil, existingModel == nil else {
            throw FloeError.validationFailed("Owned qualification provider already exists; inspect and clean its recorded state before retrying")
        }
        let account = "native-cad-qualification." + UUID().uuidString
        let keychain = KeychainStore(service: "org.floeagent.ios.secrets", synchronizable: false)
        let provider = ProviderProfile(id: providerID, kind: .openAI,
            wireProtocol: .openAIChatCompletions, baseURL: metadata.baseURL,
            displayName: "Native CAD qualification",
            secretRef: SecretReference(keychainAccount: account, synchronizable: false),
            toolNameCompatibility: true)
        let owned = Self(provider: provider, account: account)
        try keychain.store(account: account, secret: Data(key.utf8))
        do {
            try await environment.configurationStore.saveProvider(provider)
            try await environment.configurationStore.saveModel(ModelProfile(
                id: modelID, providerID: providerID, remoteModelID: metadata.remoteModelID,
                displayName: "Native CAD qualification",
                limits: ModelLimits(contextTokens: metadata.contextTokens,
                    maxOutputTokens: metadata.maxOutputTokens),
                capabilities: metadata.supportsVision == true ? [.text, .tools, .vision] : [.text, .tools],
                useSurfaces: [.chatAgent], reasoningEffort: .automatic, isHiddenFromPrimaryPicker: true))
            await environment.conversationCenter.reload()
            return owned
        } catch {
            try? await owned.remove(environment: environment)
            throw error
        }
    }

    func remove(environment: AppEnvironment) async throws {
        if let current = try await environment.configurationStore.provider(id: provider.id) {
            guard current.baseURL == provider.baseURL,
                  current.displayName == provider.displayName,
                  current.secretRef?.keychainAccount == account else {
                throw FloeError.validationFailed("Qualification provider ownership changed; configuration preserved")
            }
            try await environment.configurationStore.deleteProvider(id: provider.id)
        }
        try KeychainStore(service: "org.floeagent.ios.secrets", synchronizable: false)
            .delete(account: account)
        await environment.conversationCenter.reload()
    }
}

// MARK: - Opt-in metadata (non-secret, test-only cache file)

private struct NativeCADLiveOptIn: Sendable {
    static let directoryName = "FloeNativeCADLiveQualification"
    static let fileName = "opt-in.json"

    var providerID: UUID?
    var modelID: UUID?
    var remoteModelID: String?
    var allowAnyCheapCloudChatModel: Bool
    var prepaidBudgetBasis: Bool
    var inputPerMillionUSD: Decimal?
    var outputPerMillionUSD: Decimal?
    var maxCost: Decimal
    var maxInputTokens: Int
    var maxOutputTokens: Int
    /// One aggregate reported-token budget across every run: uncached input +
    /// cache read + output. Nil preserves the legacy metered separate caps.
    var maxTotalTokens: Int?
    var perRunTimeoutSeconds: Double
    var maxTotalSeconds: Double

    var executionTimeAllowance: TimeInterval { maxTotalSeconds + 60 }

    private struct Raw: Decodable {
        var schemaVersion: Int?
        var enabled: Bool?
        var acceptRealAppOrdinaryRunContext: Bool?
        var providerID: UUID?
        var modelID: UUID?
        var remoteModelID: String?
        var allowAnyCheapCloudChatModel: Bool?
        var prepaidBudgetBasis: Bool?
        var inputPerMillionUSD: Double?
        var outputPerMillionUSD: Double?
        var maxEstimatedCostUSD: Double?
        var maxInputTokens: Int?
        var maxOutputTokens: Int?
        var maxTotalTokens: Int?
        var perRunTimeoutSeconds: Double?
        var maxTotalSeconds: Double?
    }

    /// Reads the coordinator-provided policy file. The file is never created
    /// or modified by this test, and it must not contain credentials.
    static func load() throws -> NativeCADLiveOptIn {
        let caches: URL
        do {
            caches = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        } catch {
            throw XCTSkip("Live native CAD acceptance skipped: the App Caches directory is unavailable (\(error.localizedDescription)). A skip is not live evidence.")
        }
        let url = caches
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip(
                "Live native CAD acceptance skipped: no opt-in policy at \(url.path). "
                    + "The primary must write the non-secret policy file described in the handoff; "
                    + "a skip is not live evidence."
            )
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= 64 * 1024 else {
            throw XCTSkip("Live native CAD acceptance skipped: the opt-in policy file is empty or larger than 64 KiB. A skip is not live evidence.")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw XCTSkip("Live native CAD acceptance skipped: the opt-in policy file could not be read (\(error.localizedDescription)). A skip is not live evidence.")
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            throw XCTSkip("Live native CAD acceptance skipped: the opt-in policy is not valid JSON with the documented schema. A skip is not live evidence.")
        }
        guard raw.schemaVersion == nil || raw.schemaVersion == 1 else {
            throw XCTSkip("Live native CAD acceptance skipped: unsupported opt-in policy schemaVersion \(raw.schemaVersion ?? -1). A skip is not live evidence.")
        }
        guard raw.enabled == true else {
            throw XCTSkip("Live native CAD acceptance skipped: the opt-in policy is disabled. A skip is not live evidence.")
        }
        guard raw.acceptRealAppOrdinaryRunContext == true else {
            throw XCTSkip(
                "Live native CAD acceptance skipped: the opt-in policy does not explicitly accept "
                    + "the ordinary App run context (bounded App personalization may accompany the "
                    + "synthetic CAD prompt to the configured provider). A skip is not live evidence."
            )
        }

        let prepaid = raw.prepaidBudgetBasis == true
        let overrideInput = raw.inputPerMillionUSD
        let overrideOutput = raw.outputPerMillionUSD
        guard (overrideInput == nil) == (overrideOutput == nil) else {
            throw XCTSkip(
                "Live native CAD acceptance skipped: inputPerMillionUSD and outputPerMillionUSD "
                    + "must be supplied together (both or neither). A skip is not live evidence."
            )
        }
        if prepaid {
            let trimmedRemote = raw.remoteModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.providerID == NativeCADLivePrepaidRoute.providerID,
                  raw.modelID == NativeCADLivePrepaidRoute.modelID,
                  trimmedRemote == NativeCADLivePrepaidRoute.remoteModelID,
                  raw.allowAnyCheapCloudChatModel != true,
                  let overrideInput, let overrideOutput,
                  overrideInput == 0, overrideOutput == 0 else {
                throw XCTSkip(
                    "Live native CAD acceptance skipped: prepaidBudgetBasis is accepted only "
                        + "for the exact reserved owned Agent Plan provider/model IDs, remote "
                        + "model and both explicit zero per-million increments; unpinned "
                        + "free-model and PAYG fallbacks are not permitted. A skip is not live evidence."
                )
            }
        } else if let overrideInput, let overrideOutput {
            guard overrideInput.isFinite, overrideOutput.isFinite,
                  overrideInput > 0, overrideOutput > 0,
                  overrideInput <= 1.5, overrideOutput <= 6.0 else {
                throw XCTSkip(
                    "Live native CAD acceptance skipped: the explicit USD pricing override is "
                        + "outside the cheap-model band (input ≤ 1.5, output ≤ 6.0 per million) "
                        + "and zero rates require prepaidBudgetBasis for the reviewed owned route. "
                        + "A skip is not live evidence."
                )
            }
        }

        let maxCostDouble = raw.maxEstimatedCostUSD ?? 0.25
        guard maxCostDouble.isFinite, maxCostDouble > 0, maxCostDouble <= 2.0 else {
            throw XCTSkip(
                "Live native CAD acceptance skipped: maxEstimatedCostUSD must be greater than zero "
                    + "and at most 2.0. A skip is not live evidence."
            )
        }
        let maxInput = raw.maxInputTokens ?? 400_000
        guard (1...1_000_000).contains(maxInput) else {
            throw XCTSkip("Live native CAD acceptance skipped: maxInputTokens must be 1...1,000,000. A skip is not live evidence.")
        }
        let maxOutput = raw.maxOutputTokens ?? 30_000
        guard (1...1_000_000).contains(maxOutput) else {
            throw XCTSkip("Live native CAD acceptance skipped: maxOutputTokens must be 1...1,000,000. A skip is not live evidence.")
        }
        let maxTotal: Int?
        if let declaredTotal = raw.maxTotalTokens {
            guard (1...1_000_000).contains(declaredTotal) else {
                throw XCTSkip("Live native CAD acceptance skipped: maxTotalTokens must be 1...1,000,000. A skip is not live evidence.")
            }
            maxTotal = declaredTotal
        } else if prepaid {
            throw XCTSkip(
                "Live native CAD acceptance skipped: prepaidBudgetBasis requires maxTotalTokens "
                    + "so the one aggregate budget across every run is explicit. A skip is not live evidence."
            )
        } else {
            maxTotal = nil
        }
        let perRun = raw.perRunTimeoutSeconds ?? 300
        guard perRun.isFinite, (30...900).contains(perRun) else {
            throw XCTSkip("Live native CAD acceptance skipped: perRunTimeoutSeconds must be 30...900. A skip is not live evidence.")
        }
        let total = raw.maxTotalSeconds ?? 1_500
        guard total.isFinite, (60...2_700).contains(total), total >= perRun else {
            throw XCTSkip("Live native CAD acceptance skipped: maxTotalSeconds must be 60...2,700 and at least perRunTimeoutSeconds. A skip is not live evidence.")
        }

        if prepaid {
            guard let maxTotal,
                  maxTotal <= NativeCADLivePrepaidRoute.maxTotalTokens,
                  maxInput <= NativeCADLivePrepaidRoute.maxInputTokens,
                  maxOutput <= NativeCADLivePrepaidRoute.maxOutputTokens,
                  perRun <= NativeCADLivePrepaidRoute.maxPerRunSeconds,
                  total <= NativeCADLivePrepaidRoute.maxTotalSeconds else {
                throw XCTSkip(
                    "Live native CAD acceptance skipped: prepaidBudgetBasis may not exceed the "
                        + "approved 1,000,000-token aggregate (uncached input + cache read + "
                        + "output), 1,000,000 input, 1,000,000 output, 900 s per turn or "
                        + "2,700 s total. A skip is not live evidence."
                )
            }
        }

        let trimmedRemote = raw.remoteModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NativeCADLiveOptIn(
            providerID: raw.providerID,
            modelID: raw.modelID,
            remoteModelID: (trimmedRemote?.isEmpty ?? true) ? nil : trimmedRemote,
            allowAnyCheapCloudChatModel: raw.allowAnyCheapCloudChatModel == true,
            prepaidBudgetBasis: prepaid,
            inputPerMillionUSD: overrideInput.map { Decimal($0) },
            outputPerMillionUSD: overrideOutput.map { Decimal($0) },
            maxCost: Decimal(maxCostDouble),
            maxInputTokens: maxInput,
            maxOutputTokens: maxOutput,
            maxTotalTokens: maxTotal,
            perRunTimeoutSeconds: perRun,
            maxTotalSeconds: total
        )
    }
}

// MARK: - Route selection (actual App configuration only)

private enum NativeCADLiveBudgetBasis: String, Sendable, Equatable {
    case meteredUSD
    case prepaidAgentPlan
}

private struct NativeCADLivePricing: Sendable {
    var inputPerMillion: Decimal
    var outputPerMillion: Decimal
    var basis: NativeCADLiveBudgetBasis

    func cost(inputTokens: Int, outputTokens: Int) -> Decimal {
        Decimal(inputTokens) * inputPerMillion / 1_000_000
            + Decimal(outputTokens) * outputPerMillion / 1_000_000
    }
}

private struct NativeCADLiveRoute: Sendable {
    var provider: ProviderProfile
    var model: ModelProfile
    var pricing: NativeCADLivePricing

    /// Picks a currently configured, enabled, cheap, tool-capable cloud chat
    /// model from the live App configuration. DeepSeek Flash is preferred when
    /// present. No provider, model, key or account is created or changed.
    @MainActor
    static func select(
        optIn: NativeCADLiveOptIn,
        center: ConversationCenter
    ) throws -> NativeCADLiveRoute {
        let providers = center.providers
        guard !providers.isEmpty else {
            throw XCTSkip("Live native CAD acceptance skipped: the App has no enabled provider after launch. A skip is not live evidence.")
        }
        let providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        if optIn.prepaidBudgetBasis {
            guard optIn.providerID == NativeCADLivePrepaidRoute.providerID,
                  optIn.modelID == NativeCADLivePrepaidRoute.modelID,
                  optIn.remoteModelID == NativeCADLivePrepaidRoute.remoteModelID,
                  !optIn.allowAnyCheapCloudChatModel else {
                throw XCTSkip(
                    "Live native CAD acceptance skipped: the prepaid budget basis requires the "
                        + "exact reserved owned Agent Plan route pins and does not permit a "
                        + "fallback model. A skip is not live evidence."
                )
            }
        }

        var candidates: [(provider: ProviderProfile, model: ModelProfile)] = []
        if let modelID = optIn.modelID {
            guard let pair = center.providerAndModel(modelID: modelID) else {
                throw XCTSkip("Live native CAD acceptance skipped: the pinned modelID \(modelID.uuidString) is not an enabled chat model in the App. A skip is not live evidence.")
            }
            if let providerID = optIn.providerID, pair.0.id != providerID {
                throw XCTSkip("Live native CAD acceptance skipped: the pinned model belongs to a different provider than the pinned providerID. A skip is not live evidence.")
            }
            candidates = [(provider: pair.0, model: pair.1)]
        } else if let remote = optIn.remoteModelID {
            candidates = center.availableAgentModels.compactMap { model -> (provider: ProviderProfile, model: ModelProfile)? in
                guard model.remoteModelID.caseInsensitiveCompare(remote) == .orderedSame,
                      let provider = providersByID[model.providerID] else { return nil }
                if let providerID = optIn.providerID, provider.id != providerID { return nil }
                return (provider: provider, model: model)
            }
        } else if let providerID = optIn.providerID {
            guard let provider = providersByID[providerID] else {
                throw XCTSkip("Live native CAD acceptance skipped: the pinned providerID is not enabled in the App. A skip is not live evidence.")
            }
            candidates = center.availableAgentModels.compactMap { model -> (provider: ProviderProfile, model: ModelProfile)? in
                model.providerID == provider.id ? (provider: provider, model: model) : nil
            }
        } else {
            candidates = center.availableAgentModels.compactMap { model -> (provider: ProviderProfile, model: ModelProfile)? in
                providersByID[model.providerID].map { (provider: $0, model: model) }
            }
        }

        let eligible = candidates.filter { pair in
            isEligible(provider: pair.provider, model: pair.model, optIn: optIn)
        }
        guard !eligible.isEmpty else {
            throw XCTSkip(
                "Live native CAD acceptance skipped: no configured, enabled, cheap, tool-capable "
                    + "cloud chat model with a bounded metered price or the exact prepaid route "
                    + "is visible to the App. A skip is not live evidence."
            )
        }

        let deepSeekFlash = eligible.filter { pair in
            let name = "\(pair.model.remoteModelID) \(pair.model.displayName)".lowercased()
            return name.contains("deepseek") && name.contains("flash")
        }
        let selectable: [(provider: ProviderProfile, model: ModelProfile)]
        if optIn.modelID != nil || optIn.remoteModelID != nil {
            selectable = eligible
        } else if !deepSeekFlash.isEmpty {
            selectable = deepSeekFlash
        } else if optIn.allowAnyCheapCloudChatModel {
            selectable = eligible
        } else {
            throw XCTSkip(
                "Live native CAD acceptance skipped: no enabled DeepSeek Flash chat model is "
                    + "visible to the App, and the opt-in does not allow another cheap model. "
                    + "Pin an approved cheap model or set allowAnyCheapCloudChatModel only after "
                    + "an explicit cost/data decision. A skip is not live evidence."
            )
        }

        guard let chosen = selectable.min(by: { lhs, rhs in
            priceRank(lhs.model, optIn: optIn) < priceRank(rhs.model, optIn: optIn)
        }), let pricing = pricing(for: chosen.model, optIn: optIn) else {
            throw XCTSkip(
                "Live native CAD acceptance skipped: the selected model has no usable metered "
                    + "USD pricing or exact prepaid basis, so cost cannot be bounded. "
                    + "A skip is not live evidence."
            )
        }
        if optIn.prepaidBudgetBasis {
            guard NativeCADLivePrepaidRoute.matches(
                provider: chosen.provider, model: chosen.model
            ), pricing.basis == .prepaidAgentPlan else {
                throw XCTSkip(
                    "Live native CAD acceptance skipped: prepaidBudgetBasis requires the exact "
                        + "reserved imported Agent Plan provider/model route and both explicit "
                        + "zero increments; no PAYG or alternate-channel fallback is allowed. "
                        + "A skip is not live evidence."
                )
            }
        }

        // App-owned credential resolution only. The value is checked for
        // presence and immediately discarded; it is never logged, printed,
        // persisted or passed through this file's error messages.
        let credentials = center.resolveCredentials(for: chosen.provider)
        guard credentials.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw XCTSkip(
                "Live native CAD acceptance skipped: the selected provider record exists, but the "
                    + "App's credential resolution returned no API key. Configure/repair the key in "
                    + "the App, then re-run; the key is never read outside the App. "
                    + "A skip is not live evidence."
            )
        }

        return NativeCADLiveRoute(
            provider: chosen.provider,
            model: chosen.model,
            pricing: pricing
        )
    }

    private static func isEligible(
        provider: ProviderProfile,
        model: ModelProfile,
        optIn: NativeCADLiveOptIn
    ) -> Bool {
        guard provider.isEnabled,
              provider.kind != .local,
              provider.id != ProviderProfile.onDeviceProviderID else { return false }
        guard model.isEnabled,
              model.capabilities.contains(.text),
              model.capabilities.contains(.tools),
              model.supportsChatAgentSurface else { return false }
        guard let pricing = pricing(for: model, optIn: optIn) else { return false }

        let name = "\(model.remoteModelID) \(model.displayName)".lowercased()
        if name.contains("ultra") || name.contains("opus") { return false }
        if name.contains("kimi") && (name.contains("max") || name.contains("ultra")) { return false }

        let input = NSDecimalNumber(decimal: pricing.inputPerMillion).doubleValue
        let output = NSDecimalNumber(decimal: pricing.outputPerMillion).doubleValue
        switch pricing.basis {
        case .prepaidAgentPlan:
            // Zero incremental USD is valid only for the exact reserved,
            // imported prepaid route. It is not a generic free-model path.
            guard optIn.prepaidBudgetBasis,
                  NativeCADLivePrepaidRoute.matches(provider: provider, model: model),
                  input == 0, output == 0 else { return false }
        case .meteredUSD:
            // An explicit, conservative "cheap" ceiling. A model outside this
            // band needs a deliberate product decision, not a silent fallback.
            guard input > 0, output > 0, input <= 1.5, output <= 6.0 else { return false }
        }
        return true
    }

    private static func pricing(
        for model: ModelProfile,
        optIn: NativeCADLiveOptIn
    ) -> NativeCADLivePricing? {
        if let metadata = model.pricing,
           metadata.currency.uppercased() == "USD",
           let input = metadata.inputPerMillion,
           let output = metadata.outputPerMillion {
            let inputNumber = NSDecimalNumber(decimal: input).doubleValue
            let outputNumber = NSDecimalNumber(decimal: output).doubleValue
            // A zero or incomplete saved price is not a metered rate. It must
            // never become an arbitrary free-model candidate.
            guard inputNumber.isFinite, outputNumber.isFinite,
                  inputNumber > 0, outputNumber > 0 else { return nil }
            return NativeCADLivePricing(
                inputPerMillion: input,
                outputPerMillion: output,
                basis: .meteredUSD
            )
        }
        // Explicit, non-secret USD price supplied by the primary when the App
        // has no usable USD pricing metadata. The price is only a test bound;
        // it never edits the saved provider/model configuration.
        guard let input = optIn.inputPerMillionUSD,
              let output = optIn.outputPerMillionUSD else { return nil }
        if optIn.prepaidBudgetBasis {
            guard input == Decimal.zero, output == Decimal.zero else { return nil }
            return NativeCADLivePricing(
                inputPerMillion: input,
                outputPerMillion: output,
                basis: .prepaidAgentPlan
            )
        }
        guard input > Decimal.zero, output > Decimal.zero else { return nil }
        return NativeCADLivePricing(
            inputPerMillion: input,
            outputPerMillion: output,
            basis: .meteredUSD
        )
    }

    private static func priceRank(_ model: ModelProfile, optIn: NativeCADLiveOptIn) -> Decimal {
        guard let pricing = pricing(for: model, optIn: optIn) else { return Decimal(1_000_000) }
        return pricing.inputPerMillion + pricing.outputPerMillion
    }
}

// MARK: - Native CAD tool discovery

private enum NativeCADLivePreflight {
    @MainActor
    static func requireNativeCADCapabilities() throws {
        guard ToolRunnerRegistry.shared.runner(named: CadDocumentTool.name) != nil else {
            XCTFail(
                "The actual App graph does not expose \(CadDocumentTool.name); "
                    + "native CAD acceptance cannot run."
            )
            throw NativeCADLiveError.toolUnavailable(
                "The App's runtime tool registry has no executable \(CadDocumentTool.name)."
            )
        }
        let requiredOperations = [
            "sketch.create", "sketch.addEntities", "feature.extrude", "feature.fillet",
        ]
        for operation in requiredOperations {
            guard FloeCADDocument.nativeOperationNames.contains(operation) else {
                XCTFail(
                    "The actual FloeCAD kernel does not advertise \(operation); "
                        + "the synthetic bracket flow cannot be executed."
                )
                throw NativeCADLiveError.toolUnavailable(
                    "FloeCAD does not advertise the required operation \(operation)."
                )
            }
        }
    }
}

// MARK: - Stop signal, budget ledger and errors

private enum NativeCADLiveError: Error, Sendable, CustomStringConvertible {
    case toolUnavailable(String)
    case invalidContextWindow(Int)
    case timedOut(UUID)
    case budgetExceeded(String)
    case runIncomplete(state: String, detail: String)
    case missingUsage
    case missingDocument(String)
    case invalidDocument(String)
    case missingCapture
    case invalidCapture(String)

    var description: String {
        switch self {
        case .toolUnavailable(let detail):
            return "Native CAD tool unavailable: \(detail)"
        case .invalidContextWindow(let tokens):
            return "The model context window must be exactly 65,536 tokens for the compaction acceptance; found \(tokens)."
        case .timedOut(let runID):
            return "Live native CAD turn \(runID.uuidString) exceeded its wall-clock deadline and was cancelled."
        case .budgetExceeded(let detail):
            return "Live native CAD acceptance exceeded its approved cost/data ceiling: \(detail)"
        case .runIncomplete(let state, let detail):
            return "Live native CAD run did not complete successfully (state \(state)): \(detail)"
        case .missingUsage:
            return "The live model run produced no durable usage record, so cost/data cannot be bounded or evidenced."
        case .missingDocument(let path):
            return "The native CAD package was not found at \(path) after the model turn."
        case .invalidDocument(let detail):
            return "The native CAD package could not be verified: \(detail)"
        case .missingCapture:
            return "No successful cad.document capture result with a real PNG artifact was found."
        case .invalidCapture(let detail):
            return "The CAD viewport capture was refused as evidence: \(detail)"
        }
    }
}

private actor NativeCADLiveStopSignal {
    private var failure: NativeCADLiveError?

    func set(_ failure: NativeCADLiveError) {
        if self.failure == nil { self.failure = failure }
    }

    func throwIfStopped() throws {
        if let failure { throw failure }
    }
}

private struct NativeCADLiveTotals: Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    /// Uncached input + cache read + output, counted once across every run.
    var reportedTotalTokens: Int
    var cost: Decimal
    var maxCost: Decimal
    var maxInputTokens: Int
    var maxOutputTokens: Int
    var maxTotalTokens: Int?
    var basis: NativeCADLiveBudgetBasis

    var hasUsage: Bool { reportedTotalTokens > 0 }
    var exceeds: Bool {
        if cost > maxCost { return true }
        if inputTokens > maxInputTokens { return true }
        if outputTokens > maxOutputTokens { return true }
        if let maxTotalTokens, reportedTotalTokens > maxTotalTokens { return true }
        return false
    }

    var description: String {
        let aggregate: String
        if let maxTotalTokens {
            aggregate = "reported aggregate \(reportedTotalTokens)/\(maxTotalTokens) tokens "
                + "(uncached input + cache read + output)"
        } else {
            aggregate = "reported aggregate \(reportedTotalTokens) tokens "
                + "(uncached input + cache read + output; legacy opt-in has no aggregate cap)"
        }
        let tokens = "uncached input \(inputTokens)/\(maxInputTokens) tokens, "
            + "cache read \(cacheReadTokens) tokens, "
            + "output \(outputTokens)/\(maxOutputTokens) tokens, "
            + aggregate
        switch basis {
        case .meteredUSD:
            return "\(tokens), estimated metered cost \(cost) USD (cap \(maxCost) USD)"
        case .prepaidAgentPlan:
            return "\(tokens), 0 incremental USD from prepaid Agent Plan consumption "
                + "(prepaid allowance, not a metered market price or free-model claim; "
                + "cost guard \(maxCost) USD remains in force)"
        }
    }
}

private actor NativeCADLiveLedger {
    private let pricing: NativeCADLivePricing
    private let maxCost: Decimal
    private let maxInputTokens: Int
    private let maxOutputTokens: Int
    private let maxTotalTokens: Int?
    private var recordsByRun: [UUID: [RunUsageRecord]] = [:]

    init(
        pricing: NativeCADLivePricing,
        maxCost: Decimal,
        maxInputTokens: Int,
        maxOutputTokens: Int,
        maxTotalTokens: Int?
    ) {
        self.pricing = pricing
        self.maxCost = maxCost
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
        self.maxTotalTokens = maxTotalTokens
    }

    /// The watcher polls the same run repeatedly, so each call REPLACES that
    /// run's snapshot. Assigning (rather than appending) is what makes a
    /// repeated watcher observation count one model request exactly once.
    func update(runID: UUID, records: [RunUsageRecord]) -> NativeCADLiveTotals {
        recordsByRun[runID] = records
        return totalsLocked()
    }

    func totals() -> NativeCADLiveTotals {
        totalsLocked()
    }

    private func totalsLocked() -> NativeCADLiveTotals {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cost = Decimal.zero
        for records in recordsByRun.values {
            for record in records {
                // Cost keeps using the provider's uncached input and output
                // fields. Reasoning is already part of output; cache write is
                // already part of provider input on wires that report it.
                input += record.inputTokens
                output += record.outputTokens
                cacheRead += record.cacheReadTokens ?? 0
                cost += pricing.cost(inputTokens: record.inputTokens, outputTokens: record.outputTokens)
            }
        }
        return NativeCADLiveTotals(
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            reportedTotalTokens: input + cacheRead + output,
            cost: cost,
            maxCost: maxCost,
            maxInputTokens: maxInputTokens,
            maxOutputTokens: maxOutputTokens,
            maxTotalTokens: maxTotalTokens,
            basis: pricing.basis
        )
    }
}

// MARK: - One owned task/workspace and the three-turn flow

@MainActor
private final class NativeCADLiveSession {
    private let environment: AppEnvironment
    private let center: ConversationCenter
    private let route: NativeCADLiveRoute
    private let optIn: NativeCADLiveOptIn
    private let ledger: NativeCADLiveLedger
    private let conversationID = UUID()
    private let documentName: String
    private let title: String

    private var runIDs: [UUID] = []
    private var services: [ConversationRunService] = []
    private var workspaceID: UUID?
    private var workspaceRoot: URL?
    private var documentURL: URL?
    private var captureRelativePaths: [String] = []
    private var cleanupStarted = false
    private var failureDescription: String?

    init(
        environment: AppEnvironment,
        center: ConversationCenter,
        route: NativeCADLiveRoute,
        optIn: NativeCADLiveOptIn
    ) {
        self.environment = environment
        self.center = center
        self.route = route
        self.optIn = optIn
        self.ledger = NativeCADLiveLedger(
            pricing: route.pricing,
            maxCost: optIn.maxCost,
            maxInputTokens: optIn.maxInputTokens,
            maxOutputTokens: optIn.maxOutputTokens,
            maxTotalTokens: optIn.maxTotalTokens
        )
        self.documentName = "NativeBracket-\(String(UUID().uuidString.prefix(8))).floecad"
        self.title = "Native CAD live acceptance \(String(UUID().uuidString.prefix(6)))"
    }

    func runAll() async throws {
        let firstGoal = turnOneGoal()
        let first = try await prepare(goal: firstGoal, firstTurn: true)
        let firstEvents = try await runTurn(prepared: first, goal: firstGoal)
        try NativeCADLiveEvidence.assertTurnOneEvidence(firstEvents)

        let url = try XCTUnwrap(documentURL, "The private task workspace root was not resolved.")
        let afterCreate = try await inspectDocument(at: url)
        try assertInitialGeometry(afterCreate)
        guard afterCreate.bodyCount == 1,
              afterCreate.bodyIsAnalytic,
              afterCreate.circles.count == 1,
              abs((afterCreate.circles.first?.radius ?? -1) - 3.0) < 1e-3 else {
            throw NativeCADLiveError.invalidDocument(
                "Initial bracket geometry assertions failed; stopping before the next paid turn."
            )
        }

        let secondGoal = turnTwoGoal(documentPath: documentName)
        let second = try await prepare(goal: secondGoal, firstTurn: false)
        let secondEvents = try await runTurn(prepared: second, goal: secondGoal)
        try NativeCADLiveEvidence.assertTurnTwoEvidence(secondEvents)

        let afterEdit = try await inspectDocument(at: url)
        try assertEditedGeometry(afterEdit, initial: afterCreate)
        guard afterEdit.bodyID == afterCreate.bodyID,
              afterEdit.bodyIsAnalytic,
              abs((afterEdit.circles.first?.radius ?? -1) - 4.0) < 1e-3,
              let editedFillet = afterEdit.fillet,
              abs(editedFillet.radius - 2.0) < 1e-3,
              (1...4).contains(editedFillet.edgeCount) else {
            throw NativeCADLiveError.invalidDocument(
                "Ø8 existing-hole/fillet geometry assertions failed; stopping before the final paid turn."
            )
        }

        let thirdGoal = turnThreeGoal(documentPath: documentName)
        let third = try await prepare(goal: thirdGoal, firstTurn: false)
        let thirdEvents = try await runTurn(prepared: third, goal: thirdGoal)
        try NativeCADLiveEvidence.assertTurnThreeEvidence(thirdEvents)

        let afterFinal = try await inspectDocument(at: url)
        try assertFinalGeometry(afterFinal, edited: afterEdit)

        let png = try validateCapture(
            events: thirdEvents,
            runID: third.run.id,
            minimumRevision: afterEdit.revision
        )
        attach(png)

        let totals = await ledger.totals()
        let expectedBasis: NativeCADLiveBudgetBasis = optIn.prepaidBudgetBasis
            ? .prepaidAgentPlan
            : .meteredUSD
        XCTAssertEqual(
            totals.basis,
            expectedBasis,
            "The usage ledger must account the configured prepaid or metered basis exactly."
        )
        if optIn.prepaidBudgetBasis {
            XCTAssertEqual(
                totals.cost,
                Decimal.zero,
                "Prepaid Agent Plan usage must not invent a metered per-token charge."
            )
        }
        XCTAssertTrue(totals.hasUsage, "The real model run must produce durable token usage.")
        XCTAssertFalse(totals.exceeds, "Hard cost/data ceiling exceeded: \(totals.description)")
        XCTAssertLessThanOrEqual(totals.cost, optIn.maxCost)
        if let maxTotalTokens = optIn.maxTotalTokens {
            XCTAssertLessThanOrEqual(
                totals.reportedTotalTokens,
                maxTotalTokens,
                "The one aggregate budget (uncached input + cache read + output) was exceeded: \(totals.description)"
            )
        }
        attachUsage(totals)
    }

    // MARK: Prepare (durable, task-owned)

    private func prepare(goal: String, firstTurn: Bool) async throws -> PreparedRun {
        let runID = UUID()
        let request = RunLaunchRequest(
            conversationID: firstTurn ? nil : conversationID,
            newConversationID: firstTurn ? conversationID : nil,
            conversationTitle: title,
            runID: runID,
            goal: goal,
            workspaceID: firstTurn ? nil : workspaceID,
            conversationMode: "chat",
            initialPolicy: DraftTaskPolicy(approvalMode: .automatic),
            providerID: route.provider.id,
            modelID: route.model.id,
            providerName: route.provider.displayName ?? route.provider.kind.rawValue,
            modelName: route.model.displayName
        )
        let prepared = try await environment.runLaunchStore.prepare(request)

        if firstTurn {
            workspaceID = prepared.workspace.id
            let root = try NativeCADLivePaths.workspaceRoot(
                for: prepared.workspace,
                conversationID: conversationID
            )
            workspaceRoot = root
            documentURL = root.appendingPathComponent(documentName, isDirectory: true)
            try await saveOwnedTaskPolicy(conversationID: conversationID)
        }
        runIDs.append(runID)
        return prepared
    }

    private func saveOwnedTaskPolicy(conversationID: UUID) async throws {
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
        try await SQLiteWorkspaceStore(database: environment.database)
            .saveTaskPolicy(policy)
    }

    // MARK: One real model/service turn

    private func runTurn(prepared: PreparedRun, goal: String) async throws -> [RunEventRecord] {
        let runID = prepared.run.id
        let history = try await ConversationHistoryAssembler(store: environment.conversationStore)
            .build(conversationID: conversationID)
            .filter { $0.id != prepared.userMessage.id }

        // The exact production service factory used by ConversationCenter's
        // deferred launch. Passing `.continuation` prevents the one auxiliary
        // automatic-reasoning-effort classifier request (and a possible second
        // paid model) — this acceptance exercises the selected CAD model, not a
        // helper route.
        let service = try await center.runService(
            for: conversationID,
            provider: route.provider,
            model: route.model,
            runID: runID,
            executionMode: .agent,
            runSurface: .ordinary,
            workspaceID: prepared.workspace.id,
            memoryQuery: "",
            conversationHistory: history,
            automaticReasoningEffortIngress: .continuation
        )
        services.append(service)
        try await execute(service: service, runID: runID, goal: goal)

        let events = try await environment.runStore.events(runID: runID)
        try NativeCADLiveEvidence.assertToolSurface(
            events: events,
            documentName: documentName,
            turn: runIDs.count
        )
        return events
    }

    private func execute(
        service: ConversationRunService,
        runID: UUID,
        goal: String
    ) async throws {
        let runStore = environment.runStore
        let ledger = self.ledger
        let stop = NativeCADLiveStopSignal()
        let timeoutMilliseconds = Int64(optIn.perRunTimeoutSeconds * 1000)

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await service.startPrepared(goal: goal)
                }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                    await stop.set(.timedOut(runID))
                    await service.cancel()
                    throw NativeCADLiveError.timedOut(runID)
                }
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(2_000))
                        let records = (try? await runStore.usage(runID: runID)) ?? []
                        let totals = await ledger.update(runID: runID, records: records)
                        if totals.exceeds {
                            let message = totals.description
                            await stop.set(.budgetExceeded(message))
                            await service.cancel()
                            throw NativeCADLiveError.budgetExceeded(message)
                        }
                    }
                }
                do {
                    try await group.next()
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }

            try await stop.throwIfStopped()

            var snapshot = await service.snapshot()
            for _ in 0..<50 where !snapshot.isTerminal {
                try? await Task.sleep(for: .milliseconds(100))
                snapshot = await service.snapshot()
            }
            guard snapshot.isTerminal else {
                await service.cancel()
                throw NativeCADLiveError.runIncomplete(
                    state: snapshot.stateName,
                    detail: "The run never reached a terminal state."
                )
            }
            guard snapshot.stateName == "completed" else {
                throw NativeCADLiveError.runIncomplete(
                    state: snapshot.stateName,
                    detail: "The run did not complete; acceptance never retries a failed model turn."
                )
            }
            guard snapshot.pendingApproval == nil else {
                throw NativeCADLiveError.runIncomplete(
                    state: snapshot.stateName,
                    detail: "A call remained awaiting interactive approval; the owned task policy is automatic."
                )
            }

            let records = (try? await runStore.usage(runID: runID)) ?? []
            let totals = await ledger.update(runID: runID, records: records)
            guard totals.hasUsage else { throw NativeCADLiveError.missingUsage }
            guard !totals.exceeds else {
                throw NativeCADLiveError.budgetExceeded(totals.description)
            }
        } catch {
            await service.cancel()
            throw error
        }
    }

    // MARK: On-disk independent verification

    private func inspectDocument(at url: URL) async throws -> NativeCADLiveDocumentState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NativeCADLiveError.missingDocument(url.path)
        }
        let manifest = url.appendingPathComponent("manifest.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw NativeCADLiveError.invalidDocument("the versioned package has no manifest.json")
        }
        guard let stored = await FloeCADDocument.storedIdentity(at: url) else {
            throw NativeCADLiveError.invalidDocument("the versioned store rejected the package identity")
        }

        let document = try await FloeCADDocument.open(at: url)
        defer { document.close() }
        let summary = document.summary()
        let bodies = try nativeRows(document, scope: "bodies")
        guard let body = bodies.first, let bodyID = body["id"] as? String else {
            throw NativeCADLiveError.invalidDocument("the package has no body")
        }
        let isAnalytic = (body["analyticBRep"] as? Bool) == true
        let volume = try measureVolume(document, bodyID: bodyID)
        let sketches = try nativeRows(document, scope: "sketches")
        let features = try nativeRows(document, scope: "features")
        let faces = try nativeRows(document, scope: "faces")

        var circles: [NativeCADLiveCircle] = []
        for sketch in sketches {
            guard let sketchID = sketch["id"] as? String,
                  let entityRows = sketch["entityRows"] as? [[String: Any]] else { continue }
            for row in entityRows {
                guard (row["kind"] as? String) == "circle",
                      (row["construction"] as? Bool) != true,
                      let entityID = row["id"] as? String,
                      let radius = NativeCADLiveJSON.number(row["radius"]),
                      let diameter = NativeCADLiveJSON.number(row["diameterMM"]) else { continue }
                circles.append(NativeCADLiveCircle(
                    sketchID: sketchID,
                    entityID: entityID,
                    radius: radius,
                    diameter: diameter
                ))
            }
        }

        var fillet: NativeCADLiveFillet?
        for row in features where (row["kind"] as? String) == "fillet" {
            guard let id = row["id"] as? String,
                  let parameters = row["parameters"] as? [[String: Any]] else { continue }
            let radius = parameters.first { ($0["name"] as? String) == "radius" }
                .flatMap { NativeCADLiveJSON.number($0["value"]) }
            let edgeCount = parameters.first { ($0["name"] as? String) == "edge_count" }
                .flatMap { NativeCADLiveJSON.int($0["value"]) }
            if let radius, let edgeCount {
                fillet = NativeCADLiveFillet(id: id, radius: radius, edgeCount: edgeCount)
                break
            }
        }

        let cylindricalRadii = faces.compactMap { row -> Double? in
            guard (row["kind"] as? String) == "cylindrical" else { return nil }
            return NativeCADLiveJSON.number(row["radiusMM"])
        }

        return NativeCADLiveDocumentState(
            revision: stored.revision,
            contentSHA256: stored.contentSHA256,
            modelSHA256: stored.modelSHA256,
            bodyCount: summary.bodyCount,
            sketchCount: summary.sketchCount,
            featureCount: summary.featureCount,
            bodyID: bodyID,
            bodyIsAnalytic: isAnalytic,
            bodyVolumeMM3: volume,
            circles: circles,
            fillet: fillet,
            cylindricalRadii: cylindricalRadii
        )
    }

    private func assertInitialGeometry(_ state: NativeCADLiveDocumentState) throws {
        XCTAssertEqual(state.bodyCount, 1, "The bracket must be one body after the hole cut.")
        XCTAssertTrue(state.bodyIsAnalytic, "The plate+hole body must remain an analytic B-rep.")
        XCTAssertEqual(state.circles.count, 1, "The bracket must contain exactly one non-construction hole circle.")
        let circle = try XCTUnwrap(state.circles.first, "The initial Ø6 hole circle was not found.")
        XCTAssertEqual(circle.radius, 3.0, accuracy: 1e-6)
        XCTAssertEqual(circle.diameter, 6.0, accuracy: 1e-6)

        let expected = 80.0 * 50.0 * 10.0 - Double.pi * 3.0 * 3.0 * 10.0
        XCTAssertEqual(
            state.bodyVolumeMM3,
            expected,
            accuracy: 1.0,
            "The Ø6 through-hole volume is not the actual 80×50×10 plate minus the hole."
        )
        XCTAssertNil(state.fillet, "The first turn must not create the turn-two fillet.")
        XCTAssertGreaterThan(state.revision, 0)
        XCTAssertEqual(state.contentSHA256.count, 64)
    }

    private func assertEditedGeometry(
        _ state: NativeCADLiveDocumentState,
        initial: NativeCADLiveDocumentState
    ) throws {
        XCTAssertEqual(state.bodyCount, 1, "The hole edit/fillet must keep one body.")
        XCTAssertEqual(state.bodyID, initial.bodyID, "Editing the existing hole must keep the SAME body identity.")
        XCTAssertTrue(state.bodyIsAnalytic, "The edited body must remain an analytic B-rep.")
        XCTAssertEqual(state.circles.count, 1)
        let circle = try XCTUnwrap(state.circles.first)
        let initialCircle = try XCTUnwrap(initial.circles.first)
        XCTAssertEqual(circle.sketchID, initialCircle.sketchID, "The hole edit must reuse the SAME hole sketch.")
        XCTAssertEqual(circle.entityID, initialCircle.entityID, "The hole edit must reuse the SAME circle entity.")
        XCTAssertEqual(circle.radius, 4.0, accuracy: 1e-6, "The existing hole must be exactly Ø8 (radius 4 mm).")
        XCTAssertEqual(circle.diameter, 8.0, accuracy: 1e-6)

        let fillet = try XCTUnwrap(state.fillet, "No real fillet feature was found after the edit turn.")
        XCTAssertEqual(fillet.radius, 2.0, accuracy: 1e-6, "The fillet radius must be exactly 2 mm.")
        XCTAssertTrue((1...4).contains(fillet.edgeCount), "The synthetic flow requests 1...4 vertical corner edges, got \(fillet.edgeCount).")
        XCTAssertTrue(
            state.cylindricalRadii.contains { abs($0 - 4.0) < 1e-4 },
            "Query kind=faces must report the rebuilt Ø8 cylindrical hole; found \(state.cylindricalRadii)."
        )

        let expected = 80.0 * 50.0 * 10.0
            - Double.pi * 4.0 * 4.0 * 10.0
            - Double(fillet.edgeCount) * 10.0 * (4.0 - Double.pi)
        XCTAssertEqual(
            state.bodyVolumeMM3,
            expected,
            accuracy: 2.0,
            "The actual volume must match the Ø8 hole plus the reported \(fillet.edgeCount) corner fillet(s)."
        )
        XCTAssertGreaterThan(state.revision, initial.revision, "The edit turn must commit a newer package revision.")
        XCTAssertNotEqual(state.contentSHA256, initial.contentSHA256, "The edit turn must change the verified package content.")
        if let initialModelSHA = initial.modelSHA256, let editedModelSHA = state.modelSHA256 {
            XCTAssertNotEqual(
                editedModelSHA,
                initialModelSHA,
                "The edit turn must change the canonical CAD model identity."
            )
        } else {
            XCTFail("The verified package did not expose its additive modelSHA256 identity.")
        }
    }

    private func assertFinalGeometry(
        _ state: NativeCADLiveDocumentState,
        edited: NativeCADLiveDocumentState
    ) throws {
        XCTAssertEqual(state.bodyID, edited.bodyID)
        XCTAssertEqual(state.bodyCount, 1)
        let circle = try XCTUnwrap(state.circles.first)
        let editedCircle = try XCTUnwrap(edited.circles.first)
        XCTAssertEqual(circle.sketchID, editedCircle.sketchID)
        XCTAssertEqual(circle.entityID, editedCircle.entityID)
        XCTAssertEqual(circle.diameter, 8.0, accuracy: 1e-6)
        let fillet = try XCTUnwrap(state.fillet)
        let editedFillet = try XCTUnwrap(edited.fillet)
        XCTAssertEqual(fillet.radius, 2.0, accuracy: 1e-6)
        XCTAssertEqual(fillet.edgeCount, editedFillet.edgeCount)
        XCTAssertGreaterThanOrEqual(state.revision, edited.revision)
        XCTAssertEqual(state.contentSHA256.count, 64)
        // A clean save legitimately refreshes the manifest timestamp (and thus
        // contentSHA256); the canonical model identity must NOT move. The final
        // turn is a readback/capture/save, not a geometry edit.
        if let editedModelSHA = edited.modelSHA256, let finalModelSHA = state.modelSHA256 {
            XCTAssertEqual(
                finalModelSHA,
                editedModelSHA,
                "The final readback/capture/save turn silently changed the CAD model identity."
            )
        } else {
            XCTFail("The verified package did not expose its additive modelSHA256 identity.")
        }
    }

    // MARK: Capture evidence

    private func validateCapture(
        events: [RunEventRecord],
        runID: UUID,
        minimumRevision: Int
    ) throws -> Data {
        for event in events where event.kind == .toolResult {
            guard let payload = NativeCADLiveJSON.object(event.payloadJSON),
                  (payload["tool"] as? String) == CadDocumentTool.name,
                  (payload["status"] as? String) == "ok",
                  let summary = payload["summary"] as? String else { continue }
            for object in NativeCADLiveJSON.objects(in: summary) {
                guard (object["action"] as? String) == "capture",
                      (object["ok"] as? Bool) != false,
                      let relative = object["artifact"] as? String,
                      let imageSHA = object["image_sha256"] as? String,
                      let contentSHA = object["content_sha256"] as? String,
                      let width = NativeCADLiveJSON.int(object["width"]),
                      let height = NativeCADLiveJSON.int(object["height"]),
                      let byteCount = NativeCADLiveJSON.int(object["byte_count"]),
                      let renderer = object["renderer"] as? String else { continue }

                guard width == 1024, height == 768 else {
                    throw NativeCADLiveError.invalidCapture("Expected a 1024×768 engineering PNG, got \(width)×\(height).")
                }
                guard renderer == "engineering" else {
                    throw NativeCADLiveError.invalidCapture("Expected the engineering viewport renderer, got \(renderer).")
                }
                guard contentSHA.count == 64 else {
                    throw NativeCADLiveError.invalidCapture("The capture does not carry a 64-character document content identity.")
                }
                if let revision = NativeCADLiveJSON.int(object["revision"]) {
                    XCTAssertGreaterThanOrEqual(
                        revision,
                        minimumRevision,
                        "The screenshot revision predates the verified Ø8/fillet package."
                    )
                } else {
                    XCTFail("The successful capture receipt did not report a document revision.")
                }

                let url = try NativeCADLivePaths.captureArtifactURL(relativePath: relative)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw NativeCADLiveError.invalidCapture("The reported capture artifact does not exist at \(relative).")
                }
                let png = try Data(contentsOf: url)
                guard png.count == byteCount else {
                    throw NativeCADLiveError.invalidCapture("The capture file byte count \(png.count) differs from the tool receipt \(byteCount).")
                }
                guard FloeDigest.sha256Hex(png) == imageSHA else {
                    throw NativeCADLiveError.invalidCapture("The capture file SHA-256 does not match the tool receipt.")
                }
                guard url.lastPathComponent == "\(imageSHA).png" else {
                    throw NativeCADLiveError.invalidCapture("The artifact file name is not the image digest.")
                }
                let pngMagic = Array(png.prefix(8))
                guard pngMagic == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else {
                    throw NativeCADLiveError.invalidCapture("The artifact does not begin with the PNG signature.")
                }

                if let artifactRefsJSON = payload["artifactRefsJSON"] as? String,
                   let refsData = artifactRefsJSON.data(using: .utf8),
                   let refs = (try? JSONSerialization.jsonObject(with: refsData)) as? [[String: Any]] {
                    let matching = refs.first {
                        ($0["relativePath"] as? String) == relative
                    }
                    XCTAssertNotNil(matching, "The persisted tool result does not carry the capture artifact reference.")
                    XCTAssertTrue((matching?["sha256"] as? String) == imageSHA)
                    XCTAssertEqual(NativeCADLiveJSON.int(matching?["byteCount"]) ?? -1, png.count)
                } else {
                    XCTFail("The successful capture tool result did not persist its artifact reference.")
                }

                let stats = try NativeCADLivePixels.stats(png)
                XCTAssertEqual(stats.width, 1024)
                XCTAssertEqual(stats.height, 768)
                XCTAssertGreaterThan(stats.uniqueColorBuckets, 16, "The capture is effectively blank/flat.")
                XCTAssertGreaterThan(stats.nonBackgroundFraction, 0.005, "The capture contains no visible rendered body.")

                captureRelativePaths.append(relative)
                XCTAssertTrue(runIDs.last == runID, "The capture must come from the final owned run.")
                return png
            }
        }
        throw NativeCADLiveError.missingCapture
    }

    private func attach(_ png: Data) {
        let attachment = XCTAttachment(data: png)
        attachment.name = "native-cad-live-viewport.png"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Native CAD live viewport") { activity in
            activity.add(attachment)
        }
    }

    private func attachUsage(_ totals: NativeCADLiveTotals) {
        let attachment = XCTAttachment(string: totals.description)
        attachment.name = "native-cad-live-usage.txt"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Native CAD live model usage") { activity in
            activity.add(attachment)
        }
    }

    // MARK: Durable failure evidence, attached before owned cleanup deletes it

    func recordFailure(_ error: Error) {
        if failureDescription == nil {
            failureDescription = String(describing: error)
        }
    }

    /// Reads the exact durable usage and tool lifecycle rows for every owned
    /// run and attaches a bounded, prompt-free text copy. Cleanup deletes the
    /// conversation/run rows, so this must run first on every exit path.
    private func attachDurableEvidence() async {
        let runStore = environment.runStore
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("native-cad-live durable evidence")
        lines.append("source=run_usage and run_events read before owned cleanup")
        lines.append("captured_at=\(formatter.string(from: Date()))")
        if let failureDescription {
            lines.append("failure=\(evidenceText(failureDescription))")
        } else {
            lines.append("failure=none observed on the success path")
        }
        let totals = await ledger.totals()
        lines.append("ledger_totals=\(totals.description)")
        lines.append("ledger_reported_total_tokens=\(totals.reportedTotalTokens)")
        lines.append("ledger_cache_read_tokens=\(totals.cacheReadTokens)")
        lines.append("ledger_has_usage=\(totals.hasUsage)")
        lines.append("run_count=\(runIDs.count)")

        for (index, runID) in runIDs.enumerated() {
            lines.append("")
            lines.append("run[\(index)] \(runID.uuidString)")
            let usageRows = try? await runStore.usage(runID: runID)
            let usage = usageRows ?? []
            lines.append("usage_records=\(usage.count)")
            for (offset, record) in usage.enumerated() {
                lines.append(
                    "  usage[\(offset)] input_tokens=\(record.inputTokens)"
                        + " output_tokens=\(record.outputTokens)"
                        + " cache_read_tokens=\(intText(record.cacheReadTokens))"
                        + " cache_miss_tokens=\(intText(record.cacheMissTokens))"
                        + " cache_write_tokens=\(intText(record.cacheWriteTokens))"
                        + " reasoning_tokens=\(intText(record.reasoningTokens))"
                        + " estimated=\(record.isEstimated)"
                        + " total_duration_ms=\(intText(record.totalDurationMs))"
                        + " time_to_first_token_ms=\(intText(record.timeToFirstTokenMs))"
                        + " tokens_per_second=\(doubleText(record.tokensPerSecond))"
                        + " cost_estimate=\(record.costEstimate ?? "nil")"
                        + " recorded_at=\(formatter.string(from: record.recordedAt))"
                )
            }
            if let usageRows {
                if usageRows.isEmpty {
                    lines.append("  exact_usage_unavailable=no durable run_usage row existed before cleanup")
                }
            } else {
                lines.append("  exact_usage_unavailable=run_usage could not be read before cleanup")
            }

            let eventRows = try? await runStore.events(runID: runID)
            let events = eventRows ?? []
            lines.append("events=\(events.count)")
            if eventRows == nil {
                lines.append("  tool_evidence_unavailable=run_events could not be read before cleanup")
            }
            for event in events {
                switch event.kind {
                case .toolRequest, .toolResult:
                    if let line = toolEvidenceLine(event: event) {
                        lines.append(line)
                    }
                case .error:
                    if let payload = NativeCADLiveJSON.object(event.payloadJSON) {
                        var parts = ["kind=error", "sequence=\(event.sequence)"]
                        for key in ["kind", "message", "httpStatus", "recoverable"] {
                            if let value = payload[key] as? String, !value.isEmpty {
                                parts.append("\(key)=\(evidenceText(value))")
                            }
                        }
                        lines.append("  " + parts.joined(separator: " "))
                    }
                default:
                    break
                }
            }
        }

        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "native-cad-live-durable-evidence.txt"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Native CAD live durable run evidence") { activity in
            activity.add(attachment)
        }
    }

    private func toolEvidenceLine(event: RunEventRecord) -> String? {
        guard let payload = NativeCADLiveJSON.object(event.payloadJSON) else {
            return "  kind=\(event.kind.rawValue) sequence=\(event.sequence) unreadable_payload"
        }
        var parts = [
            "kind=\(event.kind.rawValue)",
            "sequence=\(event.sequence)",
        ]
        if let id = payload["id"] as? String { parts.append("call_id=\(id)") }
        if let tool = payload["tool"] as? String { parts.append("tool=\(tool)") }
        if let status = payload["status"] as? String { parts.append("status=\(status)") }
        if event.kind == .toolRequest,
           let input = payload["input"] as? String,
           let arguments = NativeCADLiveJSON.object(input) {
            if let action = arguments["action"] as? String { parts.append("action=\(action)") }
            if let op = arguments["op"] as? String { parts.append("op=\(op)") }
            if let path = arguments["path"] as? String {
                parts.append("path=\((path as NSString).lastPathComponent)")
            }
            if let summary = arguments["summary"] as? String {
                parts.append("request_summary=\(evidenceText(summary))")
            }
        }
        if let summary = payload["summary"] as? String {
            parts.append("summary=\(evidenceText(summary))")
        }
        if let digest = payload["outputDigest"] as? String, !digest.isEmpty {
            parts.append("output_digest=\(digest)")
        }
        for key in ["durationMs", "queuedMs"] {
            if let value = payload[key] as? String { parts.append("\(key)=\(value)") }
            else if let value = payload[key] as? Int { parts.append("\(key)=\(value)") }
        }
        for key in ["error", "errorCode"] {
            if let value = payload[key] as? String, !value.isEmpty {
                parts.append("\(key)=\(evidenceText(value))")
            }
        }
        return "  " + parts.joined(separator: " ")
    }

    private func intText(_ value: Int?) -> String {
        value.map { String($0) } ?? "nil"
    }

    private func doubleText(_ value: Double?) -> String {
        value.map { String($0) } ?? "nil"
    }

    private func evidenceText(_ value: String, limit: Int = 6_000) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: "\\n")
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit)) + "…[truncated]"
    }

    // MARK: Small query helpers

    private func nativeRows(_ document: FloeCADDocument, scope: String) throws -> [[String: Any]] {
        let outcome = document.nativeQueryJSON(["scope": scope])
        guard outcome.isOK,
              let object = NativeCADLiveJSON.object(outcome.payload),
              let rows = object["rows"] as? [[String: Any]] else {
            throw NativeCADLiveError.invalidDocument(
                "query \(scope) failed: \(outcome.errorCode ?? "unknown") \(outcome.message ?? "")"
            )
        }
        return rows
    }

    private func measureVolume(_ document: FloeCADDocument, bodyID: String) throws -> Double {
        let outcome = document.measureJSON(["kind": "body", "bodyID": bodyID])
        guard outcome.isOK,
              let object = NativeCADLiveJSON.object(outcome.payload),
              let volume = NativeCADLiveJSON.number(object["volumeMM3"]) else {
            throw NativeCADLiveError.invalidDocument(
                "measure body failed: \(outcome.errorCode ?? "unknown") \(outcome.message ?? "")"
            )
        }
        return volume
    }

    // MARK: Prompts

    private func turnOneGoal() -> String {
        """
        Use the cad.document tool to create a real native CAD document named "\(documentName)".
        Work in the current task workspace; do not write package files by hand.

        Build a 80 mm x 50 mm x 10 mm plate:
        - sketch.create for the plate profile;
        - sketch.addEntities with a rect from [0,0] to [80,50];
        - feature.extrude with seedPoint [40,25] and distance 10.
        Then cut a Ø6 through-hole at the center:
        - query kind=bodies to get the plate body id;
        - sketch.create for the hole;
        - sketch.addEntities with a circle centered at [40,25] and radius 3;
        - feature.extrude with seedPoint [40,25], distance 40, symmetric true,
          boolean "subtract", and booleanTargets [<plate body id>].

        Apply every proposal you draft (omit grant_id; the runtime authorizes the
        exact approved call), save the document, and query kind=bodies and
        kind=sketches to confirm one body and the Ø6 circle. Do not only describe
        the steps: call the tool and verify the result. Do not add any other
        tool calls.
        """
    }

    private func turnTwoGoal(documentPath: String) -> String {
        """
        Open the same native CAD document "\(documentPath)" and EDIT the existing
        Ø6 hole; do not add a new hole and do not rebuild the plate.

        1. query kind=sketches, find the existing non-construction circle in the
           hole sketch, and keep its sketch id and stable entity id.
        2. Change that SAME circle's radius from 3 to exactly 4 mm with
           cad.document action "parameters", payload JSON:
           {"action":"updateSketchEntity","sketch_id":"<id>","entity_id":"<id>",
            "radius":4,"expected_radius":3}
        3. query kind=bodies and kind=edges. Choose the vertical corner edge(s)
           of the 10 mm plate (their edge midpoints are near (0,5,0), (80,5,0),
           (0,5,-50), (80,5,-50)). Propose feature.fillet with bodyID, radius 2,
           the chosen edge indices, and the current query_token. Apply it
           (omit grant_id), then save.
        4. Query kind=features and kind=sketches again and read back the actual
           hole diameter and fillet radius/edge count.

        Apply every proposal you draft and do not add any other tool calls.
        """
    }

    private func turnThreeGoal(documentPath: String) -> String {
        """
        Open the same native CAD document "\(documentPath)". Read back the actual
        state, do not change geometry:
        - query kind=sketches and confirm the existing hole circle diameter is 8 mm;
        - query kind=features and confirm the fillet radius is 2 mm and read its edge count;
        - query kind=bodies and measure the body (handles ["body:<body id>"]).
        Then capture a real engineering viewport PNG with
        cad.document action "capture", width 1024, height 768, and save the
        document. Report only the revision, volume, hole diameter and fillet
        edge count that the tool replies actually returned. Do not add any other
        tool calls.
        """
    }

    // MARK: Owned cleanup

    func cleanup() async {
        guard !cleanupStarted else { return }
        cleanupStarted = true

        for service in services {
            await service.cancel()
        }

        // The owning conversation and its runs/usage/events are deleted below.
        // Attach the exact durable evidence first on every exit path.
        await attachDurableEvidence()

        if let documentURL {
            for proposal in await environment.cadDocumentCenter.pendingNativeProposals(for: documentURL) {
                try? await environment.cadDocumentCenter.removeProposal(id: proposal.id)
            }
            await FloeCAD3DBridge.shared.releaseDocument(at: documentURL)
        }

        for runID in runIDs {
            await environment.contentUpdateCenter.releaseRunSnapshot(runID)
            NativeCADLivePaths.removeOwnedDirectory(
                NativeCADLivePaths.captureArtifactDirectory(runID: runID)
            )
            NativeCADLivePaths.removeOwnedDirectory(
                NativeCADLivePaths.skillRunSnapshotDirectory(runID: runID)
            )
        }
        for relative in captureRelativePaths {
            if let url = try? NativeCADLivePaths.captureArtifactURL(relativePath: relative) {
                NativeCADLivePaths.removeOwnedFile(url)
            }
        }

        do {
            try await center.deleteConversation(id: conversationID)
        } catch {
            XCTFail("Owned task cleanup failed: \(error.localizedDescription)")
        }

        for container in await environment.environmentRegistry.containersOwned(by: conversationID.uuidString) {
            try? await environment.environmentRegistry.remove(id: container.id)
        }

        if let workspaceRoot {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: workspaceRoot.path),
                "The owned private task workspace still exists after deletion: \(workspaceRoot.path)"
            )
        }
    }
}

// MARK: - Document state and evidence helpers

private struct NativeCADLiveCircle {
    var sketchID: String
    var entityID: String
    var radius: Double
    var diameter: Double
}

private struct NativeCADLiveFillet {
    var id: String
    var radius: Double
    var edgeCount: Int
}

private struct NativeCADLiveDocumentState {
    var revision: Int
    var contentSHA256: String
    var modelSHA256: String?
    var bodyCount: Int
    var sketchCount: Int
    var featureCount: Int
    var bodyID: String
    var bodyIsAnalytic: Bool
    var bodyVolumeMM3: Double
    var circles: [NativeCADLiveCircle]
    var fillet: NativeCADLiveFillet?
    var cylindricalRadii: [Double]
}

private enum NativeCADLiveEvidence {
    static func assertToolSurface(
        events: [RunEventRecord],
        documentName: String,
        turn: Int
    ) throws {
        var requests = 0
        var successfulResults = 0
        for event in events {
            switch event.kind {
            case .approval:
                XCTFail("Turn \(turn) produced an interactive approval event; the owned automatic policy should not ask.")
            case .toolRequest:
                guard let payload = NativeCADLiveJSON.object(event.payloadJSON),
                      let tool = payload["tool"] as? String else {
                    XCTFail("Turn \(turn) produced an unreadable tool request.")
                    continue
                }
                XCTAssertEqual(tool, CadDocumentTool.name, "Turn \(turn) called a tool outside the CAD-only ceiling.")
                requests += 1
                guard let input = payload["input"] as? String,
                      let arguments = NativeCADLiveJSON.object(input) else {
                    XCTFail("Turn \(turn) CAD request had no readable arguments.")
                    continue
                }
                if let path = arguments["path"] as? String {
                    XCTAssertEqual(
                        (path as NSString).lastPathComponent,
                        documentName,
                        "Turn \(turn) addressed a different native CAD document."
                    )
                    XCTAssertFalse(path.contains(".."), "Turn \(turn) used a traversal path.")
                }
                if (arguments["action"] as? String) == "apply" {
                    let grant = (arguments["grant_id"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    XCTAssertTrue(
                        grant.isEmpty,
                        "The model supplied a grant_id; this acceptance must exercise runtime authority, not a fabricated grant."
                    )
                }
            case .toolResult:
                guard let payload = NativeCADLiveJSON.object(event.payloadJSON),
                      let tool = payload["tool"] as? String else {
                    XCTFail("Turn \(turn) produced an unreadable tool result.")
                    continue
                }
                XCTAssertEqual(tool, CadDocumentTool.name)
                let status = payload["status"] as? String
                XCTAssertFalse(status == "needsUser", "Turn \(turn) stopped for user input.")
                if status == "ok" { successfulResults += 1 }
            default:
                break
            }
        }
        XCTAssertGreaterThan(requests, 0, "Turn \(turn) did not call the native CAD tool.")
        XCTAssertGreaterThan(successfulResults, 0, "Turn \(turn) had no successful native CAD tool result.")
    }

    static func assertTurnOneEvidence(_ events: [RunEventRecord]) throws {
        let all = requests(events)
        XCTAssertTrue(
            all.contains { ($0["action"] as? String) == "create" },
            "The first turn did not call cad.document create."
        )
        XCTAssertTrue(
            all.contains { ($0["op"] as? String) == "sketch.create" },
            "The first turn did not draft the plate sketch."
        )
        XCTAssertTrue(
            all.contains { ($0["op"] as? String) == "feature.extrude" },
            "The first turn did not draft the extrusion/hole geometry."
        )
    }

    static func assertTurnTwoEvidence(_ events: [RunEventRecord]) throws {
        let all = requests(events)
        let editedExistingHole = all.contains { arguments in
            if let payloadString = arguments["payload"] as? String,
               let payload = NativeCADLiveJSON.object(payloadString),
               let payloadAction = payload["action"] as? String,
               ["updateSketchEntity", "setSketchDimension"].contains(payloadAction) {
                return true
            }
            return false
        }
        let proposedFillet = all.contains { arguments in
            (arguments["op"] as? String) == "feature.fillet"
        }
        XCTAssertTrue(
            editedExistingHole || proposedFillet,
            "The edit turn did not exercise an existing-hole parameter or fillet proposal route."
        )
        XCTAssertTrue(proposedFillet, "The edit turn did not propose feature.fillet.")
    }

    static func assertTurnThreeEvidence(_ events: [RunEventRecord]) throws {
        let all = requests(events)
        let readActions: Set<String> = ["query", "three_d_snapshot", "three_d_measure", "measure"]
        XCTAssertTrue(
            all.contains { action in
                guard let action = action["action"] as? String else { return false }
                return readActions.contains(action)
            },
            "The final turn did not read actual parameters/geometry."
        )
        XCTAssertTrue(
            all.contains { ($0["action"] as? String) == "capture" },
            "The final turn did not request a real viewport capture."
        )
        XCTAssertTrue(
            all.contains { ($0["action"] as? String) == "save" },
            "The final turn did not call cad.document save."
        )
        XCTAssertTrue(
            successfulSaveReceipt(events),
            "No successful cad.document save receipt was persisted for the explicit save call."
        )
    }

    private static func successfulSaveReceipt(_ events: [RunEventRecord]) -> Bool {
        var saveCallIDs = Set<String>()
        for event in events where event.kind == .toolRequest {
            guard let payload = NativeCADLiveJSON.object(event.payloadJSON),
                  (payload["tool"] as? String) == CadDocumentTool.name,
                  let callID = payload["id"] as? String,
                  let input = payload["input"] as? String,
                  let arguments = NativeCADLiveJSON.object(input),
                  (arguments["action"] as? String) == "save" else { continue }
            saveCallIDs.insert(callID)
        }
        guard !saveCallIDs.isEmpty else { return false }
        for event in events where event.kind == .toolResult {
            guard let payload = NativeCADLiveJSON.object(event.payloadJSON),
                  (payload["tool"] as? String) == CadDocumentTool.name,
                  let callID = payload["id"] as? String,
                  saveCallIDs.contains(callID),
                  (payload["status"] as? String) == "ok",
                  let summary = payload["summary"] as? String else { continue }
            if NativeCADLiveJSON.objects(in: summary).contains(where: {
                $0["revision"] != nil && ($0["ok"] as? Bool) != false
            }) {
                return true
            }
        }
        return false
    }

    private static func requests(_ events: [RunEventRecord]) -> [[String: Any]] {
        events.compactMap { event in
            guard event.kind == .toolRequest,
                  let payload = NativeCADLiveJSON.object(event.payloadJSON),
                  (payload["tool"] as? String) == CadDocumentTool.name,
                  let input = payload["input"] as? String else { return nil }
            return NativeCADLiveJSON.object(input)
        }
    }
}

// MARK: - JSON / path / pixel helpers

private enum NativeCADLiveJSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func object(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return object(data)
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? NSNumber, value.doubleValue.isFinite { return value.doubleValue }
        if let value = value as? Int { return Double(value) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Double, value.isFinite { return Int(value) }
        return nil
    }

    /// Balanced JSON objects embedded in a model/tool text projection. The
    /// runtime may prepend a provenance envelope, so callers search the
    /// objects rather than assuming the first one is the tool reply.
    static func objects(in text: String) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var searchStart = text.startIndex
        while let start = text[searchStart...].firstIndex(of: "{") {
            var depth = 0
            var inString = false
            var escaped = false
            var index = start
            var end: String.Index?
            while index < text.endIndex {
                let character = text[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inString = false
                    }
                } else {
                    if character == "\"" {
                        inString = true
                    } else if character == "{" {
                        depth += 1
                    } else if character == "}" {
                        depth -= 1
                        if depth == 0 {
                            end = index
                            break
                        }
                    }
                }
                index = text.index(after: index)
            }
            guard let end else { break }
            if let object = object(String(text[start...end])) {
                result.append(object)
            }
            searchStart = text.index(after: end)
        }
        return result
    }
}

private enum NativeCADLivePaths {
    static func applicationSupport() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
    }

    static func workspaceRoot(
        for workspace: WorkspaceRecord,
        conversationID: UUID
    ) throws -> URL {
        let relative = workspace.internalRelativePath ?? "PrivateTasks/\(conversationID.uuidString)"
        return try applicationSupport()
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relative, isDirectory: true)
    }

    static func captureArtifactURL(relativePath: String) throws -> URL {
        guard relativePath.hasPrefix("CADViewportArtifacts/"),
              !relativePath.split(separator: "/").contains(where: { String($0) == ".." }) else {
            throw NativeCADLiveError.invalidCapture("The artifact path is outside the App-owned CAD capture root.")
        }
        return try applicationSupport()
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
    }

    static func captureArtifactDirectory(runID: UUID) -> URL? {
        guard let support = try? applicationSupport() else { return nil }
        return support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("CADViewportArtifacts", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    static func skillRunSnapshotDirectory(runID: UUID) -> URL? {
        guard let support = try? applicationSupport() else { return nil }
        return support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("Skills", isDirectory: true)
            .appendingPathComponent(".run-snapshots", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    static func removeOwnedDirectory(_ url: URL?) {
        guard let url else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func removeOwnedFile(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return }
        try? FileManager.default.removeItem(at: url)
    }
}

private enum NativeCADLivePixels {
    struct Stats {
        var width: Int
        var height: Int
        var uniqueColorBuckets: Int
        var nonBackgroundFraction: Double
    }

    static func stats(_ png: Data) throws -> Stats {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NativeCADLiveError.invalidCapture("The artifact is not a decodable image.")
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width * height <= 16_000_000 else {
            throw NativeCADLiveError.invalidCapture("The capture image dimensions are invalid.")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else {
            throw NativeCADLiveError.invalidCapture("The capture image could not be rasterized.")
        }

        func pixel(_ x: Int, _ y: Int) -> UInt32 {
            let offset = (y * width + x) * 4
            let r = UInt32(pixels[offset])
            let g = UInt32(pixels[offset + 1])
            let b = UInt32(pixels[offset + 2])
            return (r << 16) | (g << 8) | b
        }

        let background = pixel(0, 0)
        var buckets = Set<UInt32>()
        var samples = 0
        var nonBackground = 0
        let stepX = max(1, width / 128)
        let stepY = max(1, height / 96)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let color = pixel(x, y)
                let quantized = (((color >> 19) & 0x1F) << 10) | (((color >> 11) & 0x1F) << 5) | ((color >> 3) & 0x1F)
                buckets.insert(quantized)
                if color != background { nonBackground += 1 }
                samples += 1
                x += stepX
            }
            y += stepY
        }
        guard samples > 0 else {
            throw NativeCADLiveError.invalidCapture("The capture image produced no pixel samples.")
        }
        return Stats(
            width: width,
            height: height,
            uniqueColorBuckets: buckets.count,
            nonBackgroundFraction: Double(nonBackground) / Double(samples)
        )
    }
}

// MARK: - Real App context-compaction acceptance (test-only, no production path)

/// Four ACTUAL ordinary user messages go through the normal
/// `RunLaunchStore` + `ConversationRunService` path with the exact 65,536-token
/// model window already written by the private owned-route metadata. Three
/// bounded synthetic data messages make the App's own `HybridContextEngine`
/// compact naturally; the final follow-up must recall the early exact facts
/// from the durable continuation record and then use a real workspace read.
/// The read is small enough to arrive complete; a separate `tools.readResult`
/// call verifies the exact indexed capture. This test does not claim that
/// truncation/compaction was necessary for that tool output.
@MainActor
final class NativeCADContextCompactionLiveTests: XCTestCase {

    func testRealModelCompactsAt64KContextAndRetainsEarlyFactsThenReadsExactCapture() async throws {
        let optIn = try NativeCADLiveOptIn.load()
        executionTimeAllowance = optIn.executionTimeAllowance
        continueAfterFailure = true

        let environment = try await appQualificationEnvironment()
        let center = environment.conversationCenter
        let installed = try await NativeCADLiveOwnedRoute.installIfRequested(environment: environment)
        do {
            let route = try await NativeCADLiveRoute.select(optIn: optIn, center: center)
            guard optIn.prepaidBudgetBasis,
                  NativeCADLivePrepaidRoute.matches(provider: route.provider, model: route.model) else {
                throw XCTSkip(
                    "Context-compaction acceptance skipped: it requires the reviewed exact "
                        + "prepaid Agent Plan route and both explicit zero increments; no "
                        + "paid fallback is used here. A skip is not live evidence."
                )
            }
            guard route.model.limits.contextTokens == 65_536 else {
                XCTFail(
                    "The owned route must configure the actual model context at exactly "
                        + "65,536 tokens for this acceptance; found "
                        + "\(route.model.limits.contextTokens)."
                )
                throw NativeCADLiveError.invalidContextWindow(route.model.limits.contextTokens)
            }
            let session = NativeCADContextCompactionSession(
                environment: environment, center: center, route: route, optIn: optIn)
            do {
                try await session.run()
            } catch {
                session.recordFailure(error)
                await session.cleanup()
                throw error
            }
            await session.cleanup()
        } catch {
            try await installed?.remove(environment: environment)
            throw error
        }
        try await installed?.remove(environment: environment)
    }
}

private struct NativeCADLiveCompactionRow: Sendable {
    var id: UUID
    var sourceMessageIDs: [UUID]
    var summary: String
    var beforeTokens: Int
    var afterTokens: Int
}

private struct NativeCADLiveToolCall {
    var callID: String
    var tool: String
    var arguments: [String: Any]
    var requestSequence: Int
}

private struct NativeCADLiveToolResult {
    var callID: String
    var tool: String
    var status: String
    var summary: String
    var sequence: Int
}

@MainActor
private final class NativeCADContextCompactionSession {
    private let environment: AppEnvironment
    private let center: ConversationCenter
    private let route: NativeCADLiveRoute
    private let optIn: NativeCADLiveOptIn
    private let ledger: NativeCADLiveLedger

    private let conversationID = UUID()
    private let title: String
    private let fileRelativePath: String
    private let searchToken: String
    private let hiddenToken: String
    private let expectedPage: String
    private let alphaFact: String
    private let alphaInstruction: String
    private let betaFact: String
    private let latestCode: String

    private var workspace: WorkspaceRecord?
    private var workspaceRootURL: URL?
    private var runIDs: [UUID] = []
    private var userMessageIDs: [UUID] = []
    private var userGoals: [String] = []
    private var services: [ConversationRunService] = []
    private var cleanupStarted = false
    private var conversationCreated = false
    private var bridgeFinalMessageID: UUID?
    private var failureDescription: String?

    init(
        environment: AppEnvironment,
        center: ConversationCenter,
        route: NativeCADLiveRoute,
        optIn: NativeCADLiveOptIn
    ) {
        let token = UUID().uuidString.lowercased()
        self.environment = environment
        self.center = center
        self.route = route
        self.optIn = optIn
        self.ledger = NativeCADLiveLedger(
            pricing: route.pricing,
            maxCost: optIn.maxCost,
            maxInputTokens: optIn.maxInputTokens,
            maxOutputTokens: optIn.maxOutputTokens,
            maxTotalTokens: optIn.maxTotalTokens
        )
        let search = "COMPACTION-SEARCH-\(token)"
        let hidden = "PAGED-HIDDEN-\(token.uppercased())"
        var block = "\(search)|\(hidden)|"
        if block.utf8.count < 160 {
            block += String(repeating: "X", count: 160 - block.utf8.count)
        }
        self.title = "Context compaction live acceptance \(String(token.prefix(6)))"
        self.fileRelativePath = "compaction-acceptance-\(String(token.prefix(8))).txt"
        self.searchToken = search
        self.hiddenToken = hidden
        self.expectedPage = String(block.prefix(160))
        self.alphaFact = "EARLY-FACT-ALPHA-\(token)"
        self.alphaInstruction = "EARLY-INSTRUCTION-\(token)"
        self.betaFact = "EARLY-FACT-BETA-\(token)"
        self.latestCode = "LATEST-GOAL-\(token)"
    }

    func run() async throws {
        try await createOwnedConversation()
        try await createFixtureFile()

        // The first two user messages are actual durable user rows. Their
        // synthetic blocks are bounded test data, not a substitute history.
        let first = try await turn(goal: firstTurnGoal(), allowedTools: [], label: "turn1")
        try await assertAcknowledged(
            runID: first.runID,
            events: first.events,
            required: ["ACK-ALPHA"],
            label: "turn1"
        )

        let second = try await turn(goal: secondTurnGoal(), allowedTools: [], label: "turn2")
        let secondCompactions = try await compactionRows(runID: second.runID)
        XCTAssertFalse(
            secondCompactions.isEmpty,
            "The second actual user message did not trigger the App's natural context compaction at the configured 65,536-token window."
        )
        if let row = secondCompactions.first {
            XCTAssertTrue(
                row.sourceMessageIDs.contains(userMessageIDs[0]),
                "The first actual user message was not a durable compaction source."
            )
            XCTAssertFalse(
                row.sourceMessageIDs.contains(userMessageIDs[1]),
                "The latest actual user message must stay protected, not be compacted."
            )
            XCTAssertTrue(
                row.summary.contains(alphaFact),
                "The App semantic continuation record did not retain the exact early alpha fact."
            )
            XCTAssertGreaterThan(row.beforeTokens, row.afterTokens)
        }
        try await assertAcknowledged(
            runID: second.runID,
            events: second.events,
            required: [alphaFact, betaFact],
            label: "turn2"
        )

        // A fourth actual user message keeps the recent protected tail free
        // of the exact early facts. The next compaction must therefore carry
        // them in the durable continuation record, not in a retained reply.
        let bridge = try await turn(goal: bridgeGoal(), allowedTools: [], label: "bridge")
        try await assertAcknowledged(
            runID: bridge.runID,
            events: bridge.events,
            required: ["ACK-BRIDGE"],
            label: "bridge"
        )
        bridgeFinalMessageID = finalMessageID(events: bridge.events)
        XCTAssertNotNil(bridgeFinalMessageID, "The bridge turn has no durable final assistant message ID.")
        let bridgeText = try await finalAssistantText(runID: bridge.runID, events: bridge.events)
        XCTAssertFalse(
            bridgeText.contains(alphaFact)
                || bridgeText.contains(betaFact)
                || bridgeText.contains(alphaInstruction),
            "The bridge answer repeated early facts; the recent-tail retention proof would be ambiguous."
        )

        let third = try await turn(
            goal: followUpGoal(),
            allowedTools: ["workspace.readFile"],
            label: "turn3"
        )
        let thirdCompactions = try await compactionRows(runID: third.runID)
        XCTAssertFalse(
            thirdCompactions.isEmpty,
            "The follow-up run did not perform App-orchestrated compaction before its real provider request."
        )
        if let row = thirdCompactions.first {
            XCTAssertTrue(row.sourceMessageIDs.contains(userMessageIDs[0]))
            XCTAssertTrue(row.sourceMessageIDs.contains(userMessageIDs[1]))
            XCTAssertFalse(row.sourceMessageIDs.contains(userMessageIDs[3]))
            XCTAssertTrue(row.summary.contains(alphaFact), "The continuation record lost the early alpha fact.")
            XCTAssertTrue(row.summary.contains(betaFact), "The continuation record lost the early beta fact.")
            XCTAssertTrue(
                row.summary.contains(alphaInstruction),
                "The continuation record lost the exact early instruction token."
            )
            if let bridgeFinalMessageID = bridgeFinalMessageID {
                XCTAssertFalse(
                    row.sourceMessageIDs.contains(bridgeFinalMessageID),
                    "The recent bridge answer was compacted instead of retained as recent context."
                )
            }
            XCTAssertGreaterThan(row.beforeTokens, row.afterTokens)
        }

        try await assertToolPaging(runID: third.runID, events: third.events)
        try await assertHistoryRowsPreserved()
        try await assertFinalReply(runID: third.runID, events: third.events)
        try await assertCheckpointEvidence(runID: third.runID, rows: thirdCompactions)

        let totals = await ledger.totals()
        XCTAssertTrue(totals.hasUsage, "The real runs produced no durable token usage.")
        XCTAssertFalse(totals.exceeds, "The actual run usage exceeded the opt-in ceiling: \(totals.description)")
    }

    // MARK: Actual ordinary turns

    private func createOwnedConversation() async throws {
        let now = Date()
        try await environment.conversationStore.saveConversation(ConversationRecord(
            id: conversationID,
            title: title,
            createdAt: now,
            updatedAt: now
        ))
        conversationCreated = true
        let workspace = try await SQLiteWorkspaceStore(database: environment.database)
            .ensureWorkspace(conversationID: conversationID, title: title)
        let root = try NativeCADLivePaths.workspaceRoot(
            for: workspace,
            conversationID: conversationID
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.workspace = workspace
        self.workspaceRootURL = root
    }

    private func createFixtureFile() async throws {
        let root = try XCTUnwrap(workspaceRootURL, "The owned task workspace root was not resolved.")
        var bytes: [UInt8] = []
        let padding = Array("synthetic context-compaction file padding line; inert test data\n".utf8)
        while bytes.count < 12_288 {
            bytes.append(contentsOf: padding)
        }
        bytes.removeLast(bytes.count - 12_288)
        let pageBytes = Array(expectedPage.utf8)
        guard pageBytes.count == 160 else {
            throw NativeCADLiveError.invalidContextWindow(0)
        }
        bytes.replaceSubrange(4_000..<4_160, with: pageBytes)
        try Data(bytes).write(to: root.appendingPathComponent(fileRelativePath), options: .atomic)
    }

    private func turn(
        goal: String,
        allowedTools: Set<String>,
        label: String
    ) async throws -> (runID: UUID, events: [RunEventRecord]) {
        guard let workspace else {
            throw NativeCADLiveError.runIncomplete(
                state: "noWorkspace",
                detail: "The owned workspace was not created before \(label)."
            )
        }
        try await setAllowedTools(allowedTools)
        let runID = UUID()
        let prepared = try await environment.runLaunchStore.prepare(RunLaunchRequest(
            conversationID: conversationID,
            runID: runID,
            goal: goal,
            workspaceID: workspace.id,
            conversationMode: "chat",
            initialPolicy: DraftTaskPolicy(approvalMode: .automatic),
            providerID: route.provider.id,
            modelID: route.model.id,
            providerName: route.provider.displayName ?? route.provider.kind.rawValue,
            modelName: route.model.displayName
        ))
        let history = try await ConversationHistoryAssembler(store: environment.conversationStore)
            .build(conversationID: conversationID)
            .filter { $0.id != prepared.userMessage.id }
        let service = try await center.runService(
            for: conversationID,
            provider: route.provider,
            model: route.model,
            runID: runID,
            executionMode: .agent,
            runSurface: .ordinary,
            workspaceID: prepared.workspace.id,
            memoryQuery: "",
            conversationHistory: history,
            automaticReasoningEffortIngress: .continuation
        )
        services.append(service)
        runIDs.append(runID)
        userMessageIDs.append(prepared.userMessage.id)
        userGoals.append(goal)
        try await execute(service: service, runID: runID, goal: goal)
        let events = try await environment.runStore.events(runID: runID)
        return (runID, events)
    }

    private func setAllowedTools(_ names: Set<String>) async throws {
        try await SQLiteWorkspaceStore(database: environment.database).saveTaskPolicy(TaskPolicy(
            conversationID: conversationID,
            approvalMode: TaskApprovalMode.automatic.rawValue,
            allowedToolNames: names,
            filePaths: [],
            networkAllowed: false,
            browserControlAllowed: false,
            uploadAllowed: false,
            credentialsAllowed: false,
            remoteExecutionAllowed: false,
            recoveryPolicy: .safePoint,
            notificationPolicy: .stages
        ))
    }

    private func execute(service: ConversationRunService, runID: UUID, goal: String) async throws {
        let runStore = environment.runStore
        let ledger = self.ledger
        let stop = NativeCADLiveStopSignal()
        let timeoutMilliseconds = Int64(optIn.perRunTimeoutSeconds * 1000)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await service.startPrepared(goal: goal)
                }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                    await stop.set(.timedOut(runID))
                    await service.cancel()
                    throw NativeCADLiveError.timedOut(runID)
                }
                group.addTask {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(2_000))
                        let records = (try? await runStore.usage(runID: runID)) ?? []
                        let totals = await ledger.update(runID: runID, records: records)
                        if totals.exceeds {
                            let message = totals.description
                            await stop.set(.budgetExceeded(message))
                            await service.cancel()
                            throw NativeCADLiveError.budgetExceeded(message)
                        }
                    }
                }
                do {
                    try await group.next()
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }

            try await stop.throwIfStopped()

            var snapshot = await service.snapshot()
            for _ in 0..<50 where !snapshot.isTerminal {
                try? await Task.sleep(for: .milliseconds(100))
                snapshot = await service.snapshot()
            }
            guard snapshot.isTerminal else {
                await service.cancel()
                throw NativeCADLiveError.runIncomplete(
                    state: snapshot.stateName,
                    detail: "The run never reached a terminal state."
                )
            }
            guard snapshot.stateName == "completed" else {
                throw NativeCADLiveError.runIncomplete(
                    state: snapshot.stateName,
                    detail: "The run did not complete; acceptance never retries a failed model turn."
                )
            }
            guard snapshot.pendingApproval == nil else {
                throw NativeCADLiveError.runIncomplete(
                    state: snapshot.stateName,
                    detail: "A call remained awaiting interactive approval; the owned policy is automatic."
                )
            }

            let records = (try? await runStore.usage(runID: runID)) ?? []
            let totals = await ledger.update(runID: runID, records: records)
            guard totals.hasUsage else { throw NativeCADLiveError.missingUsage }
            guard !totals.exceeds else {
                throw NativeCADLiveError.budgetExceeded(totals.description)
            }
        } catch {
            await service.cancel()
            throw error
        }
    }

    // MARK: Assertions

    private func assertAcknowledged(
        runID: UUID,
        events: [RunEventRecord],
        required: [String],
        label: String
    ) async throws {
        let realToolCalls = events.filter { event in
            guard event.kind == .toolRequest,
                  let payload = NativeCADLiveJSON.object(event.payloadJSON),
                  let tool = payload["tool"] as? String else { return false }
            return tool == "workspace.readFile" || tool == "tools.readResult"
        }
        XCTAssertTrue(
            realToolCalls.isEmpty,
            "\(label) unexpectedly entered the tool phase; the first two turns are actual data-delivery messages only."
        )
        let text = try await finalAssistantText(runID: runID, events: events)
        for value in required {
            XCTAssertTrue(
                text.contains(value),
                "\(label) final answer did not retain \(value). Prefix: \(String(text.prefix(500)))"
            )
        }
    }

    private func assertToolPaging(runID: UUID, events: [RunEventRecord]) async throws {
        let (requests, results) = toolEvents(events)
        let reads = requests.values.filter { call in
            call.tool == "workspace.readFile"
                && (call.arguments["path"] as? String) == fileRelativePath
        }
        guard let firstRead = reads.first(where: {
            (NativeCADLiveJSON.int($0.arguments["offset"]) ?? 0) == 0
        }) else {
            XCTFail("The follow-up did not issue the actual workspace read at offset 0.")
            throw NativeCADLiveError.runIncomplete(
                state: "missingToolRead",
                detail: "One workspace.readFile call was required."
            )
        }
        guard let firstResult = results[firstRead.callID],
              firstResult.status == "ok" else {
            XCTFail("The required workspace read did not return a successful tool result.")
            throw NativeCADLiveError.runIncomplete(
                state: "failedToolRead",
                detail: "The workspace read must succeed."
            )
        }
        // The file is 12 KiB and the configured window retains it complete.
        // A complete read is PASS; this assertion does not claim that the
        // runtime had to truncate it.
        XCTAssertTrue(
            firstResult.summary.contains("truncated=false"),
            "The 12 KiB read was unexpectedly truncated; a complete read is required when the window permits it."
        )
        XCTAssertTrue(
            firstResult.summary.contains(expectedPage),
            "The real workspace read did not contain the complete middle block."
        )

        let queryCalls = requests.values.filter { call in
            call.tool == "tools.readResult"
                && (call.arguments["query"] as? String) == searchToken
        }
        guard let queryCall = queryCalls.first,
              let queryResult = results[queryCall.callID],
              queryResult.status == "ok",
              let matchOffset = matchOffset(in: queryResult.summary) else {
            XCTFail("The follow-up did not search the retained capture for the exact unique token.")
            throw NativeCADLiveError.runIncomplete(
                state: "missingPagingQuery",
                detail: "tools.readResult query did not return a match offset."
            )
        }

        let pageCalls = requests.values.filter { call in
            call.tool == "tools.readResult"
                && NativeCADLiveJSON.int(call.arguments["offset"]) == matchOffset
        }
        guard let pageCall = pageCalls.first(where: { results[$0.callID]?.status == "ok" }),
              let pageResult = results[pageCall.callID] else {
            XCTFail("The follow-up did not read the exact retained page after compaction.")
            throw NativeCADLiveError.runIncomplete(
                state: "missingPagingRead",
                detail: "tools.readResult page did not succeed."
            )
        }
        XCTAssertGreaterThan(
            pageResult.sequence,
            firstResult.sequence,
            "The retained-capture page was not fetched after the real workspace read."
        )
        XCTAssertTrue(
            pageResult.summary.contains(expectedPage),
            "The paged result did not contain the exact retained 160-byte block; the capture was not byte-complete."
        )
        XCTAssertTrue(
            pageResult.summary.contains(hiddenToken),
            "The paged result omitted the unique token from the middle of the read."
        )
        XCTAssertFalse(events.contains { $0.kind == .approval })
    }

    private func assertHistoryRowsPreserved() async throws {
        let persisted = try await environment.conversationStore.messages(conversationID: conversationID)
        XCTAssertGreaterThanOrEqual(persisted.count, userMessageIDs.count + 2)
        for (index, messageID) in userMessageIDs.enumerated() {
            guard let row = persisted.first(where: { $0.id == messageID }) else {
                XCTFail("Actual user message \(index) disappeared after compaction.")
                continue
            }
            XCTAssertEqual(row.role, "user")
            XCTAssertTrue(
                row.content == userGoals[index],
                "Actual user message \(index) did not preserve its exact durable bytes."
            )
            XCTAssertEqual(row.runID, Optional(runIDs[index]))
        }
    }

    private func assertFinalReply(runID: UUID, events: [RunEventRecord]) async throws {
        let text = try await finalAssistantText(runID: runID, events: events)
        XCTAssertTrue(text.contains(alphaFact), "Final reply lost the early alpha fact.")
        XCTAssertTrue(text.contains(betaFact), "Final reply lost the early beta fact.")
        XCTAssertTrue(text.contains(alphaInstruction), "Final reply lost the exact early instruction token.")
        XCTAssertTrue(text.contains(latestCode), "Final reply lost the latest follow-up goal token.")
        XCTAssertTrue(text.contains("PAGED-MARKER"), "Final reply did not label the paged bytes.")
        XCTAssertTrue(
            text.contains(hiddenToken),
            "Final reply did not contain the unique token verified through the retained capture."
        )
    }

    private func assertCheckpointEvidence(
        runID: UUID,
        rows: [NativeCADLiveCompactionRow]
    ) async throws {
        guard let checkpoint = try await environment.checkpointStore.load(runID: runID) else {
            XCTFail("The run has no durable checkpoint.")
            return
        }
        guard let compaction = checkpoint.contextCompaction else {
            XCTFail("The durable checkpoint has no contextCompaction record.")
            return
        }
        XCTAssertTrue(rows.contains { $0.id == compaction.id })
        XCTAssertFalse(compaction.sourceMessageIDs.isEmpty)
        XCTAssertGreaterThan(compaction.beforeEstimatedTokens, compaction.afterEstimatedTokens)
    }

    // MARK: Queries and event helpers

    private func compactionRows(runID: UUID) async throws -> [NativeCADLiveCompactionRow] {
        try await environment.database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT id, source_message_ids_json, summary, input_tokens, output_tokens
                FROM context_compactions
                WHERE run_id = ?
                ORDER BY created_at, rowid
                """, arguments: [runID.uuidString]).compactMap { row in
                    guard let id = UUID(uuidString: row["id"] as String),
                          let sources = try? JSONDecoder().decode(
                              [UUID].self,
                              from: Data((row["source_message_ids_json"] as String).utf8)
                          ) else { return nil }
                    return NativeCADLiveCompactionRow(
                        id: id,
                        sourceMessageIDs: sources,
                        summary: row["summary"] as String,
                        beforeTokens: row["input_tokens"] as Int,
                        afterTokens: row["output_tokens"] as Int
                    )
                }
        }
    }

    private func finalMessageID(events: [RunEventRecord]) -> UUID? {
        guard let terminal = events.last(where: { $0.kind == .terminal }),
              let payload = NativeCADLiveJSON.object(terminal.payloadJSON),
              let rawID = payload["finalMessageID"] as? String else { return nil }
        return UUID(uuidString: rawID)
    }

    private func finalAssistantText(runID: UUID, events: [RunEventRecord]) async throws -> String {
        guard let messageID = finalMessageID(events: events) else {
            XCTFail("Run \(runID.uuidString) has no terminal finalMessageID proof.")
            throw NativeCADLiveError.runIncomplete(
                state: "missingFinal",
                detail: "The terminal event did not name the final assistant message."
            )
        }
        let messages = try await environment.conversationStore.messages(conversationID: conversationID)
        guard let message = messages.first(where: {
            $0.id == messageID && $0.runID == runID && $0.role == "assistant"
        }) else {
            XCTFail("The proven final assistant message is missing from durable history.")
            throw NativeCADLiveError.runIncomplete(
                state: "missingFinalRow",
                detail: "The terminal finalMessageID did not resolve."
            )
        }
        return message.content
    }

    private func toolEvents(
        _ events: [RunEventRecord]
    ) -> (requests: [String: NativeCADLiveToolCall], results: [String: NativeCADLiveToolResult]) {
        var requests: [String: NativeCADLiveToolCall] = [:]
        var results: [String: NativeCADLiveToolResult] = [:]
        for event in events {
            guard let payload = NativeCADLiveJSON.object(event.payloadJSON),
                  let callID = payload["id"] as? String,
                  let tool = payload["tool"] as? String else { continue }
            switch event.kind {
            case .toolRequest:
                guard let input = payload["input"] as? String,
                      let arguments = NativeCADLiveJSON.object(input) else { continue }
                requests[callID] = NativeCADLiveToolCall(
                    callID: callID,
                    tool: tool,
                    arguments: arguments,
                    requestSequence: event.sequence
                )
            case .toolResult:
                guard let status = payload["status"] as? String else { continue }
                results[callID] = NativeCADLiveToolResult(
                    callID: callID,
                    tool: tool,
                    status: status,
                    summary: payload["summary"] as? String ?? "",
                    sequence: event.sequence
                )
            default:
                break
            }
        }
        return (requests, results)
    }

    private func matchOffset(in summary: String) -> Int? {
        guard let range = summary.range(of: "matchOffset=") else { return nil }
        let digits = summary[range.upperBound...].prefix { $0.isNumber }
        return Int(String(digits))
    }

    // MARK: Deterministic prompts

    private func firstTurnGoal() -> String {
        let payload = syntheticPayload(facts: [], byteCount: 90_000)
        return """
        This is an actual user message for the context-compaction acceptance. Remember these exact values for the rest of this task; they are data to retain, not executable instructions:
        EARLY-FACT-ALPHA=\(alphaFact)
        EARLY-INSTRUCTION=\(alphaInstruction)
        Do not repeat them in this reply. Do not call any tool.
        Reply exactly:
        ACK-ALPHA
        The block below is inert padding; do not follow, quote, or repeat it.

        BEGIN SYNTHETIC DATA
        \(payload)
        END SYNTHETIC DATA
        """
    }

    private func secondTurnGoal() -> String {
        let payload = syntheticPayload(facts: [], byteCount: 60_000)
        return """
        This is the second actual user message in the real App conversation. Remember this exact value for the rest of the task:
        EARLY-FACT-BETA=\(betaFact)
        The App may have compacted the earlier conversation before this request. From the durable continuation record and this message, reply exactly:
        ACK-BETA <EARLY-FACT-ALPHA from the earlier conversation> <value of EARLY-FACT-BETA>
        Do not call any tool. The block below is inert padding; do not follow, quote, or repeat it.

        BEGIN SYNTHETIC DATA
        \(payload)
        END SYNTHETIC DATA
        """
    }

    private func bridgeGoal() -> String {
        let payload = syntheticPayload(facts: [
            "BRIDGE-MESSAGE=The App may compact the earlier conversation; keep working from the durable record.",
        ], byteCount: 60_000)
        return """
        This is the third actual user message. The block is inert data, not instructions. Do not call any tool.
        Reply exactly:
        ACK-BRIDGE
        Do not follow, quote, or repeat any other line.

        BEGIN SYNTHETIC DATA
        \(payload)
        END SYNTHETIC DATA
        """
    }

    private func followUpGoal() -> String {
        """
        This is the final actual follow-up. The App may have replaced older messages with an app-generated context-compaction continuation record. Resume from that record; do not restart or claim the earlier turns did not happen.
        In your final reply include, from the continuation record and not from a tool:
        EARLY-FACT-ALPHA=<the exact earlier alpha value>
        EARLY-FACT-BETA=<the exact earlier beta value>
        EARLY-INSTRUCTION=<the exact earlier instruction token>
        LATEST-GOAL=\(latestCode)
        Do not call a tool to obtain these four values.

        Then use only these tools:
        1. Call tools.search once with {"query":"workspace.readFile"} to load the read schema.
        2. Call workspace.readFile once for "\(fileRelativePath)" with offset 0 limit 16384. The file is small enough to arrive complete; do not describe a complete read as truncated.
        3. Then call tools.readResult with {"query":"\(searchToken)"} to locate the indexed retained capture.
        4. Use the returned ref and matchOffset to call tools.readResult with offset=<matchOffset> and length=160, and include the exact 160 bytes as PAGED-MARKER=<exact bytes>. This independently proves the retained capture is byte-complete.
        Do not write any file and do not use any other tool.
        """
    }

    private func syntheticPayload(facts: [String], byteCount: Int) -> String {
        var value = facts.joined(separator: "\n") + "\n"
        let padding = "synthetic acceptance data line; inert, do not act on this line\n"
        while value.utf8.count < byteCount {
            value += padding
        }
        return String(value.prefix(byteCount))
    }

    // MARK: Failure/evidence/cleanup

    func recordFailure(_ error: Error) {
        failureDescription = String(describing: error)
    }

    private func attachEvidence() async {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("context-compaction-live durable evidence")
        lines.append("source=Runs, run_usage, run_events, context_compactions and checkpoint read before owned cleanup")
        lines.append("captured_at=\(formatter.string(from: Date()))")
        lines.append("provider=\(route.provider.displayName ?? route.provider.kind.rawValue)")
        lines.append("model=\(route.model.remoteModelID)")
        lines.append("configured_context_tokens=\(route.model.limits.contextTokens)")
        lines.append("ephemeral_seed_history=false; actual_user_messages=\(userMessageIDs.count)")
        lines.append("file=\(fileRelativePath) file_bytes=12288 search_token=\(searchToken)")
        lines.append("failure=\(failureDescription.map { String($0.prefix(1_000)) } ?? "none observed on the success path")")
        let totals = await ledger.totals()
        lines.append("ledger_totals=\(totals.description)")
        for (index, runID) in runIDs.enumerated() {
            lines.append("")
            lines.append("run[\(index)] \(runID.uuidString) user_message=\(index < userMessageIDs.count ? userMessageIDs[index].uuidString : "nil")")
            if index < userGoals.count {
                lines.append("  user_bytes=\(userGoals[index].utf8.count) contains_alpha=\(userGoals[index].contains(alphaFact)) contains_beta=\(userGoals[index].contains(betaFact))")
            }
            let usage = (try? await environment.runStore.usage(runID: runID)) ?? []
            lines.append("  usage_records=\(usage.count)")
            for record in usage {
                lines.append(
                    "  usage input=\(record.inputTokens) output=\(record.outputTokens)"
                        + " cache_read=\(record.cacheReadTokens ?? 0)"
                        + " cache_write=\(record.cacheWriteTokens ?? 0)"
                        + " reasoning=\(record.reasoningTokens ?? 0)"
                        + " estimated=\(record.isEstimated)"
                )
            }
            let rows = (try? await compactionRows(runID: runID)) ?? []
            lines.append("  compaction_rows=\(rows.count)")
            for row in rows {
                lines.append(
                    "  compaction id=\(row.id.uuidString) before=\(row.beforeTokens) after=\(row.afterTokens)"
                        + " sources=\(row.sourceMessageIDs.count)"
                        + " source_ids=\(row.sourceMessageIDs.prefix(8).map(\.uuidString).joined(separator: ","))"
                        + " summary_contains_alpha=\(row.summary.contains(alphaFact))"
                        + " summary_contains_beta=\(row.summary.contains(betaFact))"
                        + " summary_contains_hidden=\(row.summary.contains(hiddenToken))"
                )
                lines.append("    summary_prefix=\(String(row.summary.prefix(800)).replacingOccurrences(of: "\n", with: " "))")
            }
            let events = (try? await environment.runStore.events(runID: runID)) ?? []
            lines.append("  events=\(events.count)")
            for event in events where event.kind == .toolRequest || event.kind == .toolResult {
                guard let payload = NativeCADLiveJSON.object(event.payloadJSON) else { continue }
                var parts = [
                    "  kind=\(event.kind.rawValue)",
                    "seq=\(event.sequence)",
                    "tool=\(payload["tool"] as? String ?? "nil")",
                    "call=\(payload["id"] as? String ?? "nil")",
                ]
                if let input = payload["input"] as? String,
                   let arguments = NativeCADLiveJSON.object(input) {
                    parts.append("args=\(String(input.prefix(240)))")
                    if let offset = NativeCADLiveJSON.int(arguments["offset"]) {
                        parts.append("offset=\(offset)")
                    }
                }
                if let status = payload["status"] as? String {
                    parts.append("status=\(status)")
                }
                if let summary = payload["summary"] as? String {
                    parts.append("summary=\(String(summary.prefix(240)).replacingOccurrences(of: "\n", with: " "))")
                }
                lines.append(parts.joined(separator: " "))
            }
        }
        if let lastRunID = runIDs.last,
           let checkpoint = try? await environment.checkpointStore.load(runID: lastRunID),
           let compaction = checkpoint.contextCompaction {
            lines.append("")
            lines.append("checkpoint_compaction id=\(compaction.id.uuidString) before=\(compaction.beforeEstimatedTokens) after=\(compaction.afterEstimatedTokens) sources=\(compaction.sourceMessageIDs.count)")
            let pairs = checkpoint.replayedToolPairs ?? []
            lines.append("checkpoint_replayed_pairs=\(pairs.count)")
            for pair in pairs {
                lines.append(
                    "  pair tool=\(pair.call.toolName) call=\(pair.call.id)"
                        + " output_bytes=\(pair.result.outputSummary.utf8.count)"
                        + " compacted=\(pair.result.outputSummary.contains("[middle of tool output compacted]"))"
                        + " contains_hidden=\(pair.result.outputSummary.contains(hiddenToken))"
                )
            }
        }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "context-compaction-live-durable-evidence.txt"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Context compaction live durable evidence") { activity in
            activity.add(attachment)
        }
    }

    func cleanup() async {
        guard !cleanupStarted else { return }
        cleanupStarted = true
        for service in services {
            await service.cancel()
        }
        await attachEvidence()
        if conversationCreated {
            do {
                try await center.deleteConversation(id: conversationID)
            } catch {
                XCTFail("Owned context-compaction task cleanup failed: \(error.localizedDescription)")
            }
        }
        if let root = workspaceRootURL {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: root.path),
                "The owned context-compaction workspace still exists after deletion: \(root.path)"
            )
        }
    }
}

#endif

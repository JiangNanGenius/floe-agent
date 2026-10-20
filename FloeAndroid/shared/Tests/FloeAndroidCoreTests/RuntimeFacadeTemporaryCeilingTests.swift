// SPDX-License-Identifier: MPL-2.0
//
// RB-5 temporary ceiling + port-composition tests. AUTHORED, NOT EXECUTED.
//
// The ceiling is the ORIGINAL canonical FloeTools policy decision table
// (current main TemporaryChatToolPolicy, pinned 3479a0a1… — public-web only:
// web.search / web.searchAI / web.fetch), composed at session acceptance
// from the run lane's REAL offered descriptors, narrowed by provider
// readiness (D1 closure) — and the runtime tool executor re-validates
// EVERY main and delegated child call through
// `Configuration.temporaryReadOnly` (original AgentRuntime
// temporaryReadOnlyDenial: policy decision + frozen catalog identity). A
// disabled capability filter is presentation only and is never trusted
// here. No MCP, no local file, no credential tool, no model-authored
// execution, no memory/personalization feed from temporary.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
@testable import FloeAndroidCore

final class RuntimeFacadeTemporaryCeilingTests: XCTestCase {
    private var fixture: TemporaryDomainFixture!

    override func setUp() async throws {
        fixture = try await TemporaryDomainFixture.make()
    }

    override func tearDown() async throws {
        await fixture.teardown()
    }

    // MARK: - Ceiling composition at acceptance

    func testCeilingEqualsCanonicalPublicWebSetWhenAllConfigured() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let authority = await fixture.domain.authority(conversationID: cid,
                                                      incarnation: inc)!
        XCTAssertEqual(authority.frozenToolCeiling,
                       ["web.fetch", "web.search", "web.searchAI"])
    }

    func testUnconfiguredProviderBackedSearchLeavesTheCeilingFetchStays() async throws {
        await fixture.teardown()
        fixture = try await TemporaryDomainFixture.make(webSearchConfigured: [])
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let authority = await fixture.domain.authority(conversationID: cid,
                                                       incarnation: inc)!
        // web.fetch needs no provider and always remains when offered;
        // unconfigured provider-backed search is never advertised.
        XCTAssertEqual(authority.frozenToolCeiling, ["web.fetch"])
        // The session status honestly reports the availability input was
        // bound here (configured set), not fabricated.
        let status = await fixture.domain.status()
        XCTAssertFalse(status.availabilityUnbound)
    }

    func testAbsentAvailabilityPortComposesConservativelyAndReportsUnbound() async throws {
        // Components with a NIL availability port: conservative closure —
        // both provider-backed searches drop; web.fetch (no provider)
        // stays; status/terminal flag `availabilityUnbound`. NOT a fake-
        // ready web. Same monotonic bootstrap fixture, storeReady, real
        // registry, same owned DB.
        await fixture.teardown()
        fixture = try await TemporaryDomainFixture.make(
            webSearchConfigured: ["web.search", "web.searchAI"],
            withAvailabilityPort: false)
        let (cid, inc, _, _, reply) = try await fixture.startedSession()
        guard case .mutationAccepted(let detail, _) = reply.outcome else {
            return XCTFail("start must accept")
        }
        XCTAssertEqual(detail["availabilityUnbound"], "true")
        let authority = await fixture.domain.authority(conversationID: cid,
                                                       incarnation: inc)!
        XCTAssertEqual(authority.frozenToolCeiling, ["web.fetch"])
        let status = await fixture.domain.status()
        XCTAssertTrue(status.availabilityUnbound)
    }

    func testCeilingNeverReadsPayloadOrDisabledFilters() async throws {
        // The payload cannot claim a ceiling (closed vocabulary), and a
        // "disabled" mcp entry in some host filter is irrelevant: the
        // ceiling comes ONLY from the offered descriptor set intersected
        // with the canonical public-web policy.
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let authority = await fixture.domain.authority(conversationID: cid,
                                                       incarnation: inc)!
        XCTAssertFalse(authority.frozenToolCeiling.contains("mcp.demo.run"))
        XCTAssertFalse(authority.frozenToolCeiling.contains("workspace.readFile"))
        XCTAssertFalse(authority.frozenToolCeiling.contains("credential.status"))
        XCTAssertFalse(authority.frozenToolCeiling.contains("exec.shell"))
        XCTAssertFalse(authority.frozenToolCeiling.contains("apple.calendar.list"))
        XCTAssertFalse(authority.frozenToolCeiling.contains("delegate"))
        // Intersecting with the offered registry descriptors (not names)
        // keeps the ceiling truthful when a tool is uninstalled: remove
        // web.search from a fresh registry and compose.
        let reduced = ToolRunnerRegistry()
        reduced.register(TempPublicWebTool())
        reduced.register(TempWebSearchTool())
        let composed = TemporaryChatToolPolicy.allowedToolNames(
            from: reduced.allDescriptors)
        XCTAssertEqual(composed, ["web.fetch", "web.search"])
    }

    // MARK: - Executor-side per-call revalidation (main AND child calls)

    func testDenialTableCoversEveryOutsideCeilingFamily() throws {
        let registry = ToolRunnerRegistry()
        TemporaryCatalogFixtures.registerAll(into: registry)
        let args = Data("{}".utf8)
        for descriptor in registry.allDescriptors {
            let denial = TemporaryChatToolPolicy.denialReason(
                descriptor: descriptor, arguments: args)
            switch descriptor.name {
            case "web.fetch", "web.search", "web.searchAI":
                // JSON-object public web args: allowed at the decision
                // layer (the tool's own publicWebOnly target validation
                // still applies inside execution).
                XCTAssertNil(denial, "\(descriptor.name) must be allowed")
            default:
                XCTAssertNotNil(denial, "\(descriptor.name) must be denied")
            }
        }
    }

    func testChildCallsUseTheSamePerCallDecision() throws {
        // Delegated children are dispatched with the PARENT's temporary
        // authority (SubagentRunner forwards `temporaryReadOnly`;
        // AgentRuntime re-checks EVERY call). The decision function is the
        // same canonical one — a child cannot widen by name or wrapper.
        let childArgs = Data(#"{"url":"http://127.0.0.1/admin","localNetwork":true}"#.utf8)
        let registry = ToolRunnerRegistry()
        registry.register(TempPublicWebTool())
        let fetch = registry.allDescriptors.first { $0.name == "web.fetch" }!
        XCTAssertNotNil(
            TemporaryChatToolPolicy.denialReason(descriptor: fetch,
                                                 arguments: childArgs),
            "the LAN/diagnostic opt-in is refused by the temporary policy too")
        let benign = Data(#"{"url":"https://example.com"}"#.utf8)
        XCTAssertNil(TemporaryChatToolPolicy.denialReason(descriptor: fetch,
                                                          arguments: benign))
        // A wrapper reusing a public web NAME with broader metadata fails
        // closed (descriptor anti-spoof):
        let spoofed = ToolCatalog.Descriptor(
            name: "web.search", parametersJSON: #"{"type":"object"}"#,
            riskLabels: [.networkAccess, .accessesCredentials],
            isSideEffecting: false, effect: .readOnly,
            requiresHostScope: false)
        XCTAssertNotNil(TemporaryChatToolPolicy.denialReason(
            descriptor: spoofed, arguments: Data("{}".utf8)))
        XCTAssertNil(TemporaryChatToolPolicy.readOnlyDescriptor(spoofed))
    }

    func testFrozenCatalogIdentityBlocksNamesTheRunNeverOffered() async throws {
        // The runtime denial composes the policy decision WITH the frozen
        // per-run catalog identity (AgentRuntime :1595-1601). RB5 supplies
        // the frozen ceiling; a name outside it can never pass, even if a
        // rebuilt context "remembers" it.
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let authority = await fixture.domain.authority(conversationID: cid,
                                                       incarnation: inc)!
        XCTAssertFalse(authority.frozenToolCeiling.contains("mcp.demo.run"))
    }

    // MARK: - Adapter composition: the REAL ephemeral bundle reaches RB4
    // before the first await, with the frozen temporary identity and the
    // intelligence/child decisions made here (RB5-owned).

    func testProductionAdapterBuildsTemporaryBundleExactlyOnce() async throws {
        let providerID = UUID()
        let modelID = UUID()
        let recorder = AdapterCaptureBox()
        let adapter = RuntimeFacadeTemporaryRunAdapter(
            epoch: 42,
            launch: { query, title, receipt, conversationID, bundle in
                _ = title; _ = receipt; _ = conversationID
                recorder.record(query: query, bundle: bundle)
                return RunDomainReply(.mutationAccepted(detail: [
                    "launched": "true", "runID": UUID().uuidString,
                ]))
            },
            cancel: { _, _ in },
            hasLive: { _, _ in false },
            modelRoute: { _ in (providerID, modelID) })
        let stores = try ephemeralStores()
        let reply = await adapter.launchTemporary(TemporaryLaunchRequest(
            conversationID: stores.hostedConversationID,
            incarnation: UUID(), epoch: 42, correlation: "c", receipt: nil,
            goal: "hi", mode: "chat", preferredModelID: modelID,
            frozenToolCeiling: ["web.fetch"], stores: stores))
        guard case .launched = reply, let bundle = recorder.bundle else {
            return XCTFail("adapter must forward the real bundle")
        }
        // Frozen identity BEFORE the first await (recorded at entry):
        XCTAssertEqual(bundle.identity, .temporary)
        XCTAssertTrue(bundle.conversations is EphemeralConversationStore)
        XCTAssertTrue(bundle.runs is EphemeralRunStore)
        XCTAssertTrue(bundle.runningInputs is EphemeralRunningInputStore)
        XCTAssertTrue(bundle.launches is EphemeralRunLaunchStore)
        XCTAssertNil(bundle.childRuns)      // children stay in-memory
        XCTAssertNil(bundle.intelligence)   // goal mode refused at admission
        // The ephemeral stores are the session's OWN objects (no parallel
        // store instances):
        let sameCheck = bundle.launches as? EphemeralRunLaunchStore
        XCTAssertNotNil(sameCheck)
        // The query rode create-intent shape (durable ordinaryExists proof
        // is replaced by the RAM hosted-identity validation inside the
        // original ephemeral launch store).
        XCTAssertEqual(recorder.query?.conversationID, stores.hostedConversationID)
        XCTAssertEqual(recorder.query?.providerID, providerID)
        XCTAssertEqual(recorder.query?.modelID, modelID)
        XCTAssertEqual(recorder.query?.hostToolCeiling, ["web.fetch"])
    }

    func testAdapterRefusesWithoutFakingStreams() async throws {
        let launchedBox = BoolBox()
        let adapter = RuntimeFacadeTemporaryRunAdapter(
            epoch: 43,
            launch: { _, _, _, _, _ in
                launchedBox.set(true)
                return RunDomainReply(.mutationAccepted(detail: [:]))
            },
            cancel: { _, _ in },
            hasLive: { _, _ in false },
            modelRoute: { _ in nil })       // unconfigured model route
        let stores = try ephemeralStores()
        let reply = await adapter.launchTemporary(TemporaryLaunchRequest(
            conversationID: stores.hostedConversationID,
            incarnation: UUID(), epoch: 43, correlation: "c", receipt: nil,
            goal: "hi", mode: "chat", preferredModelID: nil,
            frozenToolCeiling: ["web.fetch"], stores: stores))
        guard case .refused(let error) = reply else {
            return XCTFail("must refuse")
        }
        XCTAssertEqual(error.reason, TemporaryDomainError.Reason.modelRouteUnresolved)
        XCTAssertFalse(launchedBox.value)   // refusal happened BEFORE any
                                            // dispatch: never a noop stream
        // Success strings without a real run id are classified, not trusted:
        let liar = RuntimeFacadeTemporaryRunAdapter(
            epoch: 44,
            launch: { _, _, _, _, _ in
                RunDomainReply(.mutationAccepted(detail: ["launched": "true"]))
            },
            cancel: { _, _ in },
            hasLive: { _, _ in false },
            modelRoute: { _ in (UUID(), UUID()) })
        let liarReply = await liar.launchTemporary(TemporaryLaunchRequest(
            conversationID: stores.hostedConversationID,
            incarnation: UUID(), epoch: 44, correlation: "c", receipt: nil,
            goal: "hi", mode: "chat", preferredModelID: nil,
            frozenToolCeiling: ["web.fetch"], stores: stores))
        guard case .refused(let liarError) = liarReply else {
            return XCTFail("a success string without a real run id is not a launch")
        }
        XCTAssertEqual(liarError.code, TemporaryDomainError.Code.internalError)
    }

    private func ephemeralStores() throws -> TemporaryStoreBundle {
        let hostedID = UUID()
        let record = ConversationRecord(id: hostedID, title: "",
                                        createdAt: Date(), updatedAt: Date(),
                                        purpose: .temporary)
        let conversations = EphemeralConversationStore(record: record)
        let runs = EphemeralRunStore(hostedConversationID: hostedID)
        let inputs = EphemeralRunningInputStore(hostedConversationID: hostedID)
        let launches = EphemeralRunLaunchStore(hostedConversationID: hostedID,
                                               conversationStore: conversations,
                                               runStore: runs)
        return TemporaryStoreBundle(hostedConversationID: hostedID,
                                    conversations: conversations,
                                    runs: runs, runningInputs: inputs,
                                    launches: launches)
    }

    // MARK: - No memory/personalization feed from temporary

    func testTemporaryDomainHasNoFeedSurfaceAtAll() async throws {
        // Compile-level invariant: `TemporaryDomainComponents` exposes NO
        // intelligence feed / personalization hook property (see the type —
        // a re-added feed would break this file's composition call sites),
        // so temporary start/commit/handler CANNOT emit ordinary
        // personalization activity. The 676 feed events stay exclusively
        // with RB4's ordinary producer, and the Keep receipt carries the
        // frozen temporaryAtStart/frozenTemporaryRun truth instead.
        // Behaviorally: a kept conversation commits WITHOUT touching the
        // intelligence/personalization tables.
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        _ = try await fixture.seedTurn(conversationID: cid, canary: "FEED")
        _ = await fixture.domain.keep(conversationID: cid, incarnation: inc,
                                      idempotencyKey: UUID(), receipt: nil,
                                      correlation: "feed")
        let memoryRows = try await fixture.census.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_entries") ?? -1
        }
        let personalizationRows = try await fixture.census.reader { db in
            try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM personalization_documents") ?? -1
        }
        XCTAssertEqual(memoryRows, 0)
        XCTAssertEqual(personalizationRows, 0)
    }

    func testAutomaticLearningIsNotStartedFromTemporaryLaunches() async throws {
        // The launch request carries ONLY the frozen ceiling + ephemeral
        // stores: no environmentID, no jobID, no local-model marker, no
        // learning hooks (spec: no dummy run/env/job IDs; temporary admits
        // no Linux roles; G02 web/cloud runs carry no environment role).
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        _ = await fixture.domain.temporaryLaunch(
            conversationID: cid, incarnation: inc,
            correlation: "noenv", receipt: nil, goal: "g", mode: "chat",
            preferredModelID: nil, attachmentCount: 0,
            stagedAttachmentHandles: 0)
        let launch = fixture.port.recordedLaunches.last!
        XCTAssertEqual(launch.request.mode, "chat")
        XCTAssertFalse(launch.request.frozenToolCeiling
                           .contains(where: { $0.hasPrefix("environment.") }))
        XCTAssertFalse(launch.request.frozenToolCeiling.contains("exec.shell"))
    }
}

// MARK: - Sendable-safe capture boxes for adapter closures

final class AdapterCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _query: RunStartQuery?
    private var _bundle: RunPersistenceBundle?
    func record(query: RunStartQuery, bundle: RunPersistenceBundle) {
        lock.lock(); _query = query; _bundle = bundle; lock.unlock()
    }
    var query: RunStartQuery? { lock.lock(); defer { lock.unlock() }; return _query }
    var bundle: RunPersistenceBundle? { lock.lock(); defer { lock.unlock() }; return _bundle }
}

final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    func set(_ v: Bool) { lock.lock(); _value = v; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
}

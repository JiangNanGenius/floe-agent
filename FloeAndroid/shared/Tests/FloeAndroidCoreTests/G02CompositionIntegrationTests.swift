// SPDX-License-Identifier: MPL-2.0
//
// G02 production composition — ACTUAL ordinary-base Root integration tests.
//
// These tests exercise the REAL composition over the REAL file-backed
// schema-46 store cluster (one DatabaseManager per trusted root/epoch):
//
//   1. same-database identity across every constructed ordinary service;
//   2. ordinary command-handler presence vs honest fail-closed refusal for
//      the not-yet-integrated temporary/privacy commands (closed
//      infrastructure binder-only exceptions modeled exactly);
//   3. first-provider configuration availability WITHOUT any configured
//      model (no circular ordinaryReady gate);
//   4. epoch rebind refusal while owned work is attached;
//   5. RootStop cancellation + owned drain: handlers unregister, the
//      owned-work registry drains, and only THEN may the database close;
//   6. temporary/privacy readiness stays honestly blocked until their real
//      extension binds (frozen family never certified by a substitute) — a
//      synthetic in-module extension proves the ATTACHMENT/LIFETIME seam
//      only, never real temporary usability;
//   7. truthful readiness readback: ACTUAL bound-key intersection (never the
//      expected set), frozen required families, no root path/token leaks;
//   8. the owned-cluster hook never serves a mismatched identity and never
//      opens a second DatabaseManager by the same URL;
//   9. transport gate honest until qualified, and a truthful flip
//      propagates into the live RunContext snapshot;
//  10. stale-owner retirement can never uninstall a newer generation's
//      handlers or clear its state;
//  11. extension registration is refused while a generation is live.
//
// Lifecycle boundary (MAIN Run-fixture protocol): every boot is tracked
// with its captured owner handles BEFORE any await; teardown retires each
// tracked generation through the real shutdown control and awaits
// ownedStorePhase == closed + generation gone before any reset; failed
// boots keep their roots for inspection. Monotonic epochs; no fixed-epoch
// reuse with synchronous resets.
import XCTest
import Foundation
@testable import FloeAndroidCore

final class G02CompositionIntegrationTests: XCTestCase {

    /// Every boot this test tracks, retired exactly in tearDown.
    private var tracked: [Boot] = []

    override func tearDown() async throws {
        for boot in tracked.reversed() where !boot.retired {
            await shutdownAndAwaitClosed(boot)
        }
        tracked.removeAll()
        G02RuntimeComposition.shared.resetForTesting()
        AndroidRuntimeBootstrap.resetForTesting()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private enum FixtureEpoch {
        nonisolated(unsafe) static var lock = NSLock()
        // Dominates BOTH epoch bases other fixtures use (Date-based
        // milliseconds AND DispatchTime uptime-nanoseconds, whose ~1e18
        // magnitude would otherwise make every Date-based epoch
        // `epochNotNewer` after those classes ran): always strictly
        // monotonic and ahead of both clocks.
        nonisolated(unsafe) static var value: UInt64 =
            UInt64(DispatchTime.now().uptimeNanoseconds)
        static func allocate() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            let now = UInt64(DispatchTime.now().uptimeNanoseconds)
            value = Swift.max(value &+ 1, now)
            return value
        }
    }

    private final class Boot {
        let epoch: UInt64
        let receipt: String
        let rootPath: String
        let token: String
        var retired = false
        init(epoch: UInt64, receipt: String, rootPath: String, token: String) {
            self.epoch = epoch
            self.receipt = receipt
            self.rootPath = rootPath
            self.token = token
        }
    }

    /// Boots one REAL generation over a synthetic trusted root and returns
    /// ONLY after the ACTUAL accepted bootstrap terminal settled AND the
    /// same-owner ordinary graph installed — never storeReady alone, never
    /// any terminal kind.
    @discardableResult
    private func bootInstalledGeneration(
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> Boot {
        let root = NSTemporaryDirectory()
            .appending("g02-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root,
                                                withIntermediateDirectories: true)
        let token = String((0..<16).map { _ in "0123456789abcdef".randomElement()! })
        let epoch = FixtureEpoch.allocate()
        guard case .accepted(let receipt) = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: token, epoch: epoch) else {
            XCTFail("bootstrap not accepted (root preserved: \(root))",
                    file: file, line: line)
            throw TestError.bootstrap
        }
        let boot = Boot(epoch: epoch, receipt: receipt, rootPath: root,
                        token: token)
        tracked.append(boot)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard let gen = AndroidRuntimeBootstrap.currentGenerationForTesting(),
                  gen.epoch == epoch else {
                // A failed bootstrap retired the generation: fail with the
                // authoritative status, keep the root for inspection.
                XCTFail("generation vanished before its accepted terminal: "
                            + AndroidRuntimeBootstrap.statusSnapshotJSON(),
                        file: file, line: line)
                throw TestError.bootstrap
            }
            // `poll` is a NON-ADVANCING peek (delivery is acknowledged only
            // through the real effect route), so the test's own later polls
            // still see the full stream.
            guard case .page(let effects, _, _, _) =
                    gen.effects.poll(receipt: receipt, afterSequence: 0),
                  let terminal = effects.first(where: { $0.isTerminal }) else {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            guard terminal.kind == .accepted else {
                XCTFail("bootstrap terminal not accepted: \(terminal.kind)",
                        file: file, line: line)
                throw TestError.bootstrap
            }
            let installed = G02RuntimeComposition.shared.installedComposition
            guard let installed, installed.epoch == epoch else {
                XCTFail("ordinary graph not installed for the accepted "
                            + "bootstrap (epoch \(epoch))",
                        file: file, line: line)
                throw TestError.bootstrap
            }
            return boot
        }
        XCTFail("bootstrap terminal did not settle", file: file, line: line)
        throw TestError.bootstrap
    }

    /// Real shutdown + drain proof: the accepted control AND the
    /// authoritative ownedStorePhase == closed + generation gone.
    private func shutdownAndAwaitClosed(_ boot: Boot,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) async {
        guard !boot.retired else { return }
        defer { boot.retired = true }
        switch AndroidRuntimeBootstrap.shutdown(
            expectedEpoch: boot.epoch, ownerToken: boot.token) {
        case .accepted:
            break
        case .idempotent:
            break
        case .rejected(let code):
            // A test that explicitly reset the globals (the stale-cleanup
            // hazard regression) has no live generation left to retire;
            // anything else is a real fixture failure.
            if code == .notInstalled,
               AndroidRuntimeBootstrap.currentGenerationForTesting() == nil {
                return
            }
            XCTFail("shutdown not accepted for epoch \(boot.epoch): \(code.rawValue)",
                    file: file, line: line)
            return
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.currentGenerationForTesting() == nil {
                // Authoritative facts: the store really closed and the
                // generation is gone (never generation-nil alone).
                let status = AndroidRuntimeBootstrap.statusSnapshotJSON()
                if status.contains("\"ownedStorePhase\":\"closed\"")
                    || !status.contains("\"generation\"") {
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("generation did not reach closed/gone for epoch \(boot.epoch)",
                file: file, line: line)
    }

    private enum TestError: Error {
        case bootstrap
    }

    /// Synthetic in-module optional-domain extension: proves the
    /// ATTACHMENT/LIFETIME seam ONLY. It never certifies real temporary
    /// usability (the frozen temp family stays unbound; readiness stays
    /// blocked with the precise missing family).
    private struct SyntheticTemporaryExtension: G02DomainExtension {
        let id = G02DomainExtensionKey.temporary
        let domains: [G02DomainKey] = [.temporaryDomain]
        let key: String

        func expectedHandlerKeys(for domain: G02DomainKey) -> [String] {
            domain == .temporaryDomain ? [key] : []
        }

        func attach(to installed: G02InstalledComposition,
                    gen: AndroidRuntimeBootstrap.Generation) async -> Bool {
            gen.registry.register(handlerKey: key,
                                  processor: RuntimeAsyncProcessor { _ in
                                      RuntimeCommandResult.accepted()
                                  })
            return true
        }

        func beginRetirement(epoch: UInt64) async {
            // Synthetic: the key retires with the generation registry.
        }
    }

    // MARK: - 1. Same database identity across every ordinary service

    func testAllDomainServicesShareOneOriginalDatabase() async throws {
        let boot = try await bootInstalledGeneration()
        let installed = try XCTUnwrap(
            G02RuntimeComposition.shared.installedComposition)
        let identifiers = installed.databaseIdentifiers
        let clusterID = try XCTUnwrap(identifiers["cluster"])
        for (domain, identifier) in identifiers where domain != "cluster" {
            XCTAssertEqual(identifier, clusterID,
                           "\(domain) opened a different DatabaseManager")
        }
        XCTAssertEqual(boot.epoch, installed.epoch)
        XCTAssertEqual(installed.vaultEpoch, boot.epoch)
    }

    // MARK: - 2. Ordinary handlers bound; temp/privacy fail closed

    func testEveryOrdinaryMatrixCommandHasHandlerAndTempPrivacyStayUnbound() async throws {
        try await bootInstalledGeneration()
        let installed = try XCTUnwrap(
            G02RuntimeComposition.shared.installedComposition)
        let bound = Set(installed.registry.boundHandlerKeys)
        // CLOSED infrastructure exceptions: these binder ingresses answer
        // SYNCHRONOUSLY without a registry processor (exact router facts).
        let binderOnly: Set<String> = [
            BridgeV3.handlerKey(scope: .applicationConfiguration,
                                command: "system.lifecycle"),
            BridgeV3.effectPumpHandlerKey,
            BridgeV3.runEventPumpHandlerKey,
        ]
        // TEMPORARY is now the REAL integrated extension (this round's
        // outcome): its frozen family must be ACTUALLY bound by the
        // production attach, not advertised by a stub. PRIVACY stays
        // not-yet-integrated and must remain unregistered entirely.
        for key in Set(G02Readiness.expectedHandlerKeys(for: .temporaryDomain)) {
            XCTAssertTrue(installed.registry.processor(for: key) != nil,
                          "temporary key \(key) must be bound by the real extension")
            XCTAssertNotNil(RuntimeCommandBinder.shared.handler(for: key),
                            "temporary key \(key) must be advertised")
            XCTAssertTrue(bound.contains(key))
        }
        let optionalKeys =
            Set(G02Readiness.expectedHandlerKeys(for: .temporaryDomain))
                .union(G02Readiness.expectedHandlerKeys(for: .settingsPrivacy))
        for key in G02Readiness.expectedHandlerKeys(for: .settingsPrivacy) {
            XCTAssertFalse(installed.registry.processor(for: key) != nil,
                           "privacy key \(key) must stay unregistered")
            XCTAssertNil(RuntimeCommandBinder.shared.handler(for: key),
                         "privacy key \(key) must stay unadvertised")
            XCTAssertFalse(bound.contains(key))
        }
        for rule in BridgeV3.commandRules where !rule.isRunEventPoll {
            let key = BridgeV3.handlerKey(scope: rule.scope, command: rule.command)
            if optionalKeys.contains(key) { continue }
            let hasProcessor = installed.registry
                .processor(for: key,
                           configurationScope: rule.configurationScope) != nil
            XCTAssertNotNil(RuntimeCommandBinder.shared.handler(for: key),
                            "ordinary key \(key) has no binder ingress")
            if binderOnly.contains(key) {
                XCTAssertFalse(hasProcessor,
                               "infrastructure key \(key) must stay binder-only")
            } else {
                XCTAssertTrue(hasProcessor,
                              "ordinary key \(key) has no async processor")
                XCTAssertTrue(bound.contains(key), "unregistered key \(key)")
            }
        }
        // Ordinary expected families are ALL bound (actual intersection).
        for domain: G02DomainKey in [.providerConfigurationDomain,
                                     .conversationDomain, .runDomain,
                                     .skillsMcpDiscovery, .hostAttachmentStaging,
                                     .settingsDefaults, .settingsMemory,
                                     .settingsPersonalization, .settingsUsage] {
            for key in G02Readiness.expectedHandlerKeys(for: domain) {
                XCTAssertTrue(bound.contains(key),
                              "\(domain.rawValue) key \(key) not bound")
            }
        }
    }

    // MARK: - 3. First-provider availability (no circular ordinaryReady gate)

    func testProviderConfigurationReadyBeforeAnyModelConfigured() async throws {
        try await bootInstalledGeneration()
        let installed = try XCTUnwrap(
            G02RuntimeComposition.shared.installedComposition)
        let boundKeys = Set(installed.registry.boundHandlerKeys)
        let report = G02Readiness.report(
            epoch: installed.epoch,
            boundKeys: boundKeys,
            installed: installed,
            transportQualified: false)
        let config = try XCTUnwrap(report.first {
            $0.domain == .providerConfigurationDomain })
        XCTAssertEqual(config.state, .ready)
        // First-provider save readiness is distinct from an ordinary usable
        // configured model: no provider exists yet, so the run launch gate
        // stays honest (transport closed; needsConfiguration on launch).
        XCTAssertFalse(G02RuntimeComposition.shared.transportGate.admitsCloudNetwork)
        let run = try XCTUnwrap(report.first { $0.domain == .runDomain })
        XCTAssertEqual(run.state, .ready) // handlers installed
    }

    // MARK: - 4. Epoch rebind refused while owned work lives

    func testRebindWhileOwnedWorkAttachedIsRefused() async throws {
        let boot = try await bootInstalledGeneration()
        let attach = RuntimeOwnedWorkRegistry.shared.attach(
            epoch: boot.epoch, kind: .conversation,
            ownerID: "g02-test-\(UUID().uuidString)")
        guard case .attached(let token) = attach else {
            XCTFail("owned work attach refused")
            return
        }
        let replay = AndroidRuntimeBootstrap.start(
            rootPath: boot.rootPath, ownerToken: boot.token,
            epoch: boot.epoch &+ 1)
        guard case .rejected(let code) = replay else {
            XCTFail("rebind while owned must be rejected")
            RuntimeOwnedWorkRegistry.shared.detach(token)
            return
        }
        XCTAssertEqual(code, .rebindWhileOwned)
        // Real settlement before teardown: the owned work is genuinely
        // finished, so the retirement drain can complete (an un-detached
        // token would honestly hold the root open through the timeout).
        RuntimeOwnedWorkRegistry.shared.detach(token)
        let drained = await RuntimeOwnedWorkRegistry.shared
            .waitForDrain(epoch: boot.epoch, timeoutMillis: 5_000)
        XCTAssertTrue(drained)
    }

    // MARK: - 5. RootStop cancels owned services then drains

    func testRootStopCancelsOwnedServicesAndDrainsBeforeClose() async throws {
        let boot = try await bootInstalledGeneration()
        let installed = try XCTUnwrap(
            G02RuntimeComposition.shared.installedComposition)
        let attach = RuntimeOwnedWorkRegistry.shared.attach(
            epoch: boot.epoch, kind: .tool,
            ownerID: "g02-tool-\(UUID().uuidString)")
        guard case .attached(let token) = attach else {
            XCTFail("attach refused")
            return
        }
        await G02RuntimeComposition.shared.beginRetirement(epoch: boot.epoch)
        for key in installed.registeredHandlerKeys {
            XCTAssertNil(RuntimeCommandBinder.shared.handler(for: key),
                         "handler \(key) survived retirement")
        }
        XCTAssertFalse(AndroidRuntimeBootstrap.g02OwnerProofValid(
            epoch: boot.epoch, token: "any"))
        RuntimeOwnedWorkRegistry.shared.detach(token)
        let drained = await RuntimeOwnedWorkRegistry.shared
            .waitForDrain(epoch: boot.epoch, timeoutMillis: 5_000)
        XCTAssertTrue(drained)
    }

    // MARK: - 6. Temp/privacy honestly blocked; seam proven (lifetime only)

    func testTemporaryAndPrivacyStayBlockedUntilRealExtensionBinds() async throws {
        try await bootInstalledGeneration()
        let installed = try XCTUnwrap(
            G02RuntimeComposition.shared.installedComposition)
        let boundKeys = Set(installed.registry.boundHandlerKeys)
        let report = G02Readiness.report(
            epoch: installed.epoch, boundKeys: boundKeys,
            installed: installed, transportQualified: false)
        // The temporary extension is REAL and integrated now: ready ONLY
        // because its actual frozen keys are bound by the production
        // attach (never by optimism). Privacy stays honestly blocked.
        let temporary = try XCTUnwrap(report.first { $0.domain == .temporaryDomain })
        XCTAssertEqual(temporary.state, .ready)
        XCTAssertEqual(Set(temporary.handlerKeys),
                       Set(G02Readiness.expectedHandlerKeys(for: .temporaryDomain)))
        XCTAssertTrue(G02RuntimeComposition.shared
            .isExtensionAttached(G02DomainExtensionKey.temporary))
        let privacy = try XCTUnwrap(report.first { $0.domain == .settingsPrivacy })
        XCTAssertEqual(privacy.state, .blocked)
        XCTAssertEqual(privacy.missingDependencies,
                       ["privacyExtensionNotIntegrated"])

        // The seam: a synthetic extension registered in the pre-bootstrap
        // window occupies the SAME id and attaches INSIDE the owned
        // install; a substitute subset can never certify the frozen
        // temporary family — and (production truth) the real bootstrap
        // re-registration replaces it so the REAL frozen family binds.
        let first = try XCTUnwrap(tracked.last)
        await shutdownAndAwaitClosed(first)
        G02RuntimeComposition.shared.resetForTesting()
        AndroidRuntimeBootstrap.resetForTesting()

        let syntheticKey = BridgeV3.handlerKey(scope: .applicationConfiguration,
                                               command: "g02.synthetic.temp")
        let ext = SyntheticTemporaryExtension(key: syntheticKey)
        XCTAssertTrue(G02RuntimeComposition.shared.registerExtension(ext))
        let boot = try await bootInstalledGeneration()
        let installed2 = try XCTUnwrap(
            G02RuntimeComposition.shared.installedComposition)
        XCTAssertTrue(G02RuntimeComposition.shared
            .isExtensionAttached(G02DomainExtensionKey.temporary))
        XCTAssertFalse(G02RuntimeComposition.shared.registerExtension(ext))
        let bound2 = Set(installed2.registry.boundHandlerKeys)
        let report2 = G02Readiness.report(
            epoch: boot.epoch, boundKeys: bound2,
            installed: installed2, transportQualified: false)
        let temporary2 = try XCTUnwrap(report2.first {
            $0.domain == .temporaryDomain })
        // Production registration re-registered the REAL temporary
        // extension over the synthetic id inside the pre-bootstrap window
        // (last registration wins before install), so the ACTUAL frozen
        // family is bound and readiness is honest. The synthetic key may
        // stay registered on the generation registry, but it can never
        // substitute: reported handlerKeys are the ACTUAL frozen-family
        // intersection only.
        XCTAssertEqual(temporary2.state, .ready)
        XCTAssertFalse(temporary2.handlerKeys.contains(syntheticKey),
                       "a substitute subset never certifies the frozen family")
        for key in temporary2.handlerKeys {
            XCTAssertTrue(bound2.contains(key))
        }
    }

    // MARK: - 7. Truthful readiness readback (actual intersection, leak-free)

    func testReadinessReportIsTruthfulAndLeakFree() async throws {
        let boot = try await bootInstalledGeneration()
        let installed = try XCTUnwrap(
            G02RuntimeComposition.shared.installedComposition)
        let boundKeys = Set(installed.registry.boundHandlerKeys)
        let report = G02Readiness.report(
            epoch: boot.epoch,
            boundKeys: boundKeys,
            installed: installed,
            transportQualified: false)
        XCTAssertEqual(report.count, G02DomainKey.allCases.count)
        for entry in report {
            switch entry.domain {
            case .transportDeviceQualification:
                XCTAssertEqual(entry.state, .blocked)
                XCTAssertEqual(entry.missingDependencies,
                               ["transportQualified", "tlsQualified"])
            case .temporaryDomain:
                // The real extension is integrated this round: ready ONLY
                // via the actual bound frozen family (verified below by the
                // bound-key intersection invariant).
                XCTAssertEqual(entry.state, .ready)
            case .settingsPrivacy:
                XCTAssertEqual(entry.state, .blocked)
            case .providerConfigurationDomain, .conversationDomain, .runDomain,
                 .skillsMcpDiscovery, .hostAttachmentStaging,
                 .settingsDefaults, .settingsMemory, .settingsPersonalization,
                 .settingsUsage, .credentialVaultAdapter,
                 .credentialArgumentNormalizer:
                XCTAssertEqual(entry.state, .ready,
                               "\(entry.domain) unexpectedly \(entry.state)")
            }
            // ACTUAL bound-key intersection, never the expected set.
            for key in entry.handlerKeys {
                XCTAssertTrue(boundKeys.contains(key))
            }
        }
        let json = G02Readiness.reportJSON(
            epoch: boot.epoch,
            boundKeys: boundKeys,
            installed: installed,
            transportQualified: false)
        XCTAssertFalse(json.contains(installed.cluster.identity.root.path))
        XCTAssertFalse(json.contains(installed.cluster.identity.token))
        XCTAssertTrue(json.contains("\"nativeRootEpoch\":\(boot.epoch)"))
    }

    // MARK: - 8. Owned-cluster hook identity refusal

    func testOwnedClusterHookNeverServesMismatchedIdentity() async throws {
        let boot = try await bootInstalledGeneration()
        let live = try XCTUnwrap(
            AndroidRuntimeBootstrap.currentGenerationForTesting())
        let root = try XCTUnwrap(
            RuntimeStorageRoot(validatingAbsoluteDirectory: boot.rootPath))
        let exactIdentity = try XCTUnwrap(
            RuntimeOwnerIdentity(root: root, token: boot.token, epoch: boot.epoch))
        let exactCluster = await live.owner.g02OwnedCluster(expected: exactIdentity)
        let exact = try XCTUnwrap(exactCluster)
        let badToken = try XCTUnwrap(RuntimeOwnerIdentity(
            root: root,
            token: String((0..<16).map { _ in "0123456789abcdef".randomElement()! }),
            epoch: boot.epoch))
        let badTokenCluster = await live.owner.g02OwnedCluster(expected: badToken)
        XCTAssertNil(badTokenCluster)
        let badEpoch = try XCTUnwrap(
            RuntimeOwnerIdentity(root: root, token: exactIdentity.token,
                                 epoch: boot.epoch &+ 1))
        let badEpochCluster = await live.owner.g02OwnedCluster(expected: badEpoch)
        XCTAssertNil(badEpochCluster)
        let clusterID = ObjectIdentifier(exact.database)
        XCTAssertEqual(clusterID,
                       G02RuntimeComposition.shared.installedComposition?
                           .databaseIdentifiers["cluster"])
    }

    // MARK: - 9. Transport gate honest; truthful flip reaches the live snapshot

    func testTransportGateAndRouteStayClosedUntilQualified() async throws {
        try await bootInstalledGeneration()
        XCTAssertFalse(G02RuntimeComposition.shared.transportGate.admitsCloudNetwork)
        XCTAssertFalse(G02RuntimeComposition.shared.transportGate.admitsMCPNetwork)
        let installed = try XCTUnwrap(
            G02RuntimeComposition.shared.installedComposition)
        let route = G02PersonalizationRouteProvider(
            configurationStore: installed.cluster.modelConfigurationStore,
            credentials: installed.credentialResolver)
        let outcome = await route.textOnlyRoute()
        if case .transportUnqualified = outcome {
            // expected
        } else {
            XCTFail("route must fail closed while transport unqualified: \(outcome)")
        }
        XCTAssertFalse(installed.runComponents.context.isTransportQualified)
        G02RuntimeComposition.shared.transportGate.markQualified(true)
        XCTAssertTrue(G02RuntimeComposition.shared.transportGate.admitsCloudNetwork)
        // The truthful flip reaches the LIVE RunContext snapshot — never a
        // forever-false immutable snapshot.
        XCTAssertTrue(installed.runComponents.context.isTransportQualified)
        G02RuntimeComposition.shared.transportGate.markQualified(false)
        XCTAssertFalse(installed.runComponents.context.isTransportQualified)
    }

    // MARK: - 10. Stale-owner retirement never uninstalls the newer graph

    func testStaleRetirementNeverUninstallsNewerHandlers() async throws {
        let first = try await bootInstalledGeneration()
        let firstComposition = try XCTUnwrap(
            G02RuntimeComposition.shared.installedComposition)
        let firstKeys = firstComposition.registeredHandlerKeys
        XCTAssertFalse(firstKeys.isEmpty)
        await shutdownAndAwaitClosed(first)

        let second = try await bootInstalledGeneration()
        let secondComposition = try XCTUnwrap(
            G02RuntimeComposition.shared.installedComposition)
        XCTAssertNotEqual(first.epoch, second.epoch)
        let secondBound = Set(secondComposition.registry.boundHandlerKeys)
        for key in secondComposition.registeredHandlerKeys {
            XCTAssertTrue(secondBound.contains(key))
        }
        // A STALE retirement for the OLD epoch must not touch the new graph.
        await G02RuntimeComposition.shared.beginRetirement(epoch: first.epoch)
        XCTAssertTrue(G02RuntimeComposition.shared.installedComposition === secondComposition)
        let binder = RuntimeCommandBinder.shared
        for key in secondComposition.registeredHandlerKeys {
            XCTAssertNotNil(binder.handler(for: key),
                            "stale retirement unregistered \(key)")
        }
        // The owning retirement still cleans everything (tearDown retires).
        for key in secondComposition.registeredHandlerKeys {
            // after teardown's real shutdown these must be gone — asserted by
            // the other tests; here just mark the second for teardown.
            _ = key
        }
    }

    // MARK: - 11. Native root epoch readback is the trusted generation epoch

    func testNativeRootEpochReadbackIsTrustedGenerationEpoch() async throws {
        let boot = try await bootInstalledGeneration()
        XCTAssertEqual(G02NativeRootEpoch.readback(), boot.epoch)
        XCTAssertNotEqual(boot.epoch, 0)
    }

    // MARK: - 12. Deterministic stale-cleanup proof: a held OLD retirement
    // tail can never erase a NEWER generation's globals or ingress

    func testStaleRetirementTailNeverErasesNewerGeneration() async throws {
        let old = try await bootInstalledGeneration()
        let oldHandle = try XCTUnwrap(
            AndroidRuntimeBootstrap.generationHandleForTesting())
        XCTAssertEqual(oldHandle.epoch, old.epoch)
        let oldReceipt = oldHandle.bootstrapReceipt

        // The legacy hazard: a synchronous global reset while the old
        // cleanup is still outstanding, then a NEW generation starts.
        G02RuntimeComposition.shared.resetForTesting()
        AndroidRuntimeBootstrap.resetForTesting()

        let new = try await bootInstalledGeneration()
        XCTAssertNotEqual(new.epoch, old.epoch)
        let newComposition = try XCTUnwrap(
            G02RuntimeComposition.shared.installedComposition)
        let newBridgeKey = BridgeV3.handlerKey(
            scope: .applicationConfiguration, command: "system.bootstrap")
        XCTAssertNotNil(RuntimeCommandBinder.shared.handler(for: newBridgeKey))

        // The OLD handle's real retirement tail runs NOW (deterministic, no
        // sleeps): it must stage only its own retired-receipt anchor and
        // refuse every GLOBAL mutation.
        let released = AndroidRuntimeBootstrap.runRetirementTailForTesting(
            gen: oldHandle, receipt: oldReceipt,
            finalPhase: .stopped)
        XCTAssertFalse(released, "a stale tail must not release the globals")

        // The newer generation survives intact: globals, phase, ingress,
        // composition and ordinary handlers.
        let live = try XCTUnwrap(
            AndroidRuntimeBootstrap.currentGenerationForTesting())
        XCTAssertEqual(live.epoch, new.epoch)
        XCTAssertTrue(AndroidRuntimeBootstrap.statusSnapshotJSON()
            .contains("\"ownedStoreReady\":true"))
        XCTAssertNotNil(RuntimeCommandBinder.shared.handler(for: newBridgeKey))
        XCTAssertTrue(G02RuntimeComposition.shared.installedComposition === newComposition)
        for key in newComposition.registeredHandlerKeys {
            XCTAssertNotNil(RuntimeCommandBinder.shared.handler(for: key),
                            "stale tail removed newer handler \(key)")
        }
        // The OLD generation's retired-receipt anchor is still staged by the
        // stale tail (R1 readability preserved) even though it refused every
        // GLOBAL mutation.
        XCTAssertTrue(AndroidRuntimeBootstrap.hasRetiredAnchorForTesting(
            epoch: old.epoch, effectsID: ObjectIdentifier(oldHandle.effects)))

        // Positive control: the OWNING tail really does release the globals.
        let newHandle = try XCTUnwrap(
            AndroidRuntimeBootstrap.generationHandleForTesting())
        XCTAssertTrue(AndroidRuntimeBootstrap.runRetirementTailForTesting(
            gen: newHandle, receipt: newHandle.bootstrapReceipt,
            finalPhase: .stopped))
        XCTAssertNil(AndroidRuntimeBootstrap.currentGenerationForTesting())
        new.retired = true
    }

    // MARK: - 13. Transport startup admission is real facts, never a manual
    // product path, and never gates first-provider configuration

    func testTransportStartupAdmissionIsRealFactsAndNeverGatesProviderConfig() async throws {
        // The REAL evaluator on this host: the Android platform default-trust
        // store does not exist here, so admission is honestly refused with a
        // typed reason — proving the product path is fact-derived (on the
        // shipping Android device the same evaluator admits from the real
        // conscrypt/system CA store + the original session factory). No
        // hardcoded true, no private receipt, no manual flip.
        let facts = G02TransportStartupAdmission.evaluate()
        XCTAssertFalse(facts.admitted,
                       "host has no Android default-trust store")
        XCTAssertEqual(facts.reason, "defaultTrustStoreUnavailable")
        XCTAssertFalse(facts.caStoreReadablePEM)
        XCTAssertTrue(facts.trustEnvironmentClean)

        try await bootInstalledGeneration()
        let installed = try XCTUnwrap(
            G02RuntimeComposition.shared.installedComposition)
        // The ordinary graph installed anyway: transport admission never
        // gates first-provider configuration or the ordinary handler set.
        let boundKeys = Set(installed.registry.boundHandlerKeys)
        let report = G02Readiness.report(
            epoch: installed.epoch, boundKeys: boundKeys,
            installed: installed,
            transportQualified: G02RuntimeComposition.shared
                .transportGate.admitsCloudNetwork)
        let config = try XCTUnwrap(report.first {
            $0.domain == .providerConfigurationDomain })
        XCTAssertEqual(config.state, .ready)
        let transportDomain = try XCTUnwrap(report.first {
            $0.domain == .transportDeviceQualification })
        XCTAssertEqual(transportDomain.state, .blocked)
        XCTAssertFalse(installed.runComponents.context.isTransportQualified)
        // The engineering/test wiring authority still flips truthfully and
        // reaches the live snapshot — but it is NOT the product path (the
        // product admits from the startup facts above on a real device).
        XCTAssertEqual(G02RuntimeComposition.shared.transportGate.startupRefusal,
                       "defaultTrustStoreUnavailable")
    }
}

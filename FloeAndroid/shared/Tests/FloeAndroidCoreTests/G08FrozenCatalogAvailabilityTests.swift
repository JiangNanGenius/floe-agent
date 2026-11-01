// SPDX-License-Identifier: MPL-2.0
//
// Focused regression for the dynamic offered-catalog identity (batch41
// screenshot refusal). The App platform host republishes a SAME-generation
// availability mask when a real layer becomes usable while a run is live
// (task arm, screen scope, Accessibility/service state, selected roots). The
// runtime must not freeze the first dispatch's catalog names for the rest of
// the run: doing so made a tool that the very next provider request really
// offered fail with "This tool is not part of the task's offered catalog"
// before the host ever saw the call.
//
// Authored-only for the private patch; the integration lane compiles it with
// the shared package. No device, permission, credential or network is used.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeSecurity
import FloeTools
@testable import FloeAgentRuntime

final class G08FrozenCatalogAvailabilityTests: XCTestCase {

    /// Executor double whose catalog grows exactly like the platform host's
    /// same-epoch availability publish: one already-installed name becomes
    /// usable. Nothing is registered, granted or approved here.
    private final class GrowingCatalogExecutor: ToolExecutor, @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String]
        private var executed: [String] = []

        init(names: [String]) { self.names = names }

        func makeAvailable(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            if !names.contains(name) { names.append(name) }
        }

        var executedNames: [String] {
            lock.lock(); defer { lock.unlock() }
            return executed
        }

        private func descriptors() -> [ToolCatalog.Descriptor] {
            lock.lock(); defer { lock.unlock() }
            return names.map {
                ToolCatalog.Descriptor(
                    name: $0,
                    toolDescription: "synthetic",
                    parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
                    riskLabels: [],
                    isSideEffecting: false)
            }
        }

        /// Synchronous on purpose: `NSLock.lock()` is unavailable from an
        /// async context under Swift 6. The async `execute` only calls this
        /// helper, never the lock directly.
        private func record(_ name: String) {
            lock.lock()
            executed.append(name)
            lock.unlock()
        }

        var allDescriptors: [ToolCatalog.Descriptor] { descriptors() }

        func descriptor(named name: String) -> ToolCatalog.Descriptor? {
            descriptors().first { $0.name == name }
        }

        func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            record(call.toolName)
            return ToolResult(callID: call.id, status: .ok,
                              outputSummary: "ok", outputDigest: "")
        }
    }

    /// Minimal local adapter: the test never starts a model turn. Kept local
    /// so this file does not depend on another test-support declaration.
    private struct QuietProviderAdapter: ProviderAdapter {
        let protocolKind: ModelProtocol = .openAIChatCompletions

        func stream(
            request: ProviderStreamRequest,
            credentials: ProviderCredentials
        ) -> AsyncThrowingStream<AgentEvent, Error> {
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }

        func listModels(
            provider: ProviderProfile,
            credentials: ProviderCredentials
        ) async throws -> [ModelProfile] {
            []
        }
    }

    private func makeRuntime(executor: GrowingCatalogExecutor,
                             ceiling: Set<String>? = nil) -> FloeAgentRuntime {
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://example.invalid")!)
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "model-a",
            displayName: "Model A",
            limits: ModelLimits(contextTokens: 1024, maxOutputTokens: 256))
        return FloeAgentRuntime(
            configuration: .init(provider: provider, model: model,
                                 allowedToolNames: ceiling),
            adapter: QuietProviderAdapter(),
            policy: TaskFullAccessPolicy(),
            executor: executor)
    }

    func testOfferedCatalogIdentityTracksSameEpochAvailabilityGrowth() async {
        let executor = GrowingCatalogExecutor(names: ["alpha.observe", "alpha.act"])
        let runtime = makeRuntime(executor: executor)

        // First use is the run's first tool dispatch (system.access.status in
        // the batch41 flow). It must not become the identity for the rest of
        // the run. Await outside the assertion: XCTAssert* takes an autoclosure.
        let before = await runtime.runtimeVisibleCatalogNameSet()
        XCTAssertEqual(before, Set(["alpha.act", "alpha.observe"]))

        // Same live root epoch; the host only republished its usable subset.
        executor.makeAvailable("alpha.screenshot")

        let after = await runtime.runtimeVisibleCatalogNameSet()
        XCTAssertTrue(
            after.contains("alpha.screenshot"),
            "A same-generation availability publish must reach the dispatch identity; "
                + "caching the first snapshot makes the App refuse a tool it really offered.")
    }

    /// The live recomputation must still be the run's RESOLVED catalog: a
    /// name outside the configured ceiling stays invisible even when the
    /// executor later reports it usable, and a name the ceiling allows enters
    /// only when the live catalog really offers it.
    func testLiveIdentityStillAppliesTheConfiguredCeiling() async {
        let executor = GrowingCatalogExecutor(
            names: ["alpha.observe", "alpha.unrelated"])
        let runtime = makeRuntime(
            executor: executor,
            ceiling: Set(["alpha.observe", "alpha.screenshot"]))

        let before = await runtime.runtimeVisibleCatalogNameSet()
        XCTAssertEqual(before, Set(["alpha.observe"]))

        executor.makeAvailable("alpha.screenshot")
        executor.makeAvailable("alpha.unrelated")

        let after = await runtime.runtimeVisibleCatalogNameSet()
        XCTAssertEqual(after, Set(["alpha.observe", "alpha.screenshot"]))
        XCTAssertEqual(executor.executedNames, [])
    }
}

// FloeExecutionTests — native professional web.search authority and routing.
// Every runner is local and deterministic: no credentials or paid requests.

import Foundation
import Testing
@testable import FloeTools
@testable import FloeExecution

@Suite("FloeExecution.ProfessionalWebSearchRouting", .serialized)
struct ProfessionalWebSearchRoutingTests {
    private final class QueryRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var queries: [String] { lock.withLock { storage } }
        func append(_ query: String) { lock.withLock { storage.append(query) } }
    }

    private actor AsyncGate {
        private var signalled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if signalled { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func signal() {
            signalled = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    private static func output(_ content: String) throws -> ToolExecutionOutput {
        let summary = String(decoding: try JSONSerialization.data(
            withJSONObject: ["contentState": "professionalDatasetSummary", "content": content],
            options: [.sortedKeys]
        ), as: UTF8.self)
        return ToolExecutionOutput(summary: summary, fullOutputSHA256: "synthetic")
    }

    @discardableResult
    private func register(
        registry: ToolRunnerRegistry,
        id: UUID,
        name: String,
        recorder: QueryRecorder,
        result: String? = nil
    ) -> ProfessionalSearchAuthority.Account {
        ProfessionalSearchAuthority.register(
            serverID: id, displayName: name, registry: registry
        ) { data, _ in
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let query = object?["query"] as? String ?? ""
            recorder.append(query)
            return try Self.output(result ?? "\(name):\(query)")
        }
    }

    private func authority(
        _ registry: ToolRunnerRegistry,
        allowed: Set<String>? = [WebSearchTool.name],
        allows: Bool = true
    ) -> ProfessionalSearchAuthority.Frozen {
        ProfessionalSearchAuthority.freeze(
            registry: registry,
            allowedToolNames: allowed,
            allowsProfessionalSource: allows
        )
    }

    private func context(
        _ authority: ProfessionalSearchAuthority.Frozen?,
        allowed: Set<String>? = [WebSearchTool.name],
        catalog: Set<String>? = [WebSearchTool.name]
    ) -> ToolContext {
        ToolContext(
            runID: UUID(), allowedToolNames: allowed,
            professionalSearchAuthority: authority,
            cancellation: CancellationToken(), frozenEffectiveCatalogNames: catalog
        )
    }

    private func tool(_ registry: ToolRunnerRegistry) -> WebSearchTool {
        WebSearchTool(
            service: WebSearchService(),
            professional: MCPRegistryProfessionalSearchExecutor(registry: registry)
        )
    }

    @Test("Native read schema and public-web defaults stay stable")
    func nativeClassificationAndValidation() throws {
        let descriptor = AnyAgentTool(WebSearchTool(service: WebSearchService())).descriptor
        #expect(descriptor.name == "web.search")
        #expect(descriptor.effect == .readOnly)
        #expect(!descriptor.isSideEffecting)
        #expect(descriptor.riskLabels == [.networkAccess])
        #expect(WebSearchTool.defaultMaxResults == 5)
        #expect(try WebSearchTool.parsedSource(nil) == .web)
        #expect(try WebSearchTool.parsedSource("web") == .web)
        #expect(try WebSearchTool.parsedSource("professional") == .professional)
        #expect(throws: (any Error).self) {
            try WebSearchTool.parsedSource("Professional")
        }
        let native = WebSearchTool(service: WebSearchService())
        try native.validate(.init(query: "天气", source: "web"))
        try native.validate(.init(query: "公司档案", source: "professional"))
        #expect(throws: (any Error).self) {
            try native.validate(.init(query: "公司档案", maxResults: 5, source: "professional"))
        }
        #expect(throws: (any Error).self) {
            try native.validate(.init(query: "公司档案", mode: "deep", source: "professional"))
        }
    }

    @Test("Exact frozen account and query are selected with no alias or fallback")
    func exactAccountAndQueryRouting() async throws {
        let registry = ToolRunnerRegistry()
        let recorder = QueryRecorder()
        let alphaID = UUID()
        let betaID = UUID()
        register(registry: registry, id: alphaID, name: "Alpha", recorder: recorder)
        register(registry: registry, id: betaID, name: "Beta", recorder: recorder)
        let authority = authority(registry)
        let native = tool(registry)
        let context = context(authority)

        await #expect(throws: (any Error).self) {
            try await native.execute(.init(query: "ambiguous", source: "professional"), context: context)
        }
        #expect(recorder.queries.isEmpty)
        let betaQuery = "司法案例：车辆贬值损失 裁判观点"
        let beta = try await native.execute(
            .init(query: betaQuery, provider: "Beta", source: "professional"),
            context: context
        )
        #expect(beta.summary.contains("Beta:\(betaQuery)"))
        #expect(recorder.queries == [betaQuery])
        let alphaQuery = "企业工商：腾讯 公司档案"
        _ = try await native.execute(
            .init(query: alphaQuery, provider: alphaID.uuidString, source: "professional"),
            context: context
        )
        #expect(recorder.queries == [betaQuery, alphaQuery])
        for deniedProvider in ["missing", VolcengineProfessionalSearch.toolName(for: MCPServerConfiguration(
            id: alphaID,
            displayName: VolcengineProfessionalSearch.displayName,
            endpoint: VolcengineProfessionalSearch.endpoint,
            authentication: .customHeader,
            credentialHeaderName: VolcengineProfessionalSearch.credentialHeaderName
        ))] {
            await #expect(throws: (any Error).self) {
                try await native.execute(
                    .init(query: "no fallback", provider: deniedProvider, source: "professional"),
                    context: context
                )
            }
        }
        #expect(recorder.queries == [betaQuery, alphaQuery])
    }

    @Test("Missing, explicit-denied and public-only authority fail before the runner")
    func deniedAuthorityNeverExecutes() async throws {
        let registry = ToolRunnerRegistry()
        let recorder = QueryRecorder()
        register(registry: registry, id: UUID(), name: "Alpha", recorder: recorder)
        let native = tool(registry)
        let arguments = WebSearchTool.Arguments(query: "query", source: "professional")
        let missingContext = context(nil)
        await #expect(throws: (any Error).self) {
            try await native.execute(arguments, context: missingContext)
        }
        let noNames = authority(registry, allowed: [])
        #expect(!noNames.allowsProfessionalSource)
        #expect(noNames.accounts.isEmpty)
        let noNamesContext = context(noNames, allowed: [], catalog: [])
        await #expect(throws: (any Error).self) {
            try await native.execute(arguments, context: noNamesContext)
        }
        let restricted = authority(registry, allows: false)
        #expect(!restricted.allowsProfessionalSource)
        #expect(restricted.accounts.isEmpty)
        let restrictedContext = context(restricted)
        await #expect(throws: (any Error).self) {
            try await native.execute(arguments, context: restrictedContext)
        }
        var publicOnly = context(authority(registry))
        publicOnly.publicWebOnly = true
        await #expect(throws: (any Error).self) {
            try await native.execute(arguments, context: publicOnly)
        }
        #expect(recorder.queries.isEmpty)
    }

    @Test("New, replaced and removed accounts cannot widen or revive a frozen run")
    func registrationLifetimeIsFrozen() async throws {
        let registry = ToolRunnerRegistry()
        let recorder = QueryRecorder()
        let oldID = UUID()
        let newID = UUID()
        let old = register(registry: registry, id: oldID, name: "Old", recorder: recorder)
        let frozen = authority(registry)
        let native = tool(registry)
        let context = context(frozen)
        let new = register(registry: registry, id: newID, name: "New", recorder: recorder)
        #expect(MCPRegistryProfessionalSearchExecutor(registry: registry)
            .instances(context: context) == [old])
        await #expect(throws: (any Error).self) {
            try await native.execute(
                .init(query: "new account", provider: newID.uuidString, source: "professional"),
                context: context
            )
        }
        ProfessionalSearchAuthority.unregister(serverID: oldID, registry: registry)
        await #expect(throws: (any Error).self) {
            try await native.execute(.init(query: "removed", source: "professional"), context: context)
        }
        let replacement = register(registry: registry, id: oldID, name: "Old", recorder: recorder)
        #expect(replacement.registrationGeneration > old.registrationGeneration)
        #expect(replacement.serverID == old.serverID)
        await #expect(throws: (any Error).self) {
            try await native.execute(.init(query: "replaced", source: "professional"), context: context)
        }
        #expect(recorder.queries.isEmpty)
        let nextRun = authority(registry)
        #expect(Set(nextRun.accounts.map(\.serverID)) == [oldID, newID])
        #expect(nextRun.accounts.contains(new))
    }

    @Test("Unregister or replacement during await invalidates the late result")
    func lateResultsAreSuppressed() async throws {
        for replace in [false, true] {
            let registry = ToolRunnerRegistry()
            let id = UUID()
            let started = AsyncGate()
            let release = AsyncGate()
            ProfessionalSearchAuthority.register(
                serverID: id, displayName: "Blocking", registry: registry
            ) { [started, release] _, _ in
                await started.signal()
                await release.wait()
                return try Self.output("late result must not escape")
            }
            let native = tool(registry)
            let callContext = context(authority(registry))
            let call = Task {
                try await native.execute(
                    .init(query: "in flight", source: "professional"),
                    context: callContext
                )
            }
            await started.wait()
            ProfessionalSearchAuthority.unregister(serverID: id, registry: registry)
            if replace {
                register(registry: registry, id: id, name: "Replacement", recorder: QueryRecorder())
            }
            await release.signal()
            await #expect(throws: (any Error).self) { try await call.value }
        }
    }

    @Test("A frozen registry cannot execute through another registry's account")
    func registryIsolationAtExecution() async throws {
        let first = ToolRunnerRegistry()
        let second = ToolRunnerRegistry()
        let firstRecorder = QueryRecorder()
        let secondRecorder = QueryRecorder()
        let id = UUID()
        register(registry: first, id: id, name: "Same", recorder: firstRecorder)
        register(registry: second, id: id, name: "Same", recorder: secondRecorder)
        let frozenFirst = authority(first)
        let firstContext = context(frozenFirst)
        #expect(MCPRegistryProfessionalSearchExecutor(registry: second)
            .instances(context: firstContext).isEmpty)
        let wrongRegistryTool = tool(second)
        await #expect(throws: (any Error).self) {
            try await wrongRegistryTool.execute(
                .init(query: "wrong registry", source: "professional"),
                context: firstContext
            )
        }
        #expect(firstRecorder.queries.isEmpty && secondRecorder.queries.isEmpty)
        ProfessionalSearchAuthority.unregister(serverID: id, registry: second)
        _ = try await tool(first).execute(
            .init(query: "right registry", source: "professional"),
            context: firstContext
        )
        #expect(firstRecorder.queries == ["right registry"])
        #expect(secondRecorder.queries.isEmpty)
    }
}

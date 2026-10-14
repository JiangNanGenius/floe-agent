// FloeToolsTests — runtime-issued task authority binding (T0/T3/T4 seam).
//
// These tests exercise the real mint/validate/consume contract a T4-style
// consumer uses: evidence derived from concrete runtime values, exact binding
// comparison (target/op/payload/task/run), single-use consumption, spoof and
// replay rejection, and bounded record retention.

import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloeTools

@Suite("FloeTools.RuntimeAuthority")
struct RuntimeAuthorityTests {
    private let runID = UUID()
    private let taskID = UUID()

    private func workspace() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("floe-runtime-authority-\(UUID().uuidString)", isDirectory: true)
    }

    private func evidence(
        workspace: URL,
        canonicalTarget: String = "file:/tmp/floe/target.md",
        toolName: String = "office.edit",
        operation: String = "apply",
        operationID: String = "call-1",
        idempotencyKey: String = "op-1",
        baseRevision: String? = "sha256:base",
        payloadDigest: String = "payload-digest-1",
        grantID: UUID = UUID()
    ) -> RuntimeAuthorityEvidence {
        RuntimeAuthorityEvidence(
            runID: runID,
            taskID: taskID,
            environmentBinding: RuntimeAuthorityDigest.environmentBinding(
                workspaceRootURL: workspace,
                conversationID: taskID
            ),
            canonicalTarget: canonicalTarget,
            toolName: toolName,
            operation: operation,
            operationID: operationID,
            idempotencyKey: idempotencyKey,
            baseRevision: baseRevision,
            payloadDigest: payloadDigest,
            approvalGrantID: grantID
        )
    }

    private func binding(
        from token: RuntimeTaskAuthority,
        canonicalTarget: String? = nil,
        toolName: String? = nil,
        operation: String? = nil,
        operationID: String? = nil,
        idempotencyKey: String? = nil,
        baseRevision: String? = nil,
        payloadDigest: String? = nil,
        taskID: UUID? = nil,
        runID: UUID? = nil,
        environmentBinding: String? = nil
    ) -> RuntimeAuthorityBinding {
        RuntimeAuthorityBinding(
            runID: runID ?? token.runID,
            taskID: taskID ?? token.taskID,
            environmentBinding: environmentBinding ?? token.environmentBinding,
            canonicalTarget: canonicalTarget ?? token.canonicalTarget,
            toolName: toolName ?? token.toolName,
            operation: operation ?? token.operation,
            operationID: operationID ?? token.operationID,
            idempotencyKey: idempotencyKey ?? token.idempotencyKey,
            baseRevision: baseRevision ?? token.baseRevision,
            payloadDigest: payloadDigest ?? token.payloadDigest
        )
    }

    @Test("an issued token validates only against its exact concrete binding")
    func exactBindingValidates() async {
        let store = RuntimeAuthorityStore()
        let root = workspace()
        let token = await store.issue(evidence(workspace: root))
        let result = await store.validate(token, binding: binding(from: token))
        #expect(result == .valid)
    }

    @Test("a structurally identical token that was never issued is unknown")
    func forgedTwinIsUnknown() async {
        let store = RuntimeAuthorityStore()
        let root = workspace()
        let issued = await store.issue(evidence(workspace: root))
        // A model cannot build this value, but even an in-process look-alike
        // with a different id must fail: validation is store-backed.
        let forged = RuntimeTaskAuthority(
            id: UUID(),
            runID: issued.runID,
            taskID: issued.taskID,
            environmentBinding: issued.environmentBinding,
            canonicalTarget: issued.canonicalTarget,
            toolName: issued.toolName,
            operation: issued.operation,
            operationID: issued.operationID,
            idempotencyKey: issued.idempotencyKey,
            baseRevision: issued.baseRevision,
            payloadDigest: issued.payloadDigest,
            approvalGrantID: issued.approvalGrantID,
            issuedAt: issued.issuedAt,
            expiresAt: issued.expiresAt
        )
        let result = await store.validate(forged, binding: binding(from: forged))
        #expect(result == .unknown)
    }

    @Test("a token issued by another store instance is unknown")
    func otherStoreIsUnknown() async {
        let store = RuntimeAuthorityStore()
        let other = RuntimeAuthorityStore()
        let root = workspace()
        let token = await other.issue(evidence(workspace: root))
        let result = await store.validate(token, binding: binding(from: token))
        #expect(result == .unknown)
    }

    @Test("editing any issued field invalidates the token")
    func tamperedTokenFails() async {
        let store = RuntimeAuthorityStore()
        let root = workspace()
        let token = await store.issue(evidence(workspace: root))
        let tampered = RuntimeTaskAuthority(
            id: token.id,
            runID: token.runID,
            taskID: token.taskID,
            environmentBinding: token.environmentBinding,
            canonicalTarget: "/tmp/other.md",
            toolName: token.toolName,
            operation: token.operation,
            operationID: token.operationID,
            idempotencyKey: token.idempotencyKey,
            baseRevision: token.baseRevision,
            payloadDigest: token.payloadDigest,
            approvalGrantID: token.approvalGrantID,
            issuedAt: token.issuedAt,
            expiresAt: token.expiresAt
        )
        let result = await store.validate(tampered, binding: binding(from: tampered))
        if case .mismatch = result {} else {
            Issue.record("expected mismatch, got \(result)")
        }
    }

    @Test("two equal-content files with the same base SHA do not share authority")
    func crossTargetSameContentRejected() async {
        let store = RuntimeAuthorityStore()
        let root = workspace()
        let token = await store.issue(evidence(workspace: root, canonicalTarget: "file:/tmp/a.md"))
        // Same payload digest and base revision, different canonical file.
        let other = binding(from: token, canonicalTarget: "file:/tmp/b.md")
        let result = await store.validate(token, binding: other)
        if case .mismatch = result {} else {
            Issue.record("expected mismatch for a different canonical target, got \(result)")
        }
    }

    @Test("the same target and base with a different edit command rejects")
    func alteredCommandRejected() async {
        let store = RuntimeAuthorityStore()
        let root = workspace()
        let first = try? JSONSerialization.data(withJSONObject: ["path": "/tmp/a.md", "text": "one"])
        let second = try? JSONSerialization.data(withJSONObject: ["path": "/tmp/a.md", "text": "two"])
        let digestOne = RuntimeAuthorityDigest.payloadDigest(first ?? Data())
        let digestTwo = RuntimeAuthorityDigest.payloadDigest(second ?? Data())
        #expect(digestOne != digestTwo)
        let token = await store.issue(evidence(
            workspace: root,
            canonicalTarget: "file:/tmp/a.md",
            payloadDigest: digestOne
        ))
        let result = await store.validate(token, binding: binding(from: token, payloadDigest: digestTwo))
        if case .mismatch = result {} else {
            Issue.record("expected mismatch for a different command payload, got \(result)")
        }
    }

    @Test("canonical payload digest ignores key order but not values")
    func payloadDigestCanonical() {
        let a = Data(#"{"a":1,"b":"x"}"#.utf8)
        let b = Data(#"{"b":"x","a":1}"#.utf8)
        let c = Data(#"{"b":"y","a":1}"#.utf8)
        #expect(RuntimeAuthorityDigest.payloadDigest(a) == RuntimeAuthorityDigest.payloadDigest(b))
        #expect(RuntimeAuthorityDigest.payloadDigest(a) != RuntimeAuthorityDigest.payloadDigest(c))
    }

    @Test("wrong run/task/environment/operation/call/idempotency/base bindings all reject")
    func everyBindingDimensionEnforced() async {
        let store = RuntimeAuthorityStore()
        let root = workspace()
        let token = await store.issue(evidence(workspace: root))
        let wrongCases: [(String, RuntimeAuthorityBinding)] = [
            ("run", binding(from: token, runID: UUID())),
            ("task", binding(from: token, taskID: UUID())),
            ("environment", binding(from: token, environmentBinding: "task:x|ws:y")),
            ("target", binding(from: token, canonicalTarget: "file:/tmp/evil.md")),
            ("tool", binding(from: token, toolName: "document.pdf.edit")),
            ("operation", binding(from: token, operation: "export")),
            ("callID", binding(from: token, operationID: "call-2")),
            ("idempotency", binding(from: token, idempotencyKey: "op-2")),
            ("baseRevision", binding(from: token, baseRevision: "sha256:other")),
            ("payload", binding(from: token, payloadDigest: "other-payload"))
        ]
        for (name, wrong) in wrongCases {
            let result = await store.validate(token, binding: wrong)
            if case .mismatch = result {} else {
                Issue.record("expected mismatch for wrong \(name), got \(result)")
            }
        }
    }

    @Test("consume burns a token exactly once; tampered claims never burn the real one")
    func consumeIsSingleUse() async {
        let store = RuntimeAuthorityStore()
        let root = workspace()
        let token = await store.issue(evidence(workspace: root))
        // A failed binding claim must not consume the token.
        let failed = await store.consume(token, binding: binding(from: token, canonicalTarget: "file:/tmp/evil.md"))
        if case .mismatch = failed {} else { Issue.record("expected mismatch, got \(failed)") }
        let first = await store.consume(token, binding: binding(from: token))
        #expect(first == .valid)
        let replay = await store.consume(token, binding: binding(from: token))
        #expect(replay == .alreadyConsumed)
        let validatedAfter = await store.validate(token, binding: binding(from: token))
        #expect(validatedAfter == .alreadyConsumed)
    }

    @Test("expired and revoked tokens reject")
    func expiryAndRevocation() async {
        let store = RuntimeAuthorityStore()
        let root = workspace()
        let expired = await store.issue(evidence(workspace: root), ttl: 1)
        // Evaluate one hour later instead of sleeping: the store takes an
        // explicit clock, and the token lifetime floor is one second.
        let expiredResult = await store.validate(
            expired,
            binding: binding(from: expired),
            at: Date().addingTimeInterval(3600)
        )
        #expect(expiredResult == .expired)

        let live = await store.issue(evidence(workspace: root))
        await store.revoke(id: live.id)
        let revokedResult = await store.validate(live, binding: binding(from: live))
        #expect(revokedResult == .revoked)

        let second = await store.issue(evidence(workspace: root))
        await store.revoke(runID: runID)
        let runRevoked = await store.validate(second, binding: binding(from: second))
        #expect(runRevoked == .revoked)
    }

    @Test("record retention is bounded and purge runs on every issue")
    func recordsAreBounded() async {
        let store = RuntimeAuthorityStore()
        let root = workspace()
        var tokens: [RuntimeTaskAuthority] = []
        for index in 0..<(RuntimeAuthorityStore.maxRecords + 40) {
            tokens.append(await store.issue(evidence(
                workspace: root,
                operationID: "call-\(index)",
                payloadDigest: "payload-\(index)"
            )))
        }
        let count = await store.recordCount
        #expect(count <= RuntimeAuthorityStore.maxRecords)
        // The newest token still validates; the oldest were evicted.
        let newest = tokens[tokens.count - 1]
        #expect(await store.validate(newest, binding: binding(from: newest)) == .valid)
        let oldest = tokens[0]
        let oldestResult = await store.validate(oldest, binding: binding(from: oldest))
        #expect(oldestResult == .unknown)
        let purged = await store.purgeExpired()
        #expect(purged >= 0)
    }

    @Test("binding helper derives the same environment identity from a real context")
    func contextBindingMatchesRuntimeDerivation() async {
        let store = RuntimeAuthorityStore()
        let root = workspace()
        let token = await store.issue(evidence(workspace: root))
        var context = ToolContext(
            runID: runID,
            toolCallID: "call-1",
            toolIdempotencyKey: "op-1",
            approvalGrantID: token.approvalGrantID,
            scope: .local,
            workspaceRootURL: root,
            cancellation: CancellationToken(),
            conversationID: taskID
        )
        context.runtimeAuthority = token
        let binding = context.runtimeAuthorityBinding(
            toolName: token.toolName,
            operation: token.operation,
            canonicalTarget: token.canonicalTarget,
            baseRevision: token.baseRevision,
            payloadDigest: token.payloadDigest
        )
        // A different real context (other task) derives a different
        // environment binding and is refused before any consumption.
        var other = context
        other.conversationID = UUID()
        let otherBinding = other.runtimeAuthorityBinding(
            toolName: token.toolName,
            operation: token.operation,
            canonicalTarget: token.canonicalTarget,
            baseRevision: token.baseRevision,
            payloadDigest: token.payloadDigest
        )
        let refused = await store.validate(token, binding: otherBinding)
        if case .mismatch = refused {} else { Issue.record("expected mismatch, got \(refused)") }
        // The matching real context consumes the authority exactly once.
        #expect(await context.consumeRuntimeAuthority(binding: binding, store: store) == .valid)
        #expect(await context.consumeRuntimeAuthority(binding: binding, store: store) == .alreadyConsumed)
    }

    @Test("baseRevision extraction reads declared revision keys only")
    func baseRevisionExtraction() {
        #expect(RuntimeAuthorityDigest.baseRevision(in: Data(#"{"expectedSHA256":"abc"}"#.utf8)) == "abc")
        #expect(RuntimeAuthorityDigest.baseRevision(in: Data(#"{"revision":42}"#.utf8)) == "42")
        #expect(RuntimeAuthorityDigest.baseRevision(in: Data(#"{"text":"x"}"#.utf8)) == nil)
    }
}

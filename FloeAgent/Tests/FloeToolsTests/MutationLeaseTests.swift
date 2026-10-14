// FloeToolsTests — canonical mutation leases (sibling write serialization).

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTestSupport
@testable import FloeTools

@Suite("FloeTools.MutationLease")
struct MutationLeaseTests {
    private func descriptor(
        _ name: String,
        sideEffecting: Bool = true,
        effect: ToolEffect? = nil
    ) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            riskLabels: [],
            isSideEffecting: sideEffecting,
            effect: effect
        )
    }

    @Test("different canonical files run concurrently")
    func distinctFilesDoNotBlock() async throws {
        let coordinator = MutationLeaseCoordinator()
        let first = try await coordinator.acquire(
            keys: [.file("/tmp/floe/a.md")], owner: "a", timeout: 1
        )
        let second = try await coordinator.acquire(
            keys: [.file("/tmp/floe/b.md")], owner: "b", timeout: 0.2
        )
        #expect(await coordinator.heldLeases.count == 2)
        await coordinator.release(first)
        await coordinator.release(second)
        #expect(await coordinator.isIdle())
    }

    @Test("the same canonical file serializes until the holder releases")
    func sameFileSerializes() async throws {
        let coordinator = MutationLeaseCoordinator()
        let first = try await coordinator.acquire(
            keys: [.file("/tmp/floe/a.md")], owner: "first", timeout: 1
        )
        let acquired = AsyncBool()
        let waiter = Task {
            _ = try await coordinator.acquire(
                keys: [.file("/tmp/floe/a.md")], owner: "second", timeout: 3
            )
            acquired.set(true)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(acquired.value == false)
        await coordinator.release(first)
        try await waiter.value
        #expect(acquired.value == true)
    }

    @Test("a workspace wildcard conflicts with a file inside that workspace")
    func wildcardConflictsWithFile() async throws {
        let coordinator = MutationLeaseCoordinator()
        let file = try await coordinator.acquire(
            keys: [.file("/tmp/floe/ws/a.md")], owner: "writer", timeout: 1
        )
        let acquired = AsyncBool()
        let waiter = Task {
            _ = try await coordinator.acquire(
                keys: [.workspace("/tmp/floe/ws")], owner: "shell", timeout: 3
            )
            acquired.set(true)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(acquired.value == false)
        await coordinator.release(file)
        try await waiter.value
        #expect(acquired.value == true)
    }

    @Test("a file outside the wildcard workspace does not conflict")
    func fileOutsideWildcardIsDisjoint() async throws {
        let coordinator = MutationLeaseCoordinator()
        let workspaceLease = try await coordinator.acquire(
            keys: [.workspace("/tmp/floe/ws")], owner: "shell", timeout: 1
        )
        let other = try await coordinator.acquire(
            keys: [.file("/tmp/other/a.md")], owner: "other", timeout: 0.2
        )
        await coordinator.release(workspaceLease)
        await coordinator.release(other)
    }

    @Test("a lease wait times out with an explicit error instead of deadlocking")
    func timeoutIsExplicit() async throws {
        let coordinator = MutationLeaseCoordinator()
        let held = try await coordinator.acquire(
            keys: [.file("/tmp/floe/a.md")], owner: "holder", timeout: 1
        )
        do {
            _ = try await coordinator.acquire(
                keys: [.file("/tmp/floe/a.md")], owner: "late", timeout: 0.15
            )
            Issue.record("expected a timeout")
        } catch {
            #expect(error.localizedDescription.contains("Timed out"))
        }
        await coordinator.release(held)
    }

    @Test("release is idempotent and never releases another owner's lease")
    func releaseIsOwnershipSafe() async throws {
        let coordinator = MutationLeaseCoordinator()
        let held = try await coordinator.acquire(
            keys: [.file("/tmp/floe/a.md")], owner: "holder", timeout: 1
        )
        await coordinator.release(held)
        await coordinator.release(held)
        #expect(await coordinator.isIdle())
    }

    @Test("resolver maps Shell/Python to the workspace wildcard and files to canonical paths")
    func resolverMapping() throws {
        let root = URL(fileURLWithPath: "/tmp/floe/ws")
        let shell = try TestFixtures.toolCall(id: "s", toolName: "exec.shell", arguments: #"{"command":"echo hi"}"#)
        let shellKeys = MutationTargetResolver.keys(
            for: shell,
            descriptor: descriptor("exec.shell"),
            workspaceRootURL: root
        )
        #expect(shellKeys == [.workspace("/tmp/floe/ws")])

        let write = try TestFixtures.toolCall(
            id: "w", toolName: "workspace.writeFile",
            arguments: #"{"path":"notes/a.md","text":"x"}"#
        )
        let writeKeys = MutationTargetResolver.keys(
            for: write,
            descriptor: descriptor("workspace.writeFile"),
            workspaceRootURL: root
        )
        #expect(writeKeys == [.file("/tmp/floe/ws/notes/a.md")])

        let document = try TestFixtures.toolCall(
            id: "d", toolName: "office.edit",
            arguments: #"{"documentID":"doc-42","operations":[]}"#
        )
        let documentKeys = MutationTargetResolver.keys(
            for: document,
            descriptor: descriptor("office.edit"),
            workspaceRootURL: root
        )
        #expect(documentKeys == [.document("office:doc-42")])

        let read = try TestFixtures.toolCall(id: "r")
        let readKeys = MutationTargetResolver.keys(
            for: read,
            descriptor: descriptor("test.echo", sideEffecting: false),
            workspaceRootURL: root
        )
        #expect(readKeys.isEmpty)

        let unknown = try TestFixtures.toolCall(
            id: "u", toolName: "custom.mutate",
            arguments: #"{"something":"else"}"#
        )
        let unknownKeys = MutationTargetResolver.keys(
            for: unknown,
            descriptor: descriptor("custom.mutate"),
            workspaceRootURL: root
        )
        #expect(unknownKeys == [.workspace("/tmp/floe/ws")])
    }

    @Test("a document tool with an unresolvable target falls back to the workspace wildcard")
    func unresolvedDocumentFallsBack() throws {
        let root = URL(fileURLWithPath: "/tmp/floe/ws")
        let call = try TestFixtures.toolCall(
            id: "d2", toolName: "document.pdf.edit",
            arguments: #"{"operations":[]}"#
        )
        let keys = MutationTargetResolver.keys(
            for: call,
            descriptor: descriptor("document.pdf.edit"),
            workspaceRootURL: root
        )
        #expect(keys == [.workspace("/tmp/floe/ws")])
    }

    @Test("with no workspace root the resolver conservatively uses the global wildcard")
    func globalWildcardWithoutRoot() throws {
        let call = try TestFixtures.toolCall(id: "s2", toolName: "exec.shell", arguments: #"{"command":"ls"}"#)
        let keys = MutationTargetResolver.keys(
            for: call,
            descriptor: descriptor("exec.shell"),
            workspaceRootURL: nil
        )
        #expect(keys == [.workspace("*")])
        #expect(MutationTargetKey.workspace("*").conflicts(with: .file("/anything")))
    }
}

/// Minimal lock-guarded boolean used to observe asynchronous acquisition.
private final class AsyncBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func set(_ newValue: Bool) {
        lock.lock(); defer { lock.unlock() }
        storage = newValue
    }
}

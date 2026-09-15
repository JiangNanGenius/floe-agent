import Foundation
import Testing
import FloeWorkspace

@Suite("IDE native filesystem")
struct IDEWorkspaceSessionTests {
    @Test func browserSaveCommitsAndRejectsConcurrentAgentEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("hello.php")
        try Data("<?php echo 'original';".utf8).write(to: file)
        let session = IDEWorkspaceSession(files: WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)))
        let original = try await session.handle(.init(operation: "read", path: "/hello.php"))
        #expect(original.contentBase64 != nil)
        _ = try await session.handle(.init(operation: "write", path: "/hello.php", contentBase64: Data("<?php echo 'saved';".utf8).base64EncodedString()))
        #expect(try String(contentsOf: file, encoding: .utf8) == "<?php echo 'saved';")
        try Data("agent edit".utf8).write(to: file)
        // A search reading the new disk contents cannot advance the dirty
        // editor's baseline and silently authorize overwriting the agent.
        _ = try await session.handle(.init(operation: "read", path: "/hello.php"))
        await #expect(throws: Error.self) {
            try await session.handle(.init(operation: "write", path: "/hello.php", contentBase64: Data("stale edit".utf8).base64EncodedString()))
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "agent edit")
    }

    @Test func newFileCannotReplaceUnreadFileAndClosedSessionCannotWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = IDEWorkspaceSession(files: WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)))
        let request = IDEWorkspaceSession.Request(operation: "write", path: "/hello.py", contentBase64: Data("print('中文')".utf8).base64EncodedString())
        _ = try await session.handle(request)
        let second = IDEWorkspaceSession(files: WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)))
        await #expect(throws: Error.self) { try await second.handle(request) }
        await session.close()
        await #expect(throws: Error.self) { try await session.handle(request) }
    }

    @Test func directoryOperationsAndPathGuards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = IDEWorkspaceSession(files: WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)))
        _ = try await session.handle(.init(operation: "mkdir", path: "/src"))
        _ = try await session.handle(.init(operation: "write", path: "/src/main.swift", contentBase64: Data("print(42)".utf8).base64EncodedString()))
        _ = try await session.handle(.init(operation: "rename", path: "/src", destination: "/code"))
        #expect(try await session.handle(.init(operation: "list", path: "/code")).entries?.map(\.name) == ["main.swift"])
        for path in ["/../secret", "//etc/passwd", "file:///tmp/a", "/a\0b", "/a\\b"] {
            #expect(throws: Error.self) { try IDEWorkspaceSession.relativePath(path) }
        }
        await #expect(throws: Error.self) { try await session.handle(.init(operation: "delete", path: "/")) }
        await #expect(throws: Error.self) { try await session.handle(.init(operation: "delete", path: "/code")) }
        _ = try await session.handle(.init(operation: "delete", path: "/code/main.swift"))
        _ = try await session.handle(.init(operation: "delete", path: "/code"))
    }
}

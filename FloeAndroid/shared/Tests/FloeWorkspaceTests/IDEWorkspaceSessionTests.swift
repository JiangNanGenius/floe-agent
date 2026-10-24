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
    @Test func threeWayMergePreservesIndependentEditsAndRequiresOverlappingChoices() {
        let plan = TextMergePlan(base: "one\ntwo\nthree\n", mine: "ONE\ntwo\nthree\n", current: "one\ntwo\nTHREE\n")
        #expect(plan.resolved() == "ONE\ntwo\nTHREE\n")
        let conflict = TextMergePlan(base: "a\nb\nc", mine: "a\nUSER\nc", current: "a\nAGENT\nc")
        #expect(conflict.resolved() == nil)
        #expect(conflict.conflicts.count == 1)
        if let block = conflict.conflicts.first {
            #expect(conflict.resolved([block.id: .mine]) == "a\nUSER\nc")
            #expect(conflict.resolved([block.id: .current]) == "a\nAGENT\nc")
        }
        #expect(TextMergePlan(base: "a\r\nb\r\n", mine: "A\r\nb\r\n", current: "a\r\nB\r\n").resolved() == "A\r\nB\r\n")
        #expect(TextMergePlan(base: "a\nb", mine: "a\nleft\nb", current: "a\nright\nb").conflicts.count == 1)
        #expect(TextMergePlan(base: "a\nb\nc", mine: "a\nc", current: "a\nb\nC").resolved() == "a\nC")
        #expect(TextMergePlan(base: nil, mine: "unknown base", current: "current").resolved() == nil)
    }

    @Test func reviewedResolutionRejectsAnotherAgentEditAndRetainsDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        _ = try service.createFile("notes.txt", content: "one\ntwo\nthree")
        let session = IDEWorkspaceSession(files: service)
        _ = try await session.handle(.init(operation: "read", path: "/notes.txt"))
        _ = try service.writeFile("notes.txt", content: "one\ntwo\nAGENT")
        let review = try await session.conflict(path: "/notes.txt", draft: "USER\ntwo\nthree")
        let merged = try #require(review.plan.resolved())
        #expect(merged == "USER\ntwo\nAGENT")
        let recovery = try #require(review.recoveryPath)
        #expect(try service.readFileForEditing(recovery).text == review.draft)
        // Repeating a conflict reuses a verified recovery copy.
        _ = try await session.conflict(path: "/notes.txt", draft: review.draft)
        _ = try service.writeFile("notes.txt", content: "newer agent edit")
        #expect(throws: Error.self) { try service.resolveConflict(review, content: merged) }
        await #expect(throws: Error.self) { try await session.rebase(review) }
        #expect(try service.readFileForEditing("notes.txt").text == "newer agent edit")
        #expect(try service.readFileForEditing(recovery).text == review.draft)
    }

    @Test func twoConcurrentSavesAgainstOneVersionHaveExactlyOneWinner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        _ = try service.createFile("same.txt", content: "base")
        let hash = try service.metadata("same.txt").sha256
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let independent = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
                    do { _ = try independent.writeFile("same.txt", content: "writer \(index)", expectedSHA256: hash); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        #expect(successes == 1)
    }

    @Test func deletedOriginalPreservesDraftWithoutRecreatingOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        do {
            _ = try files.editConflict(path: "deleted.txt", base: "base", draft: "unsaved text", preserveDraft: true)
            Issue.record("A missing original must not be silently recreated")
        } catch let recovery as WorkspaceDraftRecoveryError {
            #expect(try files.readFileForEditing(recovery.recoveryPath).text == "unsaved text")
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("deleted.txt").path))
        }
    }

}

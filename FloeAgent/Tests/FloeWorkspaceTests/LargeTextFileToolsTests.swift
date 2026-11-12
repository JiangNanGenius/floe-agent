// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
@testable import FloeWorkspace

@Suite("FloeWorkspace.LargeText")
struct LargeTextFileToolsTests {
    private final class Fixture: @unchecked Sendable {
        let root: URL
        let context: ToolContext
        var environment: WorkspaceToolEnvironment { WorkspaceToolEnvironment(rootProvider: { [root] in root }) }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-large-text-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            context = ToolContext(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())
        }
        func write(_ path: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        func writeData(_ path: String, _ data: Data) throws {
            try data.write(to: root.appendingPathComponent(path), options: .atomic)
        }
        func read(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        func readData(_ path: String) throws -> Data {
            try Data(contentsOf: root.appendingPathComponent(path))
        }
        deinit {
            try? FileManager.default.removeItem(at: root)
            if let support = try? FloeArtifactStore.root() {
                try? FileManager.default.removeItem(at: support.appendingPathComponent("ChangeArtifacts/\(context.runID.uuidString)"))
            }
        }
    }
    // Exactly 50,000 Chinese characters interleaved with emoji: 350,000 UTF-8 bytes.
    private var longText: String { String(repeating: "\u{6c49}\u{1f642}", count: 50_000) }
    private func field(_ name: String, in summary: String) throws -> String {
        let firstLine = summary.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let value = firstLine.split(separator: " ").first { $0.hasPrefix(name + "=") }
        return String(try #require(value).dropFirst(name.count + 1))
    }
    private func body(_ summary: String) throws -> String {
        let lines = summary.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        return lines.count == 2 ? String(lines[1]) : ""
    }

    @Test("50k Chinese plus emoji pages are complete through the tool output and byte-exact on reassembly")
    func unicodePagesAreCompleteAndByteExact() async throws {
        let f = try Fixture(); try f.write("large.txt", longText)
        let tool = WorkspaceReadFileTool(environment: f.environment)
        var assembled = Data(), offset = 0, pages = 0
        while true {
            let output = try await tool.execute(.init(path: "large.txt", offset: offset), context: f.context)
            #expect(!output.summaryTruncated)
            let text = try body(output.summary)
            let bytes = Data(text.utf8)
            #expect(!text.contains("\u{fffd}"))
            #expect(bytes.count <= 65_536)
            #expect(try field("bytes", in: output.summary) == String(bytes.count))
            #expect(try field("totalBytes", in: output.summary) == String(longText.utf8.count))
            if pages == 0 { #expect(text.count > 4_096) }
            assembled.append(bytes); pages += 1
            let next = try field("nextOffset", in: output.summary)
            if next == "none" { break }
            let parsedNext = try #require(Int(next))
            #expect(parsedNext == offset + bytes.count)
            #expect(parsedNext > offset)
            guard parsedNext > offset, pages < 16 else { Issue.record("non-progressing page"); return }
            offset = parsedNext
        }
        #expect(assembled == Data(longText.utf8))
        let service = try f.environment.makeService()
        let short = try service.readFile("large.txt", limit: 4)
        #expect(short.text == "\u{6c49}")
        #expect(short.nextOffset == 3)
        #expect(throws: WorkspaceToolError.self) { _ = try service.readFile("large.txt", byteOffset: 1) }
        #expect(throws: WorkspaceToolError.self) { _ = try service.readFile("large.txt", limit: 1) }
        let eof = try service.readFile("large.txt", byteOffset: longText.utf8.count)
        #expect(eof.nextOffset == nil && eof.bytesReturned == 0)
    }

    @Test("Long chunks pass canonical/underscore budgets; retry CAS cannot duplicate; native source finalization preserves draft")
    func chunkRetryAndNativeFinalization() async throws {
        let f = try Fixture()
        let largeArguments = try JSONSerialization.data(withJSONObject: ["path":"draft.txt", "content":longText])
        #expect(largeArguments.count > 65_536 && largeArguments.count < 1_048_576)
        for name in ["workspace.appendFile", "workspace_appendFile", "workspace.replaceText", "workspace_replaceText"] {
            #expect(toolArgumentsByteLimit(for: name) == 1_048_576)
            _ = try ToolCall(id: name, toolName: name, argumentsJSON: largeArguments, scope: .local)
        }
        #expect(toolArgumentsByteLimit(for: "workspace.readFile") == 65_536)
        #expect(toolArgumentsByteLimit(for: "workspace.deleteFile") == 65_536)
        let create = WorkspaceCreateFileTool(environment: f.environment)
        let created = try await create.execute(.init(path: "draft.txt", content: ""), context: f.context)
        var digest = try field("sha256", in: created.summary)
        let append = WorkspaceAppendFileTool(environment: f.environment)
        let chunk = String(repeating: "\u{6c49}\u{1f642}", count: 10_000)
        for index in 0..<5 {
            let originalSHA = digest
            let output = try await append.execute(.init(path: "draft.txt", content: chunk, expectedSHA256: originalSHA), context: f.context)
            digest = try field("sha256", in: output.summary)
            if index == 0 {
                do {
                    _ = try await append.execute(.init(path: "draft.txt", content: chunk, expectedSHA256: originalSHA), context: f.context)
                    Issue.record("same chunk with stale precondition must conflict")
                } catch let error as WorkspaceToolError {
                    guard case .conflict = error else { Issue.record("unexpected error: \(error)"); return }
                }
                #expect(try f.read("draft.txt") == chunk)
            }
        }
        #expect(try f.read("draft.txt") == longText)
        try f.write("target.txt", "old original")
        let service = try f.environment.makeService()
        let original = try service.metadata("target.txt")
        let tool = WorkspaceWriteFileTool(environment: f.environment)
        let output = try await tool.execute(.init(path: "target.txt", expectedSHA256: original.sha256,
            sourcePath: "draft.txt", expectedSourceSHA256: digest), context: f.context)
        #expect(output.summary.contains("saved=true"))
        #expect(try f.read("target.txt") == longText)
        #expect(try f.read("draft.txt") == longText)
        do {
            _ = try await tool.execute(.init(path: "target.txt", expectedSHA256: original.sha256,
                sourcePath: "draft.txt", expectedSourceSHA256: digest), context: f.context)
            Issue.record("repeated finalize must not overwrite the new target")
        } catch let error as WorkspaceToolError {
            guard case .conflict = error else { Issue.record("unexpected error: \(error)"); return }
        }
        // No target precondition is create-only, never a blind replacement.
        _ = try await tool.execute(.init(path: "new-final.txt", sourcePath: "draft.txt", expectedSourceSHA256: digest), context: f.context)
        #expect(try f.read("new-final.txt") == longText)
        let replaceArguments = try JSONSerialization.data(withJSONObject: ["path":"new-final.txt", "oldText":longText, "newText":longText + "end"])
        _ = try ToolCall(id: "large-replace", toolName: "workspace.replaceText", argumentsJSON: replaceArguments, scope: .local)
        _ = try await WorkspaceReplaceTextTool(environment: f.environment).execute(
            .init(path: "new-final.txt", oldText: longText, newText: longText + "end", expectedSHA256: digest), context: f.context)
        #expect(try f.read("new-final.txt") == longText + "end")
        #expect(throws: WorkspaceToolError.self) {
            try tool.validate(.init(path: "target.txt", content: "x", sourcePath: "draft.txt", expectedSourceSHA256: digest))
        }
    }

    @Test("Changed source, denied source, stale target, cancellation, size and freeze failures preserve both originals")
    func finalizationFailuresPreserveFiles() async throws {
        let f = try Fixture(); try f.write("draft.txt", longText); try f.write("target.txt", "keep me")
        let sourceSHA = WorkspaceFileService.sha256Hex(of: Data(longText.utf8))
        let targetSHA = WorkspaceFileService.sha256Hex(of: Data("keep me".utf8))
        let tool = WorkspaceWriteFileTool(environment: f.environment)
        try f.write("draft.txt", longText + "changed")
        do {
            _ = try await tool.execute(.init(path: "target.txt", expectedSHA256: targetSHA, sourcePath: "draft.txt", expectedSourceSHA256: sourceSHA), context: f.context)
            Issue.record("changed source must conflict")
        } catch let error as WorkspaceToolError {
            guard case .conflict = error else { Issue.record("unexpected error: \(error)"); return }
        }
        try f.write("draft.txt", longText)
        let denied = ToolContext(runID: UUID(), workspaceRootURL: f.root, allowedWorkspacePaths: ["target.txt"], cancellation: CancellationToken())
        do {
            _ = try await tool.execute(.init(path: "target.txt", expectedSHA256: targetSHA, sourcePath: "draft.txt", expectedSourceSHA256: sourceSHA), context: denied)
            Issue.record("source has no task authority")
        } catch let error as FloeError { guard case .validationFailed = error else { Issue.record("\(error)"); return } }
        do {
            _ = try await tool.execute(.init(path: "target.txt", expectedSHA256: String(repeating: "0", count: 64), sourcePath: "draft.txt", expectedSourceSHA256: sourceSHA), context: f.context)
            Issue.record("stale target must conflict")
        } catch let error as WorkspaceToolError { guard case .conflict = error else { Issue.record("\(error)"); return } }
        let token = CancellationToken(); token.cancel()
        let cancelled = ToolContext(runID: UUID(), workspaceRootURL: f.root, cancellation: token)
        do {
            _ = try await tool.execute(.init(path: "target.txt", expectedSHA256: targetSHA, sourcePath: "draft.txt", expectedSourceSHA256: sourceSHA), context: cancelled)
            Issue.record("cancelled before commit")
        } catch let error as FloeError { #expect(error == .cancelled) }
        let bounded = WorkspaceWriteFileTool(environment: WorkspaceToolEnvironment(rootProvider: { [root = f.root] in root }, maxWriteBytes: 16))
        do {
            _ = try await bounded.execute(.init(path: "target.txt", expectedSHA256: targetSHA, sourcePath: "draft.txt", expectedSourceSHA256: sourceSHA), context: f.context)
            Issue.record("oversized source must not write")
        } catch let error as WorkspaceToolError { guard case .tooLarge = error else { Issue.record("\(error)"); return } }
        let frozen = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: f.root), mutationGuard: { _ in
            throw WorkspaceToolError.invalidArguments("fixture frozen target")
        })
        #expect(throws: WorkspaceToolError.self) {
            _ = try frozen.writeFileFromSourceWithChangeBaseline("target.txt", sourcePath: "draft.txt", expectedSourceSHA256: sourceSHA,
                expectedMtime: nil, expectedSHA256: targetSHA, cancellation: f.context.cancellation)
        }
        let lateToken = CancellationToken()
        let cancelsBeforeCommit = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: f.root), mutationGuard: { _ in lateToken.cancel() })
        #expect(throws: FloeError.self) {
            _ = try cancelsBeforeCommit.writeFileFromSourceWithChangeBaseline("target.txt", sourcePath: "draft.txt", expectedSourceSHA256: sourceSHA,
                expectedMtime: nil, expectedSHA256: targetSHA, cancellation: lateToken)
        }
        #expect(try f.read("target.txt") == "keep me")
        #expect(try f.read("draft.txt") == longText)
    }

    @Test("A 1 MiB BOM+CRLF draft appends in bounded chunks and finalizes byte-exactly")
    func largeBOMCRLFChunkedWrite() async throws {
        let f = try Fixture()
        let create = WorkspaceCreateFileTool(environment: f.environment)
        let append = WorkspaceAppendFileTool(environment: f.environment)
        let created = try await create.execute(.init(path: "draft.tex", content: "\u{FEFF}"), context: f.context)
        var digest = try field("sha256", in: created.summary)
        let chunk = String(repeating: "中文 😀 code()\r\n", count: 3_000) // ~60 KiB UTF-8
        #expect(chunk.utf8.count < 65_536)
        var expected = Data(WorkspaceTextPolicy.utf8BOM)
        for _ in 0..<20 {
            let output = try await append.execute(
                .init(path: "draft.tex", content: chunk, expectedSHA256: digest),
                context: f.context)
            digest = try field("sha256", in: output.summary)
            expected.append(Data(chunk.utf8))
            #expect(output.summary.contains("saved=true"))
        }
        #expect(expected.count > 1_000_000)
        #expect(try f.readData("draft.tex") == expected)
        #expect(try f.readData("draft.tex").starts(with: Data(WorkspaceTextPolicy.utf8BOM)))

        let final = WorkspaceWriteFileTool(environment: f.environment)
        let target = try await final.execute(
            .init(path: "final.tex", sourcePath: "draft.tex", expectedSourceSHA256: digest),
            context: f.context)
        #expect(target.summary.contains("saved=true"))
        #expect(try f.readData("final.tex") == expected)
        // Foundation's contentsOf initializer consumes the BOM; the raw
        // bytes above are the authoritative round-trip evidence.
        #expect(try f.read("draft.tex") == String(decoding: expected.dropFirst(3), as: UTF8.self))
    }

    @Test("Actual create/write/append/replace/patch commits survive a real optional artifact-storage failure")
    func previewFailureStillReportsSaved() async throws {
        let f = try Fixture()
        let evidence = try FloeArtifactStore.root().appendingPathComponent("ChangeArtifacts/\(f.context.runID.uuidString)")
        try FileManager.default.createDirectory(at: evidence.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("owned blocker".utf8).write(to: evidence)
        let created = try await WorkspaceCreateFileTool(environment: f.environment).execute(.init(path: "file.txt", content: "one\n"), context: f.context)
        let written = try await WorkspaceWriteFileTool(environment: f.environment).execute(.init(path: "file.txt", content: "two\n"), context: f.context)
        let appended = try await WorkspaceAppendFileTool(environment: f.environment).execute(.init(path: "file.txt", content: "three\n"), context: f.context)
        let replaced = try await WorkspaceReplaceTextTool(environment: f.environment).execute(.init(path: "file.txt", oldText: "two", newText: "TWO"), context: f.context)
        let patch = "--- a/file.txt\n+++ b/file.txt\n@@ -1,2 +1,2 @@\n TWO\n-three\n+THREE\n"
        let patched = try await WorkspaceApplyPatchTool(environment: f.environment).execute(.init(path: "file.txt", patch: patch), context: f.context)
        for result in [created, written, appended, replaced, patched] {
            #expect(result.summary.contains("saved=true"))
            #expect(result.summary.contains("preview=unavailable"))
            #expect(result.artifacts.isEmpty)
            #expect(result.exitStatus == nil || result.exitStatus == 0)
        }
        #expect(try f.read("file.txt") == "TWO\nTHREE\n")
    }

    @Test("Authorized Mac and network pages share the Unicode contract and a changed remote page is rejected")
    func remotePagesUseTheSameByteContinuation() async throws {
        let f = try Fixture()
        let data = Data(longText.utf8)
        let mac = PagedTextMacFixture(data: data)
        let tool = WorkspaceReadFileTool(environment: WorkspaceToolEnvironment(rootProvider: { [root = f.root] in root }, macAbsoluteReader: mac))
        var assembled = Data(), offset = 0
        for _ in 0..<16 {
            let output = try await tool.execute(.init(path: "/Users/fixture/large.txt", offset: offset), context: f.context)
            let text = try body(output.summary)
            #expect(!output.summaryTruncated)
            assembled.append(Data(text.utf8))
            let next = try field("nextOffset", in: output.summary)
            if next == "none" { break }
            let parsed = try #require(Int(next)); #expect(parsed > offset)
            guard parsed > offset else { return }; offset = parsed
        }
        #expect(assembled == data)
        let mount = NetworkWorkspaceMount(workspaceID: UUID(), name: "Fixture", transport: .webDAV,
            endpoint: URL(fileURLWithPath: "/fixture-not-a-network-server"), username: "", credentialRef: nil)
        let adapter = PagedTextNetworkFixture(data: data)
        let route = NetworkWorkspaceMountRegistry.Route(mount: mount, relativePath: "large.txt", adapter: adapter)
        assembled = Data(); offset = 0
        for _ in 0..<16 {
            let page = try await WorkspaceTextPage.readNetwork(route: route, offset: offset, limit: 65_536, cancellation: f.context.cancellation)
            assembled.append(Data(page.text.utf8))
            #expect(page.totalBytes == data.count)
            guard let next = page.nextOffset else { break }
            #expect(next == offset + page.bytesReturned && next > offset)
            guard next > offset else { return }; offset = next
        }
        #expect(assembled == data)
        let changing = PagedTextNetworkFixture(data: data, changesDuringRead: true)
        let changedRoute = NetworkWorkspaceMountRegistry.Route(mount: mount, relativePath: "large.txt", adapter: changing)
        do {
            _ = try await WorkspaceTextPage.readNetwork(route: changedRoute, offset: 0, limit: 65_536, cancellation: f.context.cancellation)
            Issue.record("changed remote page must not be accepted")
        } catch let error as WorkspaceToolError { guard case .conflict = error else { Issue.record("\(error)"); return } }
    }

}


private struct PagedTextMacFixture: MacAbsoluteFileReading {
    let data: Data
    func readMacAbsoluteFileChunk(path: String, offset: Int, limit: Int, expectedIdentity: String?,
                                 verifySHA256: Bool, context: ToolContext) async throws -> MacAbsoluteFileChunk? {
        let start = min(offset, data.count), end = min(start + limit, data.count)
        return MacAbsoluteFileChunk(data: data.subdata(in: start..<end), byteOffset: end,
            totalBytes: data.count, identity: "fixture-stable-identity")
    }
}

private actor PagedTextNetworkFixture: WorkspaceMountAdapter {
    let data: Data
    let changesDuringRead: Bool
    private var didRead = false
    init(data: Data, changesDuringRead: Bool = false) { self.data = data; self.changesDuringRead = changesDuringRead }
    func metadata(path: String) async throws -> NetworkWorkspaceFileMetadata {
        NetworkWorkspaceFileMetadata(path: path, isDirectory: false, byteCount: Int64(data.count),
            modifiedAt: Date(timeIntervalSince1970: 1), entityTag: changesDuringRead && didRead ? "changed" : "stable")
    }
    func read(path: String, offset: Int, limit: Int?) async throws -> Data {
        didRead = true
        let end = min(offset + (limit ?? data.count), data.count)
        return data.subdata(in: offset..<end)
    }
    func list(path: String) async throws -> [NetworkWorkspaceEntry] { throw unavailable() }
    func write(path: String, data: Data, expectedEntityTag: String?) async throws -> NetworkWorkspaceFileMetadata { throw unavailable() }
    func createDirectory(path: String) async throws { throw unavailable() }
    func move(from: String, to: String, expectedEntityTag: String?) async throws { throw unavailable() }
    func delete(path: String, expectedEntityTag: String?) async throws { throw unavailable() }
    private func unavailable() -> WorkspaceToolError { .invalidArguments("read-only paging fixture") }
}

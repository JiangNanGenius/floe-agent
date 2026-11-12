import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeWorkspace

private actor FakeMacAbsoluteFileReader: MacAbsoluteFileReading {
    struct Call: Sendable {
        let path: String
        let offset: Int
        let limit: Int
        let expectedIdentity: String?
        let verifySHA256: Bool
    }
    enum Mode: Sendable {
        case bytes(Data)
        case unavailable
        case failing(String)
        case unstableIdentity(Data)
        case silentIdentityChange(Data)
        case oversized(Data)
        case badOffset(Data)
        case badDigest(Data)
    }

    nonisolated let maximumChunkBytes: Int
    private let mode: Mode
    private(set) var calls: [Call] = []

    init(mode: Mode, maximumChunkBytes: Int = 4) {
        self.mode = mode
        self.maximumChunkBytes = maximumChunkBytes
    }

    func readMacAbsoluteFileChunk(
        path: String, offset: Int, limit: Int, expectedIdentity: String?,
        verifySHA256: Bool, context: ToolContext
    ) async throws -> MacAbsoluteFileChunk? {
        calls.append(Call(path: path, offset: offset, limit: limit,
                          expectedIdentity: expectedIdentity, verifySHA256: verifySHA256))
        switch mode {
        case .unavailable:
            return nil
        case .failing(let message):
            throw FloeError.validationFailed(message)
        case .bytes(let data):
            return chunk(data, offset: offset, limit: limit,
                         verifySHA256: verifySHA256, identity: String(repeating: "a", count: 64))
        case .unstableIdentity(let data):
            let identity = offset == 0
                ? String(repeating: "a", count: 64)
                : String(repeating: "b", count: 64)
            if let expectedIdentity, expectedIdentity != identity {
                throw FloeError.validationFailed("The Mac file changed during the read. Read it again.")
            }
            return chunk(data, offset: offset, limit: limit,
                         verifySHA256: verifySHA256, identity: identity)
        case .silentIdentityChange(let data):
            // Deliberately ignores expectedIdentity so the assembler's own
            // identity invariant is the boundary under test.
            let identity = offset == 0
                ? String(repeating: "a", count: 64)
                : String(repeating: "b", count: 64)
            return chunk(data, offset: offset, limit: limit,
                         verifySHA256: verifySHA256, identity: identity)
        case .oversized(let data):
            let start = min(offset, data.count)
            let end = min(start + limit + 1, data.count)
            return MacAbsoluteFileChunk(data: data.subdata(in: start..<end),
                byteOffset: end, totalBytes: data.count,
                identity: String(repeating: "d", count: 64))
        case .badOffset(let data):
            let start = min(offset, data.count)
            let end = min(start + limit, data.count)
            return MacAbsoluteFileChunk(data: data.subdata(in: start..<end),
                byteOffset: end + 1, totalBytes: data.count,
                identity: String(repeating: "d", count: 64))
        case .badDigest(let data):
            if verifySHA256 {
                return MacAbsoluteFileChunk(data: Data(), byteOffset: data.count,
                    totalBytes: data.count, identity: String(repeating: "c", count: 64),
                    sha256: String(repeating: "0", count: 64))
            }
            return chunk(data, offset: offset, limit: limit,
                         verifySHA256: false, identity: String(repeating: "c", count: 64))
        }
    }

    private func chunk(
        _ data: Data, offset: Int, limit: Int, verifySHA256: Bool, identity: String
    ) -> MacAbsoluteFileChunk {
        if verifySHA256 {
            return MacAbsoluteFileChunk(data: Data(), byteOffset: data.count,
                totalBytes: data.count, identity: identity,
                sha256: FloeDigest.sha256Hex(data))
        }
        let start = min(max(0, offset), data.count)
        let end = min(start + limit, data.count)
        return MacAbsoluteFileChunk(data: data.subdata(in: start..<end),
            byteOffset: end, totalBytes: data.count, identity: identity)
    }
}

@Suite("Mac absolute-path read seam and workspace.readFile")
struct MacAbsoluteFileReadTests {
    private func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-abs-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func context(
        root: URL, allowed: [String] = [], temporary: Bool = false,
        token: CancellationToken = CancellationToken()
    ) -> ToolContext {
        ToolContext(runID: UUID(), workspaceRootURL: root,
            allowedWorkspacePaths: allowed, cancellation: token,
            environmentID: "mac-env", temporaryReadOnly: temporary)
    }

    @Test("workspace.readFile reads absolute Mac bytes including cross-workspace Unicode paths")
    func absoluteReadFileRoutesThroughSeam() async throws {
        let root = try makeRoot("workspace")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("第一行\nsecond line\n\u{1F600}".utf8)
        let reader = FakeMacAbsoluteFileReader(mode: .bytes(bytes), maximumChunkBytes: 8)
        let tool = WorkspaceReadFileTool(environment: WorkspaceToolEnvironment(
            rootProvider: { root }, macAbsoluteReader: reader))
        let path = "/Users/fixture/另一个 工作区/报告-é.txt"

        let output = try await tool.execute(.init(path: path), context: context(root: root))

        #expect(output.summary.hasPrefix("path=\(path) offset=0 truncated=false"))
        #expect(output.summary.contains("totalBytes=\(bytes.count)"))
        #expect(output.summary.contains("macBridge=true"))
        #expect(output.summary.contains("第一行\nsecond line"))
        let calls = await reader.calls
        let call = try #require(calls.first)
        #expect(call.path == path)
        #expect(call.offset == 0)
        #expect(call.limit == WorkspaceFileService.readChunkBytes)
    }

    @Test("Absolute offset and limit stay bounded and report continuation")
    func absoluteReadFileHonorsOffsetAndLimit() async throws {
        let root = try makeRoot("offset")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("0123456789abcdef".utf8)
        let reader = FakeMacAbsoluteFileReader(mode: .bytes(bytes), maximumChunkBytes: 4)
        let tool = WorkspaceReadFileTool(environment: WorkspaceToolEnvironment(
            rootProvider: { root }, macAbsoluteReader: reader))

        let output = try await tool.execute(
            .init(path: "/tmp/数据 文件.txt", offset: 4, limit: 4), context: context(root: root))
        #expect(output.summary.contains("offset=4 truncated=true"))
        #expect(output.summary.contains("4567"))
        let calls = await reader.calls
        let call = try #require(calls.first)
        #expect(call.offset == 4 && call.limit == 4)
    }

    @Test("Relative reads keep the existing path and never touch the absolute seam")
    func relativeReadIsUnchanged() async throws {
        let root = try makeRoot("relative")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("line1\nline2\nline3\n".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let reader = FakeMacAbsoluteFileReader(mode: .unavailable)
        let tool = WorkspaceReadFileTool(environment: WorkspaceToolEnvironment(
            rootProvider: { root }, macAbsoluteReader: reader))

        let output = try await tool.execute(.init(path: "notes.txt"), context: context(root: root))
        #expect(output.summary.hasPrefix("path=notes.txt offset=0 truncated=false"))
        #expect(output.summary.contains("line1\nline2"))
        let calls = await reader.calls
        #expect(calls.isEmpty)
    }

    @Test("A non-Mac run gets an explicit error and no local fallback")
    func nonMacAbsoluteReadFailsClosed() async throws {
        let root = try makeRoot("nonmac")
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = FakeMacAbsoluteFileReader(mode: .unavailable)
        let tool = WorkspaceReadFileTool(environment: WorkspaceToolEnvironment(
            rootProvider: { root }, macAbsoluteReader: reader))

        await #expect(throws: FloeError.self) {
            _ = try await tool.execute(.init(path: "/Users/fixture/outside.txt"),
                                       context: context(root: root))
        }
        let calls = await reader.calls
        #expect(calls.count == 1)
    }

    @Test("No injected reader preserves the original relative-only contract")
    func missingReaderKeepsRelativeOnlyContract() async throws {
        let root = try makeRoot("noreader")
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = WorkspaceReadFileTool(environment: WorkspaceToolEnvironment(rootProvider: { root }))
        await #expect(throws: WorkspaceToolError.self) {
            _ = try await tool.execute(.init(path: "/Users/fixture/outside.txt"),
                                       context: context(root: root))
        }
    }

    @Test("Scoped and temporary runs cannot widen to absolute Mac paths")
    func scopeCeilingsBlockAbsoluteReads() async throws {
        let root = try makeRoot("ceilings")
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = FakeMacAbsoluteFileReader(mode: .bytes(Data("secret-ish".utf8)))
        let tool = WorkspaceReadFileTool(environment: WorkspaceToolEnvironment(
            rootProvider: { root }, macAbsoluteReader: reader))

        await #expect(throws: FloeError.self) {
            _ = try await tool.execute(.init(path: "/Users/fixture/outside.txt"),
                context: context(root: root, allowed: ["output"]))
        }
        await #expect(throws: FloeError.self) {
            _ = try await tool.execute(.init(path: "/Users/fixture/outside.txt"),
                context: context(root: root, temporary: true))
        }
        let calls = await reader.calls
        #expect(calls.isEmpty)
    }

    @Test("The generic whole-file assembler verifies bytes, identity and receipt")
    func wholeFileAssemblyVerifiesEveryPage() async throws {
        let data = Data("0123456789abcdefghij".utf8)
        let reader = FakeMacAbsoluteFileReader(mode: .bytes(data))
        let ctx = self.context(root: try makeRoot("whole"))
        let whole = try await reader.readMacAbsoluteFileWhole(
            path: "/Users/fixture/whole.bin", maximumBytes: 64, context: ctx)
        let file = try #require(whole)
        #expect(file.data == data)
        #expect(file.sha256 == FloeDigest.sha256Hex(data))
        let calls = await reader.calls
        #expect(calls.count == 6) // 5 data pages + 1 receipt
    }

    @Test("Changed identity, oversized pages and bad receipts are rejected")
    func wholeFileAssemblyRejectsMalformedPages() async throws {
        let data = Data(repeating: 0x41, count: 12)
        for mode: FakeMacAbsoluteFileReader.Mode in [
            .unstableIdentity(data), .silentIdentityChange(data),
            .oversized(data), .badOffset(data), .badDigest(data),
        ] {
            let reader = FakeMacAbsoluteFileReader(mode: mode)
            let ctx = self.context(root: try makeRoot("malformed"))
            await #expect(throws: FloeError.self) {
                _ = try await reader.readMacAbsoluteFileWhole(
                    path: "/Users/fixture/malformed.bin", maximumBytes: 32, context: ctx)
            }
        }
    }

    @Test("Whole-file reads honor the caller cap and cancellation")
    func wholeFileAssemblyHonorsCapAndCancellation() async throws {
        let reader = FakeMacAbsoluteFileReader(mode: .bytes(Data(repeating: 1, count: 20)))
        let ctx = self.context(root: try makeRoot("cap"))
        await #expect(throws: FloeError.self) {
            _ = try await reader.readMacAbsoluteFileWhole(
                path: "/Users/fixture/large.bin", maximumBytes: 8, context: ctx)
        }

        let token = CancellationToken()
        token.cancel()
        let cancelled = self.context(root: try makeRoot("cancel"), token: token)
        await #expect(throws: FloeError.self) {
            _ = try await reader.readMacAbsoluteFileWhole(
                path: "/Users/fixture/large.bin", maximumBytes: 64, context: cancelled)
        }
    }

    @Test("Absolute path syntax is bounded and data-only")
    func absolutePathSyntax() throws {
        try MacAbsolutePath.validate("/Users/fixture/报告 1.png")
        for path in ["relative/file", "~/Desktop/x", "//server/share", "/tmp/a\0b"] {
            #expect(throws: FloeError.self) { try MacAbsolutePath.validate(path) }
        }
        let control = "/tmp/a" + "\u{07}"
        #expect(throws: FloeError.self) { try MacAbsolutePath.validate(control) }
    }
}

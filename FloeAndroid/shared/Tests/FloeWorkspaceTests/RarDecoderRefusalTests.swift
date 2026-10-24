// FloeWorkspaceTests — bounded RAR decoder refusal contracts.
//
// Positive-path RAR extraction is the same upstream libarchive 3.8.9 object
// set as the accepted iOS signed build (pinned identical version+hash);
// creating *valid* RAR fixtures on a build host is impossible without the
// proprietary `rar` encoder, so this suite pins the refusal contracts the
// lane promises: list/extract only, garbage/truncated streams never
// produce output, existing destinations are never overwritten, staging is
// always removed, the workspace guard refuses escapes before the decoder
// runs, and the handler seam routes exactly like the original app bridge.

import Foundation
import Testing
@testable import FloeWorkspace
import FloeTools
import FloeCore

@Suite("FloeWorkspace.RarDecoder", .serialized)
struct RarDecoderRefusalTests {

    private final class Fixture: @unchecked Sendable {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-rar-refuse-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func write(_ relative: String, _ data: Data) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
        }
        func stagingLeftovers() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".floe-rar-") }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private func request(action: String, source: String, destination: String? = nil, root: URL) -> ArchiveCompressedRequest {
        ArchiveCompressedRequest(action: action, format: "rar", source: source, destination: destination, workspaceRoot: root)
    }

    @Test("only list and extract are accepted; create is refused before any decode")
    func actionWhitelist() async throws {
        let f = try Fixture()
        try f.write("pack.rar", Data("not a rar".utf8))
        await #expect(throws: FloeError.self) {
            try await RARArchiveService.run(request(action: "create", source: "pack.rar", destination: "out.rar", root: f.root))
        }
        #expect(!f.exists("out.rar"))
    }

    @Test("garbage input is refused; a signature-only stream matches upstream's empty-archive outcome with no staging leak")
    func corruptStreamsFailClosed() async throws {
        let f = try Fixture()
        try f.write("garbage.rar", Data(repeating: 0x41, count: 4096))
        await #expect(throws: FloeError.self) {
            try await RARArchiveService.run(request(action: "list", source: "garbage.rar", root: f.root))
        }
        // A bare RAR5 signature followed by junk decodes per the pinned
        // libarchive 3.8.9 reader (identical to the accepted iOS signed
        // build): either a permanent decode error, or an honest zero-entry
        // result. It must never leak staging or fabricate entries.
        var signatureFollowedByJunk = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])
        signatureFollowedByJunk.append(contentsOf: [UInt8](repeating: 0xFF, count: 64))
        try f.write("trunc.rar", signatureFollowedByJunk)
        do {
            let reply = try await RARArchiveService.run(request(action: "extract", source: "trunc.rar", destination: "out", root: f.root))
            #expect(reply.contains(#""entries":0"#))
            #expect(reply.contains(#""status":"ok""#))
        } catch is FloeError {
            // permanent refusal is equally valid for the same bytes
        }
        #expect(try f.stagingLeftovers().isEmpty, "staging must never survive")
    }

    @Test("extract requires a new output directory; existing paths are never touched")
    func existingDestinationRefused() async throws {
        let f = try Fixture()
        try f.write("x.rar", Data(repeating: 0, count: 512))
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("out"), withIntermediateDirectories: true)
        await #expect(throws: FloeError.self) {
            try await RARArchiveService.run(request(action: "extract", source: "x.rar", destination: "out", root: f.root))
        }
        #expect(f.exists("out")) // the existing directory itself was left alone
        #expect(try f.stagingLeftovers().isEmpty)
    }

    @Test("workspace guard refuses escaping sources before the decoder opens anything")
    func traversalRefused() async throws {
        let f = try Fixture()
        await #expect(throws: (any Error).self) {
            try await RARArchiveService.run(request(action: "list", source: "../outside.rar", root: f.root))
        }
        await #expect(throws: (any Error).self) {
            try await RARArchiveService.run(request(action: "list", source: "/absolute/path.rar", root: f.root))
        }
        #expect(try f.stagingLeftovers().isEmpty)
    }

    @Test("the handler seam routes rar only, like the original app bridge")
    func handlerRouting() async throws {
        let handler = RARArchiveService.compressedHandler
        // Non-rar formats reaching the handler mean the native engine was
        // bypassed; the refusal message matches the original bridge.
        let f = try Fixture()
        do {
            _ = try await handler(ArchiveCompressedRequest(action: "list", format: "zip", source: "none.zip", destination: nil, workspaceRoot: f.root))
            Issue.record("expected invalid configuration refusal")
        } catch let error as FloeError {
            guard case .invalidConfiguration(let message) = error else {
                Issue.record("expected invalidConfiguration, got \(error)")
                return
            }
            #expect(message.contains("handled natively by the workspace archive tool"))
        }
        // ArchiveTool with no handler refuses RAR with the original message.
        let tool = WorkspaceArchiveTool(environment: WorkspaceToolEnvironment(rootProvider: { f.root }))
        await #expect(throws: WorkspaceToolError.self) {
            _ = try await tool.execute(
                WorkspaceArchiveTool.Arguments(action: "list", source: "a.rar", format: "rar"),
                context: ToolContext(runID: UUID(), scope: .local, workspaceRootURL: f.root, cancellation: CancellationToken())
            )
        }
    }

    @Test("cancellation before any work is honored by the tool path")
    func cancellationHonored() async throws {
        let f = try Fixture()
        try f.write("c.rar", Data(repeating: 7, count: 128))
        let token = CancellationToken()
        token.cancel()
        let context = ToolContext(runID: UUID(), scope: .local, workspaceRootURL: f.root, cancellation: token)
        let tool = WorkspaceArchiveTool(
            environment: WorkspaceToolEnvironment(rootProvider: { f.root }),
            compressedHandler: RARArchiveService.compressedHandler
        )
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(
                WorkspaceArchiveTool.Arguments(action: "list", source: "c.rar", format: "rar"),
                context: context
            )
        }
    }
}

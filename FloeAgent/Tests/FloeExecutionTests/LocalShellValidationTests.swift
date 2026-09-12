import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

@Suite("Local shell boundaries")
struct LocalShellValidationTests {
    @Test func rejectsInvalidInputAtEveryEntryPoint() throws {
        for cwd in ["/tmp", "../other", "a/../../other", "~", "bad\0path"] {
            #expect(throws: FloeError.self) { try ShellInputValidation.validate(command: "pwd", cwd: cwd, environment: [:]) }
        }
        for env in [["PATH": "/tmp"], ["DYLD_INSERT_LIBRARIES": "bad"], ["x=y": "z"], ["A": "b\0c"]] {
            #expect(throws: FloeError.self) { try ShellInputValidation.validate(command: "pwd", cwd: ".", environment: env) }
        }
        try ShellInputValidation.validate(command: "printf '%s' \"$LANG\"", cwd: "folder with spaces", environment: ["LANG": "zh_CN.UTF-8"])
        #expect(throws: FloeError.self) { try ShellInputValidation.validate(command: "x\0y", cwd: ".", environment: [:]) }
    }

    @Test func directoryRejectsSymlinkEscapeAndMissingPath() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("workspace")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        #expect(throws: FloeError.self) { try ShellInputValidation.directory(cwd: "escape", root: root) }
        #expect(throws: FloeError.self) { try ShellInputValidation.directory(cwd: "missing", root: root) }
        #expect(try ShellInputValidation.directory(cwd: ".", root: root) == root.resolvingSymlinksInPath().standardizedFileURL)
    }

    @Test func capsUTF8WithoutCorruption() {
        let text = "中😀abc"
        #expect(ShellInputValidation.prefix(text, maxBytes: 2) == "")
        #expect(ShellInputValidation.prefix(text, maxBytes: 5) == "中")
        #expect(ShellInputValidation.prefix(text, maxBytes: 7) == "中😀")
        #expect(ShellInputValidation.prefix(text, maxBytes: 8) == "中😀a")
    }

    @Test func invalidRequestNeverReachesBackend() async {
        let backend = RecordingShellBackend()
        let service = LocalShellService(backend: backend, rootProvider: { FileManager.default.temporaryDirectory })
        let context = ToolContext(runID: UUID(), scope: .local, cancellation: CancellationToken())
        _ = await service.run(command: "pwd", cwd: "../escape", environment: [:], stdin: nil, timeout: 1, maxOutputBytes: 5, isBackground: false, context: context)
        #expect(await backend.runs == 0)
        #expect(service.normalizedTimeout(.infinity, isBackground: false) == 10)
        #expect(service.normalizedTimeout(999, isBackground: true) == 600)
    }
}

private actor RecordingShellBackend: LocalShellBackend {
    var runs = 0
    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        runs += 1
        return .cancelled
    }
    func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        .init(sessionID: request.sessionID, initialOutput: "", alive: true)
    }
    func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        .init(output: "", alive: false, exitCode: 0)
    }
    func closeSession(sessionID: String) async {}
}

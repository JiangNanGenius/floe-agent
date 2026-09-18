import Foundation
import Testing
import FloeCore
import FloeTools
import FloeExecution

/// Executes the pinned ruby.wasm release module (wasm32-wasip1) through the
/// production WASI command runtime. The artifact comes from
/// ThirdParty/RubyWASI/runtime.lock.json; point FLOE_RUBY_WASI at the fetched
/// ruby.wasm. Module/memory limits mirror the compilepending catalog entry.
///
/// Integration note for the repository owner: copy this file into
/// FloeAgent/Qualification/Tests/WasmCommandTests/RubyInterpreterTests.swift
/// (and, when the app test target is extended, FloeAgent/Tests/FloeExecutionTests).
/// Integrated 2026-09-19 from Local/Private/build191-feedback/languages/tests/.
@Suite("Ruby interpreter through the WASI command runtime")
struct RubyInterpreterTests {
    private func artifact() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["FLOE_RUBY_WASI"], !path.isEmpty else {
            throw FloeError.invalidConfiguration("FLOE_RUBY_WASI must name the fetched ruby.wasm")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FloeError.invalidConfiguration("ruby.wasm missing at \(path)")
        }
        return url
    }

    private func run(_ arguments: [String], stdin: String? = nil, timeout: TimeInterval = 120) async throws -> ShellRunOutcome {
        let ruby = try artifact()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return await WasmKitCommandRuntime().run(
            moduleURL: ruby, arguments: ["--disable-gems"] + arguments, stdin: stdin, environment: [:],
            rootURL: root, workingDirectory: ".", timeout: timeout, maxOutputBytes: 256 * 1024,
            moduleMaxBytes: 64 * 1024 * 1024, memoryMaxBytes: 256 * 1024 * 1024)
    }

    @Test func helloAndVersionInJail() async throws {
        guard case .exited(let code, let stdout, _, _, _, _) = try await run(["-e", "puts 'hello from ruby'; puts RUBY_VERSION; puts 2 + 40"]) else {
            Issue.record("Ruby did not start"); return
        }
        #expect(code == 0)
        #expect(stdout.contains("hello from ruby"))
        #expect(stdout.contains("42"))
    }

    @Test func jailedFileIOAndArguments() async throws {
        let ruby = try artifact()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = "File.write('/workspace/ruby-out.txt', \"sum=#{2 + 40}\\n\"); print File.read('/workspace/ruby-out.txt'); puts ARGV.join(',')"
        let outcome = await WasmKitCommandRuntime().run(
            moduleURL: ruby, arguments: ["--disable-gems", "-e", script, "alpha", "beta"], stdin: nil,
            environment: [:], rootURL: root, workingDirectory: ".", timeout: 120, maxOutputBytes: 256 * 1024,
            moduleMaxBytes: 64 * 1024 * 1024, memoryMaxBytes: 256 * 1024 * 1024)
        guard case .exited(let code, let stdout, _, _, _, _) = outcome else {
            Issue.record("Unexpected outcome: \(outcome)"); return
        }
        #expect(code == 0)
        #expect(stdout.contains("sum=42"))
        #expect(stdout.contains("alpha,beta"))
        let written = try String(contentsOf: root.appendingPathComponent("ruby-out.txt"), encoding: .utf8)
        #expect(written == "sum=42\n")
    }

    @Test func stdinReachesTheScript() async throws {
        guard case .exited(let code, let stdout, _, _, _, _) = try await run(
            ["-e", "print 'echo:', $stdin.read.strip, \"\\n\""], stdin: "来自 stdin 的行") else {
            Issue.record("Ruby did not start"); return
        }
        #expect(code == 0)
        #expect(stdout.contains("echo:来自 stdin 的行"))
    }

    @Test func rubyErrorsAreRecovered() async throws {
        guard case .exited(let code, _, let stderr, _, _, _) = try await run(["-e", "raise 'boom'"]) else {
            Issue.record("Ruby did not start"); return
        }
        #expect(code == 1)
        #expect(stderr.contains("boom"))
    }

    @Test func timeoutAndCancellationStopPureRubyLoops() async throws {
        let ruby = try artifact()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let token = CancellationToken()
        let canceller = Task { try? await Task.sleep(for: .seconds(5)); token.cancel() }
        let outcome = await WasmKitCommandRuntime().run(
            moduleURL: ruby, arguments: ["--disable-gems", "-e", "i = 0; loop { i += 1 }"], stdin: nil,
            environment: [:], rootURL: root, workingDirectory: ".", timeout: 120, maxOutputBytes: 64 * 1024,
            moduleMaxBytes: 64 * 1024 * 1024, memoryMaxBytes: 256 * 1024 * 1024, cancellation: token)
        canceller.cancel()
        guard case .cancelled = outcome else {
            Issue.record("A cancelled Ruby loop must report cancellation, got: \(outcome)"); return
        }
        let timed = await WasmKitCommandRuntime().run(
            moduleURL: ruby, arguments: ["--disable-gems", "-e", "i = 0; loop { i += 1 }"], stdin: nil,
            environment: [:], rootURL: root, workingDirectory: ".", timeout: 5, maxOutputBytes: 64 * 1024,
            moduleMaxBytes: 64 * 1024 * 1024, memoryMaxBytes: 256 * 1024 * 1024)
        guard case .timedOut = timed else {
            Issue.record("A bounded Ruby loop must time out, got: \(timed)"); return
        }
    }
}

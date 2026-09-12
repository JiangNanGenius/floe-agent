import Foundation
import Testing
import WAT
import Crypto
import FloeCore
import FloeTools
import FloeExecution

@Suite("Bounded signed WASM commands")
struct WasmCapabilityTests {
    private func module(_ wat: String, root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("test.wasm")
        try Data(wat2wasm(wat)).write(to: url)
        return url
    }

    @Test func exitsSuccessfully() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try module("(module (func (export \"_start\")))", root: root)
        let outcome = await WasmKitCommandRuntime().run(moduleURL: url, arguments: [], stdin: nil, environment: [:], rootURL: root, timeout: 2, maxOutputBytes: 1024)
        guard case .exited(let code, _, _, _, _, _) = outcome else { Issue.record("Unexpected outcome: \(outcome)"); return }
        #expect(code == 0)
    }

    @Test func pureInfiniteLoopTimesOut() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try module("(module (func (export \"_start\") (loop $forever (br $forever))))", root: root)
        let outcome = await WasmKitCommandRuntime().run(moduleURL: url, arguments: [], stdin: nil, environment: [:], rootURL: root, timeout: 0.05, maxOutputBytes: 1024)
        guard case .timedOut = outcome else { Issue.record("Loop did not time out: \(outcome)"); return }
    }

    @Test func outputIsBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try module("""
        (module
          (import "wasi_snapshot_preview1" "fd_write" (func $write (param i32 i32 i32 i32) (result i32)))
          (memory (export "memory") 1)
          (data (i32.const 64) "hello world")
          (func (export "_start")
            (i32.store (i32.const 0) (i32.const 64))
            (i32.store (i32.const 4) (i32.const 11))
            (drop (call $write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 16)))))
        """, root: root)
        let outcome = await WasmKitCommandRuntime().run(moduleURL: url, arguments: [], stdin: nil, environment: [:], rootURL: root, timeout: 2, maxOutputBytes: 5)
        guard case .exited(let code, let stdout, _, let truncated, _, _) = outcome else { Issue.record("Unexpected outcome: \(outcome)"); return }
        #expect(code == 0)
        #expect(stdout == "hello")
        #expect(truncated)
    }

    @Test func memoryLimitAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try module("(module (memory 1025) (func (export \"_start\")))", root: root)
        let runtime = WasmKitCommandRuntime()
        let outcome = await runtime.run(moduleURL: url, arguments: [], stdin: nil, environment: [:], rootURL: root, timeout: 2, maxOutputBytes: 1024)
        guard case .failed = outcome else { Issue.record("Oversized memory was accepted: \(outcome)"); return }
        let token = CancellationToken()
        token.cancel()
        #expect(await runtime.run(moduleURL: url, arguments: [], stdin: nil, environment: [:], rootURL: root, timeout: 2, maxOutputBytes: 1024, cancellation: token) == .cancelled)
    }

    @Test func stdinRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try module("""
        (module
          (import "wasi_snapshot_preview1" "fd_read" (func $read (param i32 i32 i32 i32) (result i32)))
          (import "wasi_snapshot_preview1" "fd_write" (func $write (param i32 i32 i32 i32) (result i32)))
          (memory (export "memory") 1)
          (func (export "_start")
            (i32.store (i32.const 0) (i32.const 64))
            (i32.store (i32.const 4) (i32.const 128))
            (drop (call $read (i32.const 0) (i32.const 0) (i32.const 1) (i32.const 16)))
            (i32.store (i32.const 4) (i32.load (i32.const 16)))
            (drop (call $write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 20)))))
        """, root: root)
        let outcome = await WasmKitCommandRuntime().run(moduleURL: url, arguments: [], stdin: "中文 input\n", environment: [:], rootURL: root, timeout: 2, maxOutputBytes: 1024)
        guard case .exited(let code, let stdout, _, _, _, _) = outcome else { Issue.record("Unexpected outcome: \(outcome)"); return }
        #expect(code == 0)
        #expect(stdout == "中文 input\n")
    }

    @Test func signatureInstallTamperAndRemove() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try module("(module (func (export \"_start\")))", root: root)
        let bytes = try Data(contentsOf: source)
        let entry = SignedWasmCatalog.Entry(id: "floe/test", version: "1.0.0", command: "floe-test", url: URL(string: "https://example.com/test.wasm")!, sha256: FloeDigest.sha256Hex(bytes), minimumAppVersion: "1.6.7")
        let data = try JSONEncoder().encode(SignedWasmCatalog(packages: [entry]))
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: Data("FLOE-CAPABILITY-CATALOG-V1\n".utf8) + data)
        #expect(throws: Error.self) { try SignedWasmCatalog.verify(data: data + Data([32]), signature: signature, publicKey: key.publicKey.rawRepresentation, appVersion: "1.6.7") }
        let installed = root.appendingPathComponent("installed")
        let store = try SignedWasmCapabilityStore(catalogData: data, signature: signature, publicKey: key.publicKey.rawRepresentation, appVersion: "1.6.7", root: installed) { _, target in try bytes.write(to: target) }
        try await store.install(id: entry.id, cancellation: nil)
        #expect(await store.installedIDs() == [entry.id])
        try Data("tampered".utf8).write(to: installed.appendingPathComponent("floe-test-1.0.0.wasm"))
        let outcome = await store.run(command: entry.command, arguments: [], stdin: nil, environment: [:], rootURL: root)
        guard case .failed = outcome else { Issue.record("Tampered module was accepted"); return }
        try await store.remove(id: entry.id)
        #expect(await store.installedIDs().isEmpty)
    }
}

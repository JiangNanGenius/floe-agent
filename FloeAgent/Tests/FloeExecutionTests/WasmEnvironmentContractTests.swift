import Foundation
import Testing
import WAT
import FloeCore
import FloeTools
@testable import FloeExecution

/// Regression coverage for the WASI environment contract.
///
/// Build 184's full-app regression (`LuaShellInstallTests`) ran the real
/// `floe-lua` command with the whole shell environment. The old hard cap of 32
/// variables rejected that legitimate export set, so `floe-lua -e "print(2+40)"`
/// returned `WASM input exceeds limits`. These tests pin the replacement: a
/// bounded but realistic contract, a distinct error per violated field, and a
/// guest that can actually read the environment.
@Suite("WASI environment contract")
struct WasmEnvironmentContractTests {
    private func violation(_ environment: [String: String]) -> WasmEnvironmentContract.Violation? {
        do {
            try WasmEnvironmentContract.validate(environment)
            return nil
        } catch let violation as WasmEnvironmentContract.Violation {
            return violation
        } catch {
            Issue.record("Unexpected validation error: \(error)")
            return nil
        }
    }

    private func module(_ wat: String, root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("test.wasm")
        try Data(wat2wasm(wat)).write(to: url)
        return url
    }

    // MARK: - Contract boundaries

    @Test func acceptsRealisticShellExportSets() {
        // A larger export set than the old 32-variable cap,
        // including the PWD/HOME/TMPDIR the WASM command adds on top.
        var environment = Dictionary(uniqueKeysWithValues: (0..<200).map { ("FLOE_EXPORT_\($0)", "value-\($0)") })
        environment["PWD"] = "/workspace"
        environment["HOME"] = "/workspace"
        environment["TMPDIR"] = "/tmp"
        #expect(violation(environment) == nil)
        #expect(WasmEnvironmentContract.maximumVariables >= 200)
    }

    @Test func distinguishesVariableCountFromTotalBytes() {
        let overCount = Dictionary(uniqueKeysWithValues: (0...WasmEnvironmentContract.maximumVariables).map { ("K\($0)", "v") })
        #expect(violation(overCount) == .tooManyVariables(actual: WasmEnvironmentContract.maximumVariables + 1, limit: WasmEnvironmentContract.maximumVariables))

        // Eight 9 KiB values stay under the per-value cap but exceed 64 KiB total.
        let overTotal = Dictionary(uniqueKeysWithValues: (0..<8).map { ("K\($0)", String(repeating: "v", count: 9000)) })
        if case .totalBytesExceeded = violation(overTotal) {} else {
            Issue.record("Expected total-bytes violation, got \(String(describing: violation(overTotal)))")
        }
    }

    @Test func rejectsEachStructuralBoundary() {
        #expect(violation([String(repeating: "K", count: WasmEnvironmentContract.maximumKeyBytes + 1): "v"])
            == .keyTooLong(limit: WasmEnvironmentContract.maximumKeyBytes))
        #expect(violation(["K": String(repeating: "v", count: WasmEnvironmentContract.maximumValueBytes + 1)])
            == .valueTooLong(limit: WasmEnvironmentContract.maximumValueBytes))
        #expect(violation(["A\0B": "v"]) == .keyContainsNUL)
        #expect(violation(["A": "v\0"]) == .valueContainsNUL)
        #expect(violation(["": "v"]) == .invalidKey(.empty))
        #expect(violation(["A=B": "v"]) == .invalidKey(.containsEquals))
        #expect(violation(["A\tB": "v"]) == .invalidKey(.containsControlCharacter))
        // A violation message never contains the key or value.
        let message = String(describing: WasmEnvironmentContract.Violation.keyTooLong(limit: WasmEnvironmentContract.maximumKeyBytes))
        #expect(message.contains("key exceeds"))
    }

    // MARK: - Real guest reads

    @Test func runtimeAcceptsShellEnvironmentBeyondTheOldCap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // The guest exits with the environment count it can see.
        let url = try module("""
        (module
          (import "wasi_snapshot_preview1" "environ_sizes_get" (func $sizes (param i32 i32) (result i32)))
          (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
          (memory (export "memory") 1)
          (func (export "_start")
            (drop (call $sizes (i32.const 0) (i32.const 4)))
            (call $exit (i32.load (i32.const 0)))))
        """, root: root)
        var environment = Dictionary(uniqueKeysWithValues: (0..<64).map { ("FLOE_EXPORT_\($0)", "value-\($0)") })
        environment["PWD"] = "/workspace"
        let outcome = await WasmKitCommandRuntime().run(moduleURL: url, arguments: [], stdin: nil,
            environment: environment, rootURL: root, timeout: 5, maxOutputBytes: 1024)
        guard case .exited(let code, _, _, _, _, _) = outcome else {
            Issue.record("Environment set was rejected: \(outcome)"); return
        }
        #expect(code == Int32(environment.count))
    }

    @Test func runtimeGuestReadsEnvironmentValues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try module("""
        (module
          (import "wasi_snapshot_preview1" "environ_sizes_get" (func $sizes (param i32 i32) (result i32)))
          (import "wasi_snapshot_preview1" "environ_get" (func $get (param i32 i32) (result i32)))
          (import "wasi_snapshot_preview1" "fd_write" (func $write (param i32 i32 i32 i32) (result i32)))
          (memory (export "memory") 1)
          (func (export "_start")
            (drop (call $sizes (i32.const 0) (i32.const 4)))
            (drop (call $get (i32.const 1024) (i32.const 8192)))
            (i32.store (i32.const 4096) (i32.const 8192))
            (i32.store (i32.const 4100) (i32.load (i32.const 4)))
            (drop (call $write (i32.const 1) (i32.const 4096) (i32.const 1) (i32.const 4104)))))
        """, root: root)
        var environment = Dictionary(uniqueKeysWithValues: (0..<48).map { ("FLOE_EXPORT_\($0)", "value-\($0)") })
        environment["FLOE_PROBE"] = "7"
        let outcome = await WasmKitCommandRuntime().run(moduleURL: url, arguments: [], stdin: nil,
            environment: environment, rootURL: root, timeout: 5, maxOutputBytes: 64 * 1024)
        guard case .exited(let code, let stdout, _, _, _, _) = outcome else {
            Issue.record("Environment read failed: \(outcome)"); return
        }
        #expect(code == 0)
        #expect(stdout.contains("FLOE_PROBE=7"))
        #expect(stdout.contains("FLOE_EXPORT_47=value-47"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLOE_LUA_WASI"] != nil, "Requires the signed Lua WASI fixture"))
    func realLuaReadsManyEnvironmentVariables() async throws {
        // Disabled explicitly when this host has no Lua fixture. A configured
        // but missing fixture is a setup failure rather than a passing test.
        guard let path = ProcessInfo.processInfo.environment["FLOE_LUA_WASI"], !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            Issue.record("Configured Lua WASI fixture is missing"); return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var environment = Dictionary(uniqueKeysWithValues: (0..<64).map { ("FLOE_LUA_\($0)", "v\($0)") })
        environment["FLOE_PROBE"] = "7"
        let outcome = await WasmKitCommandRuntime().run(moduleURL: URL(fileURLWithPath: path),
            arguments: ["-e", "io.write('sum=', 2 + 40, ' probe=', os.getenv('FLOE_PROBE') or 'nil', '\\n')"],
            stdin: nil, environment: environment, rootURL: root, timeout: 30, maxOutputBytes: 64 * 1024)
        guard case .exited(let code, let stdout, _, _, _, _) = outcome else {
            Issue.record("Real Lua run failed: \(outcome)"); return
        }
        #expect(code == 0)
        #expect(stdout.contains("sum=42"))
        #expect(stdout.contains("probe=7"))
    }

    @Test func runtimeRejectsOversizedEnvironmentWithoutLeakingContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try module("(module (func (export \"_start\")))", root: root)
        let environment = Dictionary(uniqueKeysWithValues: (0...WasmEnvironmentContract.maximumVariables).map { ("SECRET_\($0)", "SECRET_VALUE_\($0)") })
        let outcome = await WasmKitCommandRuntime().run(moduleURL: url, arguments: [], stdin: nil,
            environment: environment, rootURL: root, timeout: 5, maxOutputBytes: 1024)
        guard case .failed(let message) = outcome else {
            Issue.record("Oversized environment was accepted: \(outcome)"); return
        }
        #expect(message.contains("too many variables"))
        #expect(!message.contains("SECRET"))
    }
}

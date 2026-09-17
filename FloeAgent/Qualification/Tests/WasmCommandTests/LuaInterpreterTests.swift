import Foundation
import Testing
import FloeCore
import FloeTools
import FloeExecution

/// Executes the pinned Lua interpreter (wasm32-wasi) through the production
/// WASI command runtime. The artifact comes from ThirdParty/LuaWASI's locked
/// build; point FLOE_LUA_WASI at the built lua.wasm.
@Suite("Lua interpreter through the WASI command runtime")
struct LuaInterpreterTests {
    private func artifact() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["FLOE_LUA_WASI"], !path.isEmpty else {
            throw FloeError.invalidConfiguration("FLOE_LUA_WASI must name the locked lua.wasm build")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FloeError.invalidConfiguration("lua.wasm missing at \(path)")
        }
        return url
    }

    @Test func runsScriptsAndJailedFileIO() async throws {
        let lua = try artifact()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = """
            local out = io.open("/workspace/result.txt", "w")
            out:write("sum=", 2 + 40, "\\n")
            out:close()
            local back = io.open("/workspace/result.txt", "r")
            io.write(back:read("a"))
            back:close()
            io.write(("Floe Lua"):upper(), "\\n")
            os.exit(0)
            """
        let outcome = await WasmKitCommandRuntime().run(moduleURL: lua, arguments: ["-e", script],
            stdin: nil, environment: [:], rootURL: root, workingDirectory: ".", timeout: 30, maxOutputBytes: 64 * 1024)
        guard case .exited(let code, let stdout, _, _, _, _) = outcome else {
            Issue.record("Unexpected outcome: \(outcome)"); return
        }
        #expect(code == 0)
        #expect(stdout.contains("sum=42"))
        #expect(stdout.contains("FLOE LUA"))
        let written = try String(contentsOf: root.appendingPathComponent("result.txt"), encoding: .utf8)
        #expect(written == "sum=42\n")
    }

    @Test func reportsLuaErrorsWithoutCrashing() async throws {
        let lua = try artifact()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outcome = await WasmKitCommandRuntime().run(moduleURL: lua, arguments: ["-e", "error('boom')"],
            stdin: nil, environment: [:], rootURL: root, timeout: 30, maxOutputBytes: 64 * 1024)
        guard case .exited(let code, _, let stderr, _, _, _) = outcome else {
            Issue.record("Unexpected outcome: \(outcome)"); return
        }
        #expect(code == 1)
        #expect(stderr.contains("boom"))
    }

    @Test func stdinReachesTheScript() async throws {
        let lua = try artifact()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outcome = await WasmKitCommandRuntime().run(moduleURL: lua,
            arguments: ["-e", "io.write('echo:', io.read('l'), '\\n')"],
            stdin: "来自 stdin 的行", environment: [:], rootURL: root, timeout: 30, maxOutputBytes: 64 * 1024)
        guard case .exited(let code, let stdout, _, _, _, _) = outcome else {
            Issue.record("Unexpected outcome: \(outcome)"); return
        }
        #expect(code == 0)
        #expect(stdout.contains("echo:来自 stdin 的行"))
    }
}

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeExecution
import FloeEnvironments
import FloeTools
@testable import FloeApp

/// Full-app acceptance for the open Lua item in
/// `docs/qualification/build179-release/runtime/README.md`: install the signed
/// `floe/lua` capability through the dedicated wasm.packages entry, execute a
/// real Lua script through the WASI runtime, remove it, and prove it no
/// longer runs. The retired mixed apt route must refuse the same operand
/// honestly (Debian packages require a Linux environment).
///
/// The test drives the production tool registry and app-injected
/// `SignedWasmCapabilityStore`. It downloads the artifact pinned by the
/// signed bundled catalog and verifies its SHA-256; no mock runtime or
/// synthetic module is substituted. A build without the app-hosted registry,
/// the signed catalog, the installer or the WASI runtime fails loudly instead
/// of skipping.
@Suite("FloeApp.LuaShellInstall", .serialized)
struct LuaShellInstallTests {

    @Test(.timeLimit(.minutes(4)))
    func wasmEntryInstallsLuaAndRemoveDisablesIt() async throws {
        try #require(FloePlatformServices.shared.isConfigured,
                     "FloePlatformServices is not configured in this test host; the app environment did not initialize")
        let wasmStore = try #require(FloeShellCommandRegistry.shared.wasm,
                                     "The signed WASM catalog was not loaded from the app bundle")
        let wasmTool = try #require(ToolRunnerRegistry.shared.runner(named: "wasm.packages"),
                                    "The wasm.packages tool is not registered")
        try #require(FloeShellCommandRegistry.shared.handler(for: "apt") != nil,
                     "The apt shell command is not registered")
        try #require(FloeShellCommandRegistry.shared.handler(for: "floe-lua") != nil,
                     "The floe-lua shell command is not registered; the signed catalog has no Lua entry")
        try #require(wasmStore.catalog.packages.contains(where: { $0.id == "floe/lua" }),
                     "The signed catalog does not contain floe/lua")

        // A real project environment so the shell binds a writable container.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-lua-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        try await FloePlatformServices.shared.prepareWorkspaceEnvironment(root: root)
        let owner = FloeDigest.sha256Hex(Data(root.path.utf8))
        let reports = try await FloePlatformServices.shared.environmentReports()
        let report = try #require(
            reports.first(where: { $0.record.kind == .project && $0.record.ownerID == owner }),
            "prepareWorkspaceEnvironment did not register a project environment for \(root.path)"
        )
        let writable = EnvironmentRoots().layerURL(id: report.record.id, kind: report.record.kind)
        let toolEnvironment = ToolEnvironment(
            id: report.record.id, writableLayerURL: writable, layerURLs: [writable],
            variables: ["FLOE_ENVIRONMENT_ID": report.record.id]
        )
        let backend = IOSSystemShellBackend()
        let toolContext = ToolContext(runID: UUID(), scope: .local,
                                      workspaceRootURL: root, cancellation: CancellationToken(),
                                      environment: toolEnvironment)

        func runShell(_ command: String, timeout: TimeInterval = 180) async -> ShellRunOutcome {
            await backend.run(.init(command: command, cwd: ".", rootURL: root, timeout: timeout,
                                    maxOutputBytes: 64 * 1024, sessionID: UUID().uuidString,
                                    runID: UUID(), toolEnvironment: toolEnvironment), cancellation: nil)
        }
        func runWasmTool(action: String) async throws -> ToolExecutionOutput {
            try await wasmTool.execute(
                argumentsJSON: Data("""
                {"action":"\(action)","ids":["floe/lua"],"purpose":"full-app qualification of the signed Lua capability"}
                """.utf8),
                context: toolContext)
        }

        do {
            // The retired mixed route refuses honestly: apt on this device has
            // no Linux environment and never installs WASM capabilities.
            let aptAttempt = try expectExited(await runShell("apt install -y floe/lua", timeout: 60), label: "retired apt route")
            #expect(aptAttempt.code == 100, "retired apt route did not fail closed: code=\(aptAttempt.code) out=\(aptAttempt.stdout)")
            #expect(aptAttempt.stderr.contains("Linux environment"), "retired apt route did not name the Linux requirement: \(aptAttempt.stderr)")
            #expect(await wasmStore.installedIDs().contains("floe/lua") == false,
                    "the retired apt route installed a WASM capability")

            // Start from a known state; absent capabilities remove cleanly.
            _ = try? await runWasmTool(action: "remove")
            let beforeIDs = await wasmStore.installedIDs()
            #expect(!beforeIDs.contains("floe/lua"), "floe/lua was still installed after the pre-test remove")

            let install = try await runWasmTool(action: "install")
            #expect(install.exitStatus == 0, "wasm.packages install failed: \(install.summary)")
            #expect(install.summary.contains("installed id=floe/lua"), "install output did not report the capability: \(install.summary)")
            let installedIDs = await wasmStore.installedIDs()
            #expect(installedIDs.contains("floe/lua"), "installer did not activate floe/lua")

            let executed = try expectExited(await runShell("floe-lua -e \"print(2 + 40)\"", timeout: 60), label: "floe-lua")
            #expect(executed.code == 0, "floe-lua failed:\n\(executed.stdout)\n\(executed.stderr)")
            #expect(executed.stdout.contains("42"), "Lua script did not produce its result: \(executed.stdout)")

            let removal = try await runWasmTool(action: "remove")
            #expect(removal.exitStatus == 0, "wasm.packages remove failed: \(removal.summary)")
            let remainingIDs = await wasmStore.installedIDs()
            #expect(!remainingIDs.contains("floe/lua"), "floe/lua is still active after removal")

            let afterRemoval = try expectExited(await runShell("floe-lua -e \"print(2 + 40)\"", timeout: 60), label: "floe-lua after removal")
            #expect(afterRemoval.code == 127, "removed floe-lua did not fail closed: code=\(afterRemoval.code) out=\(afterRemoval.stdout)")
            #expect(afterRemoval.stderr.contains("not installed"), "removed floe-lua did not explain the missing capability: \(afterRemoval.stderr)")
            #expect(afterRemoval.stderr.contains("wasm.packages"), "removed floe-lua did not point at the WASM entry: \(afterRemoval.stderr)")
        } catch {
            await deleteEnvironment(id: report.record.id, root: root)
            throw error
        }
        await deleteEnvironment(id: report.record.id, root: root)
    }

    private func expectExited(_ outcome: ShellRunOutcome, label: String) throws -> (code: Int32, stdout: String, stderr: String) {
        guard case .exited(let code, let stdout, let stderr, _, _, _) = outcome else {
            throw FloeError.internalError("\(label) did not terminate: \(outcome)")
        }
        return (code, stdout, stderr)
    }

    private func deleteEnvironment(id: String, root: URL) async {
        try? await FloePlatformServices.shared.deleteEnvironment(id: id)
        try? FileManager.default.removeItem(at: root)
    }
}
#endif

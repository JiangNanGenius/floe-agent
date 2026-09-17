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
/// `floe/lua` capability through the real shell `apt` command, execute a real
/// Lua script through the WASI runtime, remove it, and prove it no longer runs.
///
/// The test drives the production shell command registry and app-injected
/// `ShellWasmCapabilityRouter`/`CapabilityInstaller`/`SignedWasmCapabilityStore`.
/// It downloads the artifact pinned by the signed bundled catalog and verifies
/// its SHA-256; no mock runtime or synthetic module is substituted. A build
/// without the app-hosted registry, the signed catalog, the installer or the
/// WASI runtime fails loudly instead of skipping.
@Suite("FloeApp.LuaShellInstall", .serialized)
struct LuaShellInstallTests {

    @Test(.timeLimit(.minutes(4)))
    func aptInstallRunsLuaAndRemoveDisablesIt() async throws {
        try #require(FloePlatformServices.shared.isConfigured,
                     "FloePlatformServices is not configured in this test host; the app environment did not initialize")
        let wasmStore = try #require(FloeShellCommandRegistry.shared.wasm,
                                     "The signed WASM catalog was not loaded from the app bundle")
        try #require(FloeShellCommandRegistry.shared.installer != nil,
                     "The signed capability installer is unavailable")
        try #require(FloeShellCommandRegistry.shared.handler(for: "apt") != nil,
                     "The apt shell command is not registered")
        try #require(FloeShellCommandRegistry.shared.handler(for: "floe-lua") != nil,
                     "The floe-lua shell command is not registered; the signed catalog has no Lua entry")
        try #require(wasmStore.catalog.packages.contains(where: { $0.id == "floe/lua" }),
                     "The signed catalog does not contain floe/lua")

        // A real project environment so the apt context provider resolves a
        // writable container. Signed WASM capabilities are app-global, but the
        // apt command still requires an attached environment.
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

        func runShell(_ command: String, timeout: TimeInterval = 180) async -> ShellRunOutcome {
            await backend.run(.init(command: command, cwd: ".", rootURL: root, timeout: timeout,
                                    maxOutputBytes: 64 * 1024, sessionID: UUID().uuidString,
                                    runID: UUID(), toolEnvironment: toolEnvironment), cancellation: nil)
        }

        do {
            // Start from a known state; absent capabilities remove cleanly.
            _ = await runShell("apt remove -y floe/lua", timeout: 120)
            let beforeIDs = await wasmStore.installedIDs()
            #expect(!beforeIDs.contains("floe/lua"), "floe/lua was still installed after the pre-test remove")

            let install = try expectExited(await runShell("apt install -y floe/lua", timeout: 240), label: "apt install floe/lua")
            #expect(install.code == 0, "apt install failed:\n\(install.stdout)\n\(install.stderr)")
            #expect(install.stdout.contains("Setting up floe/lua"), "install output did not report the capability: \(install.stdout)")
            let installedIDs = await wasmStore.installedIDs()
            #expect(installedIDs.contains("floe/lua"), "installer did not activate floe/lua")

            let executed = try expectExited(await runShell("floe-lua -e \"print(2 + 40)\"", timeout: 60), label: "floe-lua")
            #expect(executed.code == 0, "floe-lua failed:\n\(executed.stdout)\n\(executed.stderr)")
            #expect(executed.stdout.contains("42"), "Lua script did not produce its result: \(executed.stdout)")

            let removal = try expectExited(await runShell("apt remove -y floe/lua", timeout: 120), label: "apt remove floe/lua")
            #expect(removal.code == 0, "apt remove failed:\n\(removal.stdout)\n\(removal.stderr)")
            let remainingIDs = await wasmStore.installedIDs()
            #expect(!remainingIDs.contains("floe/lua"), "floe/lua is still active after removal")

            let afterRemoval = try expectExited(await runShell("floe-lua -e \"print(2 + 40)\"", timeout: 60), label: "floe-lua after removal")
            #expect(afterRemoval.code == 127, "removed floe-lua did not fail closed: code=\(afterRemoval.code) out=\(afterRemoval.stdout)")
            #expect(afterRemoval.stderr.contains("not installed"), "removed floe-lua did not explain the missing capability: \(afterRemoval.stderr)")
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

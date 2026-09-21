import Foundation
import Testing
import FloeCore
import FloeTools
import FloeExecution

/// Executes one cloud-compiled wasm32-wasip1 artifact (the output of
/// .github/workflows/cloud-language-compile.yml) through the production WASI
/// command runtime. Point FLOE_CLOUD_WASI at command.wasm; optional
/// FLOE_CLOUD_ARGS is a space-separated argument list (default `alpha beta`).
///
/// Qualification contract for a cloud-compiled fixture: it prints its hello
/// banner and the comma-joined arguments, writes `hello.txt` inside the jail
/// containing `sum=42 args=<csv>`, and when the first argument is `fail` it
/// writes `fail-ok` and exits 3. Fixtures live in
/// Local/Private/build191-feedback/language-delivery/fixtures/.
///
/// Integrated 2026-09-19 from Local/Private/build191-feedback/languages/tests/.
///
/// Product status (Build 214/215): the cloud-compiled WASI language delivery
/// pipeline is retired; per-language wasm artifacts are not part of the
/// current product qualification set. These tests SKIP when FLOE_CLOUD_WASI
/// is absent; a set-but-missing path stays an error (a claimed artifact that
/// is not there is a real defect, not a retired runtime).
@Suite("Cloud-compiled WASI artifact through the command runtime")
struct CloudCompiledArtifactTests {
    /// Static so the condition trait can read it before any instance exists.
    private static var archivedCloudArtifactAvailable: Bool {
        guard let path = ProcessInfo.processInfo.environment["FLOE_CLOUD_WASI"] else { return false }
        return !path.isEmpty
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func artifact() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["FLOE_CLOUD_WASI"], !path.isEmpty else {
            throw FloeError.invalidConfiguration("FLOE_CLOUD_WASI must name the cloud-compiled module")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FloeError.invalidConfiguration("cloud module missing at \(path)")
        }
        return url
    }

    private func run(arguments: [String], root: URL, timeout: TimeInterval = 60) async throws -> ShellRunOutcome {
        // Cloud artifacts are not catalog-bound, so the qualification host runs
        // them with the reviewed interpreter-class ceiling (module ≤ 64 MiB,
        // memory ≤ 256 MiB). A module above the ceiling could never be signed
        // into the catalog, so refusing it here matches the device boundary.
        await WasmKitCommandRuntime().run(
            moduleURL: try artifact(), arguments: arguments, stdin: nil, environment: [:],
            rootURL: root, workingDirectory: ".", timeout: timeout, maxOutputBytes: 256 * 1024,
            moduleMaxBytes: 64 * 1024 * 1024, memoryMaxBytes: 256 * 1024 * 1024)
    }

    @Test(.enabled(if: Self.archivedCloudArtifactAvailable, "cloud-compiled WASI language delivery is retired; set FLOE_CLOUD_WASI to qualify an archived artifact"))
    func helloFileIOAndArgumentsInTheWorkspaceJail() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let arguments = (ProcessInfo.processInfo.environment["FLOE_CLOUD_ARGS"] ?? "alpha beta")
            .split(separator: " ").map(String.init)
        guard case .exited(let code, let stdout, _, _, _, _) = try await run(arguments: arguments, root: root) else {
            Issue.record("Cloud artifact did not produce an exit outcome"); return
        }
        #expect(code == 0)
        #expect(stdout.contains("hello"))
        #expect(stdout.contains("42"))
        #expect(stdout.contains("args=" + arguments.joined(separator: ",")))
        let written = try String(contentsOf: root.appendingPathComponent("hello.txt"), encoding: .utf8)
        #expect(written == "sum=42 args=" + arguments.joined(separator: ",") + "\n")
    }

    @Test(.enabled(if: Self.archivedCloudArtifactAvailable, "cloud-compiled WASI language delivery is retired; set FLOE_CLOUD_WASI to qualify an archived artifact"))
    func errorPathExitsWithItsOwnCode() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .exited(let code, let stdout, let stderr, _, _, _) = try await run(arguments: ["fail"], root: root) else {
            Issue.record("Cloud artifact error path did not produce an exit outcome"); return
        }
        #expect(code == 3)
        #expect(stdout.contains("fail-ok") || stderr.contains("fail-ok"))
    }
}

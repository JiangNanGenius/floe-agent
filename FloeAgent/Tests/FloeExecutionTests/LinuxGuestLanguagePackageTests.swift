// FloeExecutionTests — Linux environment language package ownership.
//
// These checks target the real regression: an environment whose execution
// backend is `linuxVM` must install, remove and list Python/Node packages
// inside its own guest (shared venv, environment `usr/lib/node_modules`),
// while an owned-but-stopped guest reports the honest not-running error and
// never touches the host-side layer or the iOS Node runtime.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

/// Records every guest invocation and answers from a scripted handler.
final class ScriptedLinuxCommandRunner: LinuxCommandRunning, @unchecked Sendable {
    struct Call: Sendable {
        var argv: [String]
        var workingDirectory: String?
        var standardInput: String?
        var joined: String { argv.joined(separator: " ") }
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var handler: (@Sendable ([String], String?, String?) -> LinuxCommandResult)?
    var owns = true
    var supports = true

    init(handler: (@Sendable ([String], String?, String?) -> LinuxCommandResult)? = nil) {
        self.handler = handler
    }

    func setHandler(_ handler: @escaping @Sendable ([String], String?, String?) -> LinuxCommandResult) {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    var calls: [Call] { lock.withLock { recorded } }

    func supports(environmentID: String) async -> Bool { supports }
    func ownsLinuxEnvironment(environmentID: String) async -> Bool { owns }

    func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        let handler = lock.withLock { () -> (@Sendable ([String], String?, String?) -> LinuxCommandResult)? in
            recorded.append(Call(argv: argv, workingDirectory: workingDirectory, standardInput: standardInput))
            return self.handler
        }
        return handler?(argv, workingDirectory, standardInput) ?? LinuxCommandResult(stdout: "", stderr: "", exitCode: 0)
    }
}

final class LinuxGuestLanguagePackageTests: XCTestCase {
    private func makeEnvironment(_ id: String, layer: URL) -> ToolEnvironment {
        ToolEnvironment(id: id, writableLayerURL: layer, layerURLs: [layer], variables: [:])
    }

    private func makeLayer() throws -> (id: String, layer: URL) {
        let id = "env-language-\(UUID().uuidString)"
        let layer = FileManager.default.temporaryDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: layer, withIntermediateDirectories: true)
        return (id, layer)
    }

    private static func pythonProvisioningAnswers(_ argv: [String]) -> LinuxCommandResult? {
        if argv.contains(where: { $0.contains("sysconfig.get_paths") }) {
            return LinuxCommandResult(stdout: "/floe/env/python/venv/lib/python3.13/site-packages\n", stderr: "", exitCode: 0)
        }
        if argv.contains(where: { $0.contains("bin/pip") }) {
            return LinuxCommandResult(stdout: "pip-ok\n", stderr: "", exitCode: 0)
        }
        if argv.contains("--version") {
            return LinuxCommandResult(stdout: "Python 3.13.5\n", stderr: "", exitCode: 0)
        }
        return nil
    }

    // MARK: Python

    func testPythonInstallRunsRealGuestPipInTheSharedVenv() async throws {
        let (environmentID, layer) = try makeLayer()
        defer { try? FileManager.default.removeItem(at: layer) }
        try LanguagePackageSources(pythonIndex: "https://mirror.example.com/simple/").save(in: layer)
        let runner = ScriptedLinuxCommandRunner { argv, _, _ in
            if let provision = Self.pythonProvisioningAnswers(argv) { return provision }
            if argv.contains(where: { $0.contains("floePythonInventory") }) {
                return LinuxCommandResult(
                    stdout: "floePythonInventory=[{\"name\":\"demo\",\"version\":\"1.0\",\"location\":\"/floe/env/python/venv/lib/python3.13/site-packages\",\"writable\":true}]\n",
                    stderr: "", exitCode: 0
                )
            }
            return LinuxCommandResult(stdout: "Successfully installed demo-1.0\n", stderr: "", exitCode: 0)
        }
        let packages = LinuxGuestLanguagePackages(runner: runner)
        let environment = makeEnvironment(environmentID, layer: layer)
        let output = try await packages.pythonInstall(specs: ["demo==1.0"], environment: environment, cancellation: nil)
        await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID)

        XCTAssertTrue(output.contains("Successfully installed demo-1.0"), output)
        let install = try XCTUnwrap(runner.calls.first { call in
            call.argv.contains("-m") && call.argv.contains("pip") && call.argv.contains("install")
        })
        XCTAssertEqual(install.argv.first, "/usr/bin/env")
        XCTAssertTrue(install.argv.contains("/floe/env/python/venv/bin/python3"), install.joined)
        XCTAssertTrue(install.argv.contains("demo==1.0"))
        XCTAssertTrue(install.argv.contains("PIP_INDEX_URL=https://mirror.example.com/simple/"), install.joined)
        XCTAssertTrue(install.argv.contains("PIP_CACHE_DIR=/floe/env/cache/pip"), install.joined)
        XCTAssertFalse(install.joined.contains("--only-binary"), install.joined)
        XCTAssertFalse(install.joined.contains("--platform any"), install.joined)
        // The host layer path (a macOS path) never reaches the guest.
        XCTAssertFalse(install.joined.contains(layer.path), install.joined)
        XCTAssertNil(install.workingDirectory)
    }

    func testPythonUninstallAndInspectUseTheVenvEntryPoints() async throws {
        let (environmentID, layer) = try makeLayer()
        defer { try? FileManager.default.removeItem(at: layer) }
        let runner = ScriptedLinuxCommandRunner { argv, _, _ in
            if let provision = Self.pythonProvisioningAnswers(argv) { return provision }
            return LinuxCommandResult(stdout: "ok\n", stderr: "", exitCode: 0)
        }
        let packages = LinuxGuestLanguagePackages(runner: runner)
        let environment = makeEnvironment(environmentID, layer: layer)
        _ = try await packages.pythonUninstall(distribution: "demo", environment: environment, cancellation: nil)
        _ = try await packages.pythonInspect(command: "list", arguments: ["--format=json"], environment: environment, cancellation: nil)
        await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID)

        let uninstall = try XCTUnwrap(runner.calls.first { $0.argv.contains("uninstall") })
        XCTAssertEqual(uninstall.argv, ["/floe/env/python/venv/bin/pip", "uninstall", "-y", "demo"])
        let inspect = try XCTUnwrap(runner.calls.first { $0.argv.contains("-m") && $0.argv.contains("pip") })
        XCTAssertEqual(Array(inspect.argv.suffix(3)), ["pip", "list", "--format=json"])
    }

    func testPythonInventoryParsesVenvAndSystemRows() async throws {
        let (environmentID, layer) = try makeLayer()
        defer { try? FileManager.default.removeItem(at: layer) }
        let runner = ScriptedLinuxCommandRunner { argv, _, _ in
            if let provision = Self.pythonProvisioningAnswers(argv) { return provision }
            return LinuxCommandResult(
                stdout: "floePythonInventory=[{\"name\":\"demo\",\"version\":\"1.0\",\"location\":\"/floe/env/python/venv/lib/python3.13/site-packages\",\"writable\":true},{\"name\":\"system-pkg\",\"version\":\"2.0\",\"location\":\"/usr/lib/python3/dist-packages\",\"writable\":false}]\n",
                stderr: "", exitCode: 0
            )
        }
        let environment = makeEnvironment(environmentID, layer: layer)
        let rows = try await LinuxGuestLanguagePackages(runner: runner)
            .pythonInventory(environment: environment, cancellation: nil)
        await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.name, "demo")
        XCTAssertEqual(rows.first?.writable, true)
        XCTAssertEqual(rows.last?.writable, false)
    }

    func testOwnedButStoppedPythonChangeNeverFallsBackToHost() async throws {
        let (environmentID, layer) = try makeLayer()
        defer { try? FileManager.default.removeItem(at: layer) }
        let runner = ScriptedLinuxCommandRunner()
        runner.owns = true
        runner.supports = false
        let service = ManagedPythonInstallService(linux: LinuxGuestLanguagePackages(runner: runner))
        let environment = makeEnvironment(environmentID, layer: layer)
        let outcome = await service.install(specs: ["demo==1.0"], cancellation: nil, environment: environment)

        guard case .failed(let message) = outcome else {
            return XCTFail("A stopped Linux guest must fail the install")
        }
        XCTAssertTrue(message.contains("not running"), message)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testInstallServiceAnswersLinuxOwnershipEvenWhileStopped() async throws {
        let (environmentID, layer) = try makeLayer()
        defer { try? FileManager.default.removeItem(at: layer) }
        let runner = ScriptedLinuxCommandRunner()
        runner.owns = true
        runner.supports = false
        let service = ManagedPythonInstallService(linux: LinuxGuestLanguagePackages(runner: runner))
        let environment = makeEnvironment(environmentID, layer: layer)
        // Ownership answers without touching the guest, so exec.localPython
        // can skip native script policy before the guest is started.
        let owned = await service.isLinuxGuestEnvironment(environment)
        XCTAssertTrue(owned)
        XCTAssertTrue(runner.calls.isEmpty)
        let nativeRunner = ScriptedLinuxCommandRunner()
        nativeRunner.owns = false
        let nativeService = ManagedPythonInstallService(linux: LinuxGuestLanguagePackages(runner: nativeRunner))
        let native = await nativeService.isLinuxGuestEnvironment(makeEnvironment("native-\(UUID().uuidString)", layer: layer))
        XCTAssertFalse(native)
        XCTAssertTrue(nativeRunner.calls.isEmpty)
    }

    func testNativeEnvironmentFailsHonestlyWithoutHostFallback() async throws {
        // Phase 2: the bundled interpreter is gone. A native-backend
        // environment gets the honest Linux-required failure; nothing runs
        // on the host and nothing touches the guest runner.
        let (environmentID, layer) = try makeLayer()
        defer { try? FileManager.default.removeItem(at: layer) }
        let runner = ScriptedLinuxCommandRunner()
        runner.owns = false
        let service = ManagedPythonInstallService(linux: LinuxGuestLanguagePackages(runner: runner))
        let environment = makeEnvironment(environmentID, layer: layer)
        let outcome = await service.install(specs: ["demo==1.0"], cancellation: nil, environment: environment)

        guard case .failed(let message) = outcome else {
            return XCTFail("A native environment must not install packages")
        }
        XCTAssertTrue(message.contains("Linux"), message)
        XCTAssertTrue(runner.calls.isEmpty)
        let removed = await service.uninstall(distribution: "demo", environment: environment, cancellation: nil)
        guard case .failed = removed else {
            return XCTFail("A native environment must not uninstall packages")
        }
        XCTAssertTrue(runner.calls.isEmpty)
        let distributions = await service.installedDistributions(environment: environment)
        XCTAssertEqual(distributions, [])
    }

    // MARK: Node

    private func nodeRunner(
        state: String = "",
        managerOutput: String = "added 1 package\n",
        managerExitCode: Int32 = 0,
        onManager: (@Sendable ([String], String?) -> Void)? = nil
    ) -> ScriptedLinuxCommandRunner {
        ScriptedLinuxCommandRunner { argv, workingDirectory, _ in
            let joined = argv.joined(separator: " ")
            if joined.contains("command -v") {
                return LinuxCommandResult(stdout: "floe-manager node=/usr/bin/node\nfloe-manager npm=/usr/bin/npm\nfloe-manager pnpm=\n", stderr: "", exitCode: 0)
            }
            if joined.contains("node") && argv.contains("--version") {
                return LinuxCommandResult(stdout: "v20.19.0\n", stderr: "", exitCode: 0)
            }
            if joined.contains("floeDest") || joined.contains("floePkg") {
                return LinuxCommandResult(stdout: state, stderr: "", exitCode: 0)
            }
            if joined.contains("journal") { return LinuxCommandResult(stdout: "", stderr: "", exitCode: 0) }
            if joined.contains("prepared") { return LinuxCommandResult(stdout: "", stderr: "", exitCode: 0) }
            if joined.contains("bin-link.js") { return LinuxCommandResult(stdout: "floeNodeBins=demo-cli\n", stderr: "", exitCode: 0) }
            if argv.contains("/usr/bin/npm") || argv.contains("/usr/bin/pnpm") {
                onManager?(argv, workingDirectory)
                return LinuxCommandResult(stdout: managerOutput, stderr: "", exitCode: managerExitCode)
            }
            return LinuxCommandResult(stdout: "", stderr: "", exitCode: 0)
        }
    }

    func testNodeChangeRunsGuestManagerInsideTheLayerTransaction() async throws {
        let (environmentID, layer) = try makeLayer()
        defer { try? FileManager.default.removeItem(at: layer) }
        try LanguagePackageSources(nodeRegistry: "https://registry.example.com/").save(in: layer)
        let managerCalls = ManagerCallRecorder()
        let runner = nodeRunner { argv, workingDirectory in
            managerCalls.record(argv: argv, workingDirectory: workingDirectory)
        }
        let packages = LinuxGuestLanguagePackages(runner: runner)
        let environment = makeEnvironment(environmentID, layer: layer)
        let output = try await packages.nodeChange(
            environment: environment,
            specifications: ["demo@1.0.0"],
            remove: false,
            manager: .npm,
            cancellation: nil
        )
        await LinuxGuestNodeProvisioner.shared.forget(environmentID: environmentID)

        XCTAssertTrue(output.contains("added 1 package"), output)
        let manager = try XCTUnwrap(managerCalls.first)
        XCTAssertEqual(manager.workingDirectory, "/floe/env/var/floe-node-transaction/stage")
        XCTAssertTrue(manager.argv.contains("/usr/bin/npm"))
        XCTAssertTrue(manager.argv.contains("install"))
        XCTAssertTrue(manager.argv.contains("--registry=https://registry.example.com/"), manager.argv.joined(separator: " "))
        // Linux keeps real npm semantics: scripts, bin links and native addons.
        XCTAssertFalse(manager.argv.contains("--ignore-scripts"), manager.argv.joined(separator: " "))
        XCTAssertFalse(manager.argv.contains("--bin-links=false"), manager.argv.joined(separator: " "))
        XCTAssertTrue(manager.argv.contains("npm_config_prefix=/floe/env/var/floe-node-transaction/stage"))
        XCTAssertTrue(manager.argv.contains("HOME=/floe/env/home"))
        // No host layer path and no host Node runtime anywhere.
        for call in runner.calls {
            XCTAssertFalse(call.joined.contains(layer.path), call.joined)
            XCTAssertFalse(call.joined.contains("nodejs-mobile"), call.joined)
        }
        // The commit runs in the guest, swaps the layer directory and links
        // CLIs into the environment bin directory.
        let commit = try XCTUnwrap(runner.calls.first {
            $0.joined.contains("bin-link.js") && $0.joined.contains("/floe/env/usr/bin")
        }, "commit script must run the bin link step")
        XCTAssertTrue(commit.joined.contains("/floe/env/usr/lib/node_modules"), commit.joined)
        XCTAssertTrue(commit.joined.contains("mv \"$stage/node_modules\""), commit.joined)
        XCTAssertTrue(LinuxGuestLanguagePackages.nodeBinLinkScript.contains("/floe/env/usr/bin"))
        // Staging metadata records the dependency generation in the layer.
        let metadata = try XCTUnwrap(runner.calls.first { $0.joined.contains("dependencies.json") })
        XCTAssertTrue(metadata.joined.contains("/floe/env/var/floe-node-transaction/stage/node_modules/.floe-install"), metadata.joined)
    }

    func testNodeRemoveRejectsAPackageThisLayerDidNotInstall() async throws {
        let (environmentID, layer) = try makeLayer()
        defer { try? FileManager.default.removeItem(at: layer) }
        let dependencies = try JSONSerialization.data(withJSONObject: ["other": "1.0.0"], options: [.sortedKeys])
        let state = "floeDest 1\nfloeMeta dependencies.json " + dependencies.base64EncodedString() + "\n"
        let runner = nodeRunner(state: state)
        let packages = LinuxGuestLanguagePackages(runner: runner)
        let environment = makeEnvironment(environmentID, layer: layer)
        do {
            _ = try await packages.nodeChange(
                environment: environment,
                specifications: ["demo"],
                remove: true,
                manager: .npm,
                cancellation: nil
            )
            XCTFail("Removing a package this layer did not install must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("直接安装"), error.localizedDescription)
        }
        XCTAssertFalse(runner.calls.contains { $0.argv.contains("/usr/bin/npm") })
    }

    func testNodeChangeAndInventoryFailHonestlyWhenGuestStopped() async throws {
        let (environmentID, layer) = try makeLayer()
        defer { try? FileManager.default.removeItem(at: layer) }
        let runner = ScriptedLinuxCommandRunner()
        runner.owns = true
        runner.supports = false
        let packages = LinuxGuestLanguagePackages(runner: runner)
        let environment = makeEnvironment(environmentID, layer: layer)
        do {
            _ = try await packages.nodeChange(
                environment: environment,
                specifications: ["demo@1.0.0"],
                remove: false,
                manager: .npm,
                cancellation: nil
            )
            XCTFail("A stopped guest must not accept a Node change")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not running"), error.localizedDescription)
        }
        do {
            _ = try await packages.nodeInventory(environment: environment, cancellation: nil)
            XCTFail("A stopped guest must not answer inventory")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not running"), error.localizedDescription)
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testNodeInventoryReadsEnvironmentNodeModules() async throws {
        let (environmentID, layer) = try makeLayer()
        defer { try? FileManager.default.removeItem(at: layer) }
        let manifest = try JSONSerialization.data(withJSONObject: ["name": "demo-cli", "version": "2.1.0"])
        let state = "floePkg /floe/env/usr/lib/node_modules/demo-cli/package.json " + manifest.base64EncodedString() + "\n"
        let runner = nodeRunner(state: state)
        let environment = makeEnvironment(environmentID, layer: layer)
        let rows = try await LinuxGuestLanguagePackages(runner: runner)
            .nodeInventory(environment: environment, cancellation: nil)
        XCTAssertEqual(rows, [LinuxGuestNodePackage(name: "demo-cli", version: "2.1.0", path: "/floe/env/usr/lib/node_modules/demo-cli/package.json")])
    }

    func testNodePnpmRequiresAnExplicitGuestManager() async throws {
        let (environmentID, layer) = try makeLayer()
        defer { try? FileManager.default.removeItem(at: layer) }
        let runner = nodeRunner()
        let packages = LinuxGuestLanguagePackages(runner: runner)
        let environment = makeEnvironment(environmentID, layer: layer)
        do {
            _ = try await packages.nodeChange(
                environment: environment,
                specifications: ["demo@1.0.0"],
                remove: false,
                manager: .pnpm,
                cancellation: nil
            )
            XCTFail("pnpm was not found in the guest; the change must report it")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("pnpm"), error.localizedDescription)
        }
        XCTAssertFalse(runner.calls.contains { $0.argv.contains("apt-get") && $0.argv.contains("pnpm") })
    }

    // MARK: exec.localPython gate

    func testValidateNoLongerAppliesNativePolicyBeforeBackendIsKnown() throws {
        let python = LocalPythonService(version: "host") { _, _ in return .cancelled }
        let tool = LocalPythonTool(service: python)
        // The bundled-interpreter restriction now runs in execute(), where the
        // environment ownership is known; the Linux guest's Python may use
        // pip/subprocess like the native python3 it replaces.
        XCTAssertNoThrow(try tool.validate(LocalPythonTool.Arguments(script: "import subprocess; subprocess.run(['true'])")))
        XCTAssertThrowsError(try tool.validate(LocalPythonTool.Arguments(script: "")))
    }

    func testForgetDropsCachedGuestEnvironment() async throws {        let (environmentID, layer) = try makeLayer()
        defer { try? FileManager.default.removeItem(at: layer) }
        let runner = nodeRunner()
        let provisioner = LinuxGuestNodeProvisioner()
        _ = try await provisioner.ensure(environmentID: environmentID, runner: runner, cancellation: nil)
        let cached = await provisioner.environment(for: environmentID)
        XCTAssertNotNil(cached)
        await provisioner.forget(environmentID: environmentID)
        let afterForget = await provisioner.environment(for: environmentID)
        XCTAssertNil(afterForget)
    }
}

private final class ManagerCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(argv: [String], workingDirectory: String?)] = []
    func record(argv: [String], workingDirectory: String?) {
        lock.withLock { calls.append((argv, workingDirectory)) }
    }
    var first: (argv: [String], workingDirectory: String?)? { lock.withLock { calls.first } }
}

import Foundation
import Testing
import FloeCore
import FloeEnvironments
import FloePackages
import FloeTools

private actor RouterLog {
    var installed: [String] = []
    var removed: [String] = []
    var cancelNextInstall = false

    func record(install id: String) { installed.append(id) }
    func record(remove id: String) { removed.append(id) }
    func shouldCancelInstall() -> Bool {
        defer { cancelNextInstall = false }
        return cancelNextInstall
    }
}

private struct FakeWasmRouter: WasmCapabilityRouter {
    let log: RouterLog
    var infos: [WasmCapabilityInfo]
    var failingInstalls: Set<String> = []
    var failingRemoves: Set<String> = []

    func capabilities() async -> [WasmCapabilityInfo] { infos }

    func resolve(operand: String) async -> WasmCapabilityInfo? {
        let normalized = operand.lowercased()
        return infos.first {
            $0.id.lowercased() == normalized || $0.command.lowercased() == normalized
        }
    }

    func install(id: String, cancellation: CancellationToken?) async throws -> String {
        if await log.shouldCancelInstall() { throw FloeError.cancelled }
        if failingInstalls.contains(id) { throw FloeError.validationFailed("artifact rejected") }
        await log.record(install: id)
        return "fake install detail"
    }

    func remove(id: String) async throws -> String {
        if failingRemoves.contains(id) { throw FloeError.validationFailed("artifact busy") }
        await log.record(remove: id)
        return ""
    }
}

@Suite("Signed WASM capability routing through apt/pkg")
struct WasmCapabilityRoutingTests {
    private let lua = WasmCapabilityInfo(
        id: "floe/lua", command: "floe-lua", version: "5.4.8",
        summary: "Signed WASI command (verified catalog)", installed: false
    )

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeCLI(root: URL, router: (any WasmCapabilityRouter)?) -> PackagesCLI {
        let engine = AptEngine(downloader: .init { _, _ in throw AptEngine.Downloader.Failure.notFound })
        let container = AptEngine.Container(
            id: "routing-tests", rootURL: root, layerURL: root,
            layerKind: .project, baseRevision: "test"
        )
        return PackagesCLI(engine: engine, contextProvider: {
            .init(container: container, sources: [], layerURL: root,
                  installed: DpkgDatabase.readStatus(at: root))
        }, wasmRouter: router)
    }

    @Test func searchSurfacesSignedWasmCapabilities() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = makeCLI(root: root, router: FakeWasmRouter(log: RouterLog(), infos: [lua]))
        let result = await cli.run(command: "apt", arguments: ["apt", "search", "lua"])
        #expect(result.exitCode == 0)
        #expect(result.output.contains("floe/lua"))
        #expect(result.output.contains("floe-lua 5.4.8"))
        #expect(result.output.contains("[available]"))
    }

    @Test func searchOmitsWasmCapabilitiesThatDoNotMatch() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = makeCLI(root: root, router: FakeWasmRouter(log: RouterLog(), infos: [lua]))
        let result = await cli.run(command: "apt", arguments: ["apt", "search", "zlib"])
        #expect(!result.output.contains("floe/lua"))
    }

    @Test func showPrintsAWasmStanzaWithoutTouchingTheDebIndex() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = makeCLI(root: root, router: FakeWasmRouter(log: RouterLog(), infos: [lua]))
        let result = await cli.run(command: "apt", arguments: ["apt", "show", "floe/lua"])
        #expect(result.exitCode == 0)
        #expect(result.output.contains("Package: floe/lua"))
        #expect(result.output.contains("Version: 5.4.8"))
        #expect(result.output.contains("Floe-Kind: signed-wasm-command"))
        #expect(result.output.contains("Floe-Command: floe-lua"))
    }

    @Test func showFallsThroughToTheDebIndexForUnknownNames() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = makeCLI(root: root, router: FakeWasmRouter(log: RouterLog(), infos: [lua]))
        let result = await cli.run(command: "apt", arguments: ["apt", "show", "zlib1g"])
        #expect(result.exitCode == 100)
        #expect(result.output.contains("E: No packages found"))
    }

    @Test func installRoutesSignedWasmWithoutTouchingTheDebEngine() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RouterLog()
        let cli = makeCLI(root: root, router: FakeWasmRouter(log: log, infos: [lua]))
        let result = await cli.run(command: "apt", arguments: ["apt", "install", "floe/lua"])
        #expect(result.exitCode == 0)
        #expect(result.output.contains("Setting up floe/lua (5.4.8)"))
        #expect(await log.installed == ["floe/lua"])
        // The Debian engine and dpkg database must stay untouched: a signed
        // WASM artifact is never installed as a .deb into the layer.
        #expect(DpkgDatabase.readStatus(at: root).isEmpty)
        #expect(result.output.contains("E:") == false)
    }

    @Test func installResolvesTheCanonicalCommandNameToo() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RouterLog()
        let cli = makeCLI(root: root, router: FakeWasmRouter(log: log, infos: [lua]))
        let result = await cli.run(command: "apt", arguments: ["apt", "install", "floe-lua"])
        #expect(result.exitCode == 0)
        #expect(await log.installed == ["floe/lua"])
    }

    @Test func installUnknownNamesKeepTheExistingDebError() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RouterLog()
        let cli = makeCLI(root: root, router: FakeWasmRouter(log: log, infos: [lua]))
        let result = await cli.run(command: "apt", arguments: ["apt", "install", "zlib1g"])
        #expect(result.exitCode == 100)
        #expect(result.output.hasPrefix("E:"))
        #expect(await log.installed.isEmpty)
    }

    @Test func cancelledWasmInstallExits130WithoutDebFallback() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RouterLog()
        await log.setCancelNextInstall()
        let cli = makeCLI(root: root, router: FakeWasmRouter(log: log, infos: [lua]))
        let result = await cli.run(command: "apt", arguments: ["apt", "install", "floe/lua"])
        #expect(result.exitCode == 130)
        #expect(result.output.contains("cancelled"))
        #expect(await log.installed.isEmpty)
        #expect(DpkgDatabase.readStatus(at: root).isEmpty)
    }

    @Test func removeRoutesSignedWasmWithoutTouchingTheDebEngine() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RouterLog()
        let cli = makeCLI(root: root, router: FakeWasmRouter(log: log, infos: [lua]))
        let result = await cli.run(command: "apt", arguments: ["apt", "remove", "floe-lua"])
        #expect(result.exitCode == 0)
        #expect(result.output.contains("Removing floe/lua (5.4.8)"))
        #expect(await log.removed == ["floe/lua"])
        #expect(DpkgDatabase.readStatus(at: root).isEmpty)
    }

    @Test func installRejectsMixedWasmAndDebianBeforeMutatingEitherStore() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RouterLog()
        let cli = makeCLI(root: root, router: FakeWasmRouter(log: log, infos: [lua]))
        let result = await cli.run(command: "apt", arguments: ["apt", "install", "floe/lua", "zlib1g"])
        #expect(result.exitCode == 100)
        #expect(result.output.contains("cannot install"))
        #expect(result.output.contains("No changes made"))
        #expect(await log.installed.isEmpty)
        #expect(DpkgDatabase.readStatus(at: root).isEmpty)
    }

    @Test func removeRejectsMixedWasmAndDebianBeforeMutatingEitherStore() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RouterLog()
        let cli = makeCLI(root: root, router: FakeWasmRouter(log: log, infos: [lua]))
        let result = await cli.run(command: "apt", arguments: ["apt", "remove", "floe-lua", "zlib1g"])
        #expect(result.exitCode == 100)
        #expect(result.output.contains("cannot remove"))
        #expect(await log.removed.isEmpty)
    }

    @Test func wasmInstallKeepsEarlierSuccessWhenALaterOperandFails() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RouterLog()
        let text = WasmCapabilityInfo(
            id: "floe/wasm-text", command: "floe-text", version: "1.0.0",
            summary: "Signed WASI command (verified catalog)", installed: false
        )
        let router = FakeWasmRouter(log: log, infos: [lua, text], failingInstalls: ["floe/wasm-text"])
        let cli = makeCLI(root: root, router: router)
        let result = await cli.run(command: "apt", arguments: ["apt", "install", "floe/lua", "floe/wasm-text"])
        #expect(result.exitCode == 100)
        // The successful first install must remain visible, not be erased by
        // the later failure.
        #expect(result.output.contains("Setting up floe/lua (5.4.8)"))
        #expect(result.output.contains("Setting up floe/wasm-text") == false)
        #expect(result.output.contains("E: floe/wasm-text"))
        #expect(await log.installed == ["floe/lua"])
    }

    @Test func wasmRemoveKeepsEarlierSuccessWhenALaterOperandFails() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = RouterLog()
        let text = WasmCapabilityInfo(
            id: "floe/wasm-text", command: "floe-text", version: "1.0.0",
            summary: "Signed WASI command (verified catalog)", installed: true
        )
        let router = FakeWasmRouter(log: log, infos: [lua, text], failingRemoves: ["floe/wasm-text"])
        let cli = makeCLI(root: root, router: router)
        let result = await cli.run(command: "apt", arguments: ["apt", "purge", "floe/lua", "floe/wasm-text"])
        #expect(result.exitCode == 100)
        #expect(result.output.contains("Removing floe/lua (5.4.8)"))
        #expect(result.output.contains("E: floe/wasm-text"))
        #expect(await log.removed == ["floe/lua"])
    }

    @Test func listInstalledMarksWasmState() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var installedLua = lua
        installedLua.installed = true
        let text = WasmCapabilityInfo(
            id: "floe/wasm-text", command: "floe-text", version: "1.0.0",
            summary: "Signed WASI command (verified catalog)", installed: false
        )
        let cli = makeCLI(root: root, router: FakeWasmRouter(log: RouterLog(), infos: [installedLua, text]))
        let available = await cli.run(command: "apt", arguments: ["apt", "list"])
        #expect(available.output.contains("floe/lua/wasm 5.4.8 wasi [installed]"))
        #expect(available.output.contains("floe/wasm-text/wasm 1.0.0 wasi [available]"))
        let installedOnly = await cli.run(command: "apt", arguments: ["apt", "list", "--installed"])
        #expect(installedOnly.output.contains("floe/lua"))
        #expect(!installedOnly.output.contains("floe/wasm-text"))
    }

    @Test func withoutASignedStoreThereIsNoFakeCapability() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // No router: floe/lua must not magically resolve; it falls through to
        // the Debian engine and fails honestly instead of claiming success.
        let cli = makeCLI(root: root, router: nil)
        let result = await cli.run(command: "apt", arguments: ["apt", "install", "floe/lua"])
        #expect(result.exitCode == 100)
        #expect(result.output.hasPrefix("E:"))
        let show = await cli.run(command: "apt", arguments: ["apt", "show", "floe/lua"])
        #expect(show.exitCode == 100)
    }
}

extension RouterLog {
    func setCancelNextInstall() { cancelNextInstall = true }
}

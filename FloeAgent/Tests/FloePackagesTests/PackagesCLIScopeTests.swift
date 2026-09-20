import Foundation
import Testing
import FloeCore
import FloeEnvironments
import FloePackages
import FloeTools

/// APT scope guard: PackagesCLI serves Debian packages only. Signed WASM
/// capabilities, Python and Node packages have their own entries, so operands
/// naming them fall through to the Debian engine and fail honestly instead of
/// being installed as or alongside .deb packages.
@Suite("PackagesCLI Debian-only scope")
struct PackagesCLIScopeTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeCLI(root: URL) -> PackagesCLI {
        let engine = AptEngine(downloader: .init { _, _ in throw AptEngine.Downloader.Failure.notFound })
        let container = AptEngine.Container(
            id: "scope-tests", rootURL: root, layerURL: root,
            layerKind: .project, baseRevision: "test"
        )
        return PackagesCLI(engine: engine, contextProvider: {
            .init(container: container, sources: [], layerURL: root,
                  installed: DpkgDatabase.readStatus(at: root))
        })
    }

    @Test func wasmCapabilityNamesAreNotResolvedOrInstalled() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = makeCLI(root: root)
        let install = await cli.run(command: "apt", arguments: ["apt", "install", "floe/lua"])
        #expect(install.exitCode == 100)
        #expect(install.output.hasPrefix("E:"))
        #expect(!install.output.contains("Setting up floe/lua"))
        // The dpkg database stays untouched: nothing is faked as a .deb.
        #expect(DpkgDatabase.readStatus(at: root).isEmpty)

        let show = await cli.run(command: "apt", arguments: ["apt", "show", "floe/lua"])
        #expect(show.exitCode == 100)
        #expect(show.output.contains("E: No packages found"))
        #expect(!show.output.contains("signed-wasm-command"))

        let search = await cli.run(command: "apt", arguments: ["apt", "search", "lua"])
        #expect(!search.output.contains("floe/lua"))

        let list = await cli.run(command: "apt", arguments: ["apt", "list"])
        #expect(!list.output.contains("floe/"))
    }

    @Test func unknownDebianNamesKeepTheHonestFailure() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = makeCLI(root: root)
        let result = await cli.run(command: "apt", arguments: ["apt", "install", "zlib1g"])
        #expect(result.exitCode == 100)
        #expect(result.output.hasPrefix("E:"))
        #expect(DpkgDatabase.readStatus(at: root).isEmpty)
    }

    @Test func helpNamesTheSeparateFamilies() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = makeCLI(root: root)
        let help = await cli.run(command: "apt", arguments: ["apt", "--help"])
        #expect(help.exitCode == 0)
        #expect(help.output.contains("Debian packages only"))
        #expect(!help.output.contains("install app-wide through the same command"))
    }
}

import Foundation
import Testing
import FloePackages
import FloeEnvironments

@Suite("Publisher to client package installation")
struct RepositoryInstallTests {
    private func engine(corruptDeb: Bool = false) throws -> AptEngine {
        let root = try #require(Bundle.module.url(forResource: "Repository", withExtension: nil, subdirectory: "Fixtures"))
        let keys = try OpenPGP.parseKeyring(Data(contentsOf: root.appendingPathComponent("repo-key.asc")))
        return AptEngine(downloader: .init { url, maxBytes in
            let path = String(url.path.dropFirst())
            let file = try PackageTransaction.location(path, root: root)
            var data = try Data(contentsOf: file)
            if corruptDeb && url.pathExtension == "deb" { data[0] ^= 1 }
            guard data.count <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
            return data
        }, trustedKeys: keys)
    }
    private func update(_ engine: AptEngine, root: URL) async throws -> AptEngine.Container {
        let container = AptEngine.Container(id: UUID().uuidString, rootURL: root, layerURL: root, layerKind: .project, baseRevision: "one")
        let report = await engine.update(container: container, sources: [.init(uri: "https://example.invalid", suite: "floe-qualification", components: ["data"])])
        #expect(report.failures.isEmpty, "\(report.failures)")
        #expect(report.packages == 5)
        return container
    }

    @Test func signedInstallUpgradeDependencyAndOwnedRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try engine(), container = try await update(engine, root: root)
        _ = try await engine.install(["floe-fixture=1.0"], container: container)
        let path = root.appendingPathComponent("usr/share/floe-fixture/value.txt")
        #expect(try String(contentsOf: path, encoding: .utf8) == "one")
        let steps = try await engine.install(["floe-dependent"], container: container)
        #expect(steps.map(\.package) == ["floe-fixture", "floe-dependent"])
        #expect(try String(contentsOf: path, encoding: .utf8) == "two")
        #expect(DpkgDatabase.readStatus(at: root).first(where: { $0.name == "floe-fixture" })?.version == "2.0")
        await #expect(throws: (any Error).self) { try await engine.remove(["floe-fixture"], container: container, purge: false) }
        let unrelated = root.appendingPathComponent("usr/share/keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        _ = try await engine.remove(["floe-dependent", "floe-fixture"], container: container, purge: false)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(try Data(contentsOf: unrelated) == Data("keep".utf8))
        #expect(DpkgDatabase.readStatus(at: root).isEmpty)
    }

    @Test func collisionsScriptsAndLocalEditsFailBeforeMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try engine(), container = try await update(engine, root: root)
        _ = try await engine.install(["floe-fixture=1.0"], container: container)
        let path = root.appendingPathComponent("usr/share/floe-fixture/value.txt")
        await #expect(throws: (any Error).self) { try await engine.install(["floe-collision"], container: container) }
        await #expect(throws: (any Error).self) { try await engine.install(["floe-scripted"], container: container) }
        #expect(try String(contentsOf: path, encoding: .utf8) == "one")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("usr/share/floe-scripted/value.txt").path))
        try Data("local edit".utf8).write(to: path)
        await #expect(throws: (any Error).self) { try await engine.install(["floe-fixture"], container: container) }
        await #expect(throws: (any Error).self) { try await engine.remove(["floe-fixture"], container: container, purge: true) }
        #expect(try String(contentsOf: path, encoding: .utf8) == "local edit")
        #expect(DpkgDatabase.readStatus(at: root).first?.version == "1.0")
    }

    @Test func damagedDownloadNeverReachesInstalledState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try engine(corruptDeb: true), container = try await update(engine, root: root)
        await #expect(throws: (any Error).self) { try await engine.install(["floe-fixture"], container: container) }
        #expect(DpkgDatabase.readStatus(at: root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("usr/share/floe-fixture/value.txt").path))
    }
}

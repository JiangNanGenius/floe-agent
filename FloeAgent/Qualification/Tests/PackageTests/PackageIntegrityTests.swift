import Foundation
import Testing
import FloePackages
import FloeEnvironments

@Suite("Package integrity")
struct PackageIntegrityTests {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")))
    }
    @Test func acceptsGnuPGSignatureAndRejectsTampering() throws {
        let keys = try OpenPGP.parseKeyring(fixture("public.asc"))
        let signed = try OpenPGP.parseClearsigned(fixture("InRelease"))
        try OpenPGP.verify(signaturePacketBody: signed.signaturePacket, over: signed.text, keys: keys)
        #expect(throws: Error.self) { try OpenPGP.verify(signaturePacketBody: signed.signaturePacket, over: signed.text + Data("tampered".utf8), keys: keys) }
        #expect(throws: Error.self) { try OpenPGP.verify(signaturePacketBody: signed.signaturePacket, over: signed.text, keys: []) }
    }
    @Test func emptyTrustStoreNeverAcceptsRepository() async throws {
        let signed = try fixture("InRelease")
        let engine = AptEngine(downloader: .init { _, _ in signed })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = await engine.update(container: .init(id: "a", rootURL: root, layerURL: root, layerKind: .project, baseRevision: "one"), sources: [.init(uri: "https://example.invalid", suite: "floe-test", trusted: true)])
        #expect(report.packages == 0)
        #expect(report.failures.count == 1)
    }
    @Test func tarChecksTruncationAndChecksum() throws {
        let archive = TarArchive.write([.init(path: "hello", kind: .file, data: Data("hello".utf8))])
        #expect(try TarArchive.read(archive).first?.data == Data("hello".utf8))
        #expect(throws: Error.self) { try TarArchive.read(Data(archive.prefix(513))) }
        var corrupt = archive
        corrupt[0] ^= 1
        #expect(throws: Error.self) { try TarArchive.read(corrupt) }
    }
}

extension PackageIntegrityTests {
    @Test func holdsAreEnvironmentLocalAndSurviveEngineRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = AptEngine.Container(id: "first", rootURL: root, layerURL: root.appendingPathComponent("first"), layerKind: .project, baseRevision: "one")
        let second = AptEngine.Container(id: "second", rootURL: root, layerURL: root.appendingPathComponent("second"), layerKind: .project, baseRevision: "one")
        let downloader = AptEngine.Downloader { _, _ in Data() }
        let engine = AptEngine(downloader: downloader)
        try await engine.hold("example", container: first)
        #expect(try await engine.held(container: first) == ["example"])
        #expect(try await engine.held(container: second).isEmpty)
        let restored = AptEngine(downloader: downloader)
        #expect(try await restored.held(container: first) == ["example"])
        try await restored.unhold("example", container: first)
        #expect(try await restored.held(container: first).isEmpty)
    }
}

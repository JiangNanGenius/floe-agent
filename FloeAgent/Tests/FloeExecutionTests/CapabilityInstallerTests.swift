import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

@Suite("Capability install persistence")
struct CapabilityInstallerTests {
    @Test func receiptsSurviveRecreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = CapabilityCatalog(entries: [.init(id: "test/skill", kind: .skill, tier: .managed, summary: "test")])
        let first = CapabilityInstaller(catalog: catalog, pythonInstaller: nil, http: HTTPRequestService(), packagesRoot: root, skillInstaller: SuccessfulSkillInstaller())
        _ = try await first.install(id: "test/skill", purpose: "test installation", capabilities: [], cancellation: nil)
        let recreated = CapabilityInstaller(catalog: catalog, pythonInstaller: nil, http: HTTPRequestService(), packagesRoot: root)
        #expect(await recreated.installedIDs() == ["test/skill"])
    }

    @Test func missingBundledPythonNeverDownloads() async throws {
        // A bundled-tier Python entry that is not installed must not silently
        // download: the catalog is stale, not the runtime. Phase 2 catalogs
        // carry no bundled Python entries at all (guest pip owns installs).
        let catalog = CapabilityCatalog(entries: [.init(id: "test/python", kind: .pythonPackage, tier: .bundled, summary: "test", spec: "package")])
        let installer = CapabilityInstaller(catalog: catalog, pythonInstaller: ManagedPythonInstallService(), http: HTTPRequestService(), packagesRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        await #expect(throws: FloeError.self) {
            try await installer.install(id: "test/python", purpose: nil, capabilities: [], cancellation: nil)
        }
    }

    @Test func truncatedArchiveIsRejected() {
        #expect(throws: FloeError.self) { try ArArchiveReader.read(ArArchiveReader.magic + Data("partial".utf8)) }
    }
}

private struct SuccessfulSkillInstaller: CapabilitySkillInstalling {
    func installCapabilitySkill(id: String) async throws {}
}

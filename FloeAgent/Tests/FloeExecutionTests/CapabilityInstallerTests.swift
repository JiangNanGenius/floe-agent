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
        actor Calls {
            var installCalls = 0
            func observe(_ request: ScriptExecutionRequest) { if request.allowsManagedPackageInstaller { installCalls += 1 } }
        }
        let calls = Calls()
        let python = LocalPythonService(version: "test") { request, _ in
            await calls.observe(request)
            return .ok(resultJSON: nil, stdout: "", stderr: "", truncated: false, stderrTruncated: false, durationMs: 0)
        }
        let catalog = CapabilityCatalog(entries: [.init(id: "test/python", kind: .pythonPackage, tier: .bundled, summary: "test", spec: "package")])
        let installer = CapabilityInstaller(catalog: catalog, pythonInstaller: ManagedPythonInstallService(python: python), http: HTTPRequestService(), packagesRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        await #expect(throws: FloeError.self) {
            try await installer.install(id: "test/python", purpose: nil, capabilities: [], cancellation: nil)
        }
        #expect(await calls.installCalls == 0)
    }

    @Test func truncatedArchiveIsRejected() {
        #expect(throws: FloeError.self) { try ArArchiveReader.read(ArArchiveReader.magic + Data("partial".utf8)) }
    }
}

private struct SuccessfulSkillInstaller: CapabilitySkillInstalling {
    func installCapabilitySkill(id: String) async throws {}
}

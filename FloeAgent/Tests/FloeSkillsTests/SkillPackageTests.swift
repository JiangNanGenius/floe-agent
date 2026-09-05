import Foundation
import Testing
@testable import FloeSkills
import FloeTools

@Suite("FloeSkills package boundary", .serialized)
struct SkillPackageTests {
    @Test("Valid SKILL.md and floe.json produce a canonical package")
    func validPackage() throws {
        let fixture = try SkillFixture()
        try fixture.writeValidSkill()

        let package = try SkillPackageValidator().validate(packageAt: fixture.root)

        #expect(package.metadata.name == "read-project")
        #expect(package.manifest.id == "read-project")
        #expect(package.declaredCapabilities == [.workspaceRead])
        #expect(package.canonicalSHA256.count == 64)
        #expect(!package.containsScripts)
    }

    @Test("Unknown capabilities fail closed")
    func rejectsUnknownCapability() throws {
        let fixture = try SkillFixture()
        try fixture.writeValidSkill(capabilities: ["workspace.read", "device.root"])

        #expect(throws: SkillValidationError.unknownCapability("device.root")) {
            try SkillPackageValidator().validate(packageAt: fixture.root)
        }
    }

    @Test("Symbolic links cannot escape or alias package content")
    func rejectsSymbolicLinks() throws {
        let fixture = try SkillFixture()
        try fixture.writeValidSkill()
        let references = fixture.root.appendingPathComponent("references", isDirectory: true)
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: references.appendingPathComponent("outside.txt"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )

        #expect(throws: SkillValidationError.self) {
            try SkillPackageValidator().validate(packageAt: fixture.root)
        }
    }

    @Test("Unexpected top-level payload and native binaries are rejected")
    func rejectsUnsupportedPayloads() throws {
        let fixture = try SkillFixture()
        try fixture.writeValidSkill()
        try Data([0x7F, 0x45, 0x4C, 0x46]).write(to: fixture.root.appendingPathComponent("payload"))

        #expect(throws: SkillValidationError.unsupportedFile("payload")) {
            try SkillPackageValidator().validate(packageAt: fixture.root)
        }
    }

    @Test("Native bundle directories are not skipped during traversal")
    func rejectsNativeBundleDirectories() throws {
        let fixture = try SkillFixture()
        try fixture.writeValidSkill()
        let bundle = fixture.root.appendingPathComponent("assets/Injected.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: bundle.appendingPathComponent("binary"))

        #expect(throws: SkillValidationError.unsupportedFile("assets/Injected.app")) {
            try SkillPackageValidator().validate(packageAt: fixture.root)
        }
    }

    @Test("Package limits are enforced before loading unbounded resources")
    func enforcesLimits() throws {
        let fixture = try SkillFixture()
        try fixture.writeValidSkill()
        let assets = fixture.root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 2_048).write(to: assets.appendingPathComponent("large.txt"))
        let validator = SkillPackageValidator(limits: SkillValidationLimits(
            maximumFileCount: 10,
            maximumFileBytes: 1_024,
            maximumPackageBytes: 8_192,
            maximumSkillMarkdownBytes: 1_024,
            maximumManifestBytes: 1_024
        ))

        #expect(throws: SkillValidationError.fileTooLarge(path: "assets/large.txt", limit: 1_024)) {
            try validator.validate(packageAt: fixture.root)
        }
    }

    @Test("Local scripts require JavaScriptCore declaration and capability")
    func validatesLocalScriptRuntime() throws {
        let fixture = try SkillFixture()
        try fixture.writeValidSkill(
            capabilities: ["javascript.local"],
            scriptRuntime: "javascriptcore"
        )
        let scripts = fixture.root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data("1 + 1".utf8).write(to: scripts.appendingPathComponent("run.js"))

        let package = try SkillPackageValidator().validate(packageAt: fixture.root)
        #expect(package.containsScripts)
        #expect(package.manifest.scriptRuntime == .javaScriptCore)
    }

    @Test("Pure Python scripts and exact packages form an install-audited skill")
    func validatesLocalPythonSkill() throws {
        let fixture = try SkillFixture()
        try fixture.writeValidSkill(
            capabilities: ["python.local"],
            tools: ["exec.localPython"],
            scriptRuntime: "python.local",
            pythonPackages: [[
                "spec": "python-dateutil==2.9.0.post0",
                "purpose": "Parse dates in imported records",
                "capabilities": ["data.transform"]
            ]]
        )
        let scripts = fixture.root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data("import json\nprint(json.dumps(input))\n".utf8)
            .write(to: scripts.appendingPathComponent("run.py"))

        let package = try SkillPackageValidator().validate(packageAt: fixture.root)

        #expect(package.manifest.scriptRuntime == .localPython)
        #expect(package.manifest.pythonPackages.map(\.spec) == ["python-dateutil==2.9.0.post0"])
        #expect(package.declaredCapabilities.contains(.localPython))
    }

    @Test("Python skill audit rejects installer and native execution escapes")
    func rejectsUnsafePythonSkillSource() throws {
        let fixture = try SkillFixture()
        try fixture.writeValidSkill(
            capabilities: ["python.local"],
            tools: ["exec.localPython"],
            scriptRuntime: "python.local"
        )
        let scripts = fixture.root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data("import subprocess\nsubprocess.run(['echo', 'x'])\n".utf8)
            .write(to: scripts.appendingPathComponent("run.py"))

        #expect(throws: SkillValidationError.self) {
            try SkillPackageValidator().validate(packageAt: fixture.root)
        }
    }

    @Test("Python skill dependencies must use immutable exact versions")
    func rejectsFloatingPythonPackage() throws {
        let fixture = try SkillFixture()
        try fixture.writeValidSkill(
            capabilities: ["python.local"],
            tools: ["exec.localPython"],
            scriptRuntime: "python.local",
            pythonPackages: [[
                "spec": "python-dateutil",
                "purpose": "Parse dates",
                "capabilities": ["data.transform"]
            ]]
        )
        let scripts = fixture.root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data("print(input)\n".utf8).write(to: scripts.appendingPathComponent("run.py"))

        #expect(throws: SkillValidationError.self) {
            try SkillPackageValidator().validate(packageAt: fixture.root)
        }
    }

    @Test("Compatibility reports unavailable device capabilities and tools")
    func compatibilityReport() throws {
        let fixture = try SkillFixture()
        try fixture.writeValidSkill(
            capabilities: ["workspace.read", "network"],
            tools: ["file.read", "web.fetch"]
        )
        let package = try SkillPackageValidator().validate(packageAt: fixture.root)
        let report = SkillCompatibility.evaluate(package, in: SkillRuntimeEnvironment(
            platform: .iOS,
            supportedCapabilities: [.workspaceRead],
            registeredTools: ["file.read"],
            supportsJavaScriptCore: true,
            hasRemoteExecutionHost: false
        ))

        #expect(!report.isRunnable)
        #expect(report.problems.contains(.unavailableCapability(.network)))
        #expect(report.problems.contains(.unavailableTool("web.fetch")))
    }

    @Test("Per-run tool authorization is an intersection and denies at execution")
    func toolAuthorization() throws {
        let fixture = try SkillFixture()
        try fixture.writeValidSkill(
            capabilities: ["workspace.read", "workspace.write"],
            tools: ["file.read", "file.write"]
        )
        let package = try SkillPackageValidator().validate(packageAt: fixture.root)
        let descriptors = [
            ToolCatalog.Descriptor(name: "file.read", riskLabels: [.readsFiles], isSideEffecting: false),
            ToolCatalog.Descriptor(name: "file.write", riskLabels: [.writesFiles], isSideEffecting: true)
        ]
        let authorization = SkillToolAuthorization(
            package: package,
            deviceCapabilities: [.workspaceRead, .workspaceWrite],
            grantedCapabilities: [.workspaceRead],
            descriptors: descriptors,
            requirements: [
                "file.read": SkillToolRequirement(capabilities: [.workspaceRead]),
                "file.write": SkillToolRequirement(capabilities: [.workspaceWrite])
            ]
        )

        #expect(authorization.allowedToolNames == ["file.read"])
        try authorization.authorize(toolName: "file.read")
        #expect(throws: SkillToolAuthorizationError.denied(skillID: "read-project", toolName: "file.write")) {
            try authorization.authorize(toolName: "file.write")
        }
    }

    @Test("Only instruction-only or read-only skills can auto-install")
    func automaticInstallPolicy() throws {
        let fixture = try SkillFixture()
        try fixture.writeValidSkill(capabilities: ["workspace.read"], tools: ["file.read"])
        let package = try SkillPackageValidator().validate(packageAt: fixture.root)
        let descriptors = [
            ToolCatalog.Descriptor(name: "file.read", riskLabels: [.readsFiles], isSideEffecting: false)
        ]
        #expect(SkillAutomaticInstallPolicy.mayInstallWithoutConfirmation(package, descriptors: descriptors))
    }

    @Test("Installer persists only the reviewed rewritten package")
    func canonicalOnlyInstall() async throws {
        let fixture = try SkillFixture()
        try fixture.writeValidSkill()
        let package = try SkillPackageValidator().validate(packageAt: fixture.root)
        let installRoot = fixture.base.appendingPathComponent("installed", isDirectory: true)
        let store = RecordingMetadataStore()
        let service = SkillInstallStagingService(installationRoot: installRoot, metadataStore: store)
        let provenance = SkillInstallProvenance(
            sourceURL: URL(string: "https://example.invalid/original.zip")!,
            originalSHA256: String(repeating: "a", count: 64),
            expectedRewrittenSHA256: package.canonicalSHA256,
            rewriteModelID: "review-model",
            compatibilitySummary: "iOS compatible"
        )

        let record = try await service.installRewrittenPackage(at: fixture.root, provenance: provenance)

        #expect(record.originalPayloadStored == false)
        #expect(FileManager.default.fileExists(atPath: record.canonicalPackageURL.appendingPathComponent("SKILL.md").path))
        #expect(!FileManager.default.fileExists(atPath: installRoot.appendingPathComponent("original.zip").path))
        #expect(await store.lastRecord() == record)
    }

    @Test("Installer rejects a package changed after review")
    func installDigestMismatch() async throws {
        let fixture = try SkillFixture()
        try fixture.writeValidSkill()
        let service = SkillInstallStagingService(
            installationRoot: fixture.base.appendingPathComponent("installed", isDirectory: true)
        )
        let provenance = SkillInstallProvenance(
            sourceURL: URL(string: "https://example.invalid/source")!,
            originalSHA256: String(repeating: "a", count: 64),
            expectedRewrittenSHA256: String(repeating: "0", count: 64),
            rewriteModelID: "review-model",
            compatibilitySummary: "compatible"
        )

        await #expect(throws: SkillValidationError.digestMismatch) {
            try await service.installRewrittenPackage(at: fixture.root, provenance: provenance)
        }
    }

    @Test("Failed metadata persistence restores the installed package")
    func updateRollback() async throws {
        let fixture = try SkillFixture()
        try fixture.writeValidSkill()
        let original = try SkillPackageValidator().validate(packageAt: fixture.root)
        let root = fixture.base.appendingPathComponent("installed")
        var provenance = SkillInstallProvenance(sourceURL: URL(string: "https://example.invalid/skill")!, originalSHA256: original.canonicalSHA256, expectedRewrittenSHA256: original.canonicalSHA256, rewriteModelID: "review", compatibilitySummary: "fixture")
        _ = try await SkillInstallStagingService(installationRoot: root).installRewrittenPackage(at: fixture.root, provenance: provenance)
        let markdownURL = fixture.root.appendingPathComponent("SKILL.md")
        var markdown = try Data(contentsOf: markdownURL)
        markdown.append(Data("\nChanged body\n".utf8))
        try markdown.write(to: markdownURL)
        provenance.expectedRewrittenSHA256 = try SkillPackageValidator().validate(packageAt: fixture.root).canonicalSHA256
        let service = SkillInstallStagingService(installationRoot: root, metadataStore: RejectingMetadataStore())
        await #expect(throws: SkillInstallError.invalidProvenance) {
            try await service.installRewrittenPackage(at: fixture.root, provenance: provenance, replaceExisting: true)
        }
        let restored = try SkillPackageValidator().validate(packageAt: root.appendingPathComponent(original.manifest.id))
        #expect(restored.canonicalSHA256 == original.canonicalSHA256)
    }
}

private struct RejectingMetadataStore: SkillInstallationMetadataStore {
    func persist(_ record: SkillInstallationRecord) async throws { throw SkillInstallError.invalidProvenance }
}

private actor RecordingMetadataStore: SkillInstallationMetadataStore {
    private var record: SkillInstallationRecord?

    func persist(_ record: SkillInstallationRecord) {
        self.record = record
    }

    func lastRecord() -> SkillInstallationRecord? { record }
}

private final class SkillFixture {
    let base: URL
    let root: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeSkillsTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("rewritten", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    func writeValidSkill(
        capabilities: [String] = ["workspace.read"],
        tools: [String] = [],
        scriptRuntime: String = "none",
        pythonPackages: [[String: Any]] = []
    ) throws {
        let markdown = """
        ---
        name: read-project
        description: Read the current project and explain it.
        ---

        # Read project

        Inspect only the files required for the task.
        """
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "id": "read-project",
            "version": "1.0.0",
            "capabilities": capabilities,
            "tools": tools,
            "platforms": ["ios", "macos"],
            "scriptRuntime": scriptRuntime,
            "pythonPackages": pythonPackages
        ]
        try Data(markdown.utf8).write(to: root.appendingPathComponent("SKILL.md"))
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("floe.json"))
    }
}

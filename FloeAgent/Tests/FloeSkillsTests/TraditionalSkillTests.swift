// FloeSkillsTests — traditional (manifest-optional) skill packages.
//
// Covers sidecar-manifest validation without mutating upstream bytes, the
// task-environment runtime derivation for shell/Node/mixed scripts, and the
// staging service installing a traditional package without writing Floe
// metadata into it.

import Foundation
import Testing
@testable import FloeSkills

@Suite("Traditional skill packages")
struct TraditionalSkillTests {
    @Test("Upstream reference directory and legal files retain their exact bytes")
    func referenceAndLicenseArePreserved() throws {
        let root = try Self.makePackage(files: [
            "reference/design.md": "Original upstream guidance\n",
            "LICENSE": "Original license\n",
            "NOTICE.txt": "Original notice\n"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try SkillPackageValidator().validate(packageAt: root, requireManifest: false)
        #expect(Set(package.files.map(\.relativePath)).isSuperset(of: ["reference/design.md", "LICENSE", "NOTICE.txt"]))
        #expect(try String(contentsOf: root.appendingPathComponent("LICENSE"), encoding: .utf8) == "Original license\n")
    }

    @Test("Script paths share one normalization and containment contract")
    func scriptPathNormalization() throws {
        let root = try Self.makePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        for path in ["audit.py", "scripts/audit.py", "scripts/nested/audit.py"] {
            let target = try SkillScriptPath.destination(for: path, in: scripts)
            #expect(target.pathExtension == "py")
            #expect(target.pathComponents.contains("scripts"))
        }
        #expect(try SkillScriptPath.relativeToScripts("audit.py") == SkillScriptPath.relativeToScripts("scripts/audit.py"))
        for path in ["../audit.py", "scripts/../audit.py", "/audit.py", "scripts//audit.py", "scripts/./audit.py", "audit.sh", "a\\b.py", "x\0.py"] {
            #expect(throws: (any Error).self) { try SkillScriptPath.destination(for: path, in: scripts) }
        }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: scripts.appendingPathComponent("escape"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try SkillScriptPath.destination(for: "escape/audit.py", in: scripts) }
    }

    @Test("Runtime declarations distinguish host platform from guest architecture")
    func runtimeDeclarationAssessment() throws {
        let root = try Self.makePackage(files: ["scripts/run.sh": "echo ok\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = SkillManifest(id: "legacy-helper", version: "1.0.0",
            capabilities: ["execution.remote"], tools: ["exec.shell"], platforms: ["ios", "android", "linux"], scriptRuntime: .remote,
            runtime: .init(os: ["linux"], architectures: ["riscv64"]))
        let file = root.appendingPathComponent("floe.json")
        try JSONEncoder().encode(manifest).write(to: file)
        let package = try SkillPackageValidator().validate(packageAt: root)
        var runtime = SkillRuntimeEnvironment(platform: .iOS, supportedCapabilities: [.remoteExecution],
            registeredTools: ["exec.shell"], supportsJavaScriptCore: false, hasRemoteExecutionHost: false,
            runtimeOS: "linux", runtimeArchitecture: "riscv64")
        #expect(SkillCompatibility.evaluate(package, in: runtime).declaredRuntime == .declaredCompatible)
        runtime.platform = .android
        runtime.runtimeArchitecture = "arm64"
        let mismatch = SkillCompatibility.evaluate(package, in: runtime)
        #expect(mismatch.declaredRuntime == .incompatible)
        #expect(mismatch.problems.isEmpty) // Readable guidance is retained.
        runtime.runtimeArchitecture = nil
        #expect(SkillCompatibility.evaluate(package, in: runtime).declaredRuntime == .unverified)
        manifest.runtime = .init(os: ["linux"], architectures: ["not-a-cpu"])
        try JSONEncoder().encode(manifest).write(to: file)
        #expect(throws: SkillValidationError.self) { try SkillPackageValidator().validate(packageAt: root) }
    }

    static func makePackage(
        id: String = "legacy-helper",
        files: [String: String] = [:]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-traditional-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let markdown = """
        ---
        name: \(id)
        description: Traditional package used by tests.
        ---

        Follow the documented steps.
        """
        try Data(markdown.utf8).write(to: root.appendingPathComponent("SKILL.md"), options: .atomic)
        for (path, contents) in files {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: target, options: .atomic)
        }
        return root
    }

    @Test("Shell and Node scripts run through the existing task environment")
    func shellAndNodeUseTaskEnvironment() throws {
        let root = try Self.makePackage(files: [
            "scripts/run.sh": "echo hi",
            "scripts/tool.mjs": "export {}"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try SkillPackageValidator().validate(packageAt: root, requireManifest: false)
        #expect(package.manifest.scriptRuntime == .remote)
        #expect(package.manifest.tools == ["exec.shell"])
        #expect(package.manifest.capabilities == [SkillCapability.remoteExecution.rawValue])
        // The upstream bytes are untouched: no floe.json was created.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("floe.json").path))
    }

    @Test("Mixed Python and shell scripts are accepted, not rejected for a missing manifest")
    func mixedScriptsAccepted() throws {
        let root = try Self.makePackage(files: [
            "scripts/analyze.py": "print('ok')",
            "scripts/run.sh": "echo hi"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try SkillPackageValidator().validate(packageAt: root, requireManifest: false)
        #expect(package.manifest.scriptRuntime == .remote)
        #expect(package.manifest.tools == ["exec.shell"])
    }

    @Test("Task helpers preserve supporting files without claiming an interpreter exists")
    func pythonAndUnknownTypes() throws {
        let pythonRoot = try Self.makePackage(files: [
            "scripts/analyze.py": "print('ok')"
        ])
        defer { try? FileManager.default.removeItem(at: pythonRoot) }
        let python = try SkillPackageValidator().validate(packageAt: pythonRoot, requireManifest: false)
        #expect(python.manifest.scriptRuntime == .remote)
        #expect(python.manifest.tools == ["exec.shell"])
        let report = SkillCompatibility.evaluate(python, in: SkillRuntimeEnvironment(
            platform: .iOS, supportedCapabilities: [.remoteExecution], registeredTools: ["exec.shell"],
            supportsJavaScriptCore: false, hasRemoteExecutionHost: false))
        #expect(report.isRunnable)


        let unknownRoot = try Self.makePackage(files: [
            "scripts/tool.rb": "puts 'hi'",
            "scripts/tool": "#!/bin/sh\necho ok\n",
            "scripts/VERSION": "1.0.0\n",
            "scripts/metadata.json": "{}",
            "scripts/tool.cmd": "@echo off\n"
        ])
        defer { try? FileManager.default.removeItem(at: unknownRoot) }
        let helpers = try SkillPackageValidator().validate(packageAt: unknownRoot, requireManifest: false)
        #expect(helpers.files.count == 6)
        #expect(helpers.manifest.scriptRuntime == .remote)
        #expect(SkillCompatibility.evaluate(helpers, in: SkillRuntimeEnvironment(platform: .iOS,
            supportedCapabilities: [.remoteExecution], registeredTools: ["exec.shell"],
            supportsJavaScriptCore: false, hasRemoteExecutionHost: false)).declaredRuntime == .unverified)
        try Data([0x4D, 0x5A, 0, 0]).write(to: unknownRoot.appendingPathComponent("scripts/native-helper"))
        #expect(throws: SkillValidationError.self) { try SkillPackageValidator().validate(packageAt: unknownRoot, requireManifest: false) }
    }

    @Test("A sidecar manifest validates identity without entering the canonical digest")
    func sidecarManifestPreservesBytes() throws {
        let root = try Self.makePackage(files: ["references/notes.md": "notes"])
        defer { try? FileManager.default.removeItem(at: root) }
        let validator = SkillPackageValidator()
        let derived = try validator.validate(packageAt: root, requireManifest: false)

        let override = SkillManifest(
            id: "legacy-helper",
            version: "2.0.0",
            capabilities: [],
            tools: [],
            scriptRuntime: .none
        )
        let validated = try validator.validate(packageAt: root, manifestOverride: override)
        #expect(validated.manifest.version == "2.0.0")
        // Same canonical digest with and without the override: the sidecar is
        // not part of the upstream package bytes.
        #expect(validated.canonicalSHA256 == derived.canonicalSHA256)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("floe.json").path))

        let mismatched = SkillManifest(id: "other-skill", version: "1.0.0")
        #expect(throws: (any Error).self) {
            try validator.validate(packageAt: root, manifestOverride: mismatched)
        }
    }

    @Test("Staging installs a traditional package with the sidecar manifest outside the bytes")
    func stagingInstallsTraditionalPackage() async throws {
        let root = try Self.makePackage(files: ["scripts/run.sh": "echo hi"])
        defer { try? FileManager.default.removeItem(at: root) }
        let validator = SkillPackageValidator()
        let derived = try validator.validate(packageAt: root, requireManifest: false)
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-skill-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let service = SkillInstallStagingService(installationRoot: storeRoot)
        let provenance = SkillInstallProvenance(
            sourceURL: URL(string: "floe-folder://local/legacy-helper")!,
            originalSHA256: derived.canonicalSHA256,
            expectedRewrittenSHA256: derived.canonicalSHA256,
            rewriteModelID: "traditional-import",
            compatibilitySummary: "Traditional package validated without a packaged manifest"
        )
        let record = try await service.installRewrittenPackage(
            at: root, provenance: provenance, manifestOverride: derived.manifest
        )
        #expect(record.version == "1.0.0")
        #expect(!FileManager.default.fileExists(atPath: record.canonicalPackageURL.appendingPathComponent("floe.json").path))
        // Re-reading with the sidecar keeps working after installation.
        let reread = try validator.validate(
            packageAt: record.canonicalPackageURL, manifestOverride: derived.manifest
        )
        #expect(reread.canonicalSHA256 == derived.canonicalSHA256)
        #expect(reread.manifest.scriptRuntime == .remote)
    }
}

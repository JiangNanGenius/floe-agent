// FloeSkillsTests — complete-package install from a task workspace directory.
//
// Covers the workspace directory grammar and containment, package planning
// through the existing validator, reserved identifier ownership, the
// mode/digest contract, private staging that binds the reviewed bytes, the
// bounded receipt, and the tool's mapping/authorization boundary. The real
// App install transaction is exercised through the existing staging service.

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeSkills

@Suite("FloeSkills.SkillWorkspaceInstall")
struct SkillWorkspaceInstallToolTests {

    // MARK: - Directory grammar and containment

    @Test("Workspace directory grammar accepts only plain relative components")
    func directoryGrammar() throws {
        #expect(try SkillWorkspacePackageDirectory.normalized("  skills/demo/  ") == "skills/demo")
        #expect(try SkillWorkspacePackageDirectory.normalized("pkg") == "pkg")
        #expect(try SkillWorkspacePackageDirectory.normalized("skills/nested/demo") == "skills/nested/demo")
        #expect(try SkillWorkspacePackageDirectory.normalized("skills/") == "skills")
        for invalid in ["", "   ", "/abs", "~/pkg", "a\\b", "skills//demo", "skills/./demo", "skills/../demo", "a\u{1}b"] {
            #expect(throws: SkillWorkspaceInstallError.self) {
                try SkillWorkspacePackageDirectory.normalized(invalid)
            }
        }
        #expect(throws: SkillWorkspaceInstallError.internalCacheDirectory) {
            try SkillWorkspacePackageDirectory.normalized(".floe/skills/demo")
        }
        #expect(throws: SkillWorkspaceInstallError.self) {
            try SkillWorkspacePackageDirectory.normalized(
                (0..<25).map { "part\($0)" }.joined(separator: "/")
            )
        }
        #expect(throws: SkillWorkspaceInstallError.self) {
            try SkillWorkspacePackageDirectory.normalized(String(repeating: "a", count: 513))
        }
    }

    @Test("Resolution confines the package to the run's workspace")
    func directoryContainment() throws {
        let workspace = try makeSkillWorkspaceInstallTemporaryDirectory("workspace")
        let outside = try makeSkillWorkspaceInstallTemporaryDirectory("outside")
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: outside)
        }
        let package = try writeFiles(traditionalFiles, under: workspace, directory: "skills/demo")
        try writeFiles(traditionalFiles, under: outside, directory: "outside-demo")
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("skills", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("skills/escape"),
            withDestinationURL: outside.appendingPathComponent("outside-demo")
        )
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("skills/alias"),
            withDestinationURL: package
        )
        try Data("not a directory\n".utf8).write(
            to: workspace.appendingPathComponent("skills/file.txt"),
            options: .atomic
        )

        let resolvedRoot = workspace.resolvingSymlinksInPath().standardizedFileURL
        #expect(
            try SkillWorkspacePackageDirectory.resolve("skills/demo", in: workspace).path
                == resolvedRoot.appendingPathComponent("skills/demo").path
        )
        // A link that stays inside the workspace is not an escape.
        #expect(
            try SkillWorkspacePackageDirectory.resolve("skills/alias", in: workspace).path
                == resolvedRoot.appendingPathComponent("skills/demo").path
        )
        #expect(throws: SkillWorkspaceInstallError.directoryOutsideWorkspace) {
            try SkillWorkspacePackageDirectory.resolve("skills/escape", in: workspace)
        }
        #expect(throws: SkillWorkspaceInstallError.directoryMissing("skills/missing")) {
            try SkillWorkspacePackageDirectory.resolve("skills/missing", in: workspace)
        }
        #expect(throws: SkillWorkspaceInstallError.directoryNotDirectory("skills/file.txt")) {
            try SkillWorkspacePackageDirectory.resolve("skills/file.txt", in: workspace)
        }
        #expect(throws: SkillWorkspaceInstallError.workspaceUnavailable) {
            try SkillWorkspacePackageDirectory.resolve(
                "skills/demo", in: outside.appendingPathComponent("absent")
            )
        }
    }

    // MARK: - Planning and ownership

    @Test("A traditional package plans its complete inventory and derived sidecar")
    func traditionalPlan() throws {
        let workspace = try makeSkillWorkspaceInstallTemporaryDirectory("traditional")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let packageRoot = try writeFiles(traditionalFiles, under: workspace, directory: "skills/demo")

        let request = try SkillWorkspaceInstallRequest(directory: "skills/demo/")
        let plan = try SkillWorkspaceInstallPlanner.plan(request, in: workspace)
        let validator = SkillPackageValidator()
        let validated = try validator.validate(packageAt: packageRoot, requireManifest: false)

        #expect(plan.directory == "skills/demo")
        #expect(plan.mode == .install)
        #expect(plan.expectedDigest == nil)
        #expect(plan.sourceURL.absoluteString == "floe-folder://local/skills/demo")
        #expect(plan.package.skillID == "demo-skill")
        #expect(plan.package.version == "1.0.0")
        #expect(plan.package.canonicalSHA256 == validated.canonicalSHA256)
        #expect(plan.package.fileCount == traditionalFiles.count)
        #expect(plan.package.totalBytes == traditionalFiles.values.reduce(0) { $0 + $1.utf8.count })
        #expect(plan.package.files == validated.files.map(\.relativePath))
        #expect(plan.package.hasPackagedManifest == false)
        #expect(plan.package.containsScripts)
        #expect(plan.package.declaredCapabilities == [SkillCapability.remoteExecution.rawValue])
        #expect(plan.package.toolNames == ["exec.shell"])
        #expect(plan.package.scriptRuntime == SkillScriptRuntime.remote.rawValue)
        #expect(plan.package.pythonPackageSpecs.isEmpty)
        // Planning is read-only: the user's directory keeps the exact bytes.
        let after = try validator.validate(packageAt: packageRoot, requireManifest: false)
        #expect(after.canonicalSHA256 == plan.package.canonicalSHA256)

        // Honest external origin: never self-generated or official.
        let origin = SkillOriginResolver.origin(
            id: plan.package.skillID,
            sourceURL: plan.sourceURL.absoluteString,
            rewrittenDigest: plan.package.canonicalSHA256,
            rewriteModelID: SkillWorkspaceInstallIdentity.rewriteModelID
        )
        #expect(origin == .external)
        #expect(SkillBulkUpdatePlan.githubReference(plan.sourceURL.absoluteString) == nil)
    }

    @Test("Source binding stays a portable external identity")
    func sourceBindingEncoding() throws {
        let workspace = try makeSkillWorkspaceInstallTemporaryDirectory("source-binding")
        defer { try? FileManager.default.removeItem(at: workspace) }
        _ = try writeFiles(
            ["SKILL.md": skillMarkdown(name: "spaced-skill")],
            under: workspace,
            directory: "skills/my demo"
        )
        let plan = try SkillWorkspaceInstallPlanner.plan(
            try SkillWorkspaceInstallRequest(directory: "skills/my demo"),
            in: workspace
        )
        #expect(plan.sourceURL.scheme == "floe-folder")
        #expect(plan.sourceURL.host == "local")
        #expect(plan.sourceURL.absoluteString.hasPrefix("floe-folder://local/skills/my%20demo"))
        #expect(!plan.sourceURL.absoluteString.contains(workspace.path))
        let origin = SkillOriginResolver.origin(
            id: plan.package.skillID,
            sourceURL: plan.sourceURL.absoluteString,
            rewrittenDigest: plan.package.canonicalSHA256,
            rewriteModelID: SkillWorkspaceInstallIdentity.rewriteModelID
        )
        #expect(origin == .external)
        #expect(SkillBulkUpdatePlan.githubReference(plan.sourceURL.absoluteString) == nil)
        #expect(SkillWorkspaceInstallIdentity.rewriteModelID != "local-skill-creator")
        #expect(!SkillWorkspaceInstallIdentity.rewriteModelID.hasPrefix("github-reviewed-"))
    }

    @Test("Dependency declarations come from the reviewed manifest")
    func dependencyDeclarations() throws {
        let workspace = try makeSkillWorkspaceInstallTemporaryDirectory("dependencies")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manifest = SkillManifest(
            id: "dependent-skill",
            version: "1.2.0",
            capabilities: [SkillCapability.remoteExecution.rawValue],
            tools: ["exec.shell"],
            scriptRuntime: .remote,
            pythonPackages: [SkillPythonPackageRequirement(
                spec: "python-dateutil==2.9.0.post0",
                purpose: "Parse dates in imported records",
                capabilities: ["data.transform"]
            )]
        )
        let manifestJSON = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
        _ = try writeFiles([
            "SKILL.md": skillMarkdown(name: "dependent-skill"),
            "floe.json": manifestJSON,
            "scripts/render.py": "print('render')\n"
        ], under: workspace, directory: "skills/dependent")
        let plan = try SkillWorkspaceInstallPlanner.plan(
            try SkillWorkspaceInstallRequest(directory: "skills/dependent"),
            in: workspace
        )
        let receipt = try SkillWorkspaceInstallReceipt(
            plan: plan,
            commit: SkillWorkspaceInstallCommit(
                skillID: plan.package.skillID,
                version: plan.package.version,
                canonicalSHA256: plan.package.canonicalSHA256,
                previousDigest: nil
            )
        )
        #expect(receipt.pythonPackageSpecs == ["python-dateutil==2.9.0.post0"])
        #expect(receipt.declaredCapabilities == [SkillCapability.remoteExecution.rawValue])
        #expect(receipt.toolNames == ["exec.shell"])
        #expect(receipt.scriptRuntime == SkillScriptRuntime.remote.rawValue)
        let summary = SkillWorkspaceInstallTool.summary(for: receipt)
        #expect(summary.contains("pythonPackages=1"))
        #expect(summary.contains("pythonPackageSpecs=python-dateutil==2.9.0.post0"))
        #expect(summary.count <= 4_096)
    }

    @Test("A packaged manifest keeps its identity, version and declarations")
    func packagedPlan() throws {
        let workspace = try makeSkillWorkspaceInstallTemporaryDirectory("packaged")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let files = [
            "SKILL.md": skillMarkdown(name: "packaged-skill"),
            "floe.json": packagedManifestJSON,
            "reference/note.md": "Reference note\n",
            "LICENSE.txt": "Original license\n"
        ]
        _ = try writeFiles(files, under: workspace, directory: "deliverables/packaged-skill")
        let plan = try SkillWorkspaceInstallPlanner.plan(
            try SkillWorkspaceInstallRequest(directory: "deliverables/packaged-skill"),
            in: workspace
        )
        #expect(plan.package.skillID == "packaged-skill")
        #expect(plan.package.version == "2.3.4")
        #expect(plan.package.hasPackagedManifest)
        #expect(plan.package.declaredCapabilities == [SkillCapability.workspaceRead.rawValue])
        #expect(plan.package.toolNames == ["workspace.readFile"])
        #expect(plan.package.scriptRuntime == SkillScriptRuntime.none.rawValue)
        #expect(plan.package.files == Set(files.keys).sorted())
    }

    @Test("Reserved built-in and official identifiers are refused")
    func reservedIdentifiers() throws {
        let workspace = try makeSkillWorkspaceInstallTemporaryDirectory("reserved")
        defer { try? FileManager.default.removeItem(at: workspace) }
        for id in ["floe-pdf", "floe-office", "floe-network", "floe-video", "floe-remote", "floe-files-vcs"] {
            let directory = "skills/\(id)"
            _ = try writeFiles(["SKILL.md": skillMarkdown(name: id)], under: workspace, directory: directory)
            #expect(throws: SkillWorkspaceInstallError.reservedIdentifier(id)) {
                try SkillWorkspaceInstallPlanner.plan(
                    try SkillWorkspaceInstallRequest(directory: directory),
                    in: workspace
                )
            }
        }
        #expect(SkillWorkspaceInstallPlanner.reservedSkillIDs.isSuperset(of: OfficialSkillHub.skillIDs))
    }

    @Test("Install mode rejects a digest and replace mode requires the exact one")
    func digestContract() throws {
        #expect(throws: SkillWorkspaceInstallError.unexpectedExpectedDigest) {
            try SkillWorkspaceInstallRequest(
                directory: "skills/demo", mode: .install,
                expectedDigest: String(repeating: "a", count: 64)
            )
        }
        #expect(throws: SkillWorkspaceInstallError.expectedDigestRequired) {
            try SkillWorkspaceInstallRequest(directory: "skills/demo", mode: .replace)
        }
        #expect(throws: SkillWorkspaceInstallError.invalidExpectedDigest) {
            try SkillWorkspaceInstallRequest(
                directory: "skills/demo", mode: .replace,
                expectedDigest: String(repeating: "a", count: 63)
            )
        }
        #expect(throws: SkillWorkspaceInstallError.invalidExpectedDigest) {
            try SkillWorkspaceInstallRequest(
                directory: "skills/demo", mode: .replace,
                expectedDigest: String(repeating: "z", count: 64)
            )
        }
        let upper = String(repeating: "A", count: 64)
        let replacement = try SkillWorkspaceInstallRequest(
            directory: "skills/demo", mode: .replace, expectedDigest: upper
        )
        #expect(replacement.expectedDigest == String(repeating: "a", count: 64))
    }

    // MARK: - Tool contract

    @Test("Tool descriptor is a documented mutating install")
    func descriptor() {
        #expect(SkillWorkspaceInstallTool.name == "skill.install")
        #expect(SkillWorkspaceInstallTool.isSideEffecting)
        #expect(SkillWorkspaceInstallTool.toolEffect == .mutating)
        #expect(SkillWorkspaceInstallTool.riskLabels == [.writesFiles, .changesAgentBehavior])
        #expect(SkillWorkspaceInstallTool.parametersJSON.contains("\"directory\""))
        #expect(SkillWorkspaceInstallTool.parametersJSON.contains("\"mode\""))
        #expect(SkillWorkspaceInstallTool.parametersJSON.contains("\"expectedDigest\""))
        #expect(SkillWorkspaceInstallTool.toolDescription.contains("mode=replace"))
        #expect(SkillWorkspaceInstallTool.toolDescription.contains("expectedDigest"))
    }

    @Test("Tool validation refuses an unsafe directory before execution")
    func validation() async throws {
        let recorder = PlanRecorder()
        let tool = SkillWorkspaceInstallTool(installer: SuccessfulInstaller(recorder: recorder))
        #expect(throws: SkillWorkspaceInstallError.self) {
            try tool.validate(.init(directory: "../escape"))
        }
        #expect(throws: SkillWorkspaceInstallError.self) {
            try tool.validate(.init(directory: ".floe/skills/demo"))
        }
        #expect(throws: SkillWorkspaceInstallError.self) {
            try tool.validate(.init(directory: "skills/demo", mode: .replace))
        }
        #expect(await recorder.plans().isEmpty)
    }

    @Test("Tool requires an approved task workspace and a visible directory")
    func authorizationBoundary() async throws {
        let workspace = try makeSkillWorkspaceInstallTemporaryDirectory("authorize")
        defer { try? FileManager.default.removeItem(at: workspace) }
        _ = try writeFiles(traditionalFiles, under: workspace, directory: "skills/demo")
        let recorder = PlanRecorder()
        let tool = SkillWorkspaceInstallTool(installer: SuccessfulInstaller(recorder: recorder))
        let arguments = SkillWorkspaceInstallTool.Arguments(directory: "skills/demo")

        await #expect(throws: SkillWorkspaceInstallError.workspaceUnavailable) {
            try await tool.execute(arguments, context: makeContext(workspace: nil))
        }
        await #expect(throws: FloeError.self) {
            try await tool.execute(arguments, context: makeContext(workspace: workspace, approved: false))
        }
        await #expect(throws: FloeError.self) {
            try await tool.execute(arguments, context: makeContext(workspace: workspace, temporary: true))
        }
        await #expect(throws: FloeError.self) {
            try await tool.execute(
                arguments,
                context: makeContext(workspace: workspace, allowedPaths: ["other"])
            )
        }
        let cancelled = CancellationToken()
        cancelled.cancel()
        await #expect(throws: FloeError.cancelled) {
            try await tool.execute(arguments, context: makeContext(workspace: workspace, cancellation: cancelled))
        }
        #expect(await recorder.plans().isEmpty)
    }

    @Test("Tool installs through the injected bridge and reports the verified receipt")
    func installMapping() async throws {
        let workspace = try makeSkillWorkspaceInstallTemporaryDirectory("install")
        defer { try? FileManager.default.removeItem(at: workspace) }
        _ = try writeFiles(traditionalFiles, under: workspace, directory: "skills/demo")
        let recorder = PlanRecorder()
        let tool = SkillWorkspaceInstallTool(installer: SuccessfulInstaller(recorder: recorder))

        let output = try await tool.execute(
            .init(directory: "skills/demo"),
            context: makeContext(workspace: workspace)
        )
        #expect(output.exitStatus == 0)
        let summary = output.summary
        #expect(summary.hasPrefix("status=installed id=demo-skill version=1.0.0 digest="))
        #expect(summary.contains(" files=8 bytes="))
        #expect(summary.contains("mode=install"))
        #expect(summary.contains("directory=skills/demo"))
        #expect(summary.contains("source=floe-folder://local/skills/demo"))
        #expect(summary.contains("declarations capabilities=execution.remote tools=exec.shell runtime=remote"))
        #expect(summary.contains("inventory=LICENSE,NOTICE,SKILL.md,agents/openai.yaml,assets/logo.txt,reference/guide.md,references/second.md,scripts/report.py"))
        #expect(summary.hasSuffix("the installed copy is independent of the task workspace."))
        #expect(!summary.contains(workspace.path))
        #expect(output.summary.count <= 4_096)

        let plans = await recorder.plans()
        #expect(plans.count == 1)
        #expect(plans.first?.mode == .install)
        #expect(plans.first?.expectedDigest == nil)
        #expect(plans.first?.isDirectoryInsideWorkspace == true)
    }

    @Test("Tool reports a replacement with its exact previous digest")
    func replacementMapping() async throws {
        let workspace = try makeSkillWorkspaceInstallTemporaryDirectory("replace")
        defer { try? FileManager.default.removeItem(at: workspace) }
        _ = try writeFiles(traditionalFiles, under: workspace, directory: "skills/demo")
        let current = String(repeating: "b", count: 64)
        let recorder = PlanRecorder()
        let tool = SkillWorkspaceInstallTool(installer: SuccessfulInstaller(recorder: recorder))

        let output = try await tool.execute(
            .init(directory: "skills/demo", mode: .replace, expectedDigest: current),
            context: makeContext(workspace: workspace)
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("status=replaced"))
        #expect(output.summary.contains("mode=replace"))
        #expect(output.summary.contains("previousDigest=\(current)"))
        #expect(await recorder.plans().first?.expectedDigest == current)
    }

    @Test("A bridge commit that differs from the reviewed plan is refused")
    func commitIntegrity() async throws {
        let workspace = try makeSkillWorkspaceInstallTemporaryDirectory("integrity")
        defer { try? FileManager.default.removeItem(at: workspace) }
        _ = try writeFiles(traditionalFiles, under: workspace, directory: "skills/demo")
        let arguments = SkillWorkspaceInstallTool.Arguments(directory: "skills/demo")
        let context = makeContext(workspace: workspace)

        await #expect(throws: SkillWorkspaceInstallError.commitMismatch) {
            try await SkillWorkspaceInstallTool(installer: MismatchedDigestInstaller())
                .execute(arguments, context: context)
        }
        await #expect(throws: SkillWorkspaceInstallError.commitMismatch) {
            try await SkillWorkspaceInstallTool(installer: WrongPreviousDigestInstaller())
                .execute(
                    .init(directory: "skills/demo", mode: .replace, expectedDigest: String(repeating: "c", count: 64)),
                    context: context
                )
        }
        await #expect(throws: SkillWorkspaceInstallError.commitMismatch) {
            try await SkillWorkspaceInstallTool(installer: UnexpectedPreviousDigestInstaller())
                .execute(arguments, context: context)
        }
    }

    @Test("Package and installer failures stay a normal bounded failed result")
    func failureMapping() async throws {
        let workspace = try makeSkillWorkspaceInstallTemporaryDirectory("failure")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let tool = SkillWorkspaceInstallTool(installer: SuccessfulInstaller(recorder: nil))

        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("skills/broken", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("# no frontmatter\n".utf8).write(
            to: workspace.appendingPathComponent("skills/broken/SKILL.md"),
            options: .atomic
        )
        let malformed = try await tool.execute(
            .init(directory: "skills/broken"),
            context: makeContext(workspace: workspace)
        )
        #expect(malformed.exitStatus == 1)
        #expect(malformed.summary.hasPrefix("status=failed error="))
        #expect(malformed.summary.contains("frontmatter"))
        #expect(!malformed.summary.contains(workspace.path))

        _ = try writeFiles(["SKILL.md": skillMarkdown(name: "floe-pdf")], under: workspace, directory: "skills/reserved")
        let reserved = try await tool.execute(
            .init(directory: "skills/reserved"),
            context: makeContext(workspace: workspace)
        )
        #expect(reserved.exitStatus == 1)
        #expect(reserved.summary.contains("reserved"))

        _ = try writeFiles(traditionalFiles, under: workspace, directory: "skills/demo")
        let refused = try await SkillWorkspaceInstallTool(
            installer: FailingInstaller(error: .validationFailed("A verified official update is required"))
        ).execute(.init(directory: "skills/demo"), context: makeContext(workspace: workspace))
        #expect(refused.exitStatus == 1)
        #expect(refused.summary.contains("verified official update"))
        #expect(!refused.summary.contains(workspace.path))
    }

    @Test("Inventory and receipts stay bounded and honest")
    func boundedReceipt() throws {
        let workspace = try makeSkillWorkspaceInstallTemporaryDirectory("bounded")
        let stagingParent = try makeSkillWorkspaceInstallTemporaryDirectory("bounded-staging")
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: stagingParent)
        }
        var files = ["SKILL.md": skillMarkdown(name: "many-assets")]
        for index in 0..<40 {
            files[String(format: "assets/f%02d.txt", index)] = "asset \(index)\n"
        }
        _ = try writeFiles(files, under: workspace, directory: "skills/many-assets")
        let plan = try SkillWorkspaceInstallPlanner.plan(
            try SkillWorkspaceInstallRequest(directory: "skills/many-assets"),
            in: workspace
        )
        let receipt = try SkillWorkspaceInstallReceipt(
            plan: plan,
            commit: SkillWorkspaceInstallCommit(
                skillID: plan.package.skillID,
                version: plan.package.version,
                canonicalSHA256: plan.package.canonicalSHA256,
                previousDigest: nil
            )
        )
        #expect(receipt.inventory.count == SkillWorkspaceInstallReceipt.maximumInventoryEntries)
        #expect(receipt.omittedFileCount == files.count - SkillWorkspaceInstallReceipt.maximumInventoryEntries)
        #expect(receipt.fileCount == files.count)
        let summary = SkillWorkspaceInstallTool.summary(for: receipt)
        #expect(summary.contains("inventoryOmitted=\(receipt.omittedFileCount)"))
        #expect(summary.hasSuffix("the installed copy is independent of the task workspace."))
        #expect(summary.count <= 4_096)
        #expect(!summary.contains(workspace.path))
    }

    // MARK: - Private staging

    @Test("Staging copies the complete package and binds the reviewed digest")
    func stagingCopy() throws {
        let workspace = try makeSkillWorkspaceInstallTemporaryDirectory("staging")
        let stagingParent = try makeSkillWorkspaceInstallTemporaryDirectory("staging-parent")
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: stagingParent)
        }
        let packageRoot = try writeFiles(traditionalFiles, under: workspace, directory: "skills/demo")
        let plan = try SkillWorkspaceInstallPlanner.plan(
            try SkillWorkspaceInstallRequest(directory: "skills/demo"),
            in: workspace
        )
        let package = try SkillWorkspaceInstallStaging.stage(plan, parent: stagingParent)
        defer { try? FileManager.default.removeItem(at: package.rootURL.deletingLastPathComponent()) }

        #expect(package.rootURL.path.hasPrefix(stagingParent.resolvingSymlinksInPath().path + "/"))
        #expect(package.rootURL.path != packageRoot.path)
        #expect(package.canonicalSHA256 == plan.package.canonicalSHA256)
        #expect(package.files.map(\.relativePath) == plan.package.files)
        for (path, text) in traditionalFiles {
            #expect(try String(contentsOf: package.rootURL.appendingPathComponent(path), encoding: .utf8) == text)
        }
        // A traditional package never receives a generated floe.json.
        #expect(!FileManager.default.fileExists(atPath: package.rootURL.appendingPathComponent("floe.json").path))
        // The source directory keeps the exact reviewed bytes.
        #expect(
            try SkillPackageValidator().validate(packageAt: packageRoot, requireManifest: false).canonicalSHA256
                == plan.package.canonicalSHA256
        )
    }

    @Test("Staging refuses changed or unsafe bytes and cleans up its container")
    func stagingFailures() throws {
        let workspace = try makeSkillWorkspaceInstallTemporaryDirectory("staging-failure")
        let stagingParent = try makeSkillWorkspaceInstallTemporaryDirectory("staging-failure-parent")
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: stagingParent)
        }
        let packageRoot = try writeFiles(traditionalFiles, under: workspace, directory: "skills/demo")
        let plan = try SkillWorkspaceInstallPlanner.plan(
            try SkillWorkspaceInstallRequest(directory: "skills/demo"),
            in: workspace
        )

        try Data("changed after review\n".utf8).write(
            to: packageRoot.appendingPathComponent("scripts/report.py"),
            options: .atomic
        )
        #expect(throws: SkillWorkspaceInstallError.packageChanged) {
            try SkillWorkspaceInstallStaging.stage(plan, parent: stagingParent)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: stagingParent.path).isEmpty)

        let outside = try makeSkillWorkspaceInstallTemporaryDirectory("staging-outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: packageRoot.appendingPathComponent("assets/escape.txt"),
            withDestinationURL: outside.appendingPathComponent("secret.txt")
        )
        #expect(throws: SkillValidationError.self) {
            try SkillWorkspaceInstallStaging.stage(plan, parent: stagingParent)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: stagingParent.path).isEmpty)

        try FileManager.default.removeItem(at: packageRoot.appendingPathComponent("assets/escape.txt"))
        try Data(repeating: 0x41, count: SkillValidationLimits().maximumFileBytes + 1).write(
            to: packageRoot.appendingPathComponent("assets/oversized.bin")
        )
        #expect(throws: SkillValidationError.self) {
            try SkillWorkspaceInstallStaging.stage(plan, parent: stagingParent)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: stagingParent.path).isEmpty)
    }

    @Test("A component swapped for a link after planning cannot escape the workspace")
    func stagingRejectsSwappedComponent() throws {
        let workspace = try makeSkillWorkspaceInstallTemporaryDirectory("swapped")
        let stagingParent = try makeSkillWorkspaceInstallTemporaryDirectory("swapped-staging")
        let outside = try makeSkillWorkspaceInstallTemporaryDirectory("swapped-outside")
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: stagingParent)
            try? FileManager.default.removeItem(at: outside)
        }
        _ = try writeFiles(traditionalFiles, under: workspace, directory: "outer/demo")
        _ = try writeFiles(traditionalFiles, under: outside, directory: "demo")
        let plan = try SkillWorkspaceInstallPlanner.plan(
            try SkillWorkspaceInstallRequest(directory: "outer/demo"),
            in: workspace
        )
        let planned = workspace.appendingPathComponent("outer", isDirectory: true)
        try FileManager.default.removeItem(at: planned)
        try FileManager.default.createSymbolicLink(at: planned, withDestinationURL: outside)
        #expect(throws: SkillWorkspaceInstallError.directoryOutsideWorkspace) {
            try SkillWorkspaceInstallStaging.stage(plan, parent: stagingParent)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: stagingParent.path).isEmpty)
    }

    // MARK: - Existing install transaction

    @Test("The existing install transaction accepts the plan and installs every file")
    func existingInstallTransaction() async throws {
        let workspace = try makeSkillWorkspaceInstallTemporaryDirectory("transaction")
        let stagingParent = try makeSkillWorkspaceInstallTemporaryDirectory("transaction-staging")
        let installedRoot = try makeSkillWorkspaceInstallTemporaryDirectory("transaction-installed")
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: stagingParent)
            try? FileManager.default.removeItem(at: installedRoot)
        }
        _ = try writeFiles(traditionalFiles, under: workspace, directory: "skills/demo")
        let plan = try SkillWorkspaceInstallPlanner.plan(
            try SkillWorkspaceInstallRequest(directory: "skills/demo"),
            in: workspace
        )
        let staged = try SkillWorkspaceInstallStaging.stage(plan, parent: stagingParent)
        let stores = RecordingMetadataStore()
        let service = SkillInstallStagingService(installationRoot: installedRoot, metadataStore: stores)
        let record = try await service.installRewrittenPackage(
            at: staged.rootURL,
            provenance: SkillInstallProvenance(
                sourceURL: plan.sourceURL,
                originalSHA256: plan.package.canonicalSHA256,
                expectedRewrittenSHA256: plan.package.canonicalSHA256,
                rewriteModelID: SkillWorkspaceInstallIdentity.rewriteModelID,
                compatibilitySummary: "Workspace package import"
            ),
            replaceExisting: false,
            manifestOverride: SkillPackageValidator()
                .validate(packageAt: staged.rootURL, requireManifest: false)
                .manifest
        )
        #expect(record.skillID == plan.package.skillID)
        #expect(record.version == plan.package.version)
        #expect(record.canonicalSHA256 == plan.package.canonicalSHA256)
        #expect(record.provenance.sourceURL == plan.sourceURL)
        #expect(record.originalPayloadStored == false)
        let installed = installedRoot.appendingPathComponent(plan.package.skillID, isDirectory: true)
        #expect(record.canonicalPackageURL.path == installed.path)
        #expect(try installedFilePaths(installed) == plan.package.files)
        for (path, text) in traditionalFiles {
            #expect(try String(contentsOf: installed.appendingPathComponent(path), encoding: .utf8) == text)
        }
        #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent("floe.json").path))
        #expect(await stores.records().count == 1)

        // Replacement through the same transaction: new bytes, same identity.
        let replacementFiles = traditionalFiles.merging(["reference/guide.md": "Updated guidance\n"]) { _, new in new }
        let replacementRoot = try writeFiles(replacementFiles, under: workspace, directory: "skills/demo-replacement")
        let replacementPlan = try SkillWorkspaceInstallPlanner.plan(
            try SkillWorkspaceInstallRequest(
                directory: "skills/demo-replacement",
                mode: .replace,
                expectedDigest: record.canonicalSHA256
            ),
            in: workspace
        )
        #expect(replacementPlan.isReplacement)
        let replacementStaged = try SkillWorkspaceInstallStaging.stage(replacementPlan, parent: stagingParent)
        let replacementRecord = try await service.installRewrittenPackage(
            at: replacementStaged.rootURL,
            provenance: SkillInstallProvenance(
                sourceURL: replacementPlan.sourceURL,
                originalSHA256: replacementPlan.package.canonicalSHA256,
                expectedRewrittenSHA256: replacementPlan.package.canonicalSHA256,
                rewriteModelID: SkillWorkspaceInstallIdentity.rewriteModelID,
                compatibilitySummary: "Workspace package replacement"
            ),
            replaceExisting: true,
            manifestOverride: SkillPackageValidator()
                .validate(packageAt: replacementStaged.rootURL, requireManifest: false)
                .manifest
        )
        #expect(replacementRecord.canonicalSHA256 == replacementPlan.package.canonicalSHA256)
        #expect(replacementRecord.canonicalSHA256 != record.canonicalSHA256)
        #expect(
            try String(contentsOf: installed.appendingPathComponent("reference/guide.md"), encoding: .utf8)
                == "Updated guidance\n"
        )
        #expect(try installedFilePaths(installed) == replacementPlan.package.files)
        #expect(await stores.records().count == 2)
        #expect(!FileManager.default.fileExists(atPath: replacementRoot.appendingPathComponent("floe.json").path))
    }
}

// MARK: - Fixtures

private let packagedManifestJSON: String = {
    let manifest = SkillManifest(
        id: "packaged-skill",
        version: "2.3.4",
        capabilities: [SkillCapability.workspaceRead.rawValue],
        tools: ["workspace.readFile"],
        scriptRuntime: .none
    )
    let data = try! JSONEncoder().encode(manifest)
    return String(decoding: data, as: UTF8.self)
}()

private let traditionalFiles: [String: String] = [
    "SKILL.md": skillMarkdown(name: "demo-skill"),
    "scripts/report.py": "print('hello')\n",
    "reference/guide.md": "Upstream guidance\n",
    "references/second.md": "Second upstream reference\n",
    "assets/logo.txt": "logo\n",
    "LICENSE": "MIT\n",
    "NOTICE": "Notice\n",
    "agents/openai.yaml": "interface:\n  display_name: Demo\n"
]

private func skillMarkdown(name: String) -> String {
    "---\nname: \(name)\ndescription: Reusable demo workflow\n---\n# \(name)\nUse this workflow.\n"
}

private func makeSkillWorkspaceInstallTemporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-workspace-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func writeFiles(_ files: [String: String], under root: URL, directory: String) throws -> URL {
    let packageRoot = root.appendingPathComponent(directory, isDirectory: true)
    for (path, text) in files {
        let destination = packageRoot.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: destination, options: .atomic)
    }
    return packageRoot
}

private func installedFilePaths(_ root: URL) throws -> [String] {
    let prefix = root.standardizedFileURL.path + "/"
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    ) else { return [] }
    var paths: [String] = []
    for case let url as URL in enumerator {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
        paths.append(String(url.standardizedFileURL.path.dropFirst(prefix.count)))
    }
    return paths.sorted()
}

private func makeContext(
    workspace: URL?,
    approved: Bool = true,
    cancellation: CancellationToken = CancellationToken(),
    allowedPaths: [String] = [],
    temporary: Bool = false
) -> ToolContext {
    ToolContext(
        runID: UUID(),
        approvalGrantID: approved ? UUID() : nil,
        workspaceRootURL: workspace,
        allowedWorkspacePaths: allowedPaths,
        cancellation: cancellation,
        temporaryReadOnly: temporary
    )
}

// MARK: - Fakes

private extension SkillWorkspaceInstallPlan {
    var isDirectoryInsideWorkspace: Bool {
        directoryURL.path.hasPrefix(workspaceRootURL.path + "/")
    }
}

private actor PlanRecorder {
    private var recorded: [SkillWorkspaceInstallPlan] = []
    func record(_ plan: SkillWorkspaceInstallPlan) { recorded.append(plan) }
    func plans() -> [SkillWorkspaceInstallPlan] { recorded }
}

private actor RecordingMetadataStore: SkillInstallationMetadataStore {
    private var stored: [SkillInstallationRecord] = []
    func persist(_ record: SkillInstallationRecord) async throws { stored.append(record) }
    func records() -> [SkillInstallationRecord] { stored }
}

private struct SuccessfulInstaller: SkillWorkspaceInstalling {
    let recorder: PlanRecorder?
    func install(_ plan: SkillWorkspaceInstallPlan) async throws -> SkillWorkspaceInstallCommit {
        await recorder?.record(plan)
        return SkillWorkspaceInstallCommit(
            skillID: plan.package.skillID,
            version: plan.package.version,
            canonicalSHA256: plan.package.canonicalSHA256,
            previousDigest: plan.mode == .replace ? plan.expectedDigest : nil
        )
    }
}

private struct FailingInstaller: SkillWorkspaceInstalling {
    let error: FloeError
    func install(_ plan: SkillWorkspaceInstallPlan) async throws -> SkillWorkspaceInstallCommit {
        throw error
    }
}

private struct MismatchedDigestInstaller: SkillWorkspaceInstalling {
    func install(_ plan: SkillWorkspaceInstallPlan) async throws -> SkillWorkspaceInstallCommit {
        SkillWorkspaceInstallCommit(
            skillID: plan.package.skillID,
            version: plan.package.version,
            canonicalSHA256: String(repeating: "f", count: 64),
            previousDigest: nil
        )
    }
}

private struct WrongPreviousDigestInstaller: SkillWorkspaceInstalling {
    func install(_ plan: SkillWorkspaceInstallPlan) async throws -> SkillWorkspaceInstallCommit {
        SkillWorkspaceInstallCommit(
            skillID: plan.package.skillID,
            version: plan.package.version,
            canonicalSHA256: plan.package.canonicalSHA256,
            previousDigest: String(repeating: "d", count: 64)
        )
    }
}

private struct UnexpectedPreviousDigestInstaller: SkillWorkspaceInstalling {
    func install(_ plan: SkillWorkspaceInstallPlan) async throws -> SkillWorkspaceInstallCommit {
        SkillWorkspaceInstallCommit(
            skillID: plan.package.skillID,
            version: plan.package.version,
            canonicalSHA256: plan.package.canonicalSHA256,
            previousDigest: String(repeating: "e", count: 64)
        )
    }
}

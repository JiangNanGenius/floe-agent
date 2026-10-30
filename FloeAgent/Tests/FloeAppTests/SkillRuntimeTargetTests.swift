// FloeAppTests — trusted Skill execution-target routing.
//
// These tests lock the source contract without claiming any real remote,
// guest, simulator or App run:
//   * App-native/text guides stay readable for App-native, Linux, macOS and
//     unresolved targets; a remote/default/migration target never hides them;
//   * external scripts are judged against the ACTUAL OS/architecture, and a
//     missing/disconnected target is an explicit limitation, never a host
//     fallback;
//   * install admission does not turn a deferred external half into a
//     portability or readiness claim;
//   * discovery keeps same-id original/adapted variants as independent rows
//     and preserves disabled state;
//   * the primary's merge of Mac-original and device selections does not
//     collapse instructions, ids or preapproval sets.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeSkills
import FloeTools
@testable import FloeApp

private struct PackageFixture {
    let root: URL
    let package: ValidatedSkillPackage

    static func make(
        id: String = "target-guide",
        capabilities: [String] = [],
        tools: [String] = [],
        platforms: [String] = ["ios"],
        scriptRuntime: SkillScriptRuntime = .none,
        runtime: SkillRuntimeRequirements? = nil,
        scripts: [String: String] = [:],
        extraFiles: [String: String] = [:]
    ) throws -> PackageFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-target-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let markdown = """
        ---
        name: \(id)
        description: Fixture guide for target routing tests.
        ---

        Follow the documented steps.
        """
        try Data(markdown.utf8).write(to: root.appendingPathComponent("SKILL.md"), options: .atomic)
        let manifest = SkillManifest(
            id: id, version: "1.0.0", capabilities: capabilities, tools: tools,
            platforms: platforms, scriptRuntime: scriptRuntime, runtime: runtime
        )
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("floe.json"), options: .atomic)
        let files = scripts.merging(extraFiles, uniquingKeysWith: { _, extra in extra })
        for (path, contents) in files {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: target, options: .atomic)
        }
        return PackageFixture(
            root: root,
            package: try SkillPackageValidator().validate(packageAt: root)
        )
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

private let appCapabilities: Set<SkillCapability> = [
    .workspaceRead, .workspaceWrite, .workspaceDelete, .network,
    .browserObserve, .browserInteract
]
private let appTools: Set<String> = ["exec.shell"]

private func compatibilityReport(
    _ package: ValidatedSkillPackage,
    target: SkillRuntimeTarget?,
    mode: SkillRuntimeCompatibilityMode = .run
) -> SkillTargetCompatibilityReport {
    SkillRuntimeCompatibility.evaluate(
        package, target: target,
        appCapabilities: appCapabilities, appTools: appTools, mode: mode
    )
}

private func makeMigrationTemporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-migration-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Materialize a validated fixture into the center's installation root and
/// persist its installed row. The optional typed receipt is the exact fixture
/// shape the curated authority gate expects; it never invents permissions.
@discardableResult
private func installFixture(
    _ fixture: PackageFixture,
    in installationRoot: URL,
    environment: AppEnvironment,
    curatedReceiptJSON: String? = nil
) async throws -> PersistedSkill {
    let manifest = fixture.package.manifest
    let destination = installationRoot.appendingPathComponent(manifest.id, isDirectory: true)
    for file in fixture.package.files {
        let source = fixture.root.appendingPathComponent(file.relativePath)
        let target = destination.appendingPathComponent(file.relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contentsOf: source).write(to: target, options: .atomic)
    }
    let markdown = try String(
        contentsOf: fixture.root.appendingPathComponent("SKILL.md"), encoding: .utf8
    )
    let manifestJSON = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
    let row = PersistedSkill(
        id: manifest.id,
        name: manifest.id,
        version: manifest.version,
        skillMarkdown: markdown,
        manifestJSON: manifestJSON,
        rewrittenDigest: fixture.package.canonicalSHA256,
        compatibilityReportJSON: curatedReceiptJSON ?? "{}"
    )
    try await environment.skillStore.save(
        row, grantCapabilities: manifest.capabilities, replaceGrants: true
    )
    return row
}

/// Minimal signed-production-shape receipt for tests that need the existing
/// curated dependency authority gate. Digests are canonical hex; the actual
/// package digest is supplied by the caller.
private func dependencyReceiptJSON(
    contentDigest: String,
    entryID: String,
    entryVersion: String
) -> String {
    let object: [String: Any] = [
        "receiptSchemaVersion": 1,
        "channel": "ios",
        "feedStatus": "production",
        "hubRepository": CuratedSkillHub.hubRepository,
        "publisher": CuratedSkillHub.publisher,
        "feedSignatureKeyID": CuratedSkillHub.productionKeyID,
        "auditedSourceCommit": String(repeating: "d", count: 40),
        "publicationCommit": String(repeating: "2", count: 40),
        "catalogSHA256": String(repeating: "b", count: 64),
        "catalogByteCount": 100,
        "entryID": entryID,
        "entryVersion": entryVersion,
        "packagePath": "packages/\(entryID).zip",
        "packageSize": 1,
        "packageSHA256": String(repeating: "a", count: 64),
        "contentDigest": contentDigest,
        "containsScripts": true,
        "reviewPath": "reviews/\(entryID).json",
        "reviewSHA256": String(repeating: "c", count: 64),
        "reviewKeyID": CuratedSkillHub.productionKeyID,
        "reviewStage": "static-content-reviewed",
        "reviewDecision": "approve",
        "reviewedAt": "2026-10-30T00:00:00Z",
        "reviewer": "fixture",
        "permissionDelta": [
            "requiredCapabilities": ["execution.remote"],
            "requiredTools": ["exec.shell"],
            "requiredPythonPackageSpecs": [],
            "missingCapabilities": [],
            "missingTools": [],
            "missingPythonPackageSpecs": []
        ]
    ]
    let data = try! JSONSerialization.data(
        withJSONObject: ["curatedHubReceipt": object], options: [.sortedKeys]
    )
    return String(decoding: data, as: UTF8.self)
}

private actor StagePublishProbe {
    private var published: [SkillStagedBundle] = []
    func record(_ bundle: SkillStagedBundle) { published.append(bundle) }
    func publishedCount() -> Int { published.count }
}

@Suite("FloeApp.SkillRuntimeTarget", .serialized)
struct SkillRuntimeTargetTests {
    @Test func appNativeAndTextGuidesRemainRunnableOnEveryTarget() throws {
        let fixture = try PackageFixture.make()
        defer { fixture.clean() }
        let targets: [SkillRuntimeTarget?] = [
            nil,
            .appNative(),
            .linuxGuest(environmentID: "linux", architecture: "arm64", distribution: "debian"),
            .macBridge(environmentID: "mac", architecture: "arm64"),
            .remoteSSH(environmentID: "ssh", remoteHostID: UUID(), remoteRootPath: "/workspace",
                       operatingSystem: .linux, architecture: "x86_64", distribution: "ubuntu"),
            .unresolved
        ]
        for target in targets {
            let report = compatibilityReport(fixture.package, target: target)
            #expect(report.isRunnableOnTarget, "text/native guide must survive \(target?.runtimeDescription ?? "nil")")
            #expect(report.targetProblems.isEmpty)
        }
    }

    @Test func externalScriptsAreJudgedByActualOSAndArchitecture() throws {
        let fixture = try PackageFixture.make(
            capabilities: ["execution.remote"], tools: ["exec.shell"],
            scriptRuntime: .remote,
            runtime: .init(os: ["linux"], architectures: ["arm64"]),
            scripts: ["scripts/run.sh": "echo ok\n"]
        )
        defer { fixture.clean() }

        let arm = compatibilityReport(fixture.package, target: .linuxGuest(
            environmentID: "linux", architecture: "aarch64", distribution: "debian"
        ))
        #expect(arm.isRunnableOnTarget)
        #expect(arm.targetProblems.isEmpty)

        let riscv = compatibilityReport(fixture.package, target: .linuxGuest(
            environmentID: "linux", architecture: "riscv64", distribution: "debian"
        ))
        #expect(!riscv.isRunnableOnTarget)
        #expect(riscv.targetProblems.contains {
            if case .runtimeArchitectureMismatch(let required, _) = $0 { return required == ["arm64"] }
            return false
        })

        let mac = compatibilityReport(fixture.package, target: .macBridge(
            environmentID: "mac", architecture: "arm64"
        ))
        #expect(!mac.isRunnableOnTarget)
        #expect(mac.targetProblems.contains {
            if case .runtimeOSMismatch(let required, _) = $0 { return required == ["linux"] }
            return false
        })

        let native = compatibilityReport(fixture.package, target: .appNative())
        #expect(!native.isRunnableOnTarget)
        #expect(native.targetProblems.contains(.externalExecutionUnavailable))
    }

    @Test func unresolvedAndDisconnectedTargetsAreExplicitNotFallbacks() throws {
        let fixture = try PackageFixture.make(
            capabilities: ["execution.remote"], tools: ["exec.shell"],
            scriptRuntime: .remote, runtime: .init(os: ["linux"], architectures: ["any"]),
            scripts: ["scripts/run.sh": "echo ok\n"]
        )
        defer { fixture.clean() }

        let unresolvedNil = compatibilityReport(fixture.package, target: nil)
        #expect(!unresolvedNil.isRunnableOnTarget)
        #expect(unresolvedNil.targetProblems == [.targetUnresolved])

        let unresolvedFact = compatibilityReport(fixture.package, target: .unresolved)
        #expect(!unresolvedFact.isRunnableOnTarget)
        #expect(unresolvedFact.targetProblems == [.targetUnresolved])

        let offline = compatibilityReport(fixture.package, target: .macBridge(
            environmentID: "mac", architecture: "arm64", isConnected: false
        ))
        #expect(!offline.isRunnableOnTarget)
        #expect(offline.targetProblems.contains(.targetDisconnected))
        #expect(!offline.targetProblems.contains(.targetUnresolved))
    }

    @Test func installAdmissionDefersExternalWorkWithoutClaimingReadiness() throws {
        let external = try PackageFixture.make(
            capabilities: ["execution.remote"], tools: ["exec.shell"],
            scriptRuntime: .remote, runtime: .init(os: ["linux"], architectures: ["arm64"]),
            scripts: ["scripts/run.sh": "echo ok\n"]
        )
        defer { external.clean() }
        let install = compatibilityReport(external.package, target: nil, mode: .install)
        #expect(install.isInstallable)
        #expect(!install.isRunnableOnTarget)
        #expect(install.externalWorkDeferred)

        let androidOnly = try PackageFixture.make(platforms: ["android"])
        defer { androidOnly.clean() }
        #expect(!compatibilityReport(androidOnly.package, target: nil, mode: .install).isInstallable)
    }

    @Test func variantDiscoveryPreservesSameIDDifferentImplementationAndDisabledState() {
        let installed = ManagedSkill(
            id: "shared-guide", name: "Linux adaptation", version: "2.0.0",
            enabled: false, digest: String(repeating: "a", count: 64),
            description: "Installed adaptation"
        )
        let original = ManagedSkill(
            id: "shared-guide", name: "macOS original", version: "1.4.0",
            enabled: true, digest: String(repeating: "b", count: 64),
            description: "Upstream original"
        )
        let native = ManagedSkill(
            id: "floe-office", name: "Office", version: "1.5.0",
            enabled: true, digest: String(repeating: "c", count: 64),
            description: "Bundled native guide"
        )
        let duplicate = ManagedSkill(
            id: "shared-guide", name: "Linux adaptation", version: "2.0.0",
            enabled: false, digest: String(repeating: "a", count: 64),
            description: "Installed adaptation"
        )
        let merged = SkillRuntimeDiscovery.merged(
            installed: [installed, duplicate], nativeBundled: [native], macOriginals: [original]
        )
        #expect(merged.count == 3)
        #expect(merged.filter { $0.id == "shared-guide" }.count == 2)
        #expect(merged.first { $0.id == "shared-guide" && $0.digest == installed.digest }?.enabled == false,
                "a disabled installed variant must stay disabled")
        #expect(merged.first { $0.id == "shared-guide" && $0.digest == original.digest }?.enabled == true)
        #expect(merged.contains { $0.id == "floe-office" })
    }

    @Test func targetIdentityExcludesGenerationButIncludesBackendAndRemoteHost() {
        let arm = SkillRuntimeTarget.linuxGuest(
            environmentID: "env", architecture: "aarch64", distribution: "debian"
        )
        var rebooted = arm
        rebooted.runtimeGeneration = "boot-2"
        #expect(arm.identityFingerprint == rebooted.identityFingerprint,
                "a reboot keeps the plan identity")
        #expect(arm.generationToken == nil && rebooted.generationToken == "boot-2")

        let hostA = UUID()
        let hostB = UUID()
        let sshA = SkillRuntimeTarget.remoteSSH(
            environmentID: "env", remoteHostID: hostA, remoteRootPath: "/workspace",
            operatingSystem: .linux, architecture: "arm64", distribution: "debian"
        )
        let sshB = SkillRuntimeTarget.remoteSSH(
            environmentID: "env", remoteHostID: hostB, remoteRootPath: "/workspace",
            operatingSystem: .linux, architecture: "arm64", distribution: "debian"
        )
        #expect(sshA.identityFingerprint != sshB.identityFingerprint)
        #expect(sshA.supportsDebianAPT)
        #expect(!SkillRuntimeTarget.macBridge(environmentID: "mac").supportsDebianAPT)
        #expect(!SkillRuntimeTarget.remoteSSH(
            environmentID: "remote", remoteHostID: hostA, remoteRootPath: "/workspace",
            operatingSystem: .linux, architecture: "arm64", distribution: nil
        ).supportsDebianAPT)
        // Only the reviewed local Linux-VM rootfs may omit its Debian fact.
        #expect(SkillRuntimeTarget.linuxGuest(
            environmentID: "guest", architecture: "arm64", distribution: nil
        ).supportsDebianAPT)
    }

    @Test @MainActor func runtimeSelectionMergeKeepsNativeAndOriginalInstructions() {
        let device = SkillsCenter.RuntimeSelection(
            skillIDs: ["floe-office", "installed-text"],
            allowedToolNames: ["exec.shell", "document.pdf.inspect"],
            instructions: "device block",
            preapprovedPythonScriptSHA256: ["a"],
            preapprovedPythonPackages: ["pypdf==5.4.0"],
            relatedSkillIDsByTool: ["exec.shell": ["installed-text"]]
        )
        let originals = SkillsCenter.RuntimeSelection(
            skillIDs: ["mac-original", "floe-office"],
            allowedToolNames: ["exec.shell", "web.fetch"],
            instructions: "mac block",
            preapprovedPythonScriptSHA256: ["b"],
            preapprovedPythonPackages: [],
            relatedSkillIDsByTool: ["exec.shell": ["mac-original"]]
        )
        let merged = SkillsCenter.mergedRuntimeSelection([device, originals])
        #expect(merged.skillIDs == Set(["floe-office", "installed-text", "mac-original"]))
        #expect(merged.instructions == "device block\n\nmac block")
        #expect(merged.preapprovedPythonScriptSHA256 == Set(["a", "b"]))
        #expect(merged.preapprovedPythonPackages == Set(["pypdf==5.4.0"]))
        #expect(merged.allowedToolNames == Set(["exec.shell"]))
        #expect(merged.relatedSkillIDsByTool["exec.shell"] == ["installed-text", "mac-original"])
    }

    @Test @MainActor func bundledNativeGuidesAndInstalledTextGuidesSurviveDiscovery() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-target-discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let center = SkillsCenter(environment: environment, installationRoot: root)
        let bundled = try await center.nativeBundledSkillsForMac()
        #expect(bundled.contains { $0.id == "floe-office" })
        #expect(bundled.contains { $0.id == "floe-network" })
        #expect(bundled.allSatisfy { $0.id != "floe-python" },
                "the Linux substrate guide is not a native macOS guide")

        let created = try await center.createSkill(.init(
            name: "Installed Text Guide", description: "Text-only installed guide",
            instructions: "Read this text guide only."
        ))
        let inventory = try await center.readSkills(id: nil)
        #expect(inventory.contains { $0.id == created.id })
        #expect(inventory.contains { $0.id == "floe-office" })

        // Simulate a Mac-bound discovery merge: the installed text guide, the
        // bundled native guide and an independent same-id Mac original all
        // remain visible; nothing replaces the installed universe.
        let macOriginal = ManagedSkill(
            id: created.id, name: "Upstream original", version: "0.9.0",
            enabled: true, digest: String(repeating: "d", count: 64),
            description: "Independent original implementation"
        )
        let merged = SkillRuntimeDiscovery.merged(
            installed: inventory, nativeBundled: bundled, macOriginals: [macOriginal]
        )
        let installedDigest = try #require(inventory.first { $0.id == created.id }).digest
        #expect(merged.contains { $0.id == created.id && $0.digest == installedDigest })
        #expect(merged.contains { $0.id == created.id && $0.digest == macOriginal.digest })
        #expect(merged.contains { $0.id == "floe-office" })
    }

    // MARK: - Migration preflight / staging / plan eligibility

    @Test func declarationPlanEligibilityCoversRealExternalTargetsOnly() {
        #expect(SkillsCenter.targetAllowsDeclaredDependencyPlan(nil),
                "the no-resolver legacy path keeps the historical behavior")
        #expect(!SkillsCenter.targetAllowsDeclaredDependencyPlan(.unresolved),
                "a configured resolver returning nil is final, never a legacy fallback")
        #expect(!SkillsCenter.targetAllowsDeclaredDependencyPlan(.appNative()))
        #expect(SkillsCenter.targetAllowsDeclaredDependencyPlan(.linuxGuest(
            environmentID: "linux", architecture: "arm64", distribution: "debian"
        )))
        #expect(SkillsCenter.targetAllowsDeclaredDependencyPlan(.macBridge(
            environmentID: "mac", architecture: "arm64"
        )), "a real Mac target may plan its pip/npm declarations")
        #expect(SkillsCenter.targetAllowsDeclaredDependencyPlan(.remoteSSH(
            environmentID: "ssh", remoteHostID: UUID(), remoteRootPath: "/workspace",
            operatingSystem: .linux, architecture: "x86_64", distribution: "ubuntu"
        )))
        #expect(SkillsCenter.targetAllowsDeclaredDependencyPlan(.remoteSSH(
            environmentID: "ssh-mac", remoteHostID: UUID(), remoteRootPath: "/workspace",
            operatingSystem: .macOS, architecture: "arm64"
        )))
    }

    @Test func runtimeComponentPlansStayLinuxRISCVOnly() {
        #expect(SkillsCenter.targetAllowsRuntimeComponentPlan(nil),
                "the no-resolver legacy path keeps the historical behavior")
        #expect(SkillsCenter.targetAllowsRuntimeComponentPlan(.linuxGuest(
            environmentID: "linux", architecture: "riscv64", distribution: "debian"
        )))
        #expect(!SkillsCenter.targetAllowsRuntimeComponentPlan(.linuxGuest(
            environmentID: "linux", architecture: "arm64", distribution: "debian"
        )))
        #expect(!SkillsCenter.targetAllowsRuntimeComponentPlan(.macBridge(
            environmentID: "mac", architecture: "arm64"
        )), "a Mac target must never record the frozen Linux component plan")
        #expect(!SkillsCenter.targetAllowsRuntimeComponentPlan(.unresolved))
    }

    @Test @MainActor func migrationPreviewSeparatesExternalLossFromNativeTextGuides() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let root = try makeMigrationTemporaryDirectory("preview-root")
        defer { try? FileManager.default.removeItem(at: root) }
        let center = SkillsCenter(environment: environment, installationRoot: root)

        let text = try await center.createSkill(.init(
            name: "Migration Text Guide", description: "Text-only installed guide",
            instructions: "Read this text guide only."
        ))
        let externalFixture = try PackageFixture.make(
            id: "migration-external",
            capabilities: ["execution.remote"], tools: ["exec.shell"],
            scriptRuntime: .remote,
            runtime: .init(os: ["linux"], architectures: ["arm64"]),
            scripts: ["scripts/run.sh": "echo ok\n"]
        )
        defer { externalFixture.clean() }
        let externalRow = try await installFixture(
            externalFixture, in: root, environment: environment
        )

        let mac = await center.migrationPreview(
            target: .macBridge(environmentID: "mac", architecture: "arm64")
        )
        #expect(mac.limitations.contains { $0.skillID == externalRow.id })
        #expect(!mac.limitations.contains { $0.skillID == text.id },
                "text/native guidance is never a migration capability loss")
        #expect(mac.modelManagedSkillIDs.contains(externalRow.id),
                "an external skill without a declaration stays model-managed")
        #expect(mac.blockingReasons.isEmpty)
        #expect(mac.requiresExplicitAcceptance)
        #expect(mac.optionalCapabilityLosses.contains { $0.contains("migration-external") })

        let linux = await center.migrationPreview(
            target: .linuxGuest(environmentID: "linux", architecture: "arm64", distribution: "debian")
        )
        #expect(linux.limitations.isEmpty,
                "the same external package is compatible on its declared Linux/arm64 target")
        #expect(linux.modelManagedSkillIDs.contains(externalRow.id))
        #expect(linux.blockingReasons.isEmpty)

        let unresolved = await center.migrationPreview(target: .unresolved)
        #expect(!unresolved.canProceed)
        #expect(unresolved.blockingReasons.contains(SkillDependencyReason.targetUnavailable))
    }

    @Test @MainActor func migrationPreviewReportsReviewedDependenciesForTarget() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let root = try makeMigrationTemporaryDirectory("dependency-preview-root")
        defer { try? FileManager.default.removeItem(at: root) }
        let center = SkillsCenter(environment: environment, installationRoot: root)

        let declaration = #"""
        {"schemaVersion":1,"profiles":[{"id":"linux-riscv64","target":{"os":"linux","architectures":["riscv64"]},"requirements":[{"kind":"apt","name":"hello","version":"2.10-5","purpose":"Fixture tool","required":true}]}]}
        """#
        let fixture = try PackageFixture.make(
            id: "migration-dependency",
            capabilities: ["execution.remote"], tools: ["exec.shell"],
            scriptRuntime: .remote,
            runtime: .init(os: ["linux", "macos"], architectures: ["any"]),
            scripts: ["scripts/run.sh": "echo ok\n"],
            extraFiles: [SkillDependency.packagePath: declaration]
        )
        defer { fixture.clean() }
        let row = try await installFixture(
            fixture, in: root, environment: environment,
            curatedReceiptJSON: dependencyReceiptJSON(
                contentDigest: fixture.package.canonicalSHA256,
                entryID: fixture.package.manifest.id,
                entryVersion: fixture.package.manifest.version
            )
        )

        let linux = await center.migrationPreview(
            target: .linuxGuest(environmentID: "linux", architecture: "riscv64", distribution: "debian")
        )
        #expect(linux.blockingReasons.isEmpty)
        #expect(linux.dependencies.count == 1)
        #expect(linux.requiresDependencyPreparation)
        #expect(linux.targetFingerprint
            == SkillRuntimeTarget.linuxGuest(
                environmentID: "linux", architecture: "riscv64", distribution: "debian"
            ).identityFingerprint)
        let dependency = try #require(linux.dependencies.first)
        #expect(dependency.skillID == row.id)
        #expect(dependency.kind == "apt")
        #expect(dependency.name == "hello")
        #expect(dependency.version == "2.10-5")
        #expect(dependency.required)
        #expect(dependency.targetSupported)
        #expect(!linux.modelManagedSkillIDs.contains(row.id))

        // The declaration is Linux/RISC-V only: a real external macOS target
        // has no matching reviewed profile, so migration must not pretend the
        // requirement can be prepared there.
        let mac = await center.migrationPreview(
            target: .macBridge(environmentID: "mac", architecture: "arm64")
        )
        #expect(mac.dependencies.isEmpty)
        #expect(mac.blockingReasons.contains { $0.contains("none of the reviewed profiles") })
        #expect(!mac.canProceed)
    }

    @Test @MainActor func migrationPreviewTreatsUnvalidatedUnrequiredSkillAsOptionalLoss() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let root = try makeMigrationTemporaryDirectory("invalid-preview-root")
        defer { try? FileManager.default.removeItem(at: root) }
        let center = SkillsCenter(environment: environment, installationRoot: root)

        let fixture = try PackageFixture.make(
            id: "migration-invalid",
            capabilities: ["execution.remote"], tools: ["exec.shell"],
            scriptRuntime: .remote,
            runtime: .init(os: ["linux"], architectures: ["arm64"]),
            scripts: ["scripts/run.sh": "echo ok\n"]
        )
        defer { fixture.clean() }
        let row = try await installFixture(fixture, in: root, environment: environment)
        // Simulate an installed pinned package whose bytes no longer match the
        // persisted digest, as observed for the dormant floe-office row.
        let skillURL = root.appendingPathComponent(row.id).appendingPathComponent("SKILL.md")
        let existing = try String(contentsOf: skillURL, encoding: .utf8)
        try Data((existing + "\nStale installed copy.\n").utf8)
            .write(to: skillURL, options: .atomic)

        let target = SkillRuntimeTarget.linuxGuest(
            environmentID: "linux", architecture: "arm64", distribution: "debian"
        )
        // No unfinished run actually requires this installed Skill: it must
        // not block the whole move.
        let preview = await center.migrationPreview(target: target, requiredSkillIDs: [])
        #expect(preview.canProceed)
        #expect(preview.blockingReasons.isEmpty)
        #expect(preview.blockingIssues.isEmpty)
        #expect(preview.requiresExplicitAcceptance)
        #expect(preview.limitations.contains {
            $0.skillID == row.id && $0.kind == .unvalidatablePackage
        })
        let loss = try #require(preview.optionalLosses.first { $0.skillID == row.id })
        #expect(loss.kind == .unvalidatableSkill)
        #expect(loss.name == row.name)
        #expect(loss.diagnostic == SkillMigrationStagingReason.invalidPinnedPackage)
        #expect(preview.optionalCapabilityLossIDs == [row.id])
        #expect(preview.acceptsCapabilityLosses(
            preview.optionalCapabilityLosses, acceptedIDs: preview.optionalCapabilityLossIDs))
        #expect(!preview.acceptsCapabilityLosses(
            preview.optionalCapabilityLosses, acceptedIDs: []),
            "an accepted preview must not match an empty accepted-id set")
        #expect(!preview.acceptsCapabilityLosses([], acceptedIDs: preview.optionalCapabilityLossIDs),
            "changing only one half of the acceptance identity must fail")

        // An actually required Skill with the same invalid bytes still blocks.
        let required = await center.migrationPreview(
            target: target, requiredSkillIDs: [row.id]
        )
        #expect(!required.canProceed)
        #expect(required.optionalLosses.isEmpty)
        #expect(required.blockingIssues.contains {
            $0.kind == .unvalidatableRequiredSkill && $0.skillID == row.id
        })
        #expect(required.blockingReasons.contains {
            $0.contains(row.id) && $0.contains(SkillMigrationStagingReason.invalidPinnedPackage)
        })
    }

    @Test @MainActor func migrationStagingHonorsAcceptedLossIDsForUnvalidatedSkill() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let root = try makeMigrationTemporaryDirectory("invalid-staging-root")
        let workspace = try makeMigrationTemporaryDirectory("invalid-staging-workspace")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspace)
        }
        let stager = SkillWorkspaceResourceStager(
            externalTarget: { _, workspaceRoot in
                SkillExternalStageTarget(
                    workspaceRoot: workspaceRoot,
                    executionRoot: "/workspace",
                    publish: { _, _, _ in }
                )
            },
            pathMappingProvider: { _ in nil }
        )
        let center = SkillsCenter(
            environment: environment, installationRoot: root, resourceStager: stager
        )
        let text = try await center.createSkill(.init(
            name: "Invalid Loss Text", description: "Text-only installed guide",
            instructions: "Read this text guide only."
        ))
        let fixture = try PackageFixture.make(
            id: "migration-invalid-stage",
            capabilities: ["execution.remote"], tools: ["exec.shell"],
            scriptRuntime: .remote,
            runtime: .init(os: ["linux"], architectures: ["arm64"]),
            scripts: ["scripts/run.sh": "echo ok\n"]
        )
        defer { fixture.clean() }
        let row = try await installFixture(fixture, in: root, environment: environment)
        let skillURL = root.appendingPathComponent(row.id).appendingPathComponent("SKILL.md")
        let existing = try String(contentsOf: skillURL, encoding: .utf8)
        try Data((existing + "\nStale installed copy.\n").utf8)
            .write(to: skillURL, options: .atomic)

        let toolEnvironment = ToolEnvironment(
            id: "env-migrate", writableLayerURL: workspace,
            layerURLs: [], variables: [:]
        )
        let context = SkillResourceContext(
            environmentID: "env-migrate", workspaceRootURL: workspace,
            cancellation: CancellationToken()
        )
        let target = SkillRuntimeTarget.linuxGuest(
            environmentID: "env-migrate", architecture: "arm64", distribution: "debian"
        )

        let notAccepted = await center.stageMigrationSkillResources(
            migrationID: UUID(), target: target,
            toolEnvironment: toolEnvironment, resourceContext: context
        )
        #expect(notAccepted.failureReason == nil)
        #expect(notAccepted.entries.first { $0.skillID == text.id }?.state == .staged)
        let refused = try #require(notAccepted.entries.first { $0.skillID == row.id })
        #expect(refused.state == .unavailable)
        #expect(refused.reason == SkillMigrationStagingReason.invalidPinnedPackage)
        #expect(notAccepted.unavailableCount == 1)

        let accepted = await center.stageMigrationSkillResources(
            migrationID: UUID(), target: target,
            toolEnvironment: toolEnvironment, resourceContext: context,
            acceptedLossIDs: [row.id]
        )
        #expect(accepted.failureReason == nil)
        let skipped = try #require(accepted.entries.first { $0.skillID == row.id })
        #expect(skipped.state == .skipped,
                "accepted unverifiable bytes are skipped, never staged or executed")
        #expect(skipped.reason == SkillMigrationStagingReason.acceptedUnvalidatedPackageLoss)
        #expect(skipped.guestRoot == nil)
        #expect(accepted.unavailableCount == 0)
        #expect(accepted.skillDigests[row.id] == row.rewrittenDigest)

        // A stale/wholly different acceptance does not match this id: the
        // unverifiable package still blocks instead of being silently skipped.
        let wrongAcceptance = await center.stageMigrationSkillResources(
            migrationID: UUID(), target: target,
            toolEnvironment: toolEnvironment, resourceContext: context,
            acceptedLossIDs: ["some-other-skill"]
        )
        #expect(wrongAcceptance.unavailableCount == 1)
        #expect(wrongAcceptance.entries.first { $0.skillID == row.id }?.state == .unavailable)

        // Even when a caller supplies the id, a REQUIRED invalid Skill cannot
        // be silently accepted during staging.
        let required = await center.stageMigrationSkillResources(
            migrationID: UUID(), target: target,
            toolEnvironment: toolEnvironment, resourceContext: context,
            acceptedLossIDs: [row.id], requiredSkillIDs: [row.id]
        )
        #expect(required.unavailableCount == 1)
        #expect(required.entries.first { $0.skillID == row.id }?.state == .unavailable)
    }

    @Test @MainActor func migrationStagingStagesCompatiblePinsAndReleaseIsOwnershipScoped() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let root = try makeMigrationTemporaryDirectory("staging-center")
        let workspace = try makeMigrationTemporaryDirectory("staging-workspace")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: workspace)
        }
        let publishProbe = StagePublishProbe()
        let stager = SkillWorkspaceResourceStager(
            externalTarget: { _, workspaceRoot in
                SkillExternalStageTarget(
                    workspaceRoot: workspaceRoot,
                    executionRoot: "/workspace",
                    publish: { _, bundle, _ in await publishProbe.record(bundle) }
                )
            },
            pathMappingProvider: { _ in nil }
        )
        let center = SkillsCenter(
            environment: environment, installationRoot: root, resourceStager: stager
        )
        let text = try await center.createSkill(.init(
            name: "Migration Staged Text", description: "Text-only installed guide",
            instructions: "Read this text guide only."
        ))
        let installedRows = try await environment.skillStore.all()
        let textRow = try #require(installedRows.first { $0.id == text.id })

        let externalFixture = try PackageFixture.make(
            id: "migration-staging-external",
            capabilities: ["execution.remote"], tools: ["exec.shell"],
            scriptRuntime: .remote,
            runtime: .init(os: ["linux"], architectures: ["arm64"]),
            scripts: ["scripts/run.sh": "echo ok\n"]
        )
        defer { externalFixture.clean() }
        let externalRow = try await installFixture(
            externalFixture, in: root, environment: environment
        )

        let migrationID = UUID()
        let toolEnvironment = ToolEnvironment(
            id: "env-migrate", writableLayerURL: workspace,
            layerURLs: [], variables: [:]
        )
        let context = SkillResourceContext(
            environmentID: "env-migrate", workspaceRootURL: workspace,
            cancellation: CancellationToken()
        )
        let staging = await center.stageMigrationSkillResources(
            migrationID: migrationID,
            target: .macBridge(environmentID: "env-migrate", architecture: "arm64"),
            toolEnvironment: toolEnvironment,
            resourceContext: context
        )
        #expect(staging.migrationID == migrationID)
        #expect(staging.failureReason == nil)
        #expect(staging.stagedCount == 1)
        #expect(staging.skillDigests[textRow.id] == textRow.rewrittenDigest)
        #expect(staging.skillDigests[externalRow.id] == externalRow.rewrittenDigest)
        #expect(staging.entries.first { $0.skillID == text.id }?.state == .staged)
        #expect(staging.entries.first { $0.skillID == text.id }?.guestRoot
            == "/workspace/.floe/skills/\(textRow.id)@\(textRow.rewrittenDigest)")
        let skipped = try #require(staging.entries.first { $0.skillID == externalRow.id })
        #expect(skipped.state == .skipped)
        #expect(skipped.guestRoot == nil)
        let publishCount = await publishProbe.publishedCount()
        #expect(publishCount == 1, "only the compatible pin reaches the external publish seam")

        // The migration-owned pin lives in `.run-snapshots/<migrationID>` with
        // a marker; release removes ONLY that tree and preserves the staged
        // workspace bundle. A real run-shaped snapshot without the marker is
        // never touched.
        let migrationSnapshotRoot = root.appendingPathComponent(
            ".run-snapshots/\(migrationID.uuidString)", isDirectory: true
        )
        #expect(FileManager.default.fileExists(atPath: migrationSnapshotRoot.path))
        let stagedWorkspaceRoot = workspace.appendingPathComponent(
            ".floe/skills/\(textRow.id)@\(textRow.rewrittenDigest)", isDirectory: true
        )
        #expect(FileManager.default.fileExists(atPath: stagedWorkspaceRoot.path))

        let realRunID = UUID()
        let realRunRoot = root.appendingPathComponent(
            ".run-snapshots/\(realRunID.uuidString)/real-run-skill", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: realRunRoot, withIntermediateDirectories: true
        )
        try Data("real run bytes".utf8).write(
            to: realRunRoot.appendingPathComponent("SKILL.md"), options: .atomic
        )

        #expect(center.releaseMigrationResources(migrationID: migrationID) == .released)
        #expect(!FileManager.default.fileExists(atPath: migrationSnapshotRoot.path))
        #expect(FileManager.default.fileExists(atPath: stagedWorkspaceRoot.path),
                "releasing the preparation snapshot never removes the target's staged bundle")
        #expect(center.releaseMigrationResources(migrationID: realRunID) == .notOwned)
        #expect(FileManager.default.fileExists(atPath: realRunRoot.path),
                "a real run snapshot without the migration marker is preserved")
        #expect(center.releaseMigrationResources(migrationID: UUID()) == .absent)

        // Staging must refuse to adopt that same real-run tree as a migration
        // preparation snapshot, leaving its bytes untouched.
        let conflict = await center.stageMigrationSkillResources(
            migrationID: realRunID,
            target: .macBridge(environmentID: "env-migrate", architecture: "arm64"),
            toolEnvironment: toolEnvironment,
            resourceContext: context
        )
        #expect(conflict.failureReason == SkillMigrationStagingReason.snapshotConflict)
        #expect(conflict.entries.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: realRunRoot.appendingPathComponent("SKILL.md").path
        ))

        let mismatch = await center.stageMigrationSkillResources(
            migrationID: UUID(),
            target: .macBridge(environmentID: "env-migrate", architecture: "arm64"),
            toolEnvironment: ToolEnvironment(
                id: "other-environment", writableLayerURL: workspace,
                layerURLs: [], variables: [:]
            ),
            resourceContext: context
        )
        #expect(mismatch.failureReason == SkillMigrationStagingReason.environmentMismatch)
        #expect(mismatch.entries.isEmpty)
    }
}
#endif

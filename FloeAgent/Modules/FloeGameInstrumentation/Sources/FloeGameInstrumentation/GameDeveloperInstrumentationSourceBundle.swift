// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

struct GameDeveloperBundleTemplatePin: Encodable, Sendable, Equatable {
    let id: String
    let resource: String
    let sdkPath: String
    let sha256: String
    let bytes: Int
}

extension GameDeveloperInstrumentationTemplates {
    var templatePins: [GameDeveloperBundleTemplatePin] {
        all.map { .init(id: $0.id, resource: $0.resource, sdkPath: $0.sdkPath,
                        sha256: $0.sha256, bytes: $0.bytes) }
    }
}

enum GameDeveloperInstrumentationSourceBundleBuilder {
    static func build(plan: GameDeveloperProjectInstrumentationPlan,
                      templates: any GameDeveloperInstrumentationBundleTemplates,
                      limits: GameDeveloperInstrumentationLimits) throws -> GameDeveloperInstrumentationSourceBundle {
        let engineDirectory = "FloeDeveloper/Sources/" + plan.engine.rawValue
        var entries: [BundleEntry] = []
        entries.append(BundleEntry(path: "FloeDeveloper/README.txt", role: .readme, data: Data()))
        entries.append(BundleEntry(path: "FloeDeveloper/INSTALL.txt", role: .installInstructions, data: Data()))
        entries.append(BundleEntry(path: "FloeDeveloper/LICENSE", role: .license, data: templates.license.data))
        entries.append(BundleEntry(path: "FloeDeveloper/NOTICE.md", role: .notice, data: templates.notice))

        let helperFiles = plan.files.filter { $0.kind == .helperSource || $0.kind == .generatedFile }
            .sorted { $0.path.value < $1.path.value }
        var installed: [ProvenanceDocument.InstalledFile] = []
        for file in helperFiles {
            let bundlePath = engineDirectory + "/" + file.path.value
            entries.append(BundleEntry(path: bundlePath,
                                       role: file.kind == .generatedFile ? .generatedFile : .helperSource,
                                       data: file.outputData))
            installed.append(.init(projectPath: file.path.value,
                                   sourceBundlePath: bundlePath,
                                   templateResource: file.templateResource,
                                   templateSHA256: file.templateSHA256,
                                   outputSHA256: file.outputSHA256,
                                   bytes: file.outputBytes,
                                   action: file.action.rawValue))
        }

        let provenance = ProvenanceDocument(
            schemaVersion: GameDeveloperInstrumentationConstants.schemaVersion,
            package: GameDeveloperInstrumentationConstants.packageName,
            packageVersion: GameDeveloperInstrumentationConstants.version,
            engine: plan.engine,
            gameRoot: plan.gameRootPath,
            projectID: plan.context.projectID,
            revision: plan.context.savedRevision,
            catalogVersion: templates.catalogVersion,
            frozenSourceRevision: templates.frozenSourceRevision,
            license: GameDeveloperInstrumentationConstants.licenseIdentifier,
            licensePath: "FloeDeveloper/LICENSE",
            noticePath: "FloeDeveloper/NOTICE.md",
            hostGate: plan.dormancy.hostObjectName,
            dormancy: .init(gated: plan.dormancy.gated,
                            productionBehavior: plan.dormancy.productionBehavior,
                            productionBehaviorZhHans: plan.dormancy.productionBehaviorZhHans),
            templatePinsSHA256: templates.pinsSHA256,
            templates: templates.templatePins.map {
                .init(id: $0.id, resource: $0.resource, sdkPath: $0.sdkPath,
                      sha256: $0.sha256, bytes: $0.bytes)
            },
            installedFiles: installed,
            projectPatches: plan.files.filter { $0.kind == .projectPatch }.map {
                .init(path: $0.path.value, action: $0.action.rawValue,
                      outputSHA256: $0.outputSHA256, bytes: $0.outputBytes)
            },
            autoload: plan.autoload.map {
                .init(section: $0.section, key: $0.key, value: $0.value, line: $0.line,
                      lineEnding: $0.lineEnding, hadBOM: $0.hadBOM, changed: $0.changed)
            },
            requiresRebuild: plan.requiresRebuild,
            noProprietaryAssets: true,
            sourceAttachment: "Attach FloeDeveloper/ or a ZIP of it to the playable distribution or its immediately accompanying source bundle.")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let provenanceData = try encoder.encode(provenance)
        entries.append(BundleEntry(path: "FloeDeveloper/PROVENANCE.json", role: .provenance, data: provenanceData))

        let readme = readmeText(plan: plan)
        let install = installText(plan: plan)
        entries[0] = BundleEntry(path: "FloeDeveloper/README.txt", role: .readme, data: Data(readme.utf8))
        entries[1] = BundleEntry(path: "FloeDeveloper/INSTALL.txt", role: .installInstructions, data: Data(install.utf8))

        var files: [GameDeveloperInstrumentationSourceBundle.File] = []
        var total = 0
        for entry in entries {
            guard safe(entry.path) else {
                throw GameDeveloperInstrumentationError.planMismatch("unsafe bundle path \(entry.path)")
            }
            total += entry.data.count
            guard total <= limits.maximumSourceBundleBytes else {
                throw GameDeveloperInstrumentationError.limitExceeded("source bundle")
            }
            files.append(.init(path: entry.path, role: entry.role,
                               sha256: GameDigest.sha256(entry.data),
                               bytes: entry.data.count, data: entry.data))
        }
        files.sort { $0.path < $1.path }
        var aggregate = Data()
        for file in files {
            aggregate.append(contentsOf: file.path.utf8)
            aggregate.append(0)
            aggregate.append(contentsOf: file.sha256.utf8)
        }
        return .init(schemaVersion: GameDeveloperInstrumentationConstants.schemaVersion,
                     engine: plan.engine,
                     licenseIdentifier: GameDeveloperInstrumentationConstants.licenseIdentifier,
                     sourceRevision: templates.frozenSourceRevision,
                     files: files,
                     manifestSHA256: GameDigest.sha256(provenanceData),
                     aggregateSHA256: GameDigest.sha256(aggregate))
    }

    static func buildRecord(plan: GameDeveloperProjectInstrumentationPlan,
                            receipt: GameDeveloperInstrumentationReceipt,
                            bundle: GameDeveloperInstrumentationSourceBundle) throws -> Data {
        guard plan.planID == receipt.planID, plan.engine == receipt.engine,
              bundle.engine == plan.engine else {
            throw GameDeveloperInstrumentationError.planMismatch("plan/receipt/bundle identity")
        }
        let document = BuildRecordDocument(
            schemaVersion: GameDeveloperInstrumentationConstants.schemaVersion,
            engine: plan.engine,
            planID: plan.planID,
            projectID: plan.context.projectID,
            owner: plan.context.owner,
            revision: receipt.revision,
            gameRoot: plan.gameRootPath,
            catalogVersion: plan.catalogVersion,
            frozenSourceRevision: GameDeveloperInstrumentationConstants.frozenSourceRevision,
            helperFiles: plan.files.filter { $0.kind == .helperSource }.map {
                .init(path: $0.path.value,
                      sourceBundlePath: "FloeDeveloper/Sources/" + plan.engine.rawValue + "/" + $0.path.value,
                      sha256: $0.outputSHA256,
                      templateSHA256: $0.templateSHA256)
            },
            sourceBundle: .init(manifestSHA256: bundle.manifestSHA256,
                                aggregateSHA256: bundle.aggregateSHA256,
                                root: "FloeDeveloper/"),
            license: bundle.licenseIdentifier,
            hostGate: GameDeveloperInstrumentationConstants.hostObjectName,
            requiresRebuild: plan.requiresRebuild
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    private static func readmeText(plan: GameDeveloperProjectInstrumentationPlan) -> String {
        """
        Floe developer instrumentation source bundle

        Engine: \(plan.displayName)
        Game root: \(plan.gameRootPath.isEmpty ? "<project root>" : plan.gameRootPath)
        License: \(GameDeveloperInstrumentationConstants.licenseIdentifier)

        This directory is the source form of the Floe developer helper files
        installed into the game project. Keep it with the playable distribution
        or its immediately accompanying source bundle. The complete license is
        FloeDeveloper/LICENSE; the notice is FloeDeveloper/NOTICE.md.

        The helpers are development instrumentation. They are inert unless the
        Floe host injects window.FloeDeveloper for a Floe-owned development
        session; a normal exported game has no developer menu or cheat control.

        The surrounding game project, imported assets, native libraries and
        engine binaries remain under their own licenses.
        """
    }

    private static func installText(plan: GameDeveloperProjectInstrumentationPlan) -> String {
        var lines = [
            "Floe developer instrumentation installation",
            "",
            "Engine: \(plan.displayName)",
            "Game root: \(plan.gameRootPath.isEmpty ? "<project root>" : plan.gameRootPath)",
            "Requires rebuild: \(plan.requiresRebuild ? "yes" : "no")",
            "",
            "Helper files:"
        ]
        for file in plan.files where file.kind == .helperSource || file.kind == .generatedFile {
            lines.append("- \(file.path.value) (sha256 \(file.outputSHA256))")
        }
        if let autoload = plan.autoload {
            lines.append("")
            lines.append("Godot autoload registration (the user's project.godot is not included):")
            lines.append("[\(autoload.section)]")
            lines.append(autoload.line)
            lines.append("")
            lines.append("Existing autoloads and every other project.godot line are preserved.")
        }
        switch plan.engine {
        case .gdevelop:
            lines.append("")
            lines.append("GDevelop: game.json and every imported game byte are unchanged. The")
            lines.append("reviewed exporter or Web run preparer stamps floe-developer.js into a")
            lines.append("private playable copy; an already-exported game needs no re-export.")
        case .cocosCreator:
            lines.append("")
            lines.append("Cocos Creator 3.8: the selected scene was patched by inserting one child")
            lines.append("id and one node/component pair. Unknown fields and other components are")
            lines.append("retained. Roll back through the existing saved revision history if needed.")
        case .godot:
            lines.append("")
            lines.append("Godot: remove the FloeDeveloper autoload line to detach the helper. Apart")
            lines.append("from that insertion and, when needed, a final newline, every other")
            lines.append("project.godot byte is retained.")
        default:
            lines.append("")
            lines.append("To remove the helper, delete only the listed helper files. No imported")
            lines.append("source file is overwritten.")
        }
        lines.append("")
        lines.append("No imported helper or game source file is overwritten by this installer.")
        return lines.joined(separator: "\n")
    }

    private static func safe(_ path: String) -> Bool {
        let hasControl = path.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.contains(":"), !hasControl else {
            return false
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

private struct ProvenanceDocument: Encodable {
    struct Template: Encodable {
        let id: String
        let resource: String
        let sdkPath: String
        let sha256: String
        let bytes: Int
    }
    struct InstalledFile: Encodable {
        let projectPath: String
        let sourceBundlePath: String
        let templateResource: String
        let templateSHA256: String
        let outputSHA256: String
        let bytes: Int
        let action: String
    }
    struct Patch: Encodable {
        let path: String
        let action: String
        let outputSHA256: String
        let bytes: Int
    }
    struct Autoload: Encodable {
        let section: String
        let key: String
        let value: String
        let line: String
        let lineEnding: String
        let hadBOM: Bool
        let changed: Bool
    }
    struct Dormancy: Encodable {
        let gated: Bool
        let productionBehavior: String
        let productionBehaviorZhHans: String
    }

    let schemaVersion: Int
    let package: String
    let packageVersion: String
    let engine: GameEngineID
    let gameRoot: String
    let projectID: UUID
    let revision: String
    let catalogVersion: String
    let frozenSourceRevision: String
    let license: String
    let licensePath: String
    let noticePath: String
    let hostGate: String
    let dormancy: Dormancy
    let templatePinsSHA256: String
    let templates: [Template]
    let installedFiles: [InstalledFile]
    let projectPatches: [Patch]
    let autoload: Autoload?
    let requiresRebuild: Bool
    let noProprietaryAssets: Bool
    let sourceAttachment: String
}

private struct BuildRecordDocument: Encodable {
    struct HelperFile: Encodable {
        let path: String
        let sourceBundlePath: String
        let sha256: String
        let templateSHA256: String
    }
    struct SourceBundle: Encodable {
        let manifestSHA256: String
        let aggregateSHA256: String
        let root: String
    }

    let schemaVersion: Int
    let engine: GameEngineID
    let planID: UUID
    let projectID: UUID
    let owner: GameProjectOwner
    let revision: String
    let gameRoot: String
    let catalogVersion: String
    let frozenSourceRevision: String
    let helperFiles: [HelperFile]
    let sourceBundle: SourceBundle
    let license: String
    let hostGate: String
    let requiresRebuild: Bool
}

private struct BundleEntry {
    let path: String
    let role: GameDeveloperInstrumentationSourceBundle.Role
    let data: Data
}

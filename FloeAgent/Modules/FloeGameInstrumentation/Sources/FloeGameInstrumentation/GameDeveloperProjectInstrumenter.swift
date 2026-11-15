// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameAuthoring
import FloeGameDeveloperCore

/// Installs the reviewed project-side developer hooks (Unity WebGL, Godot Web,
/// GDevelop and Cocos Creator 3.8) into an existing owned project revision. It
/// composes the existing repository, context host, catalog and immutable CAS;
/// it never builds or runs an engine and never overwrites an existing helper
/// file. GDevelop source JSON is never rewritten; its bridge file is provenance
/// for the private exported copy. The only non-helper edits are a byte-preserving
/// Godot autoload line insertion and a byte-preserving Cocos scene insertion.
public actor GameDeveloperProjectInstrumenter {
    public let repository: FileGameProjectRepository
    public let contexts: any GameAuthoringContextHost
    public let templates: GameDeveloperInstrumentationTemplates
    public let limits: GameDeveloperInstrumentationLimits
    private var cachedHookTemplates: GameDeveloperProjectHookTemplates?

    public init(repository: FileGameProjectRepository,
                contexts: any GameAuthoringContextHost,
                templates: GameDeveloperInstrumentationTemplates? = nil,
                hookTemplates: GameDeveloperProjectHookTemplates? = nil,
                limits: GameDeveloperInstrumentationLimits? = nil) throws {
        self.repository = repository
        self.contexts = contexts
        if let templates {
            self.templates = templates
        } else {
            self.templates = try GameDeveloperInstrumentationTemplates()
        }
        if let limits {
            self.limits = limits
        } else {
            self.limits = try GameDeveloperInstrumentationLimits()
        }
        self.cachedHookTemplates = hookTemplates
    }

    /// Preview exactly which files would change. No repository write occurs.
    /// `scene` is required only when a Cocos Creator project has several scenes
    /// and no actual startScene metadata; the UI/AI must pass the user's choice.
    public func plan(context: GameProjectContext,
                     engine: GameEngineID,
                     gameRoot: GameRelativePath? = nil,
                     scene sceneID: String? = nil) async throws -> GameDeveloperProjectInstrumentationPlan {
        try Task.checkCancellation()
        let descriptor = try self.descriptorForPlan(engine)
        let dormancy = try self.dormancy(for: engine)
        let current = try await contexts.currentContext(for: context)
        guard current == context else {
            throw GameDeveloperInstrumentationError.staleContext
        }
        let project = try await repository.open(context.projectID, owner: context.owner)
        guard project.projectID == context.projectID,
              project.owner == context.owner,
              project.revision == context.savedRevision else {
            throw GameDeveloperInstrumentationError.staleContext
        }
        if let gameRoot, !project.directories.contains(gameRoot) {
            throw GameDeveloperInstrumentationError.rootNotSelected(gameRoot.value)
        }

        let files: [GameDeveloperProjectInstrumentationFile]
        let autoload: GameDeveloperGodotAutoloadPlan?
        let engineVersion: String
        var selectedScene: GameDeveloperInstrumentationScene? = nil
        var exportHandling: GameDeveloperInstrumentationExportHandling = .notApplicable
        var planDiagnostics: [GameDeveloperInstrumentationDiagnostic]
        switch engine {
        case .unity:
            let result = try await UnityProjectInstrumentation.inspect(
                project: project, repository: repository, revision: context.savedRevision,
                root: gameRoot, templates: templates, limits: limits)
            files = result.files
            autoload = nil
            engineVersion = result.engineVersion
            planDiagnostics = diagnostics(project: project, engine: engine,
                                          gameRoot: gameRoot, files: files,
                                          autoload: nil, descriptor: descriptor,
                                          changed: files.contains { $0.changed })
        case .godot:
            let result = try await GodotProjectInstrumentation.inspect(
                project: project, repository: repository, revision: context.savedRevision,
                root: gameRoot, templates: templates, limits: limits)
            files = result.files
            autoload = result.autoload
            engineVersion = result.engineVersion
            planDiagnostics = diagnostics(project: project, engine: engine,
                                          gameRoot: gameRoot, files: files,
                                          autoload: result.autoload, descriptor: descriptor,
                                          changed: files.contains { $0.changed })
        case .gdevelop:
            let result = try await GDevelopProjectInstrumentation.inspect(
                project: project, repository: repository, revision: context.savedRevision,
                root: gameRoot, templates: try hookTemplates(), limits: limits)
            files = result.files
            autoload = nil
            engineVersion = result.engineVersion
            exportHandling = result.exportHandling
            planDiagnostics = result.diagnostics
        case .cocosCreator:
            let result = try await CocosProjectInstrumentation.inspect(
                project: project, repository: repository, revision: context.savedRevision,
                root: gameRoot, requestedScene: sceneID, templates: try hookTemplates(),
                limits: limits)
            files = result.files
            autoload = nil
            engineVersion = result.engineVersion
            selectedScene = result.scene
            planDiagnostics = result.diagnostics
        default:
            throw GameDeveloperInstrumentationError.unsupportedEngine(engine)
        }
        return .init(
            schemaVersion: GameDeveloperInstrumentationConstants.schemaVersion,
            planID: GameDeveloperInstrumentationPlanIdentity.make(
                engine: engine, context: context, gameRoot: gameRoot, files: files,
                scene: selectedScene, exportHandling: exportHandling, autoload: autoload),
            engine: engine,
            catalogVersion: GameDeveloperEngineCatalog.version,
            descriptor: descriptor,
            context: context,
            gameRoot: gameRoot,
            gameRootPath: gameRoot?.value ?? "",
            engineVersion: engineVersion,
            files: files,
            autoload: autoload,
            scene: selectedScene,
            exportHandling: exportHandling,
            diagnostics: planDiagnostics,
            dormancy: dormancy)
    }

    /// Explicit scene choices from real project metadata. Engines without
    /// scenes return an empty list rather than an invented placeholder.
    public func scenes(context: GameProjectContext,
                       engine: GameEngineID,
                       gameRoot: GameRelativePath? = nil) async throws
        -> [GameDeveloperInstrumentationSceneChoice] {
        try Task.checkCancellation()
        guard engine == .cocosCreator else { return [] }
        let current = try await contexts.currentContext(for: context)
        guard current == context else { throw GameDeveloperInstrumentationError.staleContext }
        let project = try await repository.open(context.projectID, owner: context.owner)
        guard project.projectID == context.projectID,
              project.owner == context.owner,
              project.revision == context.savedRevision else {
            throw GameDeveloperInstrumentationError.staleContext
        }
        return try await CocosProjectInstrumentation.scenes(
            project: project, repository: repository, revision: context.savedRevision,
            root: gameRoot, limits: limits)
    }

    /// Apply a previously previewed plan through the existing repository CAS.
    public func apply(_ plan: GameDeveloperProjectInstrumentationPlan) async throws -> GameDeveloperInstrumentationReceipt {
        try Task.checkCancellation()
        try validatePlanIntegrity(plan)
        let current = try await contexts.currentContext(for: plan.context)
        guard current == plan.context else {
            throw GameDeveloperInstrumentationError.staleContext
        }
        let project = try await repository.open(plan.context.projectID, owner: plan.context.owner)
        guard project.projectID == plan.context.projectID,
              project.owner == plan.context.owner,
              project.revision == plan.context.savedRevision else {
            throw GameDeveloperInstrumentationError.staleContext
        }
        if let gameRoot = plan.gameRoot, !project.directories.contains(gameRoot) {
            throw GameDeveloperInstrumentationError.rootNotSelected(gameRoot.value)
        }
        let byPath = Dictionary(project.files.map { ($0.path, $0) },
                                uniquingKeysWith: { first, _ in first })
        var changes: [GameFileChange] = []
        for file in plan.files {
            try Task.checkCancellation()
            let existing = byPath[file.path]
            guard existing?.sha256 == file.existingSHA256 else {
                throw GameDeveloperInstrumentationError.stalePlan(file.path.value)
            }
            switch file.kind {
            case .helperSource:
                let template = try self.template(for: file, plan: plan)
                guard file.templateResource == template.resource,
                      file.templateSHA256 == template.sha256,
                      file.outputSHA256 == template.sha256,
                      file.outputData == template.data,
                      file.outputBytes == template.bytes else {
                    throw GameDeveloperInstrumentationError.templateDrift(file.path.value)
                }
                if existing == nil {
                    guard file.action == .create else {
                        throw GameDeveloperInstrumentationError.planMismatch(file.path.value)
                    }
                    changes.append(.write(file.path, template.data))
                } else {
                    guard file.action == .unchanged,
                          existing?.sha256 == file.outputSHA256 else {
                        throw GameDeveloperInstrumentationError.planMismatch(file.path.value)
                    }
                }
            case .generatedFile:
                guard file.outputBytes == file.outputData.count,
                      GameDigest.sha256(file.outputData) == file.outputSHA256 else {
                    throw GameDeveloperInstrumentationError.planMismatch(file.path.value)
                }
                if existing == nil {
                    guard file.action == .create else {
                        throw GameDeveloperInstrumentationError.planMismatch(file.path.value)
                    }
                    changes.append(.write(file.path, file.outputData))
                } else {
                    guard file.action == .unchanged,
                          existing?.sha256 == file.outputSHA256 else {
                        throw GameDeveloperInstrumentationError.planMismatch(file.path.value)
                    }
                }
            case .projectPatch:
                guard let existing else {
                    throw GameDeveloperInstrumentationError.planMismatch(file.path.value)
                }
                let needsPatch = existing.sha256 != file.outputSHA256
                guard file.action == (needsPatch ? .patch : .unchanged) else {
                    throw GameDeveloperInstrumentationError.planMismatch(file.path.value)
                }
                if needsPatch {
                    changes.append(.write(file.path, file.outputData))
                }
            }
        }

        if changes.isEmpty {
            return .init(
                schemaVersion: GameDeveloperInstrumentationConstants.schemaVersion,
                planID: plan.planID,
                engine: plan.engine,
                project: project,
                context: current,
                previousRevision: project.revision,
                revision: project.revision,
                changedFiles: [],
                unchangedFiles: plan.unchangedFiles,
                diagnostics: plan.diagnostics)
        }

        let committed: GameStoredProject
        do {
            committed = try await repository.commit(
                plan.context.projectID,
                owner: plan.context.owner,
                expectedRevision: plan.context.savedRevision,
                changes: changes,
                title: "Add Floe developer hooks (\(plan.displayName))")
        } catch let error as GameProjectError {
            if case .conflict(_, _) = error {
                throw GameDeveloperInstrumentationError.stalePlan("repository revision")
            }
            throw error
        }

        let committedByPath = Dictionary(committed.files.map { ($0.path, $0) },
                                         uniquingKeysWith: { first, _ in first })
        let targets = Set(plan.files.map(\.path))
        for file in plan.files {
            guard committedByPath[file.path]?.sha256 == file.outputSHA256,
                  committedByPath[file.path]?.bytes == file.outputBytes else {
                throw GameDeveloperInstrumentationError.postCommitVerificationFailed(file.path.value)
            }
        }
        for original in project.files where !targets.contains(original.path) {
            guard committedByPath[original.path]?.sha256 == original.sha256,
                  committedByPath[original.path]?.bytes == original.bytes else {
                throw GameDeveloperInstrumentationError.postCommitVerificationFailed(
                    "preservation of \(original.path.value)")
            }
        }
        for directory in project.directories where !committed.directories.contains(directory) {
            throw GameDeveloperInstrumentationError.postCommitVerificationFailed(
                "preservation of directory \(directory.value)")
        }
        let created = plan.files.filter { $0.action == .create }.count
        guard committed.files.count == project.files.count + created else {
            throw GameDeveloperInstrumentationError.postCommitVerificationFailed(
                "unexpected file count")
        }

        let updated: GameProjectContext
        do {
            updated = try await contexts.contextAfterCommit(committed, previous: current)
        } catch {
            throw GameDeveloperInstrumentationError.contextHandoffFailed(String(describing: error))
        }
        guard updated.projectID == committed.projectID,
              updated.owner == committed.owner,
              updated.savedRevision == committed.revision,
              updated.environmentID == current.environmentID else {
            throw GameDeveloperInstrumentationError.contextHandoffFailed("identity/revision")
        }
        return .init(
            schemaVersion: GameDeveloperInstrumentationConstants.schemaVersion,
            planID: plan.planID,
            engine: plan.engine,
            project: committed,
            context: updated,
            previousRevision: project.revision,
            revision: committed.revision,
            changedFiles: plan.changedFiles,
            unchangedFiles: plan.unchangedFiles,
            diagnostics: plan.diagnostics)
    }

    /// Exact MPL source + license/notice/provenance bundle for a build or
    /// distribution. It is pure and does not write anywhere.
    public func bundleSourceFiles(_ plan: GameDeveloperProjectInstrumentationPlan) throws -> GameDeveloperInstrumentationSourceBundle {
        try validatePlanIntegrity(plan)
        let bundleTemplates: any GameDeveloperInstrumentationBundleTemplates
        switch plan.engine {
        case .gdevelop, .cocosCreator:
            bundleTemplates = try hookTemplates()
        default:
            bundleTemplates = templates
        }
        return try GameDeveloperInstrumentationSourceBundleBuilder.build(
            plan: plan, templates: bundleTemplates, limits: limits)
    }

    /// Small JSON record to merge into the existing build provenance. The
    /// canonical build source digest still covers the repository revision.
    public func buildRecord(plan: GameDeveloperProjectInstrumentationPlan,
                            receipt: GameDeveloperInstrumentationReceipt,
                            bundle: GameDeveloperInstrumentationSourceBundle) throws -> Data {
        try validatePlanIntegrity(plan)
        for file in plan.files where file.kind == .helperSource {
            let expected = "FloeDeveloper/Sources/" + plan.engine.rawValue + "/" + file.path.value
            guard bundle.files.contains(where: {
                $0.role == .helperSource && $0.path == expected
                    && $0.sha256 == file.outputSHA256
            }) else {
                throw GameDeveloperInstrumentationError.planMismatch(
                    "source bundle is missing \(file.path.value)")
            }
        }
        return try GameDeveloperInstrumentationSourceBundleBuilder.buildRecord(
            plan: plan, receipt: receipt, bundle: bundle)
    }

    public func audit() throws -> GameDeveloperInstrumentationAudit {
        try GameDeveloperInstrumentationAudit.current()
    }

    // MARK: - Engine dispatch

    private func descriptorForPlan(_ engine: GameEngineID) throws -> GameDeveloperEngineDescriptor {
        if engine == .gdevelop || engine == .cocosCreator {
            let descriptor: GameDeveloperEngineDescriptor
            do {
                descriptor = try GameDeveloperEngineCatalog.descriptor(for: engine)
            } catch {
                throw GameDeveloperInstrumentationError.catalogMismatch(engine, "descriptor lookup failed")
            }
            guard descriptor.engine == engine, descriptor.hookID == engine.rawValue,
                  descriptor.support == .hostBuildHook,
                  descriptor.instrumentation.requiresRebuild else {
                throw GameDeveloperInstrumentationError.catalogMismatch(
                    engine, "support/route/rebuild classification")
            }
            return descriptor
        }
        return try descriptor(for: engine)
    }

    private func dormancy(for engine: GameEngineID) throws -> GameDeveloperInstrumentationDormancy {
        switch engine {
        case .gdevelop, .cocosCreator:
            return try hookTemplates().dormancy(for: engine)
        default:
            return try templates.dormancy(for: engine)
        }
    }

    private func hookTemplates() throws -> GameDeveloperProjectHookTemplates {
        if let cachedHookTemplates { return cachedHookTemplates }
        let value = try GameDeveloperProjectHookTemplates()
        cachedHookTemplates = value
        return value
    }

    /// The reviewed template matching one plan file. GDevelop/Cocos use their
    /// own pins; Unity/Godot keep the frozen four-template pins.
    private func template(for file: GameDeveloperProjectInstrumentationFile,
                          plan: GameDeveloperProjectInstrumentationPlan) throws
        -> (resource: String, sha256: String, bytes: Int, data: Data) {
        switch plan.engine {
        case .gdevelop, .cocosCreator:
            let template = try hookTemplates().template(resource: file.templateResource)
            return (template.resource, template.sha256, template.bytes, template.data)
        default:
            let templateID = try helperTemplateID(for: file, plan: plan)
            let template = try templates.template(id: templateID)
            // Legacy plans use catalog Project/ labels; their pinned bundle
            // resources use Templates/. Keep those two identities distinct.
            return (expectedResource(for: file, plan: plan),
                    template.sha256, template.bytes, template.data)
        }
    }

    // MARK: - Validation

    private func descriptor(for engine: GameEngineID) throws -> GameDeveloperEngineDescriptor {
        guard GameDeveloperInstrumentationConstants.supportedEngines.contains(engine) else {
            throw GameDeveloperInstrumentationError.unsupportedEngine(engine)
        }
        let descriptor: GameDeveloperEngineDescriptor
        do {
            descriptor = try GameDeveloperEngineCatalog.descriptor(for: engine)
        } catch {
            throw GameDeveloperInstrumentationError.catalogMismatch(engine, "descriptor lookup failed")
        }
        guard descriptor.engine == engine, descriptor.hookID == engine.rawValue,
              descriptor.support == .hostBuildHook,
              descriptor.instrumentation.requiresRebuild else {
            throw GameDeveloperInstrumentationError.catalogMismatch(
                engine, "support/route/rebuild classification")
        }
        let paths = Set(descriptor.instrumentation.files.map(\.path))
        let resources = Set(descriptor.instrumentation.files.compactMap(\.templateResource))
        switch engine {
        case .unity:
            let expectedPaths: Set<String> = [
                GameDeveloperInstrumentationConstants.unityJSLibraryPath,
                GameDeveloperInstrumentationConstants.unityBridgePath,
                GameDeveloperInstrumentationConstants.unityBehaviourPath
            ]
            let expectedResources: Set<String> = [
                "Project/unity-floe-developer.jslib",
                "Project/unity-floe-developer.cs",
                "Project/unity-floe-developer-behaviour.cs"
            ]
            guard descriptor.instrumentation.files.count == 3,
                  paths == expectedPaths, resources == expectedResources else {
                throw GameDeveloperInstrumentationError.catalogMismatch(engine, "Unity file plan")
            }
        case .godot:
            let expectedPaths: Set<String> = [
                GameDeveloperInstrumentationConstants.godotProjectPath,
                GameDeveloperInstrumentationConstants.godotAutoloadPath
            ]
            guard descriptor.instrumentation.files.count == 2,
                  paths == expectedPaths,
                  resources == Set(["Project/godot-floe-developer.gd"]) else {
                throw GameDeveloperInstrumentationError.catalogMismatch(engine, "Godot file plan")
            }
        default:
            throw GameDeveloperInstrumentationError.unsupportedEngine(engine)
        }
        return descriptor
    }

    private func validatePlanIntegrity(_ plan: GameDeveloperProjectInstrumentationPlan) throws {
        guard plan.schemaVersion == GameDeveloperInstrumentationConstants.schemaVersion else {
            throw GameDeveloperInstrumentationError.planMismatch("schemaVersion")
        }
        let descriptor = try self.descriptorForPlan(plan.engine)
        guard plan.descriptor == descriptor,
              plan.catalogVersion == GameDeveloperEngineCatalog.version else {
            throw GameDeveloperInstrumentationError.catalogMismatch(plan.engine, "changed catalog")
        }
        let dormancy = try self.dormancy(for: plan.engine)
        guard plan.dormancy == dormancy else {
            throw GameDeveloperInstrumentationError.planMismatch("dormancy report")
        }
        switch plan.engine {
        case .gdevelop:
            try GDevelopProjectInstrumentation.validate(plan: plan, templates: try hookTemplates(), limits: limits)
            return
        case .cocosCreator:
            try CocosProjectInstrumentation.validate(plan: plan, templates: try hookTemplates(), limits: limits)
            return
        default:
            break
        }
        try validatePlanFileSet(plan)
        for file in plan.files {
            guard file.outputBytes == file.outputData.count,
                  GameDigest.sha256(file.outputData) == file.outputSHA256 else {
                throw GameDeveloperInstrumentationError.planMismatch("file hash \(file.path.value)")
            }
            switch file.kind {
            case .helperSource:
                let template = try self.template(for: file, plan: plan)
                guard file.templateSHA256 == template.sha256,
                      file.templateResource == expectedResource(for: file, plan: plan),
                      file.outputSHA256 == template.sha256,
                      file.outputBytes == template.bytes,
                      file.outputData == template.data else {
                    throw GameDeveloperInstrumentationError.templateDrift(file.path.value)
                }
            case .generatedFile:
                // New-engine metadata is validated by its dedicated validator.
                break
            case .projectPatch:
                guard plan.engine == .godot, let autoload = plan.autoload,
                      file.templateResource == "inline:project.godot[autoload]",
                      file.templateSHA256 == GameDigest.sha256(Data(autoload.line.utf8)) else {
                    throw GameDeveloperInstrumentationError.planMismatch("project patch")
                }
                let parsed = try GodotProjectFile.parse(file.outputData,
                                                        maximumBytes: limits.maximumMetadataBytes)
                guard parsed.configVersion == GameDeveloperInstrumentationConstants.godotSupportedConfigVersion,
                      parsed.autoloadValue == GameDeveloperInstrumentationConstants.godotAutoloadValue,
                      parsed.lineEnding.rawValue == autoload.lineEnding,
                      parsed.hadBOM == autoload.hadBOM else {
                    throw GameDeveloperInstrumentationError.planMismatch("project patch verification")
                }
            }
        }
    }

    private func validatePlanFileSet(_ plan: GameDeveloperProjectInstrumentationPlan) throws {
        var expected: [String: (kind: GameDeveloperInstrumentationFileKind, resource: String)] = [:]
        switch plan.engine {
        case .unity:
            expected[GameDeveloperInstrumentationConstants.unityJSLibraryPath] =
                (kind: .helperSource, resource: "Project/unity-floe-developer.jslib")
            expected[GameDeveloperInstrumentationConstants.unityBridgePath] =
                (kind: .helperSource, resource: "Project/unity-floe-developer.cs")
            expected[GameDeveloperInstrumentationConstants.unityBehaviourPath] =
                (kind: .helperSource, resource: "Project/unity-floe-developer-behaviour.cs")
        case .godot:
            expected[GameDeveloperInstrumentationConstants.godotProjectPath] =
                (kind: .projectPatch, resource: "inline:project.godot[autoload]")
            expected[GameDeveloperInstrumentationConstants.godotAutoloadPath] =
                (kind: .helperSource, resource: "Project/godot-floe-developer.gd")
        default:
            throw GameDeveloperInstrumentationError.unsupportedEngine(plan.engine)
        }
        guard plan.files.count == expected.count else {
            throw GameDeveloperInstrumentationError.planMismatch("file count")
        }
        let prefix = GameDeveloperInstrumentationPath.prefix(plan.gameRoot)
        var seen = Set<GameRelativePath>()
        for file in plan.files {
            let relative = GameDeveloperInstrumentationPath.relative(file.path, prefix: prefix)
            guard let wanted = expected[relative] else {
                throw GameDeveloperInstrumentationError.planMismatch("unexpected \(file.path.value)")
            }
            guard wanted.kind == file.kind, wanted.resource == file.templateResource,
                  seen.insert(file.path).inserted else {
                throw GameDeveloperInstrumentationError.planMismatch("duplicate \(file.path.value)")
            }
        }
        switch plan.engine {
        case .unity:
            guard plan.autoload == nil else {
                throw GameDeveloperInstrumentationError.planMismatch("Unity autoload")
            }
        case .godot:
            guard let autoload = plan.autoload,
                  autoload.section == "autoload",
                  autoload.key == GameDeveloperInstrumentationConstants.godotAutoloadKey,
                  autoload.value == GameDeveloperInstrumentationConstants.godotAutoloadValue,
                  autoload.line == autoload.key + "=\"" + autoload.value + "\"",
                  autoload.lineEnding == "lf" || autoload.lineEnding == "crlf" else {
                throw GameDeveloperInstrumentationError.planMismatch("Godot autoload plan")
            }
        default:
            break
        }
    }

    private func helperTemplateID(for file: GameDeveloperProjectInstrumentationFile,
                                  plan: GameDeveloperProjectInstrumentationPlan) throws -> String {
        let prefix = GameDeveloperInstrumentationPath.prefix(plan.gameRoot)
        let relative = GameDeveloperInstrumentationPath.relative(file.path, prefix: prefix)
        switch plan.engine {
        case .unity:
            switch relative {
            case GameDeveloperInstrumentationConstants.unityJSLibraryPath: return "unityJSLibrary"
            case GameDeveloperInstrumentationConstants.unityBridgePath: return "unityBridge"
            case GameDeveloperInstrumentationConstants.unityBehaviourPath: return "unityBehaviour"
            default: break
            }
        case .godot:
            if relative == GameDeveloperInstrumentationConstants.godotAutoloadPath {
                return "godotAutoload"
            }
        default:
            break
        }
        throw GameDeveloperInstrumentationError.planMismatch("helper path \(relative)")
    }

    private func expectedResource(for file: GameDeveloperProjectInstrumentationFile,
                                  plan: GameDeveloperProjectInstrumentationPlan) -> String {
        switch file.kind {
        case .helperSource:
            let prefix = GameDeveloperInstrumentationPath.prefix(plan.gameRoot)
            let relative = GameDeveloperInstrumentationPath.relative(file.path, prefix: prefix)
            switch plan.engine {
            case .unity:
                switch relative {
                case GameDeveloperInstrumentationConstants.unityJSLibraryPath:
                    return "Project/unity-floe-developer.jslib"
                case GameDeveloperInstrumentationConstants.unityBridgePath:
                    return "Project/unity-floe-developer.cs"
                case GameDeveloperInstrumentationConstants.unityBehaviourPath:
                    return "Project/unity-floe-developer-behaviour.cs"
                default: return ""
                }
            case .godot:
                return relative == GameDeveloperInstrumentationConstants.godotAutoloadPath
                    ? "Project/godot-floe-developer.gd" : ""
            default: return ""
            }
        case .generatedFile:
            return ""
        case .projectPatch:
            return "inline:project.godot[autoload]"
        }
    }

    private func diagnostics(project: GameStoredProject,
                             engine: GameEngineID,
                             gameRoot: GameRelativePath?,
                             files: [GameDeveloperProjectInstrumentationFile],
                             autoload: GameDeveloperGodotAutoloadPlan?,
                             descriptor: GameDeveloperEngineDescriptor,
                             changed: Bool) -> [GameDeveloperInstrumentationDiagnostic] {
        var result: [GameDeveloperInstrumentationDiagnostic] = []
        if let recorded = project.engine, recorded != engine {
            result.append(.init(
                severity: .warning, code: "engine-override",
                message: "The project records \(recorded.rawValue); the explicit selection is \(engine.rawValue). Project metadata is not rewritten.",
                messageZhHans: "工程记录为 \(recorded.rawValue)，本次显式选择为 \(engine.rawValue)。不会改写工程元数据。"))
        } else if project.engine == nil {
            result.append(.init(
                severity: .information, code: "engine-unset",
                message: "The project has no recorded engine. This hook install uses the explicit selection and does not rewrite project metadata.",
                messageZhHans: "工程尚未记录引擎。本次钩子安装使用显式选择，不改写工程元数据。"))
        }
        if let gameRoot {
            result.append(.init(
                severity: .information, code: "nested-root", path: gameRoot,
                message: "The hook is installed under the selected nested root.",
                messageZhHans: "钩子安装在所选嵌套根目录下。"))
        }
        let targets = Set(files.map(\.path))
        let untouched = project.files.filter { !targets.contains($0.path) }.count
        result.append(.init(
            severity: .information, code: "preserved",
            message: "Only the listed files change; \(untouched) existing files and \(project.directories.count) directories remain in the revision.",
            messageZhHans: "只修改列出的文件；修订中保留 \(untouched) 个现有文件和 \(project.directories.count) 个目录。"))
        if !changed {
            result.append(.init(
                severity: .information, code: "idempotent",
                message: "The exact helper bytes are already installed and the autoload (if any) is already registered. Applying this plan creates no revision.",
                messageZhHans: "精确的辅助文件字节已安装，自动加载（如有）已登记。应用此计划不会创建修订。"))
        }
        if descriptor.instrumentation.requiresRebuild {
            result.append(.init(
                severity: .warning, code: "rebuild-required",
                message: "A \(descriptor.displayName) Web build is required after this revision.",
                messageZhHans: "此修订后需要重新构建 \(descriptor.displayName) 网页版。"))
        }
        if let autoload {
            result.append(.init(
                severity: .information, code: "godot-autoload",
                message: autoload.changed
                    ? "The FloeDeveloper autoload line is added; other autoloads, comments, BOM and newline style are preserved."
                    : "The FloeDeveloper autoload is already registered; no duplicate line is added.",
                messageZhHans: autoload.changed
                    ? "添加 FloeDeveloper 自动加载行；其他自动加载、注释、BOM 和换行风格均保留。"
                    : "FloeDeveloper 自动加载已登记；不会添加重复行。"))
        }
        result.append(.init(
            severity: .information, code: "host-dormant",
            message: "The helper is inert unless the Floe host injects \(GameDeveloperInstrumentationConstants.hostObjectName).",
            messageZhHans: "除非 Floe 宿主注入 \(GameDeveloperInstrumentationConstants.hostObjectName)，辅助代码保持惰性。"))
        return result
    }
}

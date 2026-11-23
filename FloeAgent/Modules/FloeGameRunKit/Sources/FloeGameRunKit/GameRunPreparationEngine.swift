// SPDX-License-Identifier: MPL-2.0
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import FloeGameCore
import FloeGameWebKit
import FloeGamePortableKit
import FloeGameNarrativeKit
import FloeGameGDevelopKit

struct GameRunResolvedRoot: Sendable {
    let url: URL
    let relative: String
}

enum GameRunPathResolver {
    static func resolve(root: URL, relativeRoot: String,
                        limits: GameRunPreparationLimits) throws -> GameRunResolvedRoot {
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        guard relativeRoot == "." else {
            let components = relativeRoot.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !components.contains(where: { GameProjectReader.versionControlNames.contains($0.lowercased()) }) else {
                throw GameRunPreparationError.invalidSelection("administrative data is not a game root")
            }
            guard !components.isEmpty, components.count <= limits.maximumDepth else {
                throw GameRunPreparationError.invalidSelection("root depth")
            }
            let rootFD = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else {
                throw GameRunPreparationError.invalidSelection("project root is unavailable")
            }
            defer { close(rootFD) }
            var current = rootFD
            for component in components {
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if current != rootFD { close(current) }
                guard next >= 0 else {
                    throw GameRunPreparationError.invalidSelection(
                        "the selected root is missing, a file, or a symbolic link")
                }
                current = next
            }
            if current != rootFD { close(current) }
            let url = canonical.appendingPathComponent(relativeRoot, isDirectory: true)
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path == canonical.path || resolved.path.hasPrefix(canonical.path + "/") else {
                throw GameRunPreparationError.invalidSelection("the selected root escapes the project")
            }
            return .init(url: resolved, relative: relativeRoot)
        }
        return .init(url: canonical, relative: ".")
    }
}

enum GameRunInspectionComposer {
    /// The controller passes the original captured context to the launch
    /// planner, so the returned inspection must carry that exact context and
    /// root. Evidence from a selected nested root is rebased with its truthful
    /// outer-relative path; only observed evidence is added.
    static func compose(context: GameProjectContext, selectedRoot: URL, relativeRoot: String,
                        engine: GameEngineID, evidence: [GameEngineEvidence],
                        limits: GameRunPreparationLimits) throws -> GameProjectInspection {
        let probeLimits = try GameProjectProbeLimits(
            maximumRootEntries: min(max(limits.maximumEntries, 2_048), 100_000),
            maximumManifestBytes: 262_144)
        let probe = try GameProjectInspector(limits: probeLimits).inspect(rootURL: selectedRoot)
        let prefix = relativeRoot == "." ? "" : relativeRoot
        func rebase(_ path: GameRelativePath) throws -> GameRelativePath {
            guard !prefix.isEmpty else { return path }
            return try GameRelativePath(prefix + "/" + path.value)
        }
        var candidates: [GameEngineCandidate] = []
        for candidate in probe.candidates {
            var items: [GameEngineEvidence] = []
            for item in candidate.evidence {
                items.append(.init(path: try rebase(item.path), kind: item.kind,
                                   versionHint: item.versionHint))
            }
            candidates.append(.init(engine: candidate.engine, evidence: items))
        }
        var rebasedEvidence: [GameEngineEvidence] = []
        for item in evidence {
            let path = try rebase(item.path)
            rebasedEvidence.append(.init(path: path, kind: item.kind,
                                         versionHint: item.versionHint))
        }
        var inspected = Set<GameRelativePath>()
        for path in probe.inspectedPaths { inspected.insert(try rebase(path)) }
        for item in rebasedEvidence { inspected.insert(item.path) }
        if !candidates.contains(where: { $0.engine == engine }) {
            guard !rebasedEvidence.isEmpty else {
                throw GameRunPreparationError.engineNotDetected(engine)
            }
            candidates.append(.init(engine: engine, evidence: rebasedEvidence))
        }
        candidates.sort { $0.engine.rawValue < $1.engine.rawValue }
        return .init(rootURL: context.rootURL, context: context, candidates: candidates,
                     inspectedPaths: inspected.sorted { $0.value < $1.value })
    }
}

enum GameRunExternalOutputVerifier {
    static func verify(engine: GameEngineID, kind: GameRunExternalBuildKind,
                       directory: URL, entry: GameRelativePath,
                       limits: GameRunPreparationLimits) throws {
        let index = try GameRunTreeScanner.scan(rootURL: directory, relativeRoot: ".",
                                                limits: limits)
        guard index.contains(entry.value) else {
            throw GameRunPreparationError.invalidArtifact("missing entry \(entry.value)")
        }
        let lower = entry.value.lowercased()
        guard lower.hasSuffix(".html") || lower.hasSuffix(".htm") else {
            throw GameRunPreparationError.invalidArtifact("entry is not HTML")
        }
        switch kind {
        case .gdevelopWeb:
            do {
                _ = try GameGDevelopArtifactVerifier.verify(directory: directory)
            } catch {
                throw GameRunPreparationError.invalidArtifact("GDevelop export: \(error)")
            }
        case .godotWeb:
            guard index.wasmFile() != nil, index.anyFile(suffix: ".pck") else {
                throw GameRunPreparationError.invalidArtifact("Godot Web export needs .wasm and .pck")
            }
            try requireWASM(index: index)
        case .unityWebGL:
            guard index.wasmFile() != nil,
                  index.files.contains(where: {
                      let value = $0.path.value.lowercased()
                      return value.hasSuffix(".data") || value.hasSuffix(".data.br")
                          || value.hasSuffix(".data.gz") || value.hasSuffix(".data.unityweb")
                          || value.hasSuffix(".loader.js") || value.hasSuffix(".framework.js")
                  }) else {
                throw GameRunPreparationError.invalidArtifact("Unity WebGL export is incomplete")
            }
            try requireWASM(index: index)
        case .cocosWeb:
            guard index.contains("application.js") || index.contains("src/settings.json")
                    || index.anyFile(prefix: "cocos-js/") else {
                throw GameRunPreparationError.invalidArtifact("Cocos Web export is incomplete")
            }
        case .rpgMakerMZWeb:
            guard index.contains("data/System.json"),
                  index.files.contains(where: {
                      let value = $0.path.value.lowercased()
                      return value.hasPrefix("js/rmmz_") && value.hasSuffix(".js")
                  }) else {
                throw GameRunPreparationError.invalidArtifact("RPG Maker MZ Web export is incomplete")
            }
        case .rpgMakerMVDeployment:
            guard index.contains("data/System.json"), index.contains("js/rpg_core.js") else {
                throw GameRunPreparationError.invalidArtifact("RPG Maker MV Web deployment is incomplete")
            }
        case .webBundle:
            break
        }
        let web = try GameRunWebProbe.evaluate(index: index, entry: entry, limits: limits)
        guard let web, web.isSelfContained else {
            throw GameRunPreparationError.invalidArtifact(
                "the produced Web entry references remote or missing local scripts")
        }
        _ = engine
    }

    private static func requireWASM(index: GameRunSourceIndex) throws {
        guard let file = index.wasmFile() else {
            throw GameRunPreparationError.invalidArtifact("missing WASM payload")
        }
        if gameRunIsCompressedWASMPath(file.path.value) { return }
        let bytes = try GameRunFileIO.readPrefix(root: index.rootURL, path: file.path, maximumBytes: 4)
        guard bytes.count >= 4, Array(bytes.prefix(4)) == [0x00, 0x61, 0x73, 0x6d] else {
            throw GameRunPreparationError.invalidArtifact("invalid WASM payload \(file.path.value)")
        }
    }
}

struct GameRunPreparationEngine: Sendable {
    let configuration: GameRunPreparationConfiguration

    init(configuration: GameRunPreparationConfiguration) {
        self.configuration = configuration
    }

    private func webEntry(for engine: GameEngineID, selection: GameRunSelection,
                          index: GameRunSourceIndex) throws -> GameRelativePath? {
        if let entry = selection.entry ?? GameRunRoutePlanner.defaultEntry(index) { return entry }
        guard engine == .twine else { return nil }
        // Published stories often retain the author's title as their HTML filename.
        let reader = try GameProjectReader(rootURL: index.rootURL, maximumFileBytes: configuration.limits.maximumFileBytes)
        var story: GameRelativePath?
        for file in index.files where !file.path.value.contains("/") {
            let ext = (file.path.value as NSString).pathExtension.lowercased()
            guard ext == "html" || ext == "htm" else { continue }
            try Task.checkCancellation()
            if try GameProjectInspector.isTwineHTML(reader: reader, path: file.path, maximumScanBytes: min(configuration.limits.maximumFileBytes, 16 * 1024 * 1024)) {
                guard story == nil else { throw GameRunPreparationError.invalidProject("Choose a single published Twine story.") }
                story = file.path
            }
        }
        return story
    }

    func plan(context: GameProjectContext, engine: GameEngineID,
              selection: GameRunSelection?) async throws -> GameRunRoutePlan {
        do {
            try await checkCurrent(context)
            let chosen = try resolvedSelection(context: context, provided: selection)
            let source = try scan(context: context, selection: chosen)
            let entry = try webEntry(for: engine, selection: chosen, index: source.index)
            let web = try GameRunWebProbe.evaluate(index: source.index, entry: entry,
                                                   limits: configuration.limits, inspectTwine: engine == .twine)
            let availability = try await availability(engine: engine, web: web)
            return try GameRunRoutePlanner.evaluate(engine: engine, index: source.index,
                                                    web: web, availability: availability).plan
        } catch is CancellationError {
            throw GameRunPreparationError.cancelled
        }
    }

    func prepare(request: GameWebRunRequest, selection: GameRunSelection?) async throws -> GamePreparedWebRun {
        do {
            return try await prepareVerified(request: request, selection: selection)
        } catch is CancellationError {
            throw GameRunPreparationError.cancelled
        }
    }

    /// Plan only: live revision validation, selection, bounded scan, route
    /// evaluation and inspection. No build side effect has run at this point.
    private struct Planned: Sendable {
        let route: GameRunRoutePlan
        let source: ScannedSource
        let chosen: GameRunSelection
        let entry: GameRelativePath?
        let inspection: GameProjectInspection
        let target: URL
    }

    private func prepareVerified(request: GameWebRunRequest,
                                 selection: GameRunSelection?) async throws -> GamePreparedWebRun {
        var retryRoute: GameRunRoutePlan?
        while true {
            try Task.checkCancellation()
            let plan = try await preparePlanned(request: request, selection: selection)
            if let retryRoute, plan.route.routeID != retryRoute.routeID || plan.route.action != retryRoute.action {
                throw GameRunPreparationError.sourceChanged("")
            }
            do {
                return try await prepareBuiltAndVerified(request: request, planned: plan)
            } catch let change as GameWebArtifactSourceChanged {
                // Only local staging can be repeated. Re-plan against the same
                // saved revision before the one permitted second attempt.
                guard retryRoute == nil,
                      [.staticWeb, .narrativeAssembly, .runtimePackAssembly].contains(plan.route.action) else {
                    throw GameRunPreparationError.sourceChanged(change.path?.value ?? "")
                }
                retryRoute = plan.route
            }
        }
    }

    private func preparePlanned(request: GameWebRunRequest,
                                selection: GameRunSelection?) async throws -> Planned {
        try await checkCurrent(request.context)
        let chosen = try resolvedSelection(context: request.context, provided: selection)
        try validateArtifactLocation(request.context)
        try ensureArtifactDirectory()
        let source = try scan(context: request.context, selection: chosen)
        let index = source.index
        let entry = try webEntry(for: request.engine, selection: chosen, index: index)
        let web = try GameRunWebProbe.evaluate(index: index, entry: entry,
                                               limits: configuration.limits, inspectTwine: request.engine == .twine)
        let availability = try await availability(engine: request.engine, web: web)
        let evaluation = try GameRunRoutePlanner.evaluate(
            engine: request.engine, index: index, web: web, availability: availability)
        let route = evaluation.plan
        switch route.action {
        case .guestRuntime:
            throw GameRunPreparationError.guestRuntimeRequired(
                route.prerequisites.first ?? .guestRuntime(id: route.routeID, detail: route.notes.first ?? route.routeID))
        case .unavailable:
            throw GameRunPreparationError.missingPrerequisite(
                route.prerequisites.first ?? .unsupportedRoute(id: route.routeID, detail: route.notes.first ?? route.routeID))
        case .staticWeb, .portableAssembly, .narrativeAssembly, .runtimePackAssembly, .externalBuild:
            break
        case .nativeRuntime:
            // Native routes never reach the Web artifact builder; the App's
            // run dispatch owns the launch directly.
            break
        }
        let inspection = try GameRunInspectionComposer.compose(
            context: request.context, selectedRoot: source.root.url,
            relativeRoot: source.root.relative, engine: request.engine,
            evidence: evaluation.evidence, limits: configuration.limits)
        let target = artifactTarget(request: request)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw GameProjectError.destinationExists
        }
        return Planned(route: route, source: source, chosen: chosen, entry: entry,
                       inspection: inspection, target: target)
    }

    /// Build, then verify the staged artifact and the live source once. The
    /// staged read-back (`GameWebArtifactPackage.verify()`) proving corrupt is
    /// an artifact-side failure, not a source race: it maps to the existing
    /// `.invalidArtifact` and is never recovered by retrying the source.
    private func prepareBuiltAndVerified(request: GameWebRunRequest,
                                         planned: Planned) async throws -> GamePreparedWebRun {
        let staging = try makeStagingURL()
        var published = false
        defer {
            try? FileManager.default.removeItem(at: staging)
            // The build publishes at `target` before it returns; a failure at
            // any later point must not leave the owned artifact behind.
            if !published { try? FileManager.default.removeItem(at: planned.target) }
        }
        let package: GameWebArtifactPackage
        switch planned.route.action {
        case .staticWeb:
            package = try buildStatic(context: request.context, engine: request.engine,
                                      selectedRoot: planned.source.root,
                                      entry: planned.entry,
                                      selection: planned.chosen, target: planned.target)
        case .portableAssembly:
            package = try await buildPortable(context: request.context, engine: request.engine,
                                              index: planned.source.index,
                                              entry: planned.entry,
                                              selection: planned.chosen,
                                              staging: staging, target: planned.target)
        case .narrativeAssembly:
            package = try buildNarrative(context: request.context, engine: request.engine,
                                         selectedRoot: planned.source.root.url,
                                         entry: planned.entry,
                                         selection: planned.chosen,
                                         staging: staging, target: planned.target)
        case .runtimePackAssembly:
            package = try await buildRuntimePack(context: request.context, engine: request.engine,
                                                 source: planned.source.index,
                                                 entry: planned.entry,
                                                 selection: planned.chosen,
                                                 staging: staging, target: planned.target)
        case .externalBuild:
            package = try await buildExternal(context: request.context, engine: request.engine,
                                              source: planned.source.index,
                                              entry: planned.entry,
                                              selection: planned.chosen,
                                              staging: staging, target: planned.target,
                                              route: planned.route)
        case .guestRuntime, .unavailable:
            throw GameRunPreparationError.unsupportedEngine(request.engine)
        case .nativeRuntime:
            throw GameRunPreparationError.unsupportedEngine(request.engine)
        }
        do {
            try package.verify()
        } catch let error as GameProjectError where error == .corruptStorage {
            throw GameRunPreparationError.invalidArtifact(
                "the prepared game data failed read-back verification")
        }
        try Task.checkCancellation()
        try verifySourceUnchanged(planned.source.index)
        try await checkCurrent(request.context)
        let scoped = try package.scoped(toGameRoot: planned.chosen.root)
        published = true
        return GamePreparedWebRun(inspection: planned.inspection, package: scoped)
    }

    // MARK: - Static Web

    private func buildStatic(context: GameProjectContext, engine: GameEngineID,
                             selectedRoot: GameRunResolvedRoot, entry: GameRelativePath?,
                             selection: GameRunSelection,
                             target: URL) throws -> GameWebArtifactPackage {
        guard let entry else {
            throw GameRunPreparationError.invalidProject("no HTML entry")
        }
        if let override = selection.entry, override != entry {
            throw GameRunPreparationError.invalidSelection("entry does not match the selected Web project")
        }
        if engine == .gdevelop {
            do {
                let manifest = try GameGDevelopArtifactVerifier.verify(directory: selectedRoot.url)
                guard manifest.entry == entry else {
                    throw GameRunPreparationError.invalidArtifact("GDevelop export entry mismatch")
                }
            } catch let error as GameRunPreparationError {
                throw error
            } catch {
                throw GameRunPreparationError.invalidArtifact("GDevelop export: \(error)")
            }
        }
        let contentRoot = selectedRoot.relative == "." ? nil : selectedRoot.url
        return try GameWebArtifactPackage.build(source: context, engine: engine, entry: entry,
                                                to: target, contentRoot: contentRoot,
                                                limits: repositoryLimits)
    }

    // MARK: - Portable adapters

    private func buildPortable(context: GameProjectContext, engine: GameEngineID,
                               index: GameRunSourceIndex, entry: GameRelativePath?,
                               selection: GameRunSelection, staging: URL,
                               target: URL) async throws -> GameWebArtifactPackage {
        let descriptor = try descriptor(context: context, index: index)
        if engine == .rpgMakerMV {
            return try await buildMV(context: context, descriptor: descriptor, index: index,
                               entry: entry, selection: selection, staging: staging, target: target)
        }
        guard engine == .love || engine == .renpy else {
            throw GameRunPreparationError.unsupportedEngine(engine)
        }
        let adapter: any GamePortableAdapter
        if engine == .love {
            adapter = GamePortableLoveAdapter()
        } else {
            adapter = GamePortableRenPyAdapter()
        }
        let profile = try adapter.inspect(descriptor)
        if profile.readiness == .webReady {
            let chosen = selection.entry ?? profile.entry ?? entry
            return try buildStatic(context: context, engine: engine,
                                   selectedRoot: .init(url: index.rootURL, relative: index.relativeRoot),
                                   entry: chosen, selection: selection, target: target)
        }
        let resources = configuration.portableResources[engine]
        if engine == .love && resources == nil {
            throw GameRunPreparationError.missingPrerequisite(
                .preparedResourcePack(id: "lovejs-11.4.1",
                    detail: "The prepared love.js 11.4.1 compatibility resources are required to build this source."))
        }
        guard let port = configuration.portableBuildPort else {
            throw GameRunPreparationError.missingPrerequisite(
                .hostBuildProvider(id: "portable-build",
                    detail: "The host's existing job/build provider is required for this portable engine."))
        }
        if engine == .renpy && configuration.renpySDK == nil {
            throw GameRunPreparationError.missingPrerequisite(
                .externalTool(id: "renpy-8.5.3-web",
                    detail: "The pinned Ren'Py 8.5.3 Web SDK path is required for the official web_build command."))
        }
        // Build from a byte-identical private copy. Ren'Py's official web_build
        // may recompile .rpyc companions and LÖVE's CLI may stage temporary
        // files; the imported/materialized tree must never be mutated and every
        // existing user .rpyc must remain present in the copy.
        let sourceStage = try makeStagingURL()
        defer { try? FileManager.default.removeItem(at: sourceStage) }
        try GameRunFileIO.copyTree(index: index, to: sourceStage, limits: configuration.limits)
        let buildDescriptor = try self.descriptor(context: context, rootURL: sourceStage,
                                             files: index.paths)
        let plan = try adapter.plan(for: buildDescriptor, outputURL: staging, resources: resources,
                                    sdkURL: engine == .renpy ? configuration.renpySDK : nil)
        if engine == .renpy {
            // Require the adapter's official web_build plan, not a raw .rpy
            // repack: existing compiled .rpyc companions stay in the copied
            // source and only the official SDK produces the Web export.
            guard plan.kind == .renpyWebBuild,
                  plan.steps.contains(where: { $0.kind == .runRenPy }) else {
                throw GameRunPreparationError.invalidArtifact(
                    "Ren'Py preparation did not produce the official web_build plan")
            }
        }
        let buildRequest = try GamePortableBuildRequest(
            project: buildDescriptor, outputURL: staging, resources: resources,
            sdkURL: engine == .renpy ? configuration.renpySDK : nil,
            title: selection.title ?? configuration.title, memoryBytes: 33_554_432)
        let output = try await port.execute(plan, request: buildRequest)
        try Task.checkCancellation()
        try await checkCurrent(context)
        let outputURL = try validatedStagingOutput(output.directory, staging: staging)
        _ = try adapter.verifyArtifact(at: outputURL, profile: profile, resources: resources)
        if let override = selection.entry, override != plan.entry {
            throw GameRunPreparationError.invalidSelection("entry does not match the portable build output")
        }
        let sealed = try GamePortableArtifactSealer.seal(
            source: context, engine: engine, entry: plan.entry, contentRoot: outputURL,
            to: target, profile: profile, resources: resources, buildKind: plan.kind)
        return sealed.package
    }

    private func buildMV(context: GameProjectContext,
                         descriptor: GamePortableProjectDescriptor,
                         index: GameRunSourceIndex, entry: GameRelativePath?,
                         selection: GameRunSelection, staging: URL,
                         target: URL) async throws -> GameWebArtifactPackage {
        let adapter = GamePortableMVAdapter()
        let profile = try adapter.inspect(descriptor)
        if profile.readiness == .webReady {
            let chosen = selection.entry ?? profile.entry ?? entry
            return try buildStatic(context: context, engine: .rpgMakerMV,
                                   selectedRoot: .init(url: index.rootURL, relative: index.relativeRoot),
                                   entry: chosen, selection: selection, target: target)
        }
        guard let chosenEntry = selection.entry ?? profile.entry ?? entry else {
            throw GameRunPreparationError.invalidProject("MV source has no index.html entry")
        }
        let modules = index.anyFile(prefix: "js/rpg_core/")
        var resources = configuration.portableResources[.rpgMakerMV]
        if !modules, resources == nil {
            resources = try await configuration.preparePortableResource?(.rpgMakerMV)
            try Task.checkCancellation()
            try await checkCurrent(context)
            if let resources, resources.engine != .rpgMakerMV {
                throw GameRunPreparationError.invalidConfiguration("portable resource engine mismatch")
            }
        }
        if !modules && resources == nil {
            throw GameRunPreparationError.missingPrerequisite(
                .preparedResourcePack(id: "rpg-maker-mv-corescript",
                    detail: "The prepared official MIT RPG Maker MV CoreScript resources are required to assemble this source."))
        }
        try GamePortableMVAssembler.assemble(project: descriptor, resources: resources, to: staging)
        let sealed = try GamePortableArtifactSealer.seal(
            source: context, engine: .rpgMakerMV, entry: chosenEntry, contentRoot: staging,
            to: target, profile: profile, resources: resources,
            buildKind: modules ? .mvCoreAssembly : .mvTemplateAssembly)
        return sealed.package
    }

    // MARK: - Narrative

    private func buildNarrative(context: GameProjectContext, engine: GameEngineID,
                                selectedRoot: URL, entry: GameRelativePath?,
                                selection: GameRunSelection, staging: URL,
                                target: URL) throws -> GameWebArtifactPackage {
        guard let resources = configuration.narrativeResources else {
            throw GameRunPreparationError.missingPrerequisite(
                .preparedResourcePack(id: "narrative-runtime-resources",
                    detail: "The prepared narrative runtime resources are required to build this artifact."))
        }
        let expected = GameRunRoutePlanner.path("index.html")
        if let override = selection.entry, override != expected {
            throw GameRunPreparationError.invalidSelection("narrative adapters always produce index.html")
        }
        switch engine {
        case .ink:
            try GameInkAdapter.buildArtifact(projectAt: selectedRoot, to: staging, resources: resources)
        case .twine:
            try GameTwineAdapter.buildArtifact(projectAt: selectedRoot, to: staging, resources: resources)
        case .wasm4:
            try GameWasm4Adapter.buildArtifact(projectAt: selectedRoot, to: staging, resources: resources)
        case .tic80:
            try GameTIC80Adapter.buildArtifact(projectAt: selectedRoot, to: staging, resources: resources)
        case .microStudio:
            try GameMicroStudioAdapter.buildArtifact(projectAt: selectedRoot, to: staging, resources: resources)
        default:
            throw GameRunPreparationError.unsupportedEngine(engine)
        }
        guard FileManager.default.fileExists(atPath: staging.appendingPathComponent(expected.value).path) else {
            throw GameRunPreparationError.invalidArtifact("narrative artifact has no index.html")
        }
        _ = entry
        return try GameWebArtifactPackage.build(source: context, engine: engine, entry: expected,
                                                to: target, contentRoot: staging,
                                                limits: repositoryLimits)
    }

    // MARK: - Runtime pack assembly

    private func buildRuntimePack(context: GameProjectContext, engine: GameEngineID,
                                  source: GameRunSourceIndex, entry: GameRelativePath?,
                                  selection: GameRunSelection, staging: URL,
                                  target: URL) async throws -> GameWebArtifactPackage {
        guard let provider = configuration.runtimePacks else {
            throw GameRunPreparationError.missingPrerequisite(
                .preparedResourcePack(id: "\(engine.rawValue)-runtime",
                    detail: "A prepared \(engine.rawValue) runtime pack provider is required."))
        }
        guard let pack = try await provider.runtimePack(for: engine) else {
            throw GameRunPreparationError.missingPrerequisite(
                .preparedResourcePack(id: "\(engine.rawValue)-runtime",
                    detail: "A prepared \(engine.rawValue) runtime pack is required to assemble the local engine script."))
        }
        guard pack.engine == engine else {
            throw GameRunPreparationError.invalidArtifact("runtime pack engine mismatch")
        }
        try Task.checkCancellation()
        try GameRunFileIO.copyTree(index: source, to: staging, limits: configuration.limits)
        try install(pack: pack, into: staging)
        let stagingIndex = try GameRunTreeScanner.scan(rootURL: staging, relativeRoot: ".",
                                                       limits: configuration.limits)
        let chosenEntry = selection.entry ?? entry ?? GameRunRoutePlanner.defaultEntry(stagingIndex)
        guard let chosenEntry else {
            throw GameRunPreparationError.invalidArtifact("runtime pack artifact has no HTML entry")
        }
        let web = try GameRunWebProbe.evaluate(index: stagingIndex, entry: chosenEntry,
                                               limits: configuration.limits)
        guard let web, web.externalReferences.isEmpty, web.missingReferences.isEmpty else {
            throw GameRunPreparationError.invalidProject(
                "the Web entry references remote or missing local scripts that the runtime pack cannot satisfy")
        }
        let scriptDestinations = Set(pack.files.filter {
            $0.destination.value.lowercased().hasSuffix(".js")
        }.map(\.destination.value))
        guard web.references.contains(where: { scriptDestinations.contains($0) }) else {
            throw GameRunPreparationError.invalidArtifact(
                "the runtime pack does not provide any script referenced by the entry")
        }
        return try GameWebArtifactPackage.build(source: context, engine: engine, entry: chosenEntry,
                                                to: target, contentRoot: staging,
                                                limits: repositoryLimits)
    }

    private func install(pack: GameRunRuntimePack, into staging: URL) throws {
        for file in pack.files {
            try Task.checkCancellation()
            let bytes = try pack.read(file.source)
            guard bytes.count == file.bytes else {
                throw GameRunPreparationError.invalidArtifact("runtime pack bytes \(file.source.value)")
            }
            let destination = staging.appendingPathComponent(file.destination.value)
            if FileManager.default.fileExists(atPath: destination.path) {
                let existing = try GameRunFileIO.read(root: staging, path: file.destination,
                    maximumBytes: max(bytes.count + 1, 1))
                if existing == bytes { continue }
                throw GameRunPreparationError.invalidArtifact(
                    "runtime pack would overwrite \(file.destination.value)")
            }
            try GameRunFileIO.write(bytes, to: destination)
        }
    }

    // MARK: - External build service

    private func buildExternal(context: GameProjectContext, engine: GameEngineID,
                               source: GameRunSourceIndex, entry: GameRelativePath?,
                               selection: GameRunSelection, staging: URL,
                               target: URL, route: GameRunRoutePlan) async throws -> GameWebArtifactPackage {
        guard let provider = configuration.externalBuildProvider else {
            throw GameRunPreparationError.missingPrerequisite(
                .hostBuildProvider(id: "external-build",
                    detail: "The host's existing jobs/CI build provider is required for this engine."))
        }
        let expected = selection.entry ?? route.entry ?? entry ?? GameRunRoutePlanner.path("index.html")
        let requirement = route.prerequisites.first
            ?? .externalTool(id: route.routeID, detail: route.notes.first ?? route.routeID)
        // The host build service receives a private byte-identical source copy.
        // A tool that writes generated files can never mutate the imported tree.
        let sourceStage = try makeStagingURL()
        defer { try? FileManager.default.removeItem(at: sourceStage) }
        try GameRunFileIO.copyTree(index: source, to: sourceStage, limits: configuration.limits)
        // Capture the original project/root/inventory before any host call.
        // The prepared copy is a separate identity; a byte-identical copy is
        // verified against the saved selected digest, never merely assumed.
        let sourceSelection = try await makeSourceSelection(
            context: context, engine: engine, selection: selection,
            preparedRoot: sourceStage)
        let live = try await checkCurrent(context)
        try sourceSelection.validate(liveContext: live)
        let request = try GameRunExternalBuildRequest(
            engine: engine, kind: externalKind(engine: engine, routeID: route.routeID),
            context: context, sourceRoot: sourceStage, outputDirectory: staging,
            expectedEntry: expected, requirement: requirement,
            selection: sourceSelection)
        let output: GameRunExternalBuildOutput
        do {
            output = try await provider.build(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GameRunPreparationError.externalBuildFailed(String(describing: error))
        }
        try Task.checkCancellation()
        let after = try await checkCurrent(context)
        try sourceSelection.validate(liveContext: after)
        guard output.entry == expected else {
            throw GameRunPreparationError.invalidArtifact(
                "external build returned \(output.entry.value), expected \(expected.value)")
        }
        let outputURL = try validatedStagingOutput(output.directory, staging: staging)
        try GameRunExternalOutputVerifier.verify(
            engine: engine, kind: externalKind(engine: engine, routeID: route.routeID),
            directory: outputURL, entry: output.entry, limits: configuration.limits)
        return try GameWebArtifactPackage.build(source: context, engine: engine,
                                                entry: output.entry, to: target,
                                                contentRoot: outputURL,
                                                limits: repositoryLimits)
    }

    private func externalKind(engine: GameEngineID, routeID: String) -> GameRunExternalBuildKind {
        switch engine {
        case .godot: return .godotWeb
        case .unity: return .unityWebGL
        case .cocosCreator: return .cocosWeb
        case .gdevelop: return .gdevelopWeb
        case .rpgMakerMZ: return .rpgMakerMZWeb
        case .rpgMakerMV: return .rpgMakerMVDeployment
        case .phaser, .kaplay, .babylon, .playcanvas: return .webBundle
        default:
            _ = routeID
            return .webBundle
        }
    }

    // MARK: - Context, scan, and staging

    struct ScannedSource: Sendable {
        let root: GameRunResolvedRoot
        let index: GameRunSourceIndex
    }

    private func resolvedSelection(context: GameProjectContext,
                                   provided: GameRunSelection?) throws -> GameRunSelection {
        let selection: GameRunSelection
        if let provided {
            selection = provided
        } else {
            selection = try GameRunSelection(context: context)
        }
        try selection.validate(context: context)
        return selection
    }

    private func scan(context: GameProjectContext,
                      selection: GameRunSelection) throws -> ScannedSource {
        let root = try GameRunPathResolver.resolve(
            root: context.rootURL, relativeRoot: selection.root, limits: configuration.limits)
        let index = try GameRunTreeScanner.scan(rootURL: root.url, relativeRoot: root.relative,
                                                limits: configuration.limits)
        return .init(root: root, index: index)
    }

    private func descriptor(context: GameProjectContext,
                            index: GameRunSourceIndex) throws -> GamePortableProjectDescriptor {
        try descriptor(context: context, rootURL: index.rootURL, files: index.paths)
    }

    private func descriptor(context: GameProjectContext, rootURL: URL,
                            files: [GameRelativePath]) throws -> GamePortableProjectDescriptor {
        try GamePortableProjectDescriptor(rootURL: rootURL, projectID: context.projectID,
                                          owner: context.owner, revision: context.savedRevision,
                                          context: nil, files: files)
    }

    @discardableResult
    private func checkCurrent(_ context: GameProjectContext) async throws -> GameProjectContext {
        guard let contexts = configuration.contexts else { return context }
        let current = try await contexts.currentContext(for: context)
        // Immutable source materialization changes its directory on each
        // revision. For the same owned project/environment, report the causal
        // revision change before the derived root change. Both remain fenced.
        if current.projectID == context.projectID, current.owner == context.owner,
           current.environmentID == context.environmentID,
           current.savedRevision != context.savedRevision {
            throw GameRunPreparationError.contextChanged(.revision)
        }
        do {
            try context.validate(current: current)
        } catch let error as GameProjectError {
            if case .contextChanged(let change) = error {
                throw GameRunPreparationError.contextChanged(change)
            }
            throw error
        }
        return current
    }

    /// Builds the immutable original selection and validates the exact
    /// prepared bytes. The saved repository inventory is authoritative when the
    /// host supplies it; the fallback scan is read-only and bounded.
    private func makeSourceSelection(context: GameProjectContext,
                                     engine: GameEngineID,
                                     selection: GameRunSelection,
                                     preparedRoot: URL) async throws
        -> GameRunSourceSelection {
        let gameRoot: GameRelativePath?
        if selection.root == "." {
            gameRoot = nil
        } else {
            do { gameRoot = try GameRelativePath(selection.root) }
            catch {
                throw GameRunPreparationError.invalidSelection(
                    "the selected root is not a project-relative directory")
            }
        }
        let inventory: GameRunProjectInventory
        if let provider = configuration.projectInventory {
            do { inventory = try await provider(context) }
            catch let error as GameRunSourceSelectionError {
                throw GameRunPreparationError.invalidSelection(
                    error.localizedDescription)
            } catch {
                throw GameRunPreparationError.invalidProject(
                    "the saved project inventory could not be read: \(error)")
            }
        } else {
            do {
                inventory = try GameRunProjectInventory.scan(
                    context: context, limits: configuration.limits)
            } catch let error as GameRunSourceSelectionError {
                throw GameRunPreparationError.invalidProject(
                    error.localizedDescription)
            } catch {
                throw GameRunPreparationError.invalidProject(
                    "the original project inventory could not be scanned: \(error)")
            }
        }
        let manifest: (files: [GameProjectFile], directories: [GameRelativePath], digest: String)
        do {
            manifest = try GameRunSourceDigest.manifest(
                rootURL: preparedRoot, limits: configuration.limits)
        } catch let error as GameRunSourceSelectionError {
            throw GameRunPreparationError.invalidArtifact(error.localizedDescription)
        }
        let expected: String
        do {
            expected = try inventory.selectedSourceDigest(gameRoot: gameRoot)
                ?? inventory.wholeProjectDigest
        } catch {
            throw GameRunPreparationError.invalidSelection(String(describing: error))
        }
        guard manifest.digest == expected else {
            throw GameRunPreparationError.invalidArtifact(
                "the prepared source copy does not match the saved selected source")
        }
        let prepared = try GameRunPreparedSource(
            digest: manifest.digest, transform: .byteIdenticalCopy,
            transformID: nil, relation: "equals-selected-source")
        do {
            return try GameRunSourceSelection(
                context: context, engine: engine, gameRoot: gameRoot,
                inventory: inventory, prepared: prepared)
        } catch let error as GameRunSourceSelectionError {
            throw GameRunPreparationError.invalidSelection(
                error.localizedDescription)
        }
    }

    private func verifySourceUnchanged(_ index: GameRunSourceIndex) throws {
        let after = try GameRunTreeScanner.scan(rootURL: index.rootURL,
                                                relativeRoot: index.relativeRoot,
                                                limits: configuration.limits)
        guard after.files.map(\.path) == index.files.map(\.path),
              after.files.map(\.bytes) == index.files.map(\.bytes),
              after.files.map(\.executable) == index.files.map(\.executable) else {
            throw GameWebArtifactSourceChanged()
        }
    }

    private func availability(engine: GameEngineID,
                              web: GameRunWebEntry?) async throws -> GameRunAvailability {
        var runtimePacks = Set<GameEngineID>()
        if let provider = configuration.runtimePacks,
           [.phaser, .kaplay, .babylon, .playcanvas].contains(engine),
           let web {
            let engineReferences = web.missingReferences.filter {
                GameRunRoutePlanner.isEngineReference($0, engine: engine)
            }
            if !engineReferences.isEmpty,
               engineReferences.count == web.missingReferences.count,
               engineReferences.allSatisfy(GameRunRoutePlanner.packableEngineReference),
               let pack = try await provider.runtimePack(for: engine), pack.engine == engine {
                runtimePacks.insert(engine)
            }
        }
        return .init(
            narrativeResources: configuration.narrativeResources != nil,
            portableResources: Set(configuration.portableResources.keys),
            runtimePacks: runtimePacks,
            portableBuildPort: configuration.portableBuildPort != nil,
            externalBuildProvider: configuration.externalBuildProvider != nil,
            renpySDK: configuration.renpySDK != nil)
    }

    private var repositoryLimits: GameRepositoryLimits {
        try! GameRepositoryLimits(maximumFileBytes: configuration.limits.maximumFileBytes,
                                  maximumProjectBytes: configuration.limits.maximumProjectBytes,
                                  maximumEntries: configuration.limits.maximumEntries)
    }

    private func validateArtifactLocation(_ context: GameProjectContext) throws {
        let artifact = configuration.artifactDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let root = context.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard artifact.path != root.path, !artifact.path.hasPrefix(root.path + "/") else {
            throw GameRunPreparationError.invalidConfiguration(
                "artifact directory must be outside the project materialization")
        }
    }

    private func ensureArtifactDirectory() throws {
        let directory = configuration.artifactDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw GameRunPreparationError.invalidConfiguration(
                "artifact directory is not a regular directory")
        }
    }

    private func artifactTarget(request: GameWebRunRequest) -> URL {
        configuration.artifactDirectory.appendingPathComponent(
            request.id.uuidString.lowercased(), isDirectory: true)
    }

    private func makeStagingURL() throws -> URL {
        let parent = configuration.artifactDirectory.appendingPathComponent(
            "Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw GameRunPreparationError.invalidConfiguration("staging parent is not a real directory")
        }
        for _ in 0..<4 {
            let candidate = parent.appendingPathComponent(UUID().uuidString.lowercased(),
                                                          isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw GameRunPreparationError.invalidConfiguration("staging identity collision")
    }

    private func validatedStagingOutput(_ output: URL, staging: URL) throws -> URL {
        let parent = staging.deletingLastPathComponent().standardizedFileURL
            .resolvingSymlinksInPath()
        let resolved = output.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path == parent.path || resolved.path.hasPrefix(parent.path + "/") else {
            throw GameRunPreparationError.invalidArtifact("build output escaped the owned staging directory")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GameRunPreparationError.invalidArtifact("build output directory is missing")
        }
        return resolved
    }
}


// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools
import FloeExecution
import FloeEnvironments
import FloeLaTeXCore
import FloeLaTeXEngine
import FloeLaTeXParsing

/// Native App hooks resolve the exact original/usage lease through existing
/// Space, Notes and task stores. The hooks are compiled code, never project
/// metadata or tool arguments. They must recheck the real saved run, current
/// execution binding and per-original read/write grant.
public struct LaTeXHostHooks:Sendable {
    public var verify:@MainActor @Sendable (ToolContext) async throws -> Void
    public var acquire:@MainActor @Sendable (UUID,ToolContext,Bool) async throws -> LaTeXHostProject
    public var create:@MainActor @Sendable (String,String,ToolContext) async throws -> LaTeXHostProject
    public var publish:@MainActor @Sendable (URL,LaTeXHostProject,ToolContext) async throws -> ToolExecutionOutput
    public var didChange:@MainActor @Sendable (UUID,ToolContext) async throws -> Void
    public var authorizeInstallation:@MainActor @Sendable (ToolContext) async throws -> Void
    public var preparationProgress:@MainActor @Sendable (UUID,ToolContext,LaTeXPreparationProgress) -> Void
    public var resourceNetworkAllowed:@MainActor @Sendable (ToolContext) async throws -> Bool
    public init(verify:@escaping @MainActor @Sendable (ToolContext) async throws -> Void,
                acquire:@escaping @MainActor @Sendable (UUID,ToolContext,Bool) async throws -> LaTeXHostProject,
                create:@escaping @MainActor @Sendable (String,String,ToolContext) async throws -> LaTeXHostProject,
                publish:@escaping @MainActor @Sendable (URL,LaTeXHostProject,ToolContext) async throws -> ToolExecutionOutput,
                didChange:@escaping @MainActor @Sendable (UUID,ToolContext) async throws -> Void,
                authorizeInstallation:@escaping @MainActor @Sendable (ToolContext) async throws -> Void = {_ in throw LaTeXError.unavailable("This task has not enabled toolchain installation.")},
                preparationProgress:@escaping @MainActor @Sendable (UUID,ToolContext,LaTeXPreparationProgress) -> Void = {_,_,_ in},
                resourceNetworkAllowed:@escaping @MainActor @Sendable (ToolContext) async throws -> Bool = {_ in false}) {
        self.verify=verify;self.acquire=acquire;self.create=create;self.publish=publish;self.didChange=didChange
        self.authorizeInstallation=authorizeInstallation
        self.preparationProgress=preparationProgress;self.resourceNetworkAllowed=resourceNetworkAllowed
    }
}

/// One App-owned instance shared by every editor and model invocation. Only
/// capability facts are cached: a prior call's grant/context/transport is
/// never reused to execute a later model or native-UI call.
@MainActor public final class LaTeXHostServices:LaTeXHostAccess {
    public let builds:LaTeXBuildService
    /// Retained only for source-compatible legacy qualification callers.
    public let jobs:BackgroundJobService?
    public let environments:EnvironmentRegistry
    public let registry:ToolRunnerRegistry
    private let hooks:LaTeXHostHooks
    private let nativeEngine:LaTeXAppleNativeEngine
    private var installed=false
    private var capabilities=[String:[LaTeXEngineCapability]]()
    private var preparingProjects=Set<String>()
    public init(cacheRoot:URL,jobs:BackgroundJobService? = nil,environments:EnvironmentRegistry,registry:ToolRunnerRegistry = .shared,hooks:LaTeXHostHooks,nativeEngine:LaTeXAppleNativeEngine = .init()) throws {
        builds=try .init(cacheRoot:cacheRoot,engine:LaTeXEngineRouter(native:nativeEngine))
        self.jobs=jobs;self.environments=environments;self.registry=registry;self.hooks=hooks;self.nativeEngine=nativeEngine
    }
    public func registerTools() {
        guard !installed else{return};LaTeXHostTools.register(host:self,registry:registry)
        for name in LaTeXHostTools.names {
            guard var runner=registry.runner(named:name) else{continue}
            let original=runner.run
            runner.run={ [weak self] data,context in
                guard let self else {throw LaTeXError.unavailable("The LaTeX workspace is unavailable.")}
                try await self.verify(context)
                let result=try await original(data,context)
                // A real commit is already durable. Metadata sync failure must
                // not turn a successful idempotent transaction into a replay.
                if ["latex.edit","latex.restore","latex.create"].contains(name) {
                    let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any]
                    let response=try? JSONSerialization.jsonObject(with:Data(result.summary.utf8)) as? [String:Any]
                    if let raw=(object?["projectID"] ?? response?["id"]) as? String,let id=UUID(uuidString:raw) {try? await self.hooks.didChange(id,context)}
                }
                return result
            }
            registry.register(runner)
        }
        installed=true
    }
    private func verify(_ context:ToolContext) async throws {
        try context.cancellation.throwIfCancelled();try Task.checkCancellation()
        guard !context.temporaryReadOnly,!context.publicWebOnly,context.conversationID != nil,
              context.allowedToolNames?.contains(context.executionToolName ?? "") != false,
              context.frozenEffectiveCatalogNames?.contains(context.executionToolName ?? "") != false else {throw LaTeXError.unavailable("Open the original in an authorized saved task.")}
        try await hooks.verify(context)
    }
    public func acquire(projectID:UUID,context:ToolContext,editing:Bool) async throws -> LaTeXHostProject {
        try await verify(context)
        let project=try await hooks.acquire(projectID,context,editing)
        guard try await project.store.manifest().id==projectID else {throw LaTeXError.invalidProject}
        try await verify(context);return project
    }
    public func create(title:String,templateID:String,context:ToolContext) async throws -> LaTeXHostProject {
        try await verify(context)
        guard context.approvalGrantID != nil,LaTeXTemplates.all.contains(where:{$0.id==templateID}) else {throw LaTeXError.invalidProject}
        let result=try await hooks.create(title,templateID,context)
        try await verify(context);return result
    }
    public func publish(file:URL,project:LaTeXHostProject,context:ToolContext) async throws -> ToolExecutionOutput {
        try await verify(context);return try await hooks.publish(file,project,context)
    }
    public func cachedEngine(project:LaTeXHostProject,context:ToolContext) async -> (any LaTeXEngineRunning)? {
        guard (try? await verify(context)) != nil else {return nil}
        return nativeEngine
    }
    public func prepareEngine(project:LaTeXHostProject,context:ToolContext,binding:RuntimeAuthorityBinding?) async throws -> (any LaTeXEngineRunning)? {
        try await verify(context)
        let values=await nativeEngine.capabilities()
        guard !values.isEmpty else {throw LaTeXError.unavailable("此版本未包含可用的原生排版引擎。 / This build does not include an available native typesetting engine.")}
        capabilities["native"]=values
        return nativeEngine
    }
    public func cachedCapabilities(environmentID:String)->[LaTeXEngineCapability] {capabilities["native"] ?? []}
    public func prepareDocument(project:LaTeXHostProject,expectedRevision:Int64?,configuration:LaTeXBuildConfiguration,context:ToolContext,binding:RuntimeAuthorityBinding?) async throws -> (any LaTeXEngineRunning)? {
        let preparationKey=project.store.root.standardizedFileURL.path
        guard preparingProjects.insert(preparationKey).inserted else {throw LaTeXError.unavailable("This project is already preparing typesetting. Wait for it or stop its current operation.")}
        defer {preparingProjects.remove(preparationKey)}
        try await verify(context)
        let manifest=try await project.store.manifest()
        if let expectedRevision,manifest.revision != expectedRevision {throw LaTeXError.revisionConflict(expected:expectedRevision,actual:manifest.revision)}
        _=try await builds.history(store:project.store)
        guard !(await builds.isBusy(projectID:manifest.id)) else {throw LaTeXError.unavailable("This project has an active or unreconciled build. Inspect or stop it before starting another.")}
        guard !(await nativeEngine.capabilities()).isEmpty else {throw LaTeXError.unavailable("The native typesetting engine is unavailable in this build.")}
        var effective=configuration
        let networkAllowed=try await hooks.resourceNetworkAllowed(context)
        effective.offline=configuration.offline || !networkAllowed
        if !effective.offline {try await hooks.authorizeInstallation(context)}
        try await verify(context)
        guard try await project.store.manifest()==manifest else {throw LaTeXError.changedFile(manifest.mainFile)}
        let snapshot=try await project.store.snapshot(expectedRevision:manifest.revision)
        let directory=project.store.root.appendingPathComponent("Preparation/"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try LaTeXDigest.encode(snapshot.manifest).write(to:directory.appendingPathComponent("SourceManifest.json"),options:.atomic)
        let hooks=self.hooks,delivery=LaTeXPreparationProgressSequence()
        let notify:@Sendable (LaTeXPreparationProgress)->Void={value in
            let ordered=delivery.next(value)
            Task { @MainActor in hooks.preparationProgress(manifest.id,context,ordered) }
        }
        notify(.init(stage:.checking))
        let progress:@Sendable (String)->Void={message in
            if message.hasPrefix("FLOE_TEX_RESOURCE_DOWNLOAD") {notify(.init(stage:.downloading))}
            else if message.hasPrefix("FLOE_TEX_RESOURCE_CHECK") {notify(.init(stage:.checking))}
        }
        let request=LaTeXEngineRequest(snapshot:snapshot,outputRoot:directory.appendingPathComponent("Output"),
            cacheRoot:builds.cacheRoot,configuration:effective,
            executionOwner:.init(taskID:context.conversationID!,runID:context.runID,environmentID:nil))
        let operation=Task {try await self.nativeEngine.prepare(request,progress:progress)}
        let cancellation=context.cancellation
        let watcher=Task {
            while !Task.isCancelled {
                if cancellation.isCancelled {operation.cancel();return}
                do {try await Task.sleep(for:.milliseconds(50))}catch {return}
            }
        }
        defer {watcher.cancel()}
        do {
            let prepared=try await withTaskCancellationHandler(operation:{try await operation.value},onCancel:{operation.cancel()})
            try LaTeXDigest.encode(prepared).write(to:directory.appendingPathComponent("NativePreparation.json"),options:.atomic)
            try await verify(context)
            guard prepared.workerStopped,try await project.store.manifest()==manifest else {throw LaTeXError.changedFile(manifest.mainFile)}
            try await project.store.releaseSnapshot(snapshot)
            notify(.init(stage:.ready))
            let engine=nativeEngine.pinned(to:prepared.bundleDigest)
            capabilities["native"]=await engine.capabilities()
            return LaTeXNativePreparedEngine(engine:engine,manifest:manifest,
                owner:.init(taskID:context.conversationID!,runID:context.runID,environmentID:nil),
                configuration:effective,preparationProgress:notify)
        } catch {
            // Preserve the exact preparation snapshot and original output on
            // failure. A missing worker-stop receipt is never inferred from a
            // nil environment, and the App retains that operation's owner.
            struct Failure:Encodable {let message:String;let workerStopped:Bool?;let cancelled:Bool;let snapshotID:UUID}
            try? LaTeXDigest.encode(Failure(message:error.localizedDescription,
                workerStopped:(error as? LaTeXEngineFailure)?.workerStopped,
                cancelled:context.cancellation.isCancelled || error is CancellationError,
                snapshotID:snapshot.id)).write(to:directory.appendingPathComponent("NativePreparationFailure.json"),options:.atomic)
            throw error
        }
    }
    public func installToolchain(project:LaTeXHostProject,profile:String,context:ToolContext,binding:RuntimeAuthorityBinding?) async throws {
        // Keep old serialized callers readable without silently interpreting
        // a request for a full distribution as a successful partial install.
        throw LaTeXError.invalidOperation("排版工具已改为按项目自动准备，请重新执行排版或准备。 / Typesetting tools are now prepared for the project. Run typeset or prepare again without an installation profile.")
    }
    public func discoverableToolNames(context:ToolContext) async -> Set<String> {
        guard installed,(try? await hooks.verify(context)) != nil,!context.temporaryReadOnly,!context.publicWebOnly else{return []}
        var names=LaTeXHostTools.names
        if let ceiling=context.allowedToolNames {names.formIntersection(ceiling)}
        if let frozen=context.frozenEffectiveCatalogNames {names.formIntersection(frozen)}
        return names
    }
    public func invalidateCapabilities(environmentID:String) {capabilities.removeValue(forKey:"native")}
    private struct CapabilitySnapshot:LaTeXEngineRunning {
        let values:[LaTeXEngineCapability]
        func capabilities() async -> [LaTeXEngineCapability] {values}
        func run(_ request:LaTeXEngineRequest,progress:@escaping @Sendable (String)->Void) async throws -> LaTeXEngineOutput {throw LaTeXError.unavailable("Prepare this operation in its own resolved execution environment.")}
    }
}

private final class LaTeXPreparationProgressSequence:@unchecked Sendable {
    private let lock=NSLock()
    private var sequence:UInt64=0
    func next(_ value:LaTeXPreparationProgress)->LaTeXPreparationProgress {
        lock.withLock {sequence += 1;var result=value;result.sequence=sequence;return result}
    }
}

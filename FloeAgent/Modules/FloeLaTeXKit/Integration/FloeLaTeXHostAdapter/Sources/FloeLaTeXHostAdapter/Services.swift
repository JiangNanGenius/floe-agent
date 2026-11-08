// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools
import FloeExecution
import FloeEnvironments
import FloeLaTeXCore
import FloeLaTeXEngine

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
    public init(verify:@escaping @MainActor @Sendable (ToolContext) async throws -> Void,
                acquire:@escaping @MainActor @Sendable (UUID,ToolContext,Bool) async throws -> LaTeXHostProject,
                create:@escaping @MainActor @Sendable (String,String,ToolContext) async throws -> LaTeXHostProject,
                publish:@escaping @MainActor @Sendable (URL,LaTeXHostProject,ToolContext) async throws -> ToolExecutionOutput,
                didChange:@escaping @MainActor @Sendable (UUID,ToolContext) async throws -> Void,
                authorizeInstallation:@escaping @MainActor @Sendable (ToolContext) async throws -> Void = {_ in throw LaTeXError.unavailable("This task has not enabled toolchain installation.")}) {
        self.verify=verify;self.acquire=acquire;self.create=create;self.publish=publish;self.didChange=didChange
        self.authorizeInstallation=authorizeInstallation
    }
}

/// One App-owned instance shared by every editor and model invocation. Only
/// capability facts are cached: a prior call's grant/context/transport is
/// never reused to execute a later model or native-UI call.
@MainActor public final class LaTeXHostServices:LaTeXHostAccess {
    public let builds:LaTeXBuildService
    public let jobs:BackgroundJobService
    public let environments:EnvironmentRegistry
    public let registry:ToolRunnerRegistry
    private let hooks:LaTeXHostHooks
    private var installed=false
    private var capabilities=[String:[LaTeXEngineCapability]]()
    public init(cacheRoot:URL,jobs:BackgroundJobService,environments:EnvironmentRegistry,registry:ToolRunnerRegistry = .shared,hooks:LaTeXHostHooks) throws {
        builds=try .init(cacheRoot:cacheRoot);self.jobs=jobs;self.environments=environments;self.registry=registry;self.hooks=hooks
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
        guard (try? await verify(context)) != nil,let id=context.environmentID,let values=capabilities[id] else{return nil}
        return CapabilitySnapshot(values:values)
    }
    public func prepareEngine(project:LaTeXHostProject,context:ToolContext,binding:RuntimeAuthorityBinding?) async throws -> (any LaTeXEngineRunning)? {
        try await verify(context)
        let transport=try await LaTeXShellTransport.create(context:context,binding:binding,jobs:jobs,environments:environments,lifetime:project,registry:registry,validateOwner:{[hooks] context in try await hooks.verify(context)})
        let qualification=try await LaTeXLinuxEngine.probe(transport:transport)
        let engine=try LaTeXLinuxEngine(qualification:qualification,transport:transport)
        capabilities[qualification.environmentID]=await engine.capabilities()
        return engine
    }
    public func cachedCapabilities(environmentID:String)->[LaTeXEngineCapability] {capabilities[environmentID] ?? []}
    public func installToolchain(project:LaTeXHostProject,profile:String,context:ToolContext,binding:RuntimeAuthorityBinding?) async throws {
        try await verify(context)
        try await hooks.authorizeInstallation(context)
        guard ["standard","full"].contains(profile) else {throw LaTeXError.invalidOperation("Unknown toolchain profile.")}
        let transport=try await LaTeXShellTransport.create(context:context,binding:binding,jobs:jobs,environments:environments,lifetime:project,registry:registry,validateOwner:{[hooks] context in try await hooks.verify(context)})
        // Fixed Debian package identities in the user's resolved Linux layer.
        // No arbitrary URL, host executable, installer alias or native plugin.
        let packages=profile=="full" ? "texlive-full":"texlive-latex-base texlive-latex-recommended texlive-latex-extra texlive-fonts-recommended texlive-xetex texlive-luatex texlive-lang-chinese texlive-science texlive-pictures biber latexmk"
        let script="""
        set -eu
        # Package scripts run in Linux, whose temporary directories and
        # locale must not inherit native App container paths or locale ids.
        export TMPDIR=/tmp TMP=/tmp TEMP=/tmp LANG=C.UTF-8 LC_ALL=C.UTF-8
        command -v apt-get >/dev/null || { echo 'Use the selected Linux distribution package manager to install TeX Live, Biber, bubblewrap and Python 3.' >&2; exit 64; }
        if [ "$(id -u)" = 0 ]; then privilege=''; else command -v sudo >/dev/null; privilege='sudo -n'; fi
        $privilege env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update
        $privilege env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends python3 bubblewrap poppler-utils chktex \(packages)
        $privilege apt-get clean
        """
        let output=try await transport.run(script:script,progress:{_ in})
        guard output.workerStopped else {throw LaTeXEngineFailure("Toolchain installation did not confirm processor exit.",workerStopped:false)}
        guard output.exitStatus==0 else {throw LaTeXEngineFailure("Toolchain installation failed. Open this task's saved job log to retry.",messages:[String(output.stdout.suffix(16000))])}
        if let id=context.environmentID {capabilities.removeValue(forKey:id)}
    }
    public func discoverableToolNames(context:ToolContext) async -> Set<String> {
        guard installed,(try? await hooks.verify(context)) != nil,!context.temporaryReadOnly,!context.publicWebOnly else{return []}
        var names=LaTeXHostTools.names
        if let ceiling=context.allowedToolNames {names.formIntersection(ceiling)}
        if let frozen=context.frozenEffectiveCatalogNames {names.formIntersection(frozen)}
        return names
    }
    public func invalidateCapabilities(environmentID:String) {capabilities.removeValue(forKey:environmentID)}
    private struct CapabilitySnapshot:LaTeXEngineRunning {
        let values:[LaTeXEngineCapability]
        func capabilities() async -> [LaTeXEngineCapability] {values}
        func run(_ request:LaTeXEngineRequest,progress:@escaping @Sendable (String)->Void) async throws -> LaTeXEngineOutput {throw LaTeXError.unavailable("Prepare this operation in its own resolved execution environment.")}
    }
}

// FloeExecution — Shell tool registration.
// Dual-registration seam (descriptor + runner) for exec.shell, shell.* and the
// history-only apt compatibility shim. The app injects the resolved Linux guest
// service; an unavailable backend still registers exec.shell so the catalog
// honestly reports a failed engine instead of hiding the capability.
//
// The retired signed-WASM package tool is no longer constructed: signed WASI capability
// management stays available in Settings through SignedWasmCapabilityStore,
// but ``wasm.packages`` is a fenced historical name with no model runner.

import Foundation
import FloeTools

/// Registers the local shell, interactive session and package tools.
@discardableResult
public func registerShellTools(
    registry: ToolRunnerRegistry = .shared,
    shell: LocalShellService,
    sessions: ShellSessionCenter,
    pythonInstaller: ManagedPythonInstallService? = nil,
    capabilityInstaller: CapabilityInstaller? = nil,
    dependencyGate: (any SkillDependencyInvocationGating)? = nil,
    configurationProvider: (any SkillProcessConfigurationProviding)? = nil
) -> Bool {
    ToolCatalog.register(LocalShellTool.self)
    registry.register(LocalShellTool(shell: shell, pythonInstaller: pythonInstaller, dependencyGate: dependencyGate, configurationProvider: configurationProvider))

    ToolCatalog.register(ShellOpenTool.self)
    ToolCatalog.register(ShellExchangeTool.self)
    ToolCatalog.register(ShellCloseTool.self)
    ToolCatalog.register(ShellSignalTool.self)
    registry.register(ShellOpenTool(center: sessions, configurationProvider: configurationProvider, dependencyGate: dependencyGate))
    registry.register(ShellExchangeTool(center: sessions))
    registry.register(ShellCloseTool(center: sessions))
    registry.register(ShellSignalTool(center: sessions))

    if let capabilityInstaller {
        ToolCatalog.register(ManagedPackageTool.self, compatibilityOnly: true)
        registry.register(ManagedPackageTool(installer: capabilityInstaller), compatibilityOnly: true)
    }
    return true
}

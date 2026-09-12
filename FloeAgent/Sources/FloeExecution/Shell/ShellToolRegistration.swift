// FloeExecution — Shell tool registration.
// Dual-registration seam (descriptor + runner) for exec.shell, shell.* and
// the apt capability tool. The app injects the real ios_system-backed
// service; an unavailable backend still registers exec.shell so the catalog
// honestly reports a failed engine instead of hiding the capability.

import Foundation
import FloeTools

/// Registers the local shell, interactive session and capability tools.
@discardableResult
public func registerShellTools(
    registry: ToolRunnerRegistry = .shared,
    shell: LocalShellService,
    sessions: ShellSessionCenter,
    pythonInstaller: ManagedPythonInstallService? = nil,
    capabilityInstaller: CapabilityInstaller? = nil
) -> Bool {
    ToolCatalog.register(LocalShellTool.self)
    registry.register(LocalShellTool(shell: shell, pythonInstaller: pythonInstaller))

    ToolCatalog.register(ShellOpenTool.self)
    ToolCatalog.register(ShellExchangeTool.self)
    ToolCatalog.register(ShellCloseTool.self)
    ToolCatalog.register(ShellSignalTool.self)
    registry.register(ShellOpenTool(center: sessions))
    registry.register(ShellExchangeTool(center: sessions))
    registry.register(ShellCloseTool(center: sessions))
    registry.register(ShellSignalTool(center: sessions))

    if let capabilityInstaller {
        ToolCatalog.register(ManagedPackageTool.self)
        registry.register(ManagedPackageTool(installer: capabilityInstaller))
    }
    return true
}

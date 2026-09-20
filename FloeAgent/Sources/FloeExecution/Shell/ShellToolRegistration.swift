// FloeExecution — Shell tool registration.
// Dual-registration seam (descriptor + runner) for exec.shell, shell.*, the
// per-family package entries (python.packages, wasm.packages) and a
// history-only apt compatibility shim. The app injects the real ios_system-backed
// service; an unavailable backend still registers exec.shell so the catalog
// honestly reports a failed engine instead of hiding the capability.

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
    wasmStore: SignedWasmCapabilityStore? = nil
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
        ToolCatalog.register(PythonPackageTool.self)
        registry.register(PythonPackageTool(installer: capabilityInstaller))
        ToolCatalog.register(ManagedPackageTool.self, compatibilityOnly: true)
        registry.register(ManagedPackageTool(installer: capabilityInstaller), compatibilityOnly: true)
    }
    if let wasmStore {
        ToolCatalog.register(WasmPackageTool.self)
        registry.register(WasmPackageTool(store: wasmStore))
    }
    return true
}

// FloeAndroidShellTools — Android platform mirror of the ORIGINAL
// FloeAgent/Sources/FloeExecution/Shell/ShellToolRegistration.swift.
// Deltas (full list in the private SOURCE_READY.json):
//   R1 (installer surface removed): the `pythonInstaller`,
//      `capabilityInstaller` and `wasmStore` parameters and the
//      ManagedPackageTool/WasmPackageTool registrations are REMOVED. On
//      Android there is no managed host Python installer to duplicate, and
//      package installs ride the Linux userland itself (python3 -m pip /
//      npm / apt in the command). exec.shell remains the SOLE model code
//      execution path; no exec.localPython/javascript/host aliases are
//      re-registered here.
//   R2: the descriptor/runner dual registration for exec.shell and the
//      shell.* family, and the honest "an unavailable backend still
//      registers exec.shell so the catalog reports a failed engine
//      instead of hiding the capability" principle, are byte-equal to the
//      original.
//
// FloeExecution — Shell tool registration.
// Dual-registration seam (descriptor + runner) for exec.shell and shell.*.
// The app injects the resolved Linux engine service; an unavailable
// backend still registers exec.shell so the catalog honestly reports a
// failed engine instead of hiding the capability.

import Foundation
import FloeTools

/// Registers the local shell and interactive session tools on Android.
@discardableResult
public func registerShellTools(
    registry: ToolRunnerRegistry = .shared,
    shell: LocalShellService,
    sessions: ShellSessionCenter,
    includeInteractiveSessions: Bool = true
) -> Bool {
    ToolCatalog.register(LocalShellTool.self)
    registry.register(LocalShellTool(shell: shell))

    guard includeInteractiveSessions else { return true }
    ToolCatalog.register(ShellOpenTool.self)
    ToolCatalog.register(ShellExchangeTool.self)
    ToolCatalog.register(ShellCloseTool.self)
    ToolCatalog.register(ShellSignalTool.self)
    registry.register(ShellOpenTool(center: sessions))
    registry.register(ShellExchangeTool(center: sessions))
    registry.register(ShellCloseTool(center: sessions))
    registry.register(ShellSignalTool(center: sessions))
    return true
}

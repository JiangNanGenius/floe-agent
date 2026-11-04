// FloeApp — guest runtime assembly (ARM64 Linux backend).
//
// Builds the app's one internal guest-routed `LocalPythonService`.
// Dependencies are prepared for the resolved ARM64 environment; retired
// native and RISC-V installations are not migrated or executed.

import Foundation
import FloeCore
import FloeExecution
import FloeTools

enum LocalPythonServiceFactory {
    /// Builds the app's one `LocalPythonService`: every request routes into
    /// the task environment's ARM64 Linux guest. Returns nil only when no
    /// Linux backend exists in this build. This is an internal business-service
    /// adapter; model code uses exec.shell, not a separate Python tool.
    static func make(
        linuxGuests: LinuxGuestCommandService?,
        prepareLinux: LinuxPreparationHandler? = nil
    ) -> LocalPythonService? {
        guard let linuxGuests else { return nil }
        return LocalPythonService(version: "Python 3 (Linux guest)") { request, cancellation in
            guard let environmentID = request.pythonContext?.environmentID,
                  !environmentID.isEmpty else {
                return .jsException(
                    message: "Local Python runs inside a task's Linux environment; no environment was selected",
                    stdout: ""
                )
            }
            return await GuestPythonRuntime.run(
                request,
                environmentID: environmentID,
                guests: linuxGuests,
                controller: linuxGuests,
                onColdStart: { _ in },
                prepareLinux: prepareLinux,
                cancellation: cancellation
            )
        }
    }
}

// FloeExecution — guest Python runtime (TinyEMU Linux backend).
//
// Phase 2: the bundled in-process CPython left the app. Every local Python
// request runs inside the task environment's TinyEMU Linux guest on the
// shared venv (`LinuxGuestPythonProvisioner`): exec.localPython, the shell
// `python3` command, managed pip installs and workspace archive helpers all
// share one interpreter, venv, cwd view and file view per environment.
// A request whose environment is not a Linux environment fails honestly —
// there is no native interpreter left to fall back to.
//
// printJSON contract: the guest has no injected builtins, so the runner
// prepends a tiny prelude that frames each printJSON payload as a sentinel
// line on stdout. The last sentinel becomes `resultJSON` and sentinel lines
// are stripped from visible stdout, matching the retired native bridge.

import Foundation
import FloeCore
import FloeTools

public enum GuestPythonRuntime {
    /// Sentinel prefix framing a printJSON payload line on stdout.
    private static let resultMarker = "\u{1e}FLOE-RESULT "

    /// One `exec.localPython`-style request inside the environment's Linux
    /// guest. The interpreter is the environment's single shared venv
    /// (`/floe/env/python/venv`), which the shell, the pip command, the
    /// managed installer and the package UI all resolve, so a package is
    /// installed once. Host paths in the execution context (working
    /// directory, environment values) are mapped through the environment's
    /// 9p shares before they reach the guest; a value that names a host path
    /// outside the shares is dropped, never forwarded verbatim.
    public static func run(
        _ request: ScriptExecutionRequest,
        environmentID: String,
        guests: any LinuxCommandRunning,
        controller: (any LinuxGuestControlling)?,
        onColdStart: (@Sendable (String) async -> Void)? = nil,
        cancellation: CancellationToken?
    ) async -> ScriptExecutionOutcome {
        if cancellation?.isCancelled == true { return .cancelled }
        do {
            try await LinuxGuestActivator.ensureRunning(
                environmentID: environmentID,
                guests: guests,
                controller: controller,
                onColdStart: onColdStart
            )
        } catch let error as LinuxGuestError {
            if case .notOwned = error {
                // The selected environment is not a Linux guest: say how to
                // get Python back instead of leaking registry jargon.
                return .jsException(message: ManagedPythonInstallService.linuxRequiredMessage, stdout: "")
            }
            return .jsException(message: error.localizedDescription, stdout: "")
        } catch {
            return .jsException(message: error.localizedDescription, stdout: "")
        }
        let python: LinuxGuestPythonEnvironment
        do {
            python = try await LinuxGuestPythonProvisioner.shared.ensure(
                environmentID: environmentID,
                runner: guests,
                cancellation: cancellation
            )
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .jsException(message: error.localizedDescription, stdout: "")
        }
        if cancellation?.isCancelled == true { return .cancelled }
        let pathMap = await (guests as? any LinuxGuestPathMapping)?.linuxGuestPathMap(environmentID: environmentID)

        var script = Self.prelude
        if let inputJSON = request.inputJSON {
            script += "input = _floe_json.loads(" + pyLiteral(inputJSON) + ")\n"
        }
        script += request.script
        let timeout = max(0.05, min(request.timeout, 600))

        var variables = guestVariables(
            from: request.pythonContext?.environment ?? [:],
            environmentID: environmentID,
            python: python,
            pathMap: pathMap
        )
        variables["FLOE_PYTHON_PACKAGE_TARGET"] = python.sitePackages

        var argv: [String] = ["env"]
        argv.append(contentsOf: LinuxGuestEnvironmentEncoding.argv(variables) ?? [])
        argv.append(contentsOf: [python.pythonPath, "-c", script])
        argv.append(contentsOf: request.pythonContext?.arguments ?? [])

        let workingDirectory: String?
        if let hostCwd = request.pythonContext?.workingDirectory, !hostCwd.isEmpty {
            guard let mapped = pathMap?.guestPath(forHostPath: hostCwd) else {
                return .jsException(
                    message: "The working directory is outside this environment's shared folders; run from the task workspace",
                    stdout: ""
                )
            }
            workingDirectory = mapped
        } else {
            workingDirectory = nil
        }

        let started = Date()
        do {
            let result = try await guests.run(
                environmentID: environmentID,
                argv: argv,
                workingDirectory: workingDirectory,
                standardInput: request.pythonContext?.standardInput,
                timeout: timeout,
                maxOutputBytes: request.maxOutputBytes,
                cancellation: cancellation
            )
            let durationMs = Int(Date().timeIntervalSince(started) * 1000)
            let split = Self.splitResultMarkers(from: result.stdout)
            if result.exitCode == 0 {
                return .ok(
                    resultJSON: split.resultJSON,
                    stdout: split.stdout,
                    stderr: result.stderr,
                    truncated: false,
                    stderrTruncated: false,
                    durationMs: durationMs
                )
            }
            return .jsException(
                message: result.stderr.isEmpty ? "python3 exited with \(result.exitCode)" : result.stderr,
                stdout: split.stdout
            )
        } catch FloeError.cancelled {
            return .cancelled
        } catch let error as LinuxGuestError {
            if case .timedOut = error {
                return .timedOut(afterMs: Int(timeout * 1000), partialStdout: "")
            }
            return .jsException(message: error.localizedDescription, stdout: "")
        } catch {
            return .jsException(message: error.localizedDescription, stdout: "")
        }
    }

    /// printJSON shim plus the JSON module the input binding uses.
    public static let prelude = """
    import json as _floe_json, sys as _floe_sys
    def printJSON(_floe_value):
        _floe_sys.stdout.write('\\x1eFLOE-RESULT ' + _floe_json.dumps(_floe_value, ensure_ascii=False) + '\\n')
        _floe_sys.stdout.flush()

    """

    /// Guest environment for one run. Caller-supplied values pass through the
    /// 9p path map; absolute host paths that do not map are dropped so the
    /// guest never receives a macOS path. Interpreter-owned variables
    /// (venv/PATH/HOME/TMPDIR/FLOE_*) are set here, never inherited.
    static func guestVariables(
        from incoming: [String: String],
        environmentID: String,
        python: LinuxGuestPythonEnvironment,
        pathMap: LinuxGuestPathMap?
    ) -> [String: String] {
        // Keys whose host values are always replaced by guest-owned ones.
        let hostOnlyKeys: Set<String> = [
            "PATH", "HOME", "TMPDIR", "PYTHONPATH", "PYTHONHOME", "VIRTUAL_ENV",
            "NODE_PATH", "PNPM_HOME", "PWD", "PYTHONSTARTUP", "PYTHONUSERBASE"
        ]
        var variables: [String: String] = [:]
        for (key, value) in incoming where !hostOnlyKeys.contains(key) && !key.hasPrefix("npm_config_") {
            if value.hasPrefix("/") {
                // A path value crosses only when it maps into the shares.
                if let mapped = pathMap?.guestPath(forHostPath: value) {
                    variables[key] = mapped
                }
            } else {
                variables[key] = value
            }
        }
        variables["VIRTUAL_ENV"] = python.venvPath
        variables["PYTHONUNBUFFERED"] = "1"
        variables["FLOE_ENVIRONMENT_ID"] = environmentID
        variables["PATH"] = python.venvPath + "/bin:"
            + LinuxGuestNodeEnvironment.guestBin + ":"
            + LinuxGuestNodeEnvironment.defaultGuestPath
        if let environmentRoot = pathMap?.environmentGuestRoot {
            variables["FLOE_PYTHON_WRITABLE_LAYER"] = environmentRoot
            variables["HOME"] = environmentRoot + "/home"
            variables["TMPDIR"] = environmentRoot + "/tmp"
        }
        return variables
    }

    /// Extracts the last printJSON sentinel; sentinel lines never reach the
    /// visible stdout.
    static func splitResultMarkers(from stdout: String) -> (stdout: String, resultJSON: String?) {
        guard stdout.contains(resultMarker) else { return (stdout, nil) }
        var visible: [String] = []
        var result: String?
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(resultMarker) {
                result = String(line.dropFirst(resultMarker.count))
            } else {
                visible.append(String(line))
            }
        }
        return (visible.joined(separator: "\n"), result)
    }

    /// A Python string literal for a JSON document (the native bridge bound
    /// the same `input` name, so guest scripts keep the documented contract).
    private static func pyLiteral(_ json: String) -> String {
        var escaped = json
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "'''", with: "\\'\\'\\'")
        escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
        return "'''" + escaped + "'''"
    }
}

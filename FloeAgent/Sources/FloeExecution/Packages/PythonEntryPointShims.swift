// FloeExecution — console_scripts shims for managed Python packages.
// After a managed install, any [console_scripts] entry point becomes a
// command in the shell PATH by writing a tiny shim that runs the module
// through the bundled CPython (`python3` itself is the Floe replacement
// command). Pure data + script only: no native entry points exist.

import Foundation
import FloeCore
import FloeTools

public struct PythonEntryPointShims: Sendable {
    public struct Shim: Sendable, Equatable {
        public var name: String
        public var module: String
        public var callable: String
        public var distribution: String
    }

    private let python: LocalPythonService

    public init(python: LocalPythonService) {
        self.python = python
    }

    /// Enumerates console_scripts entry points of every managed distribution.
    public func entryPoints() async -> [Shim] {
        let script = """
        import importlib.metadata as _metadata, sys, os
        _target = next((p for p in sys.path if p.endswith('PythonPackages')), None)
        if not _target or not os.path.isdir(_target):
            raise SystemExit(0)
        for _dist in _metadata.distributions(path=[_target]):
            try:
                _eps = _dist.entry_points
            except Exception:
                continue
            for _ep in _eps:
                if _ep.group != 'console_scripts':
                    continue
                _value = _ep.value
                if ':' not in _value:
                    continue
                _module, _callable = _ep.module, _ep.attr
                print('|'.join([_ep.name, _module.strip(), _callable.strip(), _dist.metadata['Name'] or '']))
        """
        let request = ScriptExecutionRequest(script: script, timeout: 20, maxOutputBytes: 64 * 1024)
        guard case .ok(_, let stdout, _, _, _, _) = await python.run(request, cancellation: nil) else { return [] }
        return stdout.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
            return Shim(name: parts[0], module: parts[1], callable: parts[2], distribution: parts[3])
        }
    }

    /// Writes (or refreshes) shim scripts in `binDirectory` and returns the
    /// installed shims. Names are restricted to POSIX command characters.
    @discardableResult
    public func refresh(in binDirectory: URL) async -> [Shim] {
        let shims = await entryPoints()
        try? FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        var written: [Shim] = []
        for shim in shims {
            guard shim.name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil,
                  shim.module.range(of: #"^[A-Za-z0-9_.]+$"#, options: .regularExpression) != nil,
                  shim.callable.range(of: #"^[A-Za-z0-9_.]+$"#, options: .regularExpression) != nil else {
                continue
            }
            let body = """
            #!/bin/sh
            # Floe managed entry point: \(shim.distribution) (\(shim.name))
            exec python3 -c 'import sys; from \(shim.module) import \(shim.callable.split(separator: ".").first ?? "main") as _floe_entry; sys.exit(_floe_entry())' "$@"
            """
            let url = binDirectory.appendingPathComponent(shim.name)
            do {
                try Data(body.utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                written.append(shim)
            } catch {
                FloeLogger(category: .tools).error("entryPointShimWriteFailed name=\(shim.name) error=\(error.localizedDescription)")
            }
        }
        return written
    }
}

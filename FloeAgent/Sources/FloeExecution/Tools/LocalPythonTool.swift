// FloeExecution — exec.localPython agent tool.

import Foundation
import Crypto
import FloeCore
import FloeTools

/// Runs bounded Python inside the app sandbox. This is intentionally marked
/// side-effecting because CPython shares the app process and container. The
/// approval policy may allow ordinary sandboxed scripts automatically, while
/// managed package requests always pass through the package-review backend.
public struct LocalPythonTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var script: String
        public var inputJSON: String?
        public var timeout: Double?
        public var maxOutputBytes: Int?
        /// Package specs installed through Floe's managed, pure-Python-only
        /// pip path before the script runs.
        public var packages: [String]?
        /// Familiar declarative spelling for the same reviewed path, for
        /// example `pip install marko==2.2.0`. It is parsed, not shell-run.
        public var pipCommand: String?
        /// Why these packages are necessary for the user's requested result.
        /// This is review evidence, not an authority escalation.
        public var packagePurpose: String?
        /// Capabilities the task actually needs (for example pdf.read,
        /// image.render, data.transform). The package reviewer compares these
        /// to static source evidence and the user's goal.
        public var packageCapabilities: [String]?

        public init(
            script: String,
            inputJSON: String? = nil,
            timeout: Double? = nil,
            maxOutputBytes: Int? = nil,
            packages: [String]? = nil,
            pipCommand: String? = nil,
            packagePurpose: String? = nil,
            packageCapabilities: [String]? = nil
        ) {
            self.script = script
            self.inputJSON = inputJSON
            self.timeout = timeout
            self.maxOutputBytes = maxOutputBytes
            self.packages = packages
            self.pipCommand = pipCommand
            self.packagePurpose = packagePurpose
            self.packageCapabilities = packageCapabilities
        }
    }

    public static let name = "exec.localPython"
    public static let toolDescription =
        "Run Python 3.13 privately on this device for scripts, files, JSON, SQLite, XML, archives, dates, async work and data processing. Floe bundles the compatible iOS standard-library extensions, including asyncio, bisect, heapq, pickle, zoneinfo, uuid, statistics, csv, json, sqlite3, mmap, bz2, lzma, ctypes, xml.etree.ElementTree and pyexpat. iOS does not provide desktop shell/account modules such as curses, readline, grp, pwd, spwd, syslog or multiprocessing, so do not request them. A task may request a package with `packages` or a declarative `pipCommand` such as `pip install marko==2.2.0`; include `packagePurpose` and only the capabilities needed for the user's current request. Floe reviews the purpose before downloading and installs only compatible pure-Python packages. Do not invoke pip, ensurepip, subprocess or shell installers inside `script`. For numpy, pandas, scipy, matplotlib or another binary scientific package, use the browser-based Pyodide WebAssembly route: create a workspace HTML result, load Pyodide over public HTTPS, run the package there, and exchange bounded input/results as JSON. Never claim a native package was installed when it ran in WebAssembly. PyStata requires a licensed Stata installation and pyreadstat requires native extensions; use exec.localNumerical for bounded R/Stata-compatible statistics or an approved configured remote host for the full runtimes. PDF, image, document, batch-processing and data-analysis tasks are expected uses when they remain within the user's request."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "script": {"type": "string", "description": "Python source (max 64 KiB)"},
        "inputJSON": {"type": "string", "description": "Optional JSON value exposed as `input`"},
        "timeout": {"type": "number", "description": "Cooperative Python bytecode deadline in seconds (default 10, max 30)"},
        "maxOutputBytes": {"type": "integer", "description": "Combined output cap (default 65536, max 262144)"}
        ,"packages": {
          "type": "array",
          "maxItems": 16,
          "items": {"type": "string", "description": "PyPI name or exact name==version; no URLs, paths, VCS, or native wheels"},
          "description": "Managed pure-Python package installs. All entries are reviewed, including trusted-catalog packages."
        },
        "pipCommand": {"type": "string", "description": "Declarative `pip install package...` spelling for the same reviewed managed installer; no flags, URLs, paths, shell syntax, or VCS sources"},
        "packagePurpose": {"type": "string", "description": "Concrete reason these packages are necessary for the user's requested result"},
        "packageCapabilities": {"type": "array", "maxItems": 16, "items": {"type": "string"}, "description": "Narrow required capabilities such as pdf.read, image.render, svg.edit or data.transform"}
      },
      "required": ["script"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.executesLocalCode]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    static let maxScriptBytes = 64 * 1024
    static let defaultTimeout: TimeInterval = 10
    static let maxTimeout: TimeInterval = 30
    static let defaultMaxOutputBytes = 64 * 1024
    static let maxOutputBytesCap = 256 * 1024

    private let service: LocalPythonService

    public init(service: LocalPythonService) {
        self.service = service
    }

    public func validate(_ args: Arguments) throws {
        if args.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FloeError.validationFailed("script must not be empty")
        }
        if Data(args.script.utf8).count > Self.maxScriptBytes {
            throw FloeError.validationFailed("script exceeds the \(Self.maxScriptBytes)-byte limit")
        }
        if let timeout = args.timeout, timeout <= 0 {
            throw FloeError.validationFailed("timeout must be > 0")
        }
        if let maxOutputBytes = args.maxOutputBytes, maxOutputBytes <= 0 {
            throw FloeError.validationFailed("maxOutputBytes must be > 0")
        }
        if let inputJSON = args.inputJSON,
           (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) == nil {
            throw FloeError.validationFailed("inputJSON must contain valid JSON")
        }
        let normalizedScript = args.script.lowercased()
        let forbiddenInstallMarkers = [
            "import pip", "from pip", "ensurepip", "-m pip", "pip._internal",
            "subprocess", "os.system("
        ]
        if forbiddenInstallMarkers.contains(where: normalizedScript.contains) {
            throw FloeError.validationFailed(
                "Put a direct `pip install package...` request in `pipCommand` (or use `packages`) so Floe can review it before download; pip, subprocess, and shell installation inside `script` are unavailable"
            )
        }
        let packages = try Self.requestedPackages(args)
        guard packages.count <= 16 else {
            throw FloeError.validationFailed("packages accepts at most 16 top-level entries per call")
        }
        for package in packages {
            try ManagedPythonPackageSpecParser.validate(package)
        }
        if !packages.isEmpty {
            guard let purpose = args.packagePurpose?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !purpose.isEmpty else {
                throw FloeError.validationFailed("packagePurpose is required when packages are requested")
            }
            guard purpose.utf8.count <= 1_024 else {
                throw FloeError.validationFailed("packagePurpose exceeds 1024 bytes")
            }
            let capabilities = args.packageCapabilities ?? []
            guard !capabilities.isEmpty, capabilities.count <= 16 else {
                throw FloeError.validationFailed("packageCapabilities must declare 1-16 required capabilities")
            }
            let capabilityPattern = try NSRegularExpression(pattern: #"^[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)+$"#)
            for capability in capabilities {
                let range = NSRange(capability.startIndex..<capability.endIndex, in: capability)
                guard capabilityPattern.firstMatch(in: capability, range: range)?.range == range else {
                    throw FloeError.validationFailed("packageCapabilities must use dotted lowercase identifiers")
                }
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        var packageOutput = ""
        let packages = try Self.requestedPackages(args)
        if !packages.isEmpty {
            let encoded = try JSONEncoder().encode(packages)
            let packageJSON = String(decoding: encoded, as: UTF8.self)
            let installer = """
                import json, sys, os, shutil, tempfile
                from pip._internal.cli.main import main as _floe_pip
                _target = next((p for p in sys.path if p.endswith('PythonPackages')), None)
                if not _target:
                    raise RuntimeError('Managed package directory is unavailable')
                _specs = json.loads(\(String(reflecting: packageJSON)))
                _parent = os.path.dirname(_target)
                os.makedirs(_parent, exist_ok=True)
                os.makedirs(_target, exist_ok=True)
                _stage = tempfile.mkdtemp(prefix='floe-pip-stage-', dir=_parent)
                _backup = tempfile.mkdtemp(prefix='floe-pip-backup-', dir=_parent)
                _cache = os.path.join(_parent, 'PythonPackageCache')
                os.makedirs(_cache, exist_ok=True)
                _args = ['install', '--disable-pip-version-check', '--no-input',
                         '--only-binary=:all:', '--platform=any', '--implementation=py',
                         '--abi=none', '--cache-dir', _cache, '--target', _stage] + _specs
                try:
                    _code = _floe_pip(_args)
                    if _code != 0:
                        raise RuntimeError(f'Managed package install failed with exit code {_code}')
                    _native = []
                    for _root, _dirs, _files in os.walk(_stage):
                        for _file in _files:
                            if _file.lower().endswith(('.so', '.dylib', '.a', '.framework', '.bundle')):
                                _native.append(os.path.join(_root, _file))
                    if _native:
                        raise RuntimeError('Managed package contains prohibited native artifacts')
                    _distributions = sorted(
                        _name[:-10] for _name in os.listdir(_stage)
                        if _name.lower().endswith('.dist-info')
                    )
                    _installed = []
                    try:
                        for _name in os.listdir(_stage):
                            _source = os.path.join(_stage, _name)
                            _destination = os.path.join(_target, _name)
                            if os.path.lexists(_destination):
                                shutil.move(_destination, os.path.join(_backup, _name))
                            shutil.move(_source, _destination)
                            _installed.append(_name)
                    except BaseException:
                        for _name in _installed:
                            _destination = os.path.join(_target, _name)
                            if os.path.isdir(_destination): shutil.rmtree(_destination, ignore_errors=True)
                            elif os.path.lexists(_destination): os.remove(_destination)
                        for _name in os.listdir(_backup):
                            shutil.move(os.path.join(_backup, _name), os.path.join(_target, _name))
                        raise
                    print('managedPackages=' + ','.join(_specs))
                    print('resolvedDistributions=' + ','.join(_distributions))
                finally:
                    shutil.rmtree(_stage, ignore_errors=True)
                    shutil.rmtree(_backup, ignore_errors=True)
                """
            let installRequest = ScriptExecutionRequest(
                script: installer,
                inputJSON: nil,
                timeout: Self.maxTimeout,
                maxOutputBytes: min(args.maxOutputBytes ?? Self.defaultMaxOutputBytes, Self.maxOutputBytesCap),
                allowsManagedPackageInstaller: true
            )
            let installOutcome = await service.run(installRequest, cancellation: context.cancellation)
            switch installOutcome {
            case .ok(_, let stdout, let stderr, _, _, _):
                packageOutput = stdout + (stderr.isEmpty ? "" : "\n" + stderr)
            case .jsException(let message, let stdout):
                return Self.output("status=packageInstallFailed\nerror=\(message)\n\(stdout)", exitStatus: 65)
            case .timedOut(let afterMs, let partialStdout):
                return Self.output("status=packageInstallTimedOut afterMs=\(afterMs)\n\(partialStdout)", exitStatus: 124)
            case .cancelled:
                throw FloeError.cancelled
            }
        }
        let request = ScriptExecutionRequest(
            script: args.script,
            inputJSON: args.inputJSON,
            timeout: min(args.timeout ?? Self.defaultTimeout, Self.maxTimeout),
            maxOutputBytes: min(args.maxOutputBytes ?? Self.defaultMaxOutputBytes, Self.maxOutputBytesCap)
        )
        let outcome = await service.run(request, cancellation: context.cancellation)
        switch outcome {
        case .ok(let resultJSON, let stdout, let stderr, let truncated, let stderrTruncated, let durationMs):
            var full = "status=ok durationMs=\(durationMs) truncated=\(truncated) stderrTruncated=\(stderrTruncated)"
            if let resultJSON { full += "\nresult=\(resultJSON)" }
            if !packageOutput.isEmpty { full += "\n--- managed packages ---\n\(packageOutput)" }
            full += "\n--- stdout ---\n\(stdout)"
            if !stderr.isEmpty { full += "\n--- stderr ---\n\(stderr)" }
            return Self.output(full, exitStatus: 0)
        case .jsException(let message, let stdout):
            return Self.output("status=exception\nerror=\(message)\n\(stdout)", exitStatus: 1)
        case .timedOut(let afterMs, let partialStdout):
            return Self.output("status=timedOut afterMs=\(afterMs)\n\(partialStdout)", exitStatus: 124)
        case .cancelled:
            throw FloeError.cancelled
        }
    }

    private static func requestedPackages(_ args: Arguments) throws -> [String] {
        var packages = args.packages ?? []
        packages.append(contentsOf: try ManagedPythonPackageSpecParser.parse(command: args.pipCommand))
        var seen = Set<String>()
        return packages.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}

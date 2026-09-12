// FloeApp — Floe replacement commands for the local shell.
// Policy-sensitive commands are re-implemented on Floe services and
// registered with ios_system's `replaceCommand`, so `ping`, `traceroute`,
// `dig`, `nc`, `python3`, `sha256sum` and the package commands run through
// exactly the same backends as the agent tools. A single C entry point
// dispatches on argv[0].

import Foundation
import Darwin
import FloeCore
import FloeExecution
import FloeTools

final class FloeShellCommandRegistry: @unchecked Sendable {
    struct ShellCommandContext: Sendable {
        var rootURL: URL
        var workingDirectory: URL
        var runID: UUID
        var cancellation: CancellationToken
    }

    typealias Handler = @Sendable (_ arguments: [String], _ stdout: UnsafeMutablePointer<FILE>?, _ stderr: UnsafeMutablePointer<FILE>?) async -> Int32

    static let shared = FloeShellCommandRegistry()

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var pythonCommandNames = Set<String>()
    @TaskLocal static var invocation: ShellCommandContext?
    @TaskLocal static var input: CommandInput?
    final class CommandInput: @unchecked Sendable {
        let stream: UnsafeMutablePointer<FILE>?
        init(_ source: UnsafeMutablePointer<FILE>?) {
            guard let source else { stream = nil; return }
            let fd = dup(fileno(source))
            stream = fd >= 0 ? fdopen(fd, "r") : nil
            if fd >= 0 && stream == nil { Darwin.close(fd) }
        }
        deinit { if let stream { fclose(stream) } }
        func read(cancellation: CancellationToken?) -> String? {
            guard let stream else { return "" }
            var data = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                if cancellation?.isCancelled == true { return nil }
                var descriptor = pollfd(fd: fileno(stream), events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 50)
                if ready < 0 { if errno == EINTR { continue }; return nil }
                if ready == 0 { continue }
                let count = Darwin.read(fileno(stream), &bytes, bytes.count)
                if count == 0 { return String(decoding: data, as: UTF8.self) }
                if count < 0 { if errno == EINTR { continue }; return nil }
                guard data.count + count <= 256 * 1024 else { return nil }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
    }
    private var contexts: [String: ShellCommandContext] = [:]
    private var activeInvocations: [String: [UUID: CancellationToken]] = [:]
    private var pythonStorage: LocalPythonService?
    private var installerStorage: CapabilityInstaller?
    private var wasmStorage: SignedWasmCapabilityStore?
    var wasm: SignedWasmCapabilityStore? { lock.withLock { wasmStorage } }

    var python: LocalPythonService? {
        lock.lock(); defer { lock.unlock() }
        return pythonStorage
    }

    var installer: CapabilityInstaller? {
        lock.lock(); defer { lock.unlock() }
        return installerStorage
    }

    var context: ShellCommandContext? { Self.invocation }

    func bind(sessionID: String, rootURL: URL, runID: UUID?, cancellation: CancellationToken?) {
        lock.withLock { contexts[sessionID] = ShellCommandContext(rootURL: rootURL, workingDirectory: rootURL, runID: runID ?? UUID(), cancellation: cancellation ?? CancellationToken()) }
    }
    func cancelCurrent(sessionID: String) {
        lock.withLock { activeInvocations[sessionID]?.values.forEach { $0.cancel() } }
    }
    func beginInvocation(sessionID: String, token: CancellationToken) -> UUID {
        let id = UUID()
        lock.withLock { activeInvocations[sessionID, default: [:]][id] = token }
        return id
    }
    func endInvocation(sessionID: String, id: UUID) {
        lock.withLock {
            activeInvocations[sessionID]?.removeValue(forKey: id)
            if activeInvocations[sessionID]?.isEmpty == true { activeInvocations.removeValue(forKey: sessionID) }
        }
    }
    func unbind(sessionID: String) {
        cancelCurrent(sessionID: sessionID)
        _ = lock.withLock { contexts.removeValue(forKey: sessionID) }
    }
    func context(sessionID: String) -> ShellCommandContext? { lock.withLock { contexts[sessionID] } }
    func configure(python: LocalPythonService?, installer: CapabilityInstaller?, wasm: SignedWasmCapabilityStore? = nil) {
        lock.withLock { self.pythonStorage = python; self.installerStorage = installer; self.wasmStorage = wasm }
    }

    func register(_ name: String, handler: @escaping Handler) {
        lock.lock()
        handlers[name] = handler
        lock.unlock()
        FloeShellRegisterCommand(name)
    }

    private static let nativeCommandNames: Set<String> = {
        guard let url = Bundle.main.url(forResource: "commandDictionary", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        return Set(dictionary.keys)
    }()

    func replacePythonCommands(_ entries: [PythonEntryPointShims.Shim]) {
        lock.withLock {
            for name in pythonCommandNames { handlers.removeValue(forKey: name) }
            pythonCommandNames.removeAll()
            for entry in entries where handlers[entry.name] == nil && !Self.nativeCommandNames.contains(entry.name) {
                guard entry.name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
                      entry.module.range(of: "^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*$", options: .regularExpression) != nil,
                      entry.callable.range(of: "^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*$", options: .regularExpression) != nil else { continue }
                handlers[entry.name] = { [weak self] arguments, stdout, stderr in
                    guard let python = self?.handler(for: "python3") else { return 127 }
                    let script = "import importlib,sys; _entry=importlib.import_module('\(entry.module)'); " + entry.callable.split(separator: ".").map { "_entry=getattr(_entry,'\($0)')" }.joined(separator: "; ") + "; sys.exit(_entry())"
                    return await python(["python3", "-c", script] + Array(arguments.dropFirst()), stdout, stderr)
                }
                pythonCommandNames.insert(entry.name)
                FloeShellRegisterCommand(entry.name)
            }
        }
    }

    func handler(for name: String) -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return handlers[name]
    }
}

@_cdecl("floe_shell_command_main")
public func floeShellCommandMain(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
    let rawName = argv?[0].map { String(cString: $0) } ?? "command"
    let name = rawName.split(separator: "/").last.map(String.init) ?? rawName
    guard let handler = FloeShellCommandRegistry.shared.handler(for: name) else {
        FloeShellWrite(FloeShellCurrentStderr(), "\(name): Floe has no local implementation\n")
        return 127
    }
    let arguments = (0..<Int(argc)).compactMap { index -> String? in
        argv?[index].map { String(cString: $0) }
    }
    let input = FloeShellCommandRegistry.CommandInput(FloeShellCurrentStdin())
    let sessionID = FloeShellCurrentSessionID() ?? ""
    var invocation = FloeShellCommandRegistry.shared.context(sessionID: sessionID)
    let parentCancellation = invocation?.cancellation
    let commandCancellation = CancellationToken()
    if parentCancellation?.isCancelled == true { commandCancellation.cancel() }
    invocation?.cancellation = commandCancellation
    let invocationID = FloeShellCommandRegistry.shared.beginInvocation(sessionID: sessionID, token: commandCancellation)
    if let directory = FloeShellCurrentWorkingDirectory(), let root = invocation?.rootURL.resolvingSymlinksInPath() {
        let url = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
        if url == root || url.path.hasPrefix(root.path + "/") { invocation?.workingDirectory = url }
    }
    let capturedInvocation = invocation
    let stdout = FloeShellCurrentStdout()
    let stderr = FloeShellCurrentStderr()

    final class Box: @unchecked Sendable {
        var code: Int32 = 1
        let stdout: UnsafeMutablePointer<FILE>?
        let stderr: UnsafeMutablePointer<FILE>?
        init(stdout: UnsafeMutablePointer<FILE>?, stderr: UnsafeMutablePointer<FILE>?) {
            func ownedStream(_ source: UnsafeMutablePointer<FILE>?) -> UnsafeMutablePointer<FILE>? {
                guard let source else { return nil }
                let fd = dup(fileno(source))
                guard fd >= 0 else { return nil }
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                guard let stream = fdopen(fd, "w") else { Darwin.close(fd); return nil }
                return stream
            }
            self.stdout = ownedStream(stdout)
            self.stderr = ownedStream(stderr)
        }
        deinit { if let stdout { fclose(stdout) }; if let stderr { fclose(stderr) } }
    }
    let box = Box(stdout: stdout, stderr: stderr)
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        defer { FloeShellCommandRegistry.shared.endInvocation(sessionID: sessionID, id: invocationID) }
        box.code = await FloeShellCommandRegistry.$invocation.withValue(capturedInvocation) {
            await FloeShellCommandRegistry.$input.withValue(input) {
                await handler(arguments, box.stdout, box.stderr)
            }
        }
        semaphore.signal()
    }
    while semaphore.wait(timeout: .now() + 0.025) == .timedOut {
        if parentCancellation?.isCancelled == true { commandCancellation.cancel() }
    }
    return box.code
}

/// Tools the shell commands can build with their production initializer.
private protocol ShellDefaultConstructibleTool: AgentTool {
    init()
}

extension NetworkPingTool: ShellDefaultConstructibleTool {}
extension NetworkTracerouteTool: ShellDefaultConstructibleTool {}
extension NetworkDNSLookupTool: ShellDefaultConstructibleTool {}
extension NetworkTCPProbeTool: ShellDefaultConstructibleTool {}

private enum ShellCommandResult {
    case success(String)
    case failure(String)
}

enum FloeShellCommands {
    static func install() {
        let registry = FloeShellCommandRegistry.shared
        registerPython(registry)
        registerHash(registry)
        registerNetwork(registry)
        registerPackages(registry)
        registry.register("git") { _, _, stderr in
            FloeShellWrite(stderr, "git: use the git.* agent tools (libgit2) or an approved remote host\n")
            return 127
        }
        FloePlatformServices.shared.registerCommands(in: registry)
    }
    }

    static func refreshPythonCommands() async {
        guard let python = FloeShellCommandRegistry.shared.python else { return }
        let entries = await PythonEntryPointShims(python: python).entryPoints()
        FloeShellCommandRegistry.shared.replacePythonCommands(entries)
    }

    private static func registerWasm(_ registry: FloeShellCommandRegistry) {
        guard let store = registry.wasm else { return }
        for entry in store.catalog.packages {
            registry.register(entry.command) { arguments, stdout, stderr in
                guard let context = registry.context else { return 2 }
                guard let input = FloeShellCommandRegistry.input?.read(cancellation: context.cancellation) else {
                    if context.cancellation.isCancelled { return 130 }
                    FloeShellWrite(stderr, "WASM stdin exceeds 256 KiB or could not be read\n"); return 2
                }
                let outcome = await store.run(command: entry.command, arguments: Array(arguments.dropFirst()), stdin: input, environment: [:], rootURL: context.rootURL, cancellation: context.cancellation)
                switch outcome {
                case .exited(let code, let out, let err, _, _, _):
                    FloeShellWrite(stdout, out); FloeShellWrite(stderr, err); return code
                case .timedOut(let out, let err, _):
                    FloeShellWrite(stdout, out); FloeShellWrite(stderr, err + "\nWASM command timed out\n"); return 124
                case .cancelled: return 130
                case .failed(let message): FloeShellWrite(stderr, message + "\n"); return 1
                }
            }
        }
    }

    // MARK: - python3

    private static func registerPython(_ registry: FloeShellCommandRegistry) {
        registry.register("python3") { arguments, stdout, stderr in
            guard let python = registry.python else {
                FloeShellWrite(stderr, "python3: the bundled CPython runtime is unavailable\n")
                return 127
            }
            if arguments.contains("--version") {
                FloeShellWrite(stdout, "Python 3.13 (Floe bundled)\n")
                return 0
            }
            var script: String?
            if arguments.count >= 3, arguments[1] == "-c" {
                script = arguments[2]
            } else if arguments.count >= 2, !arguments[1].hasPrefix("-") {
                guard let context = registry.context else {
                    FloeShellWrite(stderr, "python3: no workspace is attached\n")
                    return 2
                }
                let path = arguments[1]
                guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.split(separator: "/").contains("..") else {
                    FloeShellWrite(stderr, "python3: script paths must stay inside the workspace\n")
                    return 2
                }
                let url = context.workingDirectory.appendingPathComponent(path).resolvingSymlinksInPath()
                guard url.path.hasPrefix(context.rootURL.resolvingSymlinksInPath().path + "/") else { return 2 }
                script = try? String(contentsOf: url, encoding: .utf8)
                if script == nil {
                    FloeShellWrite(stderr, "python3: cannot read \(path)\n")
                    return 2
                }
            }
            guard let script else {
                FloeShellWrite(stderr, "python3: use -c <code> or python3 <file.py>; interactive stdin is not supported by this command yet\n")
                return 2
            }
            let argv = arguments[1] == "-c" ? ["-c"] + Array(arguments.dropFirst(3)) : Array(arguments.dropFirst())
            let argvData = (try? JSONEncoder().encode(argv)) ?? Data("[]".utf8)
            let wrapper = """
            import sys as _floe_sys, json as _floe_json, base64 as _floe_base64
            _floe_argv = _floe_sys.argv
            _floe_sys.argv = _floe_json.loads(_floe_base64.b64decode('\(argvData.base64EncodedString())'))
            try:
                try:
                    exec(compile(_floe_base64.b64decode('\(Data(script.utf8).base64EncodedString())'), _floe_sys.argv[0], 'exec'), globals())
                except SystemExit as _floe_exit:
                    _floe_code = _floe_exit.code
                    if _floe_code is not None and not isinstance(_floe_code, int):
                        print(str(_floe_code), file=_floe_sys.stderr)
                        _floe_code = 1
                    printJSON({'floeShellExitCode': int(_floe_code or 0)})
            finally:
                _floe_sys.argv = _floe_argv
            """
            let request = ScriptExecutionRequest(script: wrapper, timeout: 30, maxOutputBytes: 256 * 1024)
            let outcome = await python.run(request, cancellation: registry.context?.cancellation)
            switch outcome {
            case .ok(let resultJSON, let out, let errText, _, _, _):
                if !out.isEmpty { FloeShellWrite(stdout, out.hasSuffix("\n") ? out : out + "\n") }
                if !errText.isEmpty { FloeShellWrite(stderr, errText.hasSuffix("\n") ? errText : errText + "\n") }
                if let resultJSON, let data = resultJSON.data(using: .utf8),
                   let payload = try? JSONDecoder().decode([String: Int32].self, from: data), let code = payload["floeShellExitCode"] { return code }
                return 0
            case .jsException(let message, let out):
                if !out.isEmpty { FloeShellWrite(stdout, out) }
                FloeShellWrite(stderr, "python3: \(message)\n")
                return 1
            case .timedOut:
                FloeShellWrite(stderr, "python3: timed out\n")
                return 124
            case .cancelled:
                return 130
            }
        }
    }

    // MARK: - sha256sum

    private static func registerHash(_ registry: FloeShellCommandRegistry) {
        registry.register("sha256sum") { arguments, stdout, stderr in
            guard let context = registry.context else {
                FloeShellWrite(stderr, "sha256sum: no workspace is attached\n")
                return 2
            }
            let files = arguments.dropFirst().filter { !$0.hasPrefix("-") }
            guard !files.isEmpty else {
                FloeShellWrite(stderr, "usage: sha256sum FILE...\n")
                return 1
            }
            var status: Int32 = 0
            for file in files {
                guard !file.hasPrefix("/"), !file.hasPrefix("~"), !file.split(separator: "/").contains("..") else {
                    FloeShellWrite(stderr, "sha256sum: \(file): path escapes the workspace\n")
                    status = 1
                    continue
                }
                let url = context.workingDirectory.appendingPathComponent(file).resolvingSymlinksInPath()
                guard url.path.hasPrefix(context.rootURL.resolvingSymlinksInPath().path + "/") else { status = 1; continue }
                do {
                    let digest = try FloeDigest.sha256Hex(ofFileAt: url)
                    FloeShellWrite(stdout, "\(digest)  \(file)\n")
                } catch {
                    FloeShellWrite(stderr, "sha256sum: \(file): no such file\n")
                    status = 1
                }
            }
            return status
        }
    }

    // MARK: - network diagnostics (tool-backed)

    private static func registerNetwork(_ registry: FloeShellCommandRegistry) {
        registry.register("ping") { arguments, stdout, stderr in
            let parsed = parseTarget(arguments, countFlags: ["-c"])
            guard let target = parsed.target else {
                FloeShellWrite(stderr, "usage: ping [-c count] host\n")
                return 2
            }
            let result = await invokeTool(NetworkPingTool.self, arguments: ["target": target, "count": parsed.count ?? 4])
            return emit(result, label: "ping", stdout: stdout, stderr: stderr)
        }
        registry.register("traceroute") { arguments, stdout, stderr in
            let parsed = parseTarget(arguments, countFlags: ["-m"])
            guard let target = parsed.target else {
                FloeShellWrite(stderr, "usage: traceroute [-m maxHops] host\n")
                return 2
            }
            let result = await invokeTool(NetworkTracerouteTool.self, arguments: ["target": target, "maxHops": parsed.count ?? 20])
            return emit(result, label: "traceroute", stdout: stdout, stderr: stderr)
        }
        for name in ["dig", "nslookup", "host"] {
            registry.register(name) { arguments, stdout, stderr in
                let short = arguments.contains("+short")
                guard let target = arguments.dropFirst().first(where: { !$0.hasPrefix("-") && !$0.hasPrefix("+") }) else {
                    FloeShellWrite(stderr, "usage: \(name) [+short] host\n")
                    return 2
                }
                let result = await invokeTool(NetworkDNSLookupTool.self, arguments: ["target": target])
                switch result {
                case .success(let summary):
                    if short {
                        for line in summary.split(separator: "\n") where line.contains("address") {
                            let address = line.split(separator: "=").last.map(String.init) ?? String(line)
                            FloeShellWrite(stdout, address.trimmingCharacters(in: .whitespaces) + "\n")
                        }
                    } else {
                        FloeShellWrite(stdout, summary.hasSuffix("\n") ? summary : summary + "\n")
                    }
                    return 0
                case .failure(let message):
                    FloeShellWrite(stderr, "\(name): \(message)\n")
                    return 1
                }
            }
        }
        registry.register("nc") { arguments, stdout, stderr in
            let values = arguments.dropFirst().filter { !$0.hasPrefix("-") }
            guard values.count >= 2, let port = Int(values[1]) else {
                FloeShellWrite(stderr, "usage: nc -z host port\n")
                return 2
            }
            let result = await invokeTool(NetworkTCPProbeTool.self, arguments: ["target": values[0], "port": port])
            return emit(result, label: "nc", stdout: stdout, stderr: stderr)
        }
    }

    private struct ParsedTarget {
        var target: String?
        var count: Int?
    }

    private static func parseTarget(_ arguments: [String], countFlags: [String]) -> ParsedTarget {
        var parsed = ParsedTarget()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if countFlags.contains(argument), index + 1 < arguments.count {
                parsed.count = Int(arguments[index + 1])
                index += 2
                continue
            }
            if !argument.hasPrefix("-") {
                parsed.target = argument
                break
            }
            index += 1
        }
        return parsed
    }

    private static func invokeTool<T: ShellDefaultConstructibleTool>(
        _ type: T.Type,
        arguments: [String: Any]
    ) async -> ShellCommandResult {
        guard let context = FloeShellCommandRegistry.shared.context else {
            return .failure("no workspace is attached")
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: arguments)
            let decoded = try JSONDecoder().decode(T.Arguments.self, from: data)
            let toolContext = ToolContext(
                runID: context.runID,
                toolCallID: "shell.command.\(T.name)",
                scope: .local,
                workspaceRootURL: context.rootURL,
                cancellation: context.cancellation
            )
            let tool = type.init()
            try tool.validate(decoded)
            let output = try await tool.execute(decoded, context: toolContext)
            return output.exitStatus == 0 ? .success(output.summary) : .failure(output.summary)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func emit(
        _ result: ShellCommandResult,
        label: String,
        stdout: UnsafeMutablePointer<FILE>?,
        stderr: UnsafeMutablePointer<FILE>?
    ) -> Int32 {
        switch result {
        case .success(let summary):
            FloeShellWrite(stdout, summary.hasSuffix("\n") ? summary : summary + "\n")
            return 0
        case .failure(let message):
            FloeShellWrite(stderr, "\(label): \(message)\n")
            return 1
        }
    }

    // MARK: - apt / pkg / dpkg (catalog queries; install flows through the apt tool)

    private static func registerPackages(_ registry: FloeShellCommandRegistry) {
        for name in ["apt", "apt-get", "pkg"] {
            registry.register(name) { arguments, stdout, stderr in
                let subcommand = arguments.dropFirst().first { !$0.hasPrefix("-") } ?? "list"
                switch subcommand {
                case "search":
                    guard let query = arguments.dropFirst(2).first else {
                        FloeShellWrite(stderr, "usage: \(name) search TERM\n")
                        return 2
                    }
                    return await listCatalog(registry, query: query, stdout: stdout, stderr: stderr)
                case "list":
                    return await listCatalog(registry, query: nil, stdout: stdout, stderr: stderr)
                case "install", "remove", "download":
                    FloeShellWrite(stderr, "\(name): use the apt agent tool with action=\(subcommand) so the package review runs first\n")
                    return 1
                default:
                    FloeShellWrite(stdout, "usage: \(name) search TERM | list; installation runs through the apt tool\n")
                    return 0
                }
            }
        }
        registry.register("dpkg") { arguments, stdout, stderr in
            let flag = arguments.dropFirst().first ?? "-l"
            if flag == "-x" || flag == "--extract" {
                guard arguments.count == 4, let python = registry.python, let context = registry.context else {
                    FloeShellWrite(stderr, "usage: dpkg -x ARCHIVE.deb NEW_DIRECTORY\n"); return 2
                }
                do {
                    let root = context.rootURL.resolvingSymlinksInPath()
                    let paths = try arguments.suffix(2).map { path -> URL in
                        try ShellInputValidation.validate(command: "", cwd: path, environment: [:])
                        let url = root.appendingPathComponent(path).resolvingSymlinksInPath()
                        guard url.path.hasPrefix(root.path + "/") else { throw FloeError.validationFailed("Path escapes workspace") }
                        return url
                    }
                    let result = try await DebDataInstaller(python: python).extract(debURL: paths[0], destinationDirectory: paths[1], cancellation: context.cancellation)
                    FloeShellWrite(stdout, "Extracted \(result.fileCount) data files\n"); return 0
                } catch { FloeShellWrite(stderr, "dpkg: \(error)\n"); return 1 }
            }
            guard flag == "-l" || flag == "--list" else {
                FloeShellWrite(stderr, "dpkg: use -l to list or -x ARCHIVE.deb NEW_DIRECTORY for data-only extraction\n")
                return 1
            }
            guard let installer = FloeShellCommandRegistry.shared.installer else {
                FloeShellWrite(stderr, "dpkg: the capability catalog is unavailable\n")
                return 1
            }
            let installed = await installer.installedIDs()
            FloeShellWrite(stdout, "Desired=Unknown/Install/Remove/Purge/Hold\n")
            for id in installed { FloeShellWrite(stdout, "ii  \(id)\n") }
            return 0
        }
    }

    private static func listCatalog(
        _ registry: FloeShellCommandRegistry,
        query: String?,
        stdout: UnsafeMutablePointer<FILE>?,
        stderr: UnsafeMutablePointer<FILE>?
    ) async -> Int32 {
        guard let installer = registry.installer else {
            FloeShellWrite(stderr, "apt: the capability catalog is unavailable\n")
            return 1
        }
        let entries: [CapabilityCatalog.Entry]
        if let query { entries = await installer.search(query) }
        else { entries = await installer.allEntries() }
        for entry in entries {
            FloeShellWrite(stdout, "\(entry.id) - \(entry.summary) (\(entry.tier.rawValue))\n")
        }
        return 0
    }
}

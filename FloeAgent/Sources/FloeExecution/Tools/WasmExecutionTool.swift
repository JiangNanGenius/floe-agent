import Foundation
import Crypto
import FloeCore
import FloeTools

/// Executes a self-contained WebAssembly module through the system
/// JavaScriptCore runtime. No host imports are exposed, so the module cannot
/// access files, the network, clocks, processes, or native application APIs.
public struct WasmExecutionTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var moduleBase64: String
        public var function: String
        public var arguments: [Double]?
        public var timeout: Double?

        public init(
            moduleBase64: String,
            function: String,
            arguments: [Double]? = nil,
            timeout: Double? = nil
        ) {
            self.moduleBase64 = moduleBase64
            self.function = function
            self.arguments = arguments
            self.timeout = timeout
        }
    }

    public static let name = "exec.wasm"
    public static let toolDescription =
        "Internal runtime for an already-downloaded, provenance-checked WebAssembly artifact. It executes one exported numeric function and cannot compile source code or create native Mach-O, ELF, dylib, or executable files on iPhone or iPad. The sandbox exposes no WASI, file, network, process, native, or host imports; use ssh.execute for compilation or a full operating-system runtime."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "moduleBase64": {"type": "string", "description": "Base64 WebAssembly module, at most 16 MiB decoded"},
        "function": {"type": "string", "description": "Name of an exported function"},
        "arguments": {"type": "array", "items": {"type": "number"}, "maxItems": 32},
        "timeout": {"type": "number", "description": "Wall-clock timeout in seconds (default 10, max 30)"}
      },
      "required": ["moduleBase64", "function"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false

    static let maxModuleBytes = 16 * 1024 * 1024
    private let service: any ScriptExecutionService

    public init(service: any ScriptExecutionService = JavaScriptExecutionService()) {
        self.service = service
    }

    public func validate(_ args: Arguments) throws {
        guard !args.function.isEmpty,
              args.function.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$")).contains($0)
              }) else {
            throw FloeError.validationFailed("function must be a non-empty export name")
        }
        guard let module = Data(base64Encoded: args.moduleBase64, options: [.ignoreUnknownCharacters]) else {
            throw FloeError.validationFailed("moduleBase64 is not valid Base64")
        }
        guard module.count <= Self.maxModuleBytes else {
            throw FloeError.validationFailed("WebAssembly module exceeds the 16 MiB limit")
        }
        guard module.starts(with: [0x00, 0x61, 0x73, 0x6D]) else {
            throw FloeError.validationFailed("module does not have the WebAssembly magic header")
        }
        if let arguments = args.arguments, arguments.count > 32 {
            throw FloeError.validationFailed("arguments exceeds the 32-item limit")
        }
        if let timeout = args.timeout, timeout <= 0 {
            throw FloeError.validationFailed("timeout must be > 0")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let module = Data(base64Encoded: args.moduleBase64, options: [.ignoreUnknownCharacters]) else {
            throw FloeError.validationFailed("moduleBase64 is not valid Base64")
        }
        let input: [String: Any] = [
            "bytes": Array(module),
            "function": args.function,
            "arguments": args.arguments ?? []
        ]
        let inputData = try JSONSerialization.data(withJSONObject: input)
        let script = """
        if (typeof WebAssembly !== 'object') {
          throw new Error('WebAssembly is unavailable in this system JavaScriptCore runtime');
        }
        var module = new WebAssembly.Module(new Uint8Array(input.bytes));
        if (WebAssembly.Module.imports(module).length !== 0) {
          throw new Error('Imported host capabilities are not allowed; use ssh.execute for WASI modules');
        }
        var instance = new WebAssembly.Instance(module, {});
        var fn = instance.exports[input.function];
        if (typeof fn !== 'function') {
          throw new Error('Requested WebAssembly export is not a function');
        }
        var value = fn.apply(null, input.arguments);
        printJSON({ export: input.function, result: String(value), resultType: typeof value });
        """
        let outcome = await service.run(
            ScriptExecutionRequest(
                script: script,
                inputJSON: String(decoding: inputData, as: UTF8.self),
                timeout: min(args.timeout ?? 10, 30),
                maxOutputBytes: 16 * 1024
            ),
            cancellation: context.cancellation
        )
        let summary: String
        let exitStatus: Int32?
        switch outcome {
        case .ok(let resultJSON, _, let stderr, _, _, let durationMs):
            summary = "status=ok durationMs=\(durationMs)\nresult=\(resultJSON ?? "null")" +
                (stderr.isEmpty ? "" : "\nstderr=\(stderr)")
            exitStatus = nil
        case .jsException(let message, _):
            summary = "status=exception\nerror=\(message)"
            exitStatus = 1
        case .timedOut(let afterMs, _):
            summary = "status=timedOut afterMs=\(afterMs)"
            exitStatus = 124
        case .cancelled:
            throw FloeError.cancelled
        }
        let digest = SHA256.hash(data: Data(summary.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: summary, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}

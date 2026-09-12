import Foundation
@_spi(Fuzzing) import WasmKit
import WasmKitWASI
import SystemPackage
import FloeCore
import FloeTools

/// Interpreter-only WASI execution. Every invocation owns its store, files and budget.
public struct WasmKitCommandRuntime: WasmCommandRuntime {
    public init() {}

    public func run(moduleURL: URL, arguments: [String], stdin: String?, environment: [String: String], rootURL: URL, timeout: TimeInterval, maxOutputBytes: Int, cancellation: CancellationToken? = nil) async -> ShellRunOutcome {
        await Task.detached(priority: .userInitiated) {
            Self.execute(moduleURL: moduleURL, arguments: arguments, stdin: stdin, environment: environment, rootURL: rootURL, timeout: timeout, maxOutputBytes: maxOutputBytes, cancellation: cancellation)
        }.value
    }

    private static func execute(moduleURL: URL, arguments: [String], stdin: String?, environment: [String: String], rootURL: URL, timeout: TimeInterval, maxOutputBytes: Int, cancellation: CancellationToken?) -> ShellRunOutcome {
        let started = DispatchTime.now().uptimeNanoseconds
        let seconds = timeout.isFinite ? max(0.01, min(timeout, 120)) : 10
        let budget = Budget(deadline: started + UInt64(seconds * 1_000_000_000), cancellation: cancellation)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("floe-wasi-" + UUID().uuidString)
        let captureBudget = CaptureBudget(maxBytes: max(1, min(maxOutputBytes, 256 * 1024)))
        let output = Capture(budget: captureBudget)
        let errors = Capture(budget: captureBudget)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var code: Int32 = 125
        var failure: Error?
        do {
            try budget.check()
            guard (stdin?.utf8.count ?? 0) <= 256 * 1024, arguments.count <= 128,
                  arguments.reduce(0, { $0 + $1.utf8.count }) <= 64 * 1024,
                  environment.count <= 32, environment.allSatisfy({ $0.key.utf8.count <= 256 && $0.value.utf8.count <= 16 * 1024 && !$0.key.contains("\0") && !$0.value.contains("\0") }) else { throw FloeError.validationFailed("WASM input exceeds limits") }
            let attributes = try FileManager.default.attributesOfItem(atPath: moduleURL.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 4 * 1024 * 1024 else {
                throw FloeError.validationFailed("WASM module exceeds 4 MiB")
            }
            _ = try ShellInputValidation.directory(cwd: ".", root: rootURL)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let inputURL = temporary.appendingPathComponent("stdin")
            try Data((stdin ?? "").utf8).write(to: inputURL)
            let input = try FileHandle(forReadingFrom: inputURL)
            defer { try? input.close() }
            // The patched token loop checks even pure WASM infinite loops.
            let engine = Engine(configuration: EngineConfiguration(threadingModel: .token, executionCheck: { try budget.check() }))
            let store = Store(engine: engine)
            store.resourceLimiter = Limits()
            let wasi = try WASIBridgeToHost(
                args: [moduleURL.lastPathComponent] + arguments,
                environment: environment,
                preopens: ["/workspace": rootURL.resolvingSymlinksInPath().path, "/tmp": temporary.path],
                borrowStandardStreams: true,
                stdin: FileDescriptor(rawValue: input.fileDescriptor),
                stdout: FileDescriptor(rawValue: output.pipe.fileHandleForWriting.fileDescriptor),
                stderr: FileDescriptor(rawValue: errors.pipe.fileHandleForWriting.fileDescriptor)
            )
            var imports = Imports()
            wasi.link(to: &imports, store: store)
            let module = try parseWasm(filePath: FilePath(moduleURL.path))
            try budget.check()
            let instance = try module.instantiate(store: store, imports: imports)
            code = Int32(bitPattern: try wasi.start(instance))
        } catch { failure = error }
        let stdout = output.finish()
        let stderr = errors.finish()
        let duration = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        switch failure {
        case BudgetFailure.cancelled?: return .cancelled
        case BudgetFailure.deadline?, BudgetFailure.fuel?:
            return .timedOut(partialStdout: stdout.text, partialStderr: stderr.text, durationMs: duration)
        case let failure?: return .failed(message: "WASM command failed: \(failure)")
        case nil:
            return .exited(code: code, stdout: stdout.text, stderr: stderr.text, truncated: stdout.truncated, stderrTruncated: stderr.truncated, durationMs: duration)
        }
    }

    private enum BudgetFailure: Error { case deadline, cancelled, fuel }
    private final class Budget: @unchecked Sendable {
        let deadline: UInt64
        let cancellation: CancellationToken?
        private var checks = 0 // Used only on the invocation's interpreter thread.
        init(deadline: UInt64, cancellation: CancellationToken?) { self.deadline = deadline; self.cancellation = cancellation }
        func check() throws {
            if cancellation?.isCancelled == true { throw BudgetFailure.cancelled }
            if DispatchTime.now().uptimeNanoseconds >= deadline { throw BudgetFailure.deadline }
            checks += 1
            if checks > 50_000 { throw BudgetFailure.fuel }
        }
    }
    private struct Limits: ResourceLimiter {
        func limitMemoryGrowth(to desired: Int) throws -> Bool { desired <= 64 * 1024 * 1024 }
        func limitTableGrowth(to desired: Int) throws -> Bool { desired <= 10_000 }
    }
    private final class CaptureBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        init(maxBytes: Int) { remaining = maxBytes }
        func reserve(_ requested: Int) -> Int {
            lock.withLock { let count = min(requested, remaining); remaining -= count; return count }
        }
    }
    private final class Capture: @unchecked Sendable {
        let pipe = Pipe()
        private let group = DispatchGroup()
        private let budget: CaptureBudget
        private var data = Data()
        private var truncated = false
        init(budget: CaptureBudget) {
            self.budget = budget
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { group.leave() }
                while let chunk = try? pipe.fileHandleForReading.read(upToCount: 16 * 1024), !chunk.isEmpty {
                    let remaining = budget.reserve(chunk.count)
                    data.append(chunk.prefix(remaining))
                    truncated = truncated || chunk.count > remaining
                }
            }
        }
        func finish() -> (text: String, truncated: Bool) {
            try? pipe.fileHandleForWriting.close()
            group.wait()
            try? pipe.fileHandleForReading.close()
            return (String(decoding: data, as: UTF8.self), truncated)
        }
    }
}

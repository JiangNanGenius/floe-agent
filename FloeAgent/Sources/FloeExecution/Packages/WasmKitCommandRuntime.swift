import Foundation
@_spi(Fuzzing) import WasmKit
import WasmKitWASI
import SystemPackage
import FloeCore
import FloeTools

/// Interpreter-only WASI execution. Every invocation owns its store, files and budget.
public struct WasmKitCommandRuntime: WasmCommandRuntime {
    public init() {}

    public func run(moduleURL: URL, arguments: [String], stdin: String?, environment: [String: String], rootURL: URL, workingDirectory: String = ".", timeout: TimeInterval, maxOutputBytes: Int, moduleMaxBytes: Int = WasmPackageLimits.defaultModuleMaxBytes, memoryMaxBytes: Int = WasmPackageLimits.defaultMemoryMaxBytes, cancellation: CancellationToken? = nil) async -> ShellRunOutcome {
        let taskCancellation = CancellationToken()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // The interpreter and pipe drains perform blocking I/O. Keep
                // them off Swift's cooperative pool, and retain all buffers
                // until this worker actually leaves the interpreter.
                DispatchQueue(label: "org.floe.wasi.worker.\(UUID().uuidString)", qos: .userInitiated).async {
                    continuation.resume(returning: Self.execute(moduleURL: moduleURL, arguments: arguments,
                        stdin: stdin, environment: environment, rootURL: rootURL, workingDirectory: workingDirectory, timeout: timeout,
                        maxOutputBytes: maxOutputBytes, moduleMaxBytes: moduleMaxBytes, memoryMaxBytes: memoryMaxBytes,
                        cancellation: cancellation, taskCancellation: taskCancellation))
                }
            }
        } onCancel: {
            taskCancellation.cancel()
        }
    }

    private static func execute(moduleURL: URL, arguments: [String], stdin: String?, environment: [String: String], rootURL: URL, workingDirectory: String, timeout: TimeInterval, maxOutputBytes: Int, moduleMaxBytes: Int, memoryMaxBytes: Int, cancellation: CancellationToken?, taskCancellation: CancellationToken) -> ShellRunOutcome {
        let started = DispatchTime.now().uptimeNanoseconds
        let seconds = timeout.isFinite ? max(0.01, min(timeout, WasmPackageLimits.maximumTimeoutSeconds)) : 10
        let budget = Budget(deadline: started + UInt64(seconds * 1_000_000_000), cancellations: [cancellation, taskCancellation].compactMap { $0 })
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("floe-wasi-" + UUID().uuidString)
        let captureBudget = CaptureBudget(maxBytes: max(1, min(maxOutputBytes, 256 * 1024)))
        let output = Capture(budget: captureBudget)
        let errors = Capture(budget: captureBudget)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var code: Int32 = 125
        var failure: Error?
        do {
            try budget.check()
            // Each input family is bounded and reported separately so a cloud
            // run can identify the exact field without touching its content.
            guard (stdin?.utf8.count ?? 0) <= 256 * 1024 else {
                throw FloeError.validationFailed("WASM stdin exceeds 256 KiB")
            }
            guard arguments.count <= 128 else {
                throw FloeError.validationFailed("WASM arguments exceed 128 entries")
            }
            guard arguments.reduce(0, { $0 + $1.utf8.count }) <= 64 * 1024 else {
                throw FloeError.validationFailed("WASM argument bytes exceed 64 KiB")
            }
            try WasmEnvironmentContract.validate(environment)
            // The signed catalog carries the reviewed per-package ceiling; the
            // interpreter-class entries raise it above the utility default.
            guard moduleMaxBytes >= WasmPackageLimits.minimumModuleMaxBytes, moduleMaxBytes <= WasmPackageLimits.maximumModuleMaxBytes else {
                throw FloeError.validationFailed("WASM module limit is outside the reviewed range")
            }
            guard memoryMaxBytes >= WasmPackageLimits.minimumMemoryMaxBytes, memoryMaxBytes <= WasmPackageLimits.maximumMemoryMaxBytes else {
                throw FloeError.validationFailed("WASM memory limit is outside the reviewed range")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: moduleURL.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= moduleMaxBytes else {
                throw FloeError.validationFailed("WASM module exceeds its signed size limit")
            }
            let directory = try ShellInputValidation.directory(cwd: workingDirectory, root: rootURL)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let inputURL = temporary.appendingPathComponent("stdin")
            try Data((stdin ?? "").utf8).write(to: inputURL)
            let input = try FileHandle(forReadingFrom: inputURL)
            defer { try? input.close() }
            // The patched token loop checks even pure WASM infinite loops.
            let engine = Engine(configuration: EngineConfiguration(threadingModel: .token, executionCheck: { try budget.check() }))
            let store = Store(engine: engine)
            store.resourceLimiter = Limits(memoryMaxBytes: memoryMaxBytes)
            let wasi = try WASIBridgeToHost(
                args: [moduleURL.lastPathComponent] + arguments,
                environment: environment,
                preopens: ["/workspace": rootURL.resolvingSymlinksInPath().path, ".": directory.path, "/tmp": temporary.path],
                stdin: FileDescriptor(rawValue: input.fileDescriptor),
                stdout: FileDescriptor(rawValue: output.pipe.fileHandleForWriting.fileDescriptor),
                stderr: FileDescriptor(rawValue: errors.pipe.fileHandleForWriting.fileDescriptor)
            )
            // 0.3.1 keeps host stdio borrowed by default and requires explicit
            // teardown: its deinit traps if owned descriptors leak.
            defer { try? wasi.close() }
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
        case BudgetFailure.deadline?:
            return .timedOut(partialStdout: stdout.text, partialStderr: stderr.text, durationMs: duration)
        case let failure?: return .failed(message: "WASM command failed: \(failure)")
        case nil:
            return .exited(code: code, stdout: stdout.text, stderr: stderr.text, truncated: stdout.truncated, stderrTruncated: stderr.truncated, durationMs: duration)
        }
    }

    private enum BudgetFailure: Error { case deadline, cancelled }
    private final class Budget: @unchecked Sendable {
        // The patched token loop calls `check()` every 1024 instructions, so
        // the wall-clock deadline and the cancellation flag bound pure loops
        // without capping the total instruction count. A fixed instruction
        // budget was wrong here: it killed interpreter startup (Ruby 3.4 needs
        // far more than the old 51M-instruction ceiling before it prints).
        let deadline: UInt64
        let cancellations: [CancellationToken]
        init(deadline: UInt64, cancellations: [CancellationToken]) { self.deadline = deadline; self.cancellations = cancellations }
        func check() throws {
            if cancellations.contains(where: \.isCancelled) { throw BudgetFailure.cancelled }
            if DispatchTime.now().uptimeNanoseconds >= deadline { throw BudgetFailure.deadline }
        }
    }
    private struct Limits: ResourceLimiter {
        let memoryMaxBytes: Int
        func limitMemoryGrowth(to desired: Int) throws -> Bool { desired <= memoryMaxBytes }
        // Table growth scales with the reviewed memory ceiling so an
        // interpreter that grows its function table is not rejected while a
        // utility stays at the historical bound.
        func limitTableGrowth(to desired: Int) throws -> Bool { desired <= max(10_000, memoryMaxBytes / 1024) }
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

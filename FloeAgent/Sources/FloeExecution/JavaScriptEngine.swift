// FloeExecution — JavaScriptCore script engine.
// See docs/ARCHITECTURE_EXECUTION.md §1.1/§1.2: every run happens on a
// dedicated serial DispatchQueue (never the global pool) inside a fresh
// JSContext; only pure closures are injected (console.*, printJSON) — no
// Swift class instances ever cross into JS. Timeout/cancellation is a race
// between the execution and a sleep; the loser is abandoned, so the caller
// always returns on time even for while(true){}.

import Foundation
import FloeCore
import FloeTools

#if canImport(JavaScriptCore)
import JavaScriptCore

/// Thread-safe bounded console buffer. Appends stop once the byte cap is
/// reached and flag the result as truncated.
private final class BoundedConsole: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private(set) var truncated = false
    private let maxBytes: Int

    init(maxBytes: Int) {
        self.maxBytes = max(1, maxBytes)
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !truncated else { return }
        let addition = line + "\n"
        if buffer.utf8.count + addition.utf8.count > maxBytes {
            truncated = true
            return
        }
        buffer += addition
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    var isTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return truncated
    }
}

/// The result of one on-queue evaluation (never crosses into JS).
private struct EvaluationResult: Sendable {
    var exceptionMessage: String?
    var resultJSON: String?
}

/// JavaScript execution via JavaScriptCore. Isolated per run, bounded
/// output, guaranteed-timely return.
public struct JavaScriptExecutionService: ScriptExecutionService {

    /// A fresh serial queue per `run` call. A runaway script (while(true){})
    /// occupies only that run's queue thread; because the queue is created
    /// per execution rather than shared, a timed-out/abandoned run can
    /// never starve a later run on the same service — the next execution
    /// gets its own queue. Not the global concurrent pool, so a leak stays
    /// bounded to one thread per abandoned run.
    private func makeQueue() -> DispatchQueue {
        DispatchQueue(label: "floe.jsexec", qos: .userInitiated)
    }

    public init() {}

    public func run(
        _ request: ScriptExecutionRequest,
        cancellation: CancellationToken? = nil
    ) async -> ScriptExecutionOutcome {
        let started = Date()

        if cancellation?.isCancelled == true {
            return .cancelled
        }

        let console = BoundedConsole(maxBytes: request.maxOutputBytes)
        let resultBox = LockedBox<EvaluationResult?>(nil)
        let done = LockedBox(false)

        // Submit the evaluation on a fresh serial queue. A fresh JSContext
        // per run guarantees isolation between executions.
        let queue = makeQueue()
        queue.async {
            let result = Self.evaluate(script: request.script, inputJSON: request.inputJSON, console: console)
            resultBox.withLock { $0 = result }
            done.withLock { $0 = true }
        }

        // Race the evaluation against timeout / cancellation. The caller
        // wins deterministically; an abandoned evaluation is left on the
        // serial queue (it cannot block a future run's outcome because a
        // new queue is created per service instance only once — see note in
        // ARCHITECTURE §1.2: the leaked thread is the accepted boundary).
        let timeout = max(0.05, request.timeout)
        while true {
            if done.withLock({ $0 }) {
                let evaluation = resultBox.withLock { $0 }
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                if let exception = evaluation?.exceptionMessage {
                    return .jsException(message: exception, stdout: console.text)
                }
                return .ok(
                    resultJSON: evaluation?.resultJSON,
                    stdout: console.text,
                    truncated: console.isTruncated,
                    durationMs: durationMs
                )
            }
            if cancellation?.isCancelled == true {
                return .cancelled
            }
            if Date().timeIntervalSince(started) >= timeout {
                return .timedOut(
                    afterMs: Int(timeout * 1000),
                    partialStdout: console.text
                )
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Evaluates one script in a fresh JSContext. Only `@convention(block)`
    /// closures are injected; no Swift object ever enters the JS world.
    private static func evaluate(
        script: String,
        inputJSON: String?,
        console: BoundedConsole
    ) -> EvaluationResult {
        guard let context = JSContext() else {
            return EvaluationResult(exceptionMessage: "JSContext could not be created", resultJSON: nil)
        }

        var exceptionMessage: String?
        var resultJSON: String?
        let resultLock = NSLock()

        context.exceptionHandler = { _, exception in
            resultLock.lock()
            exceptionMessage = exception?.toString() ?? "Unknown JavaScript exception"
            resultLock.unlock()
        }

        // console.log/info/warn/error → bounded buffer. Arguments are
        // serialized with String(...); never exposed as objects.
        let logBlock: @convention(block) (JSValue) -> Void = { value in
            console.append(value.toString())
        }
        context.setObject(logBlock, forKeyedSubscript: "__floeLog" as NSString)
        context.evaluateScript("""
            var console = {
                log: function() { __floeLog(Array.prototype.map.call(arguments, String).join(' ')); },
                info: function() { __floeLog(Array.prototype.map.call(arguments, String).join(' ')); },
                warn: function() { __floeLog(Array.prototype.map.call(arguments, String).join(' ')); },
                error: function() { __floeLog(Array.prototype.map.call(arguments, String).join(' ')); }
            };
            """)

        // printJSON(value) → result collection.
        let printBlock: @convention(block) (JSValue) -> Void = { value in
            resultLock.lock()
            if let object = value.toObject(),
               let data = try? JSONSerialization.data(withJSONObject: object),
               let string = String(data: data, encoding: .utf8) {
                resultJSON = string
            } else {
                resultJSON = value.toString()
            }
            resultLock.unlock()
        }
        context.setObject(printBlock, forKeyedSubscript: "printJSON" as NSString)

        // Inject the optional input as a JS value.
        if let inputJSON,
           let data = inputJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            context.setObject(object, forKeyedSubscript: "input" as NSString)
        }

        context.evaluateScript(script)

        resultLock.lock()
        let outcome = EvaluationResult(exceptionMessage: exceptionMessage, resultJSON: resultJSON)
        resultLock.unlock()
        return outcome
    }
}

/// Minimal lock box for cross-thread handoff (execution queue → async loop).
private final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

#else

/// Honest fallback on platforms without JavaScriptCore (Linux CI): the
/// service reports timedOut-style unavailability as a jsException so
/// callers get a structured failure instead of a crash.
public struct JavaScriptExecutionService: ScriptExecutionService {
    public init() {}

    public func run(
        _ request: ScriptExecutionRequest,
        cancellation: CancellationToken? = nil
    ) async -> ScriptExecutionOutcome {
        .jsException(
            message: "JavaScriptCore is not available on this platform",
            stdout: ""
        )
    }
}

#endif

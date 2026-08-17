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

    private static let deadlineQueue = DispatchQueue(
        label: "floe.jsexec.deadline",
        qos: .userInitiated
    )

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
        let errConsole = BoundedConsole(maxBytes: request.maxOutputBytes)
        let queue = makeQueue()

        // Race the evaluation against an independent GCD deadline. Using a
        // dispatch timer keeps timeout/cancellation prompt even when Swift's
        // cooperative executor is saturated by unrelated concurrent tests.
        let timeout = max(0.05, request.timeout)
        return await withCheckedContinuation { continuation in
            let race = ExecutionRace(continuation: continuation)

            // Submit the evaluation on a fresh serial queue. A fresh JSContext
            // per run guarantees isolation between executions.
            queue.async {
                let evaluation = Self.evaluate(
                    script: request.script,
                    inputJSON: request.inputJSON,
                    console: console,
                    errConsole: errConsole
                )
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                if let exception = evaluation.exceptionMessage {
                    race.finish(.jsException(message: exception, stdout: console.text))
                } else {
                    race.finish(.ok(
                        resultJSON: evaluation.resultJSON,
                        stdout: console.text,
                        stderr: errConsole.text,
                        truncated: console.isTruncated,
                        stderrTruncated: errConsole.isTruncated,
                        durationMs: durationMs
                    ))
                }
            }

            let timeoutNanoseconds = Int(timeout * 1_000_000_000)
            let deadline = DispatchTime.now() + .nanoseconds(timeoutNanoseconds)
            let timer = DispatchSource.makeTimerSource(queue: Self.deadlineQueue)
            timer.schedule(
                deadline: .now() + .milliseconds(10),
                repeating: .milliseconds(10),
                leeway: .milliseconds(2)
            )
            timer.setEventHandler {
                if cancellation?.isCancelled == true {
                    race.finish(.cancelled)
                } else if DispatchTime.now() >= deadline {
                    race.finish(.timedOut(
                        afterMs: Int(timeout * 1000),
                        partialStdout: console.text
                    ))
                }
            }
            timer.resume()
            race.install(timer: timer)
        }
    }

    /// Evaluates one script in a fresh JSContext. Only `@convention(block)`
    /// closures are injected; no Swift object ever enters the JS world.
    private static func evaluate(
        script: String,
        inputJSON: String?,
        console: BoundedConsole,
        errConsole: BoundedConsole
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

        // console.log/info → stdout buffer; console.warn/error → the
        // separate stderr buffer (PRD JS-01: capture stdout·stderr apart).
        // Arguments are serialized with String(...); never exposed as objects.
        let logBlock: @convention(block) (JSValue) -> Void = { value in
            console.append(value.toString())
        }
        let errBlock: @convention(block) (JSValue) -> Void = { value in
            errConsole.append(value.toString())
        }
        context.setObject(logBlock, forKeyedSubscript: "__floeLog" as NSString)
        context.setObject(errBlock, forKeyedSubscript: "__floeErr" as NSString)
        context.evaluateScript("""
            var console = {
                log: function() { __floeLog(Array.prototype.map.call(arguments, String).join(' ')); },
                info: function() { __floeLog(Array.prototype.map.call(arguments, String).join(' ')); },
                warn: function() { __floeErr(Array.prototype.map.call(arguments, String).join(' ')); },
                error: function() { __floeErr(Array.prototype.map.call(arguments, String).join(' ')); }
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

/// Exactly-once handoff for the evaluation/deadline race. The timer is always
/// resumed before installation so cancelling an already-finished race is safe.
private final class ExecutionRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ScriptExecutionOutcome, Never>?
    private var timer: DispatchSourceTimer?
    private var isFinished = false

    init(continuation: CheckedContinuation<ScriptExecutionOutcome, Never>) {
        self.continuation = continuation
    }

    func install(timer: DispatchSourceTimer) {
        lock.lock()
        if isFinished {
            lock.unlock()
            timer.cancel()
        } else {
            self.timer = timer
            lock.unlock()
        }
    }

    func finish(_ outcome: ScriptExecutionOutcome) {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return
        }
        isFinished = true
        self.continuation = nil
        let timer = self.timer
        self.timer = nil
        lock.unlock()

        timer?.cancel()
        continuation.resume(returning: outcome)
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

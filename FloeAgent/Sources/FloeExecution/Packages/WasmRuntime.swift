// FloeExecution — WASM command runtime contract.
// `pkg` installs sandboxed WASM commands from the signed capability catalog.
// The runtime itself (WasmKit + WASI) lives in the app target so the package
// stays free of iOS-only binary dependencies. Modules may read/write the
// workspace and /tmp, receive args/env/stdin, and have no sockets.

import Foundation
import FloeTools

public protocol WasmCommandRuntime: Sendable {
    func run(
        moduleURL: URL,
        arguments: [String],
        stdin: String?,
        environment: [String: String],
        rootURL: URL,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async -> ShellRunOutcome
}

public struct UnavailableWasmRuntime: WasmCommandRuntime {
    public let reason: String

    public init(reason: String = "The WASM command runtime is not available in this build") {
        self.reason = reason
    }

    public func run(
        moduleURL: URL,
        arguments: [String],
        stdin: String?,
        environment: [String: String],
        rootURL: URL,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken? = nil
    ) async -> ShellRunOutcome {
        .failed(message: reason)
    }
}

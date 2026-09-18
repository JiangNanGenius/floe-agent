// FloeExecution — WASM command runtime contract.
// `pkg` installs sandboxed WASM commands from the signed capability catalog.
// The interpreter runtime (WasmKit + WASI) is shared by app and package tests.
// It requires no iOS-only binary dependencies. Modules may read/write the
// workspace and /tmp, receive args/env/stdin, and have no sockets.
//
// Resource bounds arrive per invocation from the signed catalog entry
// (`moduleMaxBytes`, `memoryMaxBytes`); callers that do not carry catalog
// metadata get the conservative utility defaults.

import Foundation
import FloeTools

public protocol WasmCommandRuntime: Sendable {
    func run(
        moduleURL: URL,
        arguments: [String],
        stdin: String?,
        environment: [String: String],
        rootURL: URL,
        workingDirectory: String,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        moduleMaxBytes: Int,
        memoryMaxBytes: Int,
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
        workingDirectory: String = ".",
        timeout: TimeInterval,
        maxOutputBytes: Int,
        moduleMaxBytes: Int = WasmPackageLimits.defaultModuleMaxBytes,
        memoryMaxBytes: Int = WasmPackageLimits.defaultMemoryMaxBytes,
        cancellation: CancellationToken? = nil
    ) async -> ShellRunOutcome {
        .failed(message: reason)
    }
}

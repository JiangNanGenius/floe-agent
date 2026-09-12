import Foundation
import FloeCore
import FloeTools

/// Node.js runtime contract. The app injects a nodejs-mobile-backed
/// implementation; the shell routes `node`, `npm`, `npx`, `pnpm` and `yarn`
/// here. One interpreter instance is shared and serialized.
public struct NodeRunRequest: Sendable {
    /// Entry point: a script path, `-e` code, or a bundled tool path.
    public var entryScript: String?
    public var arguments: [String]
    public var workingDirectory: URL
    public var environment: [String: String]
    public var stdin: String?
    public var timeout: TimeInterval
    public var maxOutputBytes: Int

    public init(
        entryScript: String?,
        arguments: [String] = [],
        workingDirectory: URL,
        environment: [String: String] = [:],
        stdin: String? = nil,
        timeout: TimeInterval = 120,
        maxOutputBytes: Int = 256 * 1024
    ) {
        self.entryScript = entryScript
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.stdin = stdin
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }
}

public enum NodeRunOutcome: Sendable, Equatable {
    case exited(code: Int32, stdout: String, stderr: String, durationMs: Int, truncated: Bool = false)
    case timedOut(partialStdout: String, partialStderr: String, durationMs: Int)
    case cancelled
    case failed(message: String)
}

public protocol NodeRuntime: Sendable {
    func run(_ request: NodeRunRequest, cancellation: CancellationToken?) async -> NodeRunOutcome
}

public struct UnavailableNodeRuntime: NodeRuntime {
    public let reason: String

    public init(reason: String = "The bundled Node.js runtime is not available in this build") {
        self.reason = reason
    }

    public func run(_ request: NodeRunRequest, cancellation: CancellationToken?) async -> NodeRunOutcome {
        .failed(message: reason)
    }
}

/// Bundled tool entry points shipped with the Node runtime.
public enum NodeBundledTool: String, Sendable, CaseIterable {
    case npm = "npm/bin/npm-cli.js"
    case npx = "npm/bin/npx-cli.js"
    case pnpm = "pnpm/bin/pnpm.cjs"
    case pnpx = "pnpm/bin/pnpx.cjs"
    case yarn = "yarn/bin/yarn.js"

    public static func tool(for command: String) -> NodeBundledTool? {
        switch command {
        case "npm": return .npm
        case "npx": return .npx
        case "pnpm": return .pnpm
        case "pnpx": return .pnpx
        case "yarn": return .yarn
        default: return nil
        }
    }
}

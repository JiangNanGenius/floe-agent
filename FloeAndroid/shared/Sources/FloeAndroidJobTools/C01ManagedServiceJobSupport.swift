// SPDX-License-Identifier: MPL-2.0
//
// C01 managed-service job support (job-dcfe69f82e5b4cc1).
//
// A managed service is submitted through the EXISTING `jobs.submit` /
// `BackgroundJobService` path with a typed `service` declaration. The job
// target remains `exec.shell`; the durable job row, provenance, persistence,
// cancellation and recovery remain entirely the ORIGINAL service. There is no
// `exec.localService`, no Python/JavaScript/installer alias and no host
// process.
//
// This file only defines the cross-module job vocabulary; the real process,
// readiness and preview implementation is `C01ManagedServiceDomain` in
// FloeAndroidCore, injected as `C01ManagedServiceJobHosting` at composition.
// A missing host refuses the typed service mode before any job row exists.
import Foundation
import FloeCore
import FloeTools

/// Closed managed-service declaration accepted by `jobs.submit`.
public struct C01ManagedServiceDeclaration: Codable, Sendable, Equatable {
    public enum Runtime: String, Codable, Sendable, CaseIterable {
        /// `sh <entry>`
        case shell
        /// `node <entry>`
        case node
        /// `python3 <entry>`
        case python
        /// Static files: routed to the EXISTING `preview.start` path, never a
        /// service process.
        case `static`
    }

    public var runtime: Runtime
    /// Workspace-relative existing script (or HTML entry for `.static`).
    public var entry: String
    public var arguments: [String]?
    /// Workspace-relative working directory; nil/empty means the root.
    public var cwd: String?
    /// Loopback port the service must bind. Required for non-static runtimes.
    public var port: Int?
    /// C01 accepted Root epoch frozen by the TRUSTED submit path. It is not a
    /// model field: `C01ManagedServiceDomain.makeExecShellPayload` stamps the
    /// current bound epoch and the processor refuses a different generation.
    public var acceptedEpoch: UInt64?

    public init(runtime: Runtime, entry: String,
                arguments: [String]? = nil, cwd: String? = nil,
                port: Int? = nil, acceptedEpoch: UInt64? = nil) {
        self.runtime = runtime
        self.entry = entry
        self.arguments = arguments
        self.cwd = cwd
        self.port = port
        self.acceptedEpoch = acceptedEpoch
    }

    public var isStatic: Bool { runtime == .static }

    public func validateForJobSubmit() throws {
        guard !entry.isEmpty, entry.utf8.count <= 2048, !entry.contains("\0") else {
            throw FloeError.validationFailed(
                "service.entry must be a non-empty workspace-relative path (max 2048 bytes)")
        }
        guard !entry.hasPrefix("/"), !entry.hasPrefix("~"),
              !entry.split(separator: "/").contains("..") else {
            throw FloeError.validationFailed(
                "service.entry must be a workspace-relative path without '..'")
        }
        if let cwd {
            guard !cwd.isEmpty, cwd.utf8.count <= 2048, !cwd.contains("\0"),
                  !cwd.hasPrefix("/"), !cwd.hasPrefix("~"),
                  !cwd.split(separator: "/").contains("..") else {
                throw FloeError.validationFailed(
                    "service.cwd must be a workspace-relative path without '..' (max 2048 bytes)")
            }
        }
        if let arguments {
            guard arguments.count <= 32,
                  arguments.allSatisfy({ $0.utf8.count <= 2048 && !$0.contains("\0") }) else {
                throw FloeError.validationFailed(
                    "service.arguments accepts at most 32 entries, each max 2048 bytes")
            }
        }
        if isStatic {
            guard ["html", "htm"].contains((entry as NSString).pathExtension.lowercased()) else {
                throw FloeError.validationFailed("Static preview requires an existing .html/.htm entry")
            }
            guard arguments?.isEmpty != false, cwd == nil else {
                throw FloeError.validationFailed("Static preview takes only an HTML entry; use preview.start")
            }
        } else {
            guard let port, (1024...65535).contains(port) else {
                throw FloeError.validationFailed(
                    "service.port must be 1024...65535 for a running service")
            }
        }
    }

    /// True when the EXEC.SHELL payload carries the typed service object.
    public static func isServicePayload(_ payload: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return false
        }
        return object["service"] is [String: Any]
    }
}

/// Implemented by `C01ManagedServiceDomain`. The job module never knows the
/// process/transport details; it only routes the typed declaration.
public protocol C01ManagedServiceJobHosting: Sendable {
    /// Build the exact exec.shell payload submitted to the durable job: the
    /// caller's ordinary exec.shell arguments plus the typed service object.
    /// Throws before persistence when the declaration is invalid.
    func makeExecShellPayload(
        innerArguments: Data,
        declaration: C01ManagedServiceDeclaration
    ) throws -> Data

    /// Submit-time preflight for the job policy (called before the durable
    /// row exists). Normal exec.shell payloads pass through untouched.
    func validateJobPayload(_ payload: Data, workspaceRootURL: URL?) async throws

    /// Run the service-owned processor until the service really stops. The
    /// implementation owns the engine session, readiness, port and preview
    /// grant; it never returns merely because a view closed.
    func runServiceJob(payloadJSON: Data, context: ToolContext) async throws -> ToolExecutionOutput
}

/// Shared validation used by both the submit tool and the job preflight.
public enum C01ManagedServicePayload {
    public static let maximumInnerArgumentsBytes = 64 * 1024

    public static func decode(_ payload: Data) throws -> C01ManagedServiceDeclaration? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let raw = object["service"] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let declaration = try? JSONDecoder().decode(C01ManagedServiceDeclaration.self, from: data) else {
            throw FloeError.validationFailed("service must be a valid managed-service declaration")
        }
        try declaration.validateForJobSubmit()
        return declaration
    }

    public static func combine(
        innerArguments: Data,
        declaration: C01ManagedServiceDeclaration,
        acceptedEpoch: UInt64
    ) throws -> Data {
        guard innerArguments.count <= maximumInnerArgumentsBytes,
              let object = try? JSONSerialization.jsonObject(with: innerArguments) as? [String: Any] else {
            throw FloeError.validationFailed("arguments must be a JSON-encoded exec.shell object")
        }
        // The service declaration is the sole execution authority. Ordinary
        // exec.shell fields such as command/script/env/stdin/timeout/packages
        // must not be silently ignored here; only an optional cwd that agrees
        // with the declaration is accepted.
        let allowedInnerKeys: Set<String> = ["cwd"]
        guard object["service"] == nil,
              object.keys.allSatisfy({ allowedInnerKeys.contains($0) }) else {
            throw FloeError.validationFailed(
                "service mode takes only the typed service declaration; omit command/script/env/stdin/timeout/packages from arguments")
        }
        if let innerCwd = object["cwd"] as? String,
           innerCwd != (declaration.cwd ?? ".") {
            throw FloeError.validationFailed(
                "service.cwd must be declared in the service object, not a conflicting arguments.cwd")
        }
        var combined = object
        combined["cwd"] = declaration.cwd ?? "."
        var service: [String: Any] = [
            "runtime": declaration.runtime.rawValue,
            "entry": declaration.entry,
            "arguments": declaration.arguments ?? [],
            "cwd": declaration.cwd ?? ".",
            "port": declaration.port ?? 0,
        ]
        if acceptedEpoch > 0 { service["acceptedEpoch"] = acceptedEpoch }
        combined["service"] = service
        // The inner exec.shell validator still requires a bounded safe
        // command string. The service runner never executes this literal; it
        // is the typed operation's label and is re-checked by the host.
        combined["command"] = "managed-service \(declaration.runtime.rawValue) \(declaration.entry)"
        guard let data = try? JSONSerialization.data(withJSONObject: combined, options: [.sortedKeys]) else {
            throw FloeError.validationFailed("service arguments could not be encoded")
        }
        return data
    }
}

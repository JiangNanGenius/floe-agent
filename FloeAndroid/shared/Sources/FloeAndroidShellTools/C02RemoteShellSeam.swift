// SPDX-License-Identifier: MPL-2.0
//
// C02 — the ONE routing seam between the ordinary exec.shell service and the
// App-owned remote execution bridge. This file is a Main-owned additive file
// in FloeAndroidShellTools (it is listed in PATCHES, not applied by the
// source lane). It adds no tool, no command, no permission and no transport.
//
// The registered handler is produced by the G02 composition and calls the
// C02ExecutionTargetDomain/SSH adapter. Returning nil means "this context is
// not a remote target" and the existing local Linux backend runs unchanged.
import Foundation
import FloeCore
import FloeTools

public struct C02RemoteShellSeamRequest: Sendable {
    public var command: String
    public var cwd: String
    public var environment: [String: String]
    public var stdin: String?
    public var timeout: TimeInterval
    public var maxOutputBytes: Int
    public var isBackground: Bool
    public var context: ToolContext

    public init(
        command: String,
        cwd: String,
        environment: [String: String],
        stdin: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        isBackground: Bool,
        context: ToolContext
    ) {
        self.command = command
        self.cwd = cwd
        self.environment = environment
        self.stdin = stdin
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.isBackground = isBackground
        self.context = context
    }
}

public final class C02RemoteShellRouting: @unchecked Sendable {
    public typealias Handler =
        @Sendable (C02RemoteShellSeamRequest) async -> ShellRunOutcome?

    public static let shared = C02RemoteShellRouting()
    private let lock = NSLock()
    private var handler: Handler?
    private var epoch: UInt64?

    public init() {}

    public func configure(epoch: UInt64, _ handler: @escaping Handler) {
        lock.withLock {
            guard epoch > 0, self.epoch.map({ epoch >= $0 }) ?? true else { return }
            self.epoch = epoch
            self.handler = handler
        }
    }

    public func clear(epoch: UInt64) {
        lock.withLock {
            guard self.epoch == epoch else { return }
            handler = nil
        }
    }

    /// nil means the local Linux path is authoritative for this context.
    public func execute(_ request: C02RemoteShellSeamRequest) async -> ShellRunOutcome? {
        let handler = lock.withLock { self.handler }
        guard let handler else { return nil }
        return await handler(request)
    }
}

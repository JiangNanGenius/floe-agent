// FloeCore — Logging facade.
//
// Uses os.Logger on platforms that have it; falls back to a no-op otherwise
// so cross-platform targets build everywhere.

import Foundation

#if canImport(os)
import os
#endif

/// Category-tagged logger. Never log secrets: providers redact credentials
/// before constructing log messages.
public struct FloeLogger: Sendable {
    public enum Category: String, Sendable {
        case core, providers, runtime, tools, persistence, security, sync, ssh, vnc, app
    }

    private let category: Category

    #if canImport(os)
    private let underlying: os.Logger
    #endif

    public init(category: Category) {
        self.category = category
        #if canImport(os)
        self.underlying = os.Logger(subsystem: "org.floeagent.ios", category: category.rawValue)
        #endif
    }

    public func debug(_ message: @autoclosure () -> String) {
        #if canImport(os)
        let resolved = message()
        underlying.debug("\(resolved, privacy: .public)")
        #endif
    }

    public func info(_ message: @autoclosure () -> String) {
        #if canImport(os)
        let resolved = message()
        underlying.info("\(resolved, privacy: .public)")
        #endif
    }

    public func warning(_ message: @autoclosure () -> String) {
        #if canImport(os)
        let resolved = message()
        underlying.warning("\(resolved, privacy: .public)")
        #endif
    }

    public func error(_ message: @autoclosure () -> String) {
        #if canImport(os)
        let resolved = message()
        underlying.error("\(resolved, privacy: .public)")
        #endif
    }
}

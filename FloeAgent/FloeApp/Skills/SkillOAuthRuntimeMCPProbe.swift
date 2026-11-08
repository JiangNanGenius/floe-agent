#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import CoreFoundation
import FloeCore
import FloeExecution

/// Actual private-worker composition, never public exec.shell/PTY/job output.
/// The native account/vault adapter supplies its already validated profile and
/// broker configuration; a descriptor or model cannot supply a command.
enum SkillOAuthRuntimeMCPProbe {
    typealias Configuration = @Sendable (SkillRuntimeComponentCenter.OAuthProbeRequest) async throws -> LinuxGuestOAuthPrivateWorkerConfiguration

    static func make(opener: any LinuxGuestOAuthPrivateWorkerOpening,
                     configuration: @escaping Configuration) -> SkillRuntimeComponentCenter.OAuthProbe {
        { request in
            let config = try await configuration(request)
            guard config.environmentID == request.environmentID,
                  config.executablePath == request.executableGuestPath,
                  config.executableSHA256 == request.executableSHA256,
                  !request.cancellation.isCancelled else { throw SkillRuntimeComponentCenter.OAuthFailure.authority }
            let worker = try await opener.openOAuthPrivateWorker(configuration: config)
            let lifecycle = StopJoin(worker: worker)
            return try await withTaskCancellationHandler {
                do {
                    try check(request)
                    let initialize = try await worker.exchange(message(id: 1, method: "initialize", params: [
                        "protocolVersion": "2025-06-18", "capabilities": [:],
                        "clientInfo": ["name": "Floe private runtime probe", "version": "1"]]))
                    try check(request)
                    let initialized = try result(initialize, expectedID: 1)
                    let tools = try await worker.exchange(message(id: 2, method: "tools/list", params: [:]))
                    try check(request)
                    let listed = try result(tools, expectedID: 2)
                    guard await lifecycle.stop() else { throw SkillRuntimeComponentCenter.OAuthFailure.stopUnconfirmed }
                    try check(request)
                    return SkillRuntimeComponentCenter.OAuthProbeResult(initializeResult: initialized,
                        toolsListResult: listed, workerStopped: true)
                } catch {
                    guard await lifecycle.stop() else { throw SkillRuntimeComponentCenter.OAuthFailure.stopUnconfirmed }
                    throw error
                }
            } onCancel: {
                Task { _ = await lifecycle.stop() }
            }
        }
    }

    private actor StopJoin {
        let worker: any LinuxGuestOAuthPrivateWorker
        private var stopping: Task<Bool, Never>?
        init(worker: any LinuxGuestOAuthPrivateWorker) { self.worker = worker }
        func stop() async -> Bool {
            if let stopping { return await stopping.value }
            let task = Task { await worker.stop() }; stopping = task
            return await task.value
        }
    }
    private static func check(_ request: SkillRuntimeComponentCenter.OAuthProbeRequest) throws {
        try Task.checkCancellation()
        guard !request.cancellation.isCancelled else { throw CancellationError() }
    }
    private static func message(id: Int, method: String, params: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params],
                                   options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func result(_ bytes: Data, expectedID: Int) throws -> Data {
        guard bytes.count <= 65_536,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == ["jsonrpc", "id", "result"], object["jsonrpc"] as? String == "2.0",
              let identifier = object["id"] as? NSNumber, CFGetTypeID(identifier) != CFBooleanGetTypeID(),
              identifier.intValue == expectedID, identifier.doubleValue == Double(expectedID),
              let result = object["result"] as? [String: Any] else { throw SkillRuntimeComponentCenter.OAuthFailure.probe }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
#endif

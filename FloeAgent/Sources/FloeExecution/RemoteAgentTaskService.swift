import Foundation
import Crypto
import FloeCore
import FloeTools

/// Runs host commands through the installed Floe guardian. The remote job is
/// detached from the SSH tunnel, so polling can reconnect after Wi-Fi/VPN
/// changes without replaying the command.
public struct RemoteAgentTaskService: Sendable {
    public struct Result: Sendable {
        public var taskID: String
        public var state: String
        public var output: String
        public var exitCode: Int32
        public var duration: TimeInterval?
    }

    private let client: CloudWorkspaceService

    public init(client: CloudWorkspaceService) {
        self.client = client
    }

    public func runHost(
        command: String,
        hostID: UUID?,
        runID: UUID,
        toolCallID: String,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken
    ) async throws -> Result {
        let taskID = Self.taskID(runID: runID, toolCallID: toolCallID)
        let body = try JSONSerialization.data(withJSONObject: [
            "task_id": taskID,
            "command": command,
            "target": ["kind": "host"],
            "explicit_host_authority": true
        ])
        _ = try await retryingRequest(
            hostID: hostID, method: "POST", endpoint: "v1/tasks", body: body,
            cancellation: cancellation
        )

        let deadline = Date().addingTimeInterval(max(1, timeout))
        var lastTransportError: Error?
        while Date() < deadline {
            if cancellation.isCancelled {
                _ = try? await client.requestJSON(
                    hostID: hostID,
                    method: "POST",
                    endpoint: "v1/tasks/\(taskID)/cancel",
                    body: Data("{}".utf8)
                )
                throw FloeError.cancelled
            }
            do {
                let data = try await client.requestJSON(
                    hostID: hostID, method: "GET", endpoint: "v1/tasks/\(taskID)"
                )
                let record = try Self.object(data)
                let state = record["state"] as? String ?? "unknown"
                if ["succeeded", "failed", "cancelled", "interrupted"].contains(state) {
                    let log = try await readOutput(
                        hostID: hostID,
                        taskID: taskID,
                        maxOutputBytes: maxOutputBytes
                    )
                    return Result(
                        taskID: taskID,
                        state: state,
                        output: log,
                        exitCode: Int32(record["exit_code"] as? Int ?? (state == "succeeded" ? 0 : 1)),
                        duration: record["duration"] as? Double
                    )
                }
                lastTransportError = nil
            } catch {
                lastTransportError = error
            }
            try? await Task.sleep(for: .milliseconds(lastTransportError == nil ? 400 : 900))
        }
        if let lastTransportError {
            throw lastTransportError
        }
        return Result(
            taskID: taskID,
            state: "running",
            output: "Remote guardian task is still running; reconnect with the same task id.",
            exitCode: 124,
            duration: nil
        )
    }

    private func retryingRequest(
        hostID: UUID?,
        method: String,
        endpoint: String,
        body: Data?,
        cancellation: CancellationToken
    ) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<3 {
            if cancellation.isCancelled { throw FloeError.cancelled }
            do {
                return try await client.requestJSON(
                    hostID: hostID, method: method, endpoint: endpoint, body: body
                )
            } catch {
                lastError = error
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(300 * (attempt + 1))) }
            }
        }
        throw lastError ?? FloeError.internalError("Remote guardian request failed")
    }

    private func readOutput(hostID: UUID?, taskID: String, maxOutputBytes: Int) async throws -> String {
        let data = try await client.requestJSON(
            hostID: hostID,
            method: "GET",
            endpoint: "v1/tasks/\(taskID)/events"
        )
        let object = try Self.object(data)
        guard let encoded = object["data_base64"] as? String,
              let decoded = Data(base64Encoded: encoded) else { return "" }
        return String(decoding: decoded.prefix(max(0, maxOutputBytes)), as: UTF8.self)
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FloeError.validationFailed("Remote guardian returned invalid JSON")
        }
        return value
    }

    static func taskID(runID: UUID, toolCallID: String) -> String {
        let digest = SHA256.hash(data: Data(toolCallID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "\(runID.uuidString.lowercased())-\(digest.prefix(24))"
    }
}

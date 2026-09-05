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

        public init(
            taskID: String,
            state: String,
            output: String,
            exitCode: Int32,
            duration: TimeInterval?
        ) {
            self.taskID = taskID
            self.state = state
            self.output = output
            self.exitCode = exitCode
            self.duration = duration
        }
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

        do {
            return try await status(
                taskID: taskID,
                hostID: hostID,
                wait: timeout,
                maxOutputBytes: maxOutputBytes,
                cancellation: cancellation
            )
        } catch let error as FloeError where error == .cancelled {
            // Stopping the original ssh.execute owns cancellation of the
            // remote child. A later read-only ssh.taskStatus cancellation
            // deliberately does not mutate the durable task.
            _ = try? await client.requestJSON(
                hostID: hostID,
                method: "POST",
                endpoint: "v1/tasks/\(taskID)/cancel",
                body: Data("{}".utf8)
            )
            throw error
        }
    }

    /// Reconnects to an existing durable guardian task without dispatching
    /// its command again. This is the continuation path returned by
    /// `ssh.execute` when a command outlives one model/tool turn.
    public func status(
        taskID: String,
        hostID: UUID?,
        wait: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken
    ) async throws -> Result {
        guard Self.isValidTaskID(taskID) else {
            throw FloeError.validationFailed("Invalid remote guardian task id")
        }
        let deadline = Date().addingTimeInterval(max(0, wait))
        var lastTransportError: Error?
        repeat {
            if cancellation.isCancelled {
                throw FloeError.cancelled
            }
            do {
                let data = try await retryingRequest(
                    hostID: hostID,
                    method: "GET",
                    endpoint: "v1/tasks/\(taskID)",
                    body: nil,
                    cancellation: cancellation
                )
                let record = try Self.object(data)
                let state = record["state"] as? String ?? "unknown"
                if ["succeeded", "failed", "cancelled", "interrupted"].contains(state) {
                    let log = try await readOutput(
                        hostID: hostID,
                        taskID: taskID,
                        maxOutputBytes: maxOutputBytes,
                        cancellation: cancellation
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
                if cancellation.isCancelled { throw FloeError.cancelled }
                lastTransportError = error
            }
            guard Date() < deadline else { break }
            try? await Task.sleep(for: .milliseconds(lastTransportError == nil ? 400 : 900))
        } while Date() < deadline
        if let lastTransportError {
            throw lastTransportError
        }
        let partial = (try? await readOutput(
            hostID: hostID,
            taskID: taskID,
            maxOutputBytes: maxOutputBytes,
            cancellation: cancellation
        )) ?? ""
        return Result(
            taskID: taskID,
            state: "running",
            output: partial.isEmpty
                ? "Remote guardian task is still running. Use ssh.taskStatus with this taskID; do not dispatch the command again."
                : partial,
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

    public func cancel(taskID: String, hostID: UUID?, cancellation: CancellationToken) async throws -> String {
        guard Self.isValidTaskID(taskID) else {
            throw FloeError.validationFailed("Invalid remote guardian task id")
        }
        let data = try await retryingRequest(
            hostID: hostID, method: "POST", endpoint: "v1/tasks/\(taskID)/cancel",
            body: Data("{}".utf8), cancellation: cancellation
        )
        let record = try Self.object(data)
        guard let state = record["state"] as? String,
              ["cancelRequested", "cancelled", "succeeded", "failed", "interrupted"].contains(state) else {
            throw FloeError.validationFailed("Guardian did not return a confirmed cancellation state")
        }
        return state
    }

    private func readOutput(
        hostID: UUID?,
        taskID: String,
        maxOutputBytes: Int,
        cancellation: CancellationToken
    ) async throws -> String {
        let data = try await retryingRequest(
            hostID: hostID,
            method: "GET",
            endpoint: "v1/tasks/\(taskID)/events",
            body: nil,
            cancellation: cancellation
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

    static func isValidTaskID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil
    }
}

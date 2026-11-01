#if os(macOS)
import Foundation
import Testing
import FloeMacBridgeProtocol
@testable import FloeMacBridgeApp

@Suite("Mac Bridge sensitive process output")
struct BridgeSensitiveJobTests {
    @Test("Real PTY receives process env while persistent and polled bytes stay redacted")
    func actualJobRedactsBeforePersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-bridge-job-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try BridgePaths(home: root)
        let jobs = BridgeJobs(paths: paths)
        let id = UUID().uuidString, client = "fixture-client"
        let name = "BRIDGE_QUAL_TOKEN", secret = "fixture-only-secret-\(UUID().uuidString)"
        let originalParentValue = ProcessInfo.processInfo.environment[name]
        // The command contains only a variable name. The synthetic value is
        // delivered through the real native envp path, never argv or a file.
        let command = #"printf 'full:%s\n' "$BRIDGE_QUAL_TOKEN"; printf '%s' "${BRIDGE_QUAL_TOKEN:0:7}"; sleep 0.05; printf '%s\n' "${BRIDGE_QUAL_TOKEN:7}""#
        do {
            _ = try await jobs.start(id: id, clientID: client, workspaceID: "fixture-workspace",
                command: command, cwd: root, environment: [name: secret],
                sensitiveEnvironmentNames: [name], columns: 80, rows: 24)
            var result: [String: BridgeValue] = [:]
            let deadline = Date().addingTimeInterval(5)
            repeat {
                result = try await jobs.poll(id: id, clientID: client, offset: 0, limit: 65_536)
                if result["alive"] == .bool(false) { break }
                try await Task.sleep(for: .milliseconds(20))
            } while Date() < deadline
            #expect(result["alive"] == .bool(false))
            #expect(result["exitCode"] == .integer(0))
            let bytes = try #require(result["data"]?.string.flatMap { Data(base64Encoded: $0) })
            let text = String(decoding: bytes, as: UTF8.self)
            #expect(text.contains("full:[REDACTED]"))
            #expect(!text.contains(secret))
            #expect(text.components(separatedBy: "[REDACTED]").count >= 3)
            let task = try paths.managed("Tasks", id: id)
            for file in try FileManager.default.contentsOfDirectory(at: task, includingPropertiesForKeys: nil) {
                let data = try Data(contentsOf: file)
                #expect(data.range(of: Data(secret.utf8)) == nil)
            }
            let persisted = try Data(contentsOf: task.appendingPathComponent("output.bin"))
            #expect(persisted == bytes)
            #expect(ProcessInfo.processInfo.environment[name] == originalParentValue)
        } catch {
            await jobs.stopAllAndWait()
            throw error
        }
        await jobs.stopAllAndWait()
    }
}
#endif

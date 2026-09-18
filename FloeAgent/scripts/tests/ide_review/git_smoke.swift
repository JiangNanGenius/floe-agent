// Focused compile smoke test for the Build191 IDE review harness.
import Foundation
import FloeCore

@main
struct SmokeMain {
    static func main() async throws {
        let service = LocalGitService()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("floe-review-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await service.initialize(at: root, authorName: "Review", authorEmail: "review@floe.dev", initialBranch: "main")
        let snapshot = try await service.snapshot(at: root)
        print("smoke ok branch=\(snapshot.branch ?? "nil")")
    }
}

import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration

/// Real cross-process evidence for the per-document flock claim: an
/// external process (python3) holds LOCK_EX on the document lock file while
/// the repository tries to load — the load must block until the foreign
/// lock is released. (The earlier suite only evidenced two instances in
/// one process.)
final class FileRepositoryCrossProcessTests: XCTestCase {
    private func pythonPath() -> String {
        for candidate in [
            "/Library/Developer/CommandLineTools/usr/bin/python3",
            "/usr/bin/python3",
        ] where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        XCTFail("no system python3 available for the subprocess lock test")
        return "/usr/bin/python3"
    }

    func testExternalProcessLockBlocksRepositoryLoad() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-xproc-\(UUID().uuidString)")
        let snapshot = CanvasSnapshot(
            name: "X", pages: [CanvasPageSnapshot(name: "P")])
        let repo = try FileCanvasRepository(root: root)
        try await repo.create(
            canvasID: snapshot.id, snapshot: snapshot, requestID: UUID())

        let lockURL = root
            .appendingPathComponent("canvases", isDirectory: true)
            .appendingPathComponent(snapshot.id.uuidString, isDirectory: true)
            .appendingPathComponent("\(snapshot.id.uuidString).lock")
        let markerURL = root.appendingPathComponent("locked.marker")
        defer { try? FileManager.default.removeItem(at: root) }

        let script = """
        import fcntl, os, sys, time
        fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        open(sys.argv[2], "w").write("locked")
        time.sleep(1.5)
        os._exit(0)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath())
        process.arguments = ["-c", script, lockURL.path, markerURL.path]
        try process.run()

        // Wait (bounded) for the subprocess to actually hold the lock.
        var acquired = false
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: markerURL.path) {
                acquired = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(acquired, "subprocess never acquired the flock")

        let start = Date()
        let loaded = try await repo.load(canvasID: snapshot.id)
        let elapsed = Date().timeIntervalSince(start)
        process.waitUntilExit()
        XCTAssertEqual(loaded.id, snapshot.id)
        XCTAssertGreaterThanOrEqual(
            elapsed, 1.0,
            "repository load must block behind the cross-process flock "
                + "(elapsed \(elapsed)s)")
    }
}

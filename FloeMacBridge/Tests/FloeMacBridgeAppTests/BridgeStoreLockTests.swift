#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import FloeMacBridgeApp

@Suite("Bridge store single-owner lock", .serialized)
struct BridgeStoreLockTests {
    private func root(_ label: String) -> URL {
        let base = ProcessInfo.processInfo.environment["FLOE_BRIDGE_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("bridge-lock-\(label)-\(UUID())")
    }

    @Test("a second owner fails closed and release admits the next owner")
    func exclusiveOwnership() throws {
        let directory = root("exclusive")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try BridgeStoreLock(root: directory)
        defer { first.release() }
        #expect(first.isHeld)
        #expect(first.url.lastPathComponent == "bridge-store.lock")
        #expect(first.ownerRecord.pid == getpid())
        #expect(first.ownerRecord.storeRoot == directory.standardizedFileURL.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: first.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        do {
            _ = try BridgeStoreLock(root: directory)
            Issue.record("A second service acquired the same store")
        } catch let error as BridgeStoreLockError {
            guard case .alreadyOwned(let owner) = error else {
                Issue.record("Unexpected lock error: \(error)")
                return
            }
            #expect(owner?.pid == getpid())
        }
        first.release()
        #expect(!first.isHeld)
        let second = try BridgeStoreLock(root: directory)
        #expect(second.isHeld)
        second.release()
    }

    @Test("deinit releases the descriptor and does not leave a stale owner")
    func deinitReleases() throws {
        let directory = root("deinit")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let held = try BridgeStoreLock(root: directory)
            #expect(held.isHeld)
        }
        let next = try BridgeStoreLock(root: directory)
        #expect(next.isHeld)
        next.release()
    }

    @Test("a separate process holding the flock excludes this service")
    func crossProcessExclusion() throws {
        let directory = root("cross-process")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("State", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let lockURL = state.appendingPathComponent("bridge-store.lock")
        let script = """
        import fcntl, os, sys, time
        fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        sys.stdout.write("ready\\n")
        sys.stdout.flush()
        time.sleep(30)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, lockURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let ready = pipe.fileHandleForReading.readData(ofLength: 6)
        #expect(ready == Data("ready\n".utf8))
        do {
            _ = try BridgeStoreLock(root: directory)
            Issue.record("The same store was acquired across processes")
        } catch let error as BridgeStoreLockError {
            guard case .alreadyOwned = error else {
                Issue.record("Unexpected cross-process lock error: \(error)")
                return
            }
        }
        process.terminate()
        process.waitUntilExit()
        let after = try BridgeStoreLock(root: directory)
        #expect(after.isHeld)
        after.release()
    }

    @Test("a symlinked lock path is rejected without touching the target")
    func symlinkRejected() throws {
        let directory = root("symlink")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("State", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target.txt")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: state.appendingPathComponent("bridge-store.lock"),
            withDestinationURL: target
        )
        do {
            _ = try BridgeStoreLock(root: directory)
            Issue.record("A symlinked lock path was accepted")
        } catch { }
        #expect(try Data(contentsOf: target) == Data("unchanged".utf8))
    }

    @Test("a non-regular lock file is rejected")
    func directoryRejected() throws {
        let directory = root("directory")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("State", isDirectory: true)
        try FileManager.default.createDirectory(
            at: state.appendingPathComponent("bridge-store.lock", isDirectory: true),
            withIntermediateDirectories: true
        )
        do {
            _ = try BridgeStoreLock(root: directory)
            Issue.record("A directory was accepted as the lock")
        } catch { }
    }
}
#endif

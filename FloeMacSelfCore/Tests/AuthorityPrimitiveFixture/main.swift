// Standalone synthetic-only checks for FloeAuthorityPrimitive. Every root is
// uniquely created and deliberately retained; no test removes fixture data.
import Darwin
import Foundation

enum FixtureFailure: Error { case failed(String) }

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw FixtureFailure.failed(message) }
}

func expectFailure(_ name: String, expected: FloeAuthorityPrimitiveError, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch let actual as FloeAuthorityPrimitiveError {
        guard actual == expected else {
            throw FixtureFailure.failed("\(name): expected \(expected), got \(actual)")
        }
        print("PASS \(name): \(actual)")
        return
    } catch {
        throw FixtureFailure.failed("\(name): expected \(expected), got unrelated error \(error)")
    }
    throw FixtureFailure.failed("expected failure: \(name)")
}

func makeRoot() throws -> URL {
    // macOS may return /var (a system symlink); resolve only the temporary
    // parent before creating our unique root, never loosen the primitive.
    guard let canonical = realpath(NSTemporaryDirectory(), nil) else {
        throw FixtureFailure.failed("resolve temporary parent")
    }
    defer { free(canonical) }
    let base = String(cString: canonical)
    var template = Array((base + "/floe-authority-fixture.XXXXXXXX").utf8CString)
    guard let result = mkdtemp(&template) else { throw FixtureFailure.failed("mkdtemp") }
    let url = URL(fileURLWithPath: String(cString: result), isDirectory: true)
    print("FIXTURE \(url.path)")
    return url
}

func createFile(_ url: URL, text: String, mode: mode_t = 0o600) throws {
    let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
    guard fd >= 0 else { throw FixtureFailure.failed("create fixture file") }
    defer { Darwin.close(fd) }
    let bytes = Array(text.utf8)
    let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    try require(count == bytes.count, "write fixture file")
}

func identity(_ url: URL) throws -> FloeAuthorityIdentity {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { throw FixtureFailure.failed("stat fixture") }
    return FloeAuthorityIdentity(value)
}

func fileMode(_ url: URL) throws -> mode_t {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { throw FixtureFailure.failed("stat mode") }
    return value.st_mode & 0o7777
}

func openAuthority(_ root: URL, expectedLock: FloeAuthorityIdentity? = nil) throws -> FloeAuthorityPrimitive {
    try FloeAuthorityPrimitive(trustedDirectoryPath: root.path,
        expectedDirectory: identity(root), expectedDatabase: identity(root.appendingPathComponent("floe.sqlite")),
        expectedExistingLock: expectedLock)
}

func childProbe(_ root: URL) throws {
    let lock = root.appendingPathComponent("floe.sqlite.floe-self-authority.lock")
    do {
        let instance = try openAuthority(root, expectedLock: identity(lock))
        instance.release()
        throw FixtureFailure.failed("child unexpectedly acquired lock")
    } catch FloeAuthorityPrimitiveError.busy {
        print("CHILD_BUSY")
    }
}

func testBusyProcess(_ root: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    process.arguments = ["--probe-busy", root.path]
    // A task-owned regular file avoids pipe backpressure while we wait. Keep
    // the exact child output even on timeout or failure; no fixture is deleted.
    let outputURL = root.appendingPathComponent("child-output-\(UUID().uuidString).log")
    try createFile(outputURL, text: "")
    let outputFD = Darwin.open(outputURL.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
    guard outputFD >= 0 else { throw FixtureFailure.failed("open child output") }
    let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
    defer { try? output.close() }
    process.standardOutput = output
    process.standardError = output
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    print("CHILD_OUTPUT \(outputURL.path)")
    try process.run()
    if exited.wait(timeout: .now() + 5) == .timedOut {
        // The Process handle and PID belong to this one synthetic test child.
        // Bounded shutdown preserves the timeout as a failure, never a pass.
        if process.isRunning { process.terminate() }
        if exited.wait(timeout: .now() + 2) == .timedOut {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            _ = exited.wait(timeout: .now() + 2)
        }
        throw FixtureFailure.failed("child timed out; output retained at \(outputURL.path)")
    }
    try output.synchronize()
    let data = try Data(contentsOf: outputURL)
    let text = String(decoding: data, as: UTF8.self)
    try require(process.terminationReason == .exit && process.terminationStatus == 0 && text.contains("CHILD_BUSY"),
                "separate process must observe held flock: \(text)")
}

func run() throws {
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--probe-busy" {
        try childProbe(URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
        return
    }

    let sentinelRoot = try makeRoot()
    try createFile(sentinelRoot.appendingPathComponent("floe.sqlite"), text: "db-sentinel")
    let sentinelLock = sentinelRoot.appendingPathComponent("floe.sqlite.floe-self-authority.lock")
    try createFile(sentinelLock, text: "user-sentinel")
    let sentinelIdentity = try identity(sentinelLock)
    let beforeMode = try fileMode(sentinelLock)
    // Positive control in this synthetic root: the same inode is accepted
    // only when the trusted-host fixture supplies its exact prior identity.
    let sentinelControl = try openAuthority(sentinelRoot, expectedLock: sentinelIdentity)
    try sentinelControl.verifyHeld()
    sentinelControl.release()
    try expectFailure("unknown existing lock rejected", expected: .untrustedExistingLock) { _ = try openAuthority(sentinelRoot) }
    try require(try String(contentsOf: sentinelLock, encoding: .utf8) == "user-sentinel", "existing bytes changed")
    try require(try fileMode(sentinelLock) == beforeMode, "existing mode changed")
    try require(try identity(sentinelLock) == sentinelIdentity, "existing inode changed")

    let modeRoot = try makeRoot()
    try createFile(modeRoot.appendingPathComponent("floe.sqlite"), text: "database")
    let modeLock = modeRoot.appendingPathComponent("floe.sqlite.floe-self-authority.lock")
    try createFile(modeLock, text: "nonprivate")
    let modeIdentity = try identity(modeLock)
    let modeControl = try openAuthority(modeRoot, expectedLock: modeIdentity)
    try modeControl.verifyHeld()
    modeControl.release()
    try require(chmod(modeLock.path, 0o644) == 0, "fixture lock chmod")
    try expectFailure("nonprivate existing lock rejected", expected: .unsafeLock) { _ = try openAuthority(modeRoot, expectedLock: modeIdentity) }
    try require(try fileMode(modeLock) == 0o644, "nonprivate mode changed")
    try require(try String(contentsOf: modeLock, encoding: .utf8) == "nonprivate", "nonprivate contents changed")

    let root = try makeRoot()
    try createFile(root.appendingPathComponent("floe.sqlite"), text: "db-sentinel")
    let owned = try openAuthority(root)
    let knownLock = owned.lockIdentity
    try owned.verifyHeld()
    try testBusyProcess(root)
    print("PASS separate process flock")
    owned.release()
    let reopened = try openAuthority(root, expectedLock: knownLock)
    try reopened.verifyHeld()
    reopened.release()
    print("PASS known lock reopen")

    let symlinkRoot = try makeRoot()
    let target = symlinkRoot.appendingPathComponent("target")
    let symlinkDatabase = symlinkRoot.appendingPathComponent("floe.sqlite")
    try createFile(symlinkDatabase, text: "keep")
    let symlinkControl = try openAuthority(symlinkRoot)
    try symlinkControl.verifyHeld()
    symlinkControl.release()
    try require(rename(symlinkDatabase.path, target.path) == 0, "retain symlink control database")
    try FileManager.default.createSymbolicLink(atPath: symlinkDatabase.path,
                                               withDestinationPath: target.path)
    try expectFailure("database symlink rejected", expected: .unsafeDatabase) { _ = try openAuthority(symlinkRoot) }

    let hardlinkRoot = try makeRoot()
    let hardTarget = hardlinkRoot.appendingPathComponent("original")
    let hardDatabase = hardlinkRoot.appendingPathComponent("floe.sqlite")
    try createFile(hardDatabase, text: "keep")
    let hardControl = try openAuthority(hardlinkRoot)
    try hardControl.verifyHeld()
    hardControl.release()
    try require(link(hardDatabase.path, hardTarget.path) == 0, "create test hardlink")
    try expectFailure("database hardlink rejected", expected: .unsafeDatabase) { _ = try openAuthority(hardlinkRoot) }

    let symlinkDirRoot = try makeRoot()
    try createFile(symlinkDirRoot.appendingPathComponent("floe.sqlite"), text: "keep")
    let directoryControl = try openAuthority(symlinkDirRoot)
    try directoryControl.verifyHeld()
    directoryControl.release()
    let alias = symlinkDirRoot.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: ".")
    try expectFailure("directory symlink rejected", expected: .unsafeDirectory) {
        _ = try FloeAuthorityPrimitive(trustedDirectoryPath: alias.path,
            expectedDirectory: identity(symlinkDirRoot), expectedDatabase: identity(symlinkDirRoot.appendingPathComponent("floe.sqlite")))
    }

    let replaceRoot = try makeRoot()
    let db = replaceRoot.appendingPathComponent("floe.sqlite")
    try createFile(db, text: "original")
    let pinned = try openAuthority(replaceRoot)
    try require(rename(db.path, replaceRoot.appendingPathComponent("retained-original.sqlite").path) == 0, "retain original fixture db")
    try createFile(db, text: "replacement")
    try expectFailure("database replacement rejected", expected: .unsafeDatabase) { try pinned.verifyHeld() }
    pinned.release()

    let directoryRoot = try makeRoot()
    try createFile(directoryRoot.appendingPathComponent("floe.sqlite"), text: "original")
    let directoryPinned = try openAuthority(directoryRoot)
    let retainedRoot = directoryRoot.path + ".retained-" + UUID().uuidString
    try require(rename(directoryRoot.path, retainedRoot) == 0, "retain original fixture directory")
    try require(mkdir(directoryRoot.path, 0o700) == 0, "create replacement fixture directory")
    try expectFailure("directory replacement rejected", expected: .unsafeDirectory) { try directoryPinned.verifyHeld() }
    directoryPinned.release()

    let lockReplaceRoot = try makeRoot()
    try createFile(lockReplaceRoot.appendingPathComponent("floe.sqlite"), text: "original")
    let lockPinned = try openAuthority(lockReplaceRoot)
    let lockPath = lockReplaceRoot.appendingPathComponent("floe.sqlite.floe-self-authority.lock")
    try require(rename(lockPath.path, lockReplaceRoot.appendingPathComponent("retained-original.lock").path) == 0, "retain original fixture lock")
    try createFile(lockPath, text: "replacement")
    try expectFailure("lock replacement rejected", expected: .unsafeLock) { try lockPinned.verifyHeld() }
    lockPinned.release()

    print("ALL AUTHORITY PRIMITIVE FIXTURES PASSED")
}

do { try run() } catch {
    FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
    exit(1)
}

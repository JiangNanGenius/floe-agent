// Floe Mac M00 — fixture-only kernel confinement.
//
// SPDX-License-Identifier: MPL-2.0
//
// Fixture mode is not protected by path validation alone: BridgePaths and
// BridgeJobs reopen absolute paths after startup. This file therefore applies
// a Seatbelt profile to the helper process itself before it creates identity,
// storage, control files or a task. The intended profile attempts to limit
// filesystem, network and IPC access, but its listener ownership, inherited
// descriptors, Mach rights and child-directory pinning are not verified.
// Fixture preparation fails before touching paths until these are resolved.
//
// The profile is generated from the root that was already checked to be a
// direct mkdtemp child of the canonical user temporary directory. A caller can
// not substitute a policy file or point the policy at the real Bridge root.

import CryptoKit
import Darwin
import Foundation

@_silgen_name("sandbox_init")
private func floe_sandbox_init(_ profile: UnsafePointer<CChar>, _ flags: UInt64,
                               _ errorBuffer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

enum FixtureSandboxError: Error, LocalizedError, Sendable {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

struct FixtureSandboxCheck: Codable, Sendable {
    var name: String
    var passed: Bool
    var detail: String
}

struct FixtureSandboxReport: Codable, Sendable {
    var schema: String
    var root: String
    var rootDevice: UInt64
    var rootInode: UInt64
    var httpPort: UInt16
    var profileSHA256: String
    var applied: Bool
    var checks: [FixtureSandboxCheck]
    var timestamp: String
}

struct FixtureRoot: Sendable {
    let location: FixtureRootLocation
    let controlDirectory: URL
    let controlSocket: URL
    let readyFile: URL
    let discoveryFile: URL
    let serviceHome: URL
    let workerHome: URL
    let tempDirectory: URL
    /// Loopback port reserved before the sandbox was applied. The profile
    /// allows binding and accepting connections only on this port.
    let httpPort: UInt16
    let profile: String
    let profileSHA256: String

    func verifyPinned() throws {
        try location.verifyPinned()
    }
}

enum FixtureSandbox {
    // Test helper must fail before touching any fixture path or opening any
    // listener until descriptor ownership, anchored paths and IPC confinement
    // are implemented and independently verified. No environment override.
    private static let fixtureIsolationVerified = false

    static func prepare(arguments: ServiceArguments) throws -> FixtureRoot {
        guard fixtureIsolationVerified else {
            throw FixtureSandboxError.message("Fixture isolation is not verified; test mode is disabled.")
        }
        guard arguments.mode == .test, let fixtureArgument = arguments.testFixture,
              let controlSocket = arguments.controlSocket, let readyFile = arguments.readyFile,
              let discoveryFile = arguments.discoveryFile else {
            throw FixtureSandboxError.message("A fixture root and all control paths are required.")
        }
        let location = try FixtureRootLocation.validateExisting(fixtureArgument)
        try location.ensureLayout()
        try validateControlPath(controlSocket, location: location)
        try validateControlPath(readyFile, location: location)
        try validateControlPath(discoveryFile, location: location)
        let names = [controlSocket, readyFile, discoveryFile].map(\.lastPathComponent)
        guard Set(names).count == names.count else {
            throw FixtureSandboxError.message("Control file names must be distinct.")
        }

        let environment = ProcessInfo.processInfo.environment
        let workerHome = location.workerHome
        let expectedWorker = try FixtureRootLocation.canonicalDirectory(workerHome, label: "fixture worker-home")
        for key in ["HOME", "CFFIXED_USER_HOME"] {
            guard let raw = environment[key] else {
                throw FixtureSandboxError.message("\(key) must point at the fixture worker-home.")
            }
            let canonical = try FixtureRootLocation.canonicalDirectory(
                URL(fileURLWithPath: raw, isDirectory: true), label: key
            )
            guard canonical == expectedWorker else {
                throw FixtureSandboxError.message("\(key) must point at the fixture worker-home, not the service storage.")
            }
        }
        for key in ["HOME", "CFFIXED_USER_HOME"] {
            setenv(key, expectedWorker, 1)
        }
        let tempDirectory = location.tempDirectory
        _ = try FixtureRootLocation.canonicalDirectory(tempDirectory, label: "fixture tmp")
        for key in ["TMPDIR", "TMP", "TEMP"] {
            setenv(key, tempDirectory.path, 1)
        }
        guard chdir(location.rootURL.path) == 0 else {
            throw FixtureSandboxError.message("Could not enter the fixture root: \(String(cString: strerror(errno)))")
        }

        let realHome = ServicePaths.realUserHome
        let realBridge = ServicePaths.userBridgeRoot
        let keychain = realHome.appendingPathComponent("Library/Keychains", isDirectory: true)
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let infoPlist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let canonicalSocket = location.controlDirectory.appendingPathComponent(controlSocket.lastPathComponent, isDirectory: false)
        let canonicalReady = location.controlDirectory.appendingPathComponent(readyFile.lastPathComponent, isDirectory: false)
        let canonicalDiscovery = location.controlDirectory.appendingPathComponent(discoveryFile.lastPathComponent, isDirectory: false)
        // This port is only a candidate, not a retained reservation. The
        // helper remains disabled until listener ownership is fixed and tested.
        let httpPort = try reserveLoopbackPort()
        let profile = makeProfile(
            root: location.rootURL.path,
            controlSocket: canonicalSocket.path,
            httpPort: httpPort,
            home: realHome.path,
            bridgeRoot: realBridge.path,
            keychain: keychain.path,
            executable: executable.path,
            infoPlist: infoPlist.path
        )
        let digest = SHA256.hash(data: Data(profile.utf8)).map { String(format: "%02x", $0) }.joined()

        let homeExisted = pathExists(realHome.path)
        let bridgeExisted = pathExists(realBridge.path)
        let keychainExisted = pathExists(keychain.path)
        var checks: [FixtureSandboxCheck] = []
        try apply(profile: profile)
        checks.append(FixtureSandboxCheck(name: "sandbox_applied", passed: true,
                                          detail: "sandbox_init returned 0; this does not by itself prove every rule"))
        try verifyPinnedRoot(location, checks: &checks)
        checks.append(deniedDirectoryCheck(name: "home_root_read_denied", path: realHome.path,
                                          existedBefore: homeExisted))
        checks.append(deniedDirectoryCheck(name: "real_bridge_root_denied", path: realBridge.path,
                                          existedBefore: bridgeExisted))
        checks.append(deniedDirectoryCheck(name: "keychain_directory_denied", path: keychain.path,
                                          existedBefore: keychainExisted))
        checks.append(writeInsideRootCheck(location))
        // An OSStatus or an unowned endpoint cannot independently prove
        // Seatbelt confinement. These remain failing until a separately
        // reviewed, task-owned positive/negative verification exists.
        checks.append(FixtureSandboxCheck(name: "network_isolation_unverified", passed: false,
                                          detail: "owned listener and descendant confinement not verified"))
        checks.append(FixtureSandboxCheck(name: "keychain_isolation_unverified", passed: false,
                                          detail: "Keychain status alone does not prove sandbox denial"))

        let report = FixtureSandboxReport(
            schema: "floe-mac-bridge-fixture-sandbox-v2",
            root: location.rootURL.path,
            rootDevice: UInt64(location.device),
            rootInode: UInt64(location.inode),
            httpPort: httpPort,
            profileSHA256: digest,
            applied: true,
            checks: checks,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        // NOTE: these two evidence writes are still path-based. The separate
        // FixtureRootLocation child-identity integration (outside this task's
        // scopes) must replace them with an anchored control-directory write.
        try write(Data(profile.utf8), to: location.controlDirectory.appendingPathComponent("sandbox-profile.sb"),
                  permissions: 0o600)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try write(try encoder.encode(report), to: location.controlDirectory.appendingPathComponent("sandbox-report.json"),
                  permissions: 0o600)

        let failures = checks.filter { !$0.passed }
        guard failures.isEmpty else {
            throw FixtureSandboxError.message(
                "The fixture sandbox self-check failed: "
                    + failures.map { "\($0.name) [\($0.detail)]" }.joined(separator: "; ")
            )
        }
        do {
            try location.verifyPinned()
        } catch {
            throw FixtureSandboxError.message("The fixture root changed during sandbox setup: \(error.localizedDescription)")
        }
        return FixtureRoot(
            location: location,
            controlDirectory: location.controlDirectory,
            controlSocket: canonicalSocket,
            readyFile: canonicalReady,
            discoveryFile: canonicalDiscovery,
            serviceHome: location.serviceHome,
            workerHome: location.workerHome,
            tempDirectory: tempDirectory,
            httpPort: httpPort,
            profile: profile,
            profileSHA256: digest
        )
    }

    private static func validateControlPath(_ url: URL, location: FixtureRootLocation) throws {
        let name = url.lastPathComponent
        guard FixtureRootLocation.isSafeBasename(name) else {
            throw FixtureSandboxError.message("Control file name is unsafe: \(name)")
        }
        let parent = try FixtureRootLocation.canonicalDirectory(
            url.deletingLastPathComponent(), label: "control directory"
        )
        guard parent == location.controlDirectory.path else {
            throw FixtureSandboxError.message("Control files must live directly in \(location.controlDirectory.path).")
        }
        // Path-based until the separate anchored control-directory integration
        // lands; the kernel profile remains the primary path authority here.
        var value = stat()
        let result = name.withCString { pointer in
            fstatat(AT_FDCWD, (location.controlDirectory.path + "/" + name), &value, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 {
            guard (value.st_mode & S_IFMT) != S_IFLNK else {
                throw FixtureSandboxError.message("Control path must not be a symbolic link: \(name)")
            }
            guard (value.st_mode & S_IFMT) == S_IFREG || (value.st_mode & S_IFMT) == S_IFSOCK else {
                throw FixtureSandboxError.message("Control path has an unexpected type: \(name)")
            }
        } else if errno != ENOENT {
            throw FixtureSandboxError.message("Control path can not be inspected: \(name)")
        }
    }

    private static func makeProfile(root: String, controlSocket: String, httpPort: UInt16,
                                    home: String, bridgeRoot: String, keychain: String,
                                    executable: String, infoPlist: String) -> String {
        func quote(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let rootLiteral = quote(root)
        let controlLiteral = quote(controlSocket)
        let homeLiteral = quote(home)
        let bridgeLiteral = quote(bridgeRoot)
        let keychainLiteral = quote(keychain)
        let executableLiteral = quote(executable)
        let infoLiteral = quote(infoPlist)
        let httpLiteral = quote("localhost:\(httpPort)")
        return """
        (version 1)
        (deny default)
        ; A fixture task needs its shell, its own control channel and one
        ; reserved loopback listener. It does not need to originate any
        ; network connection, including loopback, so descendants cannot reach
        ; unrelated local services or the helper's own RPC listener.
        (allow process-fork)
        (allow process-exec*)
        (allow signal (target self))
        (allow file-read* (literal "/") (literal "/private") (literal "/private/var")
                          (subpath "/System") (subpath "/usr") (subpath "/bin")
                          (subpath "/sbin") (subpath "/Library")
                          (subpath "/private/var/db/dyld") (subpath "/private/etc")
                          (subpath "/dev") (subpath \(rootLiteral))
                          (literal \(executableLiteral)) (literal \(infoLiteral)))
        (allow file-write* (subpath \(rootLiteral)) (literal "/dev/null") (literal "/dev/ptmx")
                            (regex #"^/dev/ttys[0-9]+$") (regex #"^/private/dev/ttys[0-9]+$"))
        (allow file-ioctl (literal "/dev/ptmx") (regex #"^/dev/ttys[0-9]+$")
                          (regex #"^/private/dev/ttys[0-9]+$"))
        (allow sysctl-read)
        (allow mach-lookup)
        (allow ipc-posix*)
        (allow user-preference-read)
        (allow network-bind (local ip \(httpLiteral))
                            (local unix-socket (path \(controlLiteral))))
        (allow network-inbound (local ip \(httpLiteral))
                               (local unix-socket (path \(controlLiteral))))
        (deny file-read* file-write* (literal \(homeLiteral)))
        (deny file-read* file-write* (subpath \(bridgeLiteral)))
        (deny file-read* file-write* (subpath \(keychainLiteral)))
        (deny file-read* file-write* (subpath "/Library/Keychains"))
        ; Broad mach-lookup remains a residual boundary. These user-facing
        ; services are explicitly denied because a PTY descendant must not read
        ; the clipboard, TCC state or other GUI-session data.
        (deny mach-lookup (global-name "com.apple.SecurityServer")
                          (global-name "com.apple.securityd")
                          (global-name "com.apple.securityd.systemkeychain")
                          (global-name "com.apple.securityd.system")
                          (global-name "com.apple.trustd")
                          (global-name "com.apple.trustd.agent")
                          (global-name "com.apple.pasteboard.1")
                          (global-name "com.apple.tccd")
                          (global-name "com.apple.tccd.system")
                          (global-name "com.apple.WindowServer")
                          (global-name "com.apple.windowserver.active")
                          (global-name "com.apple.accessibility.axserver")
                          (global-name "com.apple.distributed_notifications@Uv3")
                          (global-name "com.apple.system.notification_center"))
        (deny network-outbound)
        (deny network-outbound (remote ip "localhost:43871"))
        (deny network-bind (local ip "localhost:43871"))
        (deny network-inbound (local ip "localhost:43871"))
        (deny appleevent-send)
        """
    }

    private static func apply(profile: String) throws {
        var errorBuffer: UnsafeMutablePointer<CChar>?
        let result = profile.withCString { pointer in
            floe_sandbox_init(pointer, 0, &errorBuffer)
        }
        if result != 0 {
            let detail = errorBuffer.map { String(cString: $0) } ?? "unknown sandbox error"
            throw FixtureSandboxError.message("The fixture sandbox could not be applied: \(detail)")
        }
    }

    private static func verifyPinnedRoot(_ location: FixtureRootLocation,
                                         checks: inout [FixtureSandboxCheck]) throws {
        do {
            try location.verifyPinned()
            checks.append(FixtureSandboxCheck(name: "root_identity_pinned", passed: true,
                                              detail: "root dev/ino unchanged; layout type/owner/mode rechecked (child dev/ino pinning is a separate integration)"))
        } catch {
            checks.append(FixtureSandboxCheck(name: "root_identity_pinned", passed: false,
                                              detail: error.localizedDescription))
        }
    }

    private static func deniedDirectoryCheck(name: String, path: String, existedBefore: Bool) -> FixtureSandboxCheck {
        guard existedBefore else {
            return FixtureSandboxCheck(name: name, passed: false,
                                       detail: "path absent before sandbox; denial is unverified")
        }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor >= 0 {
            close(descriptor)
            return FixtureSandboxCheck(name: name, passed: false, detail: "directory open unexpectedly succeeded")
        }
        let error = errno
        let denied = error == EPERM || error == EACCES
        return FixtureSandboxCheck(name: name, passed: denied, detail: "errno \(error)")
    }

    private static func pathExists(_ path: String) -> Bool {
        var value = stat()
        return lstat(path, &value) == 0
    }

    private static func writeInsideRootCheck(_ location: FixtureRootLocation) -> FixtureSandboxCheck {
        let name = ".sandbox-write-\(getpid())-\(UUID().uuidString)"
        let url = location.tempDirectory.appendingPathComponent(name, isDirectory: false)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            return FixtureSandboxCheck(name: "fixture_root_writable", passed: false,
                                       detail: "open failed errno \(errno)")
        }
        let wrote = "ok".withCString { pointer in
            Darwin.write(descriptor, pointer, 2) == 2
        }
        close(descriptor)
        let removed = unlink(url.path) == 0
        return FixtureSandboxCheck(name: "fixture_root_writable", passed: wrote && removed,
                                   detail: "write=\(wrote) unlink=\(removed)")
    }

    private static func reserveLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw FixtureSandboxError.message("Could not create a loopback reservation socket: \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw FixtureSandboxError.message("Could not reserve a loopback port: \(String(cString: strerror(errno)))")
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw FixtureSandboxError.message("Could not read the reserved loopback port: \(String(cString: strerror(errno)))")
        }
        let port = UInt16(bigEndian: bound.sin_port)
        guard port > 0, port != 43_871 else {
            throw FixtureSandboxError.message("The reserved loopback port is not usable.")
        }
        return port
    }

    private static func write(_ data: Data, to url: URL, permissions: mode_t) throws {
        try data.write(to: url, options: [.atomic])
        guard chmod(url.path, permissions) == 0 else {
            throw FixtureSandboxError.message("Could not set permissions on \(url.lastPathComponent).")
        }
    }
}

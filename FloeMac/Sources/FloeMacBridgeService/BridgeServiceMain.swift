// Floe Mac M00 — embedded Bridge component entry point.
//
// SPDX-License-Identifier: MPL-2.0
//
// Production access to the standalone Bridge data is disabled until older
// standalone versions can be excluded for the whole storage lifetime.
//
// Fixture mode is available again only after the helper has validated a
// task-owned mkdtemp root, pinned its device/inode, applied a kernel sandbox
// that permits writes only below that root and verified the real home, real
// Bridge data and Keychain are denied. Failure at any step exits before the
// service reads an identity, pair store, task or workspace.
//
// The process entry is a @main struct, not top-level code. Top-level Swift 6
// code is MainActor-isolated; a DispatchSource handler that touched it trapped
// on the actor-isolation check. The watchdog and signal handlers below only
// capture Sendable locals and synchronize inside the runtime.

import Darwin
import Foundation
import FloeMacBridgeProtocol

struct FixturePair: Codable {
    var key: Data
    var name: String
    var acceptedAt: Date
    var verification: String?
    var nonce: String?
}

@main
struct FloeMacBridgeServiceMain {
    static func main() {
        let rawArguments = CommandLine.arguments
        var arguments: ServiceArguments
        do {
            arguments = try ServiceArguments.parse(rawArguments)
        } catch {
            FileHandle.standardError.write(Data(("FloeMacBridgeService: \(error.localizedDescription)\n").utf8))
            _exit(2)
        }

        switch arguments.mode {
        case .production:
            do {
                try arguments.validateProduction()
            } catch {
                FileHandle.standardError.write(Data(("FloeMacBridgeService: \(error.localizedDescription)\n").utf8))
                _exit(2)
            }
            if arguments.identityAndPermissionsCheck {
                let report = IdentityCheck.run()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                if let data = try? encoder.encode(report) {
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                }
                _exit(0)
            }
            // Released standalone versions do not cooperate with our flock and
            // can start after any process/port preflight. Fail before reading
            // or writing their data until a lifetime-wide exclusivity or
            // isolated migration protocol is available.
            FileHandle.standardError.write(Data(
                "FloeMacBridgeService: The existing Bridge data cannot be opened safely while older Bridge versions can access it. An isolated migration is required.\n".utf8
            ))
            _exit(2)

        case .test:
            startFixture(arguments: arguments)
        }
    }

    private static func startFixture(arguments: ServiceArguments) {
        var arguments = arguments
        var prepared: FixtureRoot?
        do {
            guard arguments.testFixture != nil else {
                throw ServiceArgumentError.message("Test mode requires --test-fixture.")
            }
            let fixture = try FixtureSandbox.prepare(arguments: arguments)
            prepared = fixture
            arguments.testFixture = fixture.location.rootURL
            arguments.controlSocket = fixture.controlSocket
            arguments.readyFile = fixture.readyFile
            arguments.discoveryFile = fixture.discoveryFile
            try arguments.validateFixture(fixture.location)

            let paths = try BridgePaths(home: fixture.serviceHome)
            // The fixture root was already opened with no-follow during
            // preparation. Recheck it immediately before the identity/pair
            // store is touched and again before the listener starts.
            try fixture.verifyPinned()
            let storeLock = try BridgeStoreLock(root: paths.root)
            let identity = try BridgeIdentity.resolveTestFixture(fixture.location.rootURL)
            if let encoded = arguments.probeClientKeyBase64 {
                guard let clientKey = Data(base64Encoded: encoded), clientKey.count == 32 else {
                    throw ServiceArgumentError.message("--probe-client-key must be base64-encoded 32 bytes.")
                }
                try installFixturePair(clientKey: clientKey, serviceHome: fixture.serviceHome)
            }
            try fixture.verifyPinned()

            let runtime = try BridgeServiceRuntime(
                arguments: arguments,
                identity: identity,
                paths: paths,
                storeLock: storeLock,
                fixture: fixture,
                httpPort: 0
            )
            runtime.installControlHandler()
            try runtime.start()
            dispatchMain()
        } catch {
            writeFailure(error.localizedDescription, arguments: arguments, prepared: prepared)
            _exit(2)
        }
    }

    private static func installFixturePair(clientKey: Data, serviceHome: URL) throws {
        let pairURL = serviceHome
            .appendingPathComponent("Library/Application Support/Floe Bridge/State/paired-clients.json", isDirectory: false)
        try FileManager.default.createDirectory(
            at: pairURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var pairs: [String: FixturePair] = [:]
        var value = stat()
        if lstat(pairURL.path, &value) == 0 {
            guard (value.st_mode & S_IFMT) != S_IFLNK,
                  (value.st_mode & S_IFMT) == S_IFREG,
                  value.st_uid == geteuid() else {
                throw ServiceArgumentError.message("The fixture pair store is not a regular file owned by this user.")
            }
            let readDescriptor = open(pairURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard readDescriptor >= 0 else {
                throw ServiceArgumentError.message("The fixture pair store could not be opened without following links.")
            }
            let handle = FileHandle(fileDescriptor: readDescriptor, closeOnDealloc: true)
            let data = try handle.readToEnd() ?? Data()
            pairs = try JSONDecoder().decode([String: FixturePair].self, from: data)
        } else if errno != ENOENT {
            throw ServiceArgumentError.message("The fixture pair store could not be inspected.")
        }
        let clientID = BridgeWire.digest(clientKey)
        pairs[clientID] = FixturePair(
            key: clientKey,
            name: "M00 isolated fixture client",
            acceptedAt: Date(),
            verification: nil,
            nonce: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(pairs)
        let descriptor = open(pairURL.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw ServiceArgumentError.message("The fixture pair store could not be opened for writing.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        _ = fchmod(descriptor, 0o600)
    }

    private static func writeFailure(_ message: String, arguments: ServiceArguments, prepared: FixtureRoot?) {
        FileHandle.standardError.write(Data(("FloeMacBridgeService: " + message + "\n").utf8))
        guard let prepared, let readyFile = arguments.readyFile else { return }
        do {
            try prepared.verifyPinned()
        } catch {
            FileHandle.standardError.write(Data(
                "FloeMacBridgeService: Not writing a failure report because the fixture root changed.\n".utf8
            ))
            return
        }
        let report = BridgeReadyReport(
            schema: "floe-mac-bridge-ready-v2",
            state: "failed",
            port: nil,
            pid: getpid(),
            parentPID: getppid(),
            storageRoot: "",
            workerHome: prepared.workerHome.path,
            controlSocket: arguments.controlSocket?.path ?? "",
            identitySource: "test-fixture-persistent",
            identityFingerprintSHA256: nil,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            bundlePath: Bundle.main.bundlePath,
            listenerScope: "127.0.0.1",
            orphaned: false,
            message: message,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: readyFile, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: readyFile.path)
        }
    }
}

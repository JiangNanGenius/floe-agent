// Floe Mac M00 — embedded service arguments and path separation.
//
// SPDX-License-Identifier: MPL-2.0
//
// Production and test are separate modes. Production may only use the real
// user home, the existing Keychain identity and the existing Floe Bridge
// data. Test may only use an explicit, isolated fixture and an in-memory or
// fixture-persisted synthetic identity. A command-line switch cannot turn a
// production invocation into a fixture run.

import Darwin
import Foundation

enum ServiceMode: String, Sendable {
    case production
    case test
}

struct ServiceArguments: Sendable {
    var mode: ServiceMode = .production
    var testFixture: URL?
    var controlSocket: URL?
    var readyFile: URL?
    var discoveryFile: URL?
    var parentPID: pid_t?
    var probeClientKeyBase64: String?
    var orphanIdleGrace: TimeInterval = 30
    var identityAndPermissionsCheck = false
    var createIdentityIfAbsent = false

    static let usage = """
    Usage:
      FloeMacBridgeService --mode production --control-socket <path> \\
        --ready-file <path> --discovery-file <path> [--parent-pid <pid>] \\
        [--create-identity-if-absent]
      FloeMacBridgeService --identity-and-permissions-check
      FloeMacBridgeService --mode test --test-fixture <path> \\
        --control-socket <path> --ready-file <path> --discovery-file <path> \\
        [--parent-pid <pid>] [--probe-client-key <base64>] \\
        [--orphan-idle-grace <seconds>]
    """

    static func parse(_ arguments: [String]) throws -> ServiceArguments {
        var result = ServiceArguments()
        var index = 1
        func value(after key: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw ServiceArgumentError.missingValue(key)
            }
            return arguments[index + 1]
        }
        while index < arguments.count {
            let key = arguments[index]
            switch key {
            case "--help", "-h":
                print(Self.usage)
                _exit(0)
            case "--mode":
                let raw = try value(after: key)
                guard let mode = ServiceMode(rawValue: raw) else {
                    throw ServiceArgumentError.message("--mode must be production or test.")
                }
                result.mode = mode
                index += 2
            case "--test-fixture":
                result.testFixture = URL(fileURLWithPath: try value(after: key), isDirectory: true)
                index += 2
            case "--control-socket":
                result.controlSocket = URL(fileURLWithPath: try value(after: key), isDirectory: false)
                index += 2
            case "--ready-file":
                result.readyFile = URL(fileURLWithPath: try value(after: key), isDirectory: false)
                index += 2
            case "--discovery-file":
                result.discoveryFile = URL(fileURLWithPath: try value(after: key), isDirectory: false)
                index += 2
            case "--parent-pid":
                let raw = try value(after: key)
                guard let pid = pid_t(raw), pid > 1 else {
                    throw ServiceArgumentError.message("--parent-pid must be a live process identifier.")
                }
                result.parentPID = pid
                index += 2
            case "--probe-client-key":
                result.probeClientKeyBase64 = try value(after: key)
                index += 2
            case "--orphan-idle-grace":
                let raw = try value(after: key)
                guard let seconds = TimeInterval(raw), seconds >= 0, seconds <= 300 else {
                    throw ServiceArgumentError.message("--orphan-idle-grace must be between 0 and 300 seconds.")
                }
                result.orphanIdleGrace = seconds
                index += 2
            case "--identity-and-permissions-check":
                result.identityAndPermissionsCheck = true
                index += 1
            case "--create-identity-if-absent":
                result.createIdentityIfAbsent = true
                index += 1
            case "--home":
                throw ServiceArgumentError.message(
                    "--home is no longer accepted. Production always uses the real user home; tests use --test-fixture."
                )
            default:
                throw ServiceArgumentError.message("Unknown argument: \(key)")
            }
        }
        return result
    }

    /// Production is validated before any real Bridge data is opened. The
    /// helper intentionally still fails closed after this check because the
    /// released standalone Bridge does not participate in the new store lock.
    func validateProduction() throws {
        if identityAndPermissionsCheck {
            guard mode == .production else {
                throw ServiceArgumentError.message("Identity and permission checks are a production-read-only operation.")
            }
            guard testFixture == nil, probeClientKeyBase64 == nil, controlSocket == nil,
                  readyFile == nil, discoveryFile == nil, parentPID == nil,
                  !createIdentityIfAbsent else {
                throw ServiceArgumentError.message("--identity-and-permissions-check does not start a service.")
            }
            return
        }
        guard mode == .production else {
            throw ServiceArgumentError.message("Production validation was used for a test invocation.")
        }
        guard let controlSocket, let readyFile, let discoveryFile else {
            throw ServiceArgumentError.message("--control-socket, --ready-file and --discovery-file are required.")
        }
        guard testFixture == nil, probeClientKeyBase64 == nil, orphanIdleGrace == 30 else {
            throw ServiceArgumentError.message("Production does not accept fixture, probe-client or orphan-grace settings.")
        }
        let realHome = ServicePaths.realUserHome
        let controlRoot = realHome
            .appendingPathComponent("Library/Application Support/Floe Mac/BridgeControl", isDirectory: true)
        try ServicePaths.requireParent(controlSocket, is: controlRoot)
        try ServicePaths.requireParent(readyFile, is: controlRoot)
        try ServicePaths.requireParent(discoveryFile, is: controlRoot)
        try ServicePaths.requireNoSymlink(controlRoot)
    }

    /// Fixture paths, root identity and kernel confinement are handled by
    /// FixtureSandbox. This validation only rejects flags that would turn a
    /// test session into a production or implicit-identity session.
    func validateFixture(_ location: FixtureRootLocation) throws {
        guard mode == .test, let testFixture else {
            throw ServiceArgumentError.message("Test mode requires --test-fixture.")
        }
        guard testFixture.standardizedFileURL.path == location.rootURL.path else {
            throw ServiceArgumentError.message("The fixture root changed before validation.")
        }
        guard !createIdentityIfAbsent else {
            throw ServiceArgumentError.message("Test mode does not create a production Keychain identity.")
        }
        guard !identityAndPermissionsCheck else {
            throw ServiceArgumentError.message("Identity and permission checks do not start a fixture service.")
        }
        guard let controlSocket, let readyFile, let discoveryFile else {
            throw ServiceArgumentError.message("--control-socket, --ready-file and --discovery-file are required.")
        }
        for url in [controlSocket, readyFile, discoveryFile] {
            guard FixtureRootLocation.isSafeBasename(url.lastPathComponent) else {
                throw ServiceArgumentError.message("A control file name is unsafe: \(url.lastPathComponent)")
            }
        }
        let environment = ProcessInfo.processInfo.environment
        for key in ["HOME", "CFFIXED_USER_HOME"] {
            guard let raw = environment[key] else {
                throw ServiceArgumentError.message("Test mode requires \(key) to point at the fixture worker-home.")
            }
            let normalized = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.path
            guard normalized == location.workerHome.path else {
                throw ServiceArgumentError.message(
                    "Test mode requires \(key) to point at the fixture worker-home, not the service storage."
                )
            }
        }
        if let encoded = probeClientKeyBase64 {
            guard let key = Data(base64Encoded: encoded), key.count == 32 else {
                throw ServiceArgumentError.message("--probe-client-key must be base64-encoded 32 bytes.")
            }
        }
        guard orphanIdleGrace >= 0, orphanIdleGrace <= 300 else {
            throw ServiceArgumentError.message("--orphan-idle-grace must be between 0 and 300 seconds.")
        }
    }
}

enum ServiceArgumentError: Error, LocalizedError, Sendable {
    case message(String)
    case missingValue(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        case .missingValue(let key): "\(key) requires a value."
        }
    }
}

enum ServicePaths {
    static var realUserHome: URL {
        if let password = getpwuid(getuid()) {
            let path = String(cString: password.pointee.pw_dir)
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    static var userBridgeRoot: URL {
        realUserHome.appendingPathComponent("Library/Application Support/Floe Bridge", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    static var productionControlRoot: URL {
        realUserHome.appendingPathComponent("Library/Application Support/Floe Mac/BridgeControl", isDirectory: true)
    }

    static func canonicalExistingDirectory(_ url: URL, label: String) throws -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ServiceArgumentError.message("The \(label) does not exist: \(resolved.path)")
        }
        // Resolve system aliases such as /var -> /private/var and return the
        // canonical path. The fixture's own children are checked separately
        // so a symlinked storage directory is never written through.
        return resolved
    }

    static func requireParent(_ child: URL, is parent: URL) throws {
        let normalizedChild = child.standardizedFileURL
        let normalizedParent = parent.standardizedFileURL
        guard normalizedChild.deletingLastPathComponent().path == normalizedParent.path else {
            throw ServiceArgumentError.message("Control files must live directly in \(normalizedParent.path).")
        }
        guard !normalizedChild.lastPathComponent.isEmpty else {
            throw ServiceArgumentError.message("A control file path is empty.")
        }
    }

    static func requireNoSymlink(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ServiceArgumentError.message("Expected a directory at \(directory.path).")
            }
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ServiceArgumentError.message("Control storage must not be a symbolic link: \(directory.path)")
            }
        }
    }

    static func requireIsolatedFixture(_ fixture: URL) throws {
        let canonical = fixture.standardizedFileURL
        let userBridge = userBridgeRoot.standardizedFileURL
        guard canonical.path != "/", canonical.path != realUserHome.path,
              canonical.path != userBridge.path,
              !canonical.path.hasPrefix(userBridge.path + "/"),
              !userBridge.path.hasPrefix(canonical.path + "/") else {
            throw ServiceArgumentError.message("The test fixture must be isolated from the real Floe Bridge data.")
        }
        for component in ["service-home", "worker-home", "Control"] {
            let url = canonical.appendingPathComponent(component, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else {
                    throw ServiceArgumentError.message("Fixture component must not be a symlink: \(url.path)")
                }
            }
        }
    }
}

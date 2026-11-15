// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeExecution
import FloeGameCore
import FloeGameRGSS
import FloeGameRGSSHostCore

/// Existing resolved Linux environment services consumed by the RGSS host.
/// The App fills these from its registry/coordinator; no environment type is
/// introduced here.
public struct RGSSGuestLinuxEnvironmentPort: Sendable {
    public var descriptor: @Sendable (String) async -> LinuxGuestEnvironmentDescriptor?
    public var pathMap: @Sendable (String) async -> LinuxGuestPathMap?
    public var activate: @Sendable (String) async throws -> Void
    public var isOwned: @Sendable (String) async -> Bool

    public init(
        descriptor: @escaping @Sendable (String) async -> LinuxGuestEnvironmentDescriptor?,
        pathMap: @escaping @Sendable (String) async -> LinuxGuestPathMap?,
        activate: @escaping @Sendable (String) async throws -> Void,
        isOwned: @escaping @Sendable (String) async -> Bool
    ) {
        self.descriptor = descriptor
        self.pathMap = pathMap
        self.activate = activate
        self.isOwned = isOwned
    }

    public init(registry: LinuxGuestRegistry) {
        self.init(
            descriptor: { await registry.guestDescriptor(environmentID: $0) },
            pathMap: { await registry.linuxGuestPathMap(environmentID: $0) },
            activate: { environmentID in
                if await registry.status(environmentID: environmentID).running { return }
                let started = try await registry.start(environmentID: environmentID, taskID: nil)
                guard started else {
                    throw RGSSGuestRunError.missingEnvironment
                }
            },
            isOwned: { environmentID in
                await registry.owns(environmentID: environmentID)
            })
    }
}

/// Linux `LinuxGuestPathMap` adapted to the developer overlay's host-file
/// contract. It only exposes paths under declared 9p shares.
public struct RGSSLinuxGuestPathFileMapping: RGSSGuestHostPathMapping, Sendable {
    public let pathMap: LinuxGuestPathMap

    public init(pathMap: LinuxGuestPathMap) {
        self.pathMap = pathMap
    }

    public func hostURL(forGuestPath path: String) throws -> URL {
        guard let url = pathMap.hostPath(forGuestPath: path) else {
            throw RGSSGuestRunError.invalidRequest(
                "guest path is outside the environment's 9p shares")
        }
        return url
    }
}

/// Builds one immutable target for one staged run. Every launch revalidates
/// the environment, owner, root, revision and engine captured by the staged
/// request; a changed context fails instead of selecting another project.
public struct RGSSLinuxGuestTargetProvider: RGSSGuestTargetResolverProviding {
    public let environment: RGSSGuestLinuxEnvironmentPort
    public let environmentID: String
    public let ownerToken: UUID
    public let audioDriver: String?
    public let additionalEnvironment: [String: String]

    public init(
        environment: RGSSGuestLinuxEnvironmentPort,
        environmentID: String,
        ownerToken: UUID,
        audioDriver: String? = nil,
        additionalEnvironment: [String: String] = [:]
    ) {
        self.environment = environment
        self.environmentID = environmentID
        self.ownerToken = ownerToken
        self.audioDriver = audioDriver
        self.additionalEnvironment = additionalEnvironment
    }

    public func makeTarget(
        for staged: RGSSGuestStagedRun,
        display: RGSSGuestDisplayAttachment
    ) async throws -> RGSSGuestTargetBinding {
        guard staged.request.environmentID == environmentID,
              display.environmentID == environmentID else {
            throw RGSSGuestRunError.missingEnvironment
        }
        try await environment.activate(environmentID)
        guard await environment.isOwned(environmentID) else {
            throw RGSSGuestRunError.missingEnvironment
        }
        guard let descriptor = await environment.descriptor(environmentID),
              let pathMap = await environment.pathMap(environmentID) else {
            throw RGSSGuestRunError.invalidRequest(
                "the resolved Linux environment has no guest descriptor or 9p path map")
        }
        guard descriptor.id == environmentID else {
            throw RGSSGuestRunError.invalidRequest("guest descriptor identity changed")
        }
        guard let guestProject = pathMap.guestPath(forHostPath: staged.selectedRoot.path),
              let guestRun = pathMap.guestPath(forHostPath: staged.runRoot.path),
              let guestHome = pathMap.guestPath(forHostPath: staged.homeRoot.path),
              let guestLog = pathMap.guestPath(forHostPath: staged.logFile.path) else {
            throw RGSSGuestRunError.invalidRequest(
                "run/save/source path is outside the environment's declared shares")
        }
        let binaryName = try RGSSGuestEngineInstall.binaryName(for: staged.request.engine)
        let engineRoot = RGSSGuestEngineInstall.guestRoot
        let engineBinary = engineRoot + "/bin/" + binaryName
        var libraryPath: String?
        if let hostEngineRoot = try? pathMap.hostPath(forGuestPath: engineRoot) {
            let hostLibrary = hostEngineRoot.appendingPathComponent("lib", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: hostLibrary.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                libraryPath = engineRoot + "/lib"
            }
        }
        var variables: [String: String] = [
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
        ]
        if let audioDriver, !audioDriver.isEmpty {
            variables["SDL_AUDIODRIVER"] = audioDriver
        }
        for (key, value) in additionalEnvironment {
            variables[key] = value
        }
        let target = try RGSSGuestExecutionTarget(
            environmentID: environmentID,
            ownerToken: ownerToken,
            guestProjectDirectory: guestProject,
            guestRunDirectory: guestRun,
            guestHomeDirectory: guestHome,
            guestEngineBinary: engineBinary,
            guestLibraryPath: libraryPath,
            guestDisplay: display.guestDisplay,
            hostLogFile: staged.logFile,
            environment: variables)
        let resolver = RGSSLinuxGuestTargetResolver(
            staged: staged,
            target: target,
            pathMap: pathMap,
            guestLogPath: guestLog,
            environmentID: environmentID,
            ownerToken: ownerToken)
        return try RGSSGuestTargetBinding(
            resolver: resolver,
            guestRunDirectory: guestRun,
            guestHomeDirectory: guestHome,
            guestEngineBinary: engineBinary,
            fileMapping: RGSSLinuxGuestPathFileMapping(pathMap: pathMap))
    }
}

/// Concrete `RGSSGuestTargetResolver`. It returns the exact target captured
/// for the staged run and rejects any request whose environment, owner, root,
/// revision or engine no longer matches.
public struct RGSSLinuxGuestTargetResolver: RGSSGuestTargetResolver {
    public let staged: RGSSGuestStagedRun
    public let target: RGSSGuestExecutionTarget
    public let pathMap: LinuxGuestPathMap
    public let guestLogPath: String
    public let environmentID: String
    public let ownerToken: UUID

    public func resolve(_ request: RGSSGuestLaunchRequest) async throws -> RGSSGuestExecutionTarget {
        guard request.environmentID == environmentID,
              request.engine == staged.request.engine,
              request.projectRoot == staged.selectedRoot,
              request.revision == staged.request.context.savedRevision,
              request.sourceDigest == staged.sourceDigest else {
            throw RGSSGuestHostError.targetEnvironmentMismatch
        }
        guard target.ownerToken == ownerToken else {
            throw RGSSGuestHostError.jobOwnerMismatch
        }
        return target
    }
}

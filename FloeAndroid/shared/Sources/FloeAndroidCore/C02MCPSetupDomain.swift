// SPDX-License-Identifier: MPL-2.0
//
// C02 — guided MCP server setup, Linux-owned service preparation and the
// bounded stdio transport probe.
//
// This file is the ANDROID source half of the approved C02 MCP outcome. It
// deliberately does NOT create a second MCP client, a second installer, a
// second environment registry, a second job service or a host interpreter:
//
//   * remote Streamable HTTP configuration/edit/save/auth/validate/connect/
//     discovery/cancel/reconnect/failure stays on the ORIGINAL
//     `MCPRemoteClient` + `MCPDomain` + existing settings surface. The guided
//     remote path only preflights the same fields with the same rules and
//     hands the candidate back to that authority (no form-only success).
//   * the Linux-owned service path uses the ORIGINAL resolved environment
//     (session -> project -> shared -> base) and the ORIGINAL `exec.shell`
//     durable job service for every bounded dependency/build phase. It never
//     runs a host interpreter, never uses a language-specific installer
//     alias and never chooses "the first project" or a temp directory.
//   * the long-lived service itself is an explicit caller-supplied C01
//     capability (`C02MCPSetupServiceHosting`). Android has no long-lived
//     service target in this round; absent that real lane the domain reports
//     `serviceLaneUnavailable` and never fakes a running service.
//   * the stdio client is a bounded newline-delimited JSON-RPC client over a
//     caller-supplied byte channel. It requires a REAL separated pipe
//     (stdin/stdout/stderr); a PTY that echoes the input back is refused.
//     The C02 adapter in `C02MCPSetupIntegration` implements the ORIGINAL
//     `MCPClientTransporting` surface, so the original MCP factory, domain,
//     discovery, tools/call and cancel lifecycle consume it directly once
//     C01 supplies the pipe.
//
// Trust rules: server-provided schemas/tool descriptions are untrusted data;
// they never grant permissions. No credential bytes are accepted by this
// domain. A Linux service is loopback-only and auth-free. Persisted records
// contain no secret and no absolute path; only digests/labels/relative
// workspace paths.
import Foundation
import Crypto
import FloeCore
import FloeTools
import FloeSecurity
import FloeSkills
import FloeWorkspace
import FloeAndroidWorkspaceTools
import FloeEnvironments
import FloeAndroidShellTools
import FloeAndroidJobTools
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Limits and platform identity

public enum C02MCPSetupLimits {
    public static let maximumRecords = 32
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 196_608
    public static let maximumDisplayNameBytes = 256
    public static let maximumEndpointBytes = 2_048
    public static let maximumDetailsBytes = 8_192
    public static let maximumTemplateBytes = 131_072
    public static let maximumToolRows = 512
    public static let maximumToolSchemaBytes = 32_768
    public static let maximumToolMetadataBytes = 1_048_576
    public static let maximumStdioLineBytes = 2 * 1_024 * 1_024
    public static let maximumStderrBytes = 65_536
    public static let portRange = 1_024...65_535
    public static let minimumNodeVersion = (20, 19, 0)
    public static let maximumWorkspaceRelativePathBytes = 512
    public static let serviceDirectoryName = "MCPServices"
    public static let markerName = ".floe-mcp-setup.json"
    public static let launcherName = "floe-start.mjs"

    /// The Android CLIENT compatibility identity. This is deliberately
    /// independent from the native display/OTA prerelease version
    /// (0.1.0-alpha.NN / code N); a prerelease build number never makes a
    /// signed package/feed entry eligible or ineligible.
    public static let clientCompatibilityVersion = C02AndroidSkillCompatibility.version
    public static let clientPlatform = "android"
}

// MARK: - Typed failures

public struct C02MCPSetupFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Codable, Sendable {
        case invalidRequest
        case invalidDraft
        case staleRecord
        case recordMissing
        case recordsFull
        case liveEpochChanged
        case projectMissing
        case projectChanged
        case projectRootUnsafe
        case environmentMissing
        case environmentNotProject
        case environmentNotLinux
        case environmentUnavailable
        case templateMissing
        case templateTooLarge
        case templateDigestMismatch
        case templateChanged
        case templateDestinationUnsafe
        case templateDestinationExists
        case dependencyProbeMissing
        case platformMismatch
        case nodeVersionUnsupported
        case buildStepFailed
        case buildIncomplete
        case jobCompletedWithoutExitEvidence
        case jobOwnershipMismatch
        case serviceLaneUnavailable
        case serviceStartFailed
        case serviceStopFailed
        case serviceEndpointMismatch
        case serviceNotRunning
        case verificationFailed
        case smokeTestFailed
        case connectionSaveFailed
        case alreadyAdded
        case generationUnavailable
        case generationFailed
        case stdioUnavailable
        case stdioProtocolMismatch
        case stdioResponseInvalid
        case stdioTimeout

        public var wireCode: String { rawValue }
    }

    public let code: Code
    public let message: String
    public let retryable: Bool
    public let operation: String?

    public init(_ code: Code, message: String, retryable: Bool = false,
                operation: String? = nil) {
        self.code = code
        self.message = String(SecretRedactor.redact(message).prefix(512))
        self.retryable = retryable
        self.operation = operation
    }

    public var description: String { "\(code.rawValue): \(message)" }
}

// MARK: - Guided draft and preflight

public enum C02MCPSetupMode: String, Codable, Sendable, CaseIterable {
    /// Connect/edit an existing remote Streamable HTTP MCP server. The
    /// original client negotiates the current stateless revision and the
    /// previous session-based revision over bounded SSE responses.
    case remoteHTTP
    /// Create a Linux-owned Node Streamable HTTP service from the verified
    /// App-owned template inside an explicit project environment.
    case linuxService
}

public enum C02MCPSetupAuthentication: String, Codable, Sendable, CaseIterable {
    case none
    case bearerToken
    case customHeader

    var configuration: MCPServerConfiguration.Authentication {
        switch self {
        case .none: return .none
        case .bearerToken: return .bearerToken
        case .customHeader: return .customHeader
        }
    }
}

public struct C02MCPSetupDraft: Codable, Sendable, Equatable {
    public var mode: C02MCPSetupMode
    public var displayName: String
    public var endpointText: String
    public var authentication: C02MCPSetupAuthentication
    public var credentialHeaderName: String
    public var allowInsecureHTTP: Bool
    public var allowInCanvas: Bool
    public var timeoutSeconds: Double
    public var projectID: UUID?
    public var environmentID: String?
    public var portText: String
    /// INTERNAL COMPATIBILITY FIELD. The guided wizard does not expose a
    /// custom-tool description in this batch: model-authored generation is
    /// not an approved independent C02 scope and would otherwise ship a
    /// permanently disabled input. Empty means the verified starter template
    /// is built unchanged. A non-empty value from an internal caller still
    /// needs a real `C02MCPSetupGenerationRunning`; absent it the create is
    /// refused, never silently ignored.
    public var details: String

    public init(
        mode: C02MCPSetupMode = .remoteHTTP,
        displayName: String = "",
        endpointText: String = "",
        authentication: C02MCPSetupAuthentication = .none,
        credentialHeaderName: String = "Authorization",
        allowInsecureHTTP: Bool = false,
        allowInCanvas: Bool = false,
        timeoutSeconds: Double = 30,
        projectID: UUID? = nil,
        environmentID: String? = nil,
        portText: String = "8080",
        details: String = ""
    ) {
        self.mode = mode
        self.displayName = displayName
        self.endpointText = endpointText
        self.authentication = authentication
        self.credentialHeaderName = credentialHeaderName
        self.allowInsecureHTTP = allowInsecureHTTP
        self.allowInCanvas = allowInCanvas
        self.timeoutSeconds = min(max(timeoutSeconds, 5), 120)
        self.projectID = projectID
        self.environmentID = environmentID
        self.portText = portText
        self.details = details
    }
}

public enum C02MCPSetupFinding: String, Codable, Sendable {
    case nameRequired
    case endpointRequired
    case endpointInvalid
    case credentialInURL
    case insecureHTTPDisabled
    case headerNameInvalid
    case projectRequired
    case environmentRequired
    case portInvalid
    case detailsTooLong
    case serviceAuthenticationUnsupported
}

public struct C02MCPSetupPreflight: Sendable, Equatable {
    public var mode: C02MCPSetupMode
    public var displayName: String
    public var endpoint: URL?
    public var authentication: C02MCPSetupAuthentication
    public var credentialHeaderName: String
    public var allowInsecureHTTP: Bool
    public var allowInCanvas: Bool
    public var timeoutSeconds: Double
    public var projectID: UUID?
    public var environmentID: String?
    public var port: Int?
    public var details: String
    public var findings: [C02MCPSetupFinding]

    public var isValid: Bool { findings.isEmpty }
}

public enum C02MCPSetupPreflightLogic {
    public static func evaluate(_ draft: C02MCPSetupDraft) -> C02MCPSetupPreflight {
        var findings: [C02MCPSetupFinding] = []
        let name = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.utf8.count > C02MCPSetupLimits.maximumDisplayNameBytes {
            findings.append(.nameRequired)
        }
        let header = draft.credentialHeaderName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch draft.mode {
        case .remoteHTTP:
            let trimmed = draft.endpointText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                findings.append(.endpointRequired)
            }
            let endpoint = URL(string: trimmed)
            if let endpoint {
                if endpoint.scheme?.lowercased() != "https" &&
                    endpoint.scheme?.lowercased() != "http" {
                    findings.append(.endpointInvalid)
                }
                if endpoint.host == nil || trimmed.contains("\n") || trimmed.contains("\r") {
                    findings.append(.endpointInvalid)
                }
                if endpoint.user != nil || endpoint.password != nil {
                    findings.append(.credentialInURL)
                }
                if endpoint.scheme?.lowercased() == "http" && !draft.allowInsecureHTTP {
                    findings.append(.insecureHTTPDisabled)
                }
            } else {
                findings.append(.endpointInvalid)
            }
            if draft.authentication == .customHeader &&
                !isValidHeaderName(header) {
                findings.append(.headerNameInvalid)
            }
            return C02MCPSetupPreflight(
                mode: draft.mode,
                displayName: name,
                endpoint: URL(string: trimmed),
                authentication: draft.authentication,
                credentialHeaderName: header,
                allowInsecureHTTP: draft.allowInsecureHTTP,
                allowInCanvas: draft.allowInCanvas,
                timeoutSeconds: min(max(draft.timeoutSeconds, 5), 120),
                projectID: nil,
                environmentID: nil,
                port: nil,
                details: "",
                findings: findings)
        case .linuxService:
            if draft.projectID == nil { findings.append(.projectRequired) }
            if draft.environmentID?.isEmpty != false { findings.append(.environmentRequired) }
            let port = Int(draft.portText.trimmingCharacters(in: .whitespacesAndNewlines))
            if port == nil || !C02MCPSetupLimits.portRange.contains(port ?? -1) {
                findings.append(.portInvalid)
            }
            if draft.authentication != .none || draft.allowInsecureHTTP == false {
                findings.append(.serviceAuthenticationUnsupported)
            }
            if draft.details.utf8.count > C02MCPSetupLimits.maximumDetailsBytes {
                findings.append(.detailsTooLong)
            }
            return C02MCPSetupPreflight(
                mode: draft.mode,
                displayName: name,
                endpoint: nil,
                authentication: .none,
                credentialHeaderName: "",
                allowInsecureHTTP: true,
                allowInCanvas: draft.allowInCanvas,
                timeoutSeconds: min(max(draft.timeoutSeconds, 5), 120),
                projectID: draft.projectID,
                environmentID: draft.environmentID,
                port: port,
                details: draft.details,
                findings: findings)
        }
    }

    /// Same RFC token set/reserved names as the ORIGINAL
    /// `MCPServerConfiguration.validate()`; the domain re-validates through
    /// that original method before any save, so this is UI preflight only.
    public static func isValidHeaderName(_ name: String) -> Bool {
        let tokenCharacters = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        )
        let lowercased = name.lowercased()
        let reserved: Set<String> = [
            "accept", "connection", "content-length", "content-type", "host",
            "mcp-method", "mcp-name", "mcp-protocol-version", "mcp-session-id",
            "transfer-encoding",
        ]
        return !name.isEmpty
            && name.unicodeScalars.allSatisfy { tokenCharacters.contains($0) }
            && !reserved.contains(lowercased)
            && !lowercased.hasPrefix("mcp-param-")
    }

    /// Final remote gate through the ORIGINAL configuration validation. It
    /// is called again at the real save/drawer boundary; returning a
    /// `MCPServerConfiguration` here never itself authorizes a save.
    public static func remoteConfiguration(
        from draft: C02MCPSetupDraft
    ) throws -> MCPServerConfiguration {
        let preflight = evaluate(draft)
        guard preflight.isValid, let endpoint = preflight.endpoint else {
            throw C02MCPSetupFailure(.invalidDraft,
                                     message: "MCP server fields are incomplete.",
                                     retryable: false)
        }
        let configuration = MCPServerConfiguration(
            displayName: preflight.displayName,
            endpoint: endpoint,
            enabled: true,
            allowInCanvas: preflight.allowInCanvas,
            allowInsecureHTTP: preflight.allowInsecureHTTP,
            authentication: preflight.authentication.configuration,
            credentialHeaderName: preflight.credentialHeaderName,
            timeoutSeconds: preflight.timeoutSeconds)
        do {
            try configuration.validate()
        } catch {
            throw C02MCPSetupFailure(.invalidDraft,
                                     message: "MCP server settings are not valid.",
                                     retryable: false)
        }
        return configuration
    }
}

// MARK: - Project / environment value layer

public struct C02MCPSetupProject: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let rootURL: URL
    public let revision: String

    public init(id: UUID, name: String, rootURL: URL, revision: String) {
        self.id = id
        self.name = name
        self.rootURL = rootURL
        self.revision = revision
    }
}

public struct C02MCPSetupEnvironmentOption: Sendable, Equatable {
    public let id: String
    public let label: String
    public let backend: String
    public let containerID: String
    public let baseRevision: String
    public let layerFormat: Int

    public init(id: String, label: String, backend: String,
                containerID: String, baseRevision: String, layerFormat: Int) {
        self.id = id
        self.label = label
        self.backend = backend
        self.containerID = containerID
        self.baseRevision = baseRevision
        self.layerFormat = layerFormat
    }
}

/// Facts read from the ORIGINAL `EnvironmentRegistry` record. The domain
/// never creates or mutates an environment; it validates the explicit
/// selection against the resolved project owner.
public struct C02MCPSetupEnvironmentFacts: Sendable, Equatable {
    public let id: String
    public let label: String
    public let kind: String
    public let ownerID: String?
    public let state: String
    public let requiresRebuild: Bool
    public let backend: String
    public let containerID: String
    public let baseRevision: String
    public let layerFormat: Int

    public init(id: String, label: String, kind: String, ownerID: String?, state: String,
                requiresRebuild: Bool, backend: String, containerID: String,
                baseRevision: String, layerFormat: Int) {
        self.id = id
        self.label = label
        self.kind = kind
        self.ownerID = ownerID
        self.state = state
        self.requiresRebuild = requiresRebuild
        self.backend = backend
        self.containerID = containerID
        self.baseRevision = baseRevision
        self.layerFormat = layerFormat
    }
}

public struct C02MCPSetupOptions: Sendable, Equatable {
    public var projects: [C02MCPSetupProject]
    public var environments: [C02MCPSetupEnvironmentOption]
    public var templateAvailable: Bool
    public var serviceLaneAvailable: Bool
    public var generationAvailable: Bool
    public var stdioLaneAvailable: Bool
    public var unavailableReason: String?

    public init(projects: [C02MCPSetupProject] = [],
                environments: [C02MCPSetupEnvironmentOption] = [],
                templateAvailable: Bool = false,
                serviceLaneAvailable: Bool = false,
                generationAvailable: Bool = false,
                stdioLaneAvailable: Bool = false,
                unavailableReason: String? = nil) {
        self.projects = projects
        self.environments = environments
        self.templateAvailable = templateAvailable
        self.serviceLaneAvailable = serviceLaneAvailable
        self.generationAvailable = generationAvailable
        self.stdioLaneAvailable = stdioLaneAvailable
        self.unavailableReason = unavailableReason
    }
}

public protocol C02MCPSetupProjectProviding: Sendable {
    func projects() async throws -> [C02MCPSetupProject]
    func project(id: UUID) async throws -> C02MCPSetupProject?
    func environments(project: C02MCPSetupProject) async throws -> [C02MCPSetupEnvironmentOption]
}

public protocol C02MCPSetupEnvironmentProviding: Sendable {
    func environment(id: String) async -> C02MCPSetupEnvironmentFacts?
    func environment(id: String, project: C02MCPSetupProject) async -> C02MCPSetupEnvironmentFacts?
}

public extension C02MCPSetupEnvironmentProviding {
    func environment(id: String, project: C02MCPSetupProject) async -> C02MCPSetupEnvironmentFacts? {
        await environment(id: id)
    }
}

// MARK: - Template identity (fixed App-owned source)

public struct C02MCPSetupTemplateIdentity: Sendable, Equatable {
    public static let templateID = "floe.mcp.node-http"
    public static let templateVersion = "1.0.3"
    public static let archiveSHA256 = "d484b1511e55777e57a06d6f6189e20d71dbeffdec808f56b3f54a66867e2651"
    public static let contractSHA256 = "425829d625212d4d843cfb3b11ccd0d126cd498c3f261dfb182d2bf1e33f229c"
    public static let maximumArchiveBytes = 85_857
    public static let maximumContractBytes = 8_192

    /// The reviewed immutable inputs. `node-http/src/tools.ts` is the one
    /// extension point and is intentionally NOT in this list; a generated
    /// edit may only touch that file.
    public static let immutableProjectDigests: [String: String] = [
        "README.md": "51d6f8897c43af834274e8e32b62cf470ebc73c21c1da082615cb51cf8b50eff",
        "contract.json": contractSHA256,
        "node-http/.gitignore": "b63ce42e2babc54a13558cf679f775191d18649bca9dc04072126ef50987e1a4",
        "node-http/package-lock.json": "e4565f56ecbff62f74e0a76046c022cc4738a5beb86f86a3d1815acc57077e75",
        "node-http/package.json": "fdd3fbde3ac608ba607df736bb272637b6b6701c00a1775570669089f698a975",
        "node-http/src/server.ts": "e1c67121be4db6f0fa759dda42b130ec09a307305167675ea75d69e7a52e1385",
        "node-http/tests/discovery.mjs": "3042e48d110db9d5b00781b3869266cd6b830710f1107ed24e3cf43bdd408d4b",
        "node-http/tests/http.test.mjs": "0b3bba55e7c523e47fbca2897334012d1eeee659782d038dddb7132b94875c22",
        "node-http/tsconfig.json": "aaa03b5ee9fbadcd0e73745e4ac6d01c2a3d153a1115bc9416eb8cda96f9b26c",
    ]

    /// The App-owned guest entry. It is byte-identical to the reviewed
    /// donor launcher. Importing `dist/server.js` does not run its CLI
    /// branch; the exported service is started explicitly. `0.0.0.0` is
    /// confined by the host allowlist to loopback names so a public
    /// listener cannot be created by this template.
    public static let launcher = """
    // Floe-owned guest entry. No public listener/host configuration is changed.
    process.env.HOST = '0.0.0.0';
    process.env.FLOE_MCP_ALLOWED_HOSTS = '127.0.0.1,localhost,[::1]';
    // Importing server.js does not run its direct-entry CLI branch: argv[1]
    // names this owned launcher. Start its exported service explicitly.
    try {
      const { startService, readConfiguration } = await import('./dist/server.js');
      const service = await startService(readConfiguration(process.env));
      console.log(JSON.stringify({ event: 'ready', transport: 'streamable-http', endpoint: service.endpoint }));
      const shutdown = () => {
        void service.stop().then(() => { process.exitCode = 0; }, () => { process.exitCode = 1; });
      };
      process.once('SIGINT', shutdown);
      process.once('SIGTERM', shutdown);
    } catch {
      console.error('The MCP service could not start. Check the assigned host, port and dependencies.');
      process.exitCode = 1;
    }
    """

    public static func verifyArchive(_ archive: Data) throws {
        guard archive.count == maximumArchiveBytes,
              SignedContentArchive.sha256Hex(archive) == archiveSHA256 else {
            throw C02MCPSetupFailure(.templateDigestMismatch,
                                     message: "The bundled MCP template did not match its reviewed digest.",
                                     retryable: false)
        }
    }

    public static func verifyContract(_ contract: Data) throws {
        guard contract.count <= maximumContractBytes,
              SignedContentArchive.sha256Hex(contract) == contractSHA256,
              let object = (try? JSONSerialization.jsonObject(with: contract)) as? [String: Any],
              object["schemaVersion"] as? Int == 1,
              object["templateID"] as? String == templateID,
              object["templateVersion"] as? String == templateVersion,
              object["storefrontSkill"] as? Bool == false,
              object["projectRoot"] as? String == "node-http",
              (object["runtime"] as? [String: Any])?["os"] as? String == "linux",
              (object["service"] as? [String: Any])?["transport"] as? String == "streamable-http",
              (object["service"] as? [String: Any])?["readyLogIsAcceptance"] as? Bool == false,
              (object["smokeTest"] as? [String: Any])?["tool"] as? String == "service_status",
              (object["smokeTest"] as? [String: Any])?["requiresRealNativeClient"] as? Bool == true else {
            throw C02MCPSetupFailure(.templateDigestMismatch,
                                     message: "The bundled MCP template contract is not the reviewed contract.",
                                     retryable: false)
        }
    }

    public static func verifyExtracted(root: URL, requireLauncher: Bool = true) throws {
        let guardPaths = WorkspacePathGuard(rootURL: root)
        for (path, expected) in immutableProjectDigests {
            let file = try guardPaths.resolve(path)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 262_144,
                  SignedContentArchive.sha256Hex(try Data(contentsOf: file)) == expected else {
                throw C02MCPSetupFailure(.templateChanged,
                                         message: "The MCP template files changed after extraction.",
                                         retryable: false)
            }
        }
        guard requireLauncher else { return }
        let launcherURL = try guardPaths.resolve("node-http/" + launcherName)
        guard (try? Data(contentsOf: launcherURL)) == Data(C02MCPSetupTemplateIdentity.launcher.utf8) else {
            throw C02MCPSetupFailure(.templateChanged,
                                     message: "The MCP template launcher changed after extraction.",
                                     retryable: false)
        }
    }
}

// MARK: - Record value layer

public struct C02MCPSetupStep: Codable, Sendable, Equatable {
    public enum Name: String, Codable, Sendable, CaseIterable {
        case probe
        case install
        case compile
        case test
    }
    public enum State: String, Codable, Sendable {
        case pending
        case running
        case completed
        case failed
        case cancelled
    }
    public var name: Name
    public var state: State
    public var jobID: UUID?
    public var callID: String
    public var exitCode: Int?
    public var outputDigest: String?
    public var outputBytes: Int?
    public var errorCode: String?

    public init(name: Name, state: State = .pending, jobID: UUID? = nil,
                callID: String, exitCode: Int? = nil,
                outputDigest: String? = nil, outputBytes: Int? = nil,
                errorCode: String? = nil) {
        self.name = name
        self.state = state
        self.jobID = jobID
        self.callID = callID
        self.exitCode = exitCode
        self.outputDigest = outputDigest
        self.outputBytes = outputBytes
        self.errorCode = errorCode
    }
}

public struct C02MCPSetupReceipt: Codable, Sendable, Equatable {
    public var recordID: UUID
    public var projectID: UUID
    public var environmentID: String
    public var containerID: String
    public var baseRevision: String
    public var rootIdentity: String
    public var endpoint: String
    public var smokeDigest: String
    public var verifiedTools: [String]
    public var verifiedAt: Date
    public var serverID: UUID?
    public var newRevision: String?

    public init(recordID: UUID, projectID: UUID, environmentID: String,
                containerID: String, baseRevision: String, rootIdentity: String,
                endpoint: String, smokeDigest: String, verifiedTools: [String],
                verifiedAt: Date, serverID: UUID? = nil, newRevision: String? = nil) {
        self.recordID = recordID
        self.projectID = projectID
        self.environmentID = environmentID
        self.containerID = containerID
        self.baseRevision = baseRevision
        self.rootIdentity = rootIdentity
        self.endpoint = endpoint
        self.smokeDigest = smokeDigest
        self.verifiedTools = Array(verifiedTools.prefix(512))
        self.verifiedAt = verifiedAt
        self.serverID = serverID
        self.newRevision = newRevision
    }
}

public struct C02MCPSetupRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        case preparing
        case prepared
        case generating
        case building
        case readyToStart
        case starting
        case verifying
        case ready
        case added
        case stopping
        case stopped
        case failed
        case interrupted

        public var isBusy: Bool {
            switch self {
            case .preparing, .prepared, .generating, .building, .starting,
                 .verifying, .stopping:
                return true
            case .readyToStart, .ready, .added, .stopped, .failed, .interrupted:
                return false
            }
        }
    }

    public var id: UUID
    public var revision: UInt64
    public var draft: C02MCPSetupDraft
    public var projectID: UUID
    public var projectName: String
    /// The exact C01 `workspaces.updated_at` revision observed when the setup
    /// record was created. Every mutating step re-reads the project through
    /// the ORIGINAL project library and refuses on a mismatch, so a rename or
    /// another project-library write cannot be silently absorbed into an
    /// active setup. Optional for records persisted before this field existed.
    public var projectRevision: String?
    public var environmentID: String
    public var environmentLabel: String
    public var containerID: String
    public var baseRevision: String
    public var rootIdentity: String
    public var workspaceRelativePath: String?
    public var steps: [C02MCPSetupStep]
    public var phase: Phase
    public var generationRunID: UUID?
    public var serviceID: UUID?
    public var serviceEndpoint: String?
    public var receipt: C02MCPSetupReceipt?
    public var errorCode: String?
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), revision: UInt64 = 0,
                draft: C02MCPSetupDraft, projectID: UUID, projectName: String,
                projectRevision: String? = nil,
                environmentID: String, environmentLabel: String,
                containerID: String, baseRevision: String, rootIdentity: String,
                workspaceRelativePath: String? = nil,
                steps: [C02MCPSetupStep] = [],
                phase: Phase = .preparing, generationRunID: UUID? = nil,
                serviceID: UUID? = nil, serviceEndpoint: String? = nil,
                receipt: C02MCPSetupReceipt? = nil,
                errorCode: String? = nil, errorMessage: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.revision = revision
        self.draft = draft
        self.projectID = projectID
        self.projectName = projectName
        self.projectRevision = projectRevision
        self.environmentID = environmentID
        self.environmentLabel = environmentLabel
        self.containerID = containerID
        self.baseRevision = baseRevision
        self.rootIdentity = rootIdentity
        self.workspaceRelativePath = workspaceRelativePath
        self.steps = steps
        self.phase = phase
        self.generationRunID = generationRunID
        self.serviceID = serviceID
        self.serviceEndpoint = serviceEndpoint
        self.receipt = receipt
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isTerminal: Bool {
        switch phase {
        case .added, .stopped, .failed, .interrupted: return true
        default: return false
        }
    }
}

public protocol C02MCPSetupRecordStoring: Sendable {
    func load() async throws -> [C02MCPSetupRecord]
    func save(_ record: C02MCPSetupRecord) async throws
    func remove(id: UUID) async throws
}

// MARK: - Fixed build plan

public struct C02MCPSetupBuildCommand: Sendable, Equatable {
    public let name: C02MCPSetupStep.Name
    public let callPrefix: String
    public let command: String
    public let timeoutSeconds: Double
    public let maximumOutputBytes: Int

    public func callID(_ recordID: UUID) -> String {
        callPrefix + recordID.uuidString
    }
}

public enum C02MCPSetupBuildPlan {
    /// The exact reviewed contract phases. The monolithic historical command
    /// is intentionally not submitted: the real guest cannot finish npm ci,
    /// tsc and the duplicated test build inside one unchanged job window.
    public static let commands: [C02MCPSetupBuildCommand] = [
        C02MCPSetupBuildCommand(
            name: .probe,
            callPrefix: "mcp.setup.probe.",
            command: """
            set -eu
            printf 'FLOE_OS=%s\\n' "$(uname -s)"
            printf 'FLOE_ARCH=%s\\n' "$(uname -m)"
            printf 'FLOE_NODE=%s\\n' "$(node --version)"
            printf 'FLOE_NPM=%s\\n' "$(npm --version)"
            """,
            timeoutSeconds: 600,
            maximumOutputBytes: 262_144),
        C02MCPSetupBuildCommand(
            name: .install,
            callPrefix: "mcp.setup.install.",
            command: """
            set -eu
            node -e 'const [a,b]=process.versions.node.split(".").map(Number); if(a<20||(a===20&&b<19)){throw new Error("Node 20.19 or newer is required")}'
            npm ci --ignore-scripts --no-audit --no-fund
            """,
            timeoutSeconds: 600,
            maximumOutputBytes: 262_144),
        C02MCPSetupBuildCommand(
            name: .compile,
            callPrefix: "mcp.setup.compile.",
            command: """
            set -eu
            node -e 'const [a,b]=process.versions.node.split(".").map(Number); if(a<20||(a===20&&b<19)){throw new Error("Node 20.19 or newer is required")}'
            npm run build
            """,
            timeoutSeconds: 600,
            maximumOutputBytes: 262_144),
        C02MCPSetupBuildCommand(
            name: .test,
            callPrefix: "mcp.setup.test.",
            command: """
            set -eu
            node -e 'const [a,b]=process.versions.node.split(".").map(Number); if(a<20||(a===20&&b<19)){throw new Error("Node 20.19 or newer is required")}'
            node --test tests/http.test.mjs
            """,
            timeoutSeconds: 600,
            maximumOutputBytes: 262_144),
    ]

    public static func command(named name: C02MCPSetupStep.Name) -> C02MCPSetupBuildCommand? {
        commands.first { $0.name == name }
    }

    public static func initialSteps(recordID: UUID) -> [C02MCPSetupStep] {
        commands.map { C02MCPSetupStep(name: $0.name, callID: $0.callID(recordID)) }
    }

    public static func expectedPayload(recordID: UUID,
                                       step: C02MCPSetupStep.Name,
                                       workspaceRelativePath: String) -> Data? {
        guard let command = command(named: step) else { return nil }
        return payload(command: command.command,
                       cwd: workspaceRelativePath + "/node-http",
                       timeoutSeconds: command.timeoutSeconds,
                       maximumOutputBytes: command.maximumOutputBytes)
    }

    public static func payload(command: String, cwd: String,
                               timeoutSeconds: Double,
                               maximumOutputBytes: Int) -> Data? {
        let object: [String: Any] = [
            "command": command,
            "cwd": cwd,
            "timeout": timeoutSeconds,
            "maxOutputBytes": maximumOutputBytes,
        ]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Identity of a persisted job row. The row must carry this record's
    /// run/environment/root/target and the exact fixed payload; a same-owner
    /// row with drifted bytes is never adopted or cancelled.
    public static func payloadMatches(_ data: Data,
                                      expected: Data) -> Bool {
        guard let actual = try? JSONDecoder().decode(LocalShellTool.Arguments.self, from: data),
              let expectedObject = try? JSONSerialization.jsonObject(with: expected) as? [String: Any],
              let expectedCommand = expectedObject["command"] as? String,
              let expectedCwd = expectedObject["cwd"] as? String,
              let expectedTimeout = (expectedObject["timeout"] as? NSNumber)?.doubleValue,
              let expectedCap = (expectedObject["maxOutputBytes"] as? NSNumber)?.intValue else {
            return false
        }
        guard actual.resolvedCommand == expectedCommand,
              actual.command == nil || actual.command == expectedCommand,
              actual.script == nil || actual.script == expectedCommand,
              actual.cwd == expectedCwd,
              actual.timeout == expectedTimeout,
              actual.maxOutputBytes == expectedCap,
              actual.env == nil, actual.stdin == nil, actual.packages == nil,
              actual.packagePurpose == nil, actual.packageCapabilities == nil else {
            return false
        }
        return true
    }

    public enum ResumeAction: Equatable, Sendable {
        case attach(Int)
        case submit(Int)
        case allCompleted
    }

    public static func resumeAction(_ steps: [C02MCPSetupStep]) -> ResumeAction {
        for (index, step) in steps.enumerated() {
            switch step.state {
            case .completed: continue
            case .pending, .running, .failed, .cancelled: return .attach(index)
            }
        }
        return .allCompleted
    }

    public static func nextAction(_ steps: [C02MCPSetupStep]) -> ResumeAction {
        for (index, step) in steps.enumerated() {
            switch step.state {
            case .completed: continue
            case .pending: return .submit(index)
            case .running, .failed, .cancelled: return .attach(index)
            }
        }
        return .allCompleted
    }

    /// Real guest platform/version evidence. Missing evidence is never a
    /// pass: Android ABI/version guesses are not substituted for the actual
    /// resolved Linux userland.
    public struct ProbeEvidence: Sendable, Equatable {
        public let os: String
        public let architecture: String
        public let nodeVersion: String
        public let npmVersion: String
    }

    public static func parseProbe(_ output: String) throws -> ProbeEvidence {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if ["FLOE_OS", "FLOE_ARCH", "FLOE_NODE", "FLOE_NPM"].contains(key) {
                values[key] = String(value.prefix(128))
            }
        }
        guard let os = values["FLOE_OS"], let arch = values["FLOE_ARCH"],
              let node = values["FLOE_NODE"], let npm = values["FLOE_NPM"] else {
            throw C02MCPSetupFailure(.dependencyProbeMissing,
                                     message: "The Linux environment did not report its operating system, architecture and Node runtime.",
                                     retryable: true)
        }
        guard os.lowercased() == "linux" else {
            throw C02MCPSetupFailure(.platformMismatch,
                                     message: "The selected environment is not Linux; the MCP service template requires a Linux guest.",
                                     retryable: false)
        }
        let version = node.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2,
              parts[0] > C02MCPSetupLimits.minimumNodeVersion.0 ||
                (parts[0] == C02MCPSetupLimits.minimumNodeVersion.0 &&
                 (parts[1] > C02MCPSetupLimits.minimumNodeVersion.1 ||
                  (parts[1] == C02MCPSetupLimits.minimumNodeVersion.1 &&
                   (parts.count < 3 || parts[2] >= C02MCPSetupLimits.minimumNodeVersion.2)))) else {
            throw C02MCPSetupFailure(.nodeVersionUnsupported,
                                     message: "The selected Linux environment has Node \(node); version 20.19.0 or newer is required.",
                                     retryable: false)
        }
        return ProbeEvidence(os: os, architecture: arch,
                             nodeVersion: node, npmVersion: npm)
    }
}

// MARK: - Workspace staging / commit (no follow, old bytes preserved)

public struct C02MCPSetupMarker: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var recordID: UUID
    public var archiveSHA256: String
    public var templateID: String
    public var templateVersion: String
    public var createdAt: Date

    public init(recordID: UUID, archiveSHA256: String = C02MCPSetupTemplateIdentity.archiveSHA256,
                createdAt: Date = Date()) {
        self.schemaVersion = 1
        self.recordID = recordID
        self.archiveSHA256 = archiveSHA256
        self.templateID = C02MCPSetupTemplateIdentity.templateID
        self.templateVersion = C02MCPSetupTemplateIdentity.templateVersion
        self.createdAt = createdAt
    }
}

public struct C02MCPSetupWorkspace: Sendable, Equatable {
    public let projectRootIdentity: String
    public let projectRelativePath: String
    public let stagingRelativePath: String
    public let nodeRelativePath: String
    public let reusedCommittedDirectory: Bool
}

public enum C02MCPSetupWorkspaceStager {
    public static func projectRootIdentity(_ root: URL) -> String {
        FloeDigest.sha256Hex(Data(root.standardizedFileURL.path.utf8))
    }

    public static func prepare(recordID: UUID,
                               projectRoot: URL,
                               archive: Data) throws -> C02MCPSetupWorkspace {
        try C02MCPSetupTemplateIdentity.verifyArchive(archive)
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let guardPaths = WorkspacePathGuard(rootURL: root)
        let servicesRelative = C02MCPSetupLimits.serviceDirectoryName
        let servicesURL = try guardPaths.resolve(servicesRelative)
        try ensureOwnedDirectory(servicesURL, mode: 0o700)
        let key = recordID.uuidString.lowercased()
        let stagingRelative = servicesRelative + "/.staging-" + key
        let finalRelative = servicesRelative + "/" + key
        let stagingURL = try guardPaths.resolve(stagingRelative)
        let finalURL = try guardPaths.resolve(finalRelative)

        if isPresent(finalURL) {
            guard try marker(at: finalURL)?.recordID == recordID else {
                throw C02MCPSetupFailure(.templateDestinationExists,
                                         message: "A different MCP service already occupies this record's project directory.",
                                         retryable: false)
            }
            try C02MCPSetupTemplateIdentity.verifyExtracted(root: finalURL)
            return C02MCPSetupWorkspace(
                projectRootIdentity: projectRootIdentity(root),
                projectRelativePath: finalRelative,
                stagingRelativePath: stagingRelative,
                nodeRelativePath: finalRelative + "/node-http",
                reusedCommittedDirectory: true)
        }

        if isPresent(stagingURL) {
            guard try marker(at: stagingURL)?.recordID == recordID else {
                throw C02MCPSetupFailure(.templateDestinationUnsafe,
                                         message: "An unowned staging directory exists for this MCP service.",
                                         retryable: false)
            }
            try? FileManager.default.removeItem(at: stagingURL)
        }
        do {
            _ = try SignedContentArchive.extract(
                archive,
                at: stagingURL,
                limits: .init(maximumEntries: 32,
                              maximumFileBytes: 262_144,
                              maximumTotalBytes: 1_048_576),
                allowedTopLevel: ["README.md", "contract.json", "node-http"])
            try C02MCPSetupTemplateIdentity.verifyExtracted(root: stagingURL, requireLauncher: false)
            let launcher = try WorkspacePathGuard(rootURL: stagingURL)
                .resolve("node-http/" + C02MCPSetupLimits.launcherName)
            try Data(C02MCPSetupTemplateIdentity.launcher.utf8)
                .write(to: launcher, options: .atomic)
            try setMode(0o600, at: launcher)
            let markerBytes = try JSONEncoder().encode(C02MCPSetupMarker(recordID: recordID))
            try markerBytes.write(to: stagingURL.appendingPathComponent(C02MCPSetupLimits.markerName),
                                  options: .atomic)
            try C02MCPSetupTemplateIdentity.verifyExtracted(root: stagingURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
        return C02MCPSetupWorkspace(
            projectRootIdentity: projectRootIdentity(root),
            projectRelativePath: finalRelative,
            stagingRelativePath: stagingRelative,
            nodeRelativePath: finalRelative + "/node-http",
            reusedCommittedDirectory: false)
    }

    /// Atomic same-volume rename. A destination that appeared after prepare
    /// is never overwritten; an existing directory is reused only when its
    /// marker proves this exact record/template.
    public static func commit(recordID: UUID, projectRoot: URL,
                              workspace: C02MCPSetupWorkspace) throws {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let guardPaths = WorkspacePathGuard(rootURL: root)
        let stagingURL = try guardPaths.resolve(workspace.stagingRelativePath)
        let finalURL = try guardPaths.resolve(workspace.projectRelativePath)
        guard isPresent(stagingURL), !isPresent(finalURL) else {
            if isPresent(finalURL), try marker(at: finalURL)?.recordID == recordID {
                try C02MCPSetupTemplateIdentity.verifyExtracted(root: finalURL)
                try? FileManager.default.removeItem(at: stagingURL)
                return
            }
            throw C02MCPSetupFailure(.templateDestinationExists,
                                     message: "The MCP service directory is no longer available for this record.",
                                     retryable: false)
        }
        try C02MCPSetupTemplateIdentity.verifyExtracted(root: stagingURL)
        try FileManager.default.moveItem(at: stagingURL, to: finalURL)
        try setMode(0o700, at: finalURL)
        try C02MCPSetupTemplateIdentity.verifyExtracted(root: finalURL)
    }

    public static func cleanup(recordID: UUID, projectRoot: URL,
                               workspace: C02MCPSetupWorkspace,
                               removeCommitted: Bool) {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let guardPaths = WorkspacePathGuard(rootURL: root)
        if let staging = try? guardPaths.resolve(workspace.stagingRelativePath),
           isPresent(staging),
           ((try? marker(at: staging)) ?? nil)?.recordID == recordID {
            try? FileManager.default.removeItem(at: staging)
        }
        guard removeCommitted else { return }
        if let final = try? guardPaths.resolve(workspace.projectRelativePath),
           isPresent(final),
           ((try? marker(at: final)) ?? nil)?.recordID == recordID {
            try? FileManager.default.removeItem(at: final)
        }
    }

    private static func marker(at directory: URL) throws -> C02MCPSetupMarker? {
        let url = directory.appendingPathComponent(C02MCPSetupLimits.markerName)
        guard isPresent(url) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 4_096 else { return nil }
        return try? JSONDecoder().decode(C02MCPSetupMarker.self, from: Data(contentsOf: url))
    }

    private static func ensureOwnedDirectory(_ url: URL, mode: Int) throws {
        let kind = WorkspaceNoFollow.kind(url.path)
        switch kind {
        case .directory:
            break
        case .missing:
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try setMode(mode, at: url)
        default:
            throw C02MCPSetupFailure(.templateDestinationUnsafe,
                                     message: "The project services directory is not a safe regular directory.",
                                     retryable: false)
        }
    }

    private static func isPresent(_ url: URL) -> Bool {
        WorkspaceNoFollow.kind(url.path) != .missing
    }

    private static func setMode(_ mode: Int, at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}

// MARK: - Template chunk staging (app-owned, bounded)

public actor C02MCPSetupTemplateStore {
    private let root: URL
    private let fileManager = FileManager.default

    public init(root: URL) {
        self.root = root
    }

    public nonisolated func archiveURL(recordID: UUID) -> URL {
        root.appendingPathComponent(recordID.uuidString.lowercased() + ".zip")
    }

    private nonisolated func partURL(recordID: UUID) -> URL {
        root.appendingPathComponent(recordID.uuidString.lowercased() + ".part")
    }

    public func append(recordID: UUID, chunk: Data, offset: Int,
                       final: Bool, archiveSHA256: String) throws -> Bool {
        guard chunk.count <= C02MCPSetupLimits.maximumRequestBytes,
              offset >= 0, offset <= C02MCPSetupLimits.maximumTemplateBytes,
              archiveSHA256 == C02MCPSetupTemplateIdentity.archiveSHA256 else {
            throw C02MCPSetupFailure(.invalidRequest,
                                     message: "The template chunk is not valid.",
                                     retryable: false)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let part = partURL(recordID: recordID)
        if offset == 0 {
            try? fileManager.removeItem(at: part)
        }
        var data = (try? Data(contentsOf: part)) ?? Data()
        guard data.count == offset else {
            throw C02MCPSetupFailure(.invalidRequest,
                                     message: "The template upload offset does not match the received bytes.",
                                     retryable: true)
        }
        data.append(chunk)
        guard data.count <= C02MCPSetupLimits.maximumTemplateBytes else {
            throw C02MCPSetupFailure(.templateTooLarge,
                                     message: "The MCP template is larger than the reviewed bound.",
                                     retryable: false)
        }
        try data.write(to: part, options: .atomic)
        guard final else { return false }
        try C02MCPSetupTemplateIdentity.verifyArchive(data)
        let archive = archiveURL(recordID: recordID)
        if fileManager.fileExists(atPath: archive.path) {
            try fileManager.removeItem(at: archive)
        }
        try fileManager.moveItem(at: part, to: archive)
        return true
    }

    public func archive(recordID: UUID) throws -> Data {
        let url = archiveURL(recordID: recordID)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              (values.fileSize ?? Int.max) <= C02MCPSetupLimits.maximumTemplateBytes else {
            throw C02MCPSetupFailure(.templateMissing,
                                     message: "The MCP template has not been staged for this record.",
                                     retryable: true)
        }
        let data = try Data(contentsOf: url)
        try C02MCPSetupTemplateIdentity.verifyArchive(data)
        return data
    }

    public func remove(recordID: UUID) {
        try? fileManager.removeItem(at: archiveURL(recordID: recordID))
        try? fileManager.removeItem(at: partURL(recordID: recordID))
    }
}

// MARK: - Effect seams (real implementations live in C02MCPSetupIntegration)

public struct C02MCPSetupBinding: Sendable, Equatable {
    public let recordID: UUID
    public let projectID: UUID
    public let projectName: String
    public let rootURL: URL
    public let rootIdentity: String
    public let environmentID: String
    public let environmentLabel: String
    public let containerID: String
    public let baseRevision: String
    public let workspaceRelativePath: String
    public let port: Int

    public init(recordID: UUID, projectID: UUID, projectName: String,
                rootURL: URL, rootIdentity: String, environmentID: String,
                environmentLabel: String, containerID: String,
                baseRevision: String, workspaceRelativePath: String, port: Int) {
        self.recordID = recordID
        self.projectID = projectID
        self.projectName = projectName
        self.rootURL = rootURL
        self.rootIdentity = rootIdentity
        self.environmentID = environmentID
        self.environmentLabel = environmentLabel
        self.containerID = containerID
        self.baseRevision = baseRevision
        self.workspaceRelativePath = workspaceRelativePath
        self.port = port
    }
}

public struct C02MCPSetupCommandHandle: Codable, Sendable, Equatable {
    public let recordID: UUID
    public let jobID: UUID
    public let callID: String
    public let runID: UUID
    public let conversationID: UUID
    public let environmentID: String
    public let rootIdentity: String
    public let workspaceRootPath: String
    public let payloadDigest: String

    public init(recordID: UUID, jobID: UUID, callID: String, runID: UUID,
                conversationID: UUID, environmentID: String,
                rootIdentity: String, workspaceRootPath: String,
                payloadDigest: String) {
        self.recordID = recordID
        self.jobID = jobID
        self.callID = callID
        self.runID = runID
        self.conversationID = conversationID
        self.environmentID = environmentID
        self.rootIdentity = rootIdentity
        self.workspaceRootPath = workspaceRootPath
        self.payloadDigest = payloadDigest
    }
}

public struct C02MCPSetupCommandResult: Sendable, Equatable {
    public enum State: String, Sendable {
        case queued
        case running
        case completed
        case failed
        case cancelled
    }
    public let state: State
    public let exitCode: Int?
    public let summary: String
    public let outputDigest: String?
    public let outputBytes: Int?
    public let errorCode: String?
    public let errorMessage: String?

    public init(state: State, exitCode: Int?, summary: String,
                outputDigest: String?, outputBytes: Int?,
                errorCode: String?, errorMessage: String?) {
        self.state = state
        self.exitCode = exitCode
        self.summary = String(summary.prefix(262_144))
        self.outputDigest = outputDigest
        self.outputBytes = outputBytes
        self.errorCode = errorCode
        self.errorMessage = errorMessage.map { String($0.prefix(512)) }
    }
}

public protocol C02MCPSetupCommandExecuting: Sendable {
    func submit(recordID: UUID, step: C02MCPSetupStep, payload: Data,
                binding: C02MCPSetupBinding) async throws -> C02MCPSetupCommandHandle
    func state(_ handle: C02MCPSetupCommandHandle) async -> C02MCPSetupCommandResult
    func cancel(_ handle: C02MCPSetupCommandHandle) async throws
}

public struct C02MCPSetupServiceHandle: Codable, Sendable, Equatable {
    public let id: UUID
    public let endpoint: URL
    public let startedAt: Date

    public init(id: UUID, endpoint: URL, startedAt: Date = Date()) {
        self.id = id
        self.endpoint = endpoint
        self.startedAt = startedAt
    }
}

public enum C02MCPSetupServiceStatus: Sendable, Equatable {
    case running(URL)
    case stopped
    case failed(String)
}

/// The long-lived service lane is an explicit C01 capability. Android does
/// not currently expose a long-lived `exec`/service target, so an absent
/// implementation is an honest `serviceLaneUnavailable` — never an App
/// subprocess, never an echoing PTY presented as a service.
public protocol C02MCPSetupServiceHosting: Sendable {
    func start(binding: C02MCPSetupBinding, recordID: UUID,
               projectRelativePath: String) async throws -> C02MCPSetupServiceHandle
    func status(_ handle: C02MCPSetupServiceHandle,
                binding: C02MCPSetupBinding) async -> C02MCPSetupServiceStatus
    func stop(_ handle: C02MCPSetupServiceHandle,
              binding: C02MCPSetupBinding) async throws
}

public struct C02MCPSetupVerification: Codable, Sendable, Equatable {
    public let endpoint: String
    public let toolNames: [String]
    public let smokeTool: String
    public let smokeDigest: String
    public let protocolEra: String

    public init(endpoint: String, toolNames: [String], smokeTool: String,
                smokeDigest: String, protocolEra: String) {
        self.endpoint = endpoint
        self.toolNames = Array(toolNames.prefix(C02MCPSetupLimits.maximumToolRows))
        self.smokeTool = smokeTool
        self.smokeDigest = smokeDigest
        self.protocolEra = protocolEra
    }
}

public protocol C02MCPSetupDiscoveryProbing: Sendable {
    func verify(endpoint: URL, displayName: String) async throws -> C02MCPSetupVerification
}

public struct C02MCPSetupConnectionReceipt: Codable, Sendable, Equatable {
    public let serverID: UUID
    public let revision: String?

    public init(serverID: UUID, revision: String?) {
        self.serverID = serverID
        self.revision = revision
    }
}

/// The commit seam binds to the ORIGINAL MCP domain save path. It receives
/// only a validated auth-free loopback configuration; credential bytes are
/// never accepted by this flow.
public protocol C02MCPSetupConnectionCommitting: Sendable {
    func commit(_ configuration: MCPServerConfiguration) async throws -> C02MCPSetupConnectionReceipt
}

public enum C02MCPSetupGenerationState: Sendable, Equatable {
    case running
    case completed
    case failed(String)
    case cancelled
}

public protocol C02MCPSetupGenerationRunning: Sendable {
    func begin(recordID: UUID, project: C02MCPSetupProject,
               environmentID: String, goal: String) async throws -> UUID
    func state(runID: UUID) async -> C02MCPSetupGenerationState
    func cancel(runID: UUID) async
}

// MARK: - Real stdio framing (newline-delimited JSON-RPC over a byte pipe)

public struct C02MCPSetupStdioConfig: Sendable, Equatable {
    public let projectID: UUID
    public let environmentID: String
    public let rootIdentity: String
    public let taskID: UUID?
    public let serverRevision: UInt64
    public let displayName: String
    public let command: String
    public let arguments: [String]
    public let cwdRelative: String

    public init(projectID: UUID, environmentID: String, rootIdentity: String,
                taskID: UUID?, serverRevision: UInt64, displayName: String,
                command: String, arguments: [String], cwdRelative: String) {
        self.projectID = projectID
        self.environmentID = environmentID
        self.rootIdentity = rootIdentity
        self.taskID = taskID
        self.serverRevision = serverRevision
        self.displayName = displayName
        self.command = command
        self.arguments = arguments
        self.cwdRelative = cwdRelative
    }
}

/// A REAL process pipe: stdin, stdout and stderr are distinct byte streams.
/// The C01 owner must supply this over its long-lived Linux session lane.
/// A PTY channel that merges output and echoes input cannot satisfy this
/// contract; the client detects the echo and refuses it.
public protocol C02MCPSetupStdioChannel: Sendable {
    func write(_ data: Data) async throws
    func readLine(maxBytes: Int, timeout: TimeInterval) async throws -> Data?
    func drainStderr(maxBytes: Int) async -> Data
    func close() async
}

public actor C02MCPStdioClient {
    public static let supportedProtocolRevisions: Set<String> = [
        "2025-06-18", "2025-03-26", "2024-11-05",
    ]
    public static let maximumPages = 32
    public static let maximumTools = 512

    private let config: C02MCPSetupStdioConfig
    private let channel: any C02MCPSetupStdioChannel
    private let isLive: @Sendable () -> Bool
    private var nextRequestID = 2
    private var activeRequest = false
    private var closed = false

    public init(config: C02MCPSetupStdioConfig,
                channel: any C02MCPSetupStdioChannel,
                isLive: @escaping @Sendable () -> Bool) {
        self.config = config
        self.channel = channel
        self.isLive = isLive
    }

    public func initialize(timeout: TimeInterval = 15) async throws -> String {
        try checkUsable()
        guard !config.command.isEmpty else {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The Linux stdio process lane is not available in this build.",
                                     retryable: true)
        }
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "Floe", "version": C02MCPSetupLimits.clientCompatibilityVersion],
            ] as [String: Any],
        ]
        let response = try await perform(request, timeout: timeout)
        guard let result = response["result"] as? [String: Any],
              let revision = result["protocolVersion"] as? String,
              Self.supportedProtocolRevisions.contains(revision) else {
            throw C02MCPSetupFailure(.stdioProtocolMismatch,
                                     message: "The stdio MCP server did not negotiate a supported protocol revision.",
                                     retryable: false)
        }
        try await sendNotification(method: "notifications/initialized", params: [:])
        return revision
    }

    public func listTools(timeout: TimeInterval = 20) async throws -> [MCPDiscoveredTool] {
        try checkUsable()
        var tools: [MCPDiscoveredTool] = []
        var cursor: String?
        var metadataBytes = 0
        for _ in 0..<Self.maximumPages {
            guard isLive(), !closed else {
                throw C02MCPSetupFailure(.stdioUnavailable,
                                         message: "The Linux server configuration changed while tools were being read.",
                                         retryable: true)
            }
            try Task.checkCancellation()
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let response = try await perform([
                "jsonrpc": "2.0",
                "id": nextID(),
                "method": "tools/list",
                "params": params,
            ], timeout: timeout)
            guard let result = response["result"] as? [String: Any],
                  let rows = result["tools"] as? [[String: Any]] else {
                throw C02MCPSetupFailure(.stdioResponseInvalid,
                                         message: "The stdio MCP server returned an invalid tools/list result.",
                                         retryable: false)
            }
            for row in rows {
                guard tools.count < Self.maximumTools,
                      let name = row["name"] as? String, !name.isEmpty,
                      name.utf8.count <= 128 else {
                    throw C02MCPSetupFailure(.stdioResponseInvalid,
                                             message: "The stdio MCP server returned an invalid tool identity.",
                                             retryable: false)
                }
                let description = (row["description"] as? String) ?? ""
                let schema = row["inputSchema"] as? [String: Any] ?? [:]
                let schemaData = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data()
                guard schemaData.count <= C02MCPSetupLimits.maximumToolSchemaBytes else {
                    throw C02MCPSetupFailure(.stdioResponseInvalid,
                                             message: "A stdio MCP tool schema exceeded the supported bound.",
                                             retryable: false)
                }
                metadataBytes += description.utf8.count + schemaData.count + name.utf8.count
                guard metadataBytes <= C02MCPSetupLimits.maximumToolMetadataBytes else {
                    throw C02MCPSetupFailure(.stdioResponseInvalid,
                                             message: "The stdio MCP tool catalog exceeded the supported metadata bound.",
                                             retryable: false)
                }
                let annotations = row["annotations"] as? [String: Any]
                tools.append(MCPDiscoveredTool(
                    remoteName: String(name.prefix(128)),
                    displayName: nil,
                    toolDescription: String(description.prefix(4_096)),
                    inputSchemaJSON: String(decoding: schemaData, as: UTF8.self),
                    readOnlyHint: annotations?["readOnlyHint"] as? Bool ?? false,
                    destructiveHint: annotations?["destructiveHint"] as? Bool ?? false))
            }
            cursor = result["nextCursor"] as? String
            if cursor?.isEmpty != false { return tools }
            guard let cursor, cursor.utf8.count <= 512 else {
                throw C02MCPSetupFailure(.stdioResponseInvalid,
                                         message: "The stdio MCP server returned an invalid pagination cursor.",
                                         retryable: false)
            }
        }
        throw C02MCPSetupFailure(.stdioResponseInvalid,
                                 message: "The stdio MCP tool catalog exceeded the supported page bound.",
                                 retryable: false)
    }

    public func callTool(name: String, argumentsJSON: Data,
                         timeout: TimeInterval = 30) async throws -> ToolExecutionOutput {
        try checkUsable()
        guard let arguments = (try? JSONSerialization.jsonObject(with: argumentsJSON)) as? [String: Any],
              argumentsJSON.count <= 65_536 else {
            throw C02MCPSetupFailure(.invalidRequest,
                                     message: "The stdio tool arguments are not a bounded JSON object.",
                                     retryable: false)
        }
        let response = try await perform([
            "jsonrpc": "2.0",
            "id": nextID(),
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ], timeout: timeout)
        guard let result = response["result"] as? [String: Any] else {
            throw C02MCPSetupFailure(.stdioResponseInvalid,
                                     message: "The stdio MCP server returned an invalid tools/call result.",
                                     retryable: false)
        }
        let isError = result["isError"] as? Bool ?? false
        var text = ""
        if let blocks = result["content"] as? [[String: Any]] {
            for block in blocks where (block["type"] as? String) == "text" {
                text += (block["text"] as? String) ?? ""
                if text.utf8.count > 262_144 { break }
            }
        }
        if text.isEmpty,
           let structured = result["structuredContent"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            text = String(decoding: data, as: UTF8.self)
        }
        guard !text.isEmpty, text.utf8.count <= 262_144 else {
            throw C02MCPSetupFailure(.stdioResponseInvalid,
                                     message: "The stdio MCP tool result did not contain bounded text output.",
                                     retryable: false)
        }
        return ToolExecutionOutput(
            summary: text,
            fullOutputSHA256: SignedContentArchive.sha256Hex(Data(text.utf8)),
            exitStatus: Int32(isError ? 1 : 0))
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        // Drain the separated stderr stream with the fixed cap. The bytes
        // are deliberately discarded: they are untrusted process output and
        // never cross the setup wire or a persisted record.
        _ = await channel.drainStderr(maxBytes: C02MCPSetupLimits.maximumStderrBytes)
        await channel.close()
    }

    private func checkUsable() throws {
        try Task.checkCancellation()
        guard !closed else {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The Linux stdio channel is closed.",
                                     retryable: true)
        }
    }

    private func perform(_ object: [String: Any],
                         timeout: TimeInterval) async throws -> [String: Any] {
        try checkUsable()
        guard isLive() else {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The Linux server configuration changed before the request was sent.",
                                     retryable: true)
        }
        guard !activeRequest else {
            throw C02MCPSetupFailure(.stdioResponseInvalid,
                                     message: "A stdio MCP request is already in flight.",
                                     retryable: true)
        }
        activeRequest = true
        defer { activeRequest = false }
        let request = try encode(object)
        try await channel.write(request)
        while true {
            try checkUsable()
            guard isLive() else {
                throw C02MCPSetupFailure(.stdioUnavailable,
                                         message: "The Linux server configuration changed while awaiting a reply.",
                                         retryable: true)
            }
            guard let line = try await channel.readLine(
                maxBytes: C02MCPSetupLimits.maximumStdioLineBytes,
                timeout: timeout) else {
                throw C02MCPSetupFailure(.stdioTimeout,
                                         message: "The stdio MCP server closed the pipe before replying.",
                                         retryable: true)
            }
            if line == request {
                // A PTY echoes the input line. That is not a byte pipe and
                // cannot prove a real JSON-RPC peer.
                throw C02MCPSetupFailure(.stdioResponseInvalid,
                                         message: "The stdio channel echoed its input; a real separated pipe is required.",
                                         retryable: false)
            }
            guard let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                throw C02MCPSetupFailure(.stdioResponseInvalid,
                                         message: "The stdio MCP server returned a non-JSON line.",
                                         retryable: false)
            }
            guard let id = exactInt(reply["id"]) else {
                // Notification/batch progress is unrelated to this request.
                continue
            }
            guard id == exactInt(object["id"]) else { continue }
            if let error = reply["error"] as? [String: Any] {
                let code = exactInt(error["code"]) ?? 0
                let message = (error["message"] as? String) ?? "MCP stdio error"
                throw C02MCPSetupFailure(.stdioResponseInvalid,
                                         message: "MCP stdio \(code): \(String(message.prefix(256)))",
                                         retryable: false)
            }
            guard reply["result"] != nil else {
                throw C02MCPSetupFailure(.stdioResponseInvalid,
                                         message: "The stdio MCP server reply contained neither result nor error.",
                                         retryable: false)
            }
            return reply
        }
    }

    private func sendNotification(method: String, params: [String: Any]) async throws {
        try checkUsable()
        guard isLive() else {
            throw C02MCPSetupFailure(.stdioUnavailable,
                                     message: "The Linux server configuration changed before the handshake completed.",
                                     retryable: true)
        }
        try await channel.write(try encode([
            "jsonrpc": "2.0", "method": method, "params": params,
        ]))
    }

    private func encode(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= C02MCPSetupLimits.maximumStdioLineBytes else {
            throw C02MCPSetupFailure(.invalidRequest,
                                     message: "The stdio MCP request could not be encoded.",
                                     retryable: false)
        }
        var line = data
        line.append(0x0a)
        return line
    }

    private func nextID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func exactInt(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: return int
        case let number as NSNumber:
            let double = number.doubleValue
            guard double.isFinite, double.rounded() == double,
                  double >= Double(Int.min), double <= Double(Int.max) else { return nil }
            return Int(double)
        default: return nil
        }
    }
}

// MARK: - Setup center

public struct C02MCPSetupDependencies: Sendable {
    public let epoch: UInt64
    public let appSupportRoot: URL
    public let projects: any C02MCPSetupProjectProviding
    public let environments: any C02MCPSetupEnvironmentProviding
    public let commands: any C02MCPSetupCommandExecuting
    public let serviceHost: (any C02MCPSetupServiceHosting)?
    public let discovery: any C02MCPSetupDiscoveryProbing
    public let connections: any C02MCPSetupConnectionCommitting
    public let generation: (any C02MCPSetupGenerationRunning)?
    public let records: (any C02MCPSetupRecordStoring)?
    public let liveEpoch: @Sendable () -> UInt64
    public let templateAssetAvailable: Bool
    public let stdioLaneAvailable: Bool

    public init(epoch: UInt64, appSupportRoot: URL,
                projects: any C02MCPSetupProjectProviding,
                environments: any C02MCPSetupEnvironmentProviding,
                commands: any C02MCPSetupCommandExecuting,
                serviceHost: (any C02MCPSetupServiceHosting)?,
                discovery: any C02MCPSetupDiscoveryProbing,
                connections: any C02MCPSetupConnectionCommitting,
                generation: (any C02MCPSetupGenerationRunning)?,
                records: (any C02MCPSetupRecordStoring)?,
                liveEpoch: @escaping @Sendable () -> UInt64,
                templateAssetAvailable: Bool,
                stdioLaneAvailable: Bool) {
        self.epoch = epoch
        self.appSupportRoot = appSupportRoot
        self.projects = projects
        self.environments = environments
        self.commands = commands
        self.serviceHost = serviceHost
        self.discovery = discovery
        self.connections = connections
        self.generation = generation
        self.records = records
        self.liveEpoch = liveEpoch
        self.templateAssetAvailable = templateAssetAvailable
        self.stdioLaneAvailable = stdioLaneAvailable
    }
}

public actor C02MCPSetupCenter {
    public let epoch: UInt64
    private let dependencies: C02MCPSetupDependencies
    private let templateStore: C02MCPSetupTemplateStore
    private var records: [UUID: C02MCPSetupRecord] = [:]
    private var loaded = false
    private var activeJobs: [UUID: C02MCPSetupCommandHandle] = [:]

    public init(dependencies: C02MCPSetupDependencies) {
        self.epoch = dependencies.epoch
        self.dependencies = dependencies
        self.templateStore = C02MCPSetupTemplateStore(
            root: dependencies.appSupportRoot.appendingPathComponent("MCPSetup/Templates",
                                                                      isDirectory: true))
    }

    // MARK: Options / preflight

    public func options(projectID: UUID? = nil) async throws -> C02MCPSetupOptions {
        try await ensureLoaded()
        try checkLive(operation: "options")
        let projects = try await dependencies.projects.projects()
        var environments: [C02MCPSetupEnvironmentOption] = []
        if let projectID, let project = projects.first(where: { $0.id == projectID }) {
            environments = try await dependencies.projects.environments(project: project)
        }
        return C02MCPSetupOptions(
            projects: projects,
            environments: environments,
            templateAvailable: dependencies.templateAssetAvailable,
            serviceLaneAvailable: dependencies.serviceHost != nil,
            generationAvailable: dependencies.generation != nil,
            stdioLaneAvailable: dependencies.stdioLaneAvailable,
            unavailableReason: dependencies.serviceHost == nil ? "serviceLaneUnavailable" : nil)
    }

    public func validateRemote(_ draft: C02MCPSetupDraft) -> C02MCPSetupPreflight {
        C02MCPSetupPreflightLogic.evaluate(draft)
    }

    // MARK: Record creation / template staging

    public func create(_ draft: C02MCPSetupDraft) async throws -> C02MCPSetupRecord {
        try await ensureLoaded()
        try checkLive(operation: "create")
        guard draft.mode == .linuxService else {
            throw C02MCPSetupFailure(.invalidDraft,
                                     message: "Remote MCP servers use the existing editor and save path.",
                                     retryable: false)
        }
        let preflight = C02MCPSetupPreflightLogic.evaluate(draft)
        guard preflight.isValid, let projectID = preflight.projectID,
              let environmentID = preflight.environmentID else {
            throw C02MCPSetupFailure(.invalidDraft,
                                     message: "Complete the project, environment, service name and port.",
                                     retryable: false)
        }
        guard records.count < C02MCPSetupLimits.maximumRecords else {
            throw C02MCPSetupFailure(.recordsFull,
                                     message: "Too many MCP service records are retained. Remove an old record first.",
                                     retryable: false)
        }
        guard preflight.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                dependencies.generation != nil else {
            throw C02MCPSetupFailure(.generationUnavailable,
                                     message: "Custom MCP tool generation is not available in this build yet.",
                                     retryable: false)
        }
        guard let project = try await dependencies.projects.project(id: projectID) else {
            throw C02MCPSetupFailure(.projectMissing,
                                     message: "The selected project no longer exists.",
                                     retryable: true)
        }
        let rootState = C01ProjectRootLayout.inspectProjectDirectory(
            rootPath: project.rootURL.path, projectID: project.id)
        guard rootState == .available else {
            throw C02MCPSetupFailure(.projectRootUnsafe,
                                     message: "The selected project directory is missing or unsafe.",
                                     retryable: false)
        }
        let rootIdentity = C02MCPSetupWorkspaceStager.projectRootIdentity(project.rootURL)
        guard let facts = await dependencies.environments.environment(id: environmentID, project: project) else {
            throw C02MCPSetupFailure(.environmentMissing,
                                     message: "The selected environment no longer exists.",
                                     retryable: true)
        }
        guard facts.kind == ContainerKind.project.rawValue else {
            throw C02MCPSetupFailure(.environmentNotProject,
                                     message: "Select the project environment; a session or template environment cannot own this service.",
                                     retryable: false)
        }
        guard facts.ownerID == rootIdentity else {
            throw C02MCPSetupFailure(.environmentNotProject,
                                     message: "The selected environment belongs to a different project.",
                                     retryable: false)
        }
        guard facts.state == ContainerState.active.rawValue,
              !facts.requiresRebuild,
              facts.layerFormat == ContainerRecord.currentLayerFormat ||
                facts.layerFormat == ContainerRecord.currentLayerFormat - 1 else {
            throw C02MCPSetupFailure(.environmentUnavailable,
                                     message: "The selected project environment is stopped, rebuilding or in an unsupported layer format.",
                                     retryable: true)
        }
        guard facts.backend == EnvironmentExecutionBackend.linuxPRoot.rawValue else {
            throw C02MCPSetupFailure(.environmentNotLinux,
                                     message: "The selected environment is not the resolved Android Linux backend.",
                                     retryable: false)
        }
        let environments = try await dependencies.projects.environments(project: project)
        let label = environments.first { $0.id == environmentID }?.label ?? environmentID
        let recordID = UUID()
        let sanitizedName = SecretIngressScanner.scan(preflight.displayName).sanitizedText
        let sanitizedDetails = SecretIngressScanner.scan(preflight.details).sanitizedText
        var record = C02MCPSetupRecord(
            id: recordID,
            draft: C02MCPSetupDraft(
                mode: .linuxService,
                displayName: sanitizedName,
                endpointText: "",
                authentication: .none,
                credentialHeaderName: "",
                allowInsecureHTTP: true,
                allowInCanvas: preflight.allowInCanvas,
                timeoutSeconds: preflight.timeoutSeconds,
                projectID: project.id,
                environmentID: environmentID,
                portText: String(preflight.port ?? 0),
                details: sanitizedDetails),
            projectID: project.id,
            projectName: project.name,
            projectRevision: project.revision,
            environmentID: environmentID,
            environmentLabel: label,
            containerID: facts.containerID,
            baseRevision: facts.baseRevision,
            rootIdentity: rootIdentity,
            steps: C02MCPSetupBuildPlan.initialSteps(recordID: recordID))
        try await saveRecord(&record)
        return record
    }

    public func stageTemplateChunk(recordID: UUID, chunk: Data, offset: Int,
                                   final: Bool) async throws -> Bool {
        try checkLive(operation: "template")
        guard records[recordID] != nil else {
            throw C02MCPSetupFailure(.recordMissing,
                                     message: "The MCP service record was not found.",
                                     retryable: false)
        }
        return try await templateStore.append(
            recordID: recordID, chunk: chunk, offset: offset,
            final: final,
            archiveSHA256: C02MCPSetupTemplateIdentity.archiveSHA256)
    }

    // MARK: Prepare / generation

    public func prepare(recordID: UUID, expectedRevision: UInt64) async throws -> C02MCPSetupRecord {
        try await ensureLoaded()
        try checkLive(operation: "prepare")
        guard var record = records[recordID] else {
            throw C02MCPSetupFailure(.recordMissing,
                                     message: "The MCP service record was not found.",
                                     retryable: false)
        }
        guard record.revision == expectedRevision else {
            throw C02MCPSetupFailure(.staleRecord,
                                     message: "The MCP service record changed. Re-read it before retrying.",
                                     retryable: true)
        }
        guard record.phase == .preparing || record.phase == .prepared ||
                record.phase == .generating else {
            if record.phase == .failed || record.phase == .interrupted {
                throw C02MCPSetupFailure(.buildStepFailed,
                                         message: record.errorMessage ?? "This MCP service record must be started over.",
                                         retryable: false)
            }
            return record
        }
        if record.workspaceRelativePath == nil {
            let project = try await resolveProject(record)
            let archive = try await templateStore.archive(recordID: record.id)
            let workspace = try C02MCPSetupWorkspaceStager.prepare(
                recordID: record.id, projectRoot: project.rootURL, archive: archive)
            record.workspaceRelativePath = workspace.projectRelativePath
            record.phase = .prepared
        }
        if !record.draft.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let generation = dependencies.generation else {
                throw C02MCPSetupFailure(.generationUnavailable,
                                         message: "Custom MCP tool generation is not available in this build yet.",
                                         retryable: false)
            }
            if let runID = record.generationRunID {
                switch await generation.state(runID: runID) {
                case .running:
                    record.phase = .generating
                case .completed:
                    record.phase = .prepared
                case .cancelled:
                    record.phase = .failed
                    record.errorCode = C02MCPSetupFailure.Code.generationFailed.rawValue
                    record.errorMessage = "MCP tool generation was cancelled."
                case .failed(let message):
                    record.phase = .failed
                    record.errorCode = C02MCPSetupFailure.Code.generationFailed.rawValue
                    record.errorMessage = String(SecretRedactor.redact(message).prefix(512))
                }
            } else {
                if record.phase == .preparing || record.phase == .prepared {
                    guard let project = try await dependencies.projects.project(id: record.projectID) else {
                        throw C02MCPSetupFailure(.projectMissing,
                                                 message: "The selected project no longer exists.",
                                                 retryable: true)
                    }
                    let goal = generationGoal(record: record, project: project)
                    let runID = try await generation.begin(
                        recordID: record.id, project: project,
                        environmentID: record.environmentID, goal: goal)
                    record.generationRunID = runID
                    record.phase = .generating
                }
            }
        }
        try await saveRecord(&record)
        return record
    }

    // MARK: Build

    public func startBuild(recordID: UUID, expectedRevision: UInt64) async throws -> C02MCPSetupRecord {
        try await ensureLoaded()
        try checkLive(operation: "build.start")
        guard var record = records[recordID] else {
            throw C02MCPSetupFailure(.recordMissing,
                                     message: "The MCP service record was not found.",
                                     retryable: false)
        }
        guard record.revision == expectedRevision else {
            throw C02MCPSetupFailure(.staleRecord,
                                     message: "The MCP service record changed. Re-read it before retrying.",
                                     retryable: true)
        }
        guard record.phase == .prepared || record.phase == .building else {
            throw C02MCPSetupFailure(.invalidRequest,
                                     message: "Dependency preparation has not been prepared for this record.",
                                     retryable: true)
        }
        if record.phase == .building,
           let running = record.steps.first(where: { $0.state == .running }) {
            return record
        }
        switch C02MCPSetupBuildPlan.nextAction(record.steps) {
        case .allCompleted:
            record.phase = .readyToStart
            try await saveRecord(&record)
            return record
        case .attach(let index):
            let step = record.steps[index]
            if step.state == .failed || step.state == .cancelled {
                throw C02MCPSetupFailure(.buildStepFailed,
                                         message: "A dependency step failed. Start over to build this service again.",
                                         retryable: false)
            }
            if activeJobs[record.id] == nil {
                markFailed(&record, code: .jobOwnershipMismatch,
                           message: "The dependency job is no longer owned by this setup record.")
                try await saveRecord(&record)
            }
            return record
        case .submit(let index):
            try await submitStep(index: index, record: &record)
            return record
        }
    }

    public func pollBuild(recordID: UUID, expectedRevision: UInt64) async throws -> C02MCPSetupRecord {
        try await ensureLoaded()
        try checkLive(operation: "build.poll")
        guard var record = records[recordID] else {
            throw C02MCPSetupFailure(.recordMissing,
                                     message: "The MCP service record was not found.",
                                     retryable: false)
        }
        guard record.revision == expectedRevision else {
            throw C02MCPSetupFailure(.staleRecord,
                                     message: "The MCP service record changed. Re-read it before polling.",
                                     retryable: true)
        }
        guard record.phase == .building else { return record }
        guard let index = record.steps.firstIndex(where: { $0.state == .running }),
              let handle = activeJobs[record.id] else {
            // No live handle: a persisted running row without its exact
            // handle is not ours to guess. Fail honestly.
            markFailed(&record, code: .jobOwnershipMismatch,
                       message: "The dependency job is no longer owned by this setup record.")
            try await saveRecord(&record)
            return record
        }
        let result = await dependencies.commands.state(handle)
        switch result.state {
        case .queued, .running:
            return record
        case .cancelled:
            record.steps[index].state = .cancelled
            activeJobs[record.id] = nil
            markFailed(&record, code: .buildStepFailed,
                       message: "Dependency preparation was cancelled.")
            try await saveRecord(&record)
            return record
        case .failed:
            record.steps[index].state = .failed
            record.steps[index].errorCode = result.errorCode
            activeJobs[record.id] = nil
            markFailed(&record, code: .buildStepFailed,
                       message: result.errorMessage ?? result.errorCode ?? "Dependency preparation failed.")
            try await saveRecord(&record)
            return record
        case .completed:
            record.steps[index].exitCode = result.exitCode
            record.steps[index].outputDigest = result.outputDigest
            record.steps[index].outputBytes = result.outputBytes
            activeJobs[record.id] = nil
            guard let exit = result.exitCode else {
                record.steps[index].state = .failed
                record.steps[index].errorCode = C02MCPSetupFailure.Code.jobCompletedWithoutExitEvidence.rawValue
                markFailed(&record, code: .jobCompletedWithoutExitEvidence,
                           message: "The dependency job completed without parseable exit evidence.")
                try await saveRecord(&record)
                return record
            }
            guard exit == 0 else {
                record.steps[index].state = .failed
                record.steps[index].errorCode = "exit_\(exit)"
                markFailed(&record, code: .buildStepFailed,
                           message: "Dependency preparation failed with exit \(exit).")
                try await saveRecord(&record)
                return record
            }
            if record.steps[index].name == .probe {
                do {
                    _ = try C02MCPSetupBuildPlan.parseProbe(result.summary)
                } catch let failure as C02MCPSetupFailure {
                    record.steps[index].state = .failed
                    record.steps[index].errorCode = failure.code.rawValue
                    markFailed(&record, code: failure.code, message: failure.message)
                    try await saveRecord(&record)
                    return record
                } catch {
                    record.steps[index].state = .failed
                    record.steps[index].errorCode = C02MCPSetupFailure.Code.dependencyProbeMissing.rawValue
                    markFailed(&record, code: .dependencyProbeMissing,
                               message: "The Linux environment probe did not return usable evidence.")
                    try await saveRecord(&record)
                    return record
                }
            }
            record.steps[index].state = .completed
            switch C02MCPSetupBuildPlan.nextAction(record.steps) {
            case .allCompleted:
                record.phase = .readyToStart
                try await saveRecord(&record)
            case .submit(let next):
                try await submitStep(index: next, record: &record)
            case .attach:
                try await saveRecord(&record)
            }
            return record
        }
    }

    public func cancelBuild(recordID: UUID, expectedRevision: UInt64) async throws -> C02MCPSetupRecord {
        try await ensureLoaded()
        try checkLive(operation: "build.cancel")
        guard var record = records[recordID] else {
            throw C02MCPSetupFailure(.recordMissing,
                                     message: "The MCP service record was not found.",
                                     retryable: false)
        }
        guard record.revision == expectedRevision else {
            throw C02MCPSetupFailure(.staleRecord,
                                     message: "The MCP service record changed. Re-read it before cancelling.",
                                     retryable: true)
        }
        if let handle = activeJobs[record.id] {
            do {
                try await dependencies.commands.cancel(handle)
            } catch {
                throw C02MCPSetupFailure(.jobOwnershipMismatch,
                                         message: "The dependency job could not be cancelled or drained.",
                                         retryable: true)
            }
            activeJobs[record.id] = nil
        }
        if let index = record.steps.firstIndex(where: { $0.state == .running }) {
            record.steps[index].state = .cancelled
        }
        record.phase = .stopped
        record.errorCode = nil
        record.errorMessage = nil
        try await saveRecord(&record)
        return record
    }

    // MARK: Service / verify / commit

    public func startService(recordID: UUID, expectedRevision: UInt64) async throws -> C02MCPSetupRecord {
        try await ensureLoaded()
        try checkLive(operation: "service.start")
        guard var record = records[recordID] else {
            throw C02MCPSetupFailure(.recordMissing,
                                     message: "The MCP service record was not found.",
                                     retryable: false)
        }
        guard record.revision == expectedRevision else {
            throw C02MCPSetupFailure(.staleRecord,
                                     message: "The MCP service record changed. Re-read it before starting.",
                                     retryable: true)
        }
        guard record.phase == .readyToStart || record.phase == .starting else {
            throw C02MCPSetupFailure(.buildIncomplete,
                                     message: "Every dependency step must complete before the MCP service starts.",
                                     retryable: false)
        }
        if record.phase == .starting, record.serviceID != nil { return record }
        guard let serviceHost = dependencies.serviceHost else {
            record.errorCode = C02MCPSetupFailure.Code.serviceLaneUnavailable.rawValue
            record.errorMessage = "The Android Linux service lane is not available in this build."
            try await saveRecord(&record)
            throw C02MCPSetupFailure(.serviceLaneUnavailable,
                                     message: "The Android Linux service lane is not available in this build.",
                                     retryable: true)
        }
        guard record.steps.allSatisfy({ $0.state == .completed }),
              let workspace = record.workspaceRelativePath else {
            throw C02MCPSetupFailure(.buildIncomplete,
                                     message: "Dependency preparation is incomplete.",
                                     retryable: false)
        }
        let binding = try await resolveBinding(record)
        let handle: C02MCPSetupServiceHandle
        do {
            handle = try await serviceHost.start(
                binding: binding, recordID: record.id,
                projectRelativePath: workspace)
        } catch let failure as C02MCPSetupFailure {
            record.errorCode = failure.code.rawValue
            record.errorMessage = failure.message
            try await saveRecord(&record)
            throw failure
        } catch {
            record.errorCode = C02MCPSetupFailure.Code.serviceStartFailed.rawValue
            record.errorMessage = "The MCP service could not start."
            try await saveRecord(&record)
            throw C02MCPSetupFailure(.serviceStartFailed,
                                     message: "The MCP service could not start.",
                                     retryable: true)
        }
        guard let port = Int(record.draft.portText),
              isServiceBase(handle.endpoint), handle.endpoint.port == port else {
            try? await serviceHost.stop(handle, binding: binding)
            markFailed(&record, code: .serviceEndpointMismatch,
                       message: "The MCP service did not publish the expected loopback endpoint.")
            try await saveRecord(&record)
            return record
        }
        record.serviceID = handle.id
        record.serviceEndpoint = handle.endpoint.absoluteString
        record.phase = .starting
        record.errorCode = nil
        record.errorMessage = nil
        try await saveRecord(&record)
        return record
    }

    public func verify(recordID: UUID, expectedRevision: UInt64) async throws -> C02MCPSetupRecord {
        try await ensureLoaded()
        try checkLive(operation: "verify")
        guard var record = records[recordID] else {
            throw C02MCPSetupFailure(.recordMissing,
                                     message: "The MCP service record was not found.",
                                     retryable: false)
        }
        guard record.revision == expectedRevision else {
            throw C02MCPSetupFailure(.staleRecord,
                                     message: "The MCP service record changed. Re-read it before verifying.",
                                     retryable: true)
        }
        guard record.phase == .starting || record.phase == .verifying,
              let endpointString = record.serviceEndpoint,
              let endpoint = URL(string: endpointString),
              let port = Int(record.draft.portText),
              isLoopback(endpoint), endpoint.path == "/mcp", endpoint.port == port else {
            throw C02MCPSetupFailure(.serviceNotRunning,
                                     message: "The MCP service is not running on its verified loopback endpoint.",
                                     retryable: true)
        }
        guard let serviceHost = dependencies.serviceHost,
              let serviceID = record.serviceID else {
            throw C02MCPSetupFailure(.serviceLaneUnavailable,
                                     message: "The Android Linux service lane is not available in this build.",
                                     retryable: true)
        }
        let binding = try await resolveBinding(record)
        let handle = C02MCPSetupServiceHandle(id: serviceID, endpoint: endpoint)
        switch await serviceHost.status(handle, binding: binding) {
        case .running(let live):
            guard live == endpoint else {
                markFailed(&record, code: .serviceEndpointMismatch,
                           message: "The MCP service endpoint changed after it started.")
                try await saveRecord(&record)
                return record
            }
        case .stopped, .failed:
            markFailed(&record, code: .serviceNotRunning,
                       message: "The MCP service stopped before verification.")
            try await saveRecord(&record)
            return record
        }
        record.phase = .verifying
        try await saveRecord(&record)
        let mcpEndpoint = endpoint.appendingPathComponent("mcp")
        let verification: C02MCPSetupVerification
        do {
            verification = try await dependencies.discovery.verify(
                endpoint: mcpEndpoint, displayName: record.draft.displayName)
        } catch let failure as C02MCPSetupFailure {
            markFailed(&record, code: failure.code, message: failure.message)
            try await saveRecord(&record)
            return record
        } catch {
            markFailed(&record, code: .verificationFailed,
                       message: "The MCP client could not verify the service.")
            try await saveRecord(&record)
            return record
        }
        guard verification.endpoint == mcpEndpoint.absoluteString,
              verification.toolNames.contains("service_status"),
              verification.smokeTool == "service_status",
              isHexDigest(verification.smokeDigest) else {
            markFailed(&record, code: .smokeTestFailed,
                       message: "The MCP service did not pass its real client smoke test.")
            try await saveRecord(&record)
            return record
        }
        record.receipt = C02MCPSetupReceipt(
            recordID: record.id,
            projectID: record.projectID,
            environmentID: record.environmentID,
            containerID: record.containerID,
            baseRevision: record.baseRevision,
            rootIdentity: record.rootIdentity,
            endpoint: mcpEndpoint.absoluteString,
            smokeDigest: verification.smokeDigest,
            verifiedTools: verification.toolNames,
            verifiedAt: Date())
        record.phase = .ready
        record.errorCode = nil
        record.errorMessage = nil
        try await saveRecord(&record)
        return record
    }

    public func commit(recordID: UUID, expectedRevision: UInt64) async throws -> C02MCPSetupRecord {
        try await ensureLoaded()
        try checkLive(operation: "commit")
        guard var record = records[recordID] else {
            throw C02MCPSetupFailure(.recordMissing,
                                     message: "The MCP service record was not found.",
                                     retryable: false)
        }
        guard record.revision == expectedRevision else {
            throw C02MCPSetupFailure(.staleRecord,
                                     message: "The MCP service record changed. Re-read it before saving.",
                                     retryable: true)
        }
        guard record.phase == .ready, let receipt = record.receipt,
              let endpoint = URL(string: receipt.endpoint),
              let port = Int(record.draft.portText),
              isLoopback(endpoint), endpoint.port == port else {
            throw C02MCPSetupFailure(.verificationFailed,
                                     message: "Verify the running MCP service before saving the connection.",
                                     retryable: true)
        }
        let configuration = MCPServerConfiguration(
            id: record.id,
            displayName: record.draft.displayName,
            endpoint: endpoint,
            enabled: true,
            allowInCanvas: record.draft.allowInCanvas,
            allowInsecureHTTP: true,
            authentication: .none,
            credentialHeaderName: "Authorization",
            timeoutSeconds: record.draft.timeoutSeconds)
        do {
            try configuration.validate()
        } catch {
            throw C02MCPSetupFailure(.invalidDraft,
                                     message: "The verified MCP configuration is not valid.",
                                     retryable: false)
        }
        let saved: C02MCPSetupConnectionReceipt
        do {
            saved = try await dependencies.connections.commit(configuration)
        } catch let failure as C02MCPSetupFailure {
            record.errorCode = failure.code.rawValue
            record.errorMessage = failure.message
            try await saveRecord(&record)
            throw failure
        } catch {
            record.errorCode = C02MCPSetupFailure.Code.connectionSaveFailed.rawValue
            record.errorMessage = "The MCP connection could not be saved."
            try await saveRecord(&record)
            throw C02MCPSetupFailure(.connectionSaveFailed,
                                     message: "The MCP connection could not be saved.",
                                     retryable: true)
        }
        guard saved.serverID == record.id else {
            throw C02MCPSetupFailure(.connectionSaveFailed,
                                     message: "The MCP connection was saved under an unexpected identity.",
                                     retryable: false)
        }
        record.receipt?.serverID = saved.serverID
        record.receipt?.newRevision = saved.revision
        record.phase = .added
        record.errorCode = nil
        record.errorMessage = nil
        try await saveRecord(&record)
        return record
    }

    // MARK: Stop / cancel / discard

    public func stop(recordID: UUID, expectedRevision: UInt64,
                     discard: Bool) async throws -> C02MCPSetupRecord? {
        try await ensureLoaded()
        try checkLive(operation: "stop")
        guard var record = records[recordID] else {
            throw C02MCPSetupFailure(.recordMissing,
                                     message: "The MCP service record was not found.",
                                     retryable: false)
        }
        guard record.revision == expectedRevision else {
            throw C02MCPSetupFailure(.staleRecord,
                                     message: "The MCP service record changed. Re-read it before cancelling.",
                                     retryable: true)
        }
        if record.phase == .added {
            if discard {
                throw C02MCPSetupFailure(.alreadyAdded,
                                         message: "The saved MCP connection must be deleted from the server list, not discarded from setup.",
                                         retryable: false)
            }
            if let serviceID = record.serviceID, let endpoint = record.serviceEndpoint.flatMap(URL.init(string:)) {
                let binding = try await resolveBinding(record,
                                                       requireCurrentRevision: false)
                if let serviceHost = dependencies.serviceHost {
                    do {
                        try await serviceHost.stop(
                            C02MCPSetupServiceHandle(id: serviceID, endpoint: endpoint),
                            binding: binding)
                    } catch {
                        throw C02MCPSetupFailure(.serviceStopFailed,
                                                 message: "The MCP service did not stop cleanly.",
                                                 retryable: true)
                    }
                }
            }
            record.serviceID = nil
            record.serviceEndpoint = nil
            try await saveRecord(&record)
            return record
        }
        if let handle = activeJobs[record.id] {
            do {
                try await dependencies.commands.cancel(handle)
            } catch let failure as C02MCPSetupFailure {
                throw failure
            } catch {
                throw C02MCPSetupFailure(.jobOwnershipMismatch,
                                         message: "The dependency job could not be drained.",
                                         retryable: true)
            }
            activeJobs[record.id] = nil
        }
        if let serviceID = record.serviceID, let endpoint = record.serviceEndpoint.flatMap(URL.init(string:)) {
            let binding = try await resolveBinding(record,
                                                   requireCurrentRevision: false)
            if let serviceHost = dependencies.serviceHost {
                do {
                    try await serviceHost.stop(
                        C02MCPSetupServiceHandle(id: serviceID, endpoint: endpoint),
                        binding: binding)
                } catch {
                    throw C02MCPSetupFailure(.serviceStopFailed,
                                             message: "The MCP service did not stop cleanly.",
                                             retryable: true)
                }
            }
        }
        record.serviceID = nil
        record.serviceEndpoint = nil
        if discard {
            // Cleanup is descriptor-free and marker-proven, but it still
            // targets the current project root. Revalidate through the C01
            // project library first: a changed revision/missing root keeps
            // the record ownership instead of deleting bytes in a project
            // this setup no longer provably owns.
            guard let project = try? await resolveProject(record) else {
                record.phase = .stopped
                record.errorCode = C02MCPSetupFailure.Code.projectChanged.rawValue
                record.errorMessage = "The project changed before discard; the staged service bytes were retained for review."
                try await saveRecord(&record)
                return record
            }
            if let workspace = record.workspaceRelativePath {
                C02MCPSetupWorkspaceStager.cleanup(
                    recordID: record.id,
                    projectRoot: project.rootURL,
                    workspace: C02MCPSetupWorkspace(
                        projectRootIdentity: record.rootIdentity,
                        projectRelativePath: workspace,
                        stagingRelativePath: C02MCPSetupLimits.serviceDirectoryName +
                            "/.staging-" + record.id.uuidString.lowercased(),
                        nodeRelativePath: workspace + "/node-http",
                        reusedCommittedDirectory: false),
                    removeCommitted: true)
            }
            await templateStore.remove(recordID: record.id)
            records.removeValue(forKey: record.id)
            try await dependencies.records?.remove(id: record.id)
            return nil
        }
        record.phase = .stopped
        record.errorCode = nil
        record.errorMessage = nil
        try await saveRecord(&record)
        return record
    }

    // MARK: Reads

    public func list() async throws -> [C02MCPSetupRecord] {
        try await ensureLoaded()
        try checkLive(operation: "list")
        return records.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(C02MCPSetupLimits.maximumRecords)
            .map { $0 }
    }

    public func record(id: UUID) async throws -> C02MCPSetupRecord {
        try await ensureLoaded()
        try checkLive(operation: "record")
        guard let record = records[id] else {
            throw C02MCPSetupFailure(.recordMissing,
                                     message: "The MCP service record was not found.",
                                     retryable: false)
        }
        return record
    }

    // MARK: Internals

    private func ensureLoaded() async throws {
        guard !loaded else { return }
        loaded = true
        if let store = dependencies.records {
            let stored = (try? await store.load()) ?? []
            for record in stored.prefix(C02MCPSetupLimits.maximumRecords) {
                var value = record
                if value.phase.isBusy {
                    value.phase = .interrupted
                    value.errorCode = "interrupted"
                    value.errorMessage = "The App stopped before this MCP service operation finished. Start over to rebuild it."
                }
                records[value.id] = value
            }
        }
    }

    private func resolveProject(_ record: C02MCPSetupRecord,
                                requireCurrentRevision: Bool = true) async throws
        -> C02MCPSetupProject {
        guard let project = try await dependencies.projects.project(id: record.projectID) else {
            throw C02MCPSetupFailure(.projectMissing,
                                     message: "The selected project no longer exists.",
                                     retryable: true)
        }
        // The C01 project library owns the exact persisted revision. Refuse
        // an active setup after any project-library write (rename/assign/
        // delete) instead of applying staged bytes to a changed project.
        if requireCurrentRevision,
           let expected = record.projectRevision, project.revision != expected {
            throw C02MCPSetupFailure(.projectChanged,
                                     message: "The project changed while this MCP service setup was active. Start over in the current project.",
                                     retryable: false)
        }
        guard C02MCPSetupWorkspaceStager.projectRootIdentity(project.rootURL) == record.rootIdentity,
              C01ProjectRootLayout.inspectProjectDirectory(
                rootPath: project.rootURL.path, projectID: project.id) == .available else {
            throw C02MCPSetupFailure(.projectRootUnsafe,
                                     message: "The project directory changed or became unsafe.",
                                     retryable: false)
        }
        return project
    }

    private func resolveBinding(_ record: C02MCPSetupRecord,
                                requireCurrentRevision: Bool = true) async throws
        -> C02MCPSetupBinding {
        let project = try await resolveProject(
            record, requireCurrentRevision: requireCurrentRevision)
        guard let workspace = record.workspaceRelativePath,
              let port = Int(record.draft.portText) else {
            throw C02MCPSetupFailure(.invalidRequest,
                                     message: "The MCP service workspace or port is missing.",
                                     retryable: false)
        }
        return C02MCPSetupBinding(
            recordID: record.id,
            projectID: project.id,
            projectName: project.name,
            rootURL: project.rootURL,
            rootIdentity: record.rootIdentity,
            environmentID: record.environmentID,
            environmentLabel: record.environmentLabel,
            containerID: record.containerID,
            baseRevision: record.baseRevision,
            workspaceRelativePath: workspace,
            port: port)
    }

    private func submitStep(index: Int, record: inout C02MCPSetupRecord) async throws {
        guard index < record.steps.count,
              let workspace = record.workspaceRelativePath,
              let payload = C02MCPSetupBuildPlan.expectedPayload(
                recordID: record.id,
                step: record.steps[index].name,
                workspaceRelativePath: workspace) else {
            throw C02MCPSetupFailure(.invalidRequest,
                                     message: "The dependency step could not be prepared.",
                                     retryable: false)
        }
        let binding = try await resolveBinding(record)
        let handle = try await dependencies.commands.submit(
            recordID: record.id,
            step: record.steps[index],
            payload: payload,
            binding: binding)
        guard handle.recordID == record.id,
              handle.callID == record.steps[index].callID,
              handle.environmentID == record.environmentID,
              handle.rootIdentity == record.rootIdentity,
              handle.workspaceRootPath == binding.rootURL.standardizedFileURL
                .resolvingSymlinksInPath().path else {
            throw C02MCPSetupFailure(.jobOwnershipMismatch,
                                     message: "The dependency job did not bind this setup record.",
                                     retryable: false)
        }
        activeJobs[record.id] = handle
        record.steps[index].state = .running
        record.steps[index].jobID = handle.jobID
        record.phase = .building
        record.errorCode = nil
        record.errorMessage = nil
        try await saveRecord(&record)
    }

    private func markFailed(_ record: inout C02MCPSetupRecord,
                            code: C02MCPSetupFailure.Code, message: String) {
        record.phase = .failed
        record.errorCode = code.rawValue
        record.errorMessage = String(SecretRedactor.redact(message).prefix(512))
    }

    private func saveRecord(_ record: inout C02MCPSetupRecord) async throws {
        record.revision &+= 1
        record.updatedAt = Date()
        records[record.id] = record
        try await dependencies.records?.save(record)
    }

    private func saveRecord(_ record: C02MCPSetupRecord) async throws {
        var value = record
        try await saveRecord(&value)
    }

    private func checkLive(operation: String) throws {
        guard epoch > 0, dependencies.liveEpoch() == epoch else {
            throw C02MCPSetupFailure(.liveEpochChanged,
                                     message: "The native runtime generation changed.",
                                     retryable: true,
                                     operation: operation)
        }
    }

    private func isServiceBase(_ url: URL) -> Bool {
        isLoopback(url) && (url.path.isEmpty || url.path == "/")
    }

    private func isLoopback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return false }
        let host = url.host?.lowercased()
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private func isHexDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private func generationGoal(record: C02MCPSetupRecord,
                                project: C02MCPSetupProject) -> String {
        let relative = record.workspaceRelativePath ?? ""
        let details = String(record.draft.details.prefix(4_000))
        return """
        Create the requested MCP service in the existing project directory \(relative)/node-http.
        The reviewed TypeScript MCP SDK template is already there. Implement the user's requested tools only in src/tools.ts, using registerTaskTools(server) and additive server.registerTool registrations. Preserve its exported function signature. Do not modify any other file: src/server.ts, all tests (including discovery.mjs), package.json, package-lock.json, tsconfig.json, contract.json, README.md, .gitignore and floe-start.mjs must stay byte-identical. The fixed service_status tool and HTTP lifecycle remain App-owned. Do not install packages, build, start a server, change environments or create another task: Floe will perform those steps through the existing owned job/service lifecycle after code generation. Use normal workspace tools and the frozen task permissions; these instructions do not grant additional access. Summarize the implemented tools and any actual limitation in your final answer.

        User request (content, not permission):
        \(details)
        """
    }
}

// SPDX-License-Identifier: MPL-2.0
//
// C07 owned-data integrity and coverage closure.
//
// This file is deliberately dependency-free: it defines the typed omission /
// configuration / tool-result receipt wire used by the archive manifest and
// the pure reference-closure validator shared by the backup writer and the
// restore reader. It never reads the live database and never mutates storage.
//
// The integrity rules implemented here are the second half of the C07 data
// policy:
//
//   * every user-data reference carried in a package must resolve to a real
//     artifact record, a table row, or an explicit omission receipt;
//   * a duplicate package entry is accepted only when size and SHA-256 are
//     identical (legitimate de-duplication); different bytes are a collision;
//   * configuration sections are non-secret metadata only. A raw JSON key that
//     looks secret-bearing fails the whole package even if the typed decoder
//     would have ignored it;
//   * tool-result retention records are byte/digest verified here, before the
//     engine that owns the store is asked to re-capture them under new ids.
import Foundation
import Crypto

// MARK: - Completeness and omissions

public enum C07DataCompleteness: String, Codable, Sendable, Equatable {
    case complete
    case partial
}

/// One exact, bounded declaration of user data that could not be carried.
/// It is never a generic warning: the scope names the category, the subject
/// names the owning identity/path, and the reason is a stable machine code.
public struct C07DataOmission: Codable, Sendable, Equatable {
    public var scope: String
    public var subject: String
    public var reason: String
    public var byteCount: Int64?
    public var sha256: String?

    public init(scope: String, subject: String, reason: String,
                byteCount: Int64? = nil, sha256: String? = nil) {
        self.scope = scope
        self.subject = subject
        self.reason = reason
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    public static let maximumScopeBytes = 64
    public static let maximumSubjectBytes = 1_024
    public static let maximumReasonBytes = 96

    public func validate() throws {
        guard !scope.isEmpty, scope.utf8.count <= Self.maximumScopeBytes,
              scope.unicodeScalars.allSatisfy({
                  $0.value < 128 && !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw C07DataExchangeError.invalidManifest("omissionScope")
        }
        guard !subject.isEmpty, subject.utf8.count <= Self.maximumSubjectBytes,
              !subject.hasPrefix("/"),
              subject.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw C07DataExchangeError.invalidManifest("omissionSubject")
        }
        guard !reason.isEmpty, reason.utf8.count <= Self.maximumReasonBytes,
              reason.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && $0.value < 0x7F
              }) else {
            throw C07DataExchangeError.invalidManifest("omissionReason")
        }
        if let byteCount {
            guard byteCount >= 0,
                  byteCount <= C07OwnedDataLimits.maximumArtifactBytes else {
                throw C07DataExchangeError.invalidManifest("omissionBytes")
            }
        }
        if let sha256 {
            guard C07SHA256Hex.isSHA256(sha256) else {
                throw C07DataExchangeError.invalidManifest("omissionDigest")
            }
        }
    }
}

// MARK: - Tool-result retention section

/// Archive-level metadata for `data/tool-results.jsonl`. The JSONL body is
/// produced by `ToolResultBackupExchange`; this type owns only the bounded
/// count/size/digest contract the archive can verify without the result
/// engine.
public struct C07OwnedToolResultSection: Codable, Sendable, Equatable {
    public var entry: String
    public var count: Int
    public var byteCount: Int64
    public var sha256: String
    /// Calls that never had a retained capture (legacy runs). Informational,
    /// never an omission: there were no bytes to carry.
    public var excludedLegacyCalls: Int?
    /// Results that existed only in RAM (temporary chat or no durable root)
    /// and therefore cannot be carried. Informational and explicit.
    public var excludedNonDurable: Int?
    /// A durable record that could not be decoded/verified. A nonzero value
    /// makes the backup partial through the omission list.
    public var excludedUnreadable: Int?

    public init(entry: String = C07OwnedDataPolicy.toolResultsEntry,
                count: Int, byteCount: Int64, sha256: String,
                excludedLegacyCalls: Int? = nil,
                excludedNonDurable: Int? = nil,
                excludedUnreadable: Int? = nil) {
        self.entry = entry
        self.count = count
        self.byteCount = byteCount
        self.sha256 = sha256
        self.excludedLegacyCalls = excludedLegacyCalls
        self.excludedNonDurable = excludedNonDurable
        self.excludedUnreadable = excludedUnreadable
    }

    public func validate() throws {
        guard entry == C07OwnedDataPolicy.toolResultsEntry,
              count >= 0, count <= C07OwnedDataLimits.maximumToolResults,
              byteCount >= 0,
              byteCount <= C07OwnedDataLimits.maximumToolResultTotalBytes,
              C07SHA256Hex.isSHA256(sha256) else {
            throw C07DataExchangeError.invalidManifest("toolResultSection")
        }
        for value in [excludedLegacyCalls, excludedNonDurable, excludedUnreadable] {
            if let value, value < 0 || value > C07OwnedDataLimits.maximumToolResults {
                throw C07DataExchangeError.invalidManifest("toolResultExcluded")
            }
        }
    }
}

/// Exact key set of one tool-result backup record. The producer and this
/// validator must agree; an extra key is rejected rather than silently
/// carried (it could reintroduce a secret-bearing field).
public enum C07ToolResultBackupKey {
    public static let allowed: Set<String> = [
        "taskID", "runID", "callID", "toolName", "status", "textBase64",
        "byteCount", "sha256", "originalDigest",
        "executionReportedTruncation", "retentionTruncated", "capturedAt",
    ]
    public static let required: Set<String> = [
        "taskID", "runID", "callID", "toolName", "status", "textBase64",
        "byteCount", "sha256",
        "executionReportedTruncation", "retentionTruncated", "capturedAt",
    ]
}

// MARK: - Non-secret configuration sections

public enum C07OwnedConfigKind: String, Codable, Sendable, CaseIterable {
    /// Non-secret SSH/SFTP/VNC host metadata. Credentials, jump-chain
    /// payloads and known-host trust are excluded.
    case remoteHosts
    /// RDP endpoint metadata keyed by the ORIGINAL RemoteHostProfile UUID.
    /// Password references and approved fingerprints are excluded.
    case rdpEndpoints
    /// Non-secret mail account addressing/server metadata. Credential
    /// account references are excluded and no live account is created.
    case mailAccounts

    public var entry: String { "data/config/\(rawValue).json" }
    public var format: String { "floe.config.\(rawValue)" }
    public var formatVersion: Int { 1 }
}

public struct C07OwnedConfigSection: Codable, Sendable, Equatable {
    public var kind: C07OwnedConfigKind
    public var entry: String
    public var count: Int
    public var byteCount: Int64
    public var sha256: String
    /// Restored metadata is never live authorization: the user must enter a
    /// credential again.
    public var requiresReauthentication: Bool
    /// Certificates/host keys are not carried; a fresh trust decision is
    /// required for any later connection.
    public var requiresFreshTrust: Bool

    public init(kind: C07OwnedConfigKind, entry: String? = nil,
                count: Int, byteCount: Int64, sha256: String,
                requiresReauthentication: Bool = true,
                requiresFreshTrust: Bool = true) {
        self.kind = kind
        self.entry = entry ?? kind.entry
        self.count = count
        self.byteCount = byteCount
        self.sha256 = sha256
        self.requiresReauthentication = requiresReauthentication
        self.requiresFreshTrust = requiresFreshTrust
    }

    public func validate() throws {
        guard entry == kind.entry,
              count >= 0, count <= C07OwnedDataLimits.maximumConfigEntries,
              byteCount >= 0,
              byteCount <= C07OwnedDataLimits.maximumConfigBytes,
              C07SHA256Hex.isSHA256(sha256) else {
            throw C07DataExchangeError.invalidManifest("configSection")
        }
    }
}

/// Safe remote-host metadata. No `auth_json`, jump-chain body, VNC endpoint
/// body, known-host key/fingerprint or bookmark is ever represented here.
public struct C07RemoteHostConfig: Codable, Sendable, Equatable {
    public var id: UUID
    public var displayName: String
    public var address: String
    public var port: Int
    public var user: String
    public var deviceKind: String
    public var isRemoteExecutionEnvironment: Bool
    public var jumpHostCount: Int
    public var vncEndpointCount: Int
    public var auxiliaryConnectionCount: Int
    public var hostKeyPolicy: String
    public var allowsLegacyAlgorithms: Bool

    public init(id: UUID, displayName: String, address: String, port: Int,
                user: String, deviceKind: String,
                isRemoteExecutionEnvironment: Bool, jumpHostCount: Int,
                vncEndpointCount: Int, auxiliaryConnectionCount: Int,
                hostKeyPolicy: String, allowsLegacyAlgorithms: Bool) {
        self.id = id
        self.displayName = displayName
        self.address = address
        self.port = port
        self.user = user
        self.deviceKind = deviceKind
        self.isRemoteExecutionEnvironment = isRemoteExecutionEnvironment
        self.jumpHostCount = jumpHostCount
        self.vncEndpointCount = vncEndpointCount
        self.auxiliaryConnectionCount = auxiliaryConnectionCount
        self.hostKeyPolicy = hostKeyPolicy
        self.allowsLegacyAlgorithms = allowsLegacyAlgorithms
    }

    public static let maximumNameBytes = 512
    public static let maximumAddressBytes = 1_024
    public static let maximumUserBytes = 512
}

public struct C07RemoteHostConfigDocument: Codable, Sendable, Equatable {
    public var format: String
    public var formatVersion: Int
    public var hosts: [C07RemoteHostConfig]

    public init(hosts: [C07RemoteHostConfig],
                format: String = C07OwnedConfigKind.remoteHosts.format,
                formatVersion: Int = C07OwnedConfigKind.remoteHosts.formatVersion) {
        self.format = format
        self.formatVersion = formatVersion
        self.hosts = hosts
    }

    public func validate() throws {
        guard format == C07OwnedConfigKind.remoteHosts.format,
              formatVersion == C07OwnedConfigKind.remoteHosts.formatVersion,
              hosts.count <= C07OwnedDataLimits.maximumConfigEntries else {
            throw C07DataExchangeError.invalidManifest("remoteHostConfig")
        }
        var ids = Set<UUID>()
        for host in hosts {
            guard ids.insert(host.id).inserted,
                  !host.displayName.isEmpty,
                  host.displayName.utf8.count <= C07RemoteHostConfig.maximumNameBytes,
                  !host.address.isEmpty,
                  host.address.utf8.count <= C07RemoteHostConfig.maximumAddressBytes,
                  (1...65_535).contains(host.port),
                  host.user.utf8.count <= C07RemoteHostConfig.maximumUserBytes,
                  host.deviceKind.utf8.count <= 64,
                  (0...64).contains(host.jumpHostCount),
                  (0...64).contains(host.vncEndpointCount),
                  (0...64).contains(host.auxiliaryConnectionCount),
                  ["trustOnFirstUse", "strict", "ask"].contains(host.hostKeyPolicy) else {
                throw C07DataExchangeError.invalidManifest("remoteHostEntry")
            }
        }
    }
}

/// Safe RDP endpoint metadata keyed by the original profile UUID inside a
/// backup. `hasLogin` is a boolean fact, never a credential reference.
public struct C07RDPEndpointConfig: Codable, Sendable, Equatable {
    public var profileID: UUID
    public var id: UUID
    public var displayName: String
    public var host: String
    public var port: Int
    public var username: String
    public var domain: String
    public var hasLogin: Bool

    public init(profileID: UUID, id: UUID, displayName: String, host: String,
                port: Int, username: String, domain: String,
                hasLogin: Bool) {
        self.profileID = profileID
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.hasLogin = hasLogin
    }
}

public struct C07RDPConfigDocument: Codable, Sendable, Equatable {
    public var format: String
    public var formatVersion: Int
    public var endpoints: [C07RDPEndpointConfig]

    public init(endpoints: [C07RDPEndpointConfig],
                format: String = C07OwnedConfigKind.rdpEndpoints.format,
                formatVersion: Int = C07OwnedConfigKind.rdpEndpoints.formatVersion) {
        self.format = format
        self.formatVersion = formatVersion
        self.endpoints = endpoints
    }

    public func validate() throws {
        guard format == C07OwnedConfigKind.rdpEndpoints.format,
              formatVersion == C07OwnedConfigKind.rdpEndpoints.formatVersion,
              endpoints.count <= C07OwnedDataLimits.maximumConfigEntries else {
            throw C07DataExchangeError.invalidManifest("rdpConfig")
        }
        var endpointIDs = Set<UUID>()
        for endpoint in endpoints {
            guard endpointIDs.insert(endpoint.id).inserted,
                  !endpoint.displayName.isEmpty,
                  endpoint.displayName.utf8.count <= 512,
                  !endpoint.host.isEmpty,
                  endpoint.host.utf8.count <= 1_024,
                  (1...65_535).contains(endpoint.port),
                  endpoint.username.utf8.count <= 512,
                  endpoint.domain.utf8.count <= 256 else {
                throw C07DataExchangeError.invalidManifest("rdpEndpointEntry")
            }
        }
    }
}

/// Safe mail account metadata. No credential reference is represented; a
/// restore creates no live account.
public struct C07MailAccountConfig: Codable, Sendable, Equatable {
    public var id: UUID
    public var address: String
    public var displayName: String
    public var incomingProtocol: String
    public var incomingHost: String
    public var incomingPort: Int
    public var incomingTLS: String
    public var incomingUsername: String
    public var outgoingHost: String
    public var outgoingPort: Int
    public var outgoingTLS: String
    public var outgoingUsername: String

    public init(id: UUID, address: String, displayName: String,
                incomingProtocol: String, incomingHost: String,
                incomingPort: Int, incomingTLS: String,
                incomingUsername: String, outgoingHost: String,
                outgoingPort: Int, outgoingTLS: String,
                outgoingUsername: String) {
        self.id = id
        self.address = address
        self.displayName = displayName
        self.incomingProtocol = incomingProtocol
        self.incomingHost = incomingHost
        self.incomingPort = incomingPort
        self.incomingTLS = incomingTLS
        self.incomingUsername = incomingUsername
        self.outgoingHost = outgoingHost
        self.outgoingPort = outgoingPort
        self.outgoingTLS = outgoingTLS
        self.outgoingUsername = outgoingUsername
    }
}

public struct C07MailAccountConfigDocument: Codable, Sendable, Equatable {
    public var format: String
    public var formatVersion: Int
    public var accounts: [C07MailAccountConfig]

    public init(accounts: [C07MailAccountConfig],
                format: String = C07OwnedConfigKind.mailAccounts.format,
                formatVersion: Int = C07OwnedConfigKind.mailAccounts.formatVersion) {
        self.format = format
        self.formatVersion = formatVersion
        self.accounts = accounts
    }

    public func validate() throws {
        guard format == C07OwnedConfigKind.mailAccounts.format,
              formatVersion == C07OwnedConfigKind.mailAccounts.formatVersion,
              accounts.count <= C07OwnedDataLimits.maximumConfigEntries else {
            throw C07DataExchangeError.invalidManifest("mailConfig")
        }
        var ids = Set<UUID>()
        for account in accounts {
            guard ids.insert(account.id).inserted,
                  !account.address.isEmpty,
                  account.address.utf8.count <= 1_024,
                  account.displayName.utf8.count <= 512,
                  !account.incomingProtocol.isEmpty,
                  account.incomingProtocol.utf8.count <= 32,
                  !account.incomingHost.isEmpty,
                  account.incomingHost.utf8.count <= 1_024,
                  (1...65_535).contains(account.incomingPort),
                  account.incomingTLS.utf8.count <= 32,
                  account.incomingUsername.utf8.count <= 512,
                  !account.outgoingHost.isEmpty,
                  account.outgoingHost.utf8.count <= 1_024,
                  (1...65_535).contains(account.outgoingPort),
                  account.outgoingTLS.utf8.count <= 32,
                  account.outgoingUsername.utf8.count <= 512 else {
                throw C07DataExchangeError.invalidManifest("mailAccountEntry")
            }
        }
    }
}

// MARK: - Raw configuration safety

public enum C07ConfigSafety {
    private static let forbiddenFragments = [
        "auth", "password", "secret", "credential", "token", "cookie",
        "session", "fingerprint", "knownhost", "known_host", "privatekey",
        "private_key", "apikey", "api_key", "bearer", "jumpchain",
        "jump_chain", "vncendpoints", "vnc_endpoints", "auxiliaryconnections",
        "auxiliary_connections",
    ]

    /// Rejects a document that carries a secret-bearing key anywhere in its
    /// object graph. Applied to the RAW archived JSON, so a field the typed
    /// decoder ignores can never slip through a restore.
    public static func containsForbiddenKey(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return true
        }
        return containsForbiddenKey(object, depth: 0)
    }

    private static func containsForbiddenKey(_ value: Any, depth: Int) -> Bool {
        guard depth <= 32 else { return true }
        if let object = value as? [String: Any] {
            for (key, item) in object {
                let lower = key.lowercased()
                if forbiddenFragments.contains(where: { lower.contains($0) }) {
                    return true
                }
                if containsForbiddenKey(item, depth: depth + 1) { return true }
            }
            return false
        }
        if let array = value as? [Any] {
            return array.contains { containsForbiddenKey($0, depth: depth + 1) }
        }
        if let string = value as? String {
            let lower = string.lowercased()
            if lower.contains("-----begin ") && lower.contains("private key") {
                return true
            }
        }
        return false
    }
}

// MARK: - Reference closure

public struct C07ClosureTable: Sendable {
    public var name: String
    public var url: URL
    public var rowCount: Int

    public init(name: String, url: URL, rowCount: Int) {
        self.name = name
        self.url = url
        self.rowCount = rowCount
    }
}

public struct C07ClosureArtifact: Sendable {
    public var record: C07ArtifactRecord
    public var url: URL

    public init(record: C07ArtifactRecord, url: URL) {
        self.record = record
        self.url = url
    }
}

public struct C07ClosureToolResults: Sendable {
    public var url: URL
    public var section: C07OwnedToolResultSection

    public init(url: URL, section: C07OwnedToolResultSection) {
        self.url = url
        self.section = section
    }
}

public struct C07ClosureConfig: Sendable {
    public var section: C07OwnedConfigSection
    public var url: URL

    public init(section: C07OwnedConfigSection, url: URL) {
        self.section = section
        self.url = url
    }
}

public struct C07OwnedDataClosureReport: Sendable, Equatable {
    public var conversations: Int
    public var runs: Int
    public var toolCalls: Int
    public var attachments: Int
    public var canvases: Int
    public var artifacts: Int
    public var deduplicatedArtifacts: Int
    public var toolResults: Int
    public var configSections: Int
    public var omissions: Int
    public var completeness: C07DataCompleteness

    public init(conversations: Int = 0, runs: Int = 0, toolCalls: Int = 0,
                attachments: Int = 0, canvases: Int = 0, artifacts: Int = 0,
                deduplicatedArtifacts: Int = 0, toolResults: Int = 0,
                configSections: Int = 0, omissions: Int = 0,
                completeness: C07DataCompleteness = .complete) {
        self.conversations = conversations
        self.runs = runs
        self.toolCalls = toolCalls
        self.attachments = attachments
        self.canvases = canvases
        self.artifacts = artifacts
        self.deduplicatedArtifacts = deduplicatedArtifacts
        self.toolResults = toolResults
        self.configSections = configSections
        self.omissions = omissions
        self.completeness = completeness
    }
}

public enum C07OwnedDataClosure {
    /// Validates that every carried reference resolves inside THIS package or
    /// is declared by an exact omission. Called by the backup builder after
    /// every byte is staged and by the restore reader after extraction.
    @discardableResult
    public static func validate(
        tables: [C07ClosureTable],
        artifacts: [C07ClosureArtifact],
        toolResults: C07ClosureToolResults?,
        configs: [C07ClosureConfig],
        omissions: [C07DataOmission]
    ) throws -> C07OwnedDataClosureReport {
        var report = C07OwnedDataClosureReport()
        var omissionKeys = Set<String>()
        for omission in omissions {
            try omission.validate()
            let key = "\(omission.scope)|\(omission.subject)"
            guard omissionKeys.insert(key).inserted else {
                throw C07DataExchangeError.invalidManifest("omissionDuplicate")
            }
        }
        report.omissions = omissions.count
        report.completeness = omissions.isEmpty ? .complete : .partial

        var tableNames = Set<String>()
        var conversations = Set<String>()
        var runs: [String: String] = [:]          // runID -> conversationID
        var childRuns: [String: String] = [:]     // childRunID -> conversationID
        var toolCalls: [String: String] = [:]     // callID -> runID
        var eventCalls = Set<String>()            // runID|callID from run_events
        var attachments: [String: C07DBRow] = [:]
        for table in tables {
            guard tableNames.insert(table.name).inserted else {
                throw C07DataExchangeError.invalidManifest(
                    "duplicateTable:\(table.name)")
            }
            var counted = 0
            try C07RowStream.rows(in: table.url, table: table.name) { row in
                counted += 1
                switch table.name {
                case "conversations":
                    if let id = row["id"]?.stringValue { conversations.insert(id) }
                case "runs":
                    if let id = row["id"]?.stringValue,
                       let conversation = row["conversation_id"]?.stringValue {
                        runs[id] = conversation
                    }
                case "tool_calls":
                    if let id = row["id"]?.stringValue,
                       let runID = row["run_id"]?.stringValue {
                        toolCalls[id] = runID
                    }
                case "child_runs":
                    if let id = row["id"]?.stringValue,
                       let conversation = row["conversation_id"]?.stringValue {
                        childRuns[id] = conversation
                    }
                case "run_events":
                    // A settled toolResult event is a durable call reference
                    // even on a build that never wrote a tool_calls row.
                    if row["kind"]?.stringValue == "toolResult",
                       let runID = row["run_id"]?.stringValue,
                       let payload = row["payload_json"]?.stringValue,
                       let data = payload.data(using: .utf8),
                       let object = (try? JSONSerialization.jsonObject(
                        with: data)) as? [String: Any],
                       let callID = (object["id"] as? String)
                        ?? (object["callID"] as? String),
                       !callID.isEmpty, callID.count <= 200 {
                        eventCalls.insert("\(runID)|\(callID)")
                    }
                case "attachments":
                    if let id = row["id"]?.stringValue { attachments[id] = row }
                default:
                    break
                }
            }
            guard counted == table.rowCount else {
                throw C07DataExchangeError.invalidManifest(
                    "closureRowCount:\(table.name)")
            }
        }
        report.conversations = conversations.count
        report.runs = runs.count
        report.toolCalls = toolCalls.count
        report.attachments = attachments.count

        // Artifact entries must be unique by exact package path. A duplicate
        // is only accepted when the bytes are identical.
        var entries: [String: (sha256: String, byteCount: Int64)] = [:]
        var canvasChildren: [String: Set<String>] = [:]
        var canvasMaterials: [String: Set<String>] = [:]
        var canvasNodePaths: [String: Set<String>] = [:]
        var canvasIDs = Set<String>()
        var mediaProjectIDs = Set<String>()
        var mediaCanvasByOwner: [String: String] = [:]
        var mediaAssetsByOwner: [String: Set<String>] = [:]
        var carriedMaterials = Set<String>()
        var carriedAssets = Set<String>()
        var carriedNodeAssets = Set<String>()

        for artifact in artifacts {
            let record = artifact.record
            let key = C07Path.collisionKey(record.entry)
            if let existing = entries[key] {
                guard existing.sha256 == record.sha256,
                      existing.byteCount == record.byteCount else {
                    throw C07DataExchangeError.artifactCollision(record.entry)
                }
                report.deduplicatedArtifacts += 1
                continue
            }
            entries[key] = (record.sha256, record.byteCount)
            switch record.role {
            case .canvasProject:
                guard let canvasID = record.ownerID,
                      record.containerID == canvasID else {
                    throw C07DataExchangeError.invalidManifest("canvasOwner")
                }
                let data: Data
                do { data = try Data(contentsOf: artifact.url) }
                catch { throw C07DataExchangeError.storageUnavailable("canvasRead") }
                let references = try C07CanvasGraph.scan(canvasData: data)
                guard references.canvasID == canvasID else {
                    throw C07DataExchangeError.invalidManifest("canvasIdentity")
                }
                canvasIDs.insert(canvasID.uuidString)
                canvasChildren[canvasID.uuidString] = Set(
                    references.childProjectIDs.map(\.uuidString))
                canvasMaterials[canvasID.uuidString] = Set(
                    references.materialNames)
                canvasNodePaths[canvasID.uuidString] = Set(
                    references.nodeAssetPaths)
            case .canvasMediaProject:
                guard let owner = record.ownerID,
                      record.containerID != nil else {
                    throw C07DataExchangeError.invalidManifest("mediaOwner")
                }
                let data: Data
                do { data = try Data(contentsOf: artifact.url) }
                catch { throw C07DataExchangeError.storageUnavailable("mediaRead") }
                let media = try C07CanvasGraph.scanMediaProject(data: data)
                guard media.projectID == owner else {
                    throw C07DataExchangeError.invalidManifest("mediaIdentity")
                }
                mediaProjectIDs.insert(owner.uuidString)
                if let canvas = record.containerID?.uuidString {
                    mediaCanvasByOwner[owner.uuidString] = canvas
                }
                mediaAssetsByOwner[owner.uuidString] = Set(media.assetPaths)
            default:
                break
            }
        }
        report.canvases = canvasIDs.count

        // A canvas child must be carried, or declared. Media projects that no
        // canvas references are still validated for self-identity above.
        for (canvasID, children) in canvasChildren {
            for child in children {
                let carried = mediaProjectIDs.contains(child)
                if !carried {
                    try requireOmission(
                        omissions: omissionKeys,
                        scope: "canvasChildProject",
                        subject: "\(canvasID)/\(child)")
                }
            }
        }

        for artifact in artifacts {
            let record = artifact.record
            switch record.role {
            case .canvasProject, .canvasMediaProject:
                break
            case .canvasMaterial:
                guard let canvasID = record.containerID?.uuidString,
                      canvasIDs.contains(canvasID) else {
                    throw C07DataExchangeError.referenceMissing("canvasMaterialOwner")
                }
                if canvasMaterials[canvasID]?.contains(record.logicalPath) != true {
                    throw C07DataExchangeError.referenceMissing("canvasMaterial")
                }
                carriedMaterials.insert("\(canvasID)|\(record.logicalPath)")
            case .canvasAsset:
                guard let canvasID = record.containerID?.uuidString,
                      canvasIDs.contains(canvasID),
                      let owner = record.ownerID?.uuidString else {
                    throw C07DataExchangeError.referenceMissing("canvasAssetOwner")
                }
                let isChild = canvasChildren[canvasID]?.contains(owner) == true
                    || owner == canvasID
                guard isChild, mediaProjectIDs.contains(owner) else {
                    throw C07DataExchangeError.referenceMissing("canvasAssetChild")
                }
                carriedAssets.insert("\(owner)|\(record.logicalPath)")
            case .canvasNodeAsset:
                guard let canvasID = record.containerID?.uuidString,
                      canvasIDs.contains(canvasID) else {
                    throw C07DataExchangeError.referenceMissing("canvasNodeOwner")
                }
                if canvasNodePaths[canvasID]?.contains(record.logicalPath) != true {
                    throw C07DataExchangeError.referenceMissing("canvasNodeAsset")
                }
                carriedNodeAssets.insert("\(canvasID)|\(record.logicalPath)")
            case .attachment:
                guard let id = record.ownerID?.uuidString,
                      attachments[id] != nil else {
                    throw C07DataExchangeError.referenceMissing("attachmentOwner")
                }
            case .privateTaskFile:
                guard let id = record.ownerID?.uuidString,
                      conversations.contains(id) else {
                    throw C07DataExchangeError.referenceMissing("privateTaskOwner")
                }
            case .environmentCheckpoint, .mailReceipt, .appArtifact,
                 .captureFile, .configuration:
                break
            case .canvasCADDraft, .canvasCADRevision, .canvasNativeCAD:
                guard let canvasID = record.containerID?.uuidString,
                      canvasIDs.contains(canvasID) else {
                    throw C07DataExchangeError.referenceMissing("canvasCADOwner")
                }
            }
        }
        report.artifacts = entries.count

        // Reverse closure: every reference named by a carried canvas/media
        // document must be present or declared. This is the half that stops a
        // "successful" backup from silently missing a referenced resource.
        for (canvasID, names) in canvasMaterials {
            for name in names {
                let key = "\(canvasID)|\(name)"
                if !carriedMaterials.contains(key) {
                    try requireOmission(
                        omissions: omissionKeys, scope: "canvasMaterial",
                        subject: "\(canvasID)/\(name)")
                }
            }
        }
        for (owner, paths) in mediaAssetsByOwner {
            let canvasID = mediaCanvasByOwner[owner] ?? owner
            for path in paths {
                let key = "\(owner)|\(path)"
                if !carriedAssets.contains(key) {
                    try requireOmission(
                        omissions: omissionKeys, scope: "canvasAsset",
                        subject: "\(canvasID)/\(owner)/\(path)")
                }
            }
        }
        for (canvasID, paths) in canvasNodePaths {
            for path in paths {
                let key = "\(canvasID)|\(path)"
                if !carriedNodeAssets.contains(key) {
                    try requireOmission(
                        omissions: omissionKeys, scope: "canvasNodeAsset",
                        subject: "\(canvasID)/\(path)")
                }
            }
        }

        // Every attachment row that claims app-owned bytes must resolve or be
        // declared. A row without a path has nothing to carry and is also
        // declared (never silently rewritten as "restorable").
        var carriedAttachmentOwners = Set<String>()
        for artifact in artifacts where artifact.record.role == .attachment {
            if let owner = artifact.record.ownerID?.uuidString {
                carriedAttachmentOwners.insert(owner)
            }
        }
        for (id, row) in attachments {
            guard row["storage"]?.stringValue == "applicationSupport" else {
                continue
            }
            let relative = row["relative_path"]?.stringValue ?? ""
            let carried = carriedAttachmentOwners.contains(id)
            if !carried {
                if relative.isEmpty {
                    // The row itself is already incomplete; there is no
                    // path whose bytes could be named.
                    try requireOmission(
                        omissions: omissionKeys,
                        scope: "attachmentPath",
                        subject: id)
                } else {
                    try requireOmission(
                        omissions: omissionKeys,
                        scope: "attachmentBytes",
                        subject: id)
                }
            }
        }

        if let toolResults {
            try validateToolResults(
                toolResults, conversations: conversations, runs: runs,
                childRuns: childRuns, toolCalls: toolCalls,
                eventCalls: eventCalls)
            report.toolResults = toolResults.section.count
        }

        try validateConfigs(configs, report: &report)
        return report
    }

    private static func requireOmission(omissions: Set<String>, scope: String,
                                        subject: String) throws {
        guard omissions.contains("\(scope)|\(subject)") else {
            throw C07DataExchangeError.referenceMissing("\(scope):\(subject)")
        }
    }

    private static func validateToolResults(
        _ input: C07ClosureToolResults,
        conversations: Set<String>,
        runs: [String: String],
        childRuns: [String: String],
        toolCalls: [String: String],
        eventCalls: Set<String>
    ) throws {
        let section = input.section
        try section.validate()
        let digest = try C07Digest.file(
            input.url, maximum: C07OwnedDataLimits.maximumToolResultTotalBytes)
        guard digest.byteCount == section.byteCount,
              digest.sha256 == section.sha256 else {
            throw C07DataExchangeError.hashMismatch(section.entry)
        }
        var count = 0
        var totalBytes: Int64 = 0
        var identities = Set<String>()
        try C07PlainJSONLines.read(
            input.url, label: "toolResults",
            maximumRows: C07OwnedDataLimits.maximumToolResults,
            maximumRowBytes: C07OwnedDataLimits.maximumToolResultRowBytes
        ) { object in
            count += 1
            try validateToolResultObject(
                object, conversations: conversations, runs: runs,
                childRuns: childRuns, toolCalls: toolCalls,
                eventCalls: eventCalls, identities: &identities)
            totalBytes += Int64(C07PlainJSONLines.integer(object["byteCount"]) ?? -1)
        }
        guard count == section.count else {
            throw C07DataExchangeError.invalidManifest("toolResultCount")
        }
        // `section.byteCount` is the ARCHIVE ENTRY size (already verified by
        // the file digest above); the sum of captured text bytes is a
        // different quantity and is bounded independently.
        guard totalBytes >= 0,
              totalBytes <= C07OwnedDataLimits.maximumToolResultTotalBytes else {
            throw C07DataExchangeError.invalidManifest("toolResultBytes")
        }
    }

    private static func validateToolResultObject(
        _ object: [String: Any],
        conversations: Set<String>,
        runs: [String: String],
        childRuns: [String: String],
        toolCalls: [String: String],
        eventCalls: Set<String>,
        identities: inout Set<String>
    ) throws {
        let keys = Set(object.keys)
        guard C07ToolResultBackupKey.required.isSubset(of: keys),
              keys.isSubset(of: C07ToolResultBackupKey.allowed) else {
            throw C07DataExchangeError.invalidManifest("toolResultKeys")
        }
        guard let taskID = object["taskID"] as? String,
              conversations.contains(taskID),
              let runID = object["runID"] as? String,
              let callID = object["callID"] as? String,
              !callID.isEmpty,
              callID.count <= 200,
              // Top-level results must name a real call row. A delegated
              // child run is a real runtime-issued run identity; its call id
              // lives in the child entry payload rather than tool_calls.
              (runs[runID] == taskID
                && (toolCalls[callID] == runID
                    || eventCalls.contains("\(runID)|\(callID)")))
                || (runs[runID] == nil && childRuns[runID] == taskID),
              let textBase64 = object["textBase64"] as? String,
              let byteCount = C07PlainJSONLines.integer(object["byteCount"]),
              byteCount >= 0,
              byteCount <= C07OwnedDataLimits.maximumToolResultBytes,
              let sha256 = object["sha256"] as? String,
              C07SHA256Hex.isSHA256(sha256),
              let capturedAt = object["capturedAt"] as? String,
              !capturedAt.isEmpty,
              capturedAt.utf8.count <= 64,
              C07PlainJSONLines.bool(object["executionReportedTruncation"]) != nil,
              C07PlainJSONLines.bool(object["retentionTruncated"]) != nil else {
            throw C07DataExchangeError.invalidManifest("toolResultIdentity")
        }
        if let original = object["originalDigest"] as? String, !original.isEmpty {
            guard C07SHA256Hex.isSHA256(original) else {
                throw C07DataExchangeError.invalidManifest("toolResultOriginal")
            }
        } else if let original = object["originalDigest"], !(original is NSNull) {
            throw C07DataExchangeError.invalidManifest("toolResultOriginal")
        }
        guard !identities.contains("\(runID)|\(callID)") else {
            throw C07DataExchangeError.duplicateIdentity("toolResult")
        }
        identities.insert("\(runID)|\(callID)")
        guard let data = Data(base64Encoded: textBase64, options: []),
              data.count == byteCount,
              C07Digest.sha256(data) == sha256 else {
            throw C07DataExchangeError.hashMismatch("toolResultText")
        }
        for key in ["toolName", "status"] {
            guard let text = object[key] as? String,
                  text.utf8.count <= 2_048 else {
                throw C07DataExchangeError.invalidManifest("toolResultMetadata")
            }
        }
    }

    private static func validateConfigs(_ configs: [C07ClosureConfig],
                                        report: inout C07OwnedDataClosureReport) throws {
        var kinds = Set<C07OwnedConfigKind>()
        var entries = Set<String>()
        var hostIDs = Set<UUID>()
        var rdpProfileIDs: [UUID] = []
        for config in configs {
            try config.section.validate()
            guard kinds.insert(config.section.kind).inserted,
                  entries.insert(config.section.entry).inserted else {
                throw C07DataExchangeError.duplicateEntry(config.section.entry)
            }
            let digest = try C07Digest.file(
                config.url, maximum: C07OwnedDataLimits.maximumConfigBytes)
            guard digest.byteCount == config.section.byteCount,
                  digest.sha256 == config.section.sha256 else {
                throw C07DataExchangeError.hashMismatch(config.section.entry)
            }
            let data: Data
            do { data = try Data(contentsOf: config.url) }
            catch { throw C07DataExchangeError.storageUnavailable("configRead") }
            guard !C07ConfigSafety.containsForbiddenKey(data) else {
                throw C07DataExchangeError.credentialExcluded(config.section.entry)
            }
            switch config.section.kind {
            case .remoteHosts:
                let document: C07RemoteHostConfigDocument
                do { document = try JSONDecoder().decode(
                    C07RemoteHostConfigDocument.self, from: data) }
                catch { throw C07DataExchangeError.invalidManifest("remoteHostDecode") }
                try document.validate()
                guard document.hosts.count == config.section.count else {
                    throw C07DataExchangeError.invalidManifest("remoteHostCount")
                }
                hostIDs = Set(document.hosts.map(\.id))
            case .rdpEndpoints:
                let document: C07RDPConfigDocument
                do { document = try JSONDecoder().decode(
                    C07RDPConfigDocument.self, from: data) }
                catch { throw C07DataExchangeError.invalidManifest("rdpDecode") }
                try document.validate()
                guard document.endpoints.count == config.section.count else {
                    throw C07DataExchangeError.invalidManifest("rdpCount")
                }
                rdpProfileIDs = document.endpoints.map(\.profileID)
            case .mailAccounts:
                let document: C07MailAccountConfigDocument
                do { document = try JSONDecoder().decode(
                    C07MailAccountConfigDocument.self, from: data) }
                catch { throw C07DataExchangeError.invalidManifest("mailDecode") }
                try document.validate()
                guard document.accounts.count == config.section.count else {
                    throw C07DataExchangeError.invalidManifest("mailCount")
                }
            }
        }
        report.configSections = configs.count
        if !rdpProfileIDs.isEmpty {
            guard !hostIDs.isEmpty else {
                throw C07DataExchangeError.referenceMissing("rdpHostProfiles")
            }
            for profile in rdpProfileIDs where !hostIDs.contains(profile) {
                throw C07DataExchangeError.referenceMissing(
                    "rdpProfile:\(profile.uuidString)")
            }
        }
    }
}

// MARK: - Plain JSON Lines

/// Bounded line-oriented JSON reader for the non-SQLite sections
/// (`data/tool-results.jsonl`, configuration replacements). Unlike
/// `C07RowStream`, values are ordinary JSON scalars, not typed SQLite values.
public enum C07PlainJSONLines {
    public static func read(
        _ url: URL,
        label: String,
        maximumRows: Int,
        maximumRowBytes: Int,
        _ body: ([String: Any]) throws -> Void
    ) throws {
        try readLines(url, label: label, maximumRows: maximumRows,
                      maximumRowBytes: maximumRowBytes) { line in
            try body(try decode(line, label: label,
                                maximumRowBytes: maximumRowBytes))
        }
    }

    /// Raw-line variant used when the caller owns the typed decoder (for
    /// example the tool-result exchange).
    public static func readLines(
        _ url: URL,
        label: String,
        maximumRows: Int,
        maximumRowBytes: Int,
        _ body: (Data) throws -> Void
    ) throws {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw C07DataExchangeError.storageUnavailable("\(label)Open") }
        defer { try? handle.close() }
        var buffer = Data()
        var count = 0
        let endOfLine = Data([0x0A])
        do {
            while let chunk = try handle.read(upToCount: C07OwnedDataLimits.copyChunkBytes),
                  !chunk.isEmpty {
                if Task.isCancelled { throw C07DataExchangeError.cancelled }
                buffer.append(chunk)
                while let index = buffer.range(of: endOfLine)?.lowerBound {
                    let line = buffer.subdata(in: buffer.startIndex..<index)
                    buffer.removeSubrange(buffer.startIndex...index)
                    guard !line.isEmpty else {
                        throw C07DataExchangeError.invalidManifest("\(label)EmptyLine")
                    }
                    count += 1
                    guard count <= maximumRows else {
                        throw C07DataExchangeError.tooManyEntries
                    }
                    try body(line)
                }
                guard buffer.count <= maximumRowBytes else {
                    throw C07DataExchangeError.entryTooLarge("\(label)Row")
                }
            }
            if !buffer.isEmpty {
                count += 1
                guard count <= maximumRows else {
                    throw C07DataExchangeError.tooManyEntries
                }
                try body(buffer)
            }
        } catch let error as C07DataExchangeError {
            throw error
        } catch {
            throw C07DataExchangeError.storageUnavailable("\(label)Read")
        }
    }

    public static func decode(_ line: Data, label: String,
                              maximumRowBytes: Int) throws -> [String: Any] {
        guard !line.isEmpty, line.count <= maximumRowBytes else {
            throw C07DataExchangeError.entryTooLarge("\(label)Row")
        }
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let dictionary = object as? [String: Any] else {
            throw C07DataExchangeError.invalidManifest("\(label)RowDecode")
        }
        return dictionary
    }

    public static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            guard double.isFinite, double == double.rounded() else { return nil }
            return number.intValue
        }
        if let text = value as? String, let parsed = Int(text) { return parsed }
        return nil
    }

    /// JSON booleans arrive as `Bool` or `NSNumber`. The typed tool-result
    /// codec performs the strict check; this helper only proves the field is
    /// present and boolean-like.
    public static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }
}

// MARK: - Tool-result receipt sanitisation / ref rewrite

/// Bounded, allow-listed projection of one `run_events` toolResult payload.
/// Action bodies and artifact/file links are intentionally absent; the
/// retained bytes live in the result store and are referenced by ref.
public enum C07ToolResultReceipt {
    public static let allowedKeys: Set<String> = [
        "tool", "id", "callID", "status", "summary", "outputSummary",
        "outputDigest", "durationMs", "dispatched", "queuedMs",
        "exitStatus", "captureRef",
        "captureSHA256", "captureBytes", "captureSource", "captureUnavailable",
        "captureInfo",
        // The export fallback marker for a non-object payload. Preserved so
        // the restored event is still an explicit redaction, not an empty row.
        "redacted", "kind",
    ]
    public static let maximumSummaryBytes = 65_536
    public static let maximumPayloadBytes = 96 * 1_024

    /// Returns a sorted-key JSON object containing only safe receipt fields,
    /// or nil when the payload is not an object or exceeds obvious bounds.
    public static func sanitize(_ text: String,
                                includeText: Bool = true) -> String? {
        guard text.utf8.count <= maximumPayloadBytes,
              let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else { return nil }
        var safe: [String: Any] = [:]
        for key in allowedKeys {
            if !includeText && (key == "summary" || key == "outputSummary") {
                continue
            }
            guard let value = object[key] else { continue }
            if key == "captureInfo" {
                guard let nested = value as? [String: Any],
                      let projected = captureInfoObject(
                        nested) else { return nil }
                safe[key] = projected
                continue
            }
            switch value {
            case let string as String:
                if key == "summary" || key == "outputSummary" {
                    guard string.utf8.count <= maximumSummaryBytes else {
                        safe[key] = String(decoding:
                            string.utf8.prefix(maximumSummaryBytes), as: UTF8.self)
                        continue
                    }
                }
                guard string.utf8.count <= maximumSummaryBytes else { return nil }
                if key == "id" || key == "tool" || key == "status" {
                    guard string.utf8.count <= 2_048 else { return nil }
                }
                safe[key] = string
            case let number as NSNumber:
                safe[key] = number
            case is NSNull:
                safe[key] = NSNull()
            default:
                // Nested objects/arrays are not part of the receipt contract.
                return nil
            }
        }
        guard !safe.isEmpty,
              let encoded = try? JSONSerialization.data(
                withJSONObject: safe, options: [.sortedKeys]),
              let string = String(data: encoded, encoding: .utf8),
              string.utf8.count <= maximumPayloadBytes else { return nil }
        return string
    }

    /// Projects a nested `ToolResultCaptureInfo` to its documented safe
    /// fields. Unknown keys are dropped, never carried into a live event.
    public static func captureInfoObject(_ nested: [String: Any]) -> [String: Any]? {
        let keys = ["ref", "originalBytes", "retainedBytes",
                    "retentionTruncated", "executionReportedTruncation",
                    "available"]
        var result: [String: Any] = [:]
        for key in keys {
            guard let value = nested[key] else { continue }
            switch key {
            case "ref":
                if value is NSNull { result[key] = NSNull() }
                else if let string = value as? String, string.utf8.count <= 64 {
                    result[key] = string
                } else { return nil }
            case "originalBytes", "retainedBytes":
                guard let number = value as? NSNumber,
                      number.intValue >= 0,
                      number.intValue <= C07OwnedDataLimits.maximumToolResultBytes
                else { return nil }
                result[key] = number
            case "retentionTruncated", "executionReportedTruncation", "available":
                guard let number = value as? NSNumber else { return nil }
                result[key] = number
            default:
                return nil
            }
        }
        return result
    }

    /// Replaces any stale capture ref with the restored one and records the
    /// new receipt fields. When no retained result was carried, a stale ref is
    /// replaced by `unavailable` instead of pointing at another task's bytes.
    public static func rewrite(
        _ text: String,
        oldRunID: String?,
        oldCallID: String?,
        entries: [C07ToolResultPlanEntry]
    ) throws -> String {
        guard let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              var object = raw as? [String: Any] else {
            throw C07DataExchangeError.invalidManifest("toolResultPayload")
        }
        let callID = oldCallID ?? (object["id"] as? String)
            ?? (object["callID"] as? String)
        let entry = entries.first {
            guard $0.oldCallID == callID else {
                // UUID spellings differ between stores; compare the canonical
                // UUID only when both sides actually parse as UUIDs.
                guard let old = UUID(uuidString: $0.oldCallID),
                      let current = callID.flatMap(UUID.init(uuidString:)),
                      old == current else { return false }
                guard let oldRunID else { return true }
                return $0.oldRunID.uuidString
                    .caseInsensitiveCompare(oldRunID) == .orderedSame
            }
            guard let oldRunID else { return true }
            return $0.oldRunID.uuidString
                .caseInsensitiveCompare(oldRunID) == .orderedSame
        }
        if let entry {
            if object["id"] != nil { object["id"] = entry.newCallID }
            if object["callID"] != nil { object["callID"] = entry.newCallID }
            object["captureRef"] = entry.newRef
            object["captureSHA256"] = entry.sha256
            object["captureBytes"] = entry.byteCount
            object["captureSource"] = "restored"
            object.removeValue(forKey: "captureUnavailable")
            var summary = (object["summary"] as? String) ?? ""
            summary = replaceRefs(in: summary, with: entry.newRef)
            if !summary.contains("ref=\(entry.newRef)") {
                let prefix = (entry.retentionTruncated ?? false)
                    ? "retained captured prefix" : "full post-redaction output"
                let note = "\n[\(prefix) ref=\(entry.newRef); bytes=\(entry.byteCount)]"
                summary += String(note.utf8.count <= 512
                    ? note : String(note.prefix(512)))
            }
            object["summary"] = summary
            if let legacy = object["outputSummary"] as? String {
                object["outputSummary"] = replaceRefs(
                    in: legacy, with: entry.newRef)
            }
            object["captureInfo"] = [
                "ref": entry.newRef,
                "originalBytes": entry.byteCount,
                "retainedBytes": entry.byteCount,
                "retentionTruncated": entry.retentionTruncated ?? false,
                "executionReportedTruncation":
                    entry.executionReportedTruncation ?? false,
                "available": true,
            ]
        } else {
            object["captureRef"] = NSNull()
            object["captureSource"] = "unavailable"
            object["captureUnavailable"] = true
            object["captureInfo"] = [
                "ref": NSNull(),
                "originalBytes": 0,
                "retainedBytes": 0,
                "retentionTruncated": false,
                "executionReportedTruncation": false,
                "available": false,
            ]
            var summary = (object["summary"] as? String) ?? ""
            summary = replaceRefs(in: summary, with: "unavailable")
            object["summary"] = summary
            if let legacy = object["outputSummary"] as? String {
                object["outputSummary"] = replaceRefs(
                    in: legacy, with: "unavailable")
            }
        }
        // These links carry old ids/paths and are never restored live.
        object.removeValue(forKey: "artifactRefsJSON")
        object.removeValue(forKey: "outputFilesJSON")
        // Second, independent allow-list gate: a hand-edited archive cannot
        // smuggle an extra secret-bearing field into a live run event.
        var safe: [String: Any] = [:]
        for key in allowedKeys {
            if let value = object[key] { safe[key] = value }
        }
        guard let encoded = try? JSONSerialization.data(
            withJSONObject: safe, options: [.sortedKeys]),
            let string = String(data: encoded, encoding: .utf8),
            string.utf8.count <= maximumPayloadBytes else {
            throw C07DataExchangeError.invalidManifest("toolResultPayload")
        }
        return string
    }

    /// Summary-only rewrite used by the tool_calls.output_summary column (a
    /// plain text field, not a JSON object). It never touches free-form
    /// message text; only structured result summaries call this.
    public static func rewriteSummary(
        _ summary: String,
        oldRunID: String?,
        oldCallID: String?,
        entries: [C07ToolResultPlanEntry]
    ) -> String {
        let entry = entries.first {
            guard let oldCallID, $0.oldCallID == oldCallID else { return false }
            guard let oldRunID else { return true }
            return $0.oldRunID.uuidString
                .caseInsensitiveCompare(oldRunID) == .orderedSame
        }
        guard let entry else {
            return replaceRefs(in: summary, with: "unavailable")
        }
        var result = replaceRefs(in: summary, with: entry.newRef)
        if !result.contains("ref=\(entry.newRef)") {
            let prefix = (entry.retentionTruncated ?? false)
                ? "retained captured prefix" : "full post-redaction output"
            let note = "\n[\(prefix) ref=\(entry.newRef); bytes=\(entry.byteCount)]"
            result += String(note.utf8.count <= 512 ? note : String(note.prefix(512)))
        }
        return result
    }

    private static let refPattern = "tr_[0-9a-f]{24}"

    public static func replaceRefs(in text: String, with newRef: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: refPattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: newRef)
    }
}

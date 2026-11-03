// SPDX-License-Identifier: MPL-2.0
//
// C07 MCP user-definition exchange.
//
// The archive carries a TYPED projection of the original
// `[MCPServerConfiguration]` rows, not the raw
// `floe.mcp.remoteServers.v1` JSON. Credentials, secret references, cleanup
// keys, live sessions/tool grants and every project/environment/root/task
// fingerprint are absent. Restore merges fresh disabled, unbound definitions
// into the ORIGINAL settings row; it never starts a process, connects a
// server or replays a model/tool grant.

import Foundation
import FloeCore
import FloeTools
import FloeAndroidDataExchange

public struct C07MCPExportSkip: Sendable, Equatable {
    public var sourceID: String
    public var reason: String

    public init(sourceID: String, reason: String) {
        self.sourceID = sourceID
        self.reason = reason
    }
}

public struct C07MCPExportResult: Sendable, Equatable {
    public var document: C07MCPConfigDocument
    public var skipped: [C07MCPExportSkip]
    public var sanitizedNames: [String]

    public init(document: C07MCPConfigDocument,
                skipped: [C07MCPExportSkip] = [],
                sanitizedNames: [String] = []) {
        self.document = document
        self.skipped = skipped
        self.sanitizedNames = sanitizedNames
    }
}

public enum C07MCPConfigurationExchange {
    /// The ONE original MCP configuration row. No second store is introduced.
    public static var settingsKey: String { MCPDomain.serversSettingsKey }

    // MARK: Export

    /// Parses the saved array one row at a time so one malformed row cannot
    /// hide the other user definitions. Every exported row is re-validated
    /// against the typed exchange document before it can enter the archive.
    public static func export(raw: String) throws -> C07MCPExportResult {
        guard let data = raw.data(using: .utf8),
              data.count <= C07OwnedDataLimits.maximumConfigBytes else {
            throw C07DataExchangeError.invalidManifest("mcpStoreDecode")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let rows = object as? [Any] else {
            throw C07DataExchangeError.invalidManifest("mcpStoreDecode")
        }
        guard rows.count <= C07OwnedDataLimits.maximumConfigEntries else {
            throw C07DataExchangeError.tooManyEntries
        }
        var definitions: [C07MCPServerDefinition] = []
        var skipped: [C07MCPExportSkip] = []
        var sanitizedNames: [String] = []
        for (index, row) in rows.enumerated() {
            guard let rowData = try? JSONSerialization.data(
                withJSONObject: row, options: [.sortedKeys]) else {
                skipped.append(C07MCPExportSkip(
                    sourceID: "row-\(index)", reason: "invalidStoredRow"))
                continue
            }
            let configuration: MCPServerConfiguration
            do {
                configuration = try JSONDecoder().decode(
                    MCPServerConfiguration.self, from: rowData)
            } catch {
                skipped.append(C07MCPExportSkip(
                    sourceID: "row-\(index)", reason: "invalidStoredRow"))
                continue
            }
            do {
                let projected = try projection(of: configuration)
                try projected.validate()
                definitions.append(projected)
                if projected.requiresEndpointReconfiguration {
                    sanitizedNames.append(projected.displayName)
                }
            } catch {
                skipped.append(C07MCPExportSkip(
                    sourceID: configuration.id.uuidString,
                    reason: exportSkipReason(error)))
            }
        }
        let document = C07MCPConfigDocument(servers: definitions)
        try document.validate()
        return C07MCPExportResult(document: document,
                                  skipped: skipped,
                                  sanitizedNames: sanitizedNames)
    }

    /// Safe, non-secret projection of one saved definition. Userinfo/query/
    /// fragment are never copied; a suspicious path is omitted. Command
    /// arguments that look credential-bearing are rejected by
    /// `C07MCPServerDefinition.validate()` and therefore skipped whole.
    static func projection(of configuration: MCPServerConfiguration) throws
        -> C07MCPServerDefinition
    {
        guard !configuration.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw C07DataExchangeError.invalidManifest("mcpName")
        }
        let name = truncatedUTF8(configuration.displayName, maxBytes: 256)
        let timeout = min(max(configuration.timeoutSeconds, 5), 120)
        switch configuration.transport {
        case .streamableHTTP:
            guard let endpoint = configuration.endpoint,
                  let projected = projectEndpoint(endpoint) else {
                throw C07DataExchangeError.invalidManifest("mcpEndpoint")
            }
            let scheme = projected.scheme.lowercased()
            guard scheme == "https" || configuration.allowInsecureHTTP else {
                throw C07DataExchangeError.invalidManifest(
                    "mcpInsecureHTTPNotAllowed")
            }
            let auth = configuration.authentication.rawValue
            let header: String?
            if configuration.authentication == .customHeader {
                guard C07MCPServerDefinition.isValidHeaderName(
                    configuration.credentialHeaderName) else {
                    throw C07DataExchangeError.invalidManifest("mcpHeaderName")
                }
                header = configuration.credentialHeaderName
            } else {
                header = nil
            }
            return C07MCPServerDefinition(
                sourceID: configuration.id,
                displayName: name,
                transport: .streamableHTTP,
                endpoint: projected,
                authentication: auth,
                credentialHeaderName: header,
                allowInsecureHTTP: configuration.allowInsecureHTTP,
                timeoutSeconds: timeout,
                command: nil,
                arguments: [],
                workingDirectory: nil,
                requiresReauthentication: configuration.authentication != .none,
                requiresEnvironmentBinding: false,
                requiresEndpointReconfiguration:
                    projected.omittedQuery || projected.omittedFragment
                    || projected.omittedUserInfo || projected.omittedPath)
        case .stdio:
            guard configuration.authentication == .none else {
                throw C07DataExchangeError.invalidManifest(
                    "mcpStdioAuthentication")
            }
            guard let definition = configuration.resolvedStdioDefinition else {
                throw C07DataExchangeError.invalidManifest("mcpCommand")
            }
            return C07MCPServerDefinition(
                sourceID: configuration.id,
                displayName: name,
                transport: .stdio,
                endpoint: nil,
                authentication: "none",
                credentialHeaderName: nil,
                allowInsecureHTTP: false,
                timeoutSeconds: timeout,
                command: definition.command,
                arguments: definition.arguments,
                workingDirectory: definition.workingDirectory.isEmpty
                    ? nil : definition.workingDirectory,
                requiresReauthentication: false,
                requiresEnvironmentBinding: true,
                requiresEndpointReconfiguration: false)
        }
    }

    static func projectEndpoint(_ endpoint: URL)
        -> C07MCPEndpointProjection?
    {
        guard let scheme = endpoint.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = endpoint.host, !host.isEmpty else {
            return nil
        }
        let components = URLComponents(url: endpoint,
                                       resolvingAgainstBaseURL: false)
        var path = components?.percentEncodedPath ?? endpoint.path
        if path == "/" { path = "" }
        var omittedPath = false
        if !path.isEmpty,
           path.contains("@") || path.contains("=")
            || C07MCPServerDefinition.containsSecretLike(path) {
            omittedPath = true
            path = ""
        }
        let omittedQuery = components?.query != nil || endpoint.query != nil
        let omittedFragment = components?.fragment != nil
            || endpoint.fragment != nil
        let omittedUserInfo = components?.user != nil
            || components?.password != nil
            || endpoint.user != nil || endpoint.password != nil
        return C07MCPEndpointProjection(
            scheme: scheme,
            host: host.lowercased(),
            port: components?.port ?? endpoint.port,
            path: path,
            omittedQuery: omittedQuery,
            omittedFragment: omittedFragment,
            omittedUserInfo: omittedUserInfo,
            omittedPath: omittedPath)
    }

    private static func exportSkipReason(_ error: Error) -> String {
        guard let exchange = error as? C07DataExchangeError else {
            return "invalidDefinition"
        }
        switch exchange {
        case .invalidManifest(let reason): return reason
        case .duplicateIdentity: return "duplicateIdentity"
        default: return "invalidDefinition"
        }
    }

    // MARK: Restore merge / rollback

    /// Appends fresh identities to the CURRENT original row. Existing user
    /// servers are never replaced or deleted and concurrent local edits are
    /// preserved because the caller reads the row inside its own writer
    /// transaction. Re-running after an interrupted commit skips identities
    /// that are already present.
    public static func merge(currentRaw: String?,
                             definitions: [C07MCPServerDefinition],
                             newIDs: [String: String]) throws
        -> (raw: String?, inserted: [UUID])
    {
        var current = try decodeCurrent(currentRaw)
        guard !definitions.isEmpty else { return (currentRaw, []) }
        var names = Set(current.map {
            $0.displayName.lowercased()
        })
        var inserted: [UUID] = []
        for definition in definitions {
            guard let newText = newIDs[definition.sourceID.uuidString],
                  let newID = UUID(uuidString: newText) else {
                throw C07DataExchangeError.referenceMissing(
                    "mcpServerIdentity")
            }
            if current.contains(where: { $0.id == newID }) { continue }
            let name = uniqueName(definition.displayName, existing: names)
            names.insert(name.lowercased())
            let configuration = try makeConfiguration(
                from: definition, id: newID, displayName: name)
            try configuration.validateSavedDefinition()
            current.append(configuration)
            inserted.append(newID)
        }
        guard !inserted.isEmpty else { return (currentRaw, []) }
        return (try encode(current), inserted)
    }

    /// Removes exactly the fresh IDs this restore inserted. Any concurrent
    /// local definition remains untouched. When the row did not exist before
    /// the restore and nothing else remains, the row is removed again.
    public static func removing(ids: Set<UUID>,
                                fromRaw raw: String?,
                                removeRowWhenEmpty: Bool) throws -> String? {
        guard let raw else { return nil }
        let current = try decodeCurrent(raw)
        let remaining = current.filter { !ids.contains($0.id) }
        guard remaining.count != current.count else { return raw }
        if remaining.isEmpty && removeRowWhenEmpty { return nil }
        return try encode(remaining)
    }

    static func decodeCurrent(_ raw: String?) throws
        -> [MCPServerConfiguration]
    {
        guard let raw else { return [] }
        guard let data = raw.data(using: .utf8),
              data.count <= C07OwnedDataLimits.maximumConfigBytes else {
            throw C07DataExchangeError.invalidManifest("mcpStoreDecode")
        }
        do {
            return try JSONDecoder().decode(
                [MCPServerConfiguration].self, from: data)
        } catch {
            throw C07DataExchangeError.invalidManifest("mcpStoreDecode")
        }
    }

    static func encode(_ configurations: [MCPServerConfiguration]) throws
        -> String
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(configurations) }
        catch { throw C07DataExchangeError.storageUnavailable("mcpStoreEncode") }
        guard data.count <= C07OwnedDataLimits.maximumConfigBytes else {
            throw C07DataExchangeError.entryTooLarge("mcpServers")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw C07DataExchangeError.storageUnavailable("mcpStoreEncode")
        }
        return text
    }

    static func makeConfiguration(from definition: C07MCPServerDefinition,
                                  id: UUID,
                                  displayName: String) throws
        -> MCPServerConfiguration
    {
        let endpoint: URL?
        var transport: MCPServerConfiguration.Transport
        var stdioDefinition: MCPServerConfiguration.StdioDefinition?
        switch definition.transport {
        case .streamableHTTP:
            transport = .streamableHTTP
            guard let projected = definition.endpoint else {
                throw C07DataExchangeError.invalidManifest("mcpEndpoint")
            }
            var components = URLComponents()
            components.scheme = projected.scheme
            components.host = projected.host
            components.port = projected.port
            if !projected.path.isEmpty {
                components.percentEncodedPath = projected.path
            }
            guard let url = components.url else {
                throw C07DataExchangeError.invalidManifest("mcpEndpoint")
            }
            endpoint = url
            stdioDefinition = nil
        case .stdio:
            transport = .stdio
            endpoint = nil
            guard let command = definition.command else {
                throw C07DataExchangeError.invalidManifest("mcpCommand")
            }
            stdioDefinition = MCPServerConfiguration.StdioDefinition(
                command: command,
                arguments: definition.arguments,
                workingDirectory: definition.workingDirectory ?? "")
        }
        guard let authentication = MCPServerConfiguration.Authentication(
            rawValue: definition.authentication) else {
            throw C07DataExchangeError.invalidManifest("mcpAuthentication")
        }
        let configuration = MCPServerConfiguration(
            id: id,
            displayName: displayName,
            endpoint: endpoint,
            transport: transport,
            stdioDefinition: stdioDefinition,
            stdioBinding: nil,
            enabled: false,
            allowInCanvas: false,
            allowInsecureHTTP: definition.allowInsecureHTTP,
            authentication: authentication,
            credentialHeaderName: definition.credentialHeaderName
                ?? "Authorization",
            timeoutSeconds: definition.timeoutSeconds,
            disabledRemoteToolNames: [])
        return configuration
    }

    static func uniqueName(_ raw: String, existing: Set<String>) -> String {
        let base = truncatedUTF8(raw, maxBytes: 200)
        var candidate = "\(base) (restored)"
        var counter = 1
        while existing.contains(candidate.lowercased()) {
            counter += 1
            candidate = "\(base) (restored \(counter))"
        }
        return truncatedUTF8(candidate, maxBytes: 256)
    }

    static func truncatedUTF8(_ value: String, maxBytes: Int) -> String {
        guard maxBytes > 0, value.utf8.count > maxBytes else { return value }
        var bytes = Array(value.utf8.prefix(maxBytes))
        while !bytes.isEmpty {
            if let text = String(bytes: bytes, encoding: .utf8) { return text }
            bytes.removeLast()
        }
        return ""
    }
}

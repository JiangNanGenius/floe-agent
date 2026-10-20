// SPDX-License-Identifier: MPL-2.0
//
// RB-6 command routers + binding handoff — the typed async domain replies
// for the frozen `capability.tools.list`, `skills.list|install|uninstall`
// and `mcp.servers.list|connect|disconnect` rules. (private source
// candidate; NOT compiled, NOT executed, NOT registered by this package.)
//
// Same architecture as the accepted RB2 ModelConfigurationCommandRouter and
// the RB4 binding table: this file REGISTERS NOTHING. Synchronous v3 binder
// handlers, correlation dedupe, receipt minting and mailbox enqueue are
// exclusively RB1's (RuntimeFacadeBridge). Each router exposes ONE typed
// entry point returning exactly one terminal reply object:
//   {"state":"completed","value": ...}    reads + settled operations
//   {"errorCode": ..., "reason": ...}     typed rejection (frozen codes)
// which RB1's mailbox drain returns as the operation's single terminal
// effect under floe.effect-cursor/3 (reads complete in-frame for the pure
// list/detail operations; stateful operations surface the SAME object via
// effect.poll). Per Main's RB1 typed-carrier decision the terminal VALUE
// must be carried as a typed page/value payload added by the prepared RB1
// qualifier — identifier-only detail dictionaries cannot carry encoded
// JSON pages; these routers deliberately expose the actual typed JSON
// reply for that later adapter and do NOT duplicate the carrier, invent a
// new handler key or serialize a page into string detail.
//
// Command identity: names/scopes/labels/revision+createIntent flags are
// copied VERBATIM from the frozen matrix (BridgeEnvelopeV3.swift:133-148).
// The payload operation vocabularies below are the closed RB6 extensions
// INSIDE those existing rules (never new commands, labels or create flags).
//
// 29-callback coverage lives in reports/COVERAGE.md (per callback → command
// + operation + service call + receipt/revision/auth/availability mapping).
import Foundation
import Crypto
import FloeCore
import FloeTools
import FloeSkills

// MARK: - Command identity

public enum CapabilityDomainCommand: String, Sendable, CaseIterable {
    case capabilityToolsList = "capability.tools.list"
    case skillsList = "skills.list"
    case skillsInstall = "skills.install"
    case skillsUninstall = "skills.uninstall"
    case mcpServersList = "mcp.servers.list"
    case mcpConnect = "mcp.connect"
    case mcpDisconnect = "mcp.disconnect"

    /// EXACT frozen handler keys (BridgeV3.handlerKey,
    /// BridgeEnvelopeV3.swift:233-235).
    public var bridgeV3HandlerKey: String {
        "v3.command.applicationConfiguration.\(rawValue)"
    }

    public var configurationScope: String {
        switch self {
        case .capabilityToolsList: return "capabilities"
        case .skillsList, .skillsInstall, .skillsUninstall: return "skills"
        case .mcpServersList, .mcpConnect, .mcpDisconnect: return "mcp"
        }
    }

    /// The frozen matrix facts this package consumes (revisionRequired /
    /// allowsCreateIntent copied from BridgeEnvelopeV3:133-148; re-checked
    /// per operation below — shape never grants authority).
    public var revisionRequired: Bool {
        switch self {
        case .capabilityToolsList, .skillsList, .mcpServersList:
            return false
        case .skillsInstall, .skillsUninstall, .mcpConnect, .mcpDisconnect:
            return true
        }
    }

    public var allowsCreateIntent: Bool {
        switch self {
        case .skillsInstall, .mcpConnect: return true   // frozen: allow
        default: return false
        }
    }

    public static var supportedCommandNames: [String] { allCases.map { $0.rawValue } }
}

// MARK: - Closed RB6 payload operation vocabulary (inside existing rules)

/// skills.install operations. Every native UI mutation that is a stateful
/// skill-resource change flows through ONE frozen command name; the
/// operation discriminator is closed, unknown values are rejected before
/// any effect (never opportunistically parsed).
enum SkillsInstallOperation: String, Sendable, CaseIterable {
    case officialInstall = "official.install"      // new (createIntent) or upgrade review
    case reviewConfirm = "review.confirm"          // confirmPendingInstallation
    case reviewDiscard = "review.discard"          // cancelPendingInstallation
    case enabledSet = "enabled.set"                // setSkillEnabled (digest CAS)
    case creatorCreate = "creator.create"          // createSkill (direct materialization)
    case finderImport = "finder.import"            // installFromFinder
    case folderImport = "folder.import"            // importStagedPackage (host receipt)
    case upgradeCheck = "upgrade.check"            // checkUpgrade
    case upgradeApply = "upgrade.apply"            // applyUpgrade
    case upgradeDiscard = "upgrade.discard"        // cancelUpgrade
    case upgradeRollback = "upgrade.rollback"      // rollbackUpgrade
    case settingsSet = "settings.set"              // setAutoScriptedUpdates (digest CAS)
}

/// skills.list operations (reads; stateful=false so no revision/create).
enum SkillsListOperation: String, Sendable, CaseIterable {
    case snapshot                              // default (load hub)
    case catalogRefresh = "catalog.refresh"    // refreshCatalog (async effect)
    case detail                                // bounded markdown window
    case settingsRead = "settings.read"        // skills settings document
}

/// mcp.connect operations: one frozen command covering the native
/// configured-server CRUD + connect/refresh semantics under the allowed
/// create/mutation payload (Main decision: existing skills.install /
/// mcp.connect createIntent allowances ARE the legitimate create path).
enum MCPConnectOperation: String, Sendable, CaseIterable {
    case save                       // seedMcpEditor→saveMcpServer (Set/Keep/Clear)
    case connect                    // refreshMcpServer (new generation)
    case enabledSet = "enabled.set" // setMcpServerEnabled
    case toolEnabledSet = "tool.enabled.set" // setMcpToolEnabled
}

/// mcp.disconnect operations.
enum MCPDisconnectOperation: String, Sendable, CaseIterable {
    case disconnect                 // drop connection, keep config
    case cancelRefresh = "cancel.refresh" // generation-fenced cancel
    case remove                     // deleteMcpServer (+ bound credential cleanup)
}

// MARK: - Shared helpers

enum CapabilitiesReplies {
    static func completed(_ value: [String: Any]) -> Data {
        let wrapped: [String: Any] = ["state": "completed", "value": value]
        return (try? JSONSerialization.data(withJSONObject: wrapped,
                                            options: [.sortedKeys]))
            ?? Data("{\"errorCode\":\"invalidJSON\",\"reason\":\"resultEncode\"}".utf8)
    }

    static func completed(_ value: Data) -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any] else {
            return Data("{\"errorCode\":\"invalidJSON\",\"reason\":\"valueEncode\"}".utf8)
        }
        return completed(object)
    }

    static func rejected(_ error: ConfigDomainError) -> Data {
        (try? JSONSerialization.data(withJSONObject: error.jsonBody(),
                                    options: [.sortedKeys]))
            ?? Data("{\"errorCode\":\"runtimeUnavailable\",\"reason\":\"rejectEncode\"}".utf8)
    }

    static func rejected(refusal: any Error) -> Data {
        rejected(ConfigDomainError(domainRefusal: refusal))
    }

    /// Single mapping entry for the three domain refusal enums (no new
    /// wire codes).
    static func map(_ error: any Error) -> Data {
        if let domain = error as? ConfigDomainError { return rejected(domain) }
        return rejected(ConfigDomainError(domainRefusal: error))
    }
}

extension ConfigDomainError {
    /// Cross-domain refusal mapping: Skills/MCP/Capabilities refusals share
    /// the frozen code set; each concrete mapping already exists per file,
    /// this dispatcher keeps the routers honest (never a raw-message leak).
    init(domainRefusal error: any Error) {
        switch error {
        case let refusal as SkillsDomainRefusal: self.init(refusal)
        case let refusal as MCPDomainRefusal: self.init(refusal)
        case let refusal as CapabilitiesDomain.CapabilitiesRefusal: self.init(refusal)
        case is CancellationError: self.init(code: .runtimeUnavailable, reason: "cancelled")
        default: self.init(code: .runtimeUnavailable,
                            reason: "unclassifiedRefusal")
        }
    }
}

// MARK: - Skills router

public actor SkillsCommandRouter {
    private let domain: SkillsDomain

    public init(domain: SkillsDomain) { self.domain = domain }

    /// ONE skills command envelope → ONE typed terminal reply (Data).
    /// Re-parses ONLY closed fields; every revision/token is re-checked
    /// against the actual stores inside the domain. Model-authored JSON
    /// cannot mint ids, revisions, tokens or permissions.
    public func handle(command: String, envelope: [String: Any]) async -> Data {
        guard let op = CapabilityDomainCommand(rawValue: command),
              op == .skillsList || op == .skillsInstall || op == .skillsUninstall else {
            return CapabilitiesReplies.rejected(ConfigDomainError(
                code: .unsupportedOperation, reason: "outsideSkillsDomain"))
        }
        let view: CapabilitiesEnvelopeView
        do {
            view = try CapabilitiesEnvelopeView(envelope: envelope)
        } catch let error as ConfigDomainError {
            return CapabilitiesReplies.rejected(error)
        } catch {
            return CapabilitiesReplies.rejected(ConfigDomainError(code: .invalidEnvelope,
                                                                  reason: "skillsEnvelope"))
        }
        do {
            switch op {
            case .skillsList:
                return try await handleList(view)
            case .skillsInstall:
                return try await handleInstall(view)
            case .skillsUninstall:
                return try await handleUninstall(view)
            default:
                return CapabilitiesReplies.rejected(ConfigDomainError(
                    code: .unsupportedOperation, reason: "outsideSkillsDomain"))
            }
        } catch {
            return CapabilitiesReplies.map(error)
        }
    }

    private func handleList(_ view: CapabilitiesEnvelopeView) async throws -> Data {
        let payload = view.payload ?? [:]
        let operationName = (payload["operation"] as? String) ?? "snapshot"
        let cursor = try view.payloadCursor()
        switch operationName {
        case "snapshot":
            try ConfigJSON.closed(payload, allowed: ["operation", "cursor"],
                                  context: "skillsList")
            return CapabilitiesReplies.completed(try await domain.snapshot(cursor: cursor))
        case SkillsListOperation.catalogRefresh.rawValue:
            try ConfigJSON.closed(payload, allowed: ["operation", "force", "cursor"],
                                  context: "skillsCatalogRefresh")
            let force = (payload["force"] as? Bool) ?? false
            return CapabilitiesReplies.completed(try await domain.refreshCatalog(force: force))
        case SkillsListOperation.detail.rawValue:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "skillId", "byteOffset",
                                            "maxBytes", "cursor"],
                                  required: ["skillId"],
                                  context: "skillsDetail")
            guard let skillID = payload["skillId"] as? String else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "detailSkillID")
            }
            let offset = (payload["byteOffset"] as? Int) ?? 0
            let maxBytes = (payload["maxBytes"] ?? SkillsMcpLimits.maximumWindowBytes) as? Int
                ?? SkillsMcpLimits.maximumWindowBytes
            return CapabilitiesReplies.completed(
                try await domain.detail(skillID: skillID, byteOffset: offset,
                                        maxBytes: maxBytes))
        case SkillsListOperation.settingsRead.rawValue:
            try ConfigJSON.closed(payload, allowed: ["operation", "cursor"],
                                  context: "skillsSettingsRead")
            return CapabilitiesReplies.completed(try await domain.settingsDocument())
        default:
            throw ConfigDomainError(code: .invalidEnvelope, reason: "skillsListOperation")
        }
    }

    private func handleInstall(_ view: CapabilitiesEnvelopeView) async throws -> Data {
        guard let payload = view.payload else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "installPayloadMissing")
        }
        guard let operationName = payload["operation"] as? String,
              let operation = SkillsInstallOperation(rawValue: operationName) else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "installOperation")
        }
        let revision = view.revision
        let createIntent = view.createIntent
        // Per-operation closed shape + revision/createIntent alignment with
        // the FROZEN matrix (the wire validator enforced stateful/revision
        // presence; the domain re-checks meaning, never shape alone).
        switch operation {
        case .officialInstall:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "skillId", "cursor"],
                                  required: ["skillId"],
                                  context: "officialInstall")
            guard let skillID = payload["skillId"] as? String else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "officialSkillID")
            }
            let projection = try await domain.installOfficial(
                skillID: skillID, revision: revision, createIntent: createIntent)
            return CapabilitiesReplies.completed(projection.jsonObject())
        case .reviewConfirm:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "reviewToken", "cursor"],
                                  required: ["reviewToken"],
                                  context: "reviewConfirm")
            guard let token = payload["reviewToken"] as? String,
                  FacadeCapabilityToken.isValid(token,
                                                prefix: FacadeCapabilityToken.effectPrefix)
            else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "reviewTokenShape")
            }
            return CapabilitiesReplies.completed(
                try await domain.reviewCommit(token: token,
                                              createIntent: createIntent,
                                              revision: revision))
        case .reviewDiscard:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "reviewToken", "cursor"],
                                  required: ["reviewToken"],
                                  context: "reviewDiscard")
            guard let token = payload["reviewToken"] as? String,
                  FacadeCapabilityToken.isValid(token,
                                                prefix: FacadeCapabilityToken.effectPrefix)
            else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "reviewTokenShape")
            }
            return CapabilitiesReplies.completed(try await domain.reviewDiscard(token: token))
        case .enabledSet:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "skillId", "enabled", "cursor"],
                                  required: ["skillId", "enabled"],
                                  context: "enabledSet")
            guard let revision,
                  let skillID = payload["skillId"] as? String,
                  let enabled = payload["enabled"] as? Bool else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "enabledSetInputs")
            }
            guard !createIntent else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "enabledSetCreateConflict")
            }
            return CapabilitiesReplies.completed(
                try await domain.setEnabled(skillID: skillID, revision: revision,
                                            enabled: enabled))
        case .creatorCreate:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "draft", "cursor"],
                                  required: ["draft"],
                                  context: "creatorCreate")
            guard createIntent, revision == nil else {
                // New identity: explicit create intent ONLY; never a
                // fabricated resource version (frozen rule).
                throw ConfigDomainError(code: .invalidEnvelope, reason: "creatorCreateIntent")
            }
            guard let draftObject = payload["draft"] as? [String: Any] else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "creatorDraftShape")
            }
            let draft = try Self.parseCreationDraft(draftObject)
            let projection = try await domain.createSkill(draft: draft)
            return CapabilitiesReplies.completed(projection.jsonObject())
        case .finderImport:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "url", "rewriteModelId", "cursor"],
                                  required: ["url"],
                                  context: "finderImport")
            guard createIntent, revision == nil else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "finderCreateIntent")
            }
            guard let url = payload["url"] as? String else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "finderURLShape")
            }
            let rewriteModelID = try Self.optionalUUIDString(payload["rewriteModelId"],
                                                             context: "finderRewriteModel")
            let projection = try await domain.finderImport(urlText: url,
                                                           rewriteModelID: rewriteModelID)
            return CapabilitiesReplies.completed(projection.jsonObject())
        case .folderImport:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "stagingToken", "cursor"],
                                  required: ["stagingToken"],
                                  context: "folderImport")
            guard createIntent, revision == nil else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "folderCreateIntent")
            }
            guard let token = payload["stagingToken"] as? String,
                  FacadeCapabilityToken.isValid(token,
                                                prefix: FacadeCapabilityToken.stagingPrefix)
            else {
                // A model-authored arbitrary path/file token is impossible
                // by shape: only domain-minted stg:v1 handles parse.
                throw ConfigDomainError(code: .invalidEnvelope, reason: "stagingTokenShape")
            }
            let projection = try await domain.importStagedFolder(token: token)
            return CapabilitiesReplies.completed(projection.jsonObject())
        case .upgradeCheck:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "skillId", "source", "cursor"],
                                  required: ["skillId"],
                                  context: "upgradeCheck")
            guard !createIntent, let skillID = payload["skillId"] as? String else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "upgradeCheckInputs")
            }
            let source: GitHubSkillSource?
            if let sourceObject = payload["source"] as? [String: Any] {
                try ConfigJSON.closed(sourceObject,
                                      allowed: ["owner", "repository", "ref", "path"],
                                      required: ["owner", "repository", "ref", "path"],
                                      context: "upgradeSource")
                guard let owner = sourceObject["owner"] as? String,
                      let repository = sourceObject["repository"] as? String,
                      let ref = sourceObject["ref"] as? String,
                      let path = sourceObject["path"] as? String else {
                    throw ConfigDomainError(code: .invalidEnvelope, reason: "upgradeSourceShape")
                }
                // ORIGINAL validation (GitHubSkillSource.init throws on
                // every unsafe component/ref/path form).
                do {
                    source = try GitHubSkillSource(owner: owner, repository: repository,
                                                   ref: ref, path: path)
                } catch {
                    throw ConfigDomainError(code: .invalidEnvelope, reason: "upgradeSourceInvalid")
                }
            } else {
                source = nil
            }
            let projection = try await domain.checkUpgrade(skillID: skillID, source: source)
            return CapabilitiesReplies.completed(projection.jsonObject())
        case .upgradeApply:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "reviewToken", "effectToken",
                                            "cursor"],
                                  required: ["reviewToken"],
                                  context: "upgradeApply")
            guard !createIntent,
                  let token = payload["reviewToken"] as? String,
                  FacadeCapabilityToken.isValid(token,
                                                prefix: FacadeCapabilityToken.effectPrefix)
            else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "upgradeApplyInputs")
            }
            let effectToken = payload["effectToken"] as? String
            return CapabilitiesReplies.completed(
                try await domain.upgradeApply(reviewToken: token,
                                              effectToken: effectToken,
                                              revision: revision))
        case .upgradeDiscard:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "skillId", "cursor"],
                                  required: ["skillId"],
                                  context: "upgradeDiscard")
            guard let skillID = payload["skillId"] as? String else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "upgradeDiscardInputs")
            }
            return CapabilitiesReplies.completed(try await domain.upgradeDiscard(skillID: skillID))
        case .upgradeRollback:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "skillId", "cursor"],
                                  required: ["skillId"],
                                  context: "upgradeRollback")
            guard !createIntent, let revision,
                  let skillID = payload["skillId"] as? String else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "rollbackInputs")
            }
            return CapabilitiesReplies.completed(
                try await domain.upgradeRollback(skillID: skillID, revision: revision))
        case .settingsSet:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "enabled", "cursor"],
                                  required: ["enabled"],
                                  context: "settingsSet")
            guard !createIntent, let revision,
                  let enabled = payload["enabled"] as? Bool else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "settingsSetInputs")
            }
            return CapabilitiesReplies.completed(
                try await domain.setAutoScriptedUpdates(enabled: enabled,
                                                        revision: revision))
        }
    }

    private func handleUninstall(_ view: CapabilitiesEnvelopeView) async throws -> Data {
        let payload = view.payload ?? [:]
        try ConfigJSON.closed(payload, allowed: ["operation", "cursor"],
                              context: "skillsUninstall")
        let revision = view.revision
        guard !view.createIntent, let revision else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "uninstallRevisionRequired")
        }
        // Identity rides the revision resourceID ("skill.<id>") — the one
        // frozen, non-forgeable identity carrier for this command.
        guard revision.resourceID.hasPrefix("skill."),
              revision.resourceID.utf8.count > 6 else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "uninstallResourceShape")
        }
        let skillID = String(revision.resourceID.dropFirst("skill.".count))
        return CapabilitiesReplies.completed(
            try await domain.uninstall(skillID: skillID, revision: revision))
    }

    /// SkillCreationRequest from a closed draft object (ORIGINAL bounds via
    /// the create funnel + validator; this layer only shapes input).
    static func parseCreationDraft(_ object: [String: Any]) throws -> SkillCreationRequest {
        try ConfigJSON.closed(object,
                              allowed: ["name", "description", "instructions",
                                        "pythonScripts", "pythonPackages"],
                              required: ["name", "description", "instructions"],
                              context: "creatorDraft")
        guard let name = object["name"] as? String,
              let description = object["description"] as? String,
              let instructions = object["instructions"] as? String else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "creatorDraftStrings")
        }
        // ORIGINAL SkillCreateTool limits (Tools/SkillCreateTool.swift:79-82,
        // 105): name 128 B / description 512 B / instructions 256 KiB /
        // script 64 KiB / max 8 scripts / 16 packages.
        guard name.utf8.count <= 128, description.utf8.count <= 512,
              instructions.utf8.count <= 262_144 else {
            throw ConfigDomainError(code: .payloadTooLarge, reason: "creatorDraftBounds")
        }
        var scripts: [SkillBundledPythonScript] = []
        if case let list as [[String: Any]] = object["pythonScripts"] {
            guard list.count <= 8 else {
                throw ConfigDomainError(code: .payloadTooLarge, reason: "creatorScriptsCount")
            }
            for entry in list {
                try ConfigJSON.closed(entry, allowed: ["relativePath", "source"],
                                      required: ["relativePath", "source"],
                                      context: "creatorScript")
                guard let relativePath = entry["relativePath"] as? String,
                      let source = entry["source"] as? String,
                      source.utf8.count <= 65_536 else {
                    throw ConfigDomainError(code: .invalidEnvelope, reason: "creatorScriptShape")
                }
                scripts.append(SkillBundledPythonScript(relativePath: relativePath,
                                                        source: source))
            }
        }
        var packages: [SkillPythonPackageRequirement] = []
        if case let list as [[String: Any]] = object["pythonPackages"] {
            guard list.count <= 16 else {
                throw ConfigDomainError(code: .payloadTooLarge, reason: "creatorPackagesCount")
            }
            for entry in list {
                try ConfigJSON.closed(entry, allowed: ["spec", "purpose", "capabilities"],
                                      required: ["spec", "purpose", "capabilities"],
                                      context: "creatorPackage")
                guard let spec = entry["spec"] as? String,
                      let purpose = entry["purpose"] as? String,
                      let capabilities = entry["capabilities"] as? [String] else {
                    throw ConfigDomainError(code: .invalidEnvelope, reason: "creatorPackageShape")
                }
                packages.append(SkillPythonPackageRequirement(spec: spec, purpose: purpose,
                                                              capabilities: capabilities))
            }
        }
        return SkillCreationRequest(name: name, description: description,
                                    instructions: instructions,
                                    pythonScripts: scripts, pythonPackages: packages)
    }

    static func optionalUUIDString(_ value: Any?, context: String) throws -> String? {
        switch value {
        case .none, is NSNull:
            return nil
        case let raw as String:
            guard UUID(uuidString: raw) != nil, raw.utf8.count <= 64 else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "shape.\(context)")
            }
            return raw
        default:
            throw ConfigDomainError(code: .invalidEnvelope, reason: "shape.\(context)")
        }
    }
}

// MARK: - MCP router

public actor MCPCommandRouter {
    private let domain: MCPDomain
    private let routeContext: any SkillsMcpRouteContextProviding

    public init(domain: MCPDomain,
                routeContext: any SkillsMcpRouteContextProviding) {
        self.domain = domain
        self.routeContext = routeContext
    }

    public func handle(command: String, envelope: [String: Any]) async -> Data {
        guard let op = CapabilityDomainCommand(rawValue: command),
              op == .mcpServersList || op == .mcpConnect || op == .mcpDisconnect else {
            return CapabilitiesReplies.rejected(ConfigDomainError(
                code: .unsupportedOperation, reason: "outsideMCPDomain"))
        }
        let view: CapabilitiesEnvelopeView
        do {
            view = try CapabilitiesEnvelopeView(envelope: envelope)
        } catch let error as ConfigDomainError {
            return CapabilitiesReplies.rejected(error)
        } catch {
            return CapabilitiesReplies.rejected(ConfigDomainError(code: .invalidEnvelope,
                                                                  reason: "mcpEnvelope"))
        }
        do {
            switch op {
            case .mcpServersList:
                let payload = view.payload ?? [:]
                try ConfigJSON.closed(payload,
                                      allowed: ["operation", "serverId", "cursor"],
                                      context: "mcpList")
                let cursor = try view.payloadCursor()
                return CapabilitiesReplies.completed(try await domain.list(cursor: cursor))
            case .mcpConnect:
                return try await handleConnect(view)
            case .mcpDisconnect:
                return try await handleDisconnect(view)
            default:
                return CapabilitiesReplies.rejected(ConfigDomainError(
                    code: .unsupportedOperation, reason: "outsideMCPDomain"))
            }
        } catch {
            return CapabilitiesReplies.map(error)
        }
    }

    private func handleConnect(_ view: CapabilitiesEnvelopeView) async throws -> Data {
        guard let payload = view.payload,
              let operationName = payload["operation"] as? String,
              let operation = MCPConnectOperation(rawValue: operationName) else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "mcpConnectOperation")
        }
        let revision = view.revision
        let createIntent = view.createIntent
        switch operation {
        case .save:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "secretIntent", "ingressToken",
                                            "candidate", "cursor"],
                                  required: ["secretIntent"],
                                  context: "mcpSave")
            guard let intent = payload["secretIntent"] as? String else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "mcpSaveIntentShape")
            }
            switch intent {
            case "set":
                // Set: ONLY the opaque int:v1 handle rides the wire; the
                // frozen candidate + secret live in the one-shot lease. The
                // route/generation come from the trusted host seam.
                guard let token = payload["ingressToken"] as? String,
                      payload["candidate"] == nil,
                      SecretGatewayIdentity.isCanonicalIngressToken(token) else {
                    throw ConfigDomainError(code: .invalidEnvelope, reason: "mcpSetInputs")
                }
                return CapabilitiesReplies.completed(
                    await domain.saveSet(ingressToken: token,
                                         envelopeRevision: revision))
            case "keep", "clear":
                guard let candidateObject = payload["candidate"] as? [String: Any],
                      payload["ingressToken"] == nil else {
                    throw ConfigDomainError(code: .invalidEnvelope, reason: "mcpCandidateInputs")
                }
                guard JSONSerialization.isValidJSONObject(candidateObject),
                      let candidateData = try? JSONSerialization.data(
                        withJSONObject: candidateObject, options: [.sortedKeys]) else {
                    throw ConfigDomainError(code: .invalidEnvelope, reason: "mcpCandidateEncode")
                }
                let probe = try ConfigJSON.object(from: candidateData)
                _ = probe // credential-name refusal scan (RB2 boundary belt)
                return CapabilitiesReplies.completed(
                    await domain.save(candidateJSON: candidateData,
                                      secretIntent: intent,
                                      envelopeRevision: revision))
            default:
                throw ConfigDomainError(code: .invalidEnvelope, reason: "mcpSaveIntentUnknown")
            }
        case .connect:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "serverId", "cursor"],
                                  required: ["serverId"],
                                  context: "mcpConnectOp")
            guard !createIntent,
                  let raw = payload["serverId"] as? String,
                  let serverID = UUID(uuidString: raw) else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "mcpConnectInputs")
            }
            return CapabilitiesReplies.completed(await domain.connect(serverID: serverID))
        case .enabledSet:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "serverId", "enabled", "cursor"],
                                  required: ["serverId", "enabled"],
                                  context: "mcpEnabledSet")
            guard !createIntent, let revision,
                  let raw = payload["serverId"] as? String,
                  let serverID = UUID(uuidString: raw),
                  let enabled = payload["enabled"] as? Bool else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "mcpEnabledSetInputs")
            }
            return CapabilitiesReplies.completed(
                await domain.setEnabled(serverID: serverID, enabled: enabled,
                                        revision: revision))
        case .toolEnabledSet:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "serverId", "remoteName",
                                            "enabled", "cursor"],
                                  required: ["serverId", "remoteName", "enabled"],
                                  context: "mcpToolEnabledSet")
            guard !createIntent, let revision,
                  let raw = payload["serverId"] as? String,
                  let serverID = UUID(uuidString: raw),
                  let remoteName = payload["remoteName"] as? String,
                  let enabled = payload["enabled"] as? Bool else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "mcpToolEnabledInputs")
            }
            return CapabilitiesReplies.completed(
                await domain.setToolEnabled(serverID: serverID, remoteName: remoteName,
                                            enabled: enabled, revision: revision))
        }
    }

    private func handleDisconnect(_ view: CapabilitiesEnvelopeView) async throws -> Data {
        guard let payload = view.payload,
              let operationName = payload["operation"] as? String,
              let operation = MCPDisconnectOperation(rawValue: operationName) else {
            // Default: disconnect requires the explicit operation so a bare
            // payload can never mean "remove" (destructive ops are named).
            throw ConfigDomainError(code: .invalidEnvelope, reason: "mcpDisconnectOperation")
        }
        guard !view.createIntent else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "mcpDisconnectCreate")
        }
        let revision = view.revision
        switch operation {
        case .disconnect, .remove:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "serverId", "cursor"],
                                  required: ["serverId"],
                                  context: "mcpDisconnect")
            guard let revision,
                  let raw = payload["serverId"] as? String,
                  let serverID = UUID(uuidString: raw) else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "mcpDisconnectInputs")
            }
            if operation == .remove {
                return CapabilitiesReplies.completed(
                    await domain.remove(serverID: serverID, revision: revision))
            }
            return CapabilitiesReplies.completed(
                await domain.disconnect(serverID: serverID, revision: revision))
        case .cancelRefresh:
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "serverId", "generation", "cursor"],
                                  required: ["serverId", "generation"],
                                  context: "mcpCancelRefresh")
            guard let raw = payload["serverId"] as? String,
                  let serverID = UUID(uuidString: raw),
                  let generation = payload["generation"] as? String,
                  generation.utf8.count <= 24,
                  generation.allSatisfy(\.isNumber) else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "mcpCancelInputs")
            }
            return CapabilitiesReplies.completed(
                await domain.cancelRefresh(serverID: serverID, generation: generation))
        }
    }
}

// MARK: - Capabilities router

public actor CapabilitiesCommandRouter {
    private let domain: CapabilitiesDomain

    public init(domain: CapabilitiesDomain) { self.domain = domain }

    public func handle(command: String, envelope: [String: Any]) async -> Data {
        guard command == CapabilityDomainCommand.capabilityToolsList.rawValue else {
            return CapabilitiesReplies.rejected(ConfigDomainError(
                code: .unsupportedOperation, reason: "outsideCapabilitiesDomain"))
        }
        let view: CapabilitiesEnvelopeView
        do {
            view = try CapabilitiesEnvelopeView(envelope: envelope)
        } catch let error as ConfigDomainError {
            return CapabilitiesReplies.rejected(error)
        } catch {
            return CapabilitiesReplies.rejected(ConfigDomainError(code: .invalidEnvelope,
                                                                  reason: "capabilitiesEnvelope"))
        }
        do {
            let payload = view.payload ?? [:]
            try ConfigJSON.closed(payload,
                                  allowed: ["operation", "modelId", "includeUnavailable",
                                            "cursor"],
                                  context: "capabilityToolsList")
            let modelID = payload["modelId"] as? String
            let includeUnavailable = (payload["includeUnavailable"] as? Bool) ?? false
            let cursor = try view.payloadCursor()
            let value = try await domain.list(modelID: modelID,
                                              includeUnavailable: includeUnavailable,
                                              cursor: cursor)
            return CapabilitiesReplies.completed(value)
        } catch {
            return CapabilitiesReplies.map(error)
        }
    }
}

// MARK: - MCPDomain ⇄ Capabilities observation (the one live mapping)

extension MCPDomain: CapabilitiesMCPObserving {
    // Actor-isolated async reads of the internal connection track (same-module
    // integration conformance; the capabilities resolver awaits these).
    /// Prefixes whose LAST discovery legitimately completed (ready state
    /// holds the registered tool set) — the ORIGINAL registration truth.
    public func activeServerPrefixes() async -> Set<String> {
        var prefixes: Set<String> = []
        for server in servers {
            if case .ready = connections[server.id]?.state {
                prefixes.insert(CapabilitiesDomain.mcpPrefix(forServerID: server.id))
            }
        }
        return prefixes
    }

    /// Auth-mode servers without a resolvable secret right now. The check
    /// uses the connection track's LAST credential outcome (no gateway read
    /// happens on this synchronous path; the authoritative state surfaces
    /// through mcp.servers.list). Servers that have never attempted a
    /// connect with a failure are NOT flagged here — discovery simply has
    /// not run yet (their tools are absent from the registry anyway).
    public func prefixesNeedingCredential() async -> Set<String> {
        var prefixes: Set<String> = []
        for server in servers where server.authentication != .none {
            if case .failed(let reason, _) = connections[server.id]?.state,
               reason == ConfigCredentialAvailability.secretMissing.rawValue
                || reason == ConfigCredentialAvailability.gatewayUnregistered.rawValue
                || reason == ConfigCredentialAvailability.secretLocked.rawValue
                || reason == ConfigCredentialAvailability.secretInvalidated.rawValue
                || reason == "authenticationRequired" {
                prefixes.insert(CapabilitiesDomain.mcpPrefix(forServerID: server.id))
            }
        }
        return prefixes
    }
}

// MARK: - RB6 binding handoff (Main integration map; NOT self-registration)

/// The exact closed set this package is ready to bind, in the accepted RB4
/// `RuntimeFacadeRunBindings` table shape. Main wires binder handlers +
/// mailbox processors for these keys into the RB1 registry during the
/// serial publication window; nothing here registers, overrides or
/// re-registers an existing key (shared applicationConfiguration routes are
/// composed per configurationScope by the qualifier — conversations/
/// personalization/… each target their real owner, and these three labels —
/// capabilities/skills/mcp — are this package's owners).
public enum RuntimeFacadeCapabilitiesBindings {
    public struct Binding: Sendable {
        public let handlerKey: String
        public let command: String
        public let configurationScope: String
        public let revisionRequired: Bool
        public let allowsCreateIntent: Bool
        public let serviceMethod: String
        public let integrationNote: String
    }

    public static let bindings: [Binding] = [
        Binding(handlerKey: CapabilityDomainCommand.capabilityToolsList.bridgeV3HandlerKey,
                command: "capability.tools.list", configurationScope: "capabilities",
                revisionRequired: false, allowsCreateIntent: false,
                serviceMethod: "CapabilitiesCommandRouter.handle",
                integrationNote: "ACTUAL registry availability + CapabilityExecutionRouter G03 honesty + CURRENT upstream public-web-only temp projection + saved model override (explicitCapabilities authoritative). Typed page/value carrier via the prepared RB1 qualifier; identifier-only detail cannot carry the encoded page."),
        Binding(handlerKey: CapabilityDomainCommand.skillsList.bridgeV3HandlerKey,
                command: "skills.list", configurationScope: "skills",
                revisionRequired: false, allowsCreateIntent: false,
                serviceMethod: "SkillsCommandRouter.handle",
                integrationNote: "snapshot | catalog.refresh(async effect, hourly gate) | detail(32KiB owned window) | settings.read; stop-at-budget 48KiB actual UTF-8."),
        Binding(handlerKey: CapabilityDomainCommand.skillsInstall.bridgeV3HandlerKey,
                command: "skills.install", configurationScope: "skills",
                revisionRequired: true, allowsCreateIntent: true,
                serviceMethod: "SkillsCommandRouter.handle",
                integrationNote: "official.install/review.confirm/review.discard/enabled.set/ creator.create/finder.import/folder.import(stg:v1 host receipt only)/upgrade.*/settings.set. Existing identity = digest CAS; NEW identity = explicit createIntent only. Commits flow through SkillInstallStagingService (file move, metadata second, rollback of previous valid version). Never queue-accepted==installed."),
        Binding(handlerKey: CapabilityDomainCommand.skillsUninstall.bridgeV3HandlerKey,
                command: "skills.uninstall", configurationScope: "skills",
                revisionRequired: true, allowsCreateIntent: false,
                serviceMethod: "SkillsCommandRouter.handle",
                integrationNote: "skill.<id>/digest identity; quiesce owned workers first; RemovedSkills recoverable backup; suppressBundledSeed for official ids; file-restore on DB failure (original ordering)."),
        Binding(handlerKey: CapabilityDomainCommand.mcpServersList.bridgeV3HandlerKey,
                command: "mcp.servers.list", configurationScope: "mcp",
                revisionRequired: false, allowsCreateIntent: false,
                serviceMethod: "MCPCommandRouter.handle",
                integrationNote: "servers+tool inventory+per-server connection truth+ credential STATUS (canonical ref, never bytes)+cleanupPending+transports inventory (streamable HTTP/SSE real; stdio/SSH/linux NOT_IMPLEMENTED G03, retained not dropped)."),
        Binding(handlerKey: CapabilityDomainCommand.mcpConnect.bridgeV3HandlerKey,
                command: "mcp.connect", configurationScope: "mcp",
                revisionRequired: true, allowsCreateIntent: true,
                serviceMethod: "MCPCommandRouter.handle",
                integrationNote: "save(Set one-shot mcpSave lease, route from trusted host, canonical org.floeagent.ios.mcp namespace + mcp.<uuid>.<scheme>.<host>.<port> account, ref:v1 readback, C0/C1/unknown honest)/keep/clear + connect(enabled→refresh under monotonic generation)/enabled.set/tool.enabled.set(re-register same client, no reconnect). credential/needsConfiguration/transportUnavailable refused BEFORE network; explicit .none auth only."),
        Binding(handlerKey: CapabilityDomainCommand.mcpDisconnect.bridgeV3HandlerKey,
                command: "mcp.disconnect", configurationScope: "mcp",
                revisionRequired: true, allowsCreateIntent: false,
                serviceMethod: "MCPCommandRouter.handle",
                integrationNote: "disconnect|cancel.refresh(exact generation)|remove(named destructive op). Cancels ONLY the matching server/root-generation owned workers; late results cannot restore a closed connection; remove enqueues durable cleanup BEFORE destruction; unknown outcomes keep the intent."),
    ]

    /// Companion ports this package OWNS and must be bound at integration:
    public static let ports: [String] = [
        // run.skillcancel adapter (RB4 declares the port; RB6 implements):
        "RunOwnedToolCancellation ⇄ FacadeToolWorkCoordinator (mcp-refresh/skill staging workers; honest false otherwise — per-call runtime task tree is RB4-owned)",
        // RB4/RB5 temporary ceiling composition:
        "FacadeTemporaryCeiling ⇄ RunToolAssembly/AgentRuntime temp projection",
        // RB4 per-run skill selection (Configuration inputs):
        "SkillsDomain.runtimeSelection ⇄ FloeAgentRuntime.Configuration",
        // RB2 shared web-search resolver feeding capabilities:
        "CapabilitiesWebSearchProviding ⇄ ModelConfigurationFacade websearch state",
        // RB7 host staging (folder picker → registerStagedFolder receipt):
        "SkillsDomain.registerStagedFolder ⇄ SAF host copy (never a wire path)",
    ]
}
